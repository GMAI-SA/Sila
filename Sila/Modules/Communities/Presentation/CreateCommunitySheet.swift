import SwiftUI

/// Opening a community: a name, an address, a door, and who may post.
@MainActor
public struct CreateCommunitySheet: View {

    @State private var viewModel: CreateCommunityViewModel
    private let onClose: @MainActor () -> Void
    private let onCreated: (@MainActor (Community) -> Void)?

    public init(
        viewModel: CreateCommunityViewModel,
        onClose: @escaping @MainActor () -> Void,
        onCreated: (@MainActor (Community) -> Void)? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onClose = onClose
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    Text(L10n.t("communities.create.explanation"))
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    identity
                    doorPicker
                    audiencePicker
                    topicPicker
                    rulesField

                    if let error = viewModel.createError {
                        Text(error)
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let reason = viewModel.blockingReason {
                        Label(reason, systemImage: "info.circle")
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("communities.create.blocked")
                    }

                    SLButton(
                        L10n.t("communities.create.button"),
                        isLoading: viewModel.isCreating,
                        isEnabled: viewModel.canCreate,
                        asyncAction: {
                            if let community = await viewModel.create() {
                                onCreated?(community)
                                onClose()
                            }
                        }
                    )
                }
                .padding(SLSpacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("communities.create"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("common.cancel"), action: onClose)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
            .task { await viewModel.loadTopics() }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            SLTextField(
                L10n.t("communities.create.name.label"),
                text: $viewModel.name,
                placeholder: L10n.t("communities.create.name.placeholder"),
                autocapitalization: .words,
                error: viewModel.nameError,
                accessibilityHint: L10n.t("communities.create.name.a11yHint")
            )
            SLTextField(
                L10n.t("communities.create.address.label"),
                text: $viewModel.slug,
                placeholder: "riyadh_runners",
                error: viewModel.slugError,
                accessibilityHint: L10n.t("communities.create.address.a11yHint")
            )
            .onChange(of: viewModel.slug) { _, _ in viewModel.markSlugEdited() }
            Text(L10n.t("communities.create.address.hint", "/c/\(viewModel.normalisedSlug)"))
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
            SLTextField(
                L10n.t("communities.create.about.label"),
                text: $viewModel.about,
                placeholder: L10n.t("communities.create.about.placeholder"),
                autocapitalization: .sentences,
                accessibilityHint: L10n.t("communities.create.about.a11yHint")
            )
        }
    }

    private var doorPicker: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("communities.create.door.heading"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)

            ForEach(CommunityVisibility.allCases) { option in
                optionCard(
                    title: option.title,
                    explanation: option.explanation,
                    icon: option.icon,
                    isPicked: viewModel.visibility == option,
                    pick: { viewModel.visibility = option }
                )
            }

            Text(L10n.t("communities.create.join.heading"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .padding(.top, SLSpacing.xs)

            ForEach(CommunityJoinPolicy.allCases) { option in
                optionCard(
                    title: option.title,
                    explanation: option.explanation,
                    icon: option.icon,
                    isPicked: viewModel.joinPolicy == option,
                    pick: { viewModel.joinPolicy = option }
                )
            }
        }
    }

    private var audiencePicker: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("communities.create.audience.heading"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
            ForEach(viewModel.scopeOptions) { option in
                optionCard(
                    title: option.title,
                    explanation: option.isAvailable
                        ? option.subtitle
                        : (option.unavailableReason ?? option.subtitle),
                    icon: option.icon,
                    isPicked: viewModel.scope == option.scope,
                    isEnabled: option.isAvailable,
                    pick: { viewModel.scope = option.scope }
                )
            }
            Toggle(isOn: $viewModel.verifiedOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("communities.create.verifiedOnly.label"))
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                    Text(L10n.t("communities.create.verifiedOnly.hint"))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(SLColor.primary)
        }
    }

    @ViewBuilder
    private var topicPicker: some View {
        if !viewModel.topics.isEmpty {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(L10n.t("communities.create.topic.heading"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SLSpacing.sm) {
                        ForEach(viewModel.topics) { option in
                            Button {
                                viewModel.topic = viewModel.topic == option.id ? nil : option.id
                            } label: {
                                SLChip(
                                    option.label,
                                    icon: viewModel.topic == option.id ? "checkmark" : "number"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(viewModel.topic == option.id ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    private var rulesField: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            SLTextField(
                L10n.t("communities.create.rules.label"),
                text: $viewModel.rulesText,
                placeholder: L10n.t("communities.create.rules.placeholder"),
                autocapitalization: .sentences,
                accessibilityHint: L10n.t("communities.create.rules.a11yHint")
            )
            Text(L10n.t("communities.create.rules.hint"))
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
        }
    }

    private func optionCard(
        title: String,
        explanation: String,
        icon: String,
        isPicked: Bool,
        isEnabled: Bool = true,
        pick: @escaping () -> Void
    ) -> some View {
        let tap: (() -> Void)? = isEnabled ? pick : nil
        return SLCard(
            padding: SLSpacing.md,
            accessibilityLabel: "\(title). \(explanation)",
            onTap: tap
        ) {
            HStack(spacing: SLSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isPicked ? SLColor.primary : SLColor.textMuted)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(isEnabled ? SLColor.textPrimary : SLColor.textMuted)
                    Text(explanation)
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? SLColor.primary : SLColor.stroke)
            }
            .opacity(isEnabled ? 1 : 0.6)
        }
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}
