import Foundation

extension String {

    /// The length the server measures: Unicode code points, as Python's
    /// `len()` and Pydantic's `max_length` count them — not the characters a
    /// person sees. Arabic with harakat or a shadda, and an emoji with a skin
    /// tone, are one character on screen and several code points on the wire,
    /// so a limit counted in characters lets through text the server refuses
    /// with a bare `422`.
    public var serverLength: Int { unicodeScalars.count }

    /// The longest start of this string that fits in `limit` code points,
    /// cut between characters, never through one.
    public func clamped(toServerLength limit: Int) -> String {
        guard serverLength > limit else { return self }
        var used = 0
        var end = startIndex
        for index in indices {
            let size = self[index].unicodeScalars.count
            if used + size > limit { break }
            used += size
            end = self.index(after: index)
        }
        return String(self[..<end])
    }
}
