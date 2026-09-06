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

/// Source language of a file, by extension. Kotlin matters at KMP boundaries:
/// Swift-side strict-concurrency diagnostics name Kotlin-exported types whose
/// fixes live in `.kt` declarations.
enum SourceLanguage: Sendable, Equatable {
    case swift
    case kotlin
    case unknown

    init(path: String) {
        if path.hasSuffix(".swift") {
            self = .swift
        } else if path.hasSuffix(".kt") || path.hasSuffix(".kts") {
            self = .kotlin
        } else {
            self = .unknown
        }
    }
}

/// Locates the declaration enclosing a diagnostic's line, in Swift or Kotlin
/// source.
///
/// Line-based heuristic: tracks brace depth (comments and string literals
/// excluded), confirms a pending declaration at its opening brace, and closes
/// it where the depth returns. Precise enough for task slicing — the journal
/// records names, not offsets, so line drift between slicing and fixing is
/// tolerated.
enum SymbolLocator {
    private struct Lexicon: Sendable {
        var declarations: Set<String>
        var modifiers: Set<String>
        var namelessDeclarations: Set<String>
        var isKotlin: Bool

        static let swift = Lexicon(
            declarations: [
                "func", "var", "let", "class", "struct", "enum", "actor",
                "extension", "protocol", "typealias", "associatedtype",
                "subscript", "init", "deinit",
            ],
            modifiers: [
                "public", "private", "internal", "fileprivate", "open", "final",
                "static", "class", "override", "required", "convenience", "lazy",
                "weak", "unowned", "mutating", "nonmutating", "nonisolated",
                "isolated", "indirect", "dynamic", "optional", "reasync",
                "distributed", "borrowing", "consuming", "set",
            ],
            namelessDeclarations: ["init", "deinit", "subscript"],
            isKotlin: false
        )

        // Kotlin: `enum class`/`value class`/`data class` arrive via the
        // modifier set; `get`/`set` property accessors nest inside the
        // property's symbol.
        static let kotlin = Lexicon(
            declarations: [
                "fun", "val", "var", "class", "object", "interface",
                "typealias", "constructor", "init", "get", "set",
            ],
            modifiers: [
                "private", "protected", "internal", "public", "expect", "actual",
                "final", "open", "abstract", "sealed", "const", "external",
                "override", "lateinit", "tailrec", "vararg", "suspend", "inner",
                "enum", "value", "data", "annotation", "companion", "inline",
                "infix", "operator", "reified", "crossinline", "noinline",
                "out", "in", "dynamic", "mutable",
            ],
            namelessDeclarations: ["constructor", "init", "get", "set"],
            isKotlin: true
        )
    }

    static func symbols(in source: String, language: SourceLanguage = .swift) -> [SymbolRange] {
        symbols(in: source, lexicon: language == .kotlin ? .kotlin : .swift)
    }

    private static func symbols(in source: String, lexicon: Lexicon) -> [SymbolRange] {
        var results: [SymbolRange] = []
        var openDeclarations: [(name: String, kind: String, startLine: Int, depth: Int)] = []
        var pending: (name: String, kind: String, line: Int)?
        var depth = 0
        var stripper = LineStripper()

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let code = stripper.strip(String(rawLine), kotlin: lexicon.isKotlin)
            if code.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if let declaration = firstDeclaration(in: code, depth: depth, lexicon: lexicon) {
                if let pending {
                    // A new declaration while one is still pending means the
                    // pending one was a single-liner we failed to recognize
                    // (e.g. Kotlin expression bodies ending in a string) —
                    // close it on its own line and take over, so it cannot
                    // steal the next declaration's brace.
                    results.append(
                        SymbolRange(name: pending.name, kind: pending.kind, startLine: pending.line, endLine: pending.line)
                    )
                }
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
                // properties and typealiases never open a brace; Kotlin
                // function signatures without bodies (`expect fun`, interface
                // members) end at the parameter list. Other kinds without a
                // brace here are mid-multi-line-signature and stay pending.
                let selfClosing = code.hasSuffix(";") || code.hasSuffix(")")
                    || ["var", "let", "val", "typealias"].contains(declaration.kind)
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

    private static func firstDeclaration(in line: String, depth: Int, lexicon: Lexicon) -> (name: String, kind: String)? {
        var keyword: String?
        let words = tokens(line)
        for (index, token) in words.enumerated() {
            if token.hasPrefix("@") { continue }
            if let keyword {
                // First token after the declaration keyword is the name.
                if lexicon.namelessDeclarations.contains(keyword) {
                    return (keyword, keyword)
                }
                return (token, keyword)
            }
            // Swift: `class` is both a declaration keyword and a modifier
            // (`class func`); the next token decides.
            if token == "class", !lexicon.isKotlin {
                let next = index + 1 < words.count ? words[index + 1] : ""
                if ["func", "var", "let"].contains(next) { continue }
                keyword = token
                continue
            }
            if lexicon.modifiers.contains(token) { continue }
            if lexicon.declarations.contains(token) {
                // Local var/let/val inside a function body is not a useful
                // task boundary (Swift depth ≥ 2; Kotlin ditto).
                if ["var", "let", "val"].contains(token), depth >= 2 { return nil }
                keyword = token
                continue
            }
            return nil // some other statement, not a declaration line
        }
        // `init()`, accessors, `constructor(…)` carry no name token.
        if let keyword, lexicon.namelessDeclarations.contains(keyword) {
            return (keyword, keyword)
        }
        return nil
    }

    private static func tokens(_ line: String) -> [String] {
        line.split { !$0.isLetter && $0 != "_" }.map(String.init)
    }
}

/// Removes `//`/`/* */` comments and blanks out string literals, leaving brace
/// structure intact for counting. Carries multi-line block-comment and raw-
/// string state across lines; Kotlin mode adds nested block comments,
/// `"""` raw strings, and single-quoted character literals.
private struct LineStripper {
    private var blockCommentDepth = 0
    private var inRawString = false

    mutating func strip(_ line: String, kotlin: Bool) -> String {
        var output = ""
        var inString = false
        var inChar = false
        var escaped = false
        var depth = blockCommentDepth

        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index) < line.endIndex ? line[line.index(after: index)] : nil

            if depth > 0 {
                // Kotlin nests block comments: /* /* */ */
                if character == "/", next == "*" {
                    if kotlin { depth += 1 }
                    index = line.index(after: index)
                } else if character == "*", next == "/" {
                    depth -= 1
                    index = line.index(after: index)
                } else {
                    index = line.index(after: index)
                }
                continue
            }
            if inRawString {
                let i1 = line.index(after: index)
                let i2 = i1 < line.endIndex ? line.index(after: i1) : i1
                if character == "\"", i1 < line.endIndex, line[i1] == "\"", i2 < line.endIndex, line[i2] == "\"" {
                    inRawString = false
                    index = i2 // loop advances past the closing quote
                }
                index = line.index(after: index)
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
                index = line.index(after: index)
                continue
            }
            if inChar {
                if character == "'" { inChar = false }
                index = line.index(after: index)
                continue
            }

            switch character {
            case "\"" where kotlin && next == "\"" && thirdIsQuote(line, after: index):
                inRawString = true
                index = line.index(index, offsetBy: 2)
            case "\"":
                inString = true
                index = line.index(after: index)
            case "'" where kotlin:
                inChar = true
                index = line.index(after: index)
            case "/" where next == "/":
                index = line.endIndex // rest of line is a comment
            case "/" where next == "*":
                depth = 1
                index = line.index(after: index)
            default:
                output.append(character)
                index = line.index(after: index)
            }
        }

        blockCommentDepth = depth
        return output
    }

    private func thirdIsQuote(_ line: String, after index: String.Index) -> Bool {
        let second = line.index(after: index)
        guard line.index(after: second) < line.endIndex else { return false }
        return line[line.index(after: second)] == "\""
    }

    private func optionalIndex(_ index: String.Index, in line: String) -> String.Index? {
        index < line.endIndex ? index : nil
    }
}
