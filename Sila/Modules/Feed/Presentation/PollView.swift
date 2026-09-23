import SwiftUI

/// Casts a vote from wherever a poll is drawn.
///
/// An environment value rather than another ``PostCardActions`` hook: a poll
/// can appear on every screen that shows posts, and threading a closure
/// through each of their view models would be a dozen edits for one verb.
/// The card keeps the answer locally, so the bars move the moment the server
/// confirms, on whichever screen the vote was cast.
public struct PollVoter {
    /// `POST /posts/{id}/poll/votes`.
    public var vote: @MainActor (_ postId: UUID, _ optionId: UUID) async throws -> Poll
    /// A guest tapped an option: ask them to join. `nil` shows the line only.
    public var onGuest: (@MainActor () -> Void)?

    public init(
        vote: @escaping @MainActor (_ postId: UUID, _ optionId: UUID) async throws -> Poll,
        onGuest: (@MainActor () -> Void)? = nil
    ) {
        self.vote = vote
        self.onGuest = onGuest
    }
}

private struct PollVoterKey: EnvironmentKey {
    static let defaultValue: PollVoter? = nil
}

extension EnvironmentValues {
    /// How a ``PollView`` votes. `nil` draws polls read-only.
    public var pollVoter: PollVoter? {
        get { self[PollVoterKey.self] }
        set { self[PollVoterKey.self] = newValue }
    }
}

/// The sentences a poll uses, kept out of the view so they can be asserted.
public enum PollCopy {

    /// "12 votes · Closes in 3 hours" / "12 votes · Closed".
    public static func footer(_ poll: Poll, now: Date = Date()) -> String {
        let votes = L10n.plural("poll.votes", poll.totalVotes)
        let when = poll.isClosed(now: now)
            ? L10n.t("poll.closed")
            : L10n.t("poll.closesIn", SLFormat.relative(poll.closesAt, to: now))
        return "\(votes) · \(when)"
    }

    /// Why this viewer cannot vote, when that needs saying. `nil` for the
    /// cases the bars already explain (voted, closed) and for the author.
    public static func blockedLine(_ poll: Poll, post: Post) -> String? {
        guard !poll.canVote, poll.viewerOptionId == nil, !poll.isClosed() else { return nil }
        switch poll.voteBlockReason {
        case .guest: return L10n.t("poll.blocked.guest")
        case .unverified: return L10n.t("poll.blocked.unverified")
        case .countryMismatch:
            let name = post.scopeCountry.flatMap { CountryCode.shortName($0, locale: L10n.locale) } ?? post.scopeCountry ?? ""
            return L10n.t("poll.blocked.country", name)
        case .regionMismatch: return L10n.t("poll.blocked.region", post.scopeRegion ?? "")
        case .author: return L10n.t("poll.blocked.author")
        case .alreadyVoted, .closed, .none: return nil
        case .unknown: return L10n.t("poll.error.notAllowed")
        }
    }

    /// Shown under the bars while counts are hidden.
    public static func hiddenLine(_ poll: Poll) -> String? {
        guard !poll.resultsVisible else { return nil }
        switch poll.resultsVisibility {
        case .afterClose: return L10n.t("poll.hidden.afterClose")
        case .afterVote: return L10n.t("poll.hidden.afterVote")
        case .always: return nil
        }
    }

    /// A whole-number percentage, or `nil` while hidden.
    public static func percent(_ poll: Poll, option: PollOption) -> String? {
        guard let share = poll.share(of: option) else { return nil }
        return share.formatted(.percent.precision(.fractionLength(0)).locale(L10n.formattingLocale))
    }
}

/// A poll on a post: options to tap before voting, proportion bars after.
///
/// **Anonymous.** Nothing drawn here names a voter; the only choice shown is
/// the viewer's own.
@MainActor
public struct PollView: View {

    private let post: Post
    private let isDetail: Bool

    @Environment(\.pollVoter) private var voter
    /// The server's answer to this card's vote, kept so the bars move at once
    /// even while the list behind the card still holds the old copy.
    @State private var answered: Poll?
    @State private var voting: UUID?
    @State private var error: String?

    public init(post: Post, isDetail: Bool = false) {
        self.post = post
        self.isDetail = isDetail
    }

    private var poll: Poll? { answered ?? post.poll }

    public var body: some View {
        if let poll {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                ForEach(poll.options) { option in
                    row(option, in: poll)
                }
                if let line = PollCopy.blockedLine(poll, post: post) {
                    Group {
                        if poll.voteBlockReason == .guest, let onGuest = voter?.onGuest {
                            Button(line) { onGuest() }
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.primary)
                        } else {
                            Text(line)
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.textSecondary)
                        }
                    }
                }
                if let hidden = PollCopy.hiddenLine(poll), poll.viewerOptionId != nil || !poll.canVote {
                    Text(hidden).font(SLFont.caption).foregroundStyle(SLColor.textSecondary)
                }
                if let error {
                    Text(error).font(SLFont.caption).foregroundStyle(SLColor.danger)
                }
                HStack(spacing: SLSpacing.xs) {
                    Image(systemName: "lock.fill").font(.system(size: 10)).accessibilityHidden(true)
                    Text(PollCopy.footer(poll))
                }
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
                if isDetail {
                    Text(L10n.t("poll.anonymous"))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func row(_ option: PollOption, in poll: Poll) -> some View {
        let showsBars = poll.viewerOptionId != nil || !poll.canVote
        if showsBars {
            bar(option, in: poll)
        } else {
            Button {
                Task { await vote(option) }
            } label: {
                HStack {
                    Text(option.text)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.primary)
                    Spacer(minLength: 0)
                    if voting == option.id { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, SLSpacing.md)
                .frame(minHeight: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous)
                        .stroke(SLColor.primary, lineWidth: 1.2)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(voting != nil || voter == nil)
            .accessibilityLabel(Text(option.text))
            .accessibilityHint(Text(L10n.t("poll.option.hint")))
            .accessibilityIdentifier("poll.option.\(option.position)")
        }
    }

    private func bar(_ option: PollOption, in poll: Poll) -> some View {
        let share = poll.share(of: option) ?? 0
        let mine = poll.viewerOptionId == option.id
        return HStack(spacing: SLSpacing.sm) {
            Text(option.text)
                .font(mine ? SLFont.bodyEmphasis : SLFont.body)
                .foregroundStyle(SLColor.textPrimary)
            if mine {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(SLColor.primary)
                    .accessibilityLabel(Text(L10n.t("poll.yourChoice")))
            }
            Spacer(minLength: 0)
            if let percent = PollCopy.percent(poll, option: option) {
                Text(percent)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, SLSpacing.md)
        .frame(minHeight: 40)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous)
                    .fill((mine ? SLColor.primary : SLColor.textMuted).opacity(0.18))
                    .frame(width: max(0, geo.size.width * share))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func vote(_ option: PollOption) async {
        guard let voter, voting == nil else { return }
        voting = option.id
        error = nil
        defer { voting = nil }
        do {
            answered = try await voter.vote(post.id, option.id)
        } catch {
            let wrapped = APIError.wrapping(error)
            guard !wrapped.isCancellation else { return }
            self.error = wrapped.userMessage
        }
    }
}
