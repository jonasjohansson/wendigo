import Foundation
import OSLog

private let logger = Logger(subsystem: "wendigo", category: "CertManager")

enum CertManager {
    static let password = "wendigo"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Wendigo", isDirectory: true)
    }

    static var p12URL: URL { directory.appendingPathComponent("identity.p12") }
    static var certURL: URL { directory.appendingPathComponent("cert.pem") }
    static var keyURL: URL { directory.appendingPathComponent("key.pem") }

    struct Status {
        var exists: Bool
        var notAfter: Date?
        var subjectAltNames: [String]
        var isValid: Bool { exists && (notAfter.map { $0 > Date() } ?? false) }
    }

    static func currentStatus() -> Status {
        guard FileManager.default.fileExists(atPath: p12URL.path),
              FileManager.default.fileExists(atPath: certURL.path)
        else { return Status(exists: false, notAfter: nil, subjectAltNames: []) }

        // Parse cert.pem with openssl x509 for dates + SAN.
        let certPath = certURL.path
        let dates = runOpenSSL(args: ["x509", "-in", certPath, "-noout", "-enddate"]) ?? ""
        let sanOut = runOpenSSL(args: ["x509", "-in", certPath, "-noout", "-ext", "subjectAltName"]) ?? ""

        var notAfter: Date?
        if let range = dates.range(of: "notAfter=") {
            let dateStr = String(dates[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "MMM d HH:mm:ss yyyy zzz"
            notAfter = fmt.date(from: dateStr)
        }

        var sans: [String] = []
        for line in sanOut.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("DNS:") || trimmed.contains("IP") {
                for part in trimmed.split(separator: ",") {
                    sans.append(part.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        return Status(exists: true, notAfter: notAfter, subjectAltNames: sans)
    }

    /// Generate a new self-signed cert + key + PKCS#12 bundle covering localhost and
    /// all current non-loopback IPv4 interfaces. Idempotent — overwrites any prior identity.
    static func generate() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ips = currentLocalIPv4s()
        var sanParts = ["DNS:localhost", "IP:127.0.0.1"]
        for ip in ips { sanParts.append("IP:\(ip)") }
        let sanLine = sanParts.joined(separator: ",")

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let configURL = tmp.appendingPathComponent("openssl.cnf")
        let configText = """
        [req]
        distinguished_name = dn
        x509_extensions = v3_req
        prompt = no

        [dn]
        CN = Wendigo Dev

        [v3_req]
        subjectAltName = \(sanLine)
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        """
        try configText.write(to: configURL, atomically: true, encoding: .utf8)

        let keyPath = tmp.appendingPathComponent("key.pem").path
        let certPath = tmp.appendingPathComponent("cert.pem").path

        logger.info("Generating self-signed cert with SAN \(sanLine, privacy: .public)")

        try runOrThrow(openSSLArgs: [
            "req", "-x509", "-nodes", "-newkey", "rsa:2048",
            "-keyout", keyPath,
            "-out", certPath,
            "-days", "825",
            "-config", configURL.path,
        ])

        try runOrThrow(openSSLArgs: [
            "pkcs12", "-export",
            "-inkey", keyPath,
            "-in", certPath,
            "-out", p12URL.path,
            "-name", "Wendigo Dev",
            "-passout", "pass:\(password)",
        ])

        // Also stash cert + key in the app support dir for later inspection / trust install.
        try? FileManager.default.removeItem(at: certURL)
        try? FileManager.default.removeItem(at: keyURL)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: certPath), to: certURL)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: keyPath), to: keyURL)
    }

    // MARK: helpers

    private static func runOpenSSL(args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            logger.error("openssl failed: \(error)")
            return nil
        }
    }

    private static func runOrThrow(openSSLArgs args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "CertManager", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "openssl \(args.first ?? "") failed: \(errStr)"
            ])
        }
    }

    private static func currentLocalIPv4s() -> [String] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }

        var result: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let f = ptr.pointee
            if let sa = f.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (f.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                               &hostBuf, socklen_t(hostBuf.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostBuf)
                    if !ip.hasPrefix("169.254.") { // skip link-local
                        result.append(ip)
                    }
                }
            }
            cursor = f.ifa_next
        }
        return result
    }
}
