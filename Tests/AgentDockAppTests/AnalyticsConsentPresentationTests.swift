import XCTest
@testable import AgentDock

@MainActor
final class AnalyticsConsentPresentationTests: XCTestCase {
    func testConsentPromptRequiresConfigurationAndUndecidedState() {
        XCTAssertTrue(AnalyticsConsentView.shouldPresent(consent: .undecided, isConfigured: true))
        XCTAssertFalse(AnalyticsConsentView.shouldPresent(consent: .undecided, isConfigured: false))
        XCTAssertFalse(AnalyticsConsentView.shouldPresent(consent: .granted, isConfigured: true))
        XCTAssertFalse(AnalyticsConsentView.shouldPresent(consent: .denied, isConfigured: true))
    }
}
