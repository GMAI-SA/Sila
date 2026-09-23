import EventKit
import SwiftUI

// MARK: - Remind me

/// How a scheduled room's reminder is set, from wherever the room is drawn.
public struct RoomReminderActions {
    public var toggle: @MainActor (_ room: VoiceRoom, _ on: Bool) async throws -> RoomReminder
    public var openSeries: (@MainActor (UUID) -> Void)?

    public init(toggle: @escaping @MainActor (_ room: VoiceRoom, _ on: Bool) async throws -> RoomReminder,
                openSeries: (@MainActor (UUID) -> Void)? = nil) {
        self.toggle = toggle
        self.openSeries = openSeries
    }
}

private struct RoomReminderActionsKey: EnvironmentKey {
    static let defaultValue: RoomReminderActions? = nil
}

extension EnvironmentValues {
    public var roomReminders: RoomReminderActions? {
        get { self[RoomReminderActionsKey.self] }
        set { self[RoomReminderActionsKey.self] = newValue }
    }
}

/// Puts a scheduled room in the person's calendar. Write-only access: Sila
/// never reads anybody's calendar.
public enum RoomCalendar {
    public enum Outcome: Equatable { case added, denied, failed }

    public static func add(_ room: VoiceRoom, store: EKEventStore = EKEventStore()) async -> Outcome {
        guard let start = room.scheduledFor else { return .failed }
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestWriteOnlyAccessToEvents()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .event)) ?? false
        }
        guard granted else { return .denied }
        let event = EKEvent(eventStore: store)
        event.title = room.title
        event.startDate = start
        event.endDate = start.addingTimeInterval(60 * 60)
        event.url = Permalink.room(room.id)
        event.notes = L10n.t("rooms.calendar.notes")
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            return .added
        } catch {
            return .failed
        }
    }
}

/// "Remind me" and "Add to calendar" on a scheduled room.
@MainActor
public struct RemindMeButtons: View {
    private let room: VoiceRoom
    @Environment(\.roomReminders) private var actions
    @State private var reminderSet: Bool?
    @State private var count: Int?
    @State private var busy = false
    @State private var note: String?

    public init(room: VoiceRoom) {
        self.room = room
    }

    private var isSet: Bool { reminderSet ?? room.reminderSet }

    public var body: some View {
        if room.status == .scheduled, let actions {
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                HStack(spacing: SLSpacing.md) {
                    Button {
                        Task { await toggle(actions) }
                    } label: {
                        Label(L10n.t(isSet ? "rooms.remind.set" : "rooms.remind.action"),
                              systemImage: isSet ? "bell.fill" : "bell")
                            .font(SLFont.caption)
                            .foregroundStyle(isSet ? SLColor.secondary : SLColor.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityIdentifier("rooms.remind")

                    Button {
                        Task { await addToCalendar() }
                    } label: {
                        Label(L10n.t("rooms.calendar.add"), systemImage: "calendar.badge.plus")
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("rooms.calendar")

                    if let seriesId = room.seriesId, let open = actions.openSeries {
                        Button {
                            open(seriesId)
                        } label: {
                            Label(L10n.t("rooms.series.badge"), systemImage: "repeat")
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let shown = count ?? (room.reminderCount > 0 ? room.reminderCount : nil) {
                    Text(L10n.plural("rooms.remind.count", shown))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                }
                if let note {
                    Text(note).font(SLFont.micro).foregroundStyle(SLColor.textSecondary)
                }
            }
        }
    }

    private func toggle(_ actions: RoomReminderActions) async {
        busy = true
        defer { busy = false }
        do {
            let answer = try await actions.toggle(room, !isSet)
            reminderSet = answer.reminderSet
            count = answer.reminderCount
            note = nil
        } catch {
            note = APIError.wrapping(error).presentableMessage
        }
    }

    private func addToCalendar() async {
        switch await RoomCalendar.add(room) {
        case .added: note = L10n.t("rooms.calendar.added")
        case .denied: note = L10n.t("rooms.calendar.denied")
        case .failed: note = L10n.t("rooms.calendar.failed")
        }
    }
}

// MARK: - Weekly series

@MainActor
@Observable
public final class RoomSeriesViewModel {
    public private(set) var series: RoomSeries?
    public private(set) var isLoading = false
    public private(set) var error: String?
    public private(set) var stopped = false
    private let id: UUID
    private let service: RoomEngagementServiceProtocol

    public init(id: UUID, service: RoomEngagementServiceProtocol) {
        self.id = id
        self.service = service
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do { series = try await service.fetchSeries(id) } catch { self.error = APIError.wrapping(error).presentableMessage }
    }

    public func toggleFollow() async {
        guard let series else { return }
        do { self.series = try await service.setFollowingSeries(!series.following, seriesId: id) }
        catch { self.error = APIError.wrapping(error).presentableMessage }
    }

    public func stop() async {
        do {
            try await service.stopSeries(id)
            stopped = true
        } catch { self.error = APIError.wrapping(error).presentableMessage }
    }
}

/// A weekly room: when it happens, who follows it, and a standing reminder.
@MainActor
public struct RoomSeriesSheet: View {
    @Bindable private var viewModel: RoomSeriesViewModel
    private let onClose: @MainActor () -> Void

    public init(viewModel: RoomSeriesViewModel, onClose: @escaping @MainActor () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                if let series = viewModel.series {
                    Text(series.title).font(SLFont.displayM).foregroundStyle(SLColor.textPrimary)
                    Label(series.scheduleLine, systemImage: "repeat").font(SLFont.body)
                    if let question = series.starterQuestion {
                        Label(question, systemImage: "questionmark.bubble").font(SLFont.caption)
                    }
                    if let next = series.nextAt {
                        Text(L10n.t("rooms.series.next", SLFormat.dateTime(next)))
                            .font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                    }
                    Text(L10n.plural("rooms.series.followers", series.followerCount))
                        .font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                    if viewModel.stopped || series.ended {
                        Text(L10n.t("rooms.series.stopped")).font(SLFont.caption).foregroundStyle(SLColor.warning)
                    } else if series.isHost {
                        SLButton(L10n.t("rooms.series.stop"), variant: .destructive) { Task { await viewModel.stop() } }
                    } else {
                        SLButton(L10n.t(series.following ? "rooms.series.unfollow" : "rooms.series.follow"),
                                 variant: series.following ? .secondary : .primary) {
                            Task { await viewModel.toggleFollow() }
                        }
                        Text(L10n.t("rooms.series.followHint")).font(SLFont.micro).foregroundStyle(SLColor.textMuted)
                    }
                } else if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error = viewModel.error {
                    Text(error).font(SLFont.caption).foregroundStyle(SLColor.danger)
                }
                Spacer()
            }
            .padding(SLSpacing.lg)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("rooms.series.title"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(L10n.t("common.done")) { onClose() } }
            }
            .task { await viewModel.load() }
        }
        .tint(SLColor.primary)
        .presentationDetents([.medium])
    }
}

// MARK: - Question of the week

/// The card at the top of For You while a weekly question is live.
@MainActor
public struct PromptCard: View {
    private let prompt: WeeklyPrompt
    private let onAnswer: @MainActor () -> Void
    private let onOpenTag: @MainActor () -> Void

    public init(prompt: WeeklyPrompt, onAnswer: @escaping @MainActor () -> Void, onOpenTag: @escaping @MainActor () -> Void) {
        self.prompt = prompt
        self.onAnswer = onAnswer
        self.onOpenTag = onOpenTag
    }

    public var body: some View {
        SLCard {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Label(L10n.t("prompt.eyebrow"), systemImage: "questionmark.bubble.fill")
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.warning)
                Text(prompt.localizedTitle())
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: prompt.localizedTitle()))
                if let body = prompt.localizedBody() {
                    Text(body).font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: SLSpacing.md) {
                    SLButton(L10n.t(answerKey), size: .compact) { onAnswer() }
                        .frame(maxWidth: 180)
                        .accessibilityIdentifier("prompt.answer")
                    Button(prompt.tag) { onOpenTag() }
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.primary)
                    Spacer(minLength: 0)
                    if prompt.responseCount > 0 {
                        Text(L10n.plural("prompt.responses", prompt.responseCount))
                            .font(SLFont.micro).foregroundStyle(SLColor.textMuted)
                    }
                }
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.sm)
        .accessibilityElement(children: .contain)
    }

    private var answerKey: String {
        switch prompt.kind {
        case .text: return "prompt.answer.text"
        case .poll: return "prompt.answer.poll"
        case .voice: return "prompt.answer.voice"
        case .room: return "prompt.answer.room"
        }
    }
}

// MARK: - Push settings

/// "On your phone": which kinds push, and quiet hours.
@MainActor
struct PushSettingsSection: View {
    @Bindable var viewModel: NotificationSettingsViewModel

    var body: some View {
        if !viewModel.pushSections.isEmpty {
            VStack(alignment: .leading, spacing: SLSpacing.md) {
                Text(L10n.t("notifications.push.title"))
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .padding(.top, SLSpacing.lg)
                Text(L10n.t("notifications.push.explanation"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(viewModel.pushSections) { group in
                    Text(group.title)
                        .font(SLFont.micro)
                        .tracking(0.8)
                        .foregroundStyle(SLColor.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.kinds, id: \.self) { key in
                        Toggle(isOn: Binding(
                            get: { viewModel.isPushOn(key) },
                            set: { value in Task { await viewModel.setPush(value, key: key) } }
                        )) {
                            Text(NotificationSettingRow(key: key).pushTitle)
                                .font(SLFont.body)
                                .foregroundStyle(SLColor.textPrimary)
                        }
                        .tint(SLColor.primary)
                        .accessibilityIdentifier("notifications.push.\(key)")
                    }
                }

                quietHours
            }
        }
    }

    @ViewBuilder
    private var quietHours: some View {
        Toggle(isOn: Binding(
            get: { viewModel.quietHours != nil },
            set: { on in
                Task { await viewModel.setQuietHours(on ? QuietHours(startMin: 22 * 60, endMin: 7 * 60) : nil) }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("notifications.quiet.title")).font(SLFont.body).foregroundStyle(SLColor.textPrimary)
                Text(L10n.t("notifications.quiet.detail")).font(SLFont.micro).foregroundStyle(SLColor.textMuted)
            }
        }
        .tint(SLColor.primary)
        .accessibilityIdentifier("notifications.quiet")

        if let hours = viewModel.quietHours {
            HStack {
                DatePicker(L10n.t("notifications.quiet.from"), selection: Binding(
                    get: { NotificationSettingsViewModel.date(minutes: hours.startMin) },
                    set: { date in
                        Task { await viewModel.setQuietHours(QuietHours(
                            startMin: NotificationSettingsViewModel.minutes(of: date), endMin: hours.endMin)) }
                    }
                ), displayedComponents: .hourAndMinute)
                DatePicker(L10n.t("notifications.quiet.until"), selection: Binding(
                    get: { NotificationSettingsViewModel.date(minutes: hours.endMin) },
                    set: { date in
                        Task { await viewModel.setQuietHours(QuietHours(
                            startMin: hours.startMin, endMin: NotificationSettingsViewModel.minutes(of: date))) }
                    }
                ), displayedComponents: .hourAndMinute)
            }
            .font(SLFont.caption)
        }
    }
}

extension NotificationSettingRow {
    /// A push-only kind (a message) has no in-app switch, so no copy there.
    var pushTitle: String { key == "message" ? L10n.t("notifications.push.message") : title }
}
