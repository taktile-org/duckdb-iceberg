#!/usr/bin/env bash
set -euo pipefail

# Usage: check-patches.sh <tag>
# Tag format: yyyymmddThhmmZ-<short-sha>, where <short-sha> is the upstream
# commit the tag was cut from (see cut-tag.sh). No external file needed - the
# tag name gives us the base, and the tag's own history gives us the patches.
TAG="${1:?usage: check-patches.sh <tag>}"

UPSTREAM_REMOTE="upstream"  # must point at https://github.com/duckdb/duckdb-iceberg

if ! git rev-parse --verify --quiet "$TAG" >/dev/null; then
  echo "Error: '$TAG' is not a valid tag/ref in this repo." >&2
  echo "(if it's on the fork and you haven't fetched it yet, try 'git fetch taktile --tags' first)" >&2
  exit 1
fi

BASE_SHA="${TAG##*-}"
if ! git rev-parse --verify --quiet "$BASE_SHA" >/dev/null; then
  echo "Error: could not resolve base SHA '$BASE_SHA' parsed from tag '$TAG'." >&2
  echo "(the object may not be fetched locally - try 'git fetch $UPSTREAM_REMOTE' first)" >&2
  exit 1
fi

SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

echo "==> Fetching $UPSTREAM_REMOTE (duckdb/duckdb-iceberg)..."
git fetch "$UPSTREAM_REMOTE" --quiet

echo "==> Tag $TAG, base $BASE_SHA, checking each patch against $UPSTREAM_REMOTE/main"

# --- Enumerate patches directly from the tag's own history ---
COMMITS=()
while IFS= read -r line; do
  COMMITS+=("$line")
done < <(git log --reverse --format=%H "${BASE_SHA}..${TAG}")

if [[ ${#COMMITS[@]} -eq 0 ]]; then
  echo "No patches between $BASE_SHA and $TAG - nothing to check."
  exit 0
fi

# check_one <commit> -> prints EMPTY / NOT-EMPTY / CONFLICT against upstream/main
check_one() {
  local commit="$1" worktree
  worktree="$SCRATCH_DIR/${commit}"
  git worktree add --quiet --detach "$worktree" "$commit" >/dev/null 2>&1

  (
    cd "$worktree"
    if git rebase --empty=drop --onto "$UPSTREAM_REMOTE/main" "${commit}^" "$commit" >/dev/null 2>&1; then
      if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$UPSTREAM_REMOTE/main")" ]]; then
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

for commit in "${COMMITS[@]}"; do
  short="$(git rev-parse --short "$commit")"
  subject="$(git log -1 --format=%s "$commit")"

  echo ""
  echo "=== $short: $subject ==="

  result="$(check_one "$commit")"
  echo "  [$UPSTREAM_REMOTE/main] $result"

  if [[ "$result" == "EMPTY" ]]; then
    echo "  >>> FLAG: fixed upstream — safe to drop from the next tag"
  fi
done
