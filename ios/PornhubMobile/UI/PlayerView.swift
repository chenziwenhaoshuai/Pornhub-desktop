import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

/// 播放器状态机。
///
/// 两种播放模式（对应设置里的“整片预缓冲”）：
/// - 缓存模式：`phstream://` 资源经 `HLSResourceLoader` 从本地分片缓存读取，
///   同时后台把整片下载下来，拖动基本不用等。
/// - 直连模式：直接把上游 HLS 地址交给 AVPlayer。
///
/// 缓存模式失败时会自动回退一次直连，避免用户卡在“加载失败”。
@MainActor
final class PlayerModel: ObservableObject {

    let player = AVPlayer()

    @Published var note: String = ""
    @Published var errorMessage: String?
    @Published var diagnostic: String = ""
    @Published var sourceIndex: Int = 0
    @Published var rate: Double = 1

    private var http: HTTPClient?
    private var sources: [VideoSource] = []
    private var loader: HLSResourceLoader?
    private var statusSink: AnyCancellable?
    private var controlSink: AnyCancellable?
    private var timeObserver: Any?
    private var prefetcher: Prefetcher?

    private var resumeAt: Double = 0
    private var useCache = true
    private var prefetchEnabled = true
    private var usedFallback = false
    private var lastKnownPlaying = false
    private var wasPlayingBeforeFullscreen = false
    private var started = false

    private(set) var vkey = ""
    private var metaTitle = ""
    private var metaThumb = ""
    private var metaAuthor = ""
    private var metaDuration = 0

    /* ------------------------------ 配置 ------------------------------ */

    func configure(detail: VideoDetail,
                   http: HTTPClient,
                   useCache: Bool,
                   prefetch: Bool,
                   prefetcher: Prefetcher) {
        self.http = http
        self.sources = detail.sources
        self.useCache = useCache
        self.prefetchEnabled = prefetch
        self.prefetcher = prefetcher
        self.vkey = detail.vkey
        self.metaTitle = detail.title
        self.metaThumb = detail.image
        self.metaAuthor = detail.author
        self.metaDuration = detail.duration
        self.resumeAt = HistoryStore.progress(for: detail.vkey) ?? 0
        self.usedFallback = false
        self.started = false
        self.note = ""
        self.errorMessage = nil

        // 上一个视频留下的分片缓存不再需要。
        prefetcher.clear()

        configureAudioSession()
        addPeriodicObserver()
        player.defaultRate = Float(rate)

        guard !detail.sources.isEmpty else {
            errorMessage = "该视频当前不可播放"
            return
        }
        if let preferred = detail.sources.first(where: { $0.isDefault })
            ?? detail.sources.max(by: { $0.height < $1.height }),
           let index = detail.sources.firstIndex(of: preferred) {
            load(index: index, forceDirect: false)
        }
    }

    /* ------------------------------ 加载 ------------------------------ */

    func load(index: Int, forceDirect: Bool) {
        guard index >= 0 && index < sources.count else { return }

        sourceIndex = index
        errorMessage = nil
        statusSink = nil
        controlSink = nil
        loader = nil
        diagnostic = ""
        LoaderDiagnostics.shared.reset()

        let source = sources[index]
        // HLS 的分片请求无法经过 AVAssetResourceLoader（系统返回 -12881
        // "custom url not redirect"），因此本地缓存播放暂不启用，统一直连。
        let cacheEnabled = false && useCache && !forceDirect && source.isHLS

        let item: AVPlayerItem
        if cacheEnabled, let http = http, let assetURL = HLSResourceLoader.assetURL(for: source.url) {
            let resourceLoader = HLSResourceLoader(http: http, cache: MediaCache.shared)
            let asset = AVURLAsset(url: assetURL)
            asset.resourceLoader.setDelegate(resourceLoader, queue: resourceLoader.queue)
            loader = resourceLoader
            item = AVPlayerItem(asset: asset)
        } else if let url = URL(string: source.url) {
            // 直连也必须带上站点请求头：CDN 会校验 Referer / UA / Cookie，
            // 否则 m3u8 能下载（预缓冲走 HTTPClient）但 AVPlayer 拒绝播放。
            item = AVPlayerItem(asset: PlayerModel.makeAsset(url: url, http: http))
        } else {
            errorMessage = "播放地址无效"
            return
        }

        player.replaceCurrentItem(with: item)
        observe(item: item, index: index)
        player.defaultRate = Float(rate)
        player.play()

        prefetcher?.stop()
        if cacheEnabled && prefetchEnabled, let http = http {
            prefetcher?.start(url: source.url, http: http)
        }
    }

    /// 给 AVPlayer 的请求注入与站点一致的头部（AVFoundation 原生请求默认不带 Referer）。
    static func makeAsset(url: URL, http: HTTPClient?) -> AVURLAsset {
        guard let http else { return AVURLAsset(url: url) }
        var headers: [String: String] = [
            "Referer": http.referer,
            "User-Agent": HTTPClient.userAgent,
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"
        ]
        if let origin = URL(string: http.referer)?.scheme, let host = URL(string: http.referer)?.host {
            headers["Origin"] = "\(origin)://\(host)"
        }
        var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let cookies = HTTPCookieStorage.shared.cookies ?? []
        if !cookies.isEmpty {
            options["AVURLAssetHTTPCookiesKey"] = cookies
        }
        return AVURLAsset(url: url, options: options)
    }

    private func observe(item: AVPlayerItem, index: Int) {
        statusSink = item.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                switch status {
                case .readyToPlay:
                    self.applyResume()
                case .failed:
                    let message = item.error?.localizedDescription ?? "视频加载失败"
                    let nsError = item.error as NSError?
                    let code = nsError.map { "\($0.domain) #\($0.code)" } ?? "未知错误"
                    let logText = (item.errorLog()?.events ?? [])
                        .map { "\($0.errorStatusCode) \($0.errorComment ?? "")" }
                        .joined(separator: " | ")
                    let detail = "\(message) [\(code)] 解析器: \(LoaderDiagnostics.shared.lastMessage) 日志: \(logText)"
                    self.diagnostic = detail
                    NSLog("[PHPlayer] %@", detail)

                    if self.useCache && !self.usedFallback {
                        self.usedFallback = true
                        self.note = "缓存模式加载失败（\(code)），已切换为直连播放"
                        self.load(index: index, forceDirect: true)
                    } else {
                        self.errorMessage = message
                    }
                default:
                    break
                }
            }

        controlSink = player.publisher(for: \.timeControlStatus)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                self.lastKnownPlaying = (status == .playing)
                guard status == .playing else { return }
                if !self.started {
                    self.started = true
                    self.pushHistory()
                }
                if abs(Double(self.player.rate) - self.rate) > 0.01 {
                    self.player.rate = Float(self.rate)
                }
            }
    }

    /* ------------------------------ 播放控制 ------------------------------ */

    func setRate(_ value: Double) {
        rate = value
        player.currentItem?.audioTimePitchAlgorithm = .timeDomain
        player.defaultRate = Float(value)
        if player.timeControlStatus == .playing {
            player.rate = Float(value)
        }
    }

    func restart() {
        HistoryStore.removeProgress(for: vkey)
        resumeAt = 0
        player.seek(to: .zero)
        player.play()
    }

    func togglePlay() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /* ------------------------------ 续播 / 进度 ------------------------------ */

    private func applyResume() {
        guard resumeAt > 10 else { return }
        let duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite && duration > 0 && resumeAt > duration - 15 {
            resumeAt = 0
            return
        }
        let target = resumeAt
        resumeAt = 0
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
        note = "已从 \(Format.time(target)) 继续播放"
        started = true
        pushHistory()
    }

    private func pushHistory() {
        var entry = HistoryEntry()
        entry.vkey = vkey
        entry.title = metaTitle
        entry.thumb = metaThumb
        entry.author = metaAuthor
        entry.duration = Format.time(Double(metaDuration))
        entry.durationSec = Double(metaDuration)
        let seconds = player.currentTime().seconds
        entry.position = seconds.isFinite ? max(0, seconds) : 0
        HistoryStore.push(entry)
    }

    private func addPeriodicObserver() {
        removePeriodicObserver()
        let interval = CMTime(seconds: 4, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let seconds = time.seconds
            let total = self.player.currentItem?.duration.seconds ?? 0
            if seconds.isFinite && total.isFinite && total > 0 {
                HistoryStore.updateProgress(vkey: self.vkey, position: seconds, duration: total)
            }
        }
    }

    private func removePeriodicObserver() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    /* ------------------------------ 生命周期 ------------------------------ */

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    /// AVKit 进出全屏会自行暂停，按"进全屏前是否在播"决定是否恢复
    func handleFullscreen(_ active: Bool) {
        if active {
            wasPlayingBeforeFullscreen = lastKnownPlaying || player.timeControlStatus == .playing
        } else if wasPlayingBeforeFullscreen {
            player.play()
        }
    }

    /// 离开页面 / 进入系统全屏时调用：保存进度并暂停，但保留 item 与播放位置。
    /// 不能用 destroy()，否则全屏返回后会被重新解析、从头播放。
    func pauseKeepingPosition() {
        if player.currentItem != nil {
            pushHistory()
            player.pause()
        }
    }

    func destroy() {
        prefetcher?.stop()
        removePeriodicObserver()
        statusSink = nil
        controlSink = nil
        loader = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// 系统播放器界面：自带进度条、全屏、AirPlay、画中画。
@MainActor
struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    /// 全屏状态变化回调：全屏会触发 SwiftUI 的 onDisappear，
    /// 需要用这个标记区分"真离开页面"和"只是进了系统全屏"。
    var onFullscreenChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFullscreenChange: onFullscreenChange)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        controller.updatesNowPlayingInfoCenter = true
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private let onFullscreenChange: (Bool) -> Void

        init(onFullscreenChange: @escaping (Bool) -> Void) {
            self.onFullscreenChange = onFullscreenChange
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            onFullscreenChange(true)
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            onFullscreenChange(false)
        }
    }
}
