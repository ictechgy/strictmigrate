import Foundation

/// Strips terminal control sequences and hyperlink markup from compiler output.
///
/// `swift build` (SwiftPM ≥ 6.x) colorizes diagnostics even when piped and
/// wraps diagnostic ids in OSC-8 hyperlinks, so parsing must happen on
/// cleaned text.
enum TextCleaner {
    // `Regex` is not Sendable on this toolchain, but these constants are
    // immutable after construction and safe to share — hence `nonisolated(unsafe)`.
    /// CSI sequences (colors, cursor movement), e.g. `ESC[1;31m`.
    private nonisolated(unsafe) static let csi = try! Regex(#"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#)
    /// OSC-8 hyperlinks: `ESC]8;;URL BEL/ESC\`.
    private nonisolated(unsafe) static let osc8 = try! Regex(#"\u{1B}\]8;[^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)"#)
    /// Other OSC sequences (window title, …).
    private nonisolated(unsafe) static let oscOther = try! Regex(#"\u{1B}\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)"#)
    /// Documentation footnote emitted under each diagnostic, e.g.
    /// `[#MutableGlobalVariable]: <https://…>`.
    private nonisolated(unsafe) static let footnote = try! Regex(#"^\s*\[#[A-Za-z0-9_:]+\]:\s*<[^>]*>\s*$"#)

    static func clean(_ text: String) -> String {
        var line = text
        line = line.replacing(osc8, with: "")
        line = line.replacing(oscOther, with: "")
        line = line.replacing(csi, with: "")
        return line
    }

    static func isFootnote(_ text: String) -> Bool {
        (try? footnote.firstMatch(in: text)) != nil
    }

    /// Splits the trailing bracketed diagnostic id off a cleaned message,
    /// e.g. `… language mode [#RegionIsolation::SendingRisksDataRace]`.
    static func extractDiagnosticID(from message: String) -> (message: String, id: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.lastIndex(of: "["),
              trimmed[open...].hasPrefix("[#"),
              trimmed.hasSuffix("]")
        else { return (trimmed, nil) }

        let tag = String(trimmed[trimmed.index(open, offsetBy: 2)..<trimmed.index(before: trimmed.endIndex)])
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:")
        guard !tag.isEmpty, tag.unicodeScalars.allSatisfy(allowed.contains) else {
            return (trimmed, nil)
        }

        var head = String(trimmed[..<open])
        while head.hasSuffix(" ") { head.removeLast() }
        return (head, tag)
    }
}
