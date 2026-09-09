import XCTest
@testable import Sila

/// "Network problem: cancelled" was a screen telling somebody about a request
/// the app itself abandoned (a newer load superseded it, or the screen went
/// away). A cancellation is not a problem and never becomes a message.
final class CancellationErrorTests: XCTestCase {

    func testURLErrorCancelledWrapsAsACancellation() {
        let wrapped = APIError.wrapping(URLError(.cancelled))
        XCTAssertTrue(wrapped.isCancellation)
        XCTAssertNil(wrapped.presentableMessage)
    }

    func testSwiftCancellationWrapsAsACancellation() {
        let wrapped = APIError.wrapping(CancellationError())
        XCTAssertTrue(wrapped.isCancellation)
        XCTAssertNil(wrapped.presentableMessage)
    }

    func testAnOldTransportCancelledStringStillCountsAsACancellation() {
        XCTAssertTrue(APIError.transport("cancelled").isCancellation)
        XCTAssertTrue(APIError.transport("Cancelled").isCancellation)
    }

    func testARealTransportFailureIsStillPresented() {
        let wrapped = APIError.wrapping(URLError(.notConnectedToInternet))
        XCTAssertFalse(wrapped.isCancellation)
        XCTAssertNotNil(wrapped.presentableMessage)
        XCTAssertEqual(wrapped.presentableMessage, wrapped.userMessage)
    }

    func testToastForACancellationIsNothing() {
        XCTAssertNil(SLToastMessage.error(for: URLError(.cancelled)))
        XCTAssertNil(SLToastMessage.error(for: CancellationError()))
    }

    func testToastForAFailureCarriesTheUserMessage() {
        let toast = SLToastMessage.error(for: URLError(.timedOut))
        XCTAssertEqual(toast?.text, APIError.wrapping(URLError(.timedOut)).userMessage)
    }

    func testTheCancelledCaseNeverReadsLikeANetworkProblem() {
        XCTAssertFalse(APIError.cancelled.userMessage.lowercased().contains("cancel"))
    }
}
