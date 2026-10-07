import XCTest
@testable import CodexerCore

final class AgentDockPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AgentDockPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPreferencesPersistAndRestoreAutomaticallySupportedValues() {
        let store = AgentDockPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.load(), .defaults)

        let expected = AgentDockPreferences(
            appearance: .dark,
            defaultView: .chats,
            refreshProfileActivity: false,
            refreshIntervalMinutes: 30,
            showStatusInProfileList: false
        )
        store.save(expected)
        XCTAssertEqual(store.load(), expected)

        store.restoreDefaults()
        XCTAssertEqual(store.load(), .defaults)
    }

    func testHomeIsTheDefaultAndExistingStartupChoicesRemainSupported() {
        let store = AgentDockPreferencesStore(defaults: defaults)
        XCTAssertEqual(store.load().defaultView, .home)
        for choice in AgentDockDefaultView.allCases {
            defaults.set(choice.rawValue, forKey: "AgentDock.defaultView")
            XCTAssertEqual(store.load().defaultView, choice)
        }
        store.restoreDefaults()
        XCTAssertEqual(store.load().defaultView, .home)
    }

    func testUnsupportedRefreshIntervalFallsBackToDefault() {
        let store = AgentDockPreferencesStore(defaults: defaults)
        var preferences = AgentDockPreferences.defaults
        preferences.refreshIntervalMinutes = 7
        store.save(preferences)

        XCTAssertEqual(
            store.load().refreshIntervalMinutes,
            AgentDockPreferences.defaults.refreshIntervalMinutes
        )
    }

    func testLegacyAppDefaultCanBeMigratedAndCleared() throws {
        defaults.set("cursor-bridge", forKey: "AgentDock.defaultCodexConfigProfile")
        let store = AgentDockPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.legacyDefaultCodexConfigProfile()?.name, "cursor-bridge")
        store.clearLegacyDefaultCodexConfigProfile()
        XCTAssertNil(store.legacyDefaultCodexConfigProfile())
    }

    func testOfficialCodexProviderSettingsPersistSeparately() throws {
        let store = AgentDockPreferencesStore(defaults: defaults)
        let ollama = try CodexConfigProfile(validating: "ollama")
        let expected = OfficialCodexProfileSettings(
            launchSelection: .named(ollama),
            defaultConfigProfile: ollama
        )

        store.saveOfficialCodexProfileSettings(expected)

        XCTAssertEqual(store.loadOfficialCodexProfileSettings(), expected)
        XCTAssertEqual(store.load(), .defaults)

        store.restoreDefaults()
        XCTAssertEqual(store.loadOfficialCodexProfileSettings(), .defaults)
    }
}
