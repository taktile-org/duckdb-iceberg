//===----------------------------------------------------------------------===//
//                         DuckDB
//
// api_utils.hpp
//
//
//===----------------------------------------------------------------------===//

#pragma once

#include "duckdb/common/printer.hpp"
#include "duckdb/common/file_system.hpp"
#include "duckdb/common/http_util.hpp"

#include "catalog/rest/api/url_utils.hpp"
#include "catalog/rest/storage/aws.hpp"
#include "catalog/rest/storage/iceberg_authorization.hpp"

namespace duckdb {

// we statically compile in libcurl, which means the cert file location of the build machine is the
// place curl will look. But not every distro has this file in the same location, so we search a
// number of common locations and use the first one we find.
static string certFileLocations[] = {
    // Arch, Debian-based, Gentoo
    "/etc/ssl/certs/ca-certificates.crt",
    // RedHat 7 based
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
    // Redhat 6 based
    "/etc/pki/tls/certs/ca-bundle.crt",
    // OpenSUSE
    "/etc/ssl/ca-bundle.pem",
    // Alpine
    "/etc/ssl/cert.pem"};

class APIUtils {
public:
	static unique_ptr<HTTPResponse> Request(RequestType request_type, optional_ptr<AttachedDatabase> db,
	                                        ClientContext &context, const IRCEndpointBuilder &endpoint_builder,
	                                        HTTPHeaders &headers, const string &data);

	//! Run `send`, re-sending it while the response carries a transient gateway status that DuckDB
	//! itself does not treat as retryable. HTTPResponse::ShouldRetry() covers 408/418/429/500/503/504,
	//! so a 502 from a catalog behind a load balancer (Glue, S3Tables) reaches the caller as a hard
	//! error on the very first response, where a 500 from the same endpoint would have been absorbed.
	//! Attempt count and backoff mirror HTTPUtil::RunRequestWithRetry, and ShouldRetry() gates the
	//! re-send, so this is inert on a DuckDB whose own list already contains the status. Only
	//! idempotent requests may be routed through here: a re-send is a second, indistinguishable
	//! request as far as the server is concerned.
	static unique_ptr<HTTPResponse> SendWithGatewayRetry(const HTTPParams &params,
	                                                     const std::function<unique_ptr<HTTPResponse>()> &send);

	//! We use a singleton here to store the path, set by SelectCurlCertPath
	static const string &GetCURLCertPath();
};

} // namespace duckdb
