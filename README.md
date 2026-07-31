# DuckDB-Iceberg fork for faster internal patches.

Read [this ADR](https://app.notion.com/p/taktile/ADR-Forking-duckdb-iceberg-for-Faster-Internal-Patches-3ad0a226e5be80e68350f7557ff976a1?v=2870a226e5be802d868c000c4942e97e&source=copy_link) first.

**Do not build against this branch.**

## Branch Layout

- **`main`** (this branch) - documentation and tooling only. Nothing here gets built or deployed.
- **`upstream`** - a plain mirror of [`duckdb/duckdb-iceberg:main`](https://github.com/duckdb/duckdb-iceberg/tree/main), kept in sync automatically by [`.github/workflows/sync-upstream.yml`](.github/workflows/sync-upstream.yml). Always a fast-forward, since it never carries commits of its own - no force-push, no conflicts, ever. `fix/<name>` branches and tags are both cut from here.
- **`fix/<name>` branches** - one per patch, branched fresh off `upstream`, used only to open the upstream PR. Deleted once the PR merges or is abandoned.
- **Tags** - `yyyymmddThhmmZ-<short-sha>`, where `<short-sha>` is the `upstream` commit the tag was cut from. Immutable once pushed. There is no persistent "patch stack" branch - each tag is a fresh checkout of `upstream` at cut time with the currently-active patches cherry-picked on. The tag's own git history *is* the record of what's applied; nothing else needs to track it.

## Common tasks

### Adding a patch

1. Branch off `upstream` (`fix/<name>`), commit the fix.
2. Push, open the PR against `duckdb/duckdb-iceberg`, targeting `main`.
3. Include the commit in the next `cut-tag.sh` run (see below) so it's part of the deployable artifact.

### Cutting a tag

```
./cut-tag.sh [--from <prev-tag>] <sha1> [<sha2> ...]
```

Checks out `upstream`'s current tip, cherry-picks the given commits in order, tags the result `yyyymmddThhmmZ-<base-sha>`. This is the release step - no separate "bump a version" action, the tag itself is the release. `--from <prev-tag>` seeds the patch list from that tag's own history instead of retyping every SHA.

```
git fetch upstream main
git checkout upstream/main
git cherry-pick <sha1> <sha2>
git tag -a <tag> -m "release" HEAD
```

### Check if a patch is subsumed by upstream

```
./check-patches.sh <tag>
```

Parses the base SHA out of the tag name, walks every commit between that base and the tag, and checks each one against the current `upstream/main` tip. No file to keep in sync - the tag's history is the input.

### Retiring a patch

There's no "retire" step on an existing tag - tags are immutable once cut. A patch that's been fixed upstream just doesn't get included the next time `cut-tag.sh` runs.
