import Foundation

/// Every sentence a video puts in front of somebody (contract v28 §10–§11),
/// in the language the app is set to — never English and Arabic side by side.
public enum VideoCopy {

    // MARK: - The author's own post

    /// What the author reads on their own post, by where its video stands.
    ///
    /// `nil` when there is nothing to say: a `ready` video is simply played,
    /// and a video `removed` for any reason but a moderator is a post being
    /// deleted or a draft given up on. `held` says "being reviewed", never
    /// why: the screen's reasons are for moderators.
    public static func authorNotice(for video: PostVideo) -> String? {
        switch video.status {
        case .ready, .uploading:
            return nil
        case .processing:
            return L10n.t("video.status.processing")
        case .held:
            return L10n.t("video.status.held")
        case .failed:
            return failure(code: video.failure?.code)
        case .removed:
            return video.removedByModerator ? L10n.t("video.status.removedByModerator") : nil
        }
    }

    /// The words for a failed video, by its `failure.code`.
    public static func failure(code: String?) -> String {
        switch code {
        case "video_too_long": return L10n.t("video.error.tooLong")
        case "video_unreadable": return L10n.t("video.error.unreadable")
        case "upload_expired": return L10n.t("video.error.uploadExpired")
        default: return L10n.t("video.error.processingFailed")
        }
    }

    // MARK: - Captions

    /// "Arabic (automatic)" / «العربية (تلقائية)». Machine-made captions are
    /// always labelled so, wherever they are named.
    public static func captionLabel(_ language: String) -> String {
        switch language.lowercased() {
        case "ar": return L10n.t("video.captions.ar")
        case "en": return L10n.t("video.captions.en")
        default:
            // A language this build has no words for is named by the system,
            // in the app's language, and still said to be automatic.
            let name = L10n.locale.localizedString(forLanguageCode: language) ?? language
            return L10n.t("video.captions.other", name)
        }
    }

    // MARK: - Progress

    /// `0.42` → "42%", with Western digits in both languages.
    public static func percent(_ fraction: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.locale = L10n.formattingLocale
        // Never 100% before the server has the last byte.
        let clamped = min(max(fraction, 0), 1)
        return formatter.string(from: NSNumber(value: clamped)) ?? "\(Int(clamped * 100))%"
    }

    /// "Uploading… 42%", from the bytes the server has plus those in flight.
    public static func uploading(_ fraction: Double) -> String {
        L10n.t("video.status.uploading", percent(fraction))
    }

    /// "Getting your video ready… 42%" — the compression on the phone.
    public static func preparing(_ fraction: Double) -> String {
        L10n.t("video.status.preparing", percent(fraction))
    }

    /// "1:34" — a video's length, left to right in both languages.
    public static func duration(_ seconds: Double?) -> String {
        VoiceTime.label(seconds ?? 0)
    }
}

/// A picked video the server would refuse — over three minutes — held so it
/// can be trimmed rather than simply turned away.
public struct VideoRefusal: Equatable, Sendable {
    public let source: URL
    public let durationSeconds: Double

    public init(source: URL, durationSeconds: Double) {
        self.source = source
        self.durationSeconds = durationSeconds
    }

    /// "This video is longer than 3 minutes. Trim it and try again."
    public var message: String { L10n.t("video.error.tooLong") }
}
