import Foundation

/// 页面级内存缓存，对应桌面端 `main.rs` 里 180 秒 TTL 的 `cached_json`。
@MainActor
final class PageCache {
    private struct Entry {
        let at: Date
        let value: Any
    }

    private var map: [String: Entry] = [:]
    private let ttl: TimeInterval = 180

    func get<T>(_ key: String, as type: T.Type) -> T? {
        guard let entry = map[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) < ttl else {
            map.removeValue(forKey: key)
            return nil
        }
        return entry.value as? T
    }

    func put(_ key: String, _ value: Any) {
        if map.count > 120 { map.removeAll() }
        map[key] = Entry(at: Date(), value: value)
    }

    func remove(_ key: String) {
        map.removeValue(forKey: key)
    }

    func clear() {
        map.removeAll()
    }
}

/// 站点数据接口，对应桌面端的 Tauri command 集合。
@MainActor
final class APIClient {

    let http: HTTPClient
    private let cache = PageCache()

    init(settings: AppSettings) {
        self.http = HTTPClient(settings: settings)
    }

    var settings: AppSettings { http.settings }
    var domain: String { http.settings.domain }

    func update(settings: AppSettings) {
        http.update(settings: settings)
        cache.clear()
    }

    func clearCache() {
        cache.clear()
        http.clearURLCache()
    }

    /* ------------------------------ 页面数据 ------------------------------ */

    func home(force: Bool = false) async throws -> [VideoItem] {
        if !force, let cached = cache.get("home", as: [VideoItem].self) { return cached }
        let html = try await fetchText(domain + "/")
        let items = Parser.parseHome(html, domain: domain)
        cache.put("home", items)
        return items
    }

    func categories(force: Bool = false) async throws -> [CategoryItem] {
        if !force, let cached = cache.get("categories", as: [CategoryItem].self) { return cached }
        let html = try await fetchText(domain + "/categories")
        let items = Parser.parseCategories(html, domain: domain)
        cache.put("categories", items)
        return items
    }

    func listing(path: String, page: Int = 1, force: Bool = false) async throws -> ListingPage {
        let key = "list:\(path):\(page)"
        if !force, let cached = cache.get(key, as: ListingPage.self) { return cached }
        guard let url = urlFor(path: path, page: page) else {
            throw AppError("非法的页面路径")
        }
        let html = try await fetchText(url)
        let parsed = Parser.parseListing(html, domain: domain)
        cache.put(key, parsed)
        return parsed
    }

    func video(vkey: String, force: Bool = false) async throws -> VideoDetail {
        guard Parser.validVkey(vkey) else { throw AppError("视频编号无效") }
        let key = "video:\(vkey)"
        if !force, let cached = cache.get(key, as: VideoDetail.self) { return cached }
        let html = try await fetchText("\(domain)/view_video.php?viewkey=\(vkey)")
        let detail = Parser.parseVideo(html, domain: domain, vkey: vkey)
        cache.put(key, detail)
        return detail
    }

    func forgetVideo(vkey: String) {
        cache.remove("video:\(vkey)")
    }

    /* ------------------------------ 账号 ------------------------------ */

    func account(allowFallback: Bool = true) async -> Account {
        do {
            let html = try await fetchText(domain + "/")
            guard Parser.isLoggedIn(html) else {
                return Account(loggedIn: false, username: "")
            }
            var name = Parser.parseUsername(html)
            if name.isEmpty && allowFallback { name = settings.accountName }
            return Account(loggedIn: true, username: name)
        } catch {
            if allowFallback && !settings.accountName.isEmpty {
                return Account(loggedIn: true, username: settings.accountName)
            }
            return Account(loggedIn: false, username: "")
        }
    }

    func login(email: String, password: String) async throws -> LoginResult {
        let html = try await fetchText(domain + "/login")
        let form = try Parser.parseLoginForm(html)
        let body = APIClient.formEncode([
            ("redirect", form.redirect),
            ("user_id", ""),
            ("intended_action", ""),
            ("token", form.token),
            ("from", form.from),
            ("email", email),
            ("password", password)
        ])
        let payload = try await postAuth(body: body)
        let result = try APIClient.interpret(payload, csrf: form.token)
        cache.clear()
        return result
    }

    func login2FA(challenge: TwoFactorChallenge, code: String) async throws -> LoginResult {
        let email = challenge.email.isEmpty ? challenge.username : challenge.email
        let body = APIClient.formEncode([
            ("verification_modal", "1"),
            ("email", email),
            ("username", challenge.username),
            ("token2", challenge.autoLoginParameter),
            ("authyId", challenge.authyId),
            ("authyIdHashed", challenge.authyIdHashed),
            ("token", challenge.csrf),
            ("verification_code", code)
        ])
        let payload = try await postAuth(body: body)
        let result = try APIClient.interpret(payload, csrf: challenge.csrf)
        cache.clear()
        return result
    }

    func logout() {
        CookieStore.clear(domain: domain)
        cache.clear()
    }

    @discardableResult
    func importCookies(_ header: String) async throws -> Account {
        let count = CookieStore.importHeader(header, domain: domain)
        if count == 0 {
            throw AppError("未能识别 Cookie，请确认复制的是完整的 Cookie 请求头")
        }
        cache.clear()
        let account = await self.account(allowFallback: false)
        if !account.loggedIn {
            throw AppError("Cookie 无效或已过期，请重新从浏览器复制")
        }
        return account
    }

    func test() async -> TestResult {
        let started = Date()
        do {
            let html = try await fetchText(domain + "/")
            let loggedIn = Parser.isLoggedIn(html)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return TestResult(ok: true,
                              ms: ms,
                              message: loggedIn ? "连接正常，账号已登录" : "连接正常",
                              loggedIn: loggedIn)
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let message = (error as? AppError)?.message ?? error.localizedDescription
            return TestResult(ok: false, ms: ms, message: message, loggedIn: false)
        }
    }

    /* ------------------------------ 内部实现 ------------------------------ */

    private func urlFor(path: String, page: Int) -> String? {
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        var url = domain + path
        if page > 1 {
            url += (path.contains("?") ? "&" : "?") + "page=\(page)"
        }
        return url
    }

    private func fetchText(_ url: String) async throws -> String {
        do {
            return try await fetchTextDirect(url)
        } catch {
            // 站点偶尔会因为 TLS / HTTP 指纹拒绝 URLSession，这时用 WKWebView
            // （Safari 内核）重新取一次页面。
            if let html = try? await WebFetcher.shared.fetch(url), !html.isEmpty {
                return html
            }
            throw error
        }
    }

    private func fetchTextDirect(_ url: String) async throws -> String {
        var lastError = AppError("网络请求失败，请稍后重试")
        var retryable = true

        for attempt in 0..<2 {
            do {
                let response = try await http.request("GET", url, headers: [
                    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
                ])
                if (200..<300).contains(response.status) {
                    return response.text
                }
                lastError = AppError(APIClient.statusError(response.status))
                retryable = response.status >= 500
            } catch let error as AppError {
                lastError = error
                retryable = true
            } catch {
                lastError = AppError(error.localizedDescription)
                retryable = true
            }

            if !retryable { throw lastError }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw lastError
    }

    private func postAuth(body: Data) async throws -> [String: Any] {
        let response = try await http.request("POST", domain + "/front/authenticate", headers: [
            "Referer": domain + "/login",
            "Origin": domain,
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "X-Requested-With": "XMLHttpRequest",
            "Cache-Control": "no-cache",
            "Content-Type": "application/x-www-form-urlencoded"
        ], body: body)

        if response.status == 429 {
            throw AppError("请求过于频繁，请稍后再试")
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) else {
            throw AppError("登录接口返回异常（HTTP \(response.status)），可能触发了站点风控")
        }
        guard let object = json as? [String: Any] else {
            throw AppError("登录接口返回异常（HTTP \(response.status)），可能触发了站点风控")
        }
        return object
    }

    private static func statusError(_ status: Int) -> String {
        switch status {
        case 403:
            return "站点返回 403（访问被拒绝）。请检查网络节点是否可用，或稍后重试"
        case 404:
            return "页面不存在（404），链接可能已失效"
        case 429:
            return "请求过于频繁，请稍后再试"
        case 451:
            return "该内容在当前地区不可用"
        case 500...599:
            return "站点服务器错误（HTTP \(status)），请稍后重试"
        default:
            return "站点返回 HTTP \(status)"
        }
    }

    private static func formEncode(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = pairs.map { pair -> String in
            let key = pair.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? pair.0
            let value = pair.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? pair.1
            return key + "=" + value
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func stringValue(_ object: [String: Any], _ key: String) -> String {
        guard let value = object[key] as? String else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? Double { return value != 0 }
        if let value = value as? NSNumber { return value.intValue != 0 }
        if let value = value as? String { return value != "0" && !value.isEmpty }
        return false
    }

    private static func successValue(_ value: Any?) -> Bool {
        if let value = value as? String { return value != "0" && !value.isEmpty }
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.intValue != 0 }
        return false
    }

    private static func usernameFromRedirect(_ redirect: String) -> String {
        guard let range = redirect.range(of: "/users/") else { return "" }
        let rest = redirect[range.upperBound...]
        let name = rest.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        return name
    }

    private static let captchaMessage = "站点要求人机验证，无法直接登录。可改用“网页登录”或“浏览器 Cookie”方式。"

    private static func interpret(_ value: [String: Any], csrf: String) throws -> LoginResult {
        if boolValue(value["requireCaptcha"]) {
            throw AppError(captchaMessage)
        }

        if !successValue(value["success"]) {
            var message = stringValue(value, "message")
            if message.isEmpty { message = "登录失败，请检查账号和密码" }
            let cleaned = Parser.plainText(message)
            if cleaned.lowercased().contains("captcha") {
                throw AppError(captchaMessage)
            }
            throw AppError(cleaned.isEmpty ? message : cleaned)
        }

        let twoStep = boolValue(value["twoStepVerification"])
            || !stringValue(value, "twoStepVerificationType").isEmpty

        if twoStep {
            var challenge = TwoFactorChallenge()
            var type = stringValue(value, "twoStepVerificationType")
            if type.isEmpty { type = "existingLegacy" }
            challenge.twoStepType = type
            challenge.email = stringValue(value, "email")
            challenge.username = stringValue(value, "username")
            challenge.phoneNumber = stringValue(value, "phoneNumber")
            challenge.authyId = stringValue(value, "authyId")
            challenge.authyIdHashed = stringValue(value, "authyIdHashed")
            challenge.autoLoginParameter = stringValue(value, "autoLoginParameter")
            challenge.csrf = csrf
            return .twoFactor(challenge)
        }

        var username = stringValue(value, "username")
        if username.isEmpty { username = stringValue(value, "user_name") }
        if username.isEmpty { username = stringValue(value, "nickname") }
        if username.isEmpty { username = usernameFromRedirect(stringValue(value, "redirect")) }

        return .ok(Account(loggedIn: true, username: username))
    }
}
