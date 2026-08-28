import SwiftUI

/// The audience picker — **the composer's centrepiece.**
///
/// On TrustNet the interesting question is not "who can see this" (everyone
/// can) but "who can answer it": anyone verified, only your verified
/// compatriots, or only a region. That choice is a country-verified identity
/// made useful, so it sits at the top of the composer rather than behind a
/// toolbar icon.
///
/// Options the author cannot use are **shown and explained**, never hidden. An
/// account with no country badge needs to learn that the flag comes from
/// identity verification; a blank space teaches nothing.
///
/// > Note: This replaces the Phase-4 spec's
/// > `AudiencePickerView (Everyone / Verified Only / Following / Circle)`.
/// > None of those concepts exist in this product or its API.
@MainActor
struct ScopePickerSection: View {

    let viewModel: ComposerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: TNSpacing.sm) {
            HStack(spacing: TNSpacing.sm) {
                Text("WHO CAN REPLY")
                    .font(TNFont.micro)
                    .tracking(0.8)
                    .foregroundStyle(TNColor.textSecondary)
                Spacer(minLength: 0)
                Text("Everyone can read it")
                    .font(TNFont.micro)
                    .foregroundStyle(TNColor.textMuted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Who can reply. Everyone can read this post either way."))

            VStack(spacing: TNSpacing.sm) {
                ForEach(viewModel.scopeOptions) { option in
                    ScopeOptionRow(
                        option: option,
                        isSelected: option.scope == viewModel.scope,
                        onTap: { viewModel.select(option) }
                    )
                }
            }
        }
    }
}

/// One row of the scope picker.
@MainActor
struct ScopeOptionRow: View {

    let option: ScopeOption
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: TNSpacing.md) {
                Image(systemName: option.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(TNFont.bodyEmphasis)
                        .foregroundStyle(option.isAvailable ? TNColor.textPrimary : TNColor.textMuted)
                        .lineLimit(1)

                    Text(option.unavailableReason ?? option.subtitle)
                        .font(TNFont.micro)
                        .foregroundStyle(option.isAvailable ? TNColor.textSecondary : TNColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                if !option.isAvailable {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TNColor.textMuted)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(TNColor.primary)
                }
            }
            .padding(TNSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TNRadius.md)
                    .fill(isSelected ? TNColor.primary.opacity(0.10) : TNColor.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TNRadius.md)
                    .strokeBorder(
                        isSelected ? TNColor.primary : TNColor.stroke,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: TNRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(option.accessibilityLabel))
        .accessibilityHint(Text(
            option.isAvailable
                ? "Limits replies to this audience"
                : "Unavailable. Selecting it explains why"
        ))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var iconTint: Color {
        guard option.isAvailable else { return TNColor.textMuted }
        switch option.scope {
        case .international: return TNColor.primary
        case .country: return TNColor.secondary
        case .region: return TNColor.warning
        }
    }
}

#Preview("ScopePicker — with a country badge") {
    ScrollView {
        ScopePickerSection(
            viewModel: ComposerViewModel(
                context: .newPost,
                author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
                composer: ComposerServiceMock(),
                analytics: RecordingAnalyticsClient()
            )
        )
        .padding()
    }
    .background(TNColor.background)
    .preferredColorScheme(.dark)
}

#Preview("ScopePicker — no badge yet") {
    ScrollView {
        ScopePickerSection(
            viewModel: ComposerViewModel(
                context: .newPost,
                author: ComposerAuthor(handle: "newcomer", countryCode: nil, isVerified: false),
                composer: ComposerServiceMock(),
                analytics: RecordingAnalyticsClient()
            )
        )
        .padding()
    }
    .background(TNColor.background)
    .preferredColorScheme(.dark)
}
