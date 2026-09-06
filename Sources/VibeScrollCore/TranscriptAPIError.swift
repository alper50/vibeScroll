import Foundation

/// An API failure the agent recorded in its transcript.
///
/// Claude Code writes these as
/// `{"type":"system","subtype":"api_error","level":"error","error":{"message":"429 {…}"},`
/// `"retryAttempt":3,"maxRetries":10,"retryInMs":8421}` — the HTTP status leads
/// the message string and the provider's own error object follows it as nested
/// JSON.
///
/// Parsing is pure and defensive: an entry it cannot read is dropped, never
/// guessed at. Misreading an overload as a rate limit would tell the user their
/// quota is gone when the server was merely busy.
public struct TranscriptAPIError: Equatable, Sendable {

    public enum Kind: Equatable, Sendable {
        /// Quota or rate limit — HTTP 429, or `rate_limit_error`.
        case rateLimit
        /// Provider is busy — HTTP 529, or `overloaded_error`. Transient.
        case overloaded
        /// Anything else, carrying whatever identifier was found.
        case other(String)
    }

    public let kind: Kind
    public let retryAttempt: Int
    public let maxRetries: Int

    public init(kind: Kind, retryAttempt: Int, maxRetries: Int) {
        self.kind = kind
        self.retryAttempt = retryAttempt
        self.maxRetries = maxRetries
    }

    /// True on the last attempt — the point at which the agent gives up and the
    /// turn actually fails. Earlier attempts usually recover on their own, so
    /// this is the only moment worth interrupting the user for.
    public var isFinalAttempt: Bool {
        maxRetries > 0 && retryAttempt >= maxRetries
    }

    /// Parses one decoded transcript line, or `nil` if it is not an API error.
    public static func parse(_ json: [String: Any]) -> TranscriptAPIError? {
        guard json["type"] as? String == "system",
              json["subtype"] as? String == "api_error" else { return nil }

        let message = errorMessage(from: json["error"])
        return TranscriptAPIError(
            kind: classify(message),
            retryAttempt: json["retryAttempt"] as? Int ?? 0,
            maxRetries: json["maxRetries"] as? Int ?? 0
        )
    }

    // MARK: - Private

    /// `error` is usually `{"message": "..."}` but may be a bare string.
    private static func errorMessage(from any: Any?) -> String {
        if let dict = any as? [String: Any], let message = dict["message"] as? String {
            return message
        }
        if let string = any as? String { return string }
        return ""
    }

    /// Classifies by the provider's error type first, falling back to the HTTP
    /// status. The type is authoritative; the status is what survives when the
    /// body is truncated or missing.
    static func classify(_ message: String) -> Kind {
        if let type = providerErrorType(in: message) {
            if type.contains("rate_limit") { return .rateLimit }
            if type.contains("overloaded") { return .overloaded }
            return .other(type)
        }
        switch leadingStatus(in: message) {
        case 429: return .rateLimit
        case 529: return .overloaded
        case let code?: return .other("http_\(code)")
        case nil: return .other("unknown")
        }
    }

    /// Digs out `error.type` from the JSON body embedded in the message.
    /// Parsed rather than pattern-matched: the outer envelope also has a
    /// `"type":"error"` key, and a naive match would return that instead.
    private static func providerErrorType(in message: String) -> String? {
        guard let start = message.firstIndex(of: "{") else { return nil }
        let body = String(message[start...])
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let type = error["type"] as? String else { return nil }
        return type
    }

    /// The HTTP status that leads the message, e.g. `"529 {…}"`.
    private static func leadingStatus(in message: String) -> Int? {
        let digits = message.prefix { $0.isNumber }
        guard digits.count == 3 else { return nil }
        return Int(digits)
    }
}
