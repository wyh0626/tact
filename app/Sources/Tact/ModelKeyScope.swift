import CryptoKit
import Foundation

/// API keys belong to a connection, not to whichever endpoint happens to be
/// selected next. The account name contains a digest of non-secret settings.
enum ModelKeyScope {
    static func account(provider: String, protocol protocolID: String, baseURL: String) -> String {
        let identity = [provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        protocolID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                        origin(of: baseURL) ?? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)]
        // Length prefixes keep each component unambiguous, including invalid
        // URLs or provider names that contain punctuation.
        let data = Data(identity.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(Keychain.modelKey)-\(digest)"
    }

    /// A different route on the same provider and protocol shares its key.
    /// Normalizing default ports avoids duplicate entries for the same origin.
    static func origin(of baseURL: String) -> String? {
        guard let parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        if let port = parts.port, !((scheme == "http" && port == 80) || (scheme == "https" && port == 443)) {
            origin.port = port
        }
        return origin.string
    }
}
