import Foundation

public actor CacheActor {
    public var entries: [String: Int] = [:]

    public func count(for key: String) -> Int {
        entries[key] ?? 0
    }
}

public struct PipelineConfig: Sendable {
    public var concurrencyLimit: Int = 4

    public init() {}
}

public final class ImagePipeline {
    public let config: PipelineConfig
    private let cache = CacheActor()

    public init(config: PipelineConfig) {
        self.config = config
    }

    public func runAll(keys: [String]) async -> Int {
        var total = 0
        await withTaskGroup(of: Int.self) { group in
            for key in keys {
                // Captures non-Sendable `self` in a @Sendable closure.
                group.addTask {
                    await self.cache.count(for: key)
                }
            }
            for await value in group {
                total += value
            }
        }
        return total
    }

    public func warmup() async {
        // Touches global mutable state from a concurrent task.
        let context = ImageDecoder.shared
        _ = context.cachedData(for: "hero")
    }
}
