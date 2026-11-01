import Foundation
import CryptoKit

struct CachedMedia {
    var status: Int
    var contentType: String
    var data: Data
}

/// 视频分片的磁盘缓存，对应桌面端 `src-tauri/src/cache.rs`。
///
/// 文件名是 URL 的 SHA-256；另存一个 `.meta` 记录状态码和 Content-Type。
final class MediaCache {

    static let shared = MediaCache()

    let directory: URL
    private let lock = NSLock()
    private var totalBytesValue = 0

    private init() {
        let dir = Storage.mediaDirectory
        directory = dir
        totalBytesValue = MediaCache.directorySize(dir)
    }

    static func key(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        var out = ""
        out.reserveCapacity(64)
        for byte in digest {
            out += String(format: "%02x", byte)
        }
        return out
    }

    private func paths(_ url: String) -> (bin: URL, meta: URL) {
        let key = MediaCache.key(for: url)
        return (directory.appendingPathComponent(key + ".bin"),
                directory.appendingPathComponent(key + ".meta"))
    }

    func has(_ url: String) -> Bool {
        FileManager.default.fileExists(atPath: paths(url).bin.path)
    }

    func load(_ url: String) -> CachedMedia? {
        let target = paths(url)
        guard let data = try? Data(contentsOf: target.bin) else { return nil }
        let meta = (try? String(contentsOf: target.meta, encoding: .utf8)) ?? ""
        let lines = meta.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var status = 200
        if let first = lines.first, let parsed = Int(first.trimmingCharacters(in: .whitespaces)) {
            status = parsed
        }
        var contentType = ""
        if lines.count > 1 {
            contentType = lines[1].trimmingCharacters(in: .whitespaces)
        }
        return CachedMedia(status: status, contentType: contentType, data: data)
    }

    func store(_ url: String, status: Int, contentType: String, data: Data) {
        guard !data.isEmpty else { return }
        let target = paths(url)
        do {
            try data.write(to: target.bin, options: .atomic)
            try "\(status)\n\(contentType)\n".write(to: target.meta, atomically: true, encoding: .utf8)
            lock.lock()
            totalBytesValue += data.count
            lock.unlock()
        } catch {
            /* 磁盘写入失败时忽略：缓存只是加速手段 */
        }
    }

    var totalBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalBytesValue
    }

    func clear() {
        let manager = FileManager.default
        if let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for entry in entries {
                try? manager.removeItem(at: entry)
            }
        }
        lock.lock()
        totalBytesValue = 0
        lock.unlock()
    }

    static func directorySize(_ directory: URL) -> Int {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory,
                                                             includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total = 0
        for entry in entries {
            if let values = try? entry.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += size
            }
        }
        return total
    }
}
