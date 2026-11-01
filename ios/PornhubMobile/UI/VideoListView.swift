import SwiftUI

struct SortOption: Identifiable, Hashable {
    let id: String
    let label: String
}

let allSortOptions: [SortOption] = [
    SortOption(id: "ht", label: "最热"),
    SortOption(id: "mv", label: "最多观看"),
    SortOption(id: "tr", label: "评分最高"),
    SortOption(id: "cm", label: "最新")
]

/// 把 `o=xx` 之类的查询参数改掉，保留其它参数。
func withQueryParam(_ path: String, key: String, value: String) -> String {
    let prefix = "https://local"
    guard var components = URLComponents(string: prefix + path) else { return path }
    var items = components.queryItems ?? []
    items.removeAll { $0.name == key }
    items.append(URLQueryItem(name: key, value: value))
    components.queryItems = items
    guard let result = components.string, result.hasPrefix(prefix) else { return path }
    return String(result.dropFirst(prefix.count))
}

func queryParam(_ path: String, key: String) -> String? {
    guard let components = URLComponents(string: "https://local" + path) else { return nil }
    return components.queryItems?.first { $0.name == key }?.value
}

@MainActor
final class ListModel: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var heading: String = ""
    @Published var current: Int = 1
    @Published var totalPages: Int = 1
    @Published var loading = false
    @Published var error: String?

    func load(api: APIClient, path: String, page: Int, reset: Bool, force: Bool = false) async {
        if loading { return }
        loading = true
        if reset { error = nil }

        do {
            let result = try await api.listing(path: path, page: page, force: force)
            if reset {
                items = result.items
            } else {
                let existing = Set(items.map { $0.id })
                items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            }
            heading = result.title
            current = result.current
            totalPages = result.pages.last ?? max(result.current, 1)
            error = nil
        } catch let err {
            self.error = (err as? AppError)?.message ?? err.localizedDescription
        }

        loading = false
    }
}

@MainActor
struct VideoListView: View {
    let heading: String

    @EnvironmentObject private var model: AppModel
    @StateObject private var list = ListModel()
    @State private var path: String

    init(path: String, heading: String) {
        self.heading = heading
        _path = State(initialValue: path)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !sortOptions.isEmpty {
                    sortChips
                }

                if list.loading && list.items.isEmpty {
                    LoadingView()
                } else if let error = list.error, list.items.isEmpty {
                    ErrorStateView(message: error) {
                        Task { await reload(force: true) }
                    }
                } else if list.items.isEmpty {
                    EmptyStateView(title: "没有找到视频", hint: "换个关键词或分类试试。")
                } else {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)

                    LazyVGrid(columns: GridLayout.columns, spacing: 16) {
                        ForEach(list.items) { item in
                            NavigationLink(value: Route.video(vkey: item.vkey)) {
                                VideoCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    paging
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await reload(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task(id: path) {
            await reload(force: false)
        }
    }

    private var titleText: String {
        if !heading.isEmpty { return heading }
        if !list.heading.isEmpty { return list.heading }
        return "视频列表"
    }

    private var subtitle: String {
        var text = "第 \(list.current) 页 · \(list.items.count) 个结果"
        if isSearch, let keyword = searchKeyword {
            text += " · 搜索“\(keyword)”"
        }
        return text
    }

    private var isSearch: Bool {
        path.contains("/video/search")
    }

    private var searchKeyword: String? {
        queryParam(path, key: "search")
    }

    private var sortOptions: [SortOption] {
        if isSearch { return [] }
        if path.contains("c=") { return allSortOptions.filter { $0.id != "ht" } }
        return allSortOptions
    }

    private var currentSort: String {
        queryParam(path, key: "o") ?? "ht"
    }

    private var sortChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sortOptions) { option in
                    Button {
                        path = withQueryParam(path, key: "o", value: option.id)
                    } label: {
                        Chip(text: option.label, active: currentSort == option.id)
                    }
                }
            }
            .padding(.horizontal, 1)
        }
    }

    @ViewBuilder
    private var paging: some View {
        HStack {
            Spacer()
            if list.loading {
                ProgressView().tint(Theme.muted)
            } else if list.current < list.totalPages {
                Button("加载第 \(list.current + 1) 页") {
                    Task {
                        await list.load(api: model.api,
                                        path: path,
                                        page: list.current + 1,
                                        reset: false)
                    }
                }
                .buttonStyle(GhostButtonStyle())
            } else {
                Text("已到最后一页")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted2)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private func reload(force: Bool) async {
        await list.load(api: model.api, path: path, page: 1, reset: true, force: force)
    }
}
