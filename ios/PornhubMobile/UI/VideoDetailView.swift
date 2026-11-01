import SwiftUI
import Combine

@MainActor
final class VideoDetailModel: ObservableObject {
    @Published var detail: VideoDetail?
    @Published var error: String?
    let player = PlayerModel()

    private var playerSink: AnyCancellable?

    init() {
        // 把播放器的状态变化转发出去，让页面上的缓存提示、错误条能实时刷新。
        playerSink = player.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func load(vkey: String, api: APIClient, force: Bool) async {
        do {
            let value = try await api.video(vkey: vkey, force: force)
            detail = value
            error = nil
        } catch let err {
            self.error = (err as? AppError)?.message ?? err.localizedDescription
        }
    }
}

/// 预缓冲进度提示，单独观察 `Prefetcher`。
@MainActor
struct PrefetchNoteView: View {
    @ObservedObject var prefetcher: Prefetcher
    var fallback: String = ""

    var body: some View {
        let text = content
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var content: String {
        let progress = prefetcher.progress
        if progress.active {
            if progress.total == 0 { return "正在读取播放列表…" }
            let percent = progress.total > 0
                ? Int(Double(progress.done) / Double(progress.total) * 100)
                : 0
            return "正在预缓冲 \(percent)% · \(progress.done)/\(progress.total) 段 · 已缓存 \(Format.bytes(progress.bytes))"
        }
        if progress.complete {
            return "已完整缓存 \(Format.bytes(progress.bytes))，拖动进度条无需等待"
        }
        if !progress.message.isEmpty { return progress.message }
        return fallback
    }
}

@MainActor
struct VideoDetailView: View {
    @State private var isFullscreen = false
    let vkey: String

    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    @StateObject private var vm = VideoDetailModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let detail = vm.detail {
                    playerBlock(detail)

                    PrefetchNoteView(prefetcher: model.prefetcher, fallback: vm.player.note)
                        .padding(.horizontal, 16)

                    infoBlock(detail)
                        .padding(.horizontal, 16)
                    actionBlock(detail)
                        .padding(.horizontal, 16)
                    if !detail.categories.isEmpty || !detail.tags.isEmpty {
                        tagsBlock(detail)
                            .padding(.horizontal, 16)
                    }
                    relatedBlock(detail)
                        .padding(.horizontal, 16)
                } else if let error = vm.error {
                    ErrorStateView(message: error) {
                        Task { await reload(force: true) }
                    }
                } else {
                    LoadingView(text: "正在解析视频地址…")
                }
            }
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .navigationTitle(vm.detail?.displayTitle ?? "视频")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 系统全屏会触发一次 disappear/appear，已有数据时不要重新解析
            if vm.detail == nil {
                await reload(force: false)
            }
        }
        .onDisappear {
            model.dropMediaCacheSilently()
            // 系统全屏也会触发 onDisappear，且回调顺序不保证，
            // 所以延迟 350ms 再判断：全屏中就不暂停，真正离开页面才暂停并保存进度。
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if !isFullscreen {
                    vm.player.pauseKeepingPosition()
                }
            }
        }
    }

    /* ------------------------------ 播放器 ------------------------------ */

    private func playerBlock(_ detail: VideoDetail) -> some View {
        VStack(spacing: 0) {
            Color.black
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(PlayerSurface(player: vm.player.player) { fullscreen in
                    isFullscreen = fullscreen
                })

            if let failure = vm.player.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.danger)
                    Text(failure)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("重试") {
                        vm.player.load(index: vm.player.sourceIndex, forceDirect: false)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.panel)
            }

            controlBar(detail)
        }
    }

    private func controlBar(_ detail: VideoDetail) -> some View {
        HStack(spacing: 16) {
            Menu {
                ForEach(detail.sources.indices, id: \.self) { index in
                    Button {
                        vm.player.load(index: index, forceDirect: false)
                    } label: {
                        if index == vm.player.sourceIndex {
                            Label(detail.sources[index].label, systemImage: "checkmark")
                        } else {
                            Text(detail.sources[index].label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 11))
                    Text(qualityLabel(detail)).font(.system(size: 12))
                }
                .foregroundColor(Theme.text)
            }

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                    Button(rateLabel(value)) {
                        vm.player.setRate(value)
                    }
                }
            } label: {
                Text(rateLabel(vm.player.rate))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.text)
            }

            Button {
                vm.player.togglePlay()
            } label: {
                Image(systemName: "playpause.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text)
            }

            Spacer()

            Button {
                vm.player.restart()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gobackward").font(.system(size: 11))
                    Text("从头播放").font(.system(size: 12))
                }
                .foregroundColor(Theme.text)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.panel)
    }

    private func qualityLabel(_ detail: VideoDetail) -> String {
        guard vm.player.sourceIndex >= 0, vm.player.sourceIndex < detail.sources.count else {
            return "画质"
        }
        return detail.sources[vm.player.sourceIndex].label
    }

    private func rateLabel(_ value: Double) -> String {
        if abs(value - 1) < 0.01 { return "1×" }
        return String(format: "%g×", value)
    }

    /* ------------------------------ 信息 ------------------------------ */

    private func infoBlock(_ detail: VideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.displayTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if !detail.views.isEmpty {
                    Text("\(detail.views) 次观看")
                }
                if !detail.publish.isEmpty {
                    Text(detail.publish)
                }
                if detail.duration > 0 {
                    Text(Format.time(Double(detail.duration)))
                }
            }
            .font(.system(size: 11))
            .foregroundColor(Theme.muted)

            if !detail.author.isEmpty {
                HStack(spacing: 8) {
                    Color.clear
                        .frame(width: 30, height: 30)
                        .background(Theme.panel2)
                        .clipShape(Circle())
                        .overlay(RemoteImage(url: detail.avatar))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 1) {
                        Text(detail.author)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.text)
                        Text("上传者")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.muted2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
    }

    private func actionBlock(_ detail: VideoDetail) -> some View {
        HStack(spacing: 9) {
            Button {
                Task { await reload(force: true) }
            } label: {
                Label("刷新播放地址", systemImage: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(GhostButtonStyle())

            Button {
                if let url = URL(string: detail.url) {
                    openURL(url)
                }
            } label: {
                Label("在浏览器打开", systemImage: "safari")
                    .font(.system(size: 12))
            }
            .buttonStyle(GhostButtonStyle())

            Spacer(minLength: 0)
        }
    }

    private func tagsBlock(_ detail: VideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !detail.categories.isEmpty {
                SectionHeader(title: "分类")
                FlowLayout(spacing: 8) {
                    ForEach(detail.categories) { item in
                        NavigationLink(value: Route.list(path: Parser.relativePath(item.href, domain: model.settings.domain),
                                                         title: item.name)) {
                            Chip(text: item.name)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !detail.tags.isEmpty {
                SectionHeader(title: "标签")
                FlowLayout(spacing: 8) {
                    ForEach(Array(detail.tags.prefix(24))) { item in
                        NavigationLink(value: Route.list(path: Parser.relativePath(item.href, domain: model.settings.domain),
                                                         title: item.name)) {
                            Chip(text: item.name)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func relatedBlock(_ detail: VideoDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !detail.related.isEmpty {
                SectionHeader(title: "相关推荐")
                ForEach(detail.related) { item in
                    NavigationLink(value: Route.video(vkey: item.vkey)) {
                        HStack(alignment: .top, spacing: 10) {
                            Color.clear
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .frame(width: 124)
                                .overlay(RemoteImage(url: item.thumb))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayTitle)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Theme.text)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(relatedSubtitle(item))
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
    }

    private func relatedSubtitle(_ item: VideoItem) -> String {
        var parts: [String] = []
        if !item.author.isEmpty { parts.append(item.author) }
        if !item.views.isEmpty { parts.append(item.views) }
        if !item.duration.isEmpty { parts.append(item.duration) }
        return parts.joined(separator: " · ")
    }

    /* ------------------------------ 数据 ------------------------------ */

    private func reload(force: Bool) async {
        await vm.load(vkey: vkey, api: model.api, force: force)
        guard let detail = vm.detail else { return }
        vm.player.configure(detail: detail,
                            http: model.api.http,
                            useCache: model.settings.playCache,
                            prefetch: model.settings.prefetch,
                            prefetcher: model.prefetcher)
    }
}
