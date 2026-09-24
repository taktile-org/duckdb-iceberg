#include "iceberg_options.hpp"

namespace duckdb {

IcebergSnapshotLookup IcebergSnapshotLookup::FromAtClause(optional_ptr<BoundAtClause> at) {
	IcebergSnapshotLookup result;
	if (!at) {
		return result;
	}

	auto &unit = at->Unit();
	auto &value = at->GetValue();

	if (value.IsNull()) {
		throw InvalidInputException("NULL values can not be used as the 'unit' of a time travel clause");
	}
	if (StringUtil::CIEquals(unit, "version")) {
		//! The grammar only knows VERSION and TIMESTAMP, so a ref is a non-numeric VERSION string,
		//! the same way Spark's VERSION AS OF resolves 'branch-name'.
		Value snapshot_id;
		string cast_error;
		if (value.type().id() == LogicalTypeId::VARCHAR &&
		    !value.DefaultTryCastAs(LogicalType::BIGINT, snapshot_id, &cast_error, true)) {
			result.snapshot_source = SnapshotSource::FROM_REF;
			result.snapshot_ref = StringValue::Get(value);
			return result;
		}
		result.snapshot_source = SnapshotSource::FROM_ID;
		result.snapshot_id = value.DefaultCastAs(LogicalType::BIGINT).GetValue<int64_t>();
	} else if (StringUtil::CIEquals(unit, "timestamp")) {
		result.snapshot_source = SnapshotSource::FROM_TIMESTAMP;
		result.snapshot_timestamp = value.DefaultCastAs(LogicalType::TIMESTAMP).GetValue<timestamp_t>();
	} else {
		throw InvalidInputException(
		    "Unit '%s' for time travel is not valid, supported options are 'version' and 'timestamp'", unit);
	}
	return result;
}

} // namespace duckdb
