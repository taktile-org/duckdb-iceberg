#include "catalog/rest/api/api_utils.hpp"

#include "duckdb/common/exception.hpp"
#include "duckdb/common/http_util.hpp"
#include "duckdb/main/extension_helper.hpp"
#include "duckdb/common/exception/http_exception.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/main/client_data.hpp"
#include "duckdb/main/database.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

#include <sys/stat.h>
#include <chrono>
#include <cmath>
#include <thread>

namespace duckdb {
//! Grab the first path that exists, from a list of well-known locations
static string SelectCURLCertPath() {
	for (string &caFile : certFileLocations) {
		struct stat buf;
		if (stat(caFile.c_str(), &buf) == 0) {
			return caFile;
		}
	}
	return string();
}

const string &APIUtils::GetCURLCertPath() {
	static string cert_path = SelectCURLCertPath();
	return cert_path;
}

unique_ptr<HTTPResponse> APIUtils::SendWithGatewayRetry(const HTTPParams &params,
                                                        const std::function<unique_ptr<HTTPResponse>()> &send) {
	auto response = send();
	for (uint64_t tries = 1; tries <= params.retries; tries++) {
		if (!response || response->status != HTTPStatusCode::BadGateway_502 || response->ShouldRetry()) {
			// Either the request is settled, or the status is one core retries on its own - in which
			// case this response is already the outcome of that retry loop and re-sending doubles it.
			return response;
		}
		if (tries > 1) {
#ifndef DUCKDB_NO_THREADS
			auto sleep_amount = static_cast<uint64_t>(static_cast<double>(params.retry_wait_ms) *
			                                          std::pow(params.retry_backoff, static_cast<double>(tries - 2)));
			std::this_thread::sleep_for(std::chrono::milliseconds(sleep_amount));
#endif
		}
		response = send();
	}
	return response;
}

unique_ptr<HTTPResponse> APIUtils::Request(RequestType request_type, optional_ptr<AttachedDatabase> attached_db,
                                           ClientContext &context, const IRCEndpointBuilder &endpoint_builder,
                                           HTTPHeaders &headers, const string &data) {
	// load httpfs since iceberg requests do not go through the file system api
	if (!context.db.get()) {
		throw InvalidConfigurationException("Context does not have database instance when loading Httpfs in Iceberg");
	}
	ExtensionHelper::AutoLoadExtension(*context.db, "httpfs");
	if (!context.db->ExtensionIsLoaded("httpfs")) {
		throw MissingExtensionException("The iceberg extension requires the httpfs extension to be loaded!");
	}

	auto &db = DatabaseInstance::GetDatabase(context);
	string request_url = AddHttpHostIfMissing(endpoint_builder.GetURLEncoded());

	auto &http_util = HTTPUtil::Get(db);
	unique_ptr<HTTPParams> params;
	params = http_util.InitializeParameters(context, request_url);

	unique_ptr<HTTPClient> placeholder_client;
	auto &client =
	    attached_db ? IcebergAuthorizationContextState::GetHTTPClient(*attached_db, context) : placeholder_client;
	if (client) {
		client->Initialize(*params);
	}

	switch (request_type) {
	case RequestType::GET_REQUEST: {
		GetRequestInfo get_request(request_url, headers, *params, nullptr, nullptr);
		return SendWithGatewayRetry(*params, [&]() { return http_util.Request(get_request, client); });
	}
	case RequestType::DELETE_REQUEST: {
		DeleteRequestInfo delete_request(request_url, headers, *params);
		return http_util.Request(delete_request, client);
	}
	case RequestType::POST_REQUEST: {
		PostRequestInfo post_request(request_url, headers, *params, reinterpret_cast<const_data_ptr_t>(data.data()),
		                             data.size());
		auto response = http_util.Request(post_request, client);
		response->body = post_request.buffer_out;
		return response;
	}
	case RequestType::HEAD_REQUEST: {
		HeadRequestInfo head_request(request_url, headers, *params);
		return SendWithGatewayRetry(*params, [&]() { return http_util.Request(head_request, client); });
	}
	default:
		throw NotImplementedException("Cannot make request of type %s", EnumUtil::ToString(request_type));
	}
}

} // namespace duckdb
