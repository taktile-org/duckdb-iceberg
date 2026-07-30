# DuckDB-Iceberg fork for faster internal patches.

Read [this ADR](https://app.notion.com/p/taktile/ADR-Forking-duckdb-iceberg-for-Faster-Internal-Patches-3ad0a226e5be80e68350f7557ff976a1?v=2870a226e5be802d868c000c4942e97e&source=copy_link) first.

**Do not build against this branch.**

## Branch Layout

- **`main`** (this branch) - documentation and tooling only. Nothing here gets built or deployed.
- **`internal/v<upstream-base>-tktl.<N>`** - one immutable branch per patch add or retire. Each is release-branch-era code matching whatever DUCKDB_VERSION `tktl-duckdb` currently pins, plus every patch active at that point, cherry-picked on. Never rewritten once created - adding or retiring a patch creates a *new* branch (`N+1`) rather than mutating an existing one. This is what "Cross-linking" builds from. `PATCHES.tsv` lives at the root of each of these branches, reflecting exactly the patches active in that specific branch.
- **`internal/v<upstream-base>-tktl.0`** - reserved on every version line for the frozen base with zero patches. Created once, never touched again. `check-patches.sh` derives the stable base to check against by computing this ref's name directly from whatever branch you point it at - so it must exist for every base line or that check is silently skipped (loudly, with a warning, not silently).
- **`fix/<name>` branches** - one per patch, branched fresh off [`duckdb/duckdb-iceberg:main`](https://github.com/duckdb/duckdb-iceberg/tree/main), used only to open the upstream PR. Deleted once the PR merges or is abandoned.

## Common tasks

### Adding a patch

1. Fetch `duckdb/duckdb-iceberg` and branch off `main`.
2. Commit the patch on that branch (`fix/<name>`).
3. Branch `internal/v<base>-tktl.<N+1>` off the current latest `internal/v<base>-tktl.<N>`.
4. Cherry-pick the commit onto the new branch and add its row to that branch's `PATCHES.tsv`.
5. Push both branches to this repo.
6. Open the PR against `duckdb/duckdb-iceberg`, targeting `main`.

### Check if a patch is subsumed by upstream

Run `check-patches.sh <branch>` on this branch on demand, pointed at whichever `internal/v<base>-tktl.<N>` branch you want checked.

### Retire a patch

1. Branch `internal/v<base>-tktl.<N+1>` off the current latest `internal/v<base>-tktl.<N>`.
2. Revert the patch's commit on the new branch.
3. Remove its row from the new branch's `PATCHES.tsv`.
4. Push.

## PATCHES.tsv

`PATCHES.tsv` lives on every `internal/v<base>-tktl.<N>` branch and lists exactly the patches active in that branch - not a running history, a snapshot. A patch's absence from a later branch's file means it was retired between the two. Tab-separated so it's trivial to `sed`/`awk`/`cut` and doesn't need manual column-alignment upkeep. First line is a header, one patch per row after that:

```
Commit	Issue	PR	Date
```

- Commit (SHA from `fix/*`)
- Upstream Issue ID
- Upstream PR ID (or NAN, if there is none)
- Date added (YYYY/MM/DD)
