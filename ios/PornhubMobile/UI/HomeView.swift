import SwiftUI

@MainActor
struct HomeView: View {
    var openHistory: () -> Void = {}

    @EnvironmentObject private var model: AppModel
    @State private var items: [VideoItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var history: [HistoryEntry] = []

    var body: some View {
        ScrollView {
            content
        }
        .background(Theme.bg)
        .navigationTitle("首页")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(force: true) }
        .task(id: model.settings.domain) {
            await load(force: false)
            reloadHistory()
        }
        .onAppear { reloadHistory() }
        .onChange(of: model.historyRevision) { _ in reloadHistory() }
    }

    @ViewBuilder
    private var content: some View {
        if loading && items.isEmpty {
            LoadingView(text: "正在读取首页…")
        } else if let error = error, items.isEmpty {
            ErrorStateView(message: error) {
                Task { await load(force: true) }
            }
        } else if items.isEmpty {
            EmptyStateView(title: "首页暂时没有内容",
                           hint: "可能是网络节点未生效或站点结构发生变化，下拉刷新试试。")
        } else {
            VStack(alignment: .leading, spacing: 18) {
                hero
                if !history.isEmpty { continueSection }
                SectionHeader(title: "为你推荐")
                LazyVGrid(columns: GridLayout.columns, spacing: 16) {
                    ForEach(Array(items.dropFirst())) { item in
                        NavigationLink(value: Route.video(vkey: item.vkey)) {
                            VideoCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var hero: some View {
        let item = items[0]
        return NavigationLink(value: Route.video(vkey: item.vkey)) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay(RemoteImage(url: item.thumb))

                LinearGradient(colors: [Color.black.opacity(0.05), Color.black.opacity(0.9)],
                               startPoint: .top,
                               endPoint: .bottom)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill").font(.system(size: 9))
                        Text("今日推荐").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(Color(red: 0.1, green: 0.07, blue: 0.02))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent))

                    Text(item.displayTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if !item.duration.isEmpty { metaText(item.duration) }
                        if !item.views.isEmpty { metaText(item.views) }
                        if !item.author.isEmpty { metaText(item.author) }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 12))
                        Text("立即播放").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(Color(red: 0.08, green: 0.06, blue: 0.03))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent))
                    .padding(.top, 2)
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func metaText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Color.white.opacity(0.72))
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "继续观看", trailing: "全部历史", action: openHistory)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(history) { entry in
                        NavigationLink(value: Route.video(vkey: entry.vkey)) {
                            VideoCard(item: entry.asVideoItem,
                                      progress: entry.progressFraction,
                                      durationText: entry.duration)
                                .frame(width: 190)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func reloadHistory() {
        history = Array(HistoryStore.all().filter { $0.position > 10 }.prefix(8))
    }

    private func load(force: Bool) async {
        loading = true
        if items.isEmpty { error = nil }
        do {
            let result = try await model.api.home(force: force)
            items = result
            error = nil
        } catch let err {
            if items.isEmpty {
                self.error = (err as? AppError)?.message ?? err.localizedDescription
            }
        }
        loading = false
    }
}
