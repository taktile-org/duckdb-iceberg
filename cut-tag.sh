#!/usr/bin/env bash
set -euo pipefail

# Usage: cut-tag.sh [--from <prev-tag>] <sha1> [<sha2> ...]
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

PREV_TAG=""
if [[ "${1:-}" == "--from" ]]; then
  PREV_TAG="${2:?--from requires a previous tag}"
  shift 2
fi

NEW_SHAS=("$@")

if [[ -z "$PREV_TAG" && ${#NEW_SHAS[@]} -eq 0 ]]; then
  echo "usage: cut-tag.sh [--from <prev-tag>] <sha1> [<sha2> ...]" >&2
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
git cherry-pick "${SHAS[@]}"
git tag -a "$TAG" -m "Internal patch set, base ${BASE_SHA}, cut $(date -u +%Y-%m-%dT%H:%M:%SZ)" HEAD

if [[ -n "$STARTING_BRANCH" ]]; then
  git checkout "$STARTING_BRANCH"
else
  git checkout -
fi
git branch -D "$TMP_BRANCH"

echo ""
echo "Created tag: $TAG"
echo "Push with: git push taktile $TAG"
