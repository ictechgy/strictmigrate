import Foundation

@MainActor
public final class ThumbnailRenderer {
    public var theme: String = "light"

    public init() {}

    public func render(name: String) -> String {
        "\(theme):\(name).png"
    }
}

public enum RenderService {
    /// Calls a MainActor-isolated method from a nonisolated context.
    public static func renderSync(_ renderer: ThumbnailRenderer) -> String {
        renderer.render(name: "avatar")
    }

    public static func spawnWork() {
        let renderer = ThumbnailRenderer()
        Task {
            // MainActor-isolated state touched from a nonisolated task.
            renderer.theme = "dark"
        }
    }
}
