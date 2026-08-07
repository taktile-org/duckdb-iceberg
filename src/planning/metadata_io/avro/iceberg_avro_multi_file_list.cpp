#include "planning/metadata_io/avro/iceberg_avro_multi_file_list.hpp"
#include "core/metadata/manifest/iceberg_manifest.hpp"

namespace duckdb {

IcebergAvroScanInfo::IcebergAvroScanInfo(AvroScanInfoType type, const IcebergTableMetadata &metadata,
                                         const IcebergSnapshotScanInfo &snapshot_info)
    : type(type), metadata(metadata), snapshot_info(snapshot_info) {
}
IcebergAvroScanInfo::~IcebergAvroScanInfo() {
}

IcebergManifestListScanInfo::IcebergManifestListScanInfo(const IcebergTableMetadata &metadata,
                                                         const IcebergSnapshotScanInfo &snapshot_info,
                                                         vector<IcebergManifestListEntry> &result)
    : IcebergAvroScanInfo(TYPE, metadata, snapshot_info), result(result) {
}
IcebergManifestListScanInfo::~IcebergManifestListScanInfo() {
}

IcebergManifestFileScanInfo::IcebergManifestFileScanInfo(const IcebergTableMetadata &metadata,
                                                         const IcebergSnapshotScanInfo &snapshot_info,
                                                         vector<IcebergManifestListEntry> &manifest_files,
                                                         const IcebergOptions &options, FileSystem &fs,
                                                         const string &iceberg_path,
                                                         optional_ptr<ManifestEntryReadState> read_state,
                                                         optional_ptr<const vector<idx_t>> selected_indices)
    : IcebergAvroScanInfo(TYPE, metadata, snapshot_info), manifest_files(manifest_files), options(options), fs(fs),
      iceberg_path(iceberg_path), read_state(read_state), selected_indices(selected_indices) {
	unordered_set<int32_t> partition_spec_ids;
	auto selected_count = SelectedCount();
	for (idx_t i = 0; i < selected_count; i++) {
		auto &manifest = manifest_files[SelectedIndex(i)].file;
		partition_spec_ids.insert(manifest.partition_spec_id);
	}
	//! The schema of a manifest is affected by the 'partition_spec_id' of the 'manifest_file',
	//! because the 'partition' struct has a field for every partition field in that partition spec.

	//! Since we are now reading *all* manifests in one reader, we have to merge these schemas,
	//! and to do that we create a map of all relevant partition fields
	partition_field_id_to_type = IcebergDataFile::GetFieldIdToTypeMapping(snapshot_info, metadata, partition_spec_ids);
}

IcebergManifestFileScanInfo::~IcebergManifestFileScanInfo() {
}

IcebergAvroMultiFileList::IcebergAvroMultiFileList(shared_ptr<IcebergAvroScanInfo> info, vector<OpenFileInfo> paths)
    : SimpleMultiFileList(std::move(paths)), info(info) {
}
IcebergAvroMultiFileList::~IcebergAvroMultiFileList() {
}

} // namespace duckdb
