#!/usr/bin/env bash
set -euo pipefail

# Usage: check-patches.sh <internal/v<base>-tktl.N branch>
TARGET_BRANCH="${1:?usage: check-patches.sh <internal/v<base>-tktl.N branch>}"

UPSTREAM_REMOTE="upstream"                  # must point at https://github.com/duckdb/duckdb-iceberg
PATCHES_TSV="PATCHES.tsv"
NEXT_RELEASE_BASE="${NEXT_RELEASE_BASE:-}"  # optional, set as an env var when a next-release candidate exists

if ! git rev-parse --verify --quiet "$TARGET_BRANCH" >/dev/null; then
  echo "Error: '$TARGET_BRANCH' is not a valid branch/ref in this repo." >&2
  echo "(if it's a fork branch you haven't fetched yet, try 'git fetch taktile' first)" >&2
  exit 1
fi

SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

echo "==> Fetching $UPSTREAM_REMOTE (duckdb/duckdb-iceberg)..."
git fetch "$UPSTREAM_REMOTE" --quiet

# --- Resolve bases to check against ---
# Stable base is derived by convention, not read from a file: every version
# line reserves "-tktl.0" for the frozen base with zero patches, never touched
# once created, so we can just compute the sibling ref from the branch name.
STABLE_BASE_REF="${TARGET_BRANCH%-tktl.*}-tktl.0"
BASES=("$UPSTREAM_REMOTE/main")
if git rev-parse --verify --quiet "$STABLE_BASE_REF" >/dev/null; then
  BASES+=("$STABLE_BASE_REF")
else
  echo "WARNING: derived stable base '$STABLE_BASE_REF' does not exist — only checking against $UPSTREAM_REMOTE/main." >&2
  STABLE_BASE_REF=""
fi
[[ -n "$NEXT_RELEASE_BASE" ]] && BASES+=("$NEXT_RELEASE_BASE")
echo "==> Checking $TARGET_BRANCH against bases: ${BASES[*]}"

# --- Load patch rows from PATCHES.tsv on the target branch ---
# Every row present = currently active on this branch (retirement = row removed
# from a later branch's file, not a status flag).
# Schema (tab-separated): Commit \t Issue \t PR \t Date
ROWS=()
while IFS= read -r line; do
  ROWS+=("$line")
done < <(git show "$TARGET_BRANCH:$PATCHES_TSV" | tail -n +2)

if [[ ${#ROWS[@]} -eq 0 ]]; then
  echo "No rows in $PATCHES_TSV on $TARGET_BRANCH."
  exit 0
fi

# check_one <commit> <base> -> prints EMPTY / NOT-EMPTY / CONFLICT
check_one() {
  local commit="$1" base="$2" worktree
  worktree="$SCRATCH_DIR/$(echo "${commit}_${base}" | tr '/:' '__')"
  git worktree add --quiet --detach "$worktree" "$commit" >/dev/null 2>&1

  (
    cd "$worktree"
    if git rebase --empty=drop --onto "$base" "${commit}^" "$commit" >/dev/null 2>&1; then
      if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$base")" ]]; then
        echo "EMPTY"
      else
        echo "NOT-EMPTY"
      fi
    else
      git rebase --abort >/dev/null 2>&1 || true
      echo "CONFLICT"
    fi
  )

  git worktree remove --force "$worktree" >/dev/null 2>&1 || true
}

for row in "${ROWS[@]}"; do
  IFS=$'\t' read -ra COLS <<< "$row"
  SHA="${COLS[0]:-}"
  ISSUE="${COLS[1]:-}"
  PR="${COLS[2]:-}"

  [[ -z "$SHA" ]] && continue

  echo ""
  echo "=== $SHA (issue $ISSUE, PR ${PR:-none}) ==="

  empty_main="no"
  empty_stable="no"

  for base in "${BASES[@]}"; do
    result="$(check_one "$SHA" "$base")"
    echo "  [$base] $result"
    [[ "$base" == "$UPSTREAM_REMOTE/main" && "$result" == "EMPTY" ]] && empty_main="yes"
    [[ "$base" == "$STABLE_BASE_REF" && "$result" == "EMPTY" ]] && empty_stable="yes"
  done

  if [[ "$empty_main" == "yes" && "$empty_stable" == "yes" ]]; then
    echo "  >>> FLAG: empty against BOTH main and stable base — ready to retire"
  elif [[ "$empty_main" == "yes" ]]; then
    echo "  >>> informational: fixed upstream in principle, not yet on our stable base"
  fi

  if [[ -n "$PR" && "$PR" != "NAN" ]]; then
    pr_state="$(gh pr view "$PR" --repo duckdb/duckdb-iceberg --json state --jq .state 2>/dev/null || echo "UNKNOWN")"
    echo "  PR #$PR: $pr_state"
    [[ "$pr_state" == "MERGED" ]] && echo "  >>> FLAG: PR merged — verify equivalence before retiring"
  fi
done
