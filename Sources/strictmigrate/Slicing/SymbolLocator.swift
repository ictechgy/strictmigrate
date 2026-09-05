import Foundation

/// A declaration found in a Swift source file, with its 1-based line span.
struct SymbolRange: Equatable, Sendable {
    /// Bare declaration name, e.g. `renderSync` for
    /// `public static func renderSync(_ renderer: ThumbnailRenderer)`.
    /// Overloads of one name share one symbol — one task fixes the group.
    var name: String
    var kind: String
    var startLine: Int
    var endLine: Int

    var display: String { "\(kind) \(name)" }
}

/// Locates the declaration enclosing a diagnostic's line.
///
/// Line-based heuristic: tracks brace depth (comments and string literals
/// excluded), confirms a pending declaration at its opening brace, and closes
/// it where the depth returns. Precise enough for task slicing — the journal
/// records names, not offsets, so line drift between slicing and fixing is
/// tolerated.
enum SymbolLocator {
    private static let declarationKeywords: Set<String> = [
        "func", "var", "let", "class", "struct", "enum", "actor",
        "extension", "protocol", "typealias", "associatedtype",
        "subscript", "init", "deinit",
    ]
    private static let modifierKeywords: Set<String> = [
        "public", "private", "internal", "fileprivate", "open", "final",
        "static", "class", "override", "required", "convenience", "lazy",
        "weak", "unowned", "mutating", "nonmutating", "nonisolated",
        "isolated", "indirect", "dynamic", "optional", "reasync",
        "distributed", "borrowing", "consuming", "set",
    ]

    static func symbols(in source: String) -> [SymbolRange] {
        var results: [SymbolRange] = []
        var openDeclarations: [(name: String, kind: String, startLine: Int, depth: Int)] = []
        var pending: (name: String, kind: String, line: Int)?
        var depth = 0
        var inBlockComment = false

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let (code, stillInBlockComment) = stripComments(String(rawLine), inBlockComment: inBlockComment)
            inBlockComment = stillInBlockComment
            if code.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if pending == nil, let declaration = firstDeclaration(in: code, depth: depth) {
                pending = (declaration.name, declaration.kind, lineNumber)
            }

            // Braces are processed left-to-right so mixed lines like
            // `} else {` keep the surrounding declaration open.
            var lineOpenedBrace = false
            for character in code {
                switch character {
                case "{":
                    if let declaration = pending {
                        openDeclarations.append((declaration.name, declaration.kind, declaration.line, depth))
                        pending = nil
                    }
                    depth += 1
                    lineOpenedBrace = true
                case "}":
                    depth -= 1
                    while let top = openDeclarations.last, top.depth >= depth {
                        openDeclarations.removeLast()
                        results.append(
                            SymbolRange(name: top.name, kind: top.kind, startLine: top.startLine, endLine: lineNumber)
                        )
                    }
                default:
                    break
                }
            }
            if let declaration = pending, !lineOpenedBrace {
                // Brace-less declarations close on their own line. Stored
                // properties and typealiases never open a brace; other kinds
                // (func/class/…) without a brace here are mid-multi-line-signature
                // and stay pending until their brace arrives.
                let selfClosing = code.hasSuffix(";")
                    || declaration.kind == "var"
                    || declaration.kind == "let"
                    || declaration.kind == "typealias"
                    || declaration.kind == "associatedtype"
                if selfClosing {
                    results.append(
                        SymbolRange(name: declaration.name, kind: declaration.kind, startLine: declaration.line, endLine: lineNumber)
                    )
                    pending = nil
                }
            }
        }
        // Unterminated tail (snippet input, unbalanced braces): keep what we have.
        for leftover in openDeclarations {
            results.append(SymbolRange(name: leftover.name, kind: leftover.kind, startLine: leftover.startLine, endLine: .max))
        }
        if let pending {
            results.append(SymbolRange(name: pending.name, kind: pending.kind, startLine: pending.line, endLine: .max))
        }
        return results
    }

    /// Innermost declaration whose span contains `line` (deepest start wins,
    /// so a method body resolves to the method, not the enclosing type).
    static func innermostSymbol(containingLine line: Int, in symbols: [SymbolRange]) -> SymbolRange? {
        symbols
            .filter { line >= $0.startLine && line <= $0.endLine }
            .max { $0.startLine < $1.startLine }
    }

    /// Display name for a diagnostic: the enclosing declaration, or
    /// `"(file scope)"` for top-level code.
    static func symbolName(for diagnostic: ConcurrencyDiagnostic, symbols: [SymbolRange]) -> String {
        innermostSymbol(containingLine: diagnostic.line, in: symbols)?.name ?? "(file scope)"
    }

    // MARK: - Tokenizing

    private static func firstDeclaration(in line: String, depth: Int) -> (name: String, kind: String)? {
        var keyword: String?
        let words = tokens(line)
        for (index, token) in words.enumerated() {
            if token.hasPrefix("@") { continue }
            if let keyword {
                // First token after the declaration keyword is the name.
                if keyword == "init" || keyword == "deinit" || keyword == "subscript" {
                    return (keyword, keyword)
                }
                return (token, keyword)
            }
            // `class` is both a declaration keyword and a modifier (`class func`);
            // the next token decides.
            if token == "class" {
                let next = index + 1 < words.count ? words[index + 1] : ""
                if ["func", "var", "let"].contains(next) { continue }
                keyword = token
                continue
            }
            if modifierKeywords.contains(token) { continue }
            if declarationKeywords.contains(token) {
                // Local var/let inside a function body is not a useful task boundary.
                if (token == "var" || token == "let") && depth >= 2 { return nil }
                keyword = token
                continue
            }
            return nil // some other statement, not a declaration line
        }
        // `init()`, `deinit`, `subscript(x)` carry no name token.
        if let keyword, ["init", "deinit", "subscript"].contains(keyword) {
            return (keyword, keyword)
        }
        return nil
    }

    private static func tokens(_ line: String) -> [String] {
        line.split { !$0.isLetter && $0 != "_" }.map(String.init)
    }

    /// Removes `//` comments and blanks out string literals / `/* */` bodies,
    /// leaving brace structure intact for counting.
    private static func stripComments(_ line: String, inBlockComment: Bool) -> (String, Bool) {
        var output = ""
        var inBlockComment = inBlockComment
        var inString = false
        var escaped = false
        var previous: Character = " "

        for character in line {
            if inBlockComment {
                if previous == "*" && character == "/" {
                    inBlockComment = false
                    previous = " "
                    continue
                }
                previous = character
                continue
            }
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                previous = character
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "/" where previous == "/":
                return (String(output.dropLast()), inBlockComment)
            case "*" where previous == "/":
                output.removeLast()
                inBlockComment = true
                previous = " "
                continue
            default:
                output.append(character)
            }
            previous = character
        }
        return (output, inBlockComment)
    }
}
