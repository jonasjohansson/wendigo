import Foundation
import Network
import Security
import OSLog

private let logger = Logger(subsystem: "wendigo", category: "TLS")

struct TLSConfig {
    let p12Data: Data
    let password: String
}

enum TLSSupport {
    /// Default location for the Wendigo self-signed identity.
    /// Generate with `./gen-cert.sh` at the repo root.
    static var defaultIdentityURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Wendigo", isDirectory: true).appendingPathComponent("identity.p12")
    }

    static func loadConfigIfAvailable(password: String = "wendigo") -> TLSConfig? {
        let url = defaultIdentityURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.info("No TLS identity at \(url.path, privacy: .public); run ./gen-cert.sh to create one.")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return TLSConfig(p12Data: data, password: password)
        } catch {
            logger.error("Failed to read TLS identity: \(error)")
            return nil
        }
    }

    /// Build NWProtocolTLS.Options from a PKCS#12 identity blob.
    /// Returns nil if the identity can't be imported (wrong password, malformed, etc.).
    static func makeTLSOptions(from config: TLSConfig) -> NWProtocolTLS.Options? {
        let opts: [String: Any] = [kSecImportExportPassphrase as String: config.password]
        var items: CFArray?
        let status = SecPKCS12Import(config.p12Data as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityItem = first[kSecImportItemIdentity as String]
        else {
            logger.error("SecPKCS12Import failed: OSStatus \(status)")
            return nil
        }
        let identity = identityItem as! SecIdentity
        guard let secIdentity = sec_identity_create(identity) else {
            logger.error("sec_identity_create returned nil")
            return nil
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        return tls
    }
}
