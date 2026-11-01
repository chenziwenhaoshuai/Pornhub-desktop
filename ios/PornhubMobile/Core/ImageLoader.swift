import Foundation
import UIKit

/// 缩略图加载器。
///
/// 图片同样需要 Referer / Cookie，所以不能直接用 `AsyncImage`：
/// 统一走 `HTTPClient`，内存用 `NSCache`，磁盘用 URLSession 的 `URLCache`。
@MainActor
final class ImageLoader {

    static let shared = ImageLoader()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        memory.countLimit = 300
        memory.totalCostLimit = 64 * 1024 * 1024
    }

    func cached(_ url: String) -> UIImage? {
        guard !url.isEmpty else { return nil }
        return memory.object(forKey: url as NSString)
    }

    func image(for url: String, http: HTTPClient) async -> UIImage? {
        guard !url.isEmpty else { return nil }
        if let hit = memory.object(forKey: url as NSString) { return hit }
        if let running = inFlight[url] { return await running.value }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self = self else { return nil }
            let data = await loadImageData(url, http: http)
            guard let data = data, let image = UIImage(data: data) else { return nil }
            self.memory.setObject(image, forKey: url as NSString, cost: data.count)
            return image
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }

    func clear() {
        memory.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
    }
}

private func loadImageData(_ url: String, http: HTTPClient) async -> Data? {
    do {
        let response = try await http.request("GET", url,
                                              headers: ["Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"],
                                              cachePolicy: .returnCacheDataElseLoad)
        guard (200..<300).contains(response.status) else { return nil }
        return response.body
    } catch {
        return nil
    }
}
