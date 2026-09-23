import SwiftUI

/// The first-run flow's screens: subjects (1 of 2), people (2 of 2), and the
/// one card at the end.
@MainActor
public struct OnboardingFlow: View {

    @Bindable private var viewModel: OnboardingViewModel
    private let onOpenRoom: @MainActor (VoiceRoom) -> Void

    public init(viewModel: OnboardingViewModel, onOpenRoom: @escaping @MainActor (VoiceRoom) -> Void) {
        self.viewModel = viewModel
        self.onOpenRoom = onOpenRoom
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch viewModel.step {
                case .subjects: InterestsOnboardingScreen(viewModel: viewModel)
                case .people: PeopleOnboardingScreen(viewModel: viewModel)
                case .finale: finale
                }
            }
            .tnScreenBackground()
            .tnToast($viewModel.toast)
        }
        .tint(SLColor.primary)
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var finale: some View {
        VStack(spacing: SLSpacing.xl) {
            Spacer()
            if let room = viewModel.liveRoom {
                Text(L10n.t("onboarding.finale.title"))
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                LiveNowRail(rooms: [room]) { room in
                    viewModel.complete(result: "room")
                    onOpenRoom(room)
                }
            }
            Spacer()
            SLButton(L10n.t("onboarding.finale.feed"), variant: .secondary) {
                viewModel.complete(result: "feed")
            }
            .padding(.horizontal, SLSpacing.lg)
            .accessibilityIdentifier("onboarding.finale.feed")
        }
        .padding(.vertical, SLSpacing.xl)
    }
}

/// Step 1 of 2: what do you want to read about?
@MainActor
struct InterestsOnboardingScreen: View {

    @Bindable var viewModel: OnboardingViewModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: SLSpacing.md), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.md) {
                    Text(L10n.t("onboarding.step", SLFormat.number(1), SLFormat.number(2)))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                    Text(L10n.t("onboarding.interests.title"))
                        .font(SLFont.displayM)
                        .foregroundStyle(SLColor.textPrimary)
                    Text(viewModel.subjectsHint)
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if viewModel.isLoading && viewModel.topics.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(SLSpacing.xl)
                    } else if let error = viewModel.loadError, viewModel.topics.isEmpty {
                        SLEmptyState(
                            icon: "wifi.exclamationmark",
                            title: L10n.t("onboarding.interests.error"),
                            subtitle: error,
                            tint: SLColor.danger
                        )
                    } else {
                        LazyVGrid(columns: columns, spacing: SLSpacing.lg) {
                            ForEach(viewModel.topics) { topic in
                                TopicTile(
                                    topic: topic,
                                    stance: viewModel.isSelected(topic.id) ? .interested : .none,
                                    onSelect: { _ in viewModel.toggle(topic.id) },
                                    showsMuteControl: false
                                )
                            }
                        }
                        .padding(.top, SLSpacing.sm)
                    }
                }
                .padding(SLSpacing.lg)
            }

            HStack(spacing: SLSpacing.md) {
                Button(L10n.t("onboarding.skip")) { Task { await viewModel.skipSubjects() } }
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityIdentifier("onboarding.skip")
                SLButton(
                    L10n.t("onboarding.continue"),
                    isLoading: viewModel.isSaving
                ) {
                    Task { await viewModel.continueFromSubjects() }
                }
                .accessibilityIdentifier("onboarding.continue")
            }
            .padding(SLSpacing.lg)
        }
    }
}

/// Step 2 of 2: people to follow.
@MainActor
struct PeopleOnboardingScreen: View {

    @Bindable var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.md) {
                    Text(L10n.t("onboarding.step", SLFormat.number(2), SLFormat.number(2)))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                    Text(L10n.t("onboarding.people.title"))
                        .font(SLFont.displayM)
                        .foregroundStyle(SLColor.textPrimary)
                    Text(L10n.t("onboarding.people.hint"))
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if viewModel.people.count > 1 {
                        Button(L10n.t("onboarding.people.followAll")) { Task { await viewModel.followAll() } }
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.primary)
                            .accessibilityIdentifier("onboarding.people.followAll")
                    }
                }
                .padding(SLSpacing.lg)

                VStack(spacing: SLSpacing.md) {
                    ForEach(viewModel.people) { person in
                        PersonSuggestionRow(
                            person: person,
                            isFollowed: viewModel.isFollowed(person),
                            isBusy: viewModel.isFollowing(person),
                            onOpen: {},
                            onFollow: { Task { await viewModel.follow(person) } }
                        )
                    }
                }
            }

            SLButton(L10n.t("onboarding.done")) {
                Task { await viewModel.finish() }
            }
            .padding(SLSpacing.lg)
            .accessibilityIdentifier("onboarding.done")
        }
    }
}
