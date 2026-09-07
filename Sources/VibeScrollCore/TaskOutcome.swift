import Foundation

/// What one agent run reported about itself, read from `--output-format json`.
public struct AgentRunResult: Equatable, Sendable {
    public let isError: Bool
    public let subtype: String?
    /// HTTP status of the API failure that ended the run, when one did. This is
    /// where a rate limit shows up.
    public let apiErrorStatus: Int?
    public let stopReason: String?
    public let sessionId: String?
    public let costUSD: Double?
    public let inputTokens: Int
    public let outputTokens: Int
    /// The agent's closing text — the one-line summary worth showing.
    public let text: String?

    public init(
        isError: Bool, subtype: String? = nil, apiErrorStatus: Int? = nil,
        stopReason: String? = nil, sessionId: String? = nil, costUSD: Double? = nil,
        inputTokens: Int = 0, outputTokens: Int = 0, text: String? = nil
    ) {
        self.isError = isError
        self.subtype = subtype
        self.apiErrorStatus = apiErrorStatus
        self.stopReason = stopReason
        self.sessionId = sessionId
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.text = text
    }
}

/// Turns a finished process into an outcome the queue can act on.
///
/// The result JSON is read in preference to the exit code because it says *why*
/// — and the only distinction that changes behaviour is whether the run failed
/// for a reason about the moment (a rate limit, worth another window) or a
/// reason about the task (worth a person).
public enum TaskOutcome {

    /// Anthropic's rate-limit status. A 529 overload is deliberately not
    /// included: it means the provider is busy, not that the quota is gone, and
    /// only a rate limit earns a retry under the queue's policy.
    static let rateLimitStatus = 429

    public static func parse(_ stdout: Data) -> AgentRunResult? {
        guard let json = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              json["type"] as? String == "result"
        else { return nil }
        let usage = json["usage"] as? [String: Any]
        return AgentRunResult(
            isError: json["is_error"] as? Bool ?? false,
            subtype: json["subtype"] as? String,
            apiErrorStatus: intValue(json["api_error_status"]),
            stopReason: json["stop_reason"] as? String,
            sessionId: json["session_id"] as? String,
            costUSD: json["total_cost_usd"] as? Double,
            inputTokens: intValue(usage?["input_tokens"]) ?? 0,
            outputTokens: intValue(usage?["output_tokens"]) ?? 0,
            text: json["result"] as? String)
    }

    /// Classifies a finished run. `nil` failure means it succeeded.
    public static func classify(
        exitCode: Int32?, stdout: Data, timedOut: Bool
    ) -> (failure: QueuedTask.Failure?, result: AgentRunResult?) {
        let result = parse(stdout)

        // Checked first: a killed process may still have flushed a partial
        // result, and what it managed to say does not change why it ended.
        if timedOut { return (.timedOut, result) }

        guard let result else {
            // Exit 0 with nothing readable on stdout is its own problem, and
            // calling it a non-zero exit would send somebody looking at the
            // wrong thing.
            return (exitCode == 0 ? .unreadableResult : .nonZeroExit, nil)
        }
        if result.apiErrorStatus == rateLimitStatus { return (.rateLimit, result) }
        if result.isError || result.subtype != "success" { return (.agentError, result) }
        if let exitCode, exitCode != 0 { return (.nonZeroExit, result) }
        return (nil, result)
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d.rounded()) }
        return nil
    }
}
