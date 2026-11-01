import Foundation
import WebKit

/// Cookie 管理。
///
/// 桌面端自己实现了一个 CookieJar；iOS 上直接用系统 `HTTPCookieStorage`：
/// URLSession 会自动收下 `Set-Cookie`，网页登录（WKWebView）也能把 Cookie 导进来。
enum CookieStore {

    /// 从站点地址里取出主机名（去掉协议、路径和端口）。
    static func host(from domain: String) -> String {
        var value = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "://") {
            value = String(value[range.upperBound...])
        }
        value = value.split(separator: "/").first.map(String.init) ?? value
        if let colon = value.firstIndex(of: ":") {
            value = String(value[value.startIndex..<colon])
        }
        return value.lowercased()
    }

    /// 导入用户从浏览器复制出来的 `Cookie:` 请求头。
    @discardableResult
    static func importHeader(_ header: String, domain: String) -> Int {
        let host = host(from: domain)
        guard !host.isEmpty else { return 0 }

        var count = 0
        for part in header.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }

            var value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }

            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: host,
                .path: "/"
            ]
            if let cookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(cookie)
                count += 1
            }
        }
        return count
    }

    /// 把 WKWebView 里的 Cookie 复制到 `HTTPCookieStorage`，供 URLSession 使用。
    static func importWebKitCookies(completion: ((Int) -> Void)? = nil) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var count = 0
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
                count += 1
            }
            DispatchQueue.main.async {
                completion?(count)
            }
        }
    }

    static func clear(domain: String) {
        let host = host(from: domain)
        guard !host.isEmpty else { return }
        guard let cookies = HTTPCookieStorage.shared.cookies else { return }
        for cookie in cookies {
            let cookieDomain = cookie.domain
            if cookieDomain.contains(host) || host.contains(cookieDomain) {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
    }
}
