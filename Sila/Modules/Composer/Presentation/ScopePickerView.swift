import SwiftUI

/// The audience picker — **the composer's centrepiece.**
///
/// On Sila the interesting question is not "who can see this" (everyone
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
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            HStack(spacing: SLSpacing.sm) {
                Text("WHO CAN REPLY")
                    .font(SLFont.micro)
                    .tracking(0.8)
                    .foregroundStyle(SLColor.textSecondary)
                Spacer(minLength: 0)
                Text("Everyone can read it")
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Who can reply. Everyone can read this post either way."))

            VStack(spacing: SLSpacing.sm) {
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
            HStack(alignment: .top, spacing: SLSpacing.md) {
                Image(systemName: option.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(option.isAvailable ? SLColor.textPrimary : SLColor.textMuted)
                        .lineLimit(1)

                    Text(option.unavailableReason ?? option.subtitle)
                        .font(SLFont.micro)
                        .foregroundStyle(option.isAvailable ? SLColor.textSecondary : SLColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                if !option.isAvailable {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SLColor.textMuted)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(SLColor.primary)
                }
            }
            .padding(SLSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SLRadius.md)
                    .fill(isSelected ? SLColor.primary.opacity(0.10) : SLColor.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SLRadius.md)
                    .strokeBorder(
                        isSelected ? SLColor.primary : SLColor.stroke,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: SLRadius.md))
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
        guard option.isAvailable else { return SLColor.textMuted }
        switch option.scope {
        case .international: return SLColor.primary
        case .country: return SLColor.secondary
        case .region: return SLColor.warning
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
    .background(SLColor.background)
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
    .background(SLColor.background)
    .preferredColorScheme(.dark)
}
