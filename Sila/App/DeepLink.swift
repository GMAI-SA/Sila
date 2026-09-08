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
        guard parts.count == 2 else { return nil }

        switch parts[0] {
        case "posts":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            return .post(id: id)
        case "u":
            let handle = Handle.normalised(parts[1].removingPercentEncoding ?? parts[1])
            guard !handle.isEmpty, !Handle.pathComponent(handle).isEmpty else { return nil }
            return .profile(handle: handle)
        default:
            return nil
        }
    }
}
