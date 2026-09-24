import EventKit
import SwiftUI

// MARK: - Rooms tab section

/// Events on the Rooms tab — not a new tab. This week first, then later.
@MainActor
struct EventsSection: View {
    @Bindable var viewModel: EventsViewModel
    let onOpen: @MainActor (SilaEvent) -> Void
    let onCreate: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            HStack {
                Text(L10n.t("events.section.title"))
                    .font(SLFont.micro).tracking(0.8).foregroundStyle(SLColor.textSecondary)
                Spacer(minLength: 0)
                if let onCreate {
                    Button(L10n.t("events.create.action"), action: onCreate)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.primary)
                        .accessibilityIdentifier("events.create")
                }
            }
            if viewModel.upcoming.isEmpty, viewModel.hasLoaded {
                Text(L10n.t("events.section.empty")).font(SLFont.caption).foregroundStyle(SLColor.textMuted)
            }
            if !viewModel.thisWeek.isEmpty {
                Text(L10n.t("events.section.thisWeek")).font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                ForEach(viewModel.thisWeek) { event in row(event) }
            }
            if !viewModel.later.isEmpty {
                Text(L10n.t("events.section.later")).font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                ForEach(viewModel.later) { event in row(event) }
            }
        }
        .task { if !viewModel.hasLoaded { await viewModel.load() } }
    }

    private func row(_ event: SilaEvent) -> some View {
        Button { onOpen(event) } label: { EventRow(event: event) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("events.row")
    }
}

struct EventRow: View {
    let event: SilaEvent

    var body: some View {
        SLCard(padding: SLSpacing.md) {
            HStack(alignment: .top, spacing: SLSpacing.md) {
                Image(systemName: event.kind.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(SLColor.primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(SLColor.primary.opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: event.title))
                    Text(event.whenLine).font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                    Text(event.whereLine).font(SLFont.micro).foregroundStyle(SLColor.textMuted)
                    if event.goingCount > 0 {
                        Text(L10n.plural("events.going.count", event.goingCount)).font(SLFont.micro).foregroundStyle(SLColor.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let rsvp = event.viewerRSVP {
                    Text(rsvp.title).font(SLFont.micro).foregroundStyle(SLColor.primary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

@MainActor
public struct EventDetailScreen: View {
    @Bindable var viewModel: EventDetailViewModel
    let onOpenRoom: (UUID) -> Void
    let onOpenProfile: (String) -> Void
    @State private var calendarNote: String?
    @State private var cohostHandle = ""
    @State private var inviteHandle = ""

    public var body: some View {
        ScrollView {
            if let event = viewModel.event {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    header(event)
                    if event.status == .cancelled {
                        Label(L10n.t("events.cancelled"), systemImage: "xmark.octagon")
                            .font(SLFont.bodyEmphasis).foregroundStyle(SLColor.danger)
                    } else if !event.isOver {
                        rsvp(event)
                    }
                    venue(event)
                    guests(event)
                    if event.canEdit { hostTools(event) }
                }
                .padding(SLSpacing.lg)
            } else if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(SLSpacing.xxl)
            }
        }
        .tnScreenBackground()
        .tnNavigationBar(title: L10n.t("events.detail.title"))
        .tnToast($viewModel.toast)
        .task { await viewModel.load() }
        .confirmationDialog(L10n.t("events.cancel.confirm"), isPresented: $viewModel.isConfirmingCancel, titleVisibility: .visible) {
            Button(L10n.t("events.cancel.action"), role: .destructive) { Task { await viewModel.cancel() } }
            Button(L10n.t("events.cancel.keep"), role: .cancel) {}
        }
    }

    private func header(_ event: SilaEvent) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            Label(event.kind.title, systemImage: event.kind.icon).font(SLFont.micro).foregroundStyle(SLColor.primary)
            Text(event.title)
                .font(SLFont.displayM).foregroundStyle(SLColor.textPrimary)
                .slContentDirection(TextDirection.resolve(languageCode: nil, text: event.title))
            Text(event.whenLine).font(SLFont.body).foregroundStyle(SLColor.textSecondary)
            if let host = event.host {
                Button { onOpenProfile(host.handle) } label: {
                    Text(L10n.t("events.hostedBy", host.displayName)).font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
            if let description = event.description {
                Text(description).font(SLFont.body).foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: description))
            }
        }
    }

    private func rsvp(_ event: SilaEvent) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            HStack(spacing: SLSpacing.sm) {
                ForEach(RSVPStatus.allCases) { status in
                    Button {
                        Task { await viewModel.answer(status) }
                    } label: {
                        Text(status.title)
                            .font(SLFont.caption)
                            .foregroundStyle(event.viewerRSVP == status ? .white : SLColor.textPrimary)
                            .padding(.horizontal, SLSpacing.md)
                            .padding(.vertical, SLSpacing.sm)
                            .background(Capsule().fill(event.viewerRSVP == status ? SLColor.primary : SLColor.surface1))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy || (status == .going && event.isFull && event.viewerRSVP != .going))
                    .accessibilityAddTraits(event.viewerRSVP == status ? .isSelected : [])
                    .accessibilityIdentifier("events.rsvp.\(status.rawValue)")
                }
            }
            HStack(spacing: SLSpacing.md) {
                Text(L10n.plural("events.going.count", event.goingCount))
                Text(L10n.plural("events.interested.count", event.interestedCount))
                if let cap = event.maxAttendees {
                    Text(event.isFull ? L10n.t("events.full") : L10n.t("events.capacity", SLFormat.number(cap)))
                }
            }
            .font(SLFont.micro).foregroundStyle(SLColor.textMuted)
            Button {
                Task { calendarNote = await EventCalendar.add(event) }
            } label: {
                Label(L10n.t("rooms.calendar.add"), systemImage: "calendar.badge.plus").font(SLFont.caption)
            }
            if let calendarNote {
                Text(calendarNote).font(SLFont.micro).foregroundStyle(SLColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func venue(_ event: SilaEvent) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            Text(L10n.t("events.venue.title")).font(SLFont.micro).tracking(0.8).foregroundStyle(SLColor.textSecondary)
            switch event.venueKind {
            case .room:
                if let roomId = event.roomId {
                    Button(L10n.t("events.venue.openRoom")) { onOpenRoom(roomId) }.font(SLFont.bodyEmphasis)
                } else {
                    Text(L10n.t("events.venue.onSila")).font(SLFont.body)
                }
            case .link:
                if let url = event.venueURL {
                    Link(url.host ?? url.absoluteString, destination: url).font(SLFont.bodyEmphasis)
                }
            case .place:
                Text(event.whereLine).font(SLFont.body)
            }
        }
    }

    private func guests(_ event: SilaEvent) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            Text(L10n.t("events.guests.title")).font(SLFont.micro).tracking(0.8).foregroundStyle(SLColor.textSecondary)
            if !event.cohosts.isEmpty {
                Text(L10n.t("events.cohosts", event.cohosts.map(\.displayName).joined(separator: "، ")))
                    .font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
            }
            if viewModel.going.isEmpty {
                Text(L10n.t("events.guests.empty")).font(SLFont.caption).foregroundStyle(SLColor.textMuted)
            }
            ForEach(viewModel.going, id: \.id) { user in
                Button { onOpenProfile(user.handle) } label: {
                    HStack {
                        SLAvatar(url: user.avatarURL, initials: user.initials, size: .sm, isVerified: user.isVerified,
                                 displayName: user.displayName)
                        Text(user.displayName).font(SLFont.body).foregroundStyle(SLColor.textPrimary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func hostTools(_ event: SilaEvent) -> some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("events.host.title")).font(SLFont.micro).tracking(0.8).foregroundStyle(SLColor.textSecondary)
            if !event.isInviteOnly {
                Button(L10n.t("events.share")) { Task { _ = await viewModel.share(text: nil) } }
            }
            HStack {
                TextField(L10n.t("events.invite.placeholder"), text: $inviteHandle).textFieldStyle(.roundedBorder)
                Button(L10n.t("events.invite.action")) {
                    let handle = inviteHandle
                    inviteHandle = ""
                    Task { await viewModel.invite([handle]) }
                }
                .disabled(inviteHandle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if event.isHost {
                HStack {
                    TextField(L10n.t("events.cohost.placeholder"), text: $cohostHandle).textFieldStyle(.roundedBorder)
                    Button(L10n.t("events.cohost.add")) {
                        let handle = cohostHandle
                        cohostHandle = ""
                        Task { await viewModel.addCohost(handle) }
                    }
                    .disabled(cohostHandle.trimmingCharacters(in: .whitespaces).isEmpty || event.cohosts.count >= 3)
                }
                ForEach(event.cohosts, id: \.id) { user in
                    HStack {
                        Text(user.displayName)
                        Spacer(minLength: 0)
                        Button(L10n.t("rooms.cohosts.remove"), role: .destructive) { Task { await viewModel.removeCohost(user.handle) } }
                    }
                    .font(SLFont.caption)
                }
                if !event.isOver {
                    Button(L10n.t("events.cancel.action"), role: .destructive) { viewModel.isConfirmingCancel = true }
                        .accessibilityIdentifier("events.cancel")
                }
            }
        }
        .font(SLFont.caption)
    }
}

enum EventCalendar {
    static func add(_ event: SilaEvent, store: EKEventStore = EKEventStore()) async -> String {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await store.requestWriteOnlyAccessToEvents()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .event)) ?? false
        }
        guard granted else { return L10n.t("rooms.calendar.denied") }
        let item = EKEvent(eventStore: store)
        item.title = event.title
        item.startDate = event.startsAt
        item.endDate = event.endsAt ?? event.startsAt.addingTimeInterval(3600)
        item.url = Permalink.event(event.id)
        item.location = event.venueKind == .place ? event.whereLine : nil
        item.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(item, span: .thisEvent)
            return L10n.t("rooms.calendar.added")
        } catch {
            return L10n.t("rooms.calendar.failed")
        }
    }
}

// MARK: - Create

@MainActor
public struct CreateEventSheet: View {
    @Bindable var viewModel: CreateEventViewModel
    let onClose: () -> Void

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.t("events.create.titleField"), text: $viewModel.title)
                        .accessibilityIdentifier("events.create.title")
                    TextField(L10n.t("events.create.description"), text: $viewModel.details, axis: .vertical)
                        .lineLimit(2...5)
                    Picker(L10n.t("events.create.kind"), selection: $viewModel.kind) {
                        ForEach(EventKind.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section(L10n.t("events.venue.title")) {
                    Picker(L10n.t("events.venue.title"), selection: $viewModel.venueKind) {
                        ForEach(EventVenueKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch viewModel.venueKind {
                    case .room: Text(L10n.t("events.create.roomHint")).font(SLFont.caption).foregroundStyle(SLColor.textMuted)
                    case .link:
                        TextField("https://", text: $viewModel.venueLink)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    case .place:
                        TextField(L10n.t("events.create.placeName.field"), text: $viewModel.venueName)
                        TextField(L10n.t("events.create.placeAddress"), text: $viewModel.venueAddress)
                        Text(L10n.t("events.create.placeHint")).font(SLFont.micro).foregroundStyle(SLColor.textMuted)
                    }
                }
                Section(L10n.t("events.create.when")) {
                    DatePicker(L10n.t("events.create.starts"), selection: $viewModel.startsAt, in: Date()...)
                    Toggle(L10n.t("events.create.hasEnd"), isOn: $viewModel.hasEnd)
                    if viewModel.hasEnd {
                        DatePicker(L10n.t("events.create.ends"), selection: $viewModel.endsAt, in: viewModel.startsAt...)
                    }
                }
                Section(L10n.t("events.create.who")) {
                    Toggle(L10n.t("events.create.inviteOnly"), isOn: $viewModel.isInviteOnly)
                    TextField(L10n.t("events.create.invites"), text: $viewModel.inviteText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle(L10n.t("events.create.hasCap"), isOn: $viewModel.hasCap)
                    if viewModel.hasCap {
                        Stepper(L10n.t("events.capacity", SLFormat.number(viewModel.cap)), value: $viewModel.cap, in: 2...5000, step: 5)
                    }
                }
                Section {
                    if let problem = viewModel.problem {
                        Text(problem).font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                    }
                    if let error = viewModel.error {
                        Text(error).font(SLFont.caption).foregroundStyle(SLColor.danger)
                    }
                    SLButton(L10n.t("events.create.submit"), isLoading: viewModel.isCreating, isEnabled: viewModel.canCreate) {
                        Task { if await viewModel.create() != nil { onClose() } }
                    }
                    .accessibilityIdentifier("events.create.submit")
                }
            }
            .scrollContentBackground(.hidden)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("events.create.title"))
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(L10n.t("common.cancel"), action: onClose) } }
        }
        .tint(SLColor.primary)
    }
}

// MARK: - Cards, badges, recap

/// An event shared on a timeline.
struct PostEventCard: View {
    let card: EventCard
    var onOpen: ((UUID) -> Void)?

    var body: some View {
        Button { onOpen?(card.id) } label: {
            HStack(spacing: SLSpacing.md) {
                Image(systemName: card.kind.icon).foregroundStyle(SLColor.primary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(SLFont.bodyEmphasis).foregroundStyle(SLColor.textPrimary)
                    Text(SLFormat.dateTime(card.startsAt)).font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                    if card.status == .cancelled {
                        Text(L10n.t("events.cancelled")).font(SLFont.micro).foregroundStyle(SLColor.danger)
                    } else if card.goingCount > 0 {
                        Text(L10n.plural("events.going.count", card.goingCount)).font(SLFont.micro).foregroundStyle(SLColor.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(SLSpacing.md)
            .background(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous).stroke(SLColor.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
        .accessibilityIdentifier("post.event")
    }
}

/// A weekly recognition, drawn small. Never next to the seal, never a check.
struct BadgeLabels: View {
    let badges: [RecognitionBadge]

    var body: some View {
        if !badges.isEmpty {
            HStack(spacing: SLSpacing.xs) {
                ForEach(badges) { badge in
                    Label(badge.title, systemImage: badge.icon)
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(SLColor.warning.opacity(0.12)))
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// What an ended room leaves behind: metadata only — nothing said is kept.
@MainActor
struct RoomRecapView: View {
    let roomId: UUID
    let service: RecognitionServiceProtocol
    @State private var recap: RoomRecap?

    var body: some View {
        Group {
            if let recap {
                SLCard {
                    VStack(alignment: .leading, spacing: SLSpacing.sm) {
                        Text(L10n.t("rooms.recap.title")).font(SLFont.bodyEmphasis)
                        Text(L10n.t("rooms.recap.duration", SLFormat.number(recap.durationMinutes)))
                        Text(L10n.t("rooms.recap.listeners", SLFormat.number(recap.peakListeners), SLFormat.number(recap.totalListeners)))
                        if !recap.speakers.isEmpty {
                            Text(L10n.t("rooms.recap.speakers", recap.speakers.map(\.displayName).joined(separator: "، ")))
                        }
                        if recap.questionsAnswered > 0 {
                            Text(L10n.plural("rooms.recap.questions", recap.questionsAnswered))
                        }
                        ForEach(recap.polls, id: \.question) { poll in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(poll.question).font(SLFont.caption.weight(.semibold))
                                ForEach(poll.options, id: \.text) { option in
                                    Text("\(option.text) — \(SLFormat.number(option.votes))").font(SLFont.micro)
                                }
                            }
                        }
                        Text(L10n.t("rooms.recap.note")).font(SLFont.micro).foregroundStyle(SLColor.textMuted)
                    }
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                }
            }
        }
        .task { recap = try? await service.recap(roomId: roomId) }
    }
}

private struct OpenEventKey: EnvironmentKey {
    static let defaultValue: (@MainActor (UUID) -> Void)? = nil
}

private struct RecognitionServiceKey: EnvironmentKey {
    static let defaultValue: RecognitionServiceProtocol? = nil
}

extension EnvironmentValues {
    /// Opens an event from a card on a post.
    public var openEvent: (@MainActor (UUID) -> Void)? {
        get { self[OpenEventKey.self] }
        set { self[OpenEventKey.self] = newValue }
    }

    /// Recaps and community pictures.
    public var recognitionService: RecognitionServiceProtocol? {
        get { self[RecognitionServiceKey.self] }
        set { self[RecognitionServiceKey.self] = newValue }
    }
}
