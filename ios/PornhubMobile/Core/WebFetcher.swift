import Foundation
import WebKit

/// 兜底取页方案。
///
/// 桌面端发现站点对 TLS 指纹敏感，所以改用系统 `curl.exe` 发出请求。
/// iOS 上正常情况下 `URLSession` 就够用；但如果站点仍然返回 403 / 410，
/// 这里用 `WKWebView`（Safari 内核）真正加载一次页面，再把 DOM 序列化回来。
///
/// 只有 `URLSession` 失败时才会走到这里，平时不会多花任何开销。
@MainActor
final class WebFetcher: NSObject, WKNavigationDelegate {

    static let shared = WebFetcher()

    private final class Job {
        let webView: WKWebView
        var continuation: CheckedContinuation<String, Error>?

        init(webView: WKWebView) {
            self.webView = webView
        }
    }

    private var jobs: [ObjectIdentifier: Job] = [:]
    private var timeouts: [ObjectIdentifier: Task<Void, Never>] = [:]

    func fetch(_ urlString: String, timeout: TimeInterval = 25) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw AppError("地址无效：\(urlString)")
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 414, height: 896),
                                configuration: configuration)
        webView.navigationDelegate = self

        let job = Job(webView: webView)
        let id = ObjectIdentifier(webView)
        jobs[id] = job

        return try await withCheckedThrowingContinuation { continuation in
            job.continuation = continuation
            webView.load(URLRequest(url: url))

            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self = self, !Task.isCancelled else { return }
                self.finish(id: id, html: nil, error: AppError("网页加载超时"))
            }
        }
    }

    private func finish(id: ObjectIdentifier, html: String?, error: Error?) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)?.cancel()

        job.webView.stopLoading()
        job.webView.navigationDelegate = nil

        if let html = html, !html.isEmpty {
            job.continuation?.resume(returning: html)
        } else {
            job.continuation?.resume(throwing: error ?? AppError("网页加载失败"))
        }
        job.continuation = nil
    }

    /* ------------------------------ WKNavigationDelegate ------------------------------ */

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let id = ObjectIdentifier(webView)
        webView.evaluateJavaScript("document.documentElement.outerHTML") { value, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let html = value as? String, !html.isEmpty {
                    // 顺便把 WebKit 里的 Cookie 同步给 URLSession。
                    CookieStore.importWebKitCookies()
                    self.finish(id: id, html: html, error: nil)
                } else {
                    self.finish(id: id, html: nil, error: error ?? AppError("读取页面失败"))
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(id: ObjectIdentifier(webView), html: nil, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(id: ObjectIdentifier(webView), html: nil, error: error)
    }
}
