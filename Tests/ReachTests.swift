import XCTest
@testable import Sila

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
}

final class ReachModelTests: XCTestCase {

    func testARoomCarriesItsStarterQuestionSeriesAndReminder() throws {
        let room = try decode(VoiceRoom.self, """
        {"id": "00000000-0000-4000-8000-000000000c01", "title": "Derby night", "status": "scheduled",
         "host": {"id": "00000000-0000-4000-8000-000000000101", "handle": "aziz", "display_name": "Aziz", "is_verified": true},
         "starter_question": "Who wins tonight?", "kind": "ama", "series_id": "00000000-0000-4000-8000-000000000c99",
         "reminder_set": true, "reminder_count": 7}
        """)
        XCTAssertEqual(room.starterQuestion, "Who wins tonight?")
        XCTAssertTrue(room.isAMA)
        XCTAssertNotNil(room.seriesId)
        XCTAssertTrue(room.reminderSet)
        let cleared = room.with(reminder: RoomReminder(roomId: room.id, reminderSet: false, reminderCount: 6))
        XCTAssertFalse(cleared.reminderSet)
        XCTAssertEqual(cleared.reminderCount, 6)
        XCTAssertEqual(cleared.with(metrics: RoomMetrics(), viewerLiked: true).starterQuestion, "Who wins tonight?",
                       "a copy carries the extras along")
    }

    func testASeriesRepeatsTheScheduledWeekdayAndHour() {
        let riyadh = TimeZone(identifier: "Asia/Riyadh")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = riyadh
        // Tuesday 2026-09-29 21:30 in Riyadh.
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 21, minute: 30))!
        let request = CreateSeriesRequest(title: "Football talk", topic: "sports", starterQuestion: nil,
                                          scope: .international, repeating: date, timeZone: riyadh)
        XCTAssertEqual(request.weekday, 1, "the server counts Monday as 0")
        XCTAssertEqual(request.localTime, "21:30")
        XCTAssertEqual(request.timezone, "Asia/Riyadh")
    }

    func testAPromptDecodesAndAnswersInTheReadersLanguage() throws {
        let prompt = try decode(WeeklyPrompt.self, """
        {"id": "00000000-0000-4000-8000-000000000d01", "title": "Predict tonight's score", "title_ar": "توقع نتيجة الليلة",
         "hashtag": "#SPLPredict", "kind": "poll", "live": true, "response_count": 3, "rhythm_key": "mon_poll"}
        """)
        XCTAssertEqual(prompt.kind, .poll)
        XCTAssertEqual(prompt.hashtag, "SPLPredict")
        XCTAssertEqual(prompt.localizedTitle("ar"), "توقع نتيجة الليلة")
        XCTAssertEqual(prompt.tag, "#SPLPredict")
    }

    func testAPrefillAddsItsHashtagOnce() {
        XCTAssertEqual(ComposerPrefill(hashtag: "WorkingOn").composedText, "#WorkingOn ")
        XCTAssertEqual(ComposerPrefill(text: "Which one?", hashtag: "#Poll").composedText, "Which one? #Poll")
        XCTAssertEqual(ComposerPrefill(text: "Already #poll", hashtag: "Poll").composedText, "Already #poll")
    }

    func testPushPreferencesAndQuietHoursDecode() throws {
        let prefs = try decode(FeedPreferences.self, """
        {"push": {"reply": true, "like": false, "message": true}, "quiet_hours": {"start_min": 1320, "end_min": 420},
         "timezone": "Asia/Riyadh"}
        """)
        XCTAssertEqual(prefs.push["reply"], true)
        XCTAssertEqual(prefs.quietHours, QuietHours(startMin: 1320, endMin: 420))
        var update = PreferencesUpdate()
        update.quietHours = QuietHours(startMin: 1320, endMin: 420)
        update.push = ["like": true]
        let json = String(decoding: try JSONCoding.encoder.encode(update), as: UTF8.self)
        XCTAssertTrue(json.contains(#""quiet_hours":{"#), json)
        XCTAssertTrue(json.contains(#""start_min":1320"#), json)
        XCTAssertTrue(json.contains(#""push":{"like":true}"#), json)
    }

    func testRoomLinksOpenInTheApp() {
        let id = UUID()
        XCTAssertEqual(DeepLink.parse(Permalink.room(id)), .room(id: id))
    }

    func testEveryPushKeyHasASentenceInBothLanguages() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Localizable", withExtension: "xcstrings")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sila/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: Any])
        for key in PushCopy.keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "\(key) missing")
            let locs = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertNotNil(locs["en"], "\(key) has no English")
            XCTAssertNotNil(locs["ar"], "\(key) has no Arabic")
        }
    }
}

@MainActor
final class PushRegistrarTests: XCTestCase {

    func testATokenIsRegisteredOnlyWhenSignedInAndWithdrawnOnSignOut() async {
        let service = PushServiceMock()
        var signedIn = false
        let registrar = PushRegistrar(service: service, storage: InMemoryStorageClient(),
                                      analytics: RecordingAnalyticsClient(), isSignedIn: { signedIn }, center: nil)
        await registrar.didRegister(deviceToken: Data([0xAB, 0x01]))
        XCTAssertEqual(registrar.deviceToken, "ab01")
        XCTAssertTrue(service.registered.isEmpty, "a signed-out phone registered with nobody's account")

        signedIn = true
        await registrar.didRegister(deviceToken: Data([0xAB, 0x01]))
        XCTAssertEqual(service.registered.first?.token, "ab01")
        XCTAssertEqual(service.registered.first?.environment, "sandbox")

        await registrar.willSignOut()
        XCTAssertEqual(service.unregistered, ["ab01"])
    }

    func testATappedPushOpensItsLinkAndIsMarkedOpened() async {
        let service = PushServiceMock()
        let registrar = PushRegistrar(service: service, storage: InMemoryStorageClient(),
                                      analytics: RecordingAnalyticsClient(), isSignedIn: { true }, center: nil)
        var opened: DeepLink?
        registrar.openLink = { opened = $0 }
        let id = UUID()
        await registrar.handleTap(userInfo: ["url": "https://sila.gmai.sa/posts/\(id.uuidString.lowercased())",
                                             "kind": "reply", "push_id": "p-1"])
        XCTAssertEqual(opened, .post(id: id))
        XCTAssertEqual(service.opened, ["p-1"])
    }
}

@MainActor
final class ReachViewModelTests: XCTestCase {

    func testRemindingAddsTheRoomAndTheSeriesCanBeFollowed() async throws {
        let service = RoomEngagementServiceMock()
        let room = UUID()
        let reminder = try await service.setReminder(true, roomId: room)
        XCTAssertTrue(reminder.reminderSet)
        let series = try await service.createSeries(CreateSeriesRequest(title: "Tuesday", topic: nil, starterQuestion: nil,
                                                                        scope: .international, repeating: Date()))
        let viewModel = RoomSeriesViewModel(id: series.id, service: service)
        await viewModel.load()
        XCTAssertEqual(viewModel.series?.title, "Tuesday")
        await viewModel.toggleFollow()
        XCTAssertEqual(viewModel.series?.following, true)
    }

    func testPushSwitchesAndQuietHoursInSettings() async {
        let viewModel = NotificationSettingsViewModel(service: PreferencesServiceMock(scenario: .populated),
                                                      analytics: RecordingAnalyticsClient())
        await viewModel.load()
        await viewModel.setQuietHours(QuietHours(startMin: 600, endMin: 600))
        XCTAssertNil(viewModel.quietHours, "equal start and end is refused on the phone")
        XCTAssertEqual(NotificationSettingsViewModel.minutes(of: NotificationSettingsViewModel.date(minutes: 1290)), 1290)
    }

    func testAPromptStarterCarriesItsHashtag() async {
        let composer = ComposerViewModel(context: .newPost, author: ComposerAuthor(user: nil),
                                         composer: ComposerServiceMock(scenario: .success),
                                         analytics: RecordingAnalyticsClient())
        composer.use(ComposerStarter(id: "prompt:1", text: "What are you working on?", textAr: "على ماذا تعمل؟",
                                     kind: .text, hashtag: "WorkingOn"))
        XCTAssertTrue(composer.text(at: 0).hasSuffix("#WorkingOn"), composer.text(at: 0))
    }

    func testAPollPrefillOpensThePollEditor() {
        let composer = ComposerViewModel(context: .newPost, author: ComposerAuthor(user: nil),
                                         composer: ComposerServiceMock(scenario: .success),
                                         analytics: RecordingAnalyticsClient())
        composer.apply(ComposerPrefill(text: "Predict tonight", hashtag: "SPL", poll: true))
        XCTAssertNotNil(composer.poll)
        XCTAssertEqual(composer.text(at: 0), "Predict tonight #SPL")
    }

    func testTheHubLoadsTheLivePrompt() async {
        let hub = DiscoverHubViewModel(discover: DiscoverServiceMock(), rooms: RoomsServiceMock(scenario: .empty),
                                       preferences: PreferencesServiceMock(scenario: .populated), profile: nil,
                                       analytics: RecordingAnalyticsClient())
        await hub.loadPrompt()
        XCTAssertEqual(hub.prompt?.hashtag, "WorkingOn")
    }
}
