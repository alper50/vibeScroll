import CryptoKit
import Foundation

/// Signs a request so the backend can tell a vibeScroll client from anything
/// else pointed at it.
///
/// **This is a turnstile, not a lock, and it is worth being plain about that.**
/// The secret ships inside a downloadable app, so anybody willing to run
/// `strings` on the binary has it. What it buys is that the endpoint stops
/// being interesting to casual traffic and to scrapers, and that every request
/// carries a client version worth logging. The content behind it is public
/// teaching cards; there is nothing here that would justify pretending this is
/// a security boundary.
///
/// It is still better than the flat API-key header this replaces, for two
/// reasons that are both about accidents rather than attackers: a captured
/// request stops working within minutes, and the secret itself never crosses
/// the wire where a proxy log or a shared HAR file could pick it up.
///
/// Pure and `now`-injected, like the rest of Core, and pinned to the server's
/// implementation by a shared test vector rather than by prose.
public enum ClientSignature {
    public static let timestampHeader = "X-VibeScroll-Timestamp"
    public static let signatureHeader = "X-VibeScroll-Signature"
    public static let clientHeader = "X-VibeScroll-Client"

    /// The exact bytes both sides sign.
    ///
    /// The query string is deliberately excluded. It carries no authority —
    /// every parameter is validated on its own terms server-side — and
    /// including it would make the two implementations agree about
    /// percent-encoding, which is a pointless way to break a client.
    public static func signingString(timestamp: Int, path: String) -> String {
        "\(timestamp)\n\(path)"
    }

    public static func signature(secret: String, timestamp: Int, path: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(signingString(timestamp: timestamp, path: path).utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// Headers for one request, or nothing at all when no secret is configured.
    ///
    /// Empty rather than absent-with-an-error: a build with no secret is the
    /// local-development case, and the server treats unsigned requests as fine
    /// unless it has been given secrets of its own. The two defaults line up so
    /// that running both halves straight out of the repository just works.
    public static func headers(
        secret: String?, path: String, client: String, now: Date
    ) -> [String: String] {
        guard let secret, !secret.isEmpty else { return [:] }
        let timestamp = Int(now.timeIntervalSince1970)
        return [
            timestampHeader: String(timestamp),
            signatureHeader: signature(secret: secret, timestamp: timestamp, path: path),
            clientHeader: client,
        ]
    }
}
