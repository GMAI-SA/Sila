import SwiftUI

/// A strip across the top while the app runs on this device's copy of the
/// account because the server could not be reached at launch.
///
/// It says two things, because a person who opened the app in a lift needs
/// both: what they are looking at may be out of date, and they do not have to
/// do anything about it. It goes by itself once the server answers.
@MainActor
struct OfflineSessionBanner: View {

    var body: some View {
        HStack(spacing: SLSpacing.sm) {
            Image(systemName: "wifi.slash")
                .font(SLFont.caption)
                .foregroundStyle(SLColor.warning)
                .accessibilityHidden(true)
            Text(L10n.t("app.offline.banner"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(SLColor.surface2)
        .overlay(alignment: .bottom) {
            SLColor.warning.opacity(0.4).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session.offline")
    }
}

#Preview("OfflineSessionBanner") {
    OfflineSessionBanner()
}
