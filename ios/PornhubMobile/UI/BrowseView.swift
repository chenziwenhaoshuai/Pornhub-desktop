import SwiftUI

/// “发现”页：热门 / 最新 / 评分等排序 + 搜索入口。
@MainActor
struct BrowseView: View {
    var onSearch: (String) -> Void = { _ in }

    @EnvironmentObject private var model: AppModel
    @StateObject private var list = ListModel()
    @State private var sort = "ht"
    @State private var searchText = ""

    private var path: String { "/video?o=" + sort }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(allSortOptions) { option in
                            Button {
                                sort = option.id
                            } label: {
                                Chip(text: option.label, active: sort == option.id)
                            }
                        }
                    }
                    .padding(.horizontal, 1)
                }

                if list.loading && list.items.isEmpty {
                    LoadingView()
                } else if let error = list.error, list.items.isEmpty {
                    ErrorStateView(message: error) {
                        Task { await reload(force: true) }
                    }
                } else if list.items.isEmpty {
                    EmptyStateView(title: "没有找到视频", hint: "下拉刷新，或换个排序方式。")
                } else {
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
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "搜索视频、演员、标签")
        .onSubmit(of: .search) { submitSearch() }
        .task(id: path) {
            await list.load(api: model.api, path: path, page: 1, reset: true)
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

    private func submitSearch() {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=#+")
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: allowed) ?? keyword
        onSearch("/video/search?search=" + encoded)
    }
}
