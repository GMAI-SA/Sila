import Foundation

/// One caption: what is said, and when.
public struct WebVTTCue: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Reads the server's WebVTT captions (contract v28 §7).
///
/// The app draws captions itself rather than through the player's own
/// subtitle menu, because the contract asks for them to be named "Arabic
/// (automatic)" wherever they are named, and the stream's menu can only say
/// what the playlist says. It also lets an Arabic caption run right to left
/// on an English phone.
///
/// Deliberately forgiving: a cue it cannot read is skipped, never the file.
public enum WebVTT {

    /// Every cue in the file, in time order.
    public static func parse(_ source: String) -> [WebVTTCue] {
        let normalised = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [WebVTTCue] = []
        for block in normalised.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex]
            let halves = timing.components(separatedBy: "-->")
            guard halves.count == 2,
                  let start = timestamp(halves[0].trimmingCharacters(in: .whitespaces)),
                  // Settings (`align:start`, …) may follow the end time.
                  let endToken = halves[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
                  let end = timestamp(String(endToken)),
                  end > start else { continue }
            let text = lines[(timingIndex + 1)...]
                .map(stripTags)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            cues.append(WebVTTCue(start: start, end: end, text: text))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// The words on screen at `time`, or `nil` between cues. Overlapping cues
    /// are shown together, earliest first.
    public static func text(at time: TimeInterval, in cues: [WebVTTCue]) -> String? {
        let live = cues.filter { $0.start <= time && time < $0.end }
        guard !live.isEmpty else { return nil }
        return live.map(\.text).joined(separator: "\n")
    }

    /// `00:01:02.500` or `01:02.500` → seconds.
    static func timestamp(_ raw: String) -> TimeInterval? {
        let parts = raw.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        let secondsPart = parts[parts.count - 1].replacingOccurrences(of: ",", with: ".")
        guard let seconds = Double(secondsPart),
              let minutes = Double(parts[parts.count - 2]) else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let hours, seconds >= 0, minutes >= 0, hours >= 0 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// `<v Speaker>`, `<c.red>`, `<i>` and the like carry no words.
    private static func stripTags(_ line: String) -> String {
        var output = ""
        var inTag = false
        for character in line {
            if character == "<" { inTag = true; continue }
            if character == ">" { inTag = false; continue }
            if !inTag { output.append(character) }
        }
        return output
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&lrm;", with: "\u{200E}")
            .replacingOccurrences(of: "&rlm;", with: "\u{200F}")
    }
}
