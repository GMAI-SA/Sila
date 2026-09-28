import Foundation

/// What a signed-in session leaves on this device outside the Keychain, and
/// the one place that sweeps it away.
///
/// The Keychain holds the token and the cached account, written
/// `WhenUnlockedThisDeviceOnly` and wiped at sign-out. Two other things can
/// outlive a session, and both would hand the previous account to whoever
/// signs in next on the same phone, or to anybody who copies the app's files:
///
/// * **The account export.** `GET /me/export` is the whole account — email,
///   phone, every post, follows, messages — written to `tmp` so the share
///   sheet can reach it. iOS purges `tmp` when it likes, which may be never.
/// * **The shared URL cache.** The API client keeps no cache of its own, but
///   images drawn by `AsyncImage` and GIFs go through `URLCache.shared`, whose
///   `Cache.db` has only default data protection.
///
/// A value type rather than a set of statics so tests can point it at their
/// own directory and cache instead of the host app's.
public struct SessionLeftovers: @unchecked Sendable {

    /// The file name the export is written under. Fixed, and overwritten each
    /// time, so there is only ever one copy to remove.
    public static let accountExportFileName = "sila-account-export.json"

    /// Where the export is written.
    public let directory: URL
    /// The cache swept at sign-out.
    public let responseCache: URLCache
    /// Videos on their way up (contract v28): the picked file, the
    /// compressed one, its pieces and its plan. `nil` sweeps none.
    public let videoUploads: URL?

    /// - Parameters:
    ///   - directory: Defaults to the app's temporary directory.
    ///   - responseCache: Defaults to `URLCache.shared`.
    ///   - videoUploads: Defaults to where ``VideoUploadStore`` keeps them.
    public init(
        directory: URL = FileManager.default.temporaryDirectory,
        responseCache: URLCache = .shared,
        videoUploads: URL? = VideoUploadStore().directory
    ) {
        self.directory = directory
        self.responseCache = responseCache
        self.videoUploads = videoUploads
    }

    /// The export's path.
    public var accountExportURL: URL {
        directory.appendingPathComponent(Self.accountExportFileName)
    }

    /// Writes the export where the share sheet can reach it.
    ///
    /// With complete file protection: the file is unreadable while the phone
    /// is locked, for as long as it exists at all.
    @discardableResult
    public func writeAccountExport(_ data: Data) throws -> URL {
        let url = accountExportURL
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Removes the export, if there is one. Removing nothing is not an error.
    public func removeAccountExport() {
        try? FileManager.default.removeItem(at: accountExportURL)
    }

    /// Everything a session leaves behind: the export, every cached
    /// response, and any video that had not finished going up — whether the
    /// person signed out or the server ended the session.
    public func sweep() {
        removeAccountExport()
        responseCache.removeAllCachedResponses()
        if let videoUploads {
            try? FileManager.default.removeItem(at: videoUploads)
        }
    }
}
