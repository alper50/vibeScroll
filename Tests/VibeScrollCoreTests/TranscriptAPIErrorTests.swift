import XCTest
@testable import VibeScrollCore

final class TranscriptAPIErrorTests: XCTestCase {

    private func parse(_ json: String) -> TranscriptAPIError? {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        return obj.flatMap(TranscriptAPIError.parse)
    }

    /// The exact record shape found in a real transcript.
    private func record(status: String, type: String, attempt: Int, max: Int) -> String {
        """
        {"type":"system","subtype":"api_error","level":"error",
         "error":{"message":"\(status) {\\"type\\":\\"error\\",\\"error\\":{\\"type\\":\\"\(type)\\",\\"message\\":\\"m\\"},\\"request_id\\":\\"req_1\\"}"},
         "retryAttempt":\(attempt),"maxRetries":\(max),"retryInMs":8421,
         "sessionId":"s1","timestamp":"2026-09-06T15:00:00Z"}
        """
    }

    func testParsesTheRealOverloadedRecord() throws {
        let error = try XCTUnwrap(parse(record(status: "529", type: "overloaded_error",
                                               attempt: 3, max: 10)))
        XCTAssertEqual(error.kind, .overloaded)
        XCTAssertEqual(error.retryAttempt, 3)
        XCTAssertEqual(error.maxRetries, 10)
        XCTAssertFalse(error.isFinalAttempt)
    }

    func testParsesARateLimitRecord() throws {
        let error = try XCTUnwrap(parse(record(status: "429", type: "rate_limit_error",
                                               attempt: 10, max: 10)))
        XCTAssertEqual(error.kind, .rateLimit)
        XCTAssertTrue(error.isFinalAttempt, "the attempt the agent actually gives up on")
    }

    func testProviderTypeBeatsTheOuterEnvelope() {
        // The body's outer object also carries "type":"error"; a naive pattern
        // match would classify everything as `.other("error")`.
        XCTAssertEqual(
            TranscriptAPIError.classify(
                #"429 {"type":"error","error":{"type":"rate_limit_error","message":"m"}}"#),
            .rateLimit)
    }

    func testFallsBackToTheHTTPStatusWhenTheBodyIsMissing() {
        // A truncated or bodyless message still classifies correctly.
        XCTAssertEqual(TranscriptAPIError.classify("429"), .rateLimit)
        XCTAssertEqual(TranscriptAPIError.classify("529 "), .overloaded)
        XCTAssertEqual(TranscriptAPIError.classify("500 Internal"), .other("http_500"))
        XCTAssertEqual(TranscriptAPIError.classify(""), .other("unknown"))
    }

    func testAnUnrecognisedProviderTypeIsCarriedThroughNotGuessed() {
        // Misreporting an unknown failure as a rate limit would tell the user
        // their quota is gone when it is not.
        XCTAssertEqual(
            TranscriptAPIError.classify(
                #"400 {"type":"error","error":{"type":"invalid_request_error","message":"m"}}"#),
            .other("invalid_request_error"))
    }

    func testFinalAttemptNeedsARealRetryBudget() {
        // 0/0 is not "exhausted"; it means the record carried no retry fields.
        let noBudget = TranscriptAPIError(kind: .rateLimit, retryAttempt: 0, maxRetries: 0)
        XCTAssertFalse(noBudget.isFinalAttempt)
        XCTAssertTrue(TranscriptAPIError(kind: .rateLimit, retryAttempt: 10, maxRetries: 10)
            .isFinalAttempt)
    }

    func testNonErrorLinesAreIgnored() {
        XCTAssertNil(parse(#"{"type":"assistant","message":{"role":"assistant"}}"#))
        XCTAssertNil(parse(#"{"type":"system","subtype":"stop_hook_summary"}"#))
        XCTAssertNil(parse("{}"))
    }

    func testBareStringErrorIsAccepted() throws {
        let error = try XCTUnwrap(parse("""
        {"type":"system","subtype":"api_error","error":"429 too many requests",
         "retryAttempt":1,"maxRetries":10}
        """))
        XCTAssertEqual(error.kind, .rateLimit)
    }
}
