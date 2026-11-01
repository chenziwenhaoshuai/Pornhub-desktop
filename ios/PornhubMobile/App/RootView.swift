import SwiftUI

/// 全局导航路由。每个 Tab 一个 `NavigationStack`，都能推到视频详情或列表页。
enum Route: Hashable {
    case list(path: String, title: String)
    case video(vkey: String)
}

@MainActor
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case let .list(path, title):
            VideoListView(path: path, heading: title)
        case let .video(vkey):
            VideoDetailView(vkey: vkey)
        }
    }
}

@MainActor
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeTab(openHistory: { tab = 3 })
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(0)

            CategoriesTab()
                .tabItem { Label("分类", systemImage: "square.grid.2x2.fill") }
                .tag(1)

            BrowseTab()
                .tabItem { Label("发现", systemImage: "flame.fill") }
                .tag(2)

            HistoryTab()
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
                .tag(3)

            SettingsTab()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(Theme.accent)
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastBanner(message: toast)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast?.id)
    }
}

/* ------------------------------ 各个 Tab ------------------------------ */

@MainActor
private struct HomeTab: View {
    var openHistory: () -> Void
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(openHistory: openHistory)
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }
}

@MainActor
private struct CategoriesTab: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            CategoriesView()
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }
}

@MainActor
private struct BrowseTab: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            BrowseView { searchPath in
                path.append(Route.list(path: searchPath, title: "搜索结果"))
            }
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }
}

@MainActor
private struct HistoryTab: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            HistoryView()
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }
}

@MainActor
private struct SettingsTab: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            SettingsView()
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }
}
