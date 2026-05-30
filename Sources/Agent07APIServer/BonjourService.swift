//
//  BonjourService.swift
//  Agent07APIServer
//
//  Bonjour/mDNS service advertisement for local network discovery.
//  Advertises HTTP REST API server so iOS companion app can auto-discover macOS instance.
//

import Foundation

/// Bonjour service advertisement for Agent07 HTTP API server.
///
/// Advertises the REST API server on the local network using mDNS/Bonjour,
/// allowing iOS companion app to discover and connect to macOS Agent07 instance
/// without manual IP address configuration.
///
/// Service type: `_agent07._tcp.` (custom service type for Agent07 API)
/// Service name: Device hostname (e.g., "MacBook Pro")
///
/// TXT record contains:
/// - `version`: API version (e.g., "1.0")
/// - `name`: Computer name for display
public class BonjourService: NSObject, @unchecked Sendable {
    private var netService: NetService?
    private var port: UInt16
    private let serviceName: String
    private let serviceType: String
    public var isRunning = false
    private let logger: any HTTPLogging

    /// HTTPServer can fall back to a different port (8081 / ephemeral) if
    /// the configured one is in use; APIServer.start syncs that port here
    /// before publishing Bonjour so the advertised port is correct.
    public func updatePort(_ newPort: UInt16) {
        port = newPort
    }

    /// Service type for Agent07 HTTP API
    public static let defaultServiceType = "_agent07._tcp."

    /// API version advertised in TXT record
    private static let apiVersion = "1.0"

    public init(
        port: UInt16 = 8080,
        serviceName: String? = nil,
        serviceType: String = BonjourService.defaultServiceType,
        logger: any HTTPLogging
    ) {
        self.port = port
        self.serviceName = serviceName ?? ProcessInfo.processInfo.hostName
        self.serviceType = serviceType
        self.logger = logger
        super.init()
    }

    // MARK: - Start/Stop

    /// Start advertising the service on the local network.
    ///
    /// Creates a NetService instance and publishes it with a TXT record containing
    /// API version and device name. The service will be discoverable by iOS clients
    /// using NSDNSServiceBrowser.
    ///
    /// - Throws: Does not throw - errors are logged via delegate callbacks
    public func start() {
        guard !isRunning else {
            logger.log("Bonjour service already running", source: "Bonjour")
            return
        }

        // Create NetService with domain (empty string = default .local domain)
        netService = NetService(
            domain: "",
            type: serviceType,
            name: serviceName,
            port: Int32(port)
        )

        guard let netService else {
            logger.log("Failed to create NetService", source: "Error")
            return
        }

        netService.delegate = self

        // Build TXT record with metadata
        let txtRecord = buildTXTRecord()
        netService.setTXTRecord(txtRecord)

        // Advertise only (no [.listenForConnections]). HTTPServer owns the
        // port via NWListener — asking NetService to also listen makes it
        // bind to the same port and fail with POSIX EADDRINUSE
        // (errorCode 48, errorDomain 1 in didNotPublish). We use Bonjour
        // for mDNS service discovery, not as a stream delegate, so
        // .listenForConnections is unnecessary and racy.
        netService.publish()

        logger.log(
            "Bonjour service starting: \(serviceName) on port \(port) (type: \(serviceType))",
            source: "Bonjour"
        )
    }

    /// Stop advertising the service.
    ///
    /// Unpublishes the NetService and releases resources.
    public func stop() {
        guard isRunning else { return }

        netService?.stop()
        netService?.delegate = nil
        netService = nil
        isRunning = false

        logger.log("Bonjour service stopped", source: "Bonjour")
    }

    // MARK: - TXT Record

    /// Build TXT record data with API metadata.
    ///
    /// TXT record format (key=value pairs):
    /// - `version`: API version string
    /// - `name`: Human-readable device name
    ///
    /// - Returns: Encoded TXT record data suitable for NetService.setTXTRecord()
    private func buildTXTRecord() -> Data {
        let txtDict: [String: Data] = [
            "version": Data(Self.apiVersion.utf8),
            "name": Data(serviceName.utf8),
            "platform": Data("macOS".utf8)
        ]
        return NetService.data(fromTXTRecord: txtDict)
    }
}

// MARK: - NetServiceDelegate

extension BonjourService: NetServiceDelegate {

    public func netServiceDidPublish(_ sender: NetService) {
        isRunning = true
        logger.log(
            "Bonjour service published successfully: \(sender.name) (\(sender.type))",
            source: "Bonjour"
        )
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        isRunning = false
        let errorCode = errorDict[NetService.errorCode] ?? -1
        let errorDomain = errorDict[NetService.errorDomain] ?? -1
        // mDNS frequently retries publishing after a transient name/port
        // collision and succeeds via auto-rename, so this is logged as a
        // warning rather than a fatal error. Real failures are surfaced
        // by the HTTP listener throwing from APIServer.start().
        logger.log(
            "Bonjour service failed to publish - code: \(errorCode), domain: \(errorDomain) (will retry)",
            source: "Warning"
        )
    }

    public func netServiceDidStop(_ sender: NetService) {
        isRunning = false
        logger.log("Bonjour service stopped: \(sender.name)", source: "Bonjour")
    }

    public func netService(_ sender: NetService, didAcceptConnectionWith inputStream: InputStream, outputStream: OutputStream) {
        // Not used - HTTP server handles connections directly via NWListener
        // This delegate method is here for completeness but won't be called
        // because we're advertising an HTTP server, not handling streams via Bonjour
        logger.log("Bonjour connection accepted (unexpected - HTTP handles connections)", source: "Bonjour")
    }
}
