package com.example.shared

/**
 * Shared Kotlin declaration mirrored by SharedKit on the Swift side.
 * Swift 6 strict concurrency flags this type at every boundary crossing;
 * the real fix usually belongs *here* (immutability, @ThreadSafe, or removing
 * shared mutable state), not at the Swift call sites.
 */
class UserSession(private val userID: String) {
    var lastSeen: Long = 0

    fun touch() {
        lastSeen = System.currentTimeMillis()
    }
}
