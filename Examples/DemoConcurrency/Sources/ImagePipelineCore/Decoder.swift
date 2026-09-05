import Foundation

/// Non-Sendable reference type (mutable state, no isolation).
public final class DecodeContext {
    public var cache: [String: Data] = [:]

    public init() {}

    public func cachedData(for key: String) -> Data? {
        cache[key]
    }
}

public enum ImageDecoder {
    /// Global mutable state holding a non-Sendable type.
    public static var shared = DecodeContext()
}
