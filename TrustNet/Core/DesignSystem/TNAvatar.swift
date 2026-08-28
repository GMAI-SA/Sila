import SwiftUI

/// A user avatar with an optional animated verification ring. **Component 5 of 13.**
///
/// Falls back to monogram initials on a deterministic surface when no image URL
/// is available, so the component never renders an empty hole.
///
/// ```swift
/// TNAvatar(url: user.avatarURL, initials: "AA", size: .lg, isVerified: true)
/// ```
public struct TNAvatar: View {

    /// Standard avatar diameters.
    public enum Size {
        case sm, md, lg, xl

        /// Diameter in points.
        public var diameter: CGFloat {
            switch self {
            case .sm: return 32
            case .md: return 44
            case .lg: return 64
            case .xl: return 96
            }
        }

        var initialsFont: Font {
            switch self {
            case .sm: return TNFont.micro
            case .md: return TNFont.caption
            case .lg: return TNFont.bodyEmphasis
            case .xl: return TNFont.displayM
            }
        }

        var ringWidth: CGFloat {
            switch self {
            case .sm: return 1.5
            case .md: return 2
            case .lg: return 2.5
            case .xl: return 3
            }
        }
    }

    private let url: URL?
    private let initials: String
    private let size: Size
    private let isVerified: Bool
    private let displayName: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringPhase: CGFloat = 0

    /// Creates an avatar.
    /// - Parameters:
    ///   - url: Remote image. `nil` renders the monogram fallback.
    ///   - initials: One or two characters used for the fallback.
    ///   - size: Diameter preset.
    ///   - isVerified: Draws the rotating brand ring.
    ///   - displayName: Used for the accessibility label when available.
    public init(
        url: URL? = nil,
        initials: String = "?",
        size: Size = .md,
        isVerified: Bool = false,
        displayName: String? = nil
    ) {
        self.url = url
        self.initials = String(initials.prefix(2)).uppercased()
        self.size = size
        self.isVerified = isVerified
        self.displayName = displayName
    }

    public var body: some View {
        ZStack {
            if isVerified {
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [TNColor.primary, TNColor.secondary, TNColor.primary],
                            center: .center
                        ),
                        lineWidth: size.ringWidth
                    )
                    .rotationEffect(.degrees(ringPhase))
                    .frame(width: size.diameter + size.ringWidth * 3,
                           height: size.diameter + size.ringWidth * 3)
            }

            image
                .frame(width: size.diameter, height: size.diameter)
                .clipShape(Circle())
        }
        .frame(width: size.diameter + size.ringWidth * 3,
               height: size.diameter + size.ringWidth * 3)
        .onAppear {
            guard isVerified, !reduceMotion else { return }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                ringPhase = 360
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityHint(Text("Profile picture"))
    }

    @ViewBuilder
    private var image: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let loaded):
                    loaded.resizable().scaledToFill()
                default:
                    monogram
                }
            }
        } else {
            monogram
        }
    }

    private var monogram: some View {
        ZStack {
            LinearGradient(
                colors: [TNColor.surface2, TNColor.surface1],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initials)
                .font(size.initialsFont)
                .foregroundStyle(TNColor.textSecondary)
        }
    }

    private var accessibilityText: String {
        let who = displayName ?? "User \(initials)"
        return isVerified ? "\(who), verified" : who
    }
}

#Preview("TNAvatar") {
    HStack(spacing: TNSpacing.lg) {
        TNAvatar(initials: "AA", size: .sm)
        TNAvatar(initials: "AA", size: .md, isVerified: true)
        TNAvatar(initials: "SN", size: .lg, isVerified: true, displayName: "Sara N.")
        TNAvatar(initials: "TN", size: .xl)
    }
    .padding(TNSpacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TNColor.background)
}
