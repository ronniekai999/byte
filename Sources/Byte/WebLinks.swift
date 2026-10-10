import Foundation

enum WebLinks {
    static func canOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return false }
        return ["https", "http"].contains(scheme)
    }
}
