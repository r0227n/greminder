import ComposableArchitecture
@testable import GreminderKit
import XCTest

@MainActor
final class LocalizationTests: XCTestCase {
    func testLegacyLanguagePreferenceMigratesWithoutChangingChoice() {
        let defaults = UserDefaults.inMemory
        defaults.set("en", forKey: "displayLanguage.v1")
        withDependencies { $0.defaultAppStorage = defaults } operation: {
            XCTAssertEqual(AppFeature.State().displayLanguage, .english)
            XCTAssertEqual(L10n.tr("新しいリスト"), "New List")
            XCTAssertEqual(defaults.string(forKey: L10n.preferenceKey), "en")
        }
    }

    func testBothBundledLanguagesAndReorderedArguments() {
        XCTAssertEqual(L10n.translate("新しいリスト", language: .english), "New List")
        XCTAssertEqual(L10n.translate("新しいリスト", language: .japanese), "新しいリスト")
        XCTAssertEqual(L10n.translate("%@件を%@", arguments: ["3", "Add"], language: .english), "Add tasks: 3")
        XCTAssertEqual(L10n.translate("%@件を%@", arguments: ["3", "追加"], language: .japanese), "3件を追加")
    }

    func testLanguageChoicePersistsWithoutChangingRecognitionLanguageOrDrafts() async {
        let defaults = UserDefaults.inMemory
        await withDependencies {
            $0.defaultAppStorage = defaults
        } operation: {
            var state = AppFeature.State()
            state.newListTitle = "Shopping"
            state.speechSettings.preferences.language = .japanese
            let store = TestStore(initialState: state) { AppFeature() }
            await store.send(.displayLanguageChanged(.english)) {
                $0.$displayLanguage.withLock { $0 = .english }
            }
            XCTAssertEqual(defaults.string(forKey: L10n.preferenceKey), "en")
            XCTAssertEqual(L10n.tr("新しいリスト"), "New List")
            XCTAssertEqual(AppFeature.State().displayLanguage, .english)
            XCTAssertEqual(store.state.speechSettings.preferences.language, .japanese)
            XCTAssertEqual(store.state.newListTitle, "Shopping")
        }
    }
}
