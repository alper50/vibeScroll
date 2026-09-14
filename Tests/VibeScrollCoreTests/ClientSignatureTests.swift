import XCTest
@testable import VibeScrollCore

final class ClientSignatureTests: XCTestCase {

    // Produced by the backend's own `sign()` in vibeScroll-backend/src/clientAuth.js.
    // The two implementations are pinned to this vector rather than to each
    // other's prose: a change on either side that breaks the agreement fails
    // here instead of failing silently in production, where a rejected refresh
    // is indistinguishable from no backend at all.
    private let secret = "test-secret"
    private let timestamp = 1_773_500_000
    private let path = "/v1/catalog"
    private let expected = "1d71fec2cd86dd919acaf70ad9f49557aacdbe06db8339eaa65a0bc3af784e87"

    func testMatchesTheServersImplementation() {
        XCTAssertEqual(
            ClientSignature.signature(secret: secret, timestamp: timestamp, path: path),
            expected)
    }

    func testTheSigningStringIsTheTwoFieldsAndNothingElse() {
        XCTAssertEqual(
            ClientSignature.signingString(timestamp: timestamp, path: path),
            "1773500000\n/v1/catalog")
    }

    func testEachInputChangesTheSignature() {
        let base = ClientSignature.signature(secret: secret, timestamp: timestamp, path: path)
        XCTAssertNotEqual(base, ClientSignature.signature(
            secret: "other", timestamp: timestamp, path: path))
        XCTAssertNotEqual(base, ClientSignature.signature(
            secret: secret, timestamp: timestamp + 1, path: path))
        XCTAssertNotEqual(base, ClientSignature.signature(
            secret: secret, timestamp: timestamp, path: "/v1/cards"))
    }

    func testASignatureIsLowercaseHexOfTheRightLength() {
        let hex = ClientSignature.signature(secret: secret, timestamp: timestamp, path: path)
        XCTAssertEqual(hex.count, 64)
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testNoSecretMeansNoHeaders() {
        // The local-development default on both sides: an unconfigured client
        // talking to an unconfigured server just works.
        let now = Date(timeIntervalSince1970: TimeInterval(timestamp))
        XCTAssertTrue(ClientSignature.headers(
            secret: nil, path: path, client: "vibescroll/1", now: now).isEmpty)
        XCTAssertTrue(ClientSignature.headers(
            secret: "", path: path, client: "vibescroll/1", now: now).isEmpty)
    }

    func testHeadersCarryTheTimestampThatWasSigned() {
        // The server recomputes the HMAC over the timestamp the client sent, so
        // a header set whose timestamp and signature disagree is rejected — and
        // would be, silently, on every single request.
        let now = Date(timeIntervalSince1970: TimeInterval(timestamp) + 0.75)
        let headers = ClientSignature.headers(
            secret: secret, path: path, client: "vibescroll/0.1.0", now: now)

        let sent = try? XCTUnwrap(headers[ClientSignature.timestampHeader])
        XCTAssertEqual(sent, String(timestamp), "fractional seconds must be truncated, not rounded")
        XCTAssertEqual(headers[ClientSignature.signatureHeader], expected)
        XCTAssertEqual(headers[ClientSignature.clientHeader], "vibescroll/0.1.0")
    }
}
