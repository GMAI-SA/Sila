import SwiftUI

/// "Choose your @handle" (contract v33): after sign-up, once for an account
/// that never chose, and behind "Change" in account settings.
///
/// The field is the handle exactly as it will be stored, read left to right
/// in either language, with its `@` drawn rather than typed. The line under
/// it answers as the person types; the server's suggestions sit under that as
/// chips. Save takes it; "Keep @user… for now" goes on with the one they
/// were given.
@MainActor
public struct HandleChooserScreen: View {

    @Bindable private var viewModel: HandleChooserViewModel
    @FocusState private var isFieldFocused: Bool

    public init(viewModel: HandleChooserViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        // In settings the sheet that presents it brings the navigation bar.
        if viewModel.context == .settings {
            content
        } else {
            NavigationStack { content }
                .tint(SLColor.primary)
        }
    }

    private var content: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    header
                    field
                    statusRow
                    suggestionChips
                    if let error = viewModel.saveError {
                        Text(error)
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("handle.saveError")
                    }
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .tnScreenBackground()
            .navigationTitle(viewModel.context == .settings ? L10n.t("account.handle.change.title") : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.context == .settings {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(L10n.t("common.cancel")) { viewModel.dismiss() }
                            .foregroundStyle(SLColor.textSecondary)
                            .accessibilityIdentifier("handle.cancel")
                    }
                }
            }
        }
        .task { await viewModel.load() }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            if viewModel.context != .settings {
                ZStack {
                    Circle()
                        .fill(SLColor.primary.opacity(0.12))
                        .frame(width: 72, height: 72)
                    Image(systemName: "at")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(SLColor.primary)
                }
                .accessibilityHidden(true)
                Text(L10n.t("account.handle.choose.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("handle.title")
            }
            Text(message)
                .font(SLFont.bodyLight)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var message: String {
        switch viewModel.context {
        case .signUp:
            return L10n.t("account.handle.choose.message")
        case .existing:
            return L10n.t("account.handle.choose.existing", isolated(viewModel.currentHandle ?? ""))
        case .settings:
            return L10n.t("account.handle.change.message")
        }
    }

    /// The handle, typed and read left to right in both languages, with the
    /// `@` drawn beside it.
    private var field: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            Text(L10n.t("account.profile.handle.label"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
            HStack(spacing: 2) {
                Text(verbatim: "@")
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textMuted)
                    .accessibilityHidden(true)
                TextField(
                    "",
                    text: Binding(get: { viewModel.text }, set: { viewModel.update($0) }),
                    prompt: Text(verbatim: "aziz_sa").foregroundColor(SLColor.textMuted)
                )
                .font(SLFont.bodyEmphasis)
                .foregroundStyle(SLColor.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // No content type: as a username the keyboard offered saved
                // passwords' email addresses, which are never a handle.
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
                .focused($isFieldFocused)
                .onSubmit { Task { await viewModel.save() } }
                .accessibilityLabel(Text(L10n.t("account.profile.handle.label")))
                .accessibilityHint(Text(L10n.t("account.profile.handle.hint")))
                .accessibilityIdentifier("handle.field")
                statusIcon
            }
            .padding(.horizontal, SLSpacing.md)
            .frame(minHeight: 50)
            .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.surface2))
            .overlay(
                RoundedRectangle(cornerRadius: SLRadius.md)
                    .strokeBorder(borderColor, lineWidth: isFieldFocused ? 1.5 : 1)
            )
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.status {
        case .checking:
            ProgressView().controlSize(.small).tint(SLColor.primary)
        case .available, .current:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(SLColor.secondary)
                .accessibilityHidden(true)
        case .unavailable, .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(SLColor.danger)
                .accessibilityHidden(true)
        case .idle:
            EmptyView()
        }
    }

    private var borderColor: Color {
        switch viewModel.status {
        case .available, .current: return SLColor.secondary
        case .unavailable, .failed: return SLColor.danger
        default: return isFieldFocused ? SLColor.primary : SLColor.primary.opacity(0.3)
        }
    }

    private var statusColor: Color {
        switch viewModel.status {
        case .available, .current: return SLColor.secondary
        case .unavailable, .failed: return SLColor.danger
        default: return SLColor.textSecondary
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        // Always there, so the layout does not jump as the answer arrives.
        Text(viewModel.statusLine ?? " ")
            .font(SLFont.caption)
            .foregroundStyle(statusColor)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(viewModel.statusLine == nil)
            .accessibilityIdentifier("handle.status")
    }

    @ViewBuilder
    private var suggestionChips: some View {
        if !viewModel.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(L10n.t("account.handle.suggestions"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SLSpacing.sm) {
                        ForEach(viewModel.suggestions, id: \.self) { suggestion in
                            SLChip(
                                "@" + suggestion,
                                isSelected: suggestion == viewModel.text,
                                accessibilityHint: L10n.t("account.handle.suggestion.hint"),
                                onTap: { viewModel.pick(suggestion) }
                            )
                            .accessibilityIdentifier("handle.suggestion")
                        }
                    }
                    .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: SLSpacing.sm) {
            SLButton(
                L10n.t("common.save"),
                variant: .primary,
                isLoading: viewModel.isSaving,
                isEnabled: viewModel.canSave,
                accessibilityHint: L10n.t("account.handle.save.hint"),
                asyncAction: { await viewModel.save() }
            )
            .accessibilityIdentifier("handle.save")
            if viewModel.offersKeep, let current = viewModel.currentHandle {
                SLButton(
                    L10n.t("account.handle.keep", isolated(current)),
                    variant: .ghost,
                    size: .compact,
                    isLoading: viewModel.isKeeping,
                    isEnabled: !viewModel.isSaving,
                    accessibilityHint: L10n.t("account.handle.keep.hint"),
                    asyncAction: { await viewModel.keep() }
                )
                .accessibilityIdentifier("handle.keep")
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.top, SLSpacing.md)
        .padding(.bottom, SLSpacing.md)
        .background(SLColor.background.opacity(0.96))
    }

    /// `@handle` as one left-to-right run inside a sentence of either
    /// direction, so the `@` stays at its start in Arabic.
    private func isolated(_ handle: String) -> String {
        "\u{2066}@\(handle)\u{2069}"
    }
}

#Preview("Choose your handle") {
    HandleChooserScreen(
        viewModel: HandleChooserViewModel(
            service: HandleServiceMock(latency: 0.3),
            analytics: RecordingAnalyticsClient(),
            currentHandle: "user7k2m9q4x",
            context: .signUp,
            onChosen: { _ in }
        )
    )
}
