import Foundation
import VibeScrollCore

/// The shared secret used to sign catalogue requests, and the client label sent
/// alongside it.
///
/// The secret is XOR-obfuscated rather than stored as a string literal. That is
/// worth exactly what it sounds like: it keeps the value out of `strings` and
/// out of a casual grep of the bundle, and it delays somebody who is actually
/// looking by about a minute. See `ClientSignature` for why that is the right
/// amount of effort to spend here — the content being protected is public, and
/// the only thing at stake is bandwidth.
///
/// Empty by default, which means unsigned requests. That is the local setup
/// working out of the box: a server started with no `VIBESCROLL_SECRETS` does
/// not ask for a signature either.
enum BackendCredential {
    /// Regenerate both arrays with: `python3 scripts/make-secret.py <secret>`
    private static let cipher: [UInt8] = []
    private static let pad: [UInt8] = []

    static let secret: String? = {
        guard !cipher.isEmpty, cipher.count == pad.count else { return nil }
        return String(decoding: zip(cipher, pad).map(^), as: UTF8.self)
    }()

    /// Sent as `X-VibeScroll-Client`, so a deployed backend can see which
    /// versions are still in the field before retiring a secret.
    static let clientLabel: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "vibescroll/\(version ?? "dev")"
    }()

    /// Signing headers for `url`, or nothing when this build has no secret.
    static func headers(for url: URL, now: Date = Date()) -> [String: String] {
        ClientSignature.headers(
            secret: secret, path: url.path, client: clientLabel, now: now)
    }
}
