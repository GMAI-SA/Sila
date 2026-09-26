import Foundation

/// Where things live on the web, and what a link into the app points at.
///
/// One vocabulary for both directions. A share carries ``Permalink/post(_:)``;
/// a tap on that link — from Messages, Safari, anywhere — arrives back as
/// ``DeepLink/parse(_:)``. Keeping them together is what stops the app from
/// producing links it cannot read.
public enum Permalink {

    /// The web client's origin.
    public static var base: URL { URL(string: AppConfig.webBaseURLString)! }

    /// A post's page.
    public static func post(_ id: UUID) -> URL {
        base.appendingPathComponent("posts").appendingPathComponent(id.uuidString.lowercased())
    }

    /// A profile's page.
    public static func event(_ id: UUID) -> URL {
        base.appendingPathComponent("events").appendingPathComponent(id.uuidString.lowercased())
    }

    public static func room(_ id: UUID) -> URL {
        base.appendingPathComponent("rooms").appendingPathComponent(id.uuidString.lowercased())
    }

    public static func profile(_ handle: String) -> URL {
        base.appendingPathComponent("u").appendingPathComponent(Handle.pathComponent(handle))
    }
}

/// A link into the app that names a screen.
public enum DeepLink: Equatable, Sendable {
    /// A post, by id.
    case post(id: UUID)
    /// A profile, by handle.
    case profile(handle: String)
    /// A room, by id — handed over by the first-run flow's last card.
    case room(id: UUID)
    /// An event (contract v23).
    case event(id: UUID)
    /// A vouch link someone was sent (contract v24): `/vouch/{token}`. The
    /// token is all it carries — who is vouching is read from the server.
    case vouchInvite(token: String)
    /// The voucher's list: `/vouching`. Where a claim, a graduation or a
    /// moderator's question lands.
    case vouching
    /// The person's own vouch and the way to verify: `/vouch`.
    case ownVouch

    /// Reads a URL the system handed the app.
    ///
    /// Only the web client's own host is honoured, on `https`, so a look-alike
    /// domain cannot drive navigation. Anything else — the site root, a legal
    /// page, an unknown path — is `nil`, and the app simply opens where it was.
    public static func parse(_ url: URL) -> DeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == Permalink.base.host?.lowercased()
        else { return nil }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count == 1 {
            switch parts[0] {
            case "vouching": return .vouching
            case "vouch": return .ownVouch
            default: return nil
            }
        }
        guard parts.count == 2 else { return nil }

        switch parts[0] {
        case "posts":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            return .post(id: id)
        case "events":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            return .event(id: id)
        case "rooms":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            return .room(id: id)
        case "vouch":
            guard let token = VouchLinkToken.normalised(parts[1]) else { return nil }
            return .vouchInvite(token: token)
        case "u":
            let handle = Handle.normalised(parts[1].removingPercentEncoding ?? parts[1])
            guard !handle.isEmpty, !Handle.pathComponent(handle).isEmpty else { return nil }
            return .profile(handle: handle)
        default:
            return nil
        }
    }
}

/// The opaque part of a vouch link.
///
/// The server mints URL-safe base64 (`secrets.token_urlsafe(24)`, 32
/// characters); anything outside that alphabet, or of an implausible length,
/// is not a link Sila made and is not sent anywhere — it would only become
/// a path the app did not mean to build.
public enum VouchLinkToken {
    public static func normalised(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...128).contains(token.count),
              token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return token
    }

    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
}
