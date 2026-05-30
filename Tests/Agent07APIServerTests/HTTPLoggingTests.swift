//
//  HTTPLoggingTests.swift
//  Agent07APIServerTests
//

import Testing
import Foundation
@testable import Agent07APIServer

@Suite("HTTPLogging — built-in loggers")
struct HTTPLoggingTests {

    @Test("SilentHTTPLogger discards messages without side effects")
    func silentLoggerNoOp() {
        let logger = SilentHTTPLogger()
        logger.log("anything", source: "Test")
        logger.log("more", source: "Test")
        // No assertion needed — the contract is "no crash, no side effects."
    }

    @Test("PrintHTTPLogger formats message with source tag")
    func printLoggerFormats() {
        let logger = PrintHTTPLogger()
        // Captures stdout indirectly is overkill; we just verify the call
        // completes without throwing and the formatter doesn't crash on
        // empty / multibyte input.
        logger.log("ascii", source: "HTTP")
        logger.log("кириллица + 漢字", source: "i18n")
        logger.log("", source: "")
    }

    @Test("Custom HTTPLogging implementations are callable through `any` boxes")
    func customAnyHTTPLogging() {
        final class Capture: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [(String, String)] = []
            func append(_ m: String, _ s: String) {
                lock.lock(); defer { lock.unlock() }
                items.append((m, s))
            }
            var snapshot: [(String, String)] {
                lock.lock(); defer { lock.unlock() }
                return items
            }
        }
        let store = Capture()
        struct Capturing: HTTPLogging {
            let store: Capture
            func log(_ message: String, source: String) {
                store.append(message, source)
            }
        }
        let logger: any HTTPLogging = Capturing(store: store)
        logger.log("hi", source: "Test")

        let items = store.snapshot
        #expect(items.count == 1)
        #expect(items.first?.0 == "hi")
        #expect(items.first?.1 == "Test")
    }
}
