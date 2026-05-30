# Agent07APIServer

A tiny, dependency-free HTTP server for Swift apps on macOS / iOS.
Built on `Network.framework` — no Vapor, no SwiftNIO, no system
libraries to install. Pairs with Bonjour service advertising so iOS
companion apps can discover the host on the LAN.

[![CI](https://github.com/ArtemKyslicyn/Agent07APIServer/actions/workflows/ci.yml/badge.svg)](https://github.com/ArtemKyslicyn/Agent07APIServer/actions/workflows/ci.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2014%2B%20%7C%20iOS%2017%2B-blue.svg)](#)
[![SPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](#install)
[![Tests](https://img.shields.io/badge/Tests-53%20passing-success.svg)](#testing)
[![Coverage](https://img.shields.io/badge/Coverage-51%25-yellow.svg)](#testing)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Why

Most Swift HTTP servers either drag in a heavy framework (Vapor, Hummingbird)
or require manual `NWListener` plumbing. This package gives you a
production-shaped HTTP server in ~600 LOC: TCP listening, request
parsing, response framing, fallback-port retry, and a Bonjour layer to
publish the service on the local network.

Use it when:

- You're building a **macOS companion server** for an iOS app.
- You need a quick **local-only REST endpoint** (test runner, local
  tooling, IPC between two apps on the same machine).
- You want **Bonjour discovery** without writing the `NetService`
  bridge yourself.

You don't want this if you need TLS, HTTP/2, websocket framing,
streaming responses, or thousands of concurrent connections — pick
SwiftNIO / Vapor / Hummingbird for those.

## Install

```swift
.package(url: "https://github.com/ArtemKyslicyn/Agent07APIServer.git",
         from: "0.1.0")
```

Then in your target:

```swift
.product(name: "Agent07APIServer", package: "Agent07APIServer")
```

```swift
import Agent07APIServer
```

## Quick start

```swift
import Agent07APIServer

// 1. Pick a logger — silent for prod, print for dev. Or implement
//    `HTTPLogging` on your own logger with a one-method conformance.
let logger = PrintHTTPLogger()

// 2. Create the server. Port 0 = "let the OS pick a free port".
let server = HTTPServer(port: 8080, logger: logger)

// 3. Wire a request handler. Return any HTTPResponse.
server.onRequest = { request in
    switch (request.method, request.path) {
    case ("GET", "/health"):
        return HTTPResponse(statusCode: 200, body: Data("OK".utf8))

    case ("POST", "/echo"):
        return HTTPResponse.json(
            statusCode: 200,
            body: request.body ?? Data()
        )

    default:
        return HTTPResponse.error(statusCode: 404, message: "Not Found")
    }
}

// 4. Start. If 8080 is taken, fall back to 8081, then to an
//    OS-assigned ephemeral port.
try await server.startWithFallback(fallbackPorts: [8081])
print("Listening on \(server.boundPort)")

// 5. (Optional) advertise on Bonjour so iOS apps can discover us.
let bonjour = BonjourService(logger: logger)
bonjour.start()  // publishes `_agent07._tcp` by default

// Later …
server.stop()
bonjour.stop()
```

## Public API

### `HTTPServer`

```swift
public class HTTPServer: @unchecked Sendable {
    public init(port: UInt16 = 8080, logger: any HTTPLogging)
    public var boundPort: UInt16 { get }     // updated after fallback
    public var isRunning: Bool { get }
    public var uptimeSeconds: TimeInterval { get }

    public var onRequest: ((_ request: HTTPRequest) async -> HTTPResponse)?

    public func start() async throws
    public func startWithFallback(fallbackPorts: [UInt16] = [8081]) async throws
    public func stop()
}
```

The `startWithFallback(_:)` walks the configured port → each fallback →
the kernel-assigned ephemeral port (`0`), updating `boundPort` so
callers can advertise the actual port that won.

### `HTTPRequest` / `HTTPResponse`

```swift
public struct HTTPRequest: Sendable {
    public var method: String         // GET, POST, …
    public var path: String           // "/api/sessions"
    public var queryParams: [String: String]
    public var headers: [String: String]
    public var body: Data?
    public var requestId: String      // auto UUID if not provided
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public static func json(statusCode: Int = 200,
                            body: Data,
                            headers: [String: String] = [:]) -> HTTPResponse

    public static func error(statusCode: Int,
                             message: String) -> HTTPResponse
}
```

Default status texts cover the usual 200/201/204/400/401/403/404/500/
501/503. Anything else → `"Unknown"` (you can still set the code; only
the reason phrase is generic).

### `BonjourService`

```swift
public final class BonjourService: NSObject {
    public init(logger: any HTTPLogging)
    public func start()      // advertises _agent07._tcp on the LAN
    public func stop()
    public var isRunning: Bool { get }
}
```

### `HTTPLogging`

```swift
public protocol HTTPLogging: Sendable {
    func log(_ message: String, source: String)
}

// Two convenience implementations ship with the package:
public struct SilentHTTPLogger: HTTPLogging { ... }   // discards every message
public struct PrintHTTPLogger: HTTPLogging { ... }    // prints "[source] message"
```

If your app already has a logger, a one-line extension makes it
HTTPLogging-conformant:

```swift
extension MyAppLogger: HTTPLogging {
    func log(_ message: String, source: String) {
        log("[\(source)] \(message)", level: .info)
    }
}
```

## Testing

```bash
swift test
```

53 tests across 11 suites, **51% line coverage**, all green. Covers:

- `HTTPRequest` / `HTTPResponse` construction and helpers
- Internal HTTP parser: minimal GET, query params, headers, POST body,
  URL-encoded query keys/values, invalid UTF-8 → throws
- `parseQueryString` edge cases (empty, single, multiple, malformed,
  percent-encoded)
- Status-text mapping for 2xx / 4xx / 5xx + unknown fallback
- `HTTPServer` lifecycle: init, start, stop, double-stop, uptime tracking,
  port-0 ephemeral binding
- `BonjourService` lifecycle: init, start/stop, double-start safety
- `HTTPLogging` built-ins: `SilentHTTPLogger`, `PrintHTTPLogger`, and
  custom implementations through `any HTTPLogging`

What's NOT tested in the unit suite: full TCP round-trips through
`NWConnection` — those callback-driven tests proved flaky under
swift-testing because the server closes connections immediately after
sending a response, and `receive(...)` can hang waiting for data that
will never arrive. The HTTP request parser is exercised directly
instead.

## Origin

Extracted from [Agent07](https://github.com/ArtemKyslicyn/Agent07) in
2026-05. The app uses this server to talk to an iOS companion that
discovers the host via Bonjour — same use case the package is shaped
for.

## License

MIT — see [LICENSE](LICENSE).
