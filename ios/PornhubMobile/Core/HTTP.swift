import Foundation

/// 统一的错误类型：`localizedDescription` 直接就是给用户看的中文提示。
struct AppError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct HTTPResponse {
    var status: Int
    var url: URL
    var body: Data
    var headers: [String: String]

    var text: String { String(decoding: body, as: UTF8.self) }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// 站点请求层。
///
/// 桌面端通过系统 `curl.exe`（Schannel）发请求，因为站点对 TLS 指纹敏感；
/// iOS 上使用系统 `URLSession`，握手由 iOS 自己的网络栈完成，行为与 Safari 接近。
/// Cookie 交给 `HTTPCookieStorage` 统一管理（登录、网页登录导入、退出都能复用）。
final class HTTPClient {

    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

    private(set) var settings: AppSettings
    private var session: URLSession
    private var proxySignature: String

    init(settings: AppSettings) {
        self.settings = settings
        self.proxySignature = HTTPClient.signature(for: settings.proxy)
        self.session = HTTPClient.makeSession(proxy: settings.proxy)
    }

    var referer: String {
        settings.domain + "/"
    }

    func update(settings: AppSettings) {
        let next = HTTPClient.signature(for: settings.proxy)
        if next != proxySignature {
            session.invalidateAndCancel()
            session = HTTPClient.makeSession(proxy: settings.proxy)
            proxySignature = next
        }
        self.settings = settings
    }

    private static func signature(for proxy: ProxyConfig) -> String {
        proxy.enabled ? "\(proxy.host):\(proxy.port)" : "direct"
    }

    private static func makeSession(proxy: ProxyConfig) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 120
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024,
                                   diskPath: "ph-mobile-cache")

        if proxy.enabled {
            // iOS 没有“只对单个 App 生效”的系统代理，这里走 CFNetwork 的代理支持。
            // 实际使用中更推荐系统级 VPN / Clash 等工具。
            config.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": proxy.host,
                "HTTPPort": proxy.port,
                "HTTPSEnable": 1,
                "HTTPSProxy": proxy.host,
                "HTTPSPort": proxy.port
            ]
        }
        return URLSession(configuration: config)
    }

    func request(_ method: String,
                 _ urlString: String,
                 headers: [String: String] = [:],
                 body: Data? = nil,
                 cachePolicy: URLRequest.CachePolicy? = nil,
                 referer refererOverride: String? = nil,
                 userAgent: String? = nil) async throws -> HTTPResponse {
        guard let url = URL(string: urlString) else {
            throw AppError("地址无效：\(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        if let cachePolicy = cachePolicy {
            request.cachePolicy = cachePolicy
        }
        request.setValue(userAgent ?? HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        let effectiveReferer = refererOverride ?? referer
        if !effectiveReferer.isEmpty {
            request.setValue(effectiveReferer, forHTTPHeaderField: "Referer")
        }
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = body {
            request.httpBody = body
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError("站点返回了无法识别的响应")
            }
            var map: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let name = key as? String {
                    map[name.lowercased()] = String(describing: value)
                }
            }
            return HTTPResponse(status: http.statusCode,
                                url: http.url ?? url,
                                body: data,
                                headers: map)
        } catch let error as AppError {
            throw error
        } catch let error as URLError {
            throw AppError(HTTPClient.friendly(error))
        } catch {
            throw AppError("网络请求失败：\(error.localizedDescription)")
        }
    }

    /// 清空磁盘上的 HTTP 缓存（页面 / 图片）。
    func clearURLCache() {
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    private static func friendly(_ error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "请求超时：请检查网络或代理设置"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "连接失败：无法连接到站点，请确认网络可用（或代理端口正确）"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            return "HTTPS 连接失败：可能是代理证书或网络环境问题"
        case .notConnectedToInternet, .networkConnectionLost:
            return "网络已断开，请检查连接后重试"
        case .appTransportSecurityRequiresSecureConnection:
            return "系统拒绝了该请求（ATS）"
        default:
            return "网络请求失败：\(error.localizedDescription)"
        }
    }
}
