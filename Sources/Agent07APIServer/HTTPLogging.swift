//
//  HTTPLogging.swift
//  Agent07APIServer
//
//  Minimal logger protocol used by HTTPServer and BonjourService.
//  Adopt it on whatever logger your app already has — a one-line
//  conformance is enough.
//

import Foundation

/// One-method logger. `source` is a short tag the implementation may use
/// to colorise / filter / route messages (e.g. "HTTP", "Bonjour", "Error").
public protocol HTTPLogging: Sendable {
    func log(_ message: String, source: String)
}

/// Discards every message. Useful in tests, or when you don't care about
/// log output but still need to satisfy the API.
public struct SilentHTTPLogger: HTTPLogging {
    public init() {}
    public func log(_ message: String, source: String) {}
}

/// Prints to stdout with a `[source]` prefix. Handy in scripts or
/// command-line tools.
public struct PrintHTTPLogger: HTTPLogging {
    public init() {}
    public func log(_ message: String, source: String) {
        print("[\(source)] \(message)")
    }
}
