import Foundation

/// Identity of one atomic unit of work: a symbol within a file.
struct SymbolKey: Hashable, Sendable {
    var file: String
    var symbol: String
}

/// Resolves diagnostics to their enclosing declarations, caching each file's
/// symbol table for the resolver's lifetime.
///
/// One resolver per resolution pass (slice, verdict, reconcile, prompt): the
/// cache deliberately does not outlive the measurement it describes, so a
/// file the agent edited between passes is re-read.
struct SymbolResolver {
    let packageRoot: String
    private var cache: [String: [SymbolRange]] = [:]

    init(packageRoot: String) {
        self.packageRoot = packageRoot
    }

    /// Symbol table of one repository-relative file (empty when unreadable).
    mutating func symbols(inFile file: String) -> [SymbolRange] {
        if let cached = cache[file] { return cached }
        let absolute = (packageRoot as NSString).appendingPathComponent(file)
        let symbols = (try? String(contentsOfFile: absolute, encoding: .utf8))
            .map { SymbolLocator.symbols(in: $0, language: SourceLanguage(path: file)) } ?? []
        cache[file] = symbols
        return symbols
    }

    /// Enclosing declaration of a diagnostic, or `(file scope)`.
    mutating func symbolName(for diagnostic: ConcurrencyDiagnostic) -> String {
        SymbolLocator.symbolName(for: diagnostic, symbols: symbols(inFile: diagnostic.file))
    }

    /// (file, symbol) identities of tracked diagnostics.
    mutating func symbolKeys(for diagnostics: [ConcurrencyDiagnostic]) -> Set<SymbolKey> {
        var keys = Set<SymbolKey>()
        for diagnostic in diagnostics where diagnostic.category.isTracked {
            keys.insert(SymbolKey(file: diagnostic.file, symbol: symbolName(for: diagnostic)))
        }
        return keys
    }
}
