import SwiftUI
import WebKit

/// 内嵌站点登录页。登录（含人机验证 / 两步验证）完成后把 Cookie 同步给应用。
@MainActor
struct WebLoginView: View {
    let domain: String
    var onResult: (Bool) -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var checking = false

    var body: some View {
        NavigationStack {
            LoginWebView(url: URL(string: domain + "/login")) {
                // 每次页面加载完都顺手同步一次 Cookie。
                CookieStore.importWebKitCookies()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("站点登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onResult(false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(checking ? "检查中…" : "完成") {
                        finish()
                    }
                    .disabled(checking)
                }
            }
        }
    }

    private func finish() {
        checking = true
        CookieStore.importWebKitCookies { _ in
            Task { @MainActor in
                await model.refreshAccount()
                checking = false
                if model.account.loggedIn {
                    let name = model.account.username.isEmpty ? "账号" : model.account.username
                    model.showToast("已登录：\(name)", kind: .good)
                    onResult(true)
                    dismiss()
                } else {
                    model.showToast("还没有检测到登录状态，请先在网页中完成登录", kind: .bad)
                }
            }
        }
    }
}

@MainActor
struct LoginWebView: UIViewRepresentable {
    let url: URL?
    var onNavigate: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNavigate: onNavigate)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = nil
        if let url = url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onNavigate: () -> Void

        init(onNavigate: @escaping () -> Void) {
            self.onNavigate = onNavigate
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigate()
        }
    }
}
