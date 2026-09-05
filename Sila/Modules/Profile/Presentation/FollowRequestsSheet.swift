import SwiftUI

/// The people waiting to follow the viewer's private account.
///
/// Two buttons per row and no third thing. Accept lets the person in and
/// tells them; Decline removes the row and tells nobody — which the sheet
/// says once, at the bottom, in the words the owner is trusting.
@MainActor
public struct FollowRequestsSheet: View {

    @Bindable private var viewModel: ProfileViewModel
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: ProfileViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoadingRequests && viewModel.followRequests.isEmpty {
                    ProgressView()
                        .tint(SLColor.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.followRequests.isEmpty {
                    SLEmptyState(
                        icon: "person.crop.circle.badge.checkmark",
                        title: L10n.t("profile.requests.empty"),
                        subtitle: L10n.t("profile.requests.empty.subtitle"),
                        tint: SLColor.textSecondary
                    )
                    .padding(SLSpacing.xl)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.followRequests) { request in
                                row(request)
                                SLDivider()
                            }

                            Text(L10n.t("profile.requests.silent"))
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(SLSpacing.lg)
                        }
                    }
                }
            }
            .tnScreenBackground()
            .navigationTitle(L10n.t("profile.requests.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("common.done")) { dismiss() }
                        .foregroundStyle(SLColor.primary)
                }
            }
            .task { await viewModel.loadFollowRequests() }
            .tnToast(Binding(get: { viewModel.toast }, set: { viewModel.toast = $0 }))
        }
        .tint(SLColor.primary)
    }

    private func row(_ request: FollowRequest) -> some View {
        let name = request.user.displayName
        return HStack(spacing: SLSpacing.md) {
            SLAvatar(
                initials: request.user.initials,
                size: .md,
                isVerified: request.user.isVerified,
                displayName: name
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .lineLimit(1)
                Text(request.user.atHandle)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            SLButton(
                L10n.t("profile.requests.accept"),
                variant: .primary,
                size: .compact,
                isEnabled: !viewModel.isAnsweringRequest,
                accessibilityHint: L10n.t("profile.requests.accept.hint", name),
                asyncAction: { await viewModel.answer(request, accept: true) }
            )
            .frame(width: 92)
            .accessibilityIdentifier("profile.request.accept")

            SLButton(
                L10n.t("profile.requests.decline"),
                variant: .secondary,
                size: .compact,
                isEnabled: !viewModel.isAnsweringRequest,
                accessibilityHint: L10n.t("profile.requests.decline.hint", name),
                asyncAction: { await viewModel.answer(request, accept: false) }
            )
            .frame(width: 92)
            .accessibilityIdentifier("profile.request.decline")
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.md)
    }
}
