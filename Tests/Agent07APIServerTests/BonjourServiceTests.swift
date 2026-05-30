//
//  BonjourServiceTests.swift
//  Agent07APIServerTests
//

import Testing
import Foundation
@testable import Agent07APIServer

private struct NoopLogger: HTTPLogging {
    func log(_ message: String, source: String) {}
}

@Suite("BonjourService")
struct BonjourServiceTests {

    @Test("Initialises with sane defaults")
    func initDefaults() {
        let svc = BonjourService(logger: NoopLogger())
        #expect(!svc.isRunning)
    }

    @Test("Start + stop lifecycle without crash")
    func startStop() async throws {
        let svc = BonjourService(logger: NoopLogger())
        svc.start()
        // Bonjour publish is asynchronous; the flag flips during the
        // willPublish delegate. Stop immediately — both paths must be safe.
        svc.stop()
        #expect(!svc.isRunning)
    }

    @Test("Double-start is treated as no-op")
    func doubleStartSafe() {
        let svc = BonjourService(logger: NoopLogger())
        svc.start()
        svc.start()
        svc.stop()
    }

    @Test("Stop before start is safe")
    func stopBeforeStart() {
        let svc = BonjourService(logger: NoopLogger())
        svc.stop()
        #expect(!svc.isRunning)
    }
}
