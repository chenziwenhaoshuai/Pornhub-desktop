import SwiftUI

@MainActor
struct CategoriesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var items: [CategoryItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            if loading && items.isEmpty {
                LoadingView(text: "正在读取分类…")
            } else if let error = error, items.isEmpty {
                ErrorStateView(message: error) {
                    Task { await load(force: true) }
                }
            } else if items.isEmpty {
                EmptyStateView(title: "没有读取到分类", hint: "站点可能临时限制了访问，稍后再试。")
            } else {
                LazyVGrid(columns: GridLayout.columns, spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink(value: Route.list(path: Parser.relativePath(item.href, domain: model.settings.domain),
                                                         title: item.name)) {
                            CategoryCard(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.bg)
        .navigationTitle("全部分类")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await load(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .refreshable { await load(force: true) }
        .task(id: model.settings.domain) {
            if !loaded || items.isEmpty {
                loaded = true
                await load(force: false)
            }
        }
    }

    private func load(force: Bool) async {
        loading = true
        if items.isEmpty { error = nil }
        do {
            items = try await model.api.categories(force: force)
            error = nil
        } catch let err {
            if items.isEmpty {
                self.error = (err as? AppError)?.message ?? err.localizedDescription
            }
        }
        loading = false
    }
}
