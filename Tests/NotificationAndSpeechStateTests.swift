import ComposableArchitecture
import Foundation
@testable import GreminderKit
import XCTest

@MainActor
final class NotificationAndSpeechStateTests: XCTestCase {
    func testChangingUnloadedModelPreservesPersistedLanguage() async {
        let saved = LockIsolated<[SpeechPreferences]>([])
        let prepared = LockIsolated<[SpeechPreferences]>([])
        let gate = AsyncStream<Void>.makeStream()
        let store = TestStore(initialState: SpeechSettingsFeature.State()) { SpeechSettingsFeature() }
            withDependencies: {
                $0.uuid = .incrementing
                $0.speechSettings.load = { SpeechPreferences(model: .tiny, language: .english) }
                $0.speechSettings.save = { preferences in saved.withValue { $0.append(preferences) } }
                $0.speech.prepare = { _, preferences in
                    prepared.withValue { $0.append(preferences) }
                    for await _ in gate.stream {
                        break
                    }
                }
            }

        // Base is the initial default, but differs from the persisted Tiny selection.
        await store.send(.modelChanged(.base)) {
            $0.preferences = SpeechPreferences(model: .tiny, language: .english)
            $0.isLoaded = true
            $0.downloadingModel = .base
        }
        XCTAssertTrue(saved.value.isEmpty)
        gate.continuation.yield(())
        gate.continuation.finish()
        await store.receive(\.modelPrepared) {
            $0.downloadingModel = nil
            $0.preferences.model = .base
        }
        await store.finish()
        XCTAssertEqual(prepared.value, [SpeechPreferences(model: .base, language: .english)])
        XCTAssertEqual(saved.value, prepared.value)
    }

    func testChangingUnloadedLanguagePreservesPersistedModel() async {
        let saved = LockIsolated<[SpeechPreferences]>([])
        let store = TestStore(initialState: SpeechSettingsFeature.State()) { SpeechSettingsFeature() }
            withDependencies: {
                $0.speechSettings.load = { SpeechPreferences(model: .small, language: .english) }
                $0.speechSettings.save = { preferences in saved.withValue { $0.append(preferences) } }
            }

        await store.send(.languageChanged(.automatic)) {
            $0.preferences = SpeechPreferences(model: .small, language: .automatic)
            $0.isLoaded = true
        }
        XCTAssertEqual(saved.value, [SpeechPreferences(model: .small, language: .automatic)])
    }

    func testFailedSettingsReadNeverOverwritesStoredPreferences() async {
        let saved = LockIsolated<[SpeechPreferences]>([])
        let store = TestStore(initialState: SpeechSettingsFeature.State()) { SpeechSettingsFeature() }
            withDependencies: {
                $0.uuid = .incrementing
                $0.speechSettings.load = { throw AppFailure("Unreadable preferences") }
                $0.speechSettings.save = { preferences in saved.withValue { $0.append(preferences) } }
            }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.load)
        await store.send(.modelChanged(.largeV3Turbo))
        await store.send(.languageChanged(.automatic))
        XCTAssertTrue(saved.value.isEmpty)
        XCTAssertFalse(store.state.isLoaded)
        XCTAssertEqual(store.state.preferences, SpeechPreferences())
        XCTAssertNotNil(store.state.error)

        store.dependencies.speechSettings.load = { SpeechPreferences(model: .tiny, language: .english) }
        store.dependencies.speech.prepare = { _, _ in }
        await store.send(.modelChanged(.small))
        await store.receive(\.modelPrepared)
        await store.finish()
        XCTAssertEqual(saved.value, [SpeechPreferences(model: .small, language: .english)])
        XCTAssertTrue(store.state.isLoaded)
        XCTAssertNil(store.state.error)
    }

    func testNotificationSettingsSaveBeforeTasksAreAvailable() async {
        let saved = LockIsolated<[NotificationPreferences]>([])
        let clockDate = NotificationPlanner.date(day: TaskDay("2026-09-21")!, hour: 17, minute: 30)
        let store = TestStore(initialState: NotificationFeature.State(
            preferences: NotificationPreferences(enabled: true), isLoaded: true,
        )) { NotificationFeature() } withDependencies: {
            $0.date.now = clockDate
            $0.notifications.savePreferences = { preferences in
                saved.withValue { $0.append(preferences) }
                return NotificationReport(access: .authorized, scheduled: preferences.enabled ? 3 : 0)
            }
            $0.notifications.saveAndSchedule = { _, _ in
                XCTFail("An unknown task snapshot must not replace the OS schedule")
                return NotificationReport(access: .authorized)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.defaultTimeChanged(clockDate))
        await store.receive(\.synchronize)
        await store.receive(\.synchronized)
        XCTAssertEqual(saved.value.last?.hour, 17)
        XCTAssertEqual(saved.value.last?.minute, 30)
        XCTAssertEqual(store.state.report.scheduled, 3)

        await store.send(.setEnabled(false))
        await store.receive(\.synchronize)
        await store.receive(\.synchronized)
        XCTAssertEqual(saved.value.last?.enabled, false)
        XCTAssertEqual(store.state.report.scheduled, 0)
        await store.finish()
    }

    func testFirstTaskSnapshotWaitsForPendingPreferenceSave() async {
        let gate = AsyncStream<Void>.makeStream()
        let calls = LockIsolated<[String]>([])
        let store = TestStore(initialState: NotificationFeature.State(isLoaded: true)) {
            NotificationFeature()
        } withDependencies: {
            $0.date.now = Date(timeIntervalSince1970: 0)
            $0.notifications.savePreferences = { _ in
                calls.withValue { $0.append("preferences") }
                for await _ in gate.stream {
                    break
                }
                return NotificationReport(access: .authorized, scheduled: 3)
            }
            $0.notifications.saveAndSchedule = { _, requests in
                calls.withValue { $0.append("snapshot:\(requests.count)") }
                return NotificationReport(access: .authorized, scheduled: requests.count)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.synchronize)
        await store.send(.tasksUpdated(TaskSnapshot(), nil, reviewOverdue: false))
        XCTAssertEqual(calls.value, ["preferences"])
        gate.continuation.yield(())
        gate.continuation.finish()
        await store.receive(\.synchronized)
        await store.receive(\.synchronize)
        await store.receive(\.synchronized)
        await store.finish()
        XCTAssertEqual(calls.value, ["preferences", "snapshot:0"])
        XCTAssertEqual(store.state.report.scheduled, 0)
        XCTAssertFalse(store.state.isSynchronizing)
        XCTAssertFalse(store.state.needsSynchronization)
    }

    func testBulkEditsBlockOlderSynchronizationUntilLatestRecordsAreSaved() async {
        let day = TaskDay("2026-09-21")!
        let task = ReminderTask(id: "shared", remoteID: "remote", listID: "work", title: "Shared", due: day)
        let date = NotificationPlanner.date(day: day, hour: 18, minute: 15)
        let saved = LockIsolated<[NotificationPreferences]>([])
        let store = TestStore(initialState: NotificationFeature.State(
            preferences: NotificationPreferences(enabled: true), hasTasks: true, isLoaded: true,
            revision: 4, isSynchronizing: true,
        )) { NotificationFeature() } withDependencies: {
            $0.date.now = Date(timeIntervalSince1970: 0)
            $0.notifications.saveAndSchedule = { preferences, requests in
                saved.withValue { $0.append(preferences) }
                return NotificationReport(access: .authorized, scheduled: requests.count)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.tasksUpdated(
            TaskSnapshot(tasks: [task]), nil, reviewOverdue: false,
            edits: [task.id: TaskNotificationEdit(date: date, enabled: false)],
        ))
        XCTAssertTrue(store.state.needsSynchronization)
        XCTAssertEqual(store.state.record(for: task), NotificationRecord(date: date, sourceDay: day, isEnabled: false))
        await store.send(.synchronized(4, .success(NotificationReport(access: .authorized, scheduled: 7))))
        XCTAssertNotEqual(store.state.report.scheduled, 7)
        await store.receive(\.synchronize)
        await store.receive(\.synchronized)
        await store.finish()
        XCTAssertEqual(saved.value.count, 1)
        XCTAssertEqual(saved.value[0].records.values.first?.date, date)
        XCTAssertEqual(saved.value[0].records.values.first?.isEnabled, false)
        XCTAssertEqual(store.state.report.scheduled, 0)
    }
}
