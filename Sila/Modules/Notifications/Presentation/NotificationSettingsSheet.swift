import SwiftUI

/// The five notification switches, reachable from the notifications list.
///
/// Deliberately one screen away from the thing it controls. Likes are the
/// noisiest of the five and the first switch anybody looks for, and the moment
/// they look for it they are standing in the list — not in feed preferences.
@MainActor
public struct NotificationSettingsSheet: View {

    @Bindable private var viewModel: NotificationSettingsViewModel
    private let onClose: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - viewModel: Owns the stored map and the per-switch writes.
    ///   - onClose: Dismisses the sheet. `nil` hides the Done button.
    public init(
        viewModel: NotificationSettingsViewModel,
        onClose: (@MainActor () -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onClose = onClose
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("notifications.settings.title"))
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.t("common.done")) { onClose() }
                            .foregroundStyle(SLColor.primary)
                            .accessibilityLabel(Text(L10n.t("common.done")))
                            .accessibilityHint(Text(L10n.t("notifications.settings.done.hint")))
                    }
                }
            }
            .task { await viewModel.load() }
            .tnToast($viewModel.toast)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            VStack(spacing: SLSpacing.lg) {
                ForEach(0..<5, id: \.self) { _ in
                    SLSkeletonRow(lineCount: 2).padding(.horizontal, SLSpacing.lg)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, SLSpacing.lg)
            .accessibilityLabel(Text(L10n.t("notifications.settings.loading.accessibility")))
        // Only a failed *load* replaces the switches. A failed write keeps them
        // on screen — the toast already said what went wrong, and the switch
        // has already sprung back to what the server holds.
        } else if let error = viewModel.loadError {
            ScrollView {
                SLEmptyState(
                    icon: "wifi.exclamationmark",
                    title: L10n.t("notifications.settings.error.title"),
                    subtitle: error,
                    tint: SLColor.danger,
                    actionTitle: L10n.t("notifications.settings.error.retry"),
                    action: { Task { await viewModel.reload() } }
                )
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.xxl)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.md) {
                    explanation

                    ForEach(NotificationKind.settable) { kind in
                        PreferenceToggleRow(
                            title: kind.settingTitle,
                            detail: kind.settingDetail,
                            accessibilityHint: L10n.t(
                                "notifications.settings.toggle.hint",
                                kind.settingTitle.lowercased()
                            ),
                            isOn: Binding(
                                get: { viewModel.preferences.isEnabled(kind) },
                                set: { value in
                                    Task { await viewModel.setEnabled(value, for: kind) }
                                }
                            )
                        )
                        .opacity(viewModel.isSaving(kind) ? 0.6 : 1)
                    }

                    Text(viewModel.summary)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SLSpacing.xs)
                        .accessibilityLabel(Text(viewModel.summary))
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.lg)
            }
        }
    }

    private var explanation: some View {
        SLCard {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                HStack(spacing: SLSpacing.sm) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SLColor.primary)
                        .accessibilityHidden(true)
                    Text(L10n.t("notifications.settings.explanation.title"))
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                }

                Text(NotificationCopy.settingsExplanation)
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Notification settings") {
    NavigationStack {
        NotificationSettingsSheet(
            viewModel: NotificationSettingsViewModel(
                service: PreferencesServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            ),
            onClose: {}
        )
    }
    .preferredColorScheme(.dark)
}
