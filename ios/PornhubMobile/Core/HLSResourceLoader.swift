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
    }

    private func load(remote: String) async throws -> Payload {
        if let cached = cache.load(remote), !cached.data.isEmpty {
            let isPlaylist = HLSResourceLoader.isPlaylist(remote: remote, contentType: cached.contentType)
            var data = cached.data
            if isPlaylist {
                let text = String(decoding: data, as: UTF8.self)
                data = Data(PlaylistRewriter.rewrite(text, base: remote).utf8)
            }
            return Payload(data: data, contentType: cached.contentType, isPlaylist: isPlaylist)
        }

        let response = try await http.request("GET", remote,
                                              headers: ["Accept": "*/*"],
                                              cachePolicy: .reloadIgnoringLocalCacheData)
        guard (200..<300).contains(response.status) else {
            throw AppError("视频分片返回 HTTP \(response.status)")
        }

        let contentType = response.header("content-type") ?? ""
        var data = response.body
        let isPlaylist = HLSResourceLoader.isPlaylist(remote: remote, contentType: contentType)
            || HLSResourceLoader.hasPlaylistHeader(data)

        if isPlaylist {
            let text = String(decoding: data, as: UTF8.self)
            data = Data(PlaylistRewriter.rewrite(text, base: remote).utf8)
        } else {
            cache.store(remote, status: response.status, contentType: contentType, data: data)
        }

        return Payload(data: data, contentType: contentType, isPlaylist: isPlaylist)
    }

    private func finish(_ request: AVAssetResourceLoadingRequest,
                        payload: Payload,
                        offset: Int,
                        length: Int) {
        let data = payload.data

        if let info = request.contentInformationRequest {
            info.contentType = HLSResourceLoader.uti(contentType: payload.contentType,
                                                     playlist: payload.isPlaylist)
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
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

    static func uti(contentType: String, playlist: Bool) -> String {
        if playlist { return "public.mpegurl" }
        let lower = contentType.lowercased()
        if lower.contains("mpegurl") { return "public.mpegurl" }
        if lower.contains("mp2t") || lower.contains("transport") { return "public.mpeg-2-transport-stream" }
        if lower.contains("mp4") { return "public.mpeg-4" }
        if lower.contains("aac") { return "public.aac-audio" }
        if lower.contains("mp3") { return "public.mp3" }
        return "public.data"
    }
}
