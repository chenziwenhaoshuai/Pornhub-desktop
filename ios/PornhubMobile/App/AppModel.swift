import Foundation
import SwiftUI

/// 全局状态：设置、账号、提示条，以及共享的 API 客户端和预缓冲器。
@MainActor
final class AppModel: ObservableObject {

    @Published var settings: AppSettings
    @Published var account = Account()
    @Published var toast: ToastMessage?
    /// 历史记录变化时自增，用来让历史页刷新。
    @Published var historyRevision = 0

    let api: APIClient
    let prefetcher = Prefetcher()

    private var didStart = false

    init() {
        let loaded = Storage.loadSettings()
        self.settings = loaded
        self.api = APIClient(settings: loaded)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        api.update(settings: settings)
        // 上一次运行留下的分片缓存不再需要（对应桌面端启动时清空）。
        MediaCache.shared.clear()
        Task { await refreshAccount() }
    }

    /* ------------------------------ 设置 ------------------------------ */

    func save(settings next: AppSettings, notify: Bool = true) {
        let normalized = next.normalized()
        settings = normalized
        Storage.saveSettings(normalized)
        api.update(settings: normalized)
        if notify {
            showToast("设置已保存并生效", kind: .good)
        }
    }

    /* ------------------------------ 账号 ------------------------------ */

    func refreshAccount() async {
        let result = await api.account()
        applyAccount(result)
    }

    func applyAccount(_ account: Account) {
        self.account = account
        guard account.loggedIn, !account.username.isEmpty else { return }
        guard settings.accountName != account.username else { return }
        var next = settings
        next.accountName = account.username
        settings = next
        Storage.saveSettings(next)
    }

    func logout() {
        api.logout()
        account = Account()
        var next = settings
        next.accountName = ""
        settings = next
        Storage.saveSettings(next)
        prefetcher.clear()
        historyRevision += 1
        showToast("已退出登录，本地 Cookie 已清除", kind: .good)
    }

    /* ------------------------------ 连接测试 ------------------------------ */

    func testConnection() async -> TestResult {
        let result = await api.test()
        if result.loggedIn && !account.loggedIn {
            await refreshAccount()
        }
        return result
    }

    /* ------------------------------ 本地数据 ------------------------------ */

    var mediaCacheBytes: Int {
        MediaCache.shared.totalBytes
    }

    func clearPageCache() {
        api.clearCache()
        ImageLoader.shared.clear()
        showToast("页面缓存已清除", kind: .good)
    }

    func clearMediaCache() {
        prefetcher.clear()
        showToast("视频缓存已清除", kind: .good)
    }

    /// 离开视频页时静默清空分片缓存（对应桌面端的“退出视频时清空”）。
    func dropMediaCacheSilently() {
        prefetcher.clear()
    }

    func clearHistory() {
        HistoryStore.clear()
        historyRevision += 1
        showToast("观看历史已清空", kind: .good)
    }

    /* ------------------------------ 提示 ------------------------------ */

    func showToast(_ text: String, kind: ToastMessage.Kind = .info) {
        let message = ToastMessage(text: text, kind: kind)
        toast = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard let self = self else { return }
            if self.toast?.id == message.id {
                self.toast = nil
            }
        }
    }
}
