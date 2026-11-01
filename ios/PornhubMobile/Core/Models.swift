import Foundation

/* -----------------------------------------------------------------------------
 * 数据模型
 *
 * 与桌面端 src-tauri/src/parse.rs 中的结构一一对应，字段名保持一致，
 * 方便对照维护。
 * -------------------------------------------------------------------------- */

struct VideoItem: Identifiable, Hashable {
    var vkey: String = ""
    var title: String = ""
    var thumb: String = ""
    var duration: String = ""
    var views: String = ""
    var author: String = ""
    var href: String = ""

    var id: String { vkey.isEmpty ? href : vkey }

    var displayTitle: String { title.isEmpty ? "未命名视频" : title }
}

struct CategoryItem: Identifiable, Hashable {
    var categoryID: String = ""
    var name: String = ""
    var count: String = ""
    var thumb: String = ""
    var href: String = ""

    var id: String { href.isEmpty ? name : href }
}

struct LinkItem: Identifiable, Hashable {
    var name: String = ""
    var href: String = ""

    var id: String { href + "|" + name }
}

struct VideoSource: Identifiable, Hashable {
    var quality: String = ""
    var height: Int = 0
    var format: String = ""
    var url: String = ""
    var isDefault: Bool = false

    var id: String { "\(url)|\(height)|\(quality)" }

    var label: String {
        let trimmed = quality.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.lowercased() != "auto" {
            return trimmed
        }
        if height > 0 { return "\(height)p" }
        return "默认"
    }

    var isHLS: Bool {
        format.lowercased() == "hls" || url.lowercased().contains(".m3u8")
    }
}

struct VideoDetail {
    var vkey: String = ""
    var title: String = ""
    var views: String = ""
    var publish: String = ""
    var duration: Int = 0
    var author: String = ""
    var authorHref: String = ""
    var avatar: String = ""
    var image: String = ""
    var categories: [LinkItem] = []
    var tags: [LinkItem] = []
    var sources: [VideoSource] = []
    var related: [VideoItem] = []
    var unavailable: Bool = false
    var url: String = ""

    var displayTitle: String { title.isEmpty ? "未命名视频" : title }
}

struct ListingPage {
    var title: String = ""
    var items: [VideoItem] = []
    var current: Int = 1
    var pages: [Int] = []
    var nextHref: String? = nil
    var prevHref: String? = nil
}

struct Account {
    var loggedIn: Bool = false
    var username: String = ""
}

struct TwoFactorChallenge {
    var twoStepType: String = ""
    var email: String = ""
    var username: String = ""
    var phoneNumber: String = ""
    var authyId: String = ""
    var authyIdHashed: String = ""
    var autoLoginParameter: String = ""
    var csrf: String = ""
}

enum LoginResult {
    case ok(Account)
    case twoFactor(TwoFactorChallenge)
}

struct TestResult {
    var ok: Bool = false
    var ms: Int = 0
    var message: String = ""
    var loggedIn: Bool = false
}

/* ------------------------------ 观看历史 ------------------------------ */

struct HistoryEntry: Codable, Identifiable, Hashable {
    var vkey: String = ""
    var title: String = ""
    var thumb: String = ""
    var duration: String = ""
    var author: String = ""
    var position: Double = 0
    var durationSec: Double = 0
    var at: Double = 0

    var id: String { vkey }

    var displayTitle: String { title.isEmpty ? "未命名视频" : title }

    var progressFraction: Double {
        guard durationSec > 0 else { return 0 }
        return max(0, min(1, position / durationSec))
    }

    var asVideoItem: VideoItem {
        VideoItem(vkey: vkey, title: title, thumb: thumb, duration: duration, views: "", author: author, href: "")
    }
}

/* ------------------------------ 提示消息 ------------------------------ */

struct ToastMessage: Identifiable {
    enum Kind {
        case info
        case good
        case bad
    }

    let id = UUID()
    var text: String
    var kind: Kind = .info
}
