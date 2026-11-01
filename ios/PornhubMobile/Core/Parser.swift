import Foundation
import SwiftSoup

/// HTML 解析。逻辑与桌面端 `src-tauri/src/parse.rs` 一一对应，
/// 选择器也保持一致（用 SwiftSoup 复刻 Rust 里的 scraper）。
enum Parser {

    struct LoginForm {
        var token: String = ""
        var redirect: String = ""
        var from: String = ""
    }

    /* ------------------------------ 基础工具 ------------------------------ */

    static func absolute(_ domain: String, _ href: String) -> String {
        let raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return raw }
        if raw.hasPrefix("//") { return "https:" + raw }
        var base = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if raw.hasPrefix("/") { return base + raw }
        return base + "/" + raw
    }

    static func cleanThumb(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.hasPrefix("data:") { return "" }
        if value.hasPrefix("//") { return "https:" + value }
        return value
    }

    static func validVkey(_ vkey: String) -> Bool {
        guard vkey.count >= 6 && vkey.count <= 32 else { return false }
        return vkey.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// 把站内绝对地址转成 `get_list` 需要的相对路径（`/video?c=...`）。
    static func relativePath(_ href: String, domain: String) -> String {
        let raw = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("/") { return raw }
        guard let url = URL(string: raw), let scheme = url.scheme, scheme.hasPrefix("http") else {
            return raw
        }
        var path = url.path
        if path.isEmpty { path = "/" }
        if let query = url.query, !query.isEmpty {
            path += "?" + query
        }
        return path
    }

    private static func text(_ element: Element) -> String {
        let value = (try? element.text()) ?? ""
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func attr(_ element: Element, _ name: String) -> String {
        let value = (try? element.attr(name)) ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func select(_ element: Element, _ selector: String) -> [Element] {
        guard let elements = try? element.select(selector) else { return [] }
        var out: [Element] = []
        for item in elements { out.append(item) }
        return out
    }

    private static func first(_ element: Element, _ selector: String) -> Element? {
        guard let elements = try? element.select(selector) else { return nil }
        return elements.first()
    }

    /// 找出所有带 `data-video-vkey` 的 `li`。
    private static func videoNodes(in root: Element) -> [Element] {
        select(root, "li").filter { !attr($0, "data-video-vkey").isEmpty }
    }

    /// 找出第一个 href 含 `fragment` 的 `a`。比属性选择器更稳。
    private static func anchor(in root: Element, containing fragment: String) -> Element? {
        for link in select(root, "a") {
            if attr(link, "href").contains(fragment) { return link }
        }
        return nil
    }

    /* ------------------------------ 列表 ------------------------------ */

    static func items(in root: Element, domain: String) -> [VideoItem] {
        var out: [VideoItem] = []
        var seen = Set<String>()

        for element in videoNodes(in: root) {
            let vkey = attr(element, "data-video-vkey")
            if vkey.isEmpty || seen.contains(vkey) { continue }
            guard let link = anchor(in: element, containing: "viewkey=") else { continue }
            let href = attr(link, "href")
            if href.isEmpty { continue }
            seen.insert(vkey)

            var title = attr(link, "title")
            if title.isEmpty { title = text(link) }

            var thumb = ""
            if let image = first(element, "img") {
                for key in ["data-mediumthumb", "data-image", "src"] {
                    let candidate = cleanThumb(attr(image, key))
                    if !candidate.isEmpty {
                        thumb = candidate
                        break
                    }
                }
            }

            let duration = first(element, ".duration").map { text($0) } ?? ""
            let views = first(element, ".views").map { text($0) } ?? ""
            let author = first(element, ".videoUploaderBlock a").map { text($0) } ?? ""

            out.append(VideoItem(vkey: vkey,
                                 title: title,
                                 thumb: thumb,
                                 duration: duration,
                                 views: views,
                                 author: author,
                                 href: absolute(domain, href)))
        }
        return out
    }

    static func parseHome(_ html: String, domain: String) -> [VideoItem] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        if let feed = first(doc, "#singleFeedSection") {
            return items(in: feed, domain: domain)
        }
        if let wrapper = first(doc, ".frontListingWrapper") {
            return items(in: wrapper, domain: domain)
        }
        return items(in: doc, domain: domain)
    }

    static func parseListing(_ html: String, domain: String) -> ListingPage {
        var page = ListingPage()
        guard let doc = try? SwiftSoup.parse(html) else { return page }

        var container: Element? = first(doc, "#singleFeedSection")
        if container == nil {
            var best: Element? = nil
            var bestCount = 0
            for list in select(doc, "ul.nf-videos") {
                let count = videoNodes(in: list).count
                if count > bestCount {
                    bestCount = count
                    best = list
                }
            }
            container = best
        }

        if let container = container {
            page.items = items(in: container, domain: domain)
        }

        page.title = first(doc, "h1").map { text($0) } ?? ""
        page.current = first(doc, ".page_current").flatMap { Int(text($0)) } ?? 1

        var pages = select(doc, ".page_number a").compactMap { Int(text($0)) }
        pages.sort()
        var unique: [Int] = []
        for value in pages where !unique.contains(value) { unique.append(value) }
        page.pages = unique

        if let next = first(doc, ".page_next a") {
            let href = attr(next, "href")
            if !href.isEmpty { page.nextHref = href }
        }

        if let previous = first(doc, ".page_previous a") {
            let disabled = first(doc, ".page_previous.disabled") != nil
            if !disabled {
                let href = attr(previous, "href")
                if !href.isEmpty { page.prevHref = href }
            }
        }

        return page
    }

    static func parseCategories(_ html: String, domain: String) -> [CategoryItem] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        var out: [CategoryItem] = []

        for element in select(doc, "li.catPic") {
            let id = attr(element, "data-category")
            guard let link = anchor(in: element, containing: "c=") else { continue }
            let href = attr(link, "href")
            if id.isEmpty || href.isEmpty { continue }

            var name = first(element, "strong").map { text($0) } ?? ""
            if name.isEmpty, let image = first(element, "img") {
                let alt = attr(image, "alt")
                    .replacingOccurrences(of: "色情类别", with: "")
                    .replacingOccurrences(of: "Porn Category", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                name = alt
            }

            let count = first(element, ".videoCount").map { text($0) } ?? ""

            var thumb = ""
            if let image = first(element, "img") {
                let path = attr(image, "data-path")
                thumb = cleanThumb(path.isEmpty ? attr(image, "src") : path)
            }

            out.append(CategoryItem(categoryID: id,
                                    name: name,
                                    count: count,
                                    thumb: thumb,
                                    href: absolute(domain, href)))
        }
        return out
    }

    /* ------------------------------ 视频详情 ------------------------------ */

    static func parseVideo(_ html: String, domain: String, vkey: String) -> VideoDetail {
        var detail = VideoDetail()
        detail.vkey = vkey
        detail.url = "\(domain.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/view_video.php?viewkey=\(vkey)"

        guard let doc = try? SwiftSoup.parse(html) else { return detail }
        let flash = flashvars(html)

        let h1 = first(doc, "h1.title") ?? first(doc, "h1")
        let heading = h1.map { text($0) } ?? ""

        var title = ""
        if let flash = flash {
            let translated = jsonString(flash, "videoTitleTranslated")
            title = translated.isEmpty ? jsonString(flash, "video_title") : translated
        }
        if title.isEmpty { title = heading }
        detail.title = title

        detail.duration = flash.map { intValue($0["video_duration"]) } ?? 0

        if let views = first(doc, ".views span.count") ?? first(doc, ".views") {
            detail.views = text(views)
        }
        if let info = first(doc, ".videoInfo") {
            detail.publish = text(info)
        }
        if let author = first(doc, ".userInfo .usernameWrap a") {
            detail.author = text(author)
            detail.authorHref = absolute(domain, attr(author, "href"))
        }
        if let avatar = first(doc, ".userAvatar img") {
            detail.avatar = cleanThumb(attr(avatar, "src"))
        }
        if let flash = flash {
            detail.image = cleanThumb(jsonString(flash, "image_url"))
        }

        for element in select(doc, ".categoriesWrapper a") {
            let name = text(element)
            if !name.isEmpty {
                detail.categories.append(LinkItem(name: name, href: absolute(domain, attr(element, "href"))))
            }
        }
        for element in select(doc, ".tagsWrapper a") {
            let name = text(element)
            if !name.isEmpty {
                detail.tags.append(LinkItem(name: name, href: absolute(domain, attr(element, "href"))))
            }
        }

        detail.sources = sources(from: mediaDefinitions(html: html, flash: flash))

        var related = first(doc, "#relatedVideosListing").map { items(in: $0, domain: domain) } ?? []
        related.removeAll { $0.vkey == vkey }
        detail.related = Array(related.prefix(30))

        let unavailableFlag = flash.map { boolValue($0["video_unavailable"]) } ?? false
        detail.unavailable = unavailableFlag || detail.sources.isEmpty
        return detail
    }

    private static func sources(from definitions: [[String: Any]]) -> [VideoSource] {
        var out: [VideoSource] = []
        for definition in definitions {
            let format = jsonString(definition, "format")
            guard let url = definition["videoUrl"] as? String, !url.isEmpty else { continue }
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
            if url.contains("/video/get_media") { continue }

            let normalizedFormat = format.lowercased()
            if !normalizedFormat.isEmpty && normalizedFormat != "hls" && normalizedFormat != "mp4" {
                continue
            }

            let height = intValue(definition["height"])
            var quality = ""
            if let value = definition["quality"] as? String {
                quality = value
            } else if let value = definition["quality"] as? Int {
                quality = String(value)
            } else if let value = definition["quality"] as? Double {
                quality = String(Int(value))
            }

            if out.contains(where: { $0.url == url && $0.height == height }) { continue }

            out.append(VideoSource(quality: quality,
                                   height: height,
                                   format: format,
                                   url: url,
                                   isDefault: boolValue(definition["defaultQuality"])))
        }
        out.sort { $0.height > $1.height }
        return out
    }

    /* -------------------------- flashvars / JSON -------------------------- */

    private static func flashvars(_ html: String) -> [String: Any]? {
        guard let marker = html.range(of: "var flashvars_") else { return nil }
        let tail = html[marker.lowerBound...]
        guard let brace = tail.firstIndex(of: "{") else { return nil }
        guard let json = balanced(String(html[brace...]), open: "{", close: "}") else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    private static func mediaDefinitions(html: String, flash: [String: Any]?) -> [[String: Any]] {
        if let definitions = flash?["mediaDefinitions"] as? [[String: Any]], !definitions.isEmpty {
            return definitions
        }

        guard let marker = html.range(of: "\"mediaDefinitions\"") else { return [] }
        let tail = html[marker.upperBound...]
        guard let bracket = tail.firstIndex(of: "[") else { return [] }
        guard let json = balanced(String(html[bracket...]), open: "[", close: "]") else { return [] }
        guard let data = json.data(using: .utf8) else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return object as? [[String: Any]] ?? []
    }

    /// 从 `open` 字符开始做括号配对，跳过字符串里的括号。
    private static func balanced(_ text: String, open: Character, close: Character) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var out = ""

        for character in text {
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                out.append(character)
                continue
            }

            if character == "\"" {
                inString = true
                if depth > 0 { out.append(character) }
                continue
            }
            if character == open {
                depth += 1
                out.append(character)
                continue
            }
            if character == close {
                depth -= 1
                if depth == 0 {
                    out.append(character)
                    return out
                }
                if depth < 0 { return nil }
                out.append(character)
                continue
            }
            if depth > 0 { out.append(character) }
        }
        return nil
    }

    private static func jsonString(_ object: [String: Any], _ key: String) -> String {
        guard let value = object[key] as? String else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? NSNumber { return value.intValue != 0 }
        if let value = value as? String { return value == "1" || value.lowercased() == "true" }
        return false
    }

    /* ------------------------------ 账号 ------------------------------ */

    static func isLoggedIn(_ html: String) -> Bool {
        let compact = html.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if compact.contains("isLoggedInUser = 1") || compact.contains("isLoggedInUser=1") { return true }
        if compact.contains("isLoggedInUser = 0") || compact.contains("isLoggedInUser=0") { return false }

        guard let doc = try? SwiftSoup.parse(html) else { return false }
        if first(doc, "body.logged-in") != nil { return true }
        if first(doc, "body.logged-out") != nil { return false }
        return false
    }

    static func parseUsername(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return "" }
        for selector in ["#headerUserName", ".userName", ".headerUserName"] {
            if let element = first(doc, selector) {
                let nickname = attr(element, "data-user-nickname")
                if !nickname.isEmpty { return nickname }
                let value = text(element)
                if !value.isEmpty { return value }
            }
        }
        return ""
    }

    static func parseLoginForm(_ html: String) throws -> LoginForm {
        guard let doc = try? SwiftSoup.parse(html) else {
            throw AppError("未能解析登录页，请稍后重试")
        }
        guard let form = first(doc, "form.js-loginForm") else {
            throw AppError("未能解析登录表单，站点结构可能已变化")
        }

        var result = LoginForm()
        for input in select(form, "input") {
            let name = attr(input, "name")
            let value = attr(input, "value")
            if name == "token" { result.token = value }
            if name == "redirect" { result.redirect = value }
            if name == "from" { result.from = value }
        }
        if result.token.isEmpty {
            throw AppError("登录页缺少安全令牌，请稍后重试")
        }
        if result.from.isEmpty {
            result.from = "pc_login_modal_:login"
        }
        return result
    }

    /// 把可能的 HTML 片段（站点登录接口返回的错误信息）转成纯文本。
    static func plainText(_ html: String) -> String {
        if let doc = try? SwiftSoup.parse(html), let body = doc.body() {
            let value = text(body)
            if !value.isEmpty { return value }
        }
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
