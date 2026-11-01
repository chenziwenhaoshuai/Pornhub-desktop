import Foundation
import AVFoundation

/// HLS 播放地址改写。
///
/// AVFoundation 只在 URL scheme 不是它原生支持的情况下才会把请求交给
/// `AVAssetResourceLoader`，所以播放列表里的每个地址都要改写成 `phstream://`，
/// 由 `HLSResourceLoader` 从本地缓存或上游取回。
enum PlaylistRewriter {

    static func resolve(_ uri: String, base: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        guard let baseURL = URL(string: base) else { return nil }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    static func proxify(_ uri: String, base: String) -> String {
        guard let absolute = resolve(uri, base: base) else { return uri }
        return "\(HLSResourceLoader.scheme)://media/\(HLSResourceLoader.encode(absolute))"
    }

    /// 把 m3u8 里的分片地址、`URI="..."`（加密密钥 / EXT-X-MAP）全部改写。
    static func rewrite(_ text: String, base: String) -> String {
        var lines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.append("")
            } else if trimmed.hasPrefix("#") {
                lines.append(rewriteAttributes(line, base: base))
            } else {
                lines.append(proxify(trimmed, base: base))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func rewriteAttributes(_ line: String, base: String) -> String {
        var result = ""
        var rest = Substring(line)
        let marker = "URI=\""

        while let range = rest.range(of: marker) {
            result += String(rest[rest.startIndex..<range.upperBound])
            let after = rest[range.upperBound...]
            guard let end = after.firstIndex(of: "\"") else {
                rest = after
                break
            }
            let uri = String(after[after.startIndex..<end])
            result += proxify(uri, base: base)
            result += "\""
            rest = after[after.index(after: end)...]
        }
        result += String(rest)
        return result
    }

    static func extractURI(_ line: String) -> String? {
        guard let range = line.range(of: "URI=\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }
}

/// 播放链路诊断：缓存模式失败时把真实原因带到 UI / 系统日志里。
final class LoaderDiagnostics {
    static let shared = LoaderDiagnostics()

    private let lock = NSLock()
    private var messages: [String] = []

    var lastMessage: String {
        lock.lock()
        defer { lock.unlock() }
        return messages.last ?? ""
    }

    func record(_ text: String) {
        lock.lock()
        messages.append(text)
        if messages.count > 40 { messages.removeFirst(messages.count - 40) }
        lock.unlock()
        NSLog("[PHLoader] %@", text)
    }

    func reset() {
        lock.lock()
        messages.removeAll()
        lock.unlock()
    }
}

/// 播放时的分片提供者：先查本地缓存，缺失时回源下载并写入缓存。
/// 这样只要预缓冲跑过，拖动进度条基本不用等。
final class HLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    static let scheme = "phstream"

    let queue: DispatchQueue
    private let http: HTTPClient
    private let cache: MediaCache
    private let lock = NSLock()
    private var cancelled: Set<ObjectIdentifier> = []

    init(http: HTTPClient, cache: MediaCache) {
        self.http = http
        self.cache = cache
        self.queue = DispatchQueue(label: "local.ph.stream.loader", qos: .userInitiated)
        super.init()
    }

    /* ------------------------------ 地址编解码 ------------------------------ */

    static func encode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> String? {
        var text = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        guard let data = Data(base64Encoded: text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func assetURL(for remote: String) -> URL? {
        guard !remote.isEmpty else { return nil }
        return URL(string: "\(scheme)://media/\(encode(remote))")
    }

    static func remoteURL(for local: URL) -> String? {
        guard local.scheme == scheme else { return nil }
        let encoded = local.lastPathComponent
        guard !encoded.isEmpty else { return nil }
        return decode(encoded)
    }

    /* ------------------------------ 代理方法 ------------------------------ */

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        handle(loadingRequest)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        cancelled.insert(ObjectIdentifier(loadingRequest))
        lock.unlock()
    }

    private func isCancelled(_ request: AVAssetResourceLoadingRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(ObjectIdentifier(request))
    }

    private func handle(_ request: AVAssetResourceLoadingRequest) {
        guard let localURL = request.request.url,
              let remote = HLSResourceLoader.remoteURL(for: localURL) else {
            request.finishLoading(with: AppError("无效的播放地址") as NSError)
            return
        }

        let offset = Int(request.dataRequest?.requestedOffset ?? 0)
        let allToEnd = request.dataRequest?.requestsAllDataToEndOfResource ?? true
        let requestedLength = request.dataRequest?.requestedLength ?? 0

        Task {
            do {
                let payload = try await self.load(remote: remote)
                self.queue.async {
                    guard !self.isCancelled(request) else { return }
                    self.finish(request, payload: payload, offset: offset,
                                length: allToEnd ? 0 : requestedLength)
                }
            } catch {
                LoaderDiagnostics.shared.record("取流失败 \(remote)：\(error.localizedDescription)")
                self.queue.async {
                    guard !self.isCancelled(request) else { return }
                    request.finishLoading(with: error as NSError)
                }
            }
        }
    }

    private struct Payload {
        var data: Data
        var contentType: String
        var isPlaylist: Bool
        var remote: String
    }

    private func load(remote: String) async throws -> Payload {
        if let cached = cache.load(remote), !cached.data.isEmpty {
            let isPlaylist = HLSResourceLoader.isPlaylist(remote: remote, contentType: cached.contentType)
            var data = cached.data
            if isPlaylist {
                let text = String(decoding: data, as: UTF8.self)
                data = Data(PlaylistRewriter.rewrite(text, base: remote).utf8)
            }
            return Payload(data: data, contentType: cached.contentType, isPlaylist: isPlaylist, remote: remote)
        }

        let response = try await http.request("GET", remote,
                                              headers: ["Accept": "*/*"],
                                              cachePolicy: .reloadIgnoringLocalCacheData)
        guard (200..<300).contains(response.status) else {
            LoaderDiagnostics.shared.record("HTTP \(response.status) \(remote)")
            throw AppError("视频分片返回 HTTP \(response.status)")
        }

        let contentType = response.header("content-type") ?? ""
        var data = response.body
        let isPlaylist = HLSResourceLoader.isPlaylist(remote: remote, contentType: contentType)
            || HLSResourceLoader.hasPlaylistHeader(data)

        if isPlaylist {
            let text = String(decoding: data, as: UTF8.self)
            // 关键：必须用重定向后的最终地址做相对路径基准。
            // 站点 master.m3u8 常 302 到 CDN，用原始地址会拼出错误的分片 host。
            let base = response.url.absoluteString.isEmpty ? remote : response.url.absoluteString
            data = Data(PlaylistRewriter.rewrite(text, base: base).utf8)
            LoaderDiagnostics.shared.record("播放列表 \(remote) -> base \(base)")
        } else {
            cache.store(remote, status: response.status, contentType: contentType, data: data)
        }

        return Payload(data: data, contentType: contentType, isPlaylist: isPlaylist, remote: remote)
    }

    private func finish(_ request: AVAssetResourceLoadingRequest,
                        payload: Payload,
                        offset: Int,
                        length: Int) {
        let data = payload.data

        if let info = request.contentInformationRequest {
            info.contentType = HLSResourceLoader.uti(contentType: payload.contentType,
                                                     playlist: payload.isPlaylist,
                                                     remote: payload.remote)
            info.contentLength = Int64(data.count)
            // m3u8 不支持 byte-range；分片由我们自己切片返回
            info.isByteRangeAccessSupported = !payload.isPlaylist
        }

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }

        let start = max(0, min(offset, data.count))
        let available = data.count - start
        var size = length
        if size <= 0 || size > available { size = available }

        if size > 0 {
            dataRequest.respond(with: data.subdata(in: start..<(start + size)))
        }
        request.finishLoading()
    }

    /* ------------------------------ 工具 ------------------------------ */

    static func isPlaylist(remote: String, contentType: String) -> Bool {
        if contentType.lowercased().contains("mpegurl") { return true }
        return remote.lowercased().contains(".m3u8")
    }

    static func hasPlaylistHeader(_ data: Data) -> Bool {
        guard let text = String(data: data.prefix(16), encoding: .utf8) else { return false }
        return text.contains("#EXTM3U")
    }

    static func uti(contentType: String, playlist: Bool, remote: String = "") -> String {
        // 注意：iOS 系统里没有 "public.mpegurl" 这个 UTI，
        // m3u8 对应的真实 UTI 是 "public.m3u-playlist"。写错会导致
        // AVPlayerItem 直接 failed（表现为“无可用资源”，随后回退直连）。
        if playlist { return "public.m3u-playlist" }
        let lower = contentType.lowercased()
        if lower.contains("mpegurl") || lower.contains("m3u8") { return "public.m3u-playlist" }
        if lower.contains("mp2t") || lower.contains("transport") { return "public.mpeg-2-transport-stream" }
        if lower.contains("mp4") { return "public.mpeg-4" }
        if lower.contains("aac") { return "public.aac-audio" }
        if lower.contains("mp3") { return "public.mp3" }

        // 服务器常把分片标成 application/octet-stream，按扩展名兜底
        let path = remote.lowercased().split(separator: "?").first.map(String.init) ?? remote.lowercased()
        if path.hasSuffix(".ts") { return "public.mpeg-2-transport-stream" }
        if path.hasSuffix(".m4s") || path.hasSuffix(".m4v") || path.hasSuffix(".mp4") { return "public.mpeg-4" }
        if path.hasSuffix(".aac") { return "public.aac-audio" }
        if path.hasSuffix(".key") { return "public.data" }
        return "public.data"
    }
}
