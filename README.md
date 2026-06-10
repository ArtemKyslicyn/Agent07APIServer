# Agent07APIServer

A tiny, dependency-free HTTP server + Bonjour LAN broadcast for Swift apps
on macOS / iOS. Built on `Network.framework` — no Vapor, no SwiftNIO, no
system libraries to install. Pairs HTTP listening with Bonjour service
advertising so iOS companion apps can discover the host on the local network.

[![CI](https://github.com/ArtemKyslicyn/Agent07APIServer/actions/workflows/ci.yml/badge.svg)](https://github.com/ArtemKyslicyn/Agent07APIServer/actions/workflows/ci.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2014%2B%20%7C%20iOS%2017%2B-blue.svg)](#)
[![SPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](#install)
[![Tests](https://img.shields.io/badge/Tests-53%20passing-success.svg)](#testing)
[![Coverage](https://img.shields.io/badge/Coverage-51%25-yellow.svg)](#testing)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## About

`Agent07APIServer` is the **public, dependency-free transport layer** that
lets the [Agent07](https://github.com/ArtemKyslicyn/Agent07) macOS app talk to
its iOS companion (Agent07Companion) over the **local network only**. It does
two things and nothing more:

1. **Serves HTTP** over a TCP port using `Network.framework`'s `NWListener` —
   request parsing, response framing, port-fallback retry, and a
   handler-based router (`onRequest`).
2. **Advertises on Bonjour** (mDNS) as `_agent07._tcp.` so the companion can
   auto-discover the host on the LAN without anyone typing an IP address.

In the Agent07 product, the macOS app embeds this server and registers an
`onRequest` handler that exposes read-only views of the user's data —
sessions list, chat transcripts, cost-savings / usage stats — plus a
push-notification relay. **Those routes are defined by the host app, not by
this package.** This package is intentionally the wire: it owns the socket,
the parser, and the Bonjour broadcast; the app owns the endpoints, the data
models, and any auth. That split keeps the transport open-source and
data-free while the product logic stays in the app.

**Privacy / network stance.** Everything is **LAN-only**. The Bonjour service
is published on the `.local` domain; the HTTP listener binds a local TCP port.
There is no cloud relay, no TLS termination, no outbound calls — the iOS
companion and the macOS host find each other and converse on the same Wi-Fi.

**Dependencies.** Zero third-party packages. Foundation + Network.framework
only, both first-party Apple frameworks.

## Why

Most Swift HTTP servers either drag in a heavy framework (Vapor, Hummingbird)
or require manual `NWListener` plumbing. This package gives you a
production-shaped HTTP server in ~440 LOC: TCP listening, request
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

Requires **macOS 14+ / iOS 17+**, Swift 6 language mode.

## Quick start

```swift
import Agent07APIServer

// 1. Pick a logger — silent for prod, print for dev. Or implement
//    `HTTPLogging` on your own logger with a one-method conformance.
let logger = PrintHTTPLogger()

// 2. Create the server. Port 0 = "let the OS pick a free port".
let server = HTTPServer(port: 8080, logger: logger)

// 3. Wire a request handler. Return any HTTPResponse. THIS is where
//    your app defines its routes — the package itself ships none.
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
//    Sync the *actually-bound* port first, in case a fallback won.
let bonjour = BonjourService(port: server.boundPort, logger: logger)
bonjour.updatePort(server.boundPort)
bonjour.start()  // publishes `_agent07._tcp.` by default

// Later …
server.stop()
bonjour.stop()
```

## How the macOS app embeds it

The Agent07 app composes the two pieces in a thin `APIServer` coordinator:

1. Construct `HTTPServer`, register an `onRequest` router that maps paths
   (`/api/sessions`, chat reads, usage/cost-savings, push relay) to the app's
   read-only data and returns `HTTPResponse.json(...)`.
2. Call `startWithFallback()`. Because the configured port may be taken, the
   server retries `8081` and then an ephemeral port, updating `boundPort`.
3. Construct `BonjourService`, call `updatePort(server.boundPort)` so the
   advertised port matches the port that actually won, then `start()`.

> **Note on endpoints.** This README does not enumerate `/api/...` routes
> because **none are defined in this package** — grep the sources and you will
> find no route table. Routes live in the host app's `onRequest` closure. The
> only "endpoint" behaviour baked into the package is the fallback when no
> handler is installed: any request returns **`501 Not Implemented`** with the
> JSON error body `{"error":true,"message":"Server not configured","statusCode":501}`,
> and an unparseable request returns **`400 Bad Request`**.

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

`startWithFallback(_:)` walks the configured port → each fallback →
the kernel-assigned ephemeral port (`0`), updating `boundPort` so
callers can advertise the actual port that won. `start()` bridges
`NWListener`'s `stateUpdateHandler` into `async` via a checked
continuation that resumes exactly once (a state machine can fire
`.ready` → `.failed` → `.cancelled` for a single start).

### `HTTPRequest` / `HTTPResponse`

These are the Sendable value types your `onRequest` handler receives and
returns. They are plain structs, not Codable wire models — you decode
`request.body` and encode your response body yourself (typically with
`HTTPResponse.json`).

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

- `HTTPResponse.json(...)` sets `Content-Type: application/json; charset=utf-8`
  and `Content-Length`, preserving any custom headers you pass.
- `HTTPResponse.error(...)` builds a JSON body
  `{"error": true, "message": <message>, "statusCode": <code>}` and sends it
  as JSON.
- On the wire the server always adds `Server: Agent07/1.0` and
  `Connection: close` (HTTP/1.0-style; the connection is closed after each
  response), plus `Content-Length` if you didn't set one.

Default status texts cover 200/201/204/400/401/403/404/500/
501/503. Anything else → `"Unknown"` (you can still set the code; only
the reason phrase is generic).

### `BonjourService`

```swift
public class BonjourService: NSObject, @unchecked Sendable {
    public static let defaultServiceType = "_agent07._tcp."

    public init(port: UInt16 = 8080,
                serviceName: String? = nil,
                serviceType: String = BonjourService.defaultServiceType,
                logger: any HTTPLogging)

    public func updatePort(_ newPort: UInt16)  // sync after HTTP fallback
    public func start()      // advertises on the LAN
    public func stop()
    public var isRunning: Bool { get }
}
```

Advertising details (all from the implementation):

- **Service type:** `_agent07._tcp.` on the empty (default `.local`) domain.
- **Service name:** defaults to `ProcessInfo.processInfo.hostName` (e.g.
  `"MacBook-Pro"`); override via `serviceName:`.
- **TXT record** carries three keys:
  - `version` — API version, currently `"1.0"`
  - `name` — the human-readable device/service name
  - `platform` — `"macOS"`
- **Advertise-only.** It publishes for discovery but does **not** call
  `listenForConnections` — the `HTTPServer`'s `NWListener` owns the port.
  Asking `NetService` to also listen would bind the same port and fail with
  `EADDRINUSE`. The `didAcceptConnectionWith` delegate method is therefore
  never expected to fire.
- **Resilient publish.** A `didNotPublish` callback is logged as a warning
  (mDNS auto-renames and retries on transient name/port collisions); genuine
  bind failures surface from the HTTP listener instead.

Always call `updatePort(server.boundPort)` before `start()` if you used
`startWithFallback`, so the advertised port matches the bound one.

### `HTTPLogging`

```swift
public protocol HTTPLogging: Sendable {
    func log(_ message: String, source: String)
}

// Two convenience implementations ship with the package:
public struct SilentHTTPLogger: HTTPLogging { ... }   // discards every message
public struct PrintHTTPLogger: HTTPLogging { ... }    // prints "[source] message"
```

`source` is a short routing tag the server emits — `"HTTP"`, `"Bonjour"`,
`"Error"`, `"Warning"` — so your logger can colourise / filter by category.
If your app already has a logger, a one-line extension makes it conformant:

```swift
extension MyAppLogger: HTTPLogging {
    func log(_ message: String, source: String) {
        log("[\(source)] \(message)", level: .info)
    }
}
```

## Concurrency model

- `onRequest` is an `async` closure; the server awaits it per request inside a
  `Task`, so handlers may do async work (DB reads, file IO) without blocking
  the listener.
- `NWListener` and each `NWConnection` run on a global dispatch queue. Incoming
  bytes are read (up to 8 KB of headers), parsed off the callback into a
  `Task`, handled, and the response is written back before the connection is
  cancelled.
- `HTTPServer` and `BonjourService` are `@unchecked Sendable`: they hold
  mutable state (`connections`, `isRunning`, `netService`) mutated from
  Network.framework callbacks. The continuation that backs `start()` is
  guarded by a single-shot `ResumeOnce` lock so it can never double-resume.
- `HTTPRequest`, `HTTPResponse`, and the loggers are value types / are
  properly `Sendable`. The whole package builds clean under Swift 6 language
  mode.

## Testing

```bash
swift test
```

53 tests across 11 suites, all green. (The coverage badge above is
**updated automatically by CI on every push to `main`** — see
`.github/workflows/ci.yml`; do not hardcode it.) Covered:

- **`HTTPRequest` / `HTTPResponse`** — construction, minimal vs. full init,
  unique auto request IDs, the `json` factory (Content-Type / Content-Length /
  custom-header preservation / custom status), and the `error` factory's JSON
  body shape across 4xx/5xx codes.
- **Internal HTTP parser (`parseHTTPRequest`)** — minimal GET, query-param
  extraction, header parsing, POST/JSON body after the blank line,
  URL-encoded keys/values, invalid UTF-8 → throws, permissive empty
  request-line behaviour, and bodyless requests (`DELETE`).
- **`parseQueryString`** — empty, single, multiple, malformed (no `=`,
  dropped), and percent-encoded pairs.
- **`statusText`** — 2xx / 4xx / 5xx mappings plus the `"Unknown"` fallback
  for unmapped codes.
- **`HTTPServer` lifecycle** — default/custom port init, uptime tracking,
  start on an ephemeral port (`port: 0`), stop, double-stop, stop-without-start,
  and that `onRequest` can be installed and return custom responses.
- **`BonjourService` lifecycle** — init defaults, start/stop, double-start
  no-op, stop-before-start safety.
- **`HTTPLogging` built-ins** — `SilentHTTPLogger` no-op, `PrintHTTPLogger`
  formatting (including multibyte/empty input), and custom conformances
  exercised through an `any HTTPLogging` box.

**What's NOT covered by unit tests:** full TCP round-trips through a live
`NWConnection`. Those callback-driven tests proved flaky under swift-testing —
the server closes the connection immediately after sending its response, so a
test-side `receive(...)` can hang waiting for bytes that never arrive. The
HTTP request parser is exercised directly instead, covering the actual
request-handling logic without a real socket.

## Origin

Extracted from [Agent07](https://github.com/ArtemKyslicyn/Agent07) in
2026-05. The app uses this server to talk to an iOS companion that
discovers the host via Bonjour — the same use case the package is shaped
for.

## License

MIT — see [LICENSE](LICENSE).
</content>
</invoke>
