#!/usr/bin/env bash
set -euo pipefail

# Usage: cut-tag.sh [--from <prev-tag>] <sha1> [<sha2> ...]
#        cut-tag.sh --continue
#        cut-tag.sh --abort
#
# Cuts a new internal tag: fresh checkout of the upstream mirror's current tip,
# cherry-pick the given commits (in order), tag the result. Tag name is
# yyyymmddThhmmZ-<short-sha-of-base>, so check-patches.sh can derive the base
# straight from the tag name later - no separate file needed.
#
# --from <prev-tag> seeds the patch list from a previous tag's own history
# (git log <prev-base>..<prev-tag>) instead of requiring every SHA to be
# retyped - any SHAs given after --from are appended on top. To drop a patch
# that's since been fixed upstream, just cut without --from and pass the
# remaining SHAs explicitly.
#
# A cherry-pick conflict is never auto-resolved - that stays a human decision.
# What --continue/--abort handle is the bookkeeping around it: git's own
# sequencer already remembers which SHAs are left in a multi-commit pick, so
# --continue only needs to recall the two things git doesn't track for us -
# the tag name (recomputing it fresh would give a different timestamp) and
# which branch to return to - both stashed in a small state file for exactly
# this purpose, removed once the cut actually finishes.

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
if [[ "${1:-}" == "--from" ]]; then
  PREV_TAG="${2:?--from requires a previous tag}"
  shift 2
fi

NEW_SHAS=("$@")

if [[ -z "$PREV_TAG" && ${#NEW_SHAS[@]} -eq 0 ]]; then
  echo "usage: cut-tag.sh [--from <prev-tag>] <sha1> [<sha2> ...]" >&2
  echo "       cut-tag.sh --continue   (after resolving a cherry-pick conflict)" >&2
  echo "       cut-tag.sh --abort      (bail out of an in-progress cut)" >&2
  exit 1
fi

if [[ -f "$STATE_FILE" ]]; then
  echo "Error: a cut-tag.sh run is already in progress (see $STATE_FILE)." >&2
  echo "Resolve it first with --continue or --abort." >&2
  exit 1
fi

UPSTREAM_MIRROR="taktile/upstream"  # the fork's auto-synced mirror of duckdb/duckdb-iceberg:main

git fetch taktile upstream --quiet

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
SHAS+=("${NEW_SHAS[@]}")

if [[ ${#SHAS[@]} -eq 0 ]]; then
  echo "Error: no patches to cherry-pick (empty history on '$PREV_TAG' and no SHAs given)." >&2
  exit 1
fi

BASE_SHA="$(git rev-parse --short "$UPSTREAM_MIRROR")"
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
