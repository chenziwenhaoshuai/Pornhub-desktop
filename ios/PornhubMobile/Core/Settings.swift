import Foundation

struct ProxyConfig: Codable, Equatable {
    var enabled: Bool = true
    var host: String = "127.0.0.1"
    var port: Int = 7897
}

struct AppSettings: Codable, Equatable {
    var domain: String = "https://cn.pornhub.com"
    var proxy: ProxyConfig = ProxyConfig()
    var accountName: String = ""
    /// 点开视频后后台把整部视频缓存到本机（对应桌面端的“整片预缓冲”）。
    var prefetch: Bool = true
    /// 播放时走本地分片缓存；关闭则直接播上游 HLS 地址。
    var playCache: Bool = true

    enum CodingKeys: String, CodingKey {
        case domain
        case proxy
        case accountName
        case prefetch
        case playCache
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings()
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? fallback.domain
        proxy = try container.decodeIfPresent(ProxyConfig.self, forKey: .proxy) ?? fallback.proxy
        accountName = try container.decodeIfPresent(String.self, forKey: .accountName) ?? ""
        prefetch = try container.decodeIfPresent(Bool.self, forKey: .prefetch) ?? true
        playCache = try container.decodeIfPresent(Bool.self, forKey: .playCache) ?? true
    }

    func normalized() -> AppSettings {
        var next = self
        var domain = next.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if domain.isEmpty { domain = "https://cn.pornhub.com" }
        if !domain.hasPrefix("http://") && !domain.hasPrefix("https://") {
            domain = "https://" + domain
        }
        while domain.hasSuffix("/") { domain.removeLast() }
        next.domain = domain

        next.proxy.host = next.proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.proxy.host.isEmpty { next.proxy.host = "127.0.0.1" }
        if next.proxy.port <= 0 || next.proxy.port > 65535 { next.proxy.port = 7897 }

        next.accountName = next.accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return next
    }
}
