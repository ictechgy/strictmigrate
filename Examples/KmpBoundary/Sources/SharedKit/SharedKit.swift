import Foundation

/// Swift shim standing in for the Kotlin/Native framework export of
/// `shared/src/commonMain`. In a real KMP build these declarations are
/// generated from the Kotlin module; keeping the mirror here lets the demo
/// build with SwiftPM alone.
public final class UserSession {
    public var lastSeen: Date = .distantPast

    public init(userID: String) {}

    public func touch() {
        lastSeen = Date()
    }
}

@MainActor
public final class SessionCache {
    public var items: [String] = []

    public init() {}

    public func add(_ item: String) {
        items.append(item)
    }
}
