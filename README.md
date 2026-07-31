# DuckDB-Iceberg fork for faster internal patches.

Read [this ADR](https://app.notion.com/p/taktile/ADR-Forking-duckdb-iceberg-for-Faster-Internal-Patches-3ad0a226e5be80e68350f7557ff976a1?v=2870a226e5be802d868c000c4942e97e&source=copy_link) first.

**Do not build against this branch.**

## Tooling

`cut-tag.sh` lives on this branch (`main`), but you'll often need to run it while checked out somewhere else entirely - mid cherry-pick conflict included. `git show` reads a file from any branch's history without touching what's actually checked out, so that's how it's invoked, from anywhere in this checkout, on any branch, any state:

```
git show main:cut-tag.sh | bash -s -- [--from <prev-tag>] <sha1> [<sha2> ...]
git show main:cut-tag.sh | bash -s -- --continue
git show main:cut-tag.sh | bash -s -- --abort
```

No setup step, no PATH changes, nothing outside this one repo - works for anyone who's cloned it.

## Branch Layout

- **`main`** (this branch) - documentation and tooling only. Nothing here gets built or deployed.
- **`upstream`** - a plain mirror of [`duckdb/duckdb-iceberg:main`](https://github.com/duckdb/duckdb-iceberg/tree/main), kept in sync automatically by [`.github/workflows/sync-upstream.yml`](.github/workflows/sync-upstream.yml). Always a fast-forward, since it never carries commits of its own - no force-push, no conflicts, ever. `fix/<name>` branches and tags are both cut from here.
- **`fix/<name>` branches** - one per patch, branched fresh off `upstream`, used only to open the upstream PR. Deleted once the PR merges or is abandoned.
- **Tags** - `yyyymmddThhmmZ-<short-sha>`, where `<short-sha>` is the `upstream` commit the tag was cut from. Immutable once pushed. There is no persistent "patch stack" branch - each tag is a fresh checkout of `upstream` at cut time with the currently-active patches cherry-picked on. The tag's own git history *is* the record of what's applied; nothing else needs to track it.

## Common tasks

### Adding a patch

1. Branch off `upstream` (`fix/<name>`), commit the fix.
2. Push, open the PR against `duckdb/duckdb-iceberg`, targeting `main`.
3. Include the commit in the next tag cut (see below) so it's part of the deployable artifact.

### Cutting a tag

```
git show main:cut-tag.sh | bash -s -- [--from <prev-tag>] <sha1> [<sha2> ...]
```

Checks out `upstream`'s current tip, cherry-picks the given commits in order, tags the result `yyyymmddThhmmZ-<base-sha>`. This is the release step - no separate "bump a version" action, the tag itself is the release. `--from <prev-tag>` seeds the patch list from that tag's own history instead of retyping every SHA.

Conceptually, this is exactly:

```
git fetch upstream main
git checkout upstream/main
git cherry-pick <sha1> <sha2>
git tag -a <tag> -m "release" HEAD
```

If a cherry-pick conflicts, resolve it by hand, `git add` the resolved files, then:

```
git show main:cut-tag.sh | bash -s -- --continue
```

which finishes the remaining steps (any further SHAs in the list, tagging, cleanup) once the conflict itself is actually resolved. To bail out entirely instead:

```
git show main:cut-tag.sh | bash -s -- --abort
```

### Checking if a patch is subsumed by upstream

No tooling for this - it's faster to just check by hand: `gh pr view <PR> --repo duckdb/duckdb-iceberg` for status, or try rebasing the patch's commit onto current `upstream/main` yourself if you want to see whether it's become redundant. An automated check here degrades badly with time anyway (upstream drifts, so old patches mostly come back as unresolvable conflicts rather than a clean answer) - not worth the complexity for something this quick to check manually.

### Retiring a patch

There's no "retire" step on an existing tag - tags are immutable once cut. A patch that's been fixed upstream just doesn't get included the next time a tag is cut.
