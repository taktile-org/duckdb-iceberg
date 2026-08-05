#!/usr/bin/env bash
set -euo pipefail

# Usage: cut-tag.sh [--from <prev-tag>] [--stable-base <ref>] <sha1> [<sha2> ...]
#        cut-tag.sh --continue
#        cut-tag.sh --abort
#
# Cuts a new internal tag: fresh checkout of a base commit, cherry-pick the
# given commits (in order), tag the result. Tag name is
# yyyymmddThhmmZ-<short-sha-of-base>, so the base is always recoverable
# straight from the tag name later - no separate file needed.
#
# Default base is the upstream mirror's current tip (fast-forwarded from
# duckdb/duckdb-iceberg:main first) - right for tags meant to become upstream
# PRs, since a PR has to apply cleanly against current main anyway.
#
# --stable-base <ref> cuts from an explicit ref instead - use this for a tag
# meant to be built against a STABLE (released) duckdb version rather than
# main's own dev-pinned tip, e.g. what tktl-duckdb's download.py consumes via
# TAKTILE_ICEBERG_TAG. A tag cut from upstream's live tip is NOT guaranteed to
# compile against a stable duckdb release: main's iceberg source and its
# extension_config.cmake dependency pins (avro, ...) drift to require newer
# core APIs over time (see learnings/contributing-upstream-to-duckdb-iceberg.md,
# "Stable-build tags need a pinned, verified base, not upstream's live tip" -
# confirmed the hard way 2026-08-05: a tag cut from a same-day upstream tip
# failed with `'Identifier' was not declared in this scope`, a 1.6-only core
# type, when downgrading just the duckdb submodule to v1.5.4). Pass whatever
# ref already builds clean against the target duckdb version - typically a
# previous stable-base tag, not upstream's tip. This intentionally does NOT
# fast-forward or push the upstream mirror - a stable base is meant to stay
# fixed until someone deliberately re-verifies compatibility and advances it,
# not silently drift forward on every cut.
#
# --from <prev-tag> seeds the patch list from a previous tag's own history
# (git log <prev-base>..<prev-tag>) instead of requiring every SHA to be
# retyped - any SHAs given after --from are appended on top. To drop a patch
# that's since been fixed upstream, just cut without --from and pass the
# remaining SHAs explicitly. Composes with --stable-base: --from a previous
# stable-base tag re-seeds its patch list, --stable-base then pins where the
# NEW cut is built from (pass the same ref the previous tag used, unless
# deliberately advancing it after re-verifying compatibility).
#
# A cherry-pick conflict is never auto-resolved - that stays a human decision.
# What --continue/--abort handle is the bookkeeping around it: git's own
# sequencer already remembers which SHAs are left in a multi-commit pick, so
# --continue only needs to recall the two things git doesn't track for us -
# the tag name (recomputing it fresh would give a different timestamp) and
# which branch to return to - both stashed in a small state file for exactly
# this purpose, removed once the cut actually finishes.
#
# A fresh cut (without --stable-base) also fast-forwards the fork's upstream
# branch from duckdb/duckdb-iceberg:main first - done here rather than in CI
# because this fork is public and the org's self-hosted runners don't grant
# public repos access.

GIT_DIR="$(git rev-parse --git-dir)"
STATE_FILE="$GIT_DIR/CUT_TAG_STATE"

finish_cut() {
  # Called once all cherry-picks are actually done (fresh run or after --continue).
  local tag="$1" base_sha="$2" starting_branch="$3" tmp_branch="$4"

  git tag -a "$tag" -m "Internal patch set, base ${base_sha}, cut $(date -u +%Y-%m-%dT%H:%M:%SZ)" HEAD

  if [[ -n "$starting_branch" ]]; then
    git checkout "$starting_branch"
  else
    git checkout -
  fi
  git branch -D "$tmp_branch"
  rm -f "$STATE_FILE"

  echo ""
  echo "Created tag: $tag"
  echo "Push with: git push taktile $tag"
}

if [[ "${1:-}" == "--continue" || "${1:-}" == "--abort" ]]; then
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  else
    # No state file - likely a tmp branch left over from a run predating this
    # script version, or one where the state file was otherwise lost. The tag
    # is still recoverable: it's encoded in the branch name itself
    # (tmp/cut-<tag>). STARTING_BRANCH isn't recoverable at all, so this
    # defaults to main and says so explicitly rather than silently guessing.
    CURRENT_BRANCH="$(git branch --show-current)"
    if [[ "$CURRENT_BRANCH" != tmp/cut-* ]]; then
      echo "Error: no in-progress cut-tag.sh run found ($STATE_FILE missing, and current branch '$CURRENT_BRANCH' doesn't look like a cut-tag.sh tmp branch)." >&2
      exit 1
    fi
    TMP_BRANCH="$CURRENT_BRANCH"
    TAG="${TMP_BRANCH#tmp/cut-}"
    BASE_SHA="${TAG##*-}"
    STARTING_BRANCH="main"
    echo "No state file found - recovered from branch name '$TMP_BRANCH':" >&2
    echo "  TAG=$TAG  BASE_SHA=$BASE_SHA" >&2
    echo "  STARTING_BRANCH defaulted to 'main' (not recoverable) - check this is actually right before pushing." >&2
  fi

  if [[ "$1" == "--abort" ]]; then
    git cherry-pick --abort 2>/dev/null || true
    if [[ -n "$STARTING_BRANCH" ]]; then
      git checkout "$STARTING_BRANCH"
    else
      git checkout -
    fi
    git branch -D "$TMP_BRANCH" --force
    rm -f "$STATE_FILE"
    echo "Aborted. Back on $STARTING_BRANCH, $TMP_BRANCH removed."
    exit 0
  fi

  # If there's no cherry-pick actually in progress (e.g. it was already
  # resolved and completed manually), there's nothing to --continue - skip
  # straight to finishing rather than erroring on "no cherry-pick in progress".
  if [[ -f "$GIT_DIR/CHERRY_PICK_HEAD" ]]; then
    if ! git cherry-pick --continue; then
      echo "Error: cherry-pick --continue failed - resolve remaining conflicts, git add them, then run --continue again." >&2
      exit 1
    fi
  else
    echo "No cherry-pick in progress (already resolved and completed) - finishing up." >&2
  fi

  # If more commits remain in the sequence, another conflict may follow;
  # cherry-pick --continue above already advances through clean ones on its own.
  if [[ -f "$GIT_DIR/CHERRY_PICK_HEAD" ]]; then
    echo "Still mid cherry-pick (another conflict) - resolve, git add, then run --continue again." >&2
    exit 1
  fi

  finish_cut "$TAG" "$BASE_SHA" "$STARTING_BRANCH" "$TMP_BRANCH"
  exit 0
fi

# --- Fresh cut ---
PREV_TAG=""
STABLE_BASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      PREV_TAG="${2:?--from requires a previous tag}"
      shift 2
      ;;
    --stable-base)
      STABLE_BASE="${2:?--stable-base requires a ref}"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

NEW_SHAS=("$@")

if [[ -z "$PREV_TAG" && ${#NEW_SHAS[@]} -eq 0 ]]; then
  echo "usage: cut-tag.sh [--from <prev-tag>] [--stable-base <ref>] <sha1> [<sha2> ...]" >&2
  echo "       cut-tag.sh --continue   (after resolving a cherry-pick conflict)" >&2
  echo "       cut-tag.sh --abort      (bail out of an in-progress cut)" >&2
  exit 1
fi

if [[ -f "$STATE_FILE" ]]; then
  echo "Error: a cut-tag.sh run is already in progress (see $STATE_FILE)." >&2
  echo "Resolve it first with --continue or --abort." >&2
  exit 1
fi

if [[ -n "$STABLE_BASE" ]]; then
  if ! git rev-parse --verify --quiet "$STABLE_BASE" >/dev/null; then
    echo "Error: '$STABLE_BASE' (--stable-base) is not a valid ref in this repo." >&2
    exit 1
  fi
  UPSTREAM_MIRROR="$STABLE_BASE"  # not actually upstream - see --stable-base usage note above
else
  UPSTREAM_MIRROR="taktile/upstream"  # the fork's mirror branch, tracking duckdb/duckdb-iceberg:main

  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0='url.git@github.com:.insteadOf' GIT_CONFIG_VALUE_0='https://github.com/' \
    git fetch upstream main --quiet
  git push taktile upstream/main:refs/heads/upstream
  git fetch taktile upstream --quiet
fi

SHAS=()
if [[ -n "$PREV_TAG" ]]; then
  if ! git rev-parse --verify --quiet "$PREV_TAG" >/dev/null; then
    echo "Error: '$PREV_TAG' is not a valid tag/ref in this repo." >&2
    exit 1
  fi

  PREV_BASE="${PREV_TAG##*-}"
  if ! git rev-parse --verify --quiet "$PREV_BASE" >/dev/null; then
    echo "Error: could not resolve base SHA '$PREV_BASE' parsed from '$PREV_TAG'." >&2
    exit 1
  fi

  while IFS= read -r line; do
    SHAS+=("$line")
  done < <(git log --reverse --format=%H "${PREV_BASE}..${PREV_TAG}")
  echo "==> Seeded ${#SHAS[@]} patch(es) from $PREV_TAG"
fi
if [[ ${#NEW_SHAS[@]} -gt 0 ]]; then
  SHAS+=("${NEW_SHAS[@]}")
fi

if [[ ${#SHAS[@]} -eq 0 ]]; then
  echo "Error: no patches to cherry-pick (empty history on '$PREV_TAG' and no SHAs given)." >&2
  exit 1
fi

BASE_SHA="$(git rev-parse --short "${UPSTREAM_MIRROR}^{commit}")"
TAG="$(date -u +%Y%m%dT%H%MZ)-${BASE_SHA}"

STARTING_BRANCH="$(git branch --show-current)"
TMP_BRANCH="tmp/cut-${TAG}"

echo "==> Base: $UPSTREAM_MIRROR @ $BASE_SHA"
echo "==> Tag: $TAG"
echo "==> Patches (${#SHAS[@]}): ${SHAS[*]}"

git checkout -b "$TMP_BRANCH" "$UPSTREAM_MIRROR"

# Save what --continue/--abort will need before attempting the cherry-pick,
# so a conflict has something to resume from.
cat > "$STATE_FILE" <<EOF
TAG="$TAG"
BASE_SHA="$BASE_SHA"
STARTING_BRANCH="$STARTING_BRANCH"
TMP_BRANCH="$TMP_BRANCH"
EOF

if ! git cherry-pick "${SHAS[@]}"; then
  echo "" >&2
  echo "Cherry-pick conflict. Resolve it (see the git status output above), then:" >&2
  echo "  git add <resolved files>" >&2
  echo "  ./cut-tag.sh --continue" >&2
  echo "or to bail out entirely:" >&2
  echo "  ./cut-tag.sh --abort" >&2
  exit 1
fi

finish_cut "$TAG" "$BASE_SHA" "$STARTING_BRANCH" "$TMP_BRANCH"
