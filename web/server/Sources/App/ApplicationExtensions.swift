import Vapor

extension Application {
    private struct InviteCodeKey: StorageKey {
        typealias Value = String
    }

    private struct AdminTokenKey: StorageKey {
        typealias Value = String
    }

    /// Shared invite code participants must supply to enroll — `nil` means the link is open.
    public var inviteCode: String? {
        get { self.storage[InviteCodeKey.self] }
        set { self.storage[InviteCodeKey.self] = newValue }
    }

    /// Bearer token admin export routes require — `nil` means they're unauthenticated (dev only).
    public var adminToken: String? {
        get { self.storage[AdminTokenKey.self] }
        set { self.storage[AdminTokenKey.self] = newValue }
    }
}
