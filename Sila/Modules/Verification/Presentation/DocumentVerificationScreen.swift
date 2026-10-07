import PhotosUI
import SwiftUI

/// **The document + selfie verification flow.**
///
/// Choose a document, photograph it, check what its zone said, take the
/// selfie sequence, and hand everything to a reviewer. Presented full-screen
/// from the verification wall, for anyone — a passport from any country, a
/// national ID card, a residence permit — including Saudi citizens who would
/// rather not use Nafath.
///
/// One thing on these screens is typed: the birthdate, first, as a claim the
/// document is then held to. The nationality, birth date and expiry shown on
/// the review step were read off the document and verified by its check
/// digits; the only way to change them is a better photograph.
@MainActor
public struct DocumentVerificationScreen: View {

    @State private var viewModel: DocumentVerificationViewModel
    private let onSubmitted: () -> Void
    private let onSignInInstead: (() -> Void)?
    private let onUseNafath: (() -> Void)?
    private let onWithdrawn: ((VerificationStatusReport) -> Void)?
    private let onClose: () -> Void
    /// The privacy policy, from the consent card's link.
    @State private var showsPolicy = false

    /// - Parameters:
    ///   - viewModel: Owns the flow's state.
    ///   - onSubmitted: Called from the under-review screen's Done — the
    ///     caller refreshes the session so the wall shows `pending_review`.
    ///   - onSignInInstead: Ends this session so the person can sign in to the
    ///     account their document already belongs to. `nil` hides the button.
    ///   - onUseNafath: Closes this flow and opens the Nafath one — for a
    ///     Saudi document, which this route does not take. `nil` hides the
    ///     button and leaves only Cancel.
    ///   - onWithdrawn: The submission was taken back from the under-review
    ///     screen; the caller closes this flow and offers the methods again,
    ///     with the status the withdrawal answered. `nil` hides the action.
    ///   - onClose: Dismisses the flow without finishing it.
    public init(
        viewModel: DocumentVerificationViewModel,
        onSubmitted: @escaping () -> Void,
        onSignInInstead: (() -> Void)? = nil,
        onUseNafath: (() -> Void)? = nil,
        onWithdrawn: ((VerificationStatusReport) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onSubmitted = onSubmitted
        self.onSignInInstead = onSignInInstead
        self.onUseNafath = onUseNafath
        self.onWithdrawn = onWithdrawn
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: SLSpacing.lg) {
                    Color.clear.frame(height: 0).id(Self.top)
                    if let step = viewModel.progress {
                        VStack(spacing: SLSpacing.xs) {
                            // The bar draws its own "Step 4 of 6" beside the
                            // track, and reads it to VoiceOver; once is enough.
                            SLProgressBar(
                                value: Double(step.index) / Double(step.count),
                                label: L10n.t("document.step.progress", step.index, step.count)
                            )
                        }
                        .padding(.horizontal, SLSpacing.lg)
                    }
                    content
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, SLSpacing.xl)
            }
            // Every step starts at its top: a step that opened where the last
            // one had been scrolled to hid the card saying what had just been
            // added, which is how "Front added" read as nothing happening.
            .onChange(of: viewModel.phase) { previous, current in
                withAnimation(.easeOut(duration: 0.25)) { scroller.scrollTo(Self.top, anchor: .top) }
                announce(from: previous, to: current)
            }
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
        // App Attest's key, attested while the person is still at the camera
        // (contract v32). Leaving the flow stops nobody waiting for it.
        .task { await viewModel.prepareDevice() }
        // Whether the server offers to keep the photographs (contract v34):
        // the card and the new wording only while it does.
        .task { await viewModel.loadConsentOffer() }
        .sheet(isPresented: $showsPolicy) {
            LegalDocumentSheet(document: .privacy) { showsPolicy = false }
        }
    }

    // MARK: - Phases

    private static let top = "flowTop"

    /// VoiceOver hears what the screen shows: the side that was just added,
    /// and what comes next.
    private func announce(from previous: DocumentPhase, to current: DocumentPhase) {
        var words: [String] = []
        if previous == .captureFront, current == .captureBack {
            words = [L10n.t("document.side.front.added"), L10n.t("document.capture.back.title")]
        } else if previous == .captureFront, current == .review {
            words = [DocumentSideCard.addedTitle(.front, documentType: viewModel.documentType)]
        } else if previous == .captureBack, current == .review {
            words = [L10n.t("document.side.back.added")]
        }
        guard !words.isEmpty else { return }
        AccessibilityNotification.Announcement(words.joined(separator: ". ")).post()
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .birthdate: birthdate
        case .chooseDocument: chooseDocument
        case .captureFront, .captureBack:
            DocumentCaptureStep(viewModel: viewModel)
        case .review: review
        case .liveness:
            VStack(spacing: SLSpacing.sm) {
                if let notice = viewModel.stepNotice {
                    StepNoticeCard(text: notice)
                }
                // No upload here, on purpose: the face check has to be live.
                Label(L10n.t("document.upload.liveOnly"), systemImage: "faceid")
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SLSpacing.lg)
                    .accessibilityIdentifier("document.liveOnly")
                SweepCaptureView { sweep in
                    viewModel.sweepCompleted(sweep)
                }
            }
        case .send: sendStep
        case .submitting: submitting
        case .sendFailed: sendFailed
        case .submitted: submitted
        case .identityUsed: identityUsed
        case .underAge: underAge
        case .documentExpired: documentExpired
        case .useNafath: useNafath
        case .dateOfBirthMismatch: dateOfBirthMismatch
        }
    }

    // MARK: Birthdate

    /// The one thing the person types. Asked first, sent as a claim, and
    /// tested against the document by its check digits — so the wheel says
    /// "exactly as printed", because a slip here is a mismatch later.
    private var birthdate: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "calendar", tint: SLColor.primary)

            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("document.birthdate.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.t("document.birthdate.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SLCard(padding: SLSpacing.md) {
                DatePicker(
                    L10n.t("document.birthdate.field"),
                    selection: $viewModel.birthdateSelection,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .environment(\.calendar, Calendar(identifier: .gregorian))
                .accessibilityLabel(Text(L10n.t("document.birthdate.field")))
                .accessibilityHint(Text(L10n.t("document.birthdate.field.hint")))
            }

            SLButton(
                L10n.t("document.birthdate.continue"),
                variant: .primary,
                isLoading: viewModel.isSavingBirthdate,
                isEnabled: viewModel.canSubmitBirthdate,
                accessibilityHint: L10n.t("document.birthdate.continue.hint"),
                asyncAction: { await viewModel.submitBirthdate() }
            )

            Text(L10n.t("document.birthdate.privacy"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SLSpacing.lg)
    }

    /// The zone's birthdate is not the one that was entered. Nothing has been
    /// uploaded; a wheel can slip, and this offers the two honest ways out.
    private var dateOfBirthMismatch: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "calendar.badge.exclamationmark", tint: SLColor.warning)
            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("document.mismatch.birthdate.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.t("document.mismatch.birthdate.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: SLSpacing.md) {
                SLButton(
                    L10n.t("document.mismatch.birthdate.change"),
                    variant: .primary,
                    icon: "calendar",
                    accessibilityHint: L10n.t("document.mismatch.birthdate.change.hint")
                ) {
                    viewModel.changeBirthdate()
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
        .padding(.top, SLSpacing.xl)
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
                Label(L10n.t("document.upload.hint"), systemImage: "photo.on.rectangle")
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("document.upload.hint")
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

            Text(L10n.t(viewModel.offersConsent ? "document.privacy.offer" : "document.privacy"))
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

            // Both sides, each with its own Retake: a blurry back is retaken
            // without photographing the front again.
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(L10n.t("document.review.photos"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                DocumentSideCard(
                    side: .front,
                    documentType: viewModel.documentType,
                    image: viewModel.frontImage,
                    onRetake: { viewModel.retakeFront() }
                )
                if viewModel.documentType?.hasBack == true {
                    DocumentSideCard(
                        side: .back,
                        documentType: viewModel.documentType,
                        image: viewModel.backImage,
                        onRetake: { viewModel.retakeBack() }
                    )
                }
            }

            if viewModel.zoneIsReadable {
                SLCard(padding: SLSpacing.md) {
                    VStack(spacing: SLSpacing.sm) {
                        row(L10n.t("document.review.nationality"), nationalityText)
                        SLDivider()
                        row(L10n.t("document.review.dateOfBirth"), formatted(viewModel.mrz?.dateOfBirth))
                        if let declared = viewModel.declaredDateOfBirth, let day = ISODay.date(declared) {
                            SLDivider()
                            row(L10n.t("document.review.declaredBirthdate"), formatted(day))
                        }
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

            SLButton(
                L10n.t("document.review.continue"),
                variant: .primary,
                isEnabled: viewModel.canContinueFromReview,
                accessibilityHint: L10n.t("document.review.continue.hint")
            ) {
                viewModel.confirmDetails()
            }
            .accessibilityIdentifier("document.review.continue")
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
        // The interface's language, Western digits and the Gregorian
        // calendar, like every other date in the app.
        formatter.locale = L10n.formattingLocale
        formatter.calendar = Calendar(identifier: .gregorian)
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

    /// Two lines that fill in as they happen: the upload with its real
    /// percentage, then the server's check, until the server answers.
    private var submitting: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: isChecking ? "doc.text.magnifyingglass" : "arrow.up.doc", tint: SLColor.primary)
            VStack(spacing: SLSpacing.sm) {
                Text(isChecking ? L10n.t("document.submitting.checking") : uploadingLine)
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                Text(isChecking ? L10n.t("document.submitting.keepOpen") : submittingMessage)
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SLCard(padding: SLSpacing.md) {
                VStack(alignment: .leading, spacing: SLSpacing.md) {
                    VStack(alignment: .leading, spacing: SLSpacing.sm) {
                        stageRow(
                            done: isChecking,
                            active: !isChecking,
                            text: isChecking ? L10n.t("document.submitting.uploaded") : uploadingLine
                        )
                        if case let .uploading(fraction) = viewModel.submissionStage {
                            SLProgressBar(value: fraction, label: VideoCopy.percent(fraction))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("document.upload.progress")
                    stageRow(done: false, active: isChecking, text: L10n.t("document.submitting.checking"))
                        .accessibilityIdentifier(isChecking ? "document.checking" : "document.checking.waiting")
                }
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .animation(.easeInOut(duration: 0.25), value: viewModel.submissionStage)
    }

    private var isChecking: Bool { viewModel.submissionStage == .checking }

    /// "…deleted the moment a reviewer decides", unless the box was ticked.
    private var submittingMessage: String {
        L10n.t(viewModel.sentWithConsent ? "document.submitting.message.kept" : "document.submitting.message")
    }

    // MARK: Send (contract v34)

    /// Everything is taken; the consent card sits beside Send. Send works
    /// with or without the tick unless the server has made it required.
    private var sendStep: some View {
        VStack(spacing: SLSpacing.lg) {
            VStack(spacing: SLSpacing.xs) {
                Text(L10n.t("document.send.title"))
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("document.send.title")
                Text(L10n.t("document.send.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = viewModel.consentNotice {
                StepNoticeCard(text: notice)
            }
            if viewModel.offersConsent {
                RetentionConsentCard(isTicked: $viewModel.consentTicked) { showsPolicy = true }
            }
            SLButton(
                L10n.t("document.send.button"),
                variant: .primary,
                isLoading: viewModel.isSubmitting,
                isEnabled: viewModel.canSend,
                accessibilityHint: L10n.t("document.send.button.hint"),
                asyncAction: { await viewModel.send() }
            )
            .accessibilityIdentifier("document.send.button")
        }
        .padding(.horizontal, SLSpacing.lg)
    }

    private var uploadingLine: String {
        if case let .uploading(fraction) = viewModel.submissionStage {
            return L10n.t("document.submitting.uploading", VideoCopy.percent(fraction))
        }
        return L10n.t("document.submitting.uploaded")
    }

    private func stageRow(done: Bool, active: Bool, text: String) -> some View {
        HStack(spacing: SLSpacing.sm) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(SLColor.secondary)
                } else if active {
                    ProgressView().controlSize(.small).tint(SLColor.primary)
                } else {
                    Image(systemName: "circle").foregroundStyle(SLColor.textMuted)
                }
            }
            .frame(width: 22)
            Text(text)
                .font(SLFont.bodyEmphasis)
                .foregroundStyle(done || active ? SLColor.textPrimary : SLColor.textMuted)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The pictures did not go. Nothing is lost and nothing has to be taken
    /// again: one tap sends the same ones.
    private var sendFailed: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "wifi.exclamationmark", tint: SLColor.warning)
            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("document.sendFailed.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                if let reason = viewModel.sendFailure {
                    Text(reason)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.t("document.sendFailed.kept"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SLButton(
                L10n.t("document.sendFailed.retry"),
                variant: .primary,
                icon: "arrow.clockwise",
                accessibilityHint: L10n.t("document.sendFailed.retry.hint"),
                asyncAction: { await viewModel.retrySend() }
            )
            .accessibilityIdentifier("document.sendFailed.retry")
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.top, SLSpacing.xl)
    }

    private var submitted: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "hourglass", tint: SLColor.primary)
            // The answer to "did it arrive?", before anything else.
            Label(L10n.t("document.submitted.received"), systemImage: "checkmark.circle.fill")
                .font(SLFont.bodyEmphasis)
                .foregroundStyle(SLColor.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("document.submitted")
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
            if viewModel.canWithdraw, let onWithdrawn {
                // A wrong photo, the wrong document: taken back and sent
                // again, until somebody decides it.
                WithdrawSubmissionControl(
                    isConfirming: $viewModel.isConfirmingWithdrawal,
                    isWithdrawing: viewModel.isWithdrawing
                ) {
                    switch await viewModel.withdraw() {
                    case let .withdrawn(report): onWithdrawn(report)
                    // Decided before it arrived: the wall shows how.
                    case .nothingWaiting: onSubmitted()
                    case .failed: break
                    }
                }
            }
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


// MARK: - Photographing or choosing a side

/// One side of the document, front or back, made unmistakable: what was
/// already added sits at the top with its picture and a check; while a photo
/// is read on the phone the step says so; a photo that cannot be used says
/// why, with Retake and Choose another; and only then the camera, with
/// Photos and Files beside it.
@MainActor
private struct DocumentCaptureStep: View {
    @Bindable var viewModel: DocumentVerificationViewModel
    @State private var isPickingPhoto = false
    @State private var picked: PhotosPickerItem?
    @State private var isChoosingFile = false

    private var side: DocumentSide { viewModel.captureSide ?? .front }

    var body: some View {
        VStack(spacing: SLSpacing.md) {
            if let notice = viewModel.stepNotice {
                StepNoticeCard(text: notice)
            }
            if side == .back {
                // The front is in: its picture and a check, before the camera
                // asks for the back.
                DocumentSideCard(
                    side: .front,
                    documentType: viewModel.documentType,
                    image: viewModel.frontImage,
                    onRetake: { viewModel.retakeFront() }
                )
                .padding(.horizontal, SLSpacing.lg)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if viewModel.reading != nil {
                ReadingCard(preview: viewModel.readingPreview)
                    .padding(.horizontal, SLSpacing.lg)
            } else if let problem = viewModel.importProblem {
                ProblemCard(
                    problem: problem,
                    onRetake: { viewModel.clearImportError() },
                    onChooseAnother: { isPickingPhoto = true }
                )
                .padding(.horizontal, SLSpacing.lg)
            } else {
                DocumentCaptureView(side: side, documentType: viewModel.documentType ?? (side == .front ? .passport : .nationalId)) { jpeg, zone in
                    Task { await viewModel.useCapturedPhoto(jpeg, knownZone: zone) }
                }
                .id(side)
                uploadButtons
                if side == .front {
                    SLButton(
                        L10n.t("document.changeDocument"),
                        variant: .ghost,
                        size: .compact,
                        accessibilityHint: L10n.t("document.changeDocument.hint")
                    ) {
                        viewModel.changeDocument()
                    }
                    .accessibilityIdentifier("document.changeDocument")
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.reading)
        .animation(.easeInOut(duration: 0.25), value: viewModel.importProblem)
        .photosPicker(isPresented: $isPickingPhoto, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            // "Reading your document…" from the moment of the pick: an
            // iCloud original can take a while to come down.
            Task {
                await viewModel.importDocument(source: .photos) {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
                    return (data, false)
                }
            }
        }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: DocumentImport.fileTypes) { result in
            guard case let .success(url) = result else {
                viewModel.importFailed()
                return
            }
            Task {
                await viewModel.importDocument(source: .file) {
                    await Task.detached(priority: .userInitiated) { () -> (Data, Bool?)? in
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        guard let data = try? Data(contentsOf: url) else { return nil }
                        return (data, url.pathExtension.lowercased() == "pdf" || DocumentImport.looksLikePDF(data))
                    }.value
                }
            }
        }
    }

    /// "Upload a photo" and "Choose a file", beside the camera, for the
    /// front and back of the document only.
    private var uploadButtons: some View {
        VStack(spacing: SLSpacing.sm) {
            Text(L10n.t("document.upload.or"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
            HStack(spacing: SLSpacing.md) {
                Button {
                    isPickingPhoto = true
                } label: {
                    Label(L10n.t("document.upload.photo"), systemImage: "photo.on.rectangle")
                        .font(SLFont.caption)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: SLRadius.md).strokeBorder(SLColor.primary, lineWidth: 1))
                }
                .accessibilityIdentifier("document.upload.photo")
                Button {
                    isChoosingFile = true
                } label: {
                    Label(L10n.t("document.upload.file"), systemImage: "doc")
                        .font(SLFont.caption)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: SLRadius.md).strokeBorder(SLColor.primary, lineWidth: 1))
                }
                .accessibilityIdentifier("document.upload.file")
            }
            .disabled(viewModel.isImporting)
        }
        .padding(.horizontal, SLSpacing.lg)
    }
}

/// A side that is in: its picture, a check, "Front added", and Retake.
@MainActor
struct DocumentSideCard: View {
    let side: DocumentSide
    let documentType: DocumentType?
    let image: Data?
    let onRetake: () -> Void

    /// "Front added", "Back added" — and for a passport, whose one side is
    /// its photo page, "Photo page added".
    static func addedTitle(_ side: DocumentSide, documentType: DocumentType?) -> String {
        switch side {
        case .front:
            return documentType == .passport ? L10n.t("document.side.page.added") : L10n.t("document.side.front.added")
        case .back:
            return L10n.t("document.side.back.added")
        }
    }

    var body: some View {
        SLCard(padding: SLSpacing.md) {
            HStack(spacing: SLSpacing.md) {
                thumbnail
                Label {
                    Text(Self.addedTitle(side, documentType: documentType))
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(SLColor.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                Button(L10n.t("document.capture.retake"), action: onRetake)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.primary)
                    .accessibilityHint(Text(L10n.t(side == .front ? "document.side.retake.front.hint" : "document.side.retake.back.hint")))
                    .accessibilityIdentifier(side == .front ? "document.retake.front" : "document.retake.back")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(side == .front ? "document.sideAdded.front" : "document.sideAdded.back")
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let image, let picture = UIImage(data: image) {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
            } else {
                SLColor.surface2
            }
        }
        .frame(width: 72, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.sm))
        .overlay(RoundedRectangle(cornerRadius: SLRadius.sm).strokeBorder(SLColor.secondary, lineWidth: 1.5))
        .accessibilityHidden(true)
    }
}

/// "Reading your document…" — the picture being read, when there is one,
/// under a spinner that does not stop until the step moves on.
@MainActor
private struct ReadingCard: View {
    let preview: Data?

    var body: some View {
        SLCard(padding: SLSpacing.lg) {
            VStack(spacing: SLSpacing.md) {
                ZStack {
                    if let preview, let picture = UIImage(data: preview) {
                        Image(uiImage: picture)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 170)
                            .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
                            .opacity(0.55)
                    } else {
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(size: 52, weight: .light))
                            .foregroundStyle(SLColor.primary)
                            .frame(height: 110)
                    }
                    ProgressView()
                        .controlSize(.large)
                        .tint(SLColor.primary)
                }
                .accessibilityHidden(true)
                Text(L10n.t("document.reading.title"))
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.t("document.reading.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("document.reading")
    }
}

/// A photo or file that cannot be used: why, in plain words, and the two
/// ways on.
@MainActor
private struct ProblemCard: View {
    let problem: DocumentImportProblem
    let onRetake: () -> Void
    let onChooseAnother: () -> Void

    var body: some View {
        SLCard(padding: SLSpacing.lg) {
            VStack(spacing: SLSpacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(SLColor.warning)
                    .accessibilityHidden(true)
                VStack(spacing: SLSpacing.xs) {
                    Text(L10n.t("document.problem.title"))
                        .font(SLFont.displayM)
                        .foregroundStyle(SLColor.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(problem.message)
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("document.upload.error")
                }
                .accessibilityElement(children: .combine)
                SLButton(
                    L10n.t("document.problem.chooseAnother"),
                    variant: .primary,
                    icon: "photo.on.rectangle",
                    accessibilityHint: L10n.t("document.problem.chooseAnother.hint"),
                    action: onChooseAnother
                )
                .accessibilityIdentifier("document.problem.chooseAnother")
                SLButton(
                    L10n.t("document.capture.retake"),
                    variant: .secondary,
                    icon: "camera.fill",
                    accessibilityHint: L10n.t("document.problem.retake.hint"),
                    action: onRetake
                )
                .accessibilityIdentifier("document.problem.retake")
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("document.problem")
    }
}

/// Why the person is back on this step, at its top.
@MainActor
private struct StepNoticeCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: SLSpacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(SLColor.warning)
                .accessibilityHidden(true)
            Text(text)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(SLSpacing.md)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.warning.opacity(0.12)))
        .padding(.horizontal, SLSpacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("document.stepNotice")
    }
}
