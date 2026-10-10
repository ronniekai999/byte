import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// All account records share one Keychain item, so its read/modify/write and
/// rotating-token exchanges must be serialized across Byte processes.
final class ChatGPTCredentialLock {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/byte/chatgpt-credentials.lock")
    }

    private let url: URL
    init(url: URL = ChatGPTCredentialLock.defaultURL) { self.url = url }

    final class Lease {
        private var descriptor: Int32
        fileprivate init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { release() }

        func release() {
            guard descriptor >= 0 else { return }
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            descriptor = -1
        }
    }

    @MainActor
    func acquire(timeout: TimeInterval = 30) async throws -> Lease {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw ChatGPTConnectionError("Couldn't coordinate your ChatGPT connection. Check access to Byte's data folder.")
        }
        let lease = Lease(descriptor)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return lease }
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw ChatGPTConnectionError("Couldn't lock your ChatGPT connection. Try again.")
            }
            guard Date() < deadline else {
                throw ChatGPTConnectionError("Another Byte instance is updating ChatGPT credentials. Finish or retry its Keychain save, then try again.")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
