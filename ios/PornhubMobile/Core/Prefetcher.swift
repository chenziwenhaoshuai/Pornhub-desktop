import Foundation
import Combine

/// 后台整片预缓冲，对应桌面端 `src-tauri/src/prefetch.rs`。
///
/// 点开视频后延迟 2.5 秒开始（先让播放器抢到首屏带宽），
/// 以 4 路并发把该视频的所有分片下载到磁盘缓存，供播放器直接命中。
@MainActor
final class Prefetcher: ObservableObject {

    struct Progress {
        var active: Bool = false
        var complete: Bool = false
        var total: Int = 0
        var done: Int = 0
        var bytes: Int = 0
        var message: String = ""
    }

    @Published private(set) var progress = Progress()

    private var task: Task<Void, Never>?
    private var generation = 0
    private let concurrency = 4
    private let maxBytes = 6 * 1024 * 1024 * 1024

    func start(url: String, http: HTTPClient) {
        stop()
        generation += 1
        let current = generation
        progress = Progress(active: true,
                            complete: false,
                            total: 0,
                            done: 0,
                            bytes: 0,
                            message: "正在读取播放列表…")

        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self = self, !Task.isCancelled else { return }
            await self.download(url: url, http: http, generation: current)
        }
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        if progress.active {
            progress.active = false
            progress.message = ""
        }
    }

    /// 停止预缓冲并清空整块磁盘缓存。
    func clear() {
        stop()
        MediaCache.shared.clear()
        progress = Progress()
    }

    private func download(url: String, http: HTTPClient, generation: Int) async {
        do {
            var playlistURL = url
            var text = try await fetchPlaylist(playlistURL, http: http)

            if text.contains("#EXT-X-STREAM-INF") {
                let variant = text
                    .split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty && !$0.hasPrefix("#") }
                guard let variant = variant,
                      let absolute = PlaylistRewriter.resolve(variant, base: playlistURL) else {
                    throw AppError("主播放列表中没有可用清晰度")
                }
                playlistURL = absolute
                text = try await fetchPlaylist(absolute, http: http)
            }

            var targets: [String] = []
            var seen = Set<String>()
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }

                if line.hasPrefix("#") {
                    if line.hasPrefix("#EXT-X-MAP") || line.hasPrefix("#EXT-X-KEY") {
                        if let uri = PlaylistRewriter.extractURI(line),
                           let absolute = PlaylistRewriter.resolve(uri, base: playlistURL),
                           seen.insert(absolute).inserted {
                            targets.append(absolute)
                        }
                    }
                    continue
                }

                if let absolute = PlaylistRewriter.resolve(line, base: playlistURL),
                   seen.insert(absolute).inserted {
                    targets.append(absolute)
                }
            }

            if targets.isEmpty {
                throw AppError("未找到可缓冲的视频分片")
            }

            progress.total = targets.count
            progress.message = "正在预缓冲…"

            var index = 0
            while index < targets.count {
                if Task.isCancelled || generation != self.generation { return }
                if MediaCache.shared.totalBytes > maxBytes {
                    progress.active = false
                    progress.message = "已达到本地缓存上限（6 GB）"
                    return
                }

                let upper = min(index + concurrency, targets.count)
                let chunk = Array(targets[index..<upper])
                index = upper

                let bytes = await withTaskGroup(of: Int.self) { group -> [Int] in
                    for target in chunk {
                        group.addTask {
                            await fetchSegmentData(target, http: http)
                        }
                    }
                    var collected: [Int] = []
                    for await value in group { collected.append(value) }
                    return collected
                }

                if Task.isCancelled || generation != self.generation { return }
                for value in bytes {
                    progress.done += 1
                    progress.bytes += value
                }
            }

            progress.active = false
            progress.complete = progress.total > 0 && progress.done >= progress.total
            if progress.complete {
                progress.message = "已完整缓存"
            }
        } catch {
            progress.active = false
            progress.complete = false
            progress.message = (error as? AppError)?.message ?? error.localizedDescription
        }
    }

    private func fetchPlaylist(_ url: String, http: HTTPClient) async throws -> String {
        let response = try await http.request("GET", url, headers: ["Accept": "*/*"])
        guard (200..<300).contains(response.status) else {
            throw AppError("播放列表返回 HTTP \(response.status)")
        }
        return response.text
    }
}

/// 下载单个分片（成功时写入磁盘缓存），返回新增字节数。
private func fetchSegmentData(_ url: String, http: HTTPClient) async -> Int {
    let cache = MediaCache.shared
    if cache.has(url) { return 0 }

    do {
        let response = try await http.request("GET", url, headers: ["Accept": "*/*"])
        guard (200..<300).contains(response.status), !response.body.isEmpty else { return 0 }
        let contentType = response.header("content-type") ?? "application/octet-stream"
        cache.store(url, status: response.status, contentType: contentType, data: response.body)
        return response.body.count
    } catch {
        return 0
    }
}
