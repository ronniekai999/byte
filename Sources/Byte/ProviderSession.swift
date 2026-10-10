import Foundation

/// A redirect must never forward a token exchange or a conversation to another
/// host. Tests can still inject their own URLSession/URLProtocol.
enum ProviderSession {
    static let shared = URLSession(configuration: .ephemeral, delegate: RedirectPolicy(), delegateQueue: nil)

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            let target = request.url
            let origin = task.originalRequest?.url
            let allowed = target?.scheme == "https" && target?.host == origin?.host &&
                (target?.port == nil || target?.port == 443) && target?.user == nil && target?.password == nil
            completionHandler(allowed ? request : nil)
        }
    }
}
