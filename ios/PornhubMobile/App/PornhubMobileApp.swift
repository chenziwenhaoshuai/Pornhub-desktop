import SwiftUI

@main
@MainActor
struct PornhubMobileApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { model.start() }
        }
    }
}
