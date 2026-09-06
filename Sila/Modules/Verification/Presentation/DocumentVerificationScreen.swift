import SwiftUI

/// **The document + selfie verification flow.**
///
/// Choose a document, photograph it, check what its zone said, take the
/// selfie sequence, and hand everything to a reviewer. Presented full-screen
/// from the verification wall, for anyone — a passport from any country, a
/// national ID card, a residence permit — including Saudi citizens who would
/// rather not use Nafath.
///
/// Nothing on these screens is typed. The nationality, birth date and expiry
/// shown on the review step were read off the document and verified by its
/// check digits; the only way to change them is a better photograph.
@MainActor
public struct DocumentVerificationScreen: View {

    @State private var viewModel: DocumentVerificationViewModel
    private let onSubmitted: () -> Void
    private let onSignInInstead: (() -> Void)?
    private let onUseNafath: (() -> Void)?
    private let onClose: () -> Void

    /// - Parameters:
    ///   - viewModel: Owns the flow's state.
    ///   - onSubmitted: Called from the under-review screen's Done — the
    ///     caller refreshes the session so the wall shows `pending_review`.
    ///   - onSignInInstead: Ends this session so the person can sign in to the
    ///     account their document already belongs to. `nil` hides the button.
    ///   - onUseNafath: Closes this flow and opens the Nafath one — for a
    ///     Saudi document, which this route does not take. `nil` hides the
    ///     button and leaves only Cancel.
    ///   - onClose: Dismisses the flow without finishing it.
    public init(
        viewModel: DocumentVerificationViewModel,
        onSubmitted: @escaping () -> Void,
        onSignInInstead: (() -> Void)? = nil,
        onUseNafath: (() -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onSubmitted = onSubmitted
        self.onSignInInstead = onSignInInstead
        self.onUseNafath = onUseNafath
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SLSpacing.xl)
            }
            .tnScreenBackground()
            .tnToast($viewModel.toast)
            .navigationTitle(L10n.t("document.nav.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.phase != .submitting && viewModel.phase != .submitted {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(L10n.t("common.cancel"), action: onClose)
                            .foregroundStyle(SLColor.textSecondary)
                            .accessibilityHint(Text(L10n.t("document.cancel.hint")))
                    }
                }
            }
        }
        .tint(SLColor.primary)
        .interactiveDismissDisabled(viewModel.phase == .submitting || viewModel.phase == .submitted)
    }

    // MARK: - Phases

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .chooseDocument: chooseDocument
        case .captureFront:
            DocumentCaptureView(side: .front, documentType: viewModel.documentType ?? .passport) { jpeg, text in
                viewModel.acceptFront(jpeg: jpeg, recognisedText: text)
            }
            .id("front")
        case .captureBack:
            DocumentCaptureView(side: .back, documentType: viewModel.documentType ?? .nationalId) { jpeg, _ in
                viewModel.acceptBack(jpeg: jpeg)
            }
            .id("back")
        case .review: review
        case .liveness:
            LivenessCaptureView { selfie, turn, challenges in
                viewModel.livenessCompleted(selfie: selfie, turn: turn, challenges: challenges)
            }
        case .submitting: submitting
        case .submitted: submitted
        case .identityUsed: identityUsed
        case .underAge: underAge
        case .documentExpired: documentExpired
        case .useNafath: useNafath
        }
    }

    // MARK: Choose

    private var chooseDocument: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "doc.text.viewfinder", tint: SLColor.primary)

            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("document.type.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.t("document.type.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: SLSpacing.md) {
                ForEach(DocumentType.allCases) { type in
                    SLCard(
                        padding: SLSpacing.md,
                        accessibilityLabel: "\(type.title). \(type.detail)",
                        accessibilityHint: L10n.t("document.type.hint"),
                        onTap: { viewModel.choose(type) }
                    ) {
                        HStack(spacing: SLSpacing.md) {
                            Image(systemName: type.icon)
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(SLColor.primary)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                                Text(type.title)
                                    .font(SLFont.bodyEmphasis)
                                    .foregroundStyle(SLColor.textPrimary)
                                Text(type.detail)
                                    .font(SLFont.caption)
                                    .foregroundStyle(SLColor.textSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward")
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.textMuted)
                        }
                    }
                }
            }

            Text(L10n.t("document.privacy"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SLSpacing.lg)
    }

    // MARK: Review

    private var review: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(
                icon: viewModel.zoneIsReadable ? "checkmark.seal" : "questionmark.circle",
                tint: viewModel.zoneIsReadable ? SLColor.secondary : SLColor.warning
            )

            VStack(spacing: SLSpacing.sm) {
                Text(viewModel.zoneIsReadable ? L10n.t("document.review.title") : L10n.t("document.review.unreadable.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(viewModel.zoneIsReadable ? L10n.t("document.review.message") : L10n.t("document.review.unreadable.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.zoneIsReadable {
                SLCard(padding: SLSpacing.md) {
                    VStack(spacing: SLSpacing.sm) {
                        row(L10n.t("document.review.nationality"), nationalityText)
                        SLDivider()
                        row(L10n.t("document.review.dateOfBirth"), formatted(viewModel.mrz?.dateOfBirth))
                        SLDivider()
                        row(L10n.t("document.review.expiry"), formatted(viewModel.mrz?.expiryDate))
                        if let number = viewModel.maskedDocumentNumber {
                            SLDivider()
                            row(L10n.t("document.review.documentNumber"), number)
                        }
                    }
                }
            }

            if viewModel.zoneHasNoCountry {
                Text(L10n.t("document.review.noCountry"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: SLSpacing.md) {
                SLButton(
                    L10n.t("document.review.continue"),
                    variant: .primary,
                    isEnabled: viewModel.canContinueFromReview,
                    accessibilityHint: L10n.t("document.review.continue.hint")
                ) {
                    viewModel.confirmDetails()
                }
                SLButton(
                    L10n.t("document.capture.retake"),
                    variant: .secondary,
                    accessibilityHint: L10n.t("document.retake.hint")
                ) {
                    viewModel.retakeFront()
                }
            }
        }
        .padding(.horizontal, SLSpacing.lg)
    }

    private var nationalityText: String {
        guard let code = viewModel.mrz?.nationality else { return "—" }
        let flag = CountryCode.flag(code) ?? ""
        let name = CountryCode.name(code) ?? code
        return "\(flag) \(name)".trimmingCharacters(in: .whitespaces)
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
            Spacer(minLength: SLSpacing.md)
            Text(value)
                .font(SLFont.bodyEmphasis)
                .foregroundStyle(SLColor.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Submitting / submitted

    private var submitting: some View {
        VStack(spacing: SLSpacing.xl) {
            ProgressView()
                .controlSize(.large)
                .tint(SLColor.primary)
                .padding(.top, SLSpacing.xxl)
            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("document.submitting.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                Text(L10n.t("document.submitting.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, SLSpacing.lg)
    }

    private var submitted: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "hourglass", tint: SLColor.primary)
            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("document.submitted.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.t("document.submitted.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SLButton(
                L10n.t("document.submitted.continue"),
                variant: .primary,
                accessibilityHint: L10n.t("document.submitted.continue.hint"),
                action: onSubmitted
            )
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.top, SLSpacing.xl)
    }

    // MARK: Terminal states

    private var identityUsed: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "person.crop.circle.badge.checkmark", tint: SLColor.primary)
            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("verification.identityUsed.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.t("verification.identityUsed.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onSignInInstead {
                SLButton(
                    L10n.t("verification.identityUsed.signIn"),
                    variant: .primary,
                    accessibilityHint: L10n.t("verification.identityUsed.signIn.hint"),
                    action: onSignInInstead
                )
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.top, SLSpacing.xl)
    }

    private var underAge: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "hand.raised.fill", tint: SLColor.warning)
            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("verification.underAge.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                // The server's sentence, verbatim: the age rule is policy.
                Text(viewModel.underAgeMessage)
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(
                        \.layoutDirection,
                        TextDirection.resolve(languageCode: nil, text: viewModel.underAgeMessage).layoutDirection
                    )
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.top, SLSpacing.xl)
    }

    private var documentExpired: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "calendar.badge.exclamationmark", tint: SLColor.warning)
            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("document.expired.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.t("document.review.expired"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SLButton(
                L10n.t("verification.tryAgain"),
                variant: .primary,
                accessibilityHint: L10n.t("verification.tryAgain.hint")
            ) {
                viewModel.startAgain()
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.top, SLSpacing.xl)
    }

    /// Not a failure. The person is Saudi, or holds a Saudi-issued permit,
    /// and has the instant route; this one would only ever have made them a
    /// second account.
    private var useNafath: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "person.badge.shield.checkmark", tint: SLColor.primary)
            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("document.useNafath.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.t("document.useNafath.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onUseNafath {
                SLButton(
                    L10n.t("document.useNafath.button"),
                    variant: .primary,
                    accessibilityHint: L10n.t("document.useNafath.button.hint"),
                    action: onUseNafath
                )
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.top, SLSpacing.xl)
    }

    // MARK: - Pieces

    private func hero(icon: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 132, height: 132)
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(tint)
        }
        .accessibilityHidden(true)
    }
}

#Preview("Document — choose") {
    DocumentVerificationScreen(
        viewModel: DocumentVerificationViewModel(
            service: VerificationServiceMock(scenario: .approved, latency: 0.4),
            analytics: RecordingAnalyticsClient()
        ),
        onSubmitted: {},
        onSignInInstead: {},
        onClose: {}
    )
    .preferredColorScheme(.dark)
}
