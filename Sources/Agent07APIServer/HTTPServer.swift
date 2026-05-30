// swiftlint:disable no_untyped_dictionaries
//
//  HTTPServer.swift
//  Agent07APIServer
//
//  HTTP REST server for iOS companion app communication.
//  Uses NWListener (Network.framework) — no external deps.
//

import Foundation
import Network

/// HTTP request representation parsed from raw TCP connection.
public struct HTTPRequest: Sendable {
    /// HTTP method (GET, POST, etc.)
    public var method: String

    /// Request path (e.g., "/api/sessions")
    public var path: String

    /// Query parameters extracted from URL
    public var queryParams: [String: String]

    /// Request headers
    public var headers: [String: String]

    /// Request body (if present)
    public var body: Data?

    /// Request ID for logging/correlation
    public var requestId: String

    public init(
        method: String,
        path: String,
        queryParams: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil,
        requestId: String = UUID().uuidString
    ) {
        self.method = method
        self.path = path
        self.queryParams = queryParams
        self.headers = headers
        self.body = body
        self.requestId = requestId
    }
}

/// HTTP response representation to send back to clients.
public struct HTTPResponse: Sendable {
    /// HTTP status code (200, 404, 500, etc.)
    public var statusCode: Int

    /// Response headers
    public var headers: [String: String]

    /// Response body
    public var body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Create JSON response with standard headers
    public static func json(
        statusCode: Int = 200,
        body: Data,
        headers: [String: String] = [:]
    ) -> HTTPResponse {
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json; charset=utf-8"
        allHeaders["Content-Length"] = "\(body.count)"
        return HTTPResponse(statusCode: statusCode, headers: allHeaders, body: body)
    }

    /// Create error response
    public static func error(
        statusCode: Int,
        message: String
    ) -> HTTPResponse {
        let errorDict: [String: Any] = [
            "error": true,
            "message": message,
            "statusCode": statusCode
        ]
        let body = (try? JSONSerialization.data(withJSONObject: errorDict)) ?? Data()
        return .json(statusCode: statusCode, body: body)
    }
}

/// HTTP server using Network.framework for iOS companion app REST API.
///
/// Listens on a TCP port, parses incoming HTTP requests, and delegates to a router for handling.
/// No external dependencies — pure Network.framework implementation.
public class HTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var port: UInt16
    /// Public-readable so callers (APIServer/BonjourService) can advertise
    /// the actually-bound port when a fallback was taken.
    public var boundPort: UInt16 { port }
    public var isRunning = false
    private let logger: any HTTPLogging
    private let startTime: Date

    /// Called when an HTTP request is received. Return HTTPResponse to send back.
    public var onRequest: ((_ request: HTTPRequest) async -> HTTPResponse)?

    public init(port: UInt16 = 8080, logger: any HTTPLogging) {
        self.port = port
        self.logger = logger
        self.startTime = Date()
    }

    /// Try `start()` on the configured port; if that fails because the
    /// port is in use, fall back through `fallbackPorts` in order, and
    /// finally to an ephemeral port (kernel-assigned). Throws only when
    /// every attempt fails. The `boundPort` property is updated to reflect
    /// the port the listener actually attached to.
    public func startWithFallback(fallbackPorts: [UInt16] = [8081]) async throws {
        let attempts: [UInt16] = [port] + fallbackPorts + [0]
        var lastError: Error?
        for attempt in attempts {
            port = attempt
            do {
                try await start()
                return
            } catch {
                lastError = error
                logger.log("HTTP server port \(attempt) failed — trying next", source: "HTTP")
            }
        }
        throw lastError ?? NSError(domain: "HTTPServer", code: -1)
    }

    // MARK: - Start/Stop

    public func start() async throws {
        let params = NWParameters.tcp
        // Configure TCP options for HTTP traffic
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(
                domain: "HTTPServer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid port number: \(port)"]
            )
        }

        let newListener = try NWListener(using: params, on: nwPort)
        listener = newListener

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Capture-once flag: stateUpdateHandler may fire multiple times.
            let resumed = ResumeOnce()
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.logger.log("HTTP server started on port \(self.port)", source: "HTTP")
                    resumed.resume { cont.resume() }
                case .failed(let error):
                    self.isRunning = false
                    self.logger.log("HTTP server failed: \(error)", source: "Error")
                    resumed.resume { cont.resume(throwing: error) }
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
            newListener.start(queue: .global())
        }
    }

    public func stop() {
        listener?.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isRunning = false
        logger.log("HTTP server stopped", source: "HTTP")
    }

    // MARK: - Server Info

    /// Server uptime in seconds
    public var uptimeSeconds: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)
        logger.log("HTTP client connected (\(connections.count) total)", source: "HTTP")

        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.connections.removeAll { $0 === connection }
                self?.logger.log("HTTP client disconnected", source: "HTTP")
            }
        }

        connection.start(queue: .global())
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        // Receive HTTP request header (up to 8KB for headers)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.logger.log("HTTP receive error: \(error)", source: "Error")
                connection.cancel()
                return
            }

            guard let data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }

            // Parse HTTP request
            Task {
                do {
                    let request = try self.parseHTTPRequest(from: data)
                    let response = await self.handleRequest(request)
                    self.sendResponse(response, on: connection)
                } catch {
                    self.logger.log("HTTP parse error: \(error)", source: "Error")
                    let errorResponse = HTTPResponse.error(statusCode: 400, message: "Bad Request")
                    self.sendResponse(errorResponse, on: connection)
                }
            }
        }
    }

    // MARK: - Request Parsing

    /// Internal for `@testable import` so the parser can be exercised without
    /// going through a real TCP connection.
    func parseHTTPRequest(from data: Data) throws -> HTTPRequest {
        guard let requestString = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "HTTPServer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 encoding"]
            )
        }

        // Split headers and body
        let parts = requestString.components(separatedBy: "\r\n\r\n")
        guard let headerSection = parts.first else {
            throw NSError(
                domain: "HTTPServer",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Missing HTTP headers"]
            )
        }

        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw NSError(
                domain: "HTTPServer",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Missing request line"]
            )
        }

        // Parse request line: "GET /api/sessions HTTP/1.1"
        let requestComponents = requestLine.components(separatedBy: " ")
        guard requestComponents.count >= 2 else {
            throw NSError(
                domain: "HTTPServer",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Invalid request line format"]
            )
        }

        let method = requestComponents[0]
        let fullPath = requestComponents[1]

        // Parse path and query params
        var path = fullPath
        var queryParams: [String: String] = [:]

        if let queryStart = fullPath.firstIndex(of: "?") {
            path = String(fullPath[..<queryStart])
            let queryString = String(fullPath[fullPath.index(after: queryStart)...])
            queryParams = parseQueryString(queryString)
        }

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Extract body if present
        var body: Data?
        if parts.count > 1 {
            let bodyString = parts[1...].joined(separator: "\r\n\r\n")
            body = bodyString.data(using: .utf8)
        }

        return HTTPRequest(
            method: method,
            path: path,
            queryParams: queryParams,
            headers: headers,
            body: body
        )
    }

    /// Internal for `@testable import`.
    func parseQueryString(_ queryString: String) -> [String: String] {
        var params: [String: String] = [:]
        let pairs = queryString.components(separatedBy: "&")
        for pair in pairs {
            let components = pair.components(separatedBy: "=")
            if components.count == 2 {
                let key = components[0].removingPercentEncoding ?? components[0]
                let value = components[1].removingPercentEncoding ?? components[1]
                params[key] = value
            }
        }
        return params
    }

    // MARK: - Request Handling

    private func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        logger.log("HTTP \(request.method) \(request.path)", source: "HTTP")

        guard let handler = onRequest else {
            return HTTPResponse.error(
                statusCode: 501,
                message: "Server not configured"
            )
        }

        return await handler(request)
    }

    // MARK: - Response Sending

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        let statusLine = "HTTP/1.1 \(response.statusCode) \(statusText(for: response.statusCode))\r\n"

        var headerLines = ""
        for (key, value) in response.headers {
            headerLines += "\(key): \(value)\r\n"
        }

        // Ensure we have basic headers
        if response.headers["Content-Length"] == nil {
            headerLines += "Content-Length: \(response.body.count)\r\n"
        }
        if response.headers["Server"] == nil {
            headerLines += "Server: Agent07/1.0\r\n"
        }
        if response.headers["Connection"] == nil {
            headerLines += "Connection: close\r\n"
        }

        let responseString = statusLine + headerLines + "\r\n"
        var responseData = Data(responseString.utf8)
        responseData.append(response.body)

        connection.send(
            content: responseData,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.logger.log("HTTP send error: \(error)", source: "Error")
                }
                // Close connection after response (HTTP/1.0 style)
                connection.cancel()
            }
        )
    }

    /// Internal for `@testable import`.
    func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}

// Single-shot guard so an NWListener stateUpdateHandler — which may fire
// `.ready` → `.failed` → `.cancelled` for the same start — resumes the
// awaiting continuation exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func resume(_ action: () -> Void) {
        lock.lock()
        let shouldFire = !fired
        fired = true
        lock.unlock()
        if shouldFire { action() }
    }
}
