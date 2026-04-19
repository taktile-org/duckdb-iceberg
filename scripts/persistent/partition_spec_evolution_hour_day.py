"""Regression fixture for https://github.com/duckdb/duckdb-iceberg/issues/941

A table whose partition spec evolved from hour(ts) to day(ts). The day-transform
manifest encodes partition values as Avro int + logicalType=date, which surfaced
as DuckDB's DATE type and crashed the scan with
"Unimplemented type for cast (DATE -> INTEGER)" before the
FixSamePhysicalTypeCasts rewriter landed in iceberg_avro_multi_file_reader.cpp.
"""
import datetime as dt
import os
import shutil

import pyarrow as pa
from pyiceberg.catalog.sql import SqlCatalog
from pyiceberg.partitioning import PartitionField, PartitionSpec
from pyiceberg.schema import Schema
from pyiceberg.transforms import DayTransform, HourTransform
from pyiceberg.types import LongType, NestedField, TimestampType

warehouse_path = "data/persistent/partition_spec_evolution_hour_day"

if os.path.exists(warehouse_path):
    shutil.rmtree(warehouse_path)
os.makedirs(warehouse_path)

catalog = SqlCatalog(
    "default",
    uri=f"sqlite:///{warehouse_path}/pyiceberg_catalog.db",
    warehouse=warehouse_path,
)
catalog.create_namespace("default")

schema = Schema(
    NestedField(1, "id", LongType(), required=False),
    NestedField(2, "ts", TimestampType(), required=False),
)

spec_hour = PartitionSpec(
    PartitionField(source_id=2, field_id=1000, transform=HourTransform(), name="ts_hour"),
)
table = catalog.create_table(
    "default.partition_spec_evolution_hour_day",
    schema=schema,
    partition_spec=spec_hour,
    properties={"format-version": "2"},
)

# spec 0: hour transform -> Avro 'int' (no logicalType)
table.append(pa.table({
    "id": pa.array([1], type=pa.int64()),
    "ts": pa.array([dt.datetime(2025, 1, 1, 0, 0)]),
}))

# evolve: hour -> day
with table.update_spec() as us:
    us.remove_field("ts_hour")
    us.add_field("ts", DayTransform(), "ts_day")

# spec 1: day transform -> Avro 'int' + logicalType=date
table.append(pa.table({
    "id": pa.array([2], type=pa.int64()),
    "ts": pa.array([dt.datetime(2025, 2, 1, 0, 0)]),
}))

print(f"metadata_location={table.metadata_location}")
