/**
 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as
 published by the Free Software Foundation, either version 3 of the
 License, or (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
import Swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A service that converts actions and parameters into an endpoint URL
public protocol EndpointService {
    /// The session that will be used to connect to a service
    var session: URLSession { get }

    /// Creates a request for the given `APIRequest`
    func buildRequest<A: APIRequest>(for request: A, cache: URLRequest.CachePolicy?) throws -> URLRequest where A.Service == Self
}

/// An API request that can be either a REST GET or a POST like GraphQL.
///
/// Each request has a specific associated `Response`, which
/// can be an `Xor` when multiple response types should be expected, such as:
///
/// ```
/// typealias Response = XOr<FailureResponse>.Or<SuccessResponse>
/// ```
public protocol APIRequest {
    associatedtype Response : Pure
    associatedtype Service : EndpointService
    func queryURL(for service: Service) -> URL
    /// Post data if this is a `POST` request, `nil` if it is a `GET`
    func postData() throws -> Data?
}

public extension EndpointService {
    /// The default endpoint implementation uses `URLSession.shared`
    var session: URLSession { .shared }
}

extension EndpointService {
#if swift(>=5.5)
    @available(macOS 12.0, iOS 15.0, *)
    public func requestAsync<A: APIRequest>(_ request: A, cache: URLRequest.CachePolicy? = nil, retry: Bool = true) async throws -> A.Response where A.Service == Self {
        let (data, response) = try await session.data(for: buildRequest(for: request, cache: cache), delegate: nil)

        // check response headers for rate-limiting
        if let response = response as? HTTPURLResponse {
            let headers = response.allHeaderFields
            // let limitResource = headers["x-ratelimit-resource"]
            let limit = headers[AnyHashable("x-ratelimit-limit")] as? String
            let used = headers[AnyHashable("x-ratelimit-used")] as? String
            let remaining = headers[AnyHashable("x-ratelimit-remaining")] as? String
            let reset = headers[AnyHashable("x-ratelimit-reset")] as? String

            // dbg("limit:", limit, type(of: limit), "used:", used, "remaing:", remaining, "reset:", reset)

            if let limit = limit.flatMap(Int.init),
               let used = used.flatMap(Int.init),
               let remaining = remaining.flatMap(Int.init),
               let reset = reset.flatMap(TimeInterval.init) {
                let resetTime = Date(timeIntervalSince1970: reset)
                dbg("rate limit: \(used)/\(limit) (\(remaining) remaining) resets:", resetTime)
            }
        }
        return try decode(data: data)
    }
#endif
}

extension EndpointService {

    /// Decodes the given response, first checking for a `ResponseError` error
    func decode<T: Decodable>(data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        //dbg("decoding:", String(data: data, encoding: .utf8) ?? "") // debugging for failures

        return try decoder.decode(T.self, from: data)
    }

    /// Fetches the web service for the given request
    public func requestSync<A: APIRequest>(_ request: A) throws -> A.Response where A.Service == Self {
        try decode(data: try session.fetchSync(buildRequest(for: request, cache: nil)).data)
    }

    /// Fetches the web service for the given request, following the cursor until the `batchHandler` returns a non-`nil` response; the first response element will be returned
    public func requestFirstBatch<T, A: CursoredAPIRequest>(_ request: A, cache: URLRequest.CachePolicy? = nil, batchHandler: (_ requestIndex: Int, _ urlResponse: URLResponse, _ batch: A.Response) throws -> T?) throws -> T? where A.Service == Self, A.Response.CursorType == A.CursorType {
        var request = request
        for requestIndex in 0... {
            let (data, urlResponse) = try session.fetchSync(buildRequest(for: request, cache: cache))
            let batch: A.Response = try decode(data: data)

            if let stopValue = try batchHandler(requestIndex, urlResponse, batch) {
                // handler found what it wants
                return stopValue
            }
            guard let cursor = batch.endCursor else {
                // no more elements
                return nil
            }
            dbg("requesing next cursor") // , cursor)
            request.cursor = cursor // make another request with the new cursor
        }

        return nil
    }

    /// Fetches the web service for the given request, following the cursor until a maximum number of batches has been retrieved
    public func requestBatches<A: CursoredAPIRequest>(_ request: A, maxBatches: Int) throws -> [A.Response] where A.Service == Self, A.Response.CursorType == A.CursorType {
        var batches: [A.Response] = []
        let _: Bool? = try self.requestFirstBatch(request) { resultIndex, urlResponse, batch in
            batches.append(batch)
            if batches.count >= maxBatches {
                return false
            } else {
                return nil // keep going
            }
        }
        return batches
    }
}

/// A response that returns results in batches with a cursor
public protocol CursoredAPIResponse {
    associatedtype CursorType
    var endCursor: CursorType? { get }
    /// The number of elements in this response batch
    var elementCount: Int { get }
}

/// In the common case of a result type that is in `XOr<Error>.Or<Result>`, use the success value as the success
extension XOr.Or : CursoredAPIResponse where P : Error, Q : CursoredAPIResponse {
    public typealias CursorType = Q.CursorType

    public var elementCount: Int {
        result.successValue?.elementCount ?? 0
    }

    /// Passes the cursor check through to the success value
    public var endCursor: CursorType? {
        result.successValue?.endCursor
    }
}

/// A response from an API that incudes the ability to move through pages.
public protocol CursoredAPIRequest : APIRequest where Response : CursoredAPIResponse {
    associatedtype CursorType
    /// The number of results per batch to return
    var count: Int { get set }
    /// The cursor for the request
    var cursor: CursorType? { get set }
}

public extension URLRequest {
    #if swift(>=5.5)
    /// Downloads the URL and verifies the HTTP success code and, optionally, the validity of the
    /// SHA-256 hash included as the URL's fragment.
    ///
    /// - Parameters:
    ///   - session: the URLSession to use, defaulting to `URLSession.shared`
    ///   - validateFragmentHash: if `true`, validate that the contents of the data match a SHA256 hash in the URL
    /// - Returns: the `Data` if it downloaded and validated
    @available(macOS 12.0, iOS 15.0, *)
    func fetch(session: URLSession = .shared, validateFragmentHash: Bool = false) async throws -> Data {
        let (data, response) = try await session.data(for: self, delegate: nil)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Bundle.module.error("URL response was not HTTP for \(self.url?.absoluteString ?? "")")
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            throw Bundle.module.error("Bad HTTP response \(httpResponse.statusCode) for \(self.url?.absoluteString ?? "")")
        }

        #if canImport(CommonCrypto)
        if validateFragmentHash == true,
            let fragmentHash = self.url?.fragment {
            let dataHash = data.sha256().hex()
            if dataHash != fragmentHash {
                throw Bundle.module.error("Hash mismatch for \(self.url?.absoluteString ?? ""): \(fragmentHash) vs. \(dataHash)")
            }
        }
        #endif

        return data
    }
    #endif
}

// TODO: @available(*, deprecated, message: "migrate to async")
public extension URLSession {
    /// Synchronously fetches the given URL
    ///
    /// ```let (data, response) = try await session.data(from: url)```
    ///
    /// - TODO: Swift 5.5 async support
    func dataSync(from url: URL) throws -> (data: Data, response: URLResponse) {
        try fetchSync(URLRequest(url: url))
    }

    /// Fetches the given URL request in the current session
    func fetchSync(_ request: URLRequest, timeout: DispatchTime = .distantFuture) throws -> (data: Data, response: URLResponse) {
        try sync(request: request, timeout: timeout, createTask: dataTask)
    }

    #if os(Linux) || os(Windows)
    /// Stub for missing async data support on Linux & Windows
    func data(for request: URLRequest, delegate: Void?) async throws -> (data: Data, response: URLResponse) {
        try fetchSync(request)
    }
    #endif

    /// Downloads the given URL request in the current session
    func downloadSync(_ request: URLRequest, timeout: DispatchTime = .distantFuture) throws -> (url: URL, response: URLResponse) {
        try sync(request: request, timeout: timeout, createTask: downloadTaskCopy)
    }

    /// Initiates the given task (either `dataTask` or `downloadTask`) and waits for completion.
    /// Swift 5.5 applications should avoid using this in favor of the async/await versions of the API.
    private func sync<T>(request: URLRequest, timeout: DispatchTime, createTask: (_ with: URLRequest, _ completionHandler: @escaping (T?, URLResponse?, Error?) -> ()) -> URLSessionTask) throws -> (T, response: URLResponse) {

        let done = DispatchSemaphore(value: 0)
        var data: T?
        var response: URLResponse?
        var error: Error?
        createTask(request) {
            (data, response, error) = ($0, $1, $2)
            done.signal()
        }.resume()
        switch done.wait(timeout: timeout) {
        case .success:
            if let error = error {
                throw error
            } else if let response = response, let data = data {
                return (data, response)
            } else {
                throw GraphQLError(message: "No response or data")
            }
        case .timedOut:
            throw GraphQLError(message: "Request timed out")
        }
    }
}

extension URLSession {
    /// If the download from `downloadTask` is successful, the completion handler receives a URL indicating the location of the downloaded file on the local filesystem. This storage is temporary. To preserve the file, this will move it from the temporary location before returning from the completion handler.
    /// In practice, macOS seems to be inconsistent in when it ever cleans up these files, so a failure here will manifest itself in occasional missing files.
    /// This is needed for running an async operation that will still have access to the resulting file.
    func downloadTaskCopy(with request: URLRequest, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
        self.downloadTask(with: request) { url, response, error in
            /// Files are generally placed somewhere like: file:///var/folders/24/8k48jl6d249_n_qfxwsl6xvm0000gn/T/CFNetworkDownload_q0k6gM.tmp
            do {
                /// We'll copy it to a temporary replacement directory with the base name matching the URL's name
                if let temporaryLocalURL = url,
                   temporaryLocalURL.isFileURL {
                   let tempDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: temporaryLocalURL, create: true)
                    let destinationURL = tempDir.appendingPathComponent(temporaryLocalURL.lastPathComponent)
                    try FileManager.default.moveItem(at: temporaryLocalURL, to: destinationURL)
                    dbg("replace download file for:", response?.url, "local:", temporaryLocalURL.path, "moved:", destinationURL.path)
                    return completionHandler(destinationURL, response, error)
                       
                }
            } catch {
                dbg("ignoring file move error and falling back to un-copied file:", error)
            }

            // fall-back to the completion handler
            return completionHandler(url, response, error)
        }
    }
}
