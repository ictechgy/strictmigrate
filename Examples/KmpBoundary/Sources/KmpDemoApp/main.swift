import SharedKit

let session = UserSession(userID: "u-1")
let cache = SessionCache()

Task.detached {
    // KMP boundary: UserSession is a Kotlin-exported, non-Sendable type.
    session.touch()
    cache.add("boot")
}
