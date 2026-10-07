import Foundation
import Observation
import SwiftUI

/// Settings › Privacy › **Verification photos** (contract v34 §7.8).
///
/// Shown only while `GET /verification/status` answers `verification_photos`
/// — whatever the consent switch says, so a person can always withdraw.
/// "Delete my verification photos" asks in place, withdraws the consent,
/// and reads the status again, so the row goes once nothing is kept.
@MainActor
@Observable
public final class VerificationPhotosViewModel {

    /// What is kept, or `nil` — then there is no row.
    public private(set) var photos: VerificationPhotos?
    /// The in-place confirmation is open.
    public var isConfirming = false
    public private(set) var isWithdrawing = false
    /// The sentence to show once a withdrawal went, or why it did not.
    public var toast: SLToastMessage? {
        didSet { if let toast { onToast?(toast) } }
    }
    /// Hands each toast to the screen that hosts the row.
    public var onToast: (@MainActor (SLToastMessage) -> Void)?

    private let service: VerificationServiceProtocol

    public init(service: VerificationServiceProtocol) {
        self.service = service
    }

    /// The row is on screen.
    public var showsRow: Bool { photos != nil }

    /// "Kept in your verification file since {date}".
    public var detail: String {
        guard let since = photos?.consentedAt else { return L10n.t("settings.privacy.verificationPhotos.detail.undated") }
        let formatter = DateFormatter()
        formatter.locale = L10n.formattingLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return L10n.t("settings.privacy.verificationPhotos.detail", formatter.string(from: since))
    }

    /// Reads the status. A failure leaves the row as it was.
    public func load() async {
        guard let report = try? await service.verificationStatus() else { return }
        photos = report.verificationPhotos
    }

    /// Withdraws the consent and deletes the kept photographs, then reads the
    /// status again.
    public func withdraw() async {
        guard !isWithdrawing else { return }
        isWithdrawing = true
        defer { isWithdrawing = false }
        do {
            _ = try await service.withdrawPhotoConsent()
            isConfirming = false
            toast = .success(L10n.t("settings.privacy.verificationPhotos.done"))
            photos = nil
            await load()
        } catch let error as APIError {
            if !error.isCancellation { toast = .error(error.userMessage) }
        } catch {
            toast = .error(L10n.t("common.somethingWentWrong"))
        }
    }
}

/// The row itself, with its in-place confirmation.
@MainActor
public struct VerificationPhotosRow: View {

    @Bindable var viewModel: VerificationPhotosViewModel

    public init(viewModel: VerificationPhotosViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        SLCard {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(L10n.t("settings.privacy.verificationPhotos.row"))
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .accessibilityIdentifier("settings.privacy.verificationPhotos.row")
                Text(viewModel.detail)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if viewModel.isConfirming {
                    Text(L10n.t("settings.privacy.verificationPhotos.confirm"))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.privacy.verificationPhotos.confirm")
                    HStack(spacing: SLSpacing.md) {
                        SLButton(
                            L10n.t("settings.privacy.verificationPhotos.button"),
                            variant: .destructive,
                            size: .compact,
                            isLoading: viewModel.isWithdrawing,
                            asyncAction: { await viewModel.withdraw() }
                        )
                        .accessibilityIdentifier("settings.privacy.verificationPhotos.confirmButton")
                        SLButton(
                            L10n.t("common.cancel"),
                            variant: .secondary,
                            size: .compact,
                            action: { viewModel.isConfirming = false }
                        )
                    }
                } else {
                    SLButton(
                        L10n.t("settings.privacy.verificationPhotos.button"),
                        variant: .secondary,
                        size: .compact,
                        action: { viewModel.isConfirming = true }
                    )
                    .accessibilityIdentifier("settings.privacy.verificationPhotos.button")
                }
            }
        }
    }
}
