"""Fixtures for test/sql/local/iceberg_scans/scan_order_dynamic_filter*.test.

Run from the repository root (table locations are stored relative to it):

    python scripts/topk_scan_order/generate.py [name ...]

Needs pyiceberg[pyiceberg-core,sql-sqlite] and pyarrow. With no names, every fixture is (re)written. Each table is
small; most hold 8 rows per partition, 3h apart, with `env` alternating 'live'/'sandbox' so that no bound prunes on
`env` and only the TOP_N dynamic filter on the order column can skip manifests and files.
"""

from __future__ import annotations

import datetime as dt
import io
import json
import random
import shutil
import sys
import tempfile
import uuid
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.manifest import (
    DataFile,
    DataFileContent,
    ManifestContent,
    ManifestEntry,
    ManifestEntryStatus,
    ManifestWriterV2,
    write_manifest_list,
)
from pyiceberg.partitioning import PartitionField, PartitionSpec
from pyiceberg.schema import Schema
from pyiceberg.transforms import DayTransform, HourTransform, IdentityTransform, MonthTransform
from pyiceberg.typedef import Record
from pyiceberg.types import DateType, IntegerType, NestedField, StringType, StructType, TimestampType

ROOT = Path("data/persistent")
BASE = dt.datetime(2025, 1, 1)
ID, TS, ENV = (
    NestedField(1, "id", IntegerType()),
    NestedField(2, "ts", TimestampType()),
    NestedField(3, "env", StringType()),
)
SCHEMA = Schema(ID, TS, ENV)
ARROW = pa.schema([pa.field("id", pa.int32()), pa.field("ts", pa.timestamp("us")), pa.field("env", pa.string())])


def _catalog(tmp: str) -> SqlCatalog:
    cat = SqlCatalog("gen", uri=f"sqlite:///{tmp}/catalog.db", warehouse=str(ROOT))
    cat.create_namespace("default")
    return cat


def _table(cat, name, schema=SCHEMA, spec=PartitionSpec()):
    location = ROOT / name
    shutil.rmtree(location, ignore_errors=True)
    return cat.create_table(
        f"default.{name}",
        schema=schema,
        partition_spec=spec,
        location=str(location),
        properties={"format-version": "2"},
    )


def _day_spec(transform=DayTransform(), source_id=2, name="ts_day"):
    return PartitionSpec(PartitionField(source_id=source_id, field_id=1000, transform=transform, name=name))


def _rows(first_id, start, step, n):
    return [dict(id=first_id + s, ts=start + step * s, env="live" if s % 2 == 0 else "sandbox") for s in range(n)]


def _append(tbl, rows, schema=ARROW):
    tbl.append(pa.Table.from_pylist(rows, schema=schema))


def ties(cat, name, swap):
    """Two commits on day 5 whose rows share ts = 2025-01-06 12:00 (ids 10-12 and 1-3); one commit on day 6 with two
    live rows; one on day 4. ORDER BY ts DESC, id LIMIT 4 = both day-6 rows + ids 1 and 2 from the tie. `swap` flips
    the commit order of the two tie manifests, so whichever one is read second holds the winning ids once."""
    tbl = _table(cat, name, spec=_day_spec())
    tie = BASE + dt.timedelta(days=5, hours=12)
    a = [dict(id=i, ts=tie, env="live") for i in (10, 11, 12)]
    b = [dict(id=i, ts=tie, env="live") for i in (1, 2, 3)]
    commits = [
        _rows(40, BASE + dt.timedelta(days=4), dt.timedelta(hours=3), 8),
        *((b, a) if swap else (a, b)),
        [
            dict(id=60, ts=BASE + dt.timedelta(days=6, hours=1), env="live"),
            dict(id=61, ts=BASE + dt.timedelta(days=6, hours=2), env="live"),
        ],
    ]
    for rows in commits:
        _append(tbl, rows)


def nulls(cat, name):
    """Six day commits in shuffled order. Day 3's commit also carries two NULL-ts rows (so its manifest summary has
    contains_null plus real bounds); one extra commit holds only NULL-ts rows (NULL partition, no bounds)."""
    tbl = _table(cat, name, spec=_day_spec())
    days = [3, 0, 5, 1, 4, 2]
    for d in days:
        rows = _rows(d * 8, BASE + dt.timedelta(days=d), dt.timedelta(hours=3), 8)
        if d == 3:
            rows += [dict(id=100, ts=None, env="live"), dict(id=101, ts=None, env="sandbox")]
        _append(tbl, rows)
        if d == 5:
            _append(tbl, [dict(id=200 + i, ts=None, env="live" if i % 2 == 0 else "sandbox") for i in range(4)])


def hour(cat, name):
    """8 hour-partitioned commits (one hour each, 8 rows 5 min apart) in shuffled order."""
    tbl = _table(cat, name, spec=_day_spec(HourTransform(), name="ts_hour"))
    order = list(range(8))
    random.Random(5).shuffle(order)
    for h in order:
        _append(tbl, _rows(h * 8, BASE + dt.timedelta(hours=h), dt.timedelta(minutes=5), 8))


def month(cat, name):
    """6 month-partitioned commits (8 rows 3 days apart within the month) in shuffled order."""
    tbl = _table(cat, name, spec=_day_spec(MonthTransform(), name="ts_month"))
    order = list(range(6))
    random.Random(6).shuffle(order)
    for m in order:
        _append(tbl, _rows(m * 8, dt.datetime(2025, m + 1, 1), dt.timedelta(days=3), 8))


def date_identity(cat, name):
    """DATE column `d`, identity-partitioned; 8 day commits in shuffled order, 8 rows each (same d, env alternating)."""
    schema = Schema(ID, NestedField(2, "d", DateType()), ENV)
    arrow = pa.schema([pa.field("id", pa.int32()), pa.field("d", pa.date32()), pa.field("env", pa.string())])
    tbl = _table(cat, name, schema=schema, spec=_day_spec(IdentityTransform(), name="d"))
    order = list(range(8))
    random.Random(7).shuffle(order)
    for day in order:
        rows = [
            dict(
                id=day * 8 + s, d=dt.date(2025, 1, 1) + dt.timedelta(days=day), env="live" if s % 2 == 0 else "sandbox"
            )
            for s in range(8)
        ]
        _append(tbl, rows, schema=arrow)


def evolved(cat, name):
    """Spec evolution hour(ts) -> day(ts): 4 hour-partitioned commits on days 0-3, then 4 day-partitioned commits on
    days 4-7, both halves in shuffled order. Manifests of the two specs carry summaries of different transforms."""
    tbl = _table(cat, name, spec=_day_spec(HourTransform(), name="ts_hour"))
    for d in (2, 0, 3, 1):
        _append(tbl, _rows(d * 8, BASE + dt.timedelta(days=d, hours=1), dt.timedelta(minutes=5), 8))
    with tbl.update_spec() as update:
        update.remove_field("ts_hour")
        update.add_field("ts", DayTransform(), "ts_day")
    tbl.refresh()
    for d in (6, 4, 7, 5):
        _append(tbl, _rows(d * 8, BASE + dt.timedelta(days=d), dt.timedelta(hours=3), 8))


def unpartitioned(cat, name):
    """5 commits on an unpartitioned table: manifests carry no partition summaries."""
    tbl = _table(cat, name)
    for d in (3, 0, 4, 1, 2):
        _append(tbl, _rows(d * 8, BASE + dt.timedelta(days=d), dt.timedelta(hours=3), 8))


def varchar_identity(cat, name):
    """VARCHAR order column `s`, identity-partitioned, 8 commits in shuffled order. Values share a 20-character prefix,
    longer than the 16 characters pyiceberg keeps in file bounds, so file bounds are truncated."""
    schema = Schema(ID, NestedField(2, "s", StringType()), ENV)
    arrow = pa.schema([pa.field("id", pa.int32()), pa.field("s", pa.string()), pa.field("env", pa.string())])
    tbl = _table(cat, name, schema=schema, spec=_day_spec(IdentityTransform(), name="s"))
    order = list(range(8))
    random.Random(8).shuffle(order)
    for k in order:
        rows = [
            dict(id=k * 8 + i, s=f"shared-prefix-012345-{k:02d}", env="live" if i % 2 == 0 else "sandbox")
            for i in range(8)
        ]
        _append(tbl, rows, schema=arrow)


def struct(cat, name):
    """Order column inside a struct: st.t (plus a top-level ts); day(ts)-partitioned, 6 shuffled commits."""
    schema = Schema(ID, TS, ENV, NestedField(4, "st", StructType(NestedField(5, "t", TimestampType()))))
    arrow = pa.schema([*ARROW, pa.field("st", pa.struct([pa.field("t", pa.timestamp("us"))]))])
    tbl = _table(cat, name, schema=schema, spec=_day_spec())
    for d in (2, 5, 0, 3, 1, 4):
        rows = _rows(d * 8, BASE + dt.timedelta(days=d), dt.timedelta(hours=3), 8)
        for r in rows:
            r["st"] = {"t": r["ts"]}
        _append(tbl, rows, schema=arrow)


class _DeleteManifestWriterV2(ManifestWriterV2):
    """pyiceberg only writes content=DATA manifests; flip it to DELETES."""

    def content(self) -> ManifestContent:  # type: ignore[override]
        return ManifestContent.DELETES

    @property
    def _meta(self) -> dict[str, str]:  # type: ignore[override]
        return {**super()._meta, "content": "deletes"}


def _commit_delete_file(tbl, content, arrow_table, partition, equality_ids=None):
    """Write one delete file, a delete manifest holding it and a new snapshot/metadata.json (pyiceberg's own deletes
    are copy-on-write only)."""
    tbl.refresh()
    base = tbl.current_snapshot()
    location = tbl.location().rstrip("/")
    buf = io.BytesIO()
    pq.write_table(arrow_table, buf)
    path = f"{location}/data/delete-{uuid.uuid4()}.parquet"
    with tbl.io.new_output(path).create() as f:
        f.write(buf.getvalue())
    delete_file = DataFile.from_args(
        content=content,
        file_path=path,
        file_format="PARQUET",
        partition=partition,
        record_count=len(arrow_table),
        file_size_in_bytes=len(buf.getvalue()),
        spec_id=tbl.spec().spec_id,
        sort_order_id=None,
        equality_ids=equality_ids,
    )
    snapshot_id = base.snapshot_id + 1
    seq = base.sequence_number + 1
    manifest_path = f"{location}/metadata/{uuid.uuid4()}-m0.avro"
    with _DeleteManifestWriterV2(
        spec=tbl.spec(),
        schema=tbl.schema(),
        output_file=tbl.io.new_output(manifest_path),
        snapshot_id=snapshot_id,
        avro_compression="gzip",
    ) as w:
        w.add(
            ManifestEntry.from_args(
                status=ManifestEntryStatus.ADDED,
                snapshot_id=snapshot_id,
                sequence_number=seq,
                file_sequence_number=seq,
                data_file=delete_file,
            )
        )
    list_path = f"{location}/metadata/snap-{snapshot_id}-1-{uuid.uuid4()}.avro"
    with write_manifest_list(
        format_version=2,
        output_file=tbl.io.new_output(list_path),
        snapshot_id=snapshot_id,
        parent_snapshot_id=base.snapshot_id,
        sequence_number=seq,
        avro_compression="gzip",
    ) as mlw:
        mlw.add_manifests([*base.manifests(io=tbl.io), w.to_manifest_file()])
    with tbl.io.new_input(tbl.metadata_location).open() as f:
        md = json.loads(f.read())
    ts_ms = base.timestamp_ms + 1000
    md["snapshots"].append(
        {
            "sequence-number": seq,
            "snapshot-id": snapshot_id,
            "parent-snapshot-id": base.snapshot_id,
            "timestamp-ms": ts_ms,
            "summary": {"operation": "delete"},
            "manifest-list": list_path,
            "schema-id": tbl.schema().schema_id,
        }
    )
    md.update({"current-snapshot-id": snapshot_id, "last-sequence-number": seq, "last-updated-ms": ts_ms})
    md["snapshot-log"].append({"timestamp-ms": ts_ms, "snapshot-id": snapshot_id})
    md["refs"] = {"main": {"snapshot-id": snapshot_id, "type": "branch"}}
    with tbl.io.new_output(f"{location}/metadata/v-final.metadata.json").create() as f:
        f.write(json.dumps(md, indent=2).encode())


def _newest_day_file(tbl, day):
    for manifest in tbl.current_snapshot().manifests(io=tbl.io):
        for entry in manifest.fetch_manifest_entry(io=tbl.io):
            if entry.data_file.partition[0] == (BASE + dt.timedelta(days=day) - dt.datetime(1970, 1, 1)).days:
                return entry.data_file
    raise AssertionError(day)


def pos_delete(cat, name):
    """6 shuffled day commits, then a positional delete of the two newest live rows (ids 46 and 44, day 5)."""
    tbl = _table(cat, name, spec=_day_spec())
    for d in (1, 5, 0, 3, 2, 4):
        _append(tbl, _rows(d * 8, BASE + dt.timedelta(days=d), dt.timedelta(hours=3), 8))
    tbl.refresh()
    data_file = _newest_day_file(tbl, 5)
    with tbl.io.new_input(data_file.file_path).open() as f:
        ids = pq.read_table(f).column("id").to_pylist()
    schema = pa.schema(
        [
            pa.field("file_path", pa.string(), nullable=False, metadata={b"PARQUET:field_id": b"2147483546"}),
            pa.field("pos", pa.int64(), nullable=False, metadata={b"PARQUET:field_id": b"2147483545"}),
        ]
    )
    rows = sorted([dict(file_path=data_file.file_path, pos=ids.index(i)) for i in (44, 46)], key=lambda r: r["pos"])
    _commit_delete_file(
        tbl, DataFileContent.POSITION_DELETES, pa.Table.from_pylist(rows, schema=schema), data_file.partition
    )


def eq_delete(cat, name):
    """6 shuffled day commits, then an equality delete on id in (46, 44) scoped to day 5's partition."""
    tbl = _table(cat, name, spec=_day_spec())
    for d in (1, 5, 0, 3, 2, 4):
        _append(tbl, _rows(d * 8, BASE + dt.timedelta(days=d), dt.timedelta(hours=3), 8))
    tbl.refresh()
    data_file = _newest_day_file(tbl, 5)
    schema = pa.schema([pa.field("id", pa.int32(), nullable=False, metadata={b"PARQUET:field_id": b"1"})])
    _commit_delete_file(
        tbl,
        DataFileContent.EQUALITY_DELETES,
        pa.Table.from_pylist([dict(id=44), dict(id=46)], schema=schema),
        data_file.partition,
        equality_ids=[1],
    )


FIXTURES = {
    "ties_a": lambda c, n: ties(c, n, swap=False),
    "ties_b": lambda c, n: ties(c, n, swap=True),
    "nulls": nulls,
    "hour": hour,
    "month": month,
    "date_identity": date_identity,
    "evolved": evolved,
    "unpartitioned": unpartitioned,
    "varchar_identity": varchar_identity,
    "struct": struct,
    "pos_delete": pos_delete,
    "eq_delete": eq_delete,
}

if __name__ == "__main__":
    names = sys.argv[1:] or list(FIXTURES)
    with tempfile.TemporaryDirectory() as tmp:
        cat = _catalog(tmp)
        for n in names:
            FIXTURES[n](cat, f"topk_scan_order/{n}")
            print("wrote", ROOT / "topk_scan_order" / n)
