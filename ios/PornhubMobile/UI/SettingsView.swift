import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var domain = ""
    @State private var useProxy = true
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var playCache = true
    @State private var prefetch = true

    @State private var testing = false
    @State private var testMessage: String?
    @State private var showLogin = false
    @State private var mediaBytes = 0
    @State private var historyCount = 0
    @State private var synced = false

    var body: some View {
        Form {
            networkSection
            playbackSection
            accountSection
            dataSection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.accent)
        .onAppear {
            if !synced {
                synced = true
                syncFromModel()
            }
            refreshStats()
        }
        .onChange(of: model.settings.domain) { _ in
            syncFromModel()
            refreshStats()
        }
        .sheet(isPresented: $showLogin) {
            LoginView().environmentObject(model)
        }
    }

    /* ------------------------------ 网络 ------------------------------ */

    private var networkSection: some View {
        Section {
            Group {
                TextField("站点域名", text: $domain)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Toggle("使用代理（实验性）", isOn: $useProxy)

                if useProxy {
                    TextField("代理地址", text: $proxyHost)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("端口", text: $proxyPort)
                        .keyboardType(.numberPad)
                }

                HStack(spacing: 10) {
                    Button("保存并应用") { apply() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button(testing ? "测试中…" : "测试连接") { test() }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(testing)
                    Spacer(minLength: 0)
                }

                if let testMessage = testMessage {
                    Text(testMessage)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listRowBackground(Theme.panel)
        } header: {
            Text("网络与代理")
        } footer: {
            Text("默认 https://cn.pornhub.com。iOS 不允许 App 强制系统代理，更推荐使用系统级 VPN / Clash 等工具；这里的设置只影响应用自身的请求。")
        }
    }

    /* ------------------------------ 播放 ------------------------------ */

    private var playbackSection: some View {
        Section {
            Group {
                Toggle("整片预缓冲（缓存加速）", isOn: $playCache)
                if playCache {
                    Toggle("点开视频后下载整片", isOn: $prefetch)
                }
                HStack {
                    Text("视频缓存")
                    Spacer()
                    Text(Format.bytes(mediaBytes))
                        .foregroundColor(Theme.muted)
                    Button("清除") {
                        model.clearMediaCache()
                        mediaBytes = 0
                    }
                    .foregroundColor(Theme.accent)
                }
            }
            .listRowBackground(Theme.panel)
        } header: {
            Text("播放与缓存")
        } footer: {
            Text("开启后视频通过本地分片缓存播放，同时后台尽可能把整部视频下载到本机，拖动进度条几乎无需等待。离开视频页或下次启动会自动清理。关闭则直接播放上游地址：最稳，但拖动较慢。")
        }
    }

    /* ------------------------------ 账号 ------------------------------ */

    private var accountSection: some View {
        Section {
            Group {
                if model.account.loggedIn {
                    HStack(spacing: 10) {
                        Text(String(model.account.username.prefix(1)).uppercased())
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Theme.accent)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.accent.opacity(0.16)))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.account.username.isEmpty ? "已登录" : model.account.username)
                                .font(.system(size: 14, weight: .medium))
                            Text("Cookie 已保存在本机")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.muted)
                        }
                        Spacer(minLength: 0)
                    }

                    Button("刷新登录状态") {
                        Task {
                            await model.refreshAccount()
                            if model.account.loggedIn {
                                model.showToast("登录状态正常", kind: .good)
                            } else {
                                model.showToast("登录状态已过期，请重新登录", kind: .bad)
                            }
                        }
                    }
                    .foregroundColor(Theme.accent)

                    Button("退出登录") {
                        model.logout()
                    }
                    .foregroundColor(Theme.danger)
                } else {
                    Button("登录账号") {
                        showLogin = true
                    }
                    .foregroundColor(Theme.accent)

                    Text("登录后可同步收藏、订阅与个性化首页推荐。密码只用于向站点发起登录，不会保存在本机。")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listRowBackground(Theme.panel)
        } header: {
            Text("账号")
        }
    }

    /* ------------------------------ 本地数据 ------------------------------ */

    private var dataSection: some View {
        Section {
            Group {
                HStack {
                    Text("观看历史")
                    Spacer()
                    Text("\(historyCount) 条")
                        .foregroundColor(Theme.muted)
                }
                Button("清除页面缓存") {
                    model.clearPageCache()
                }
                .foregroundColor(Theme.accent)
                Button("清空观看历史") {
                    model.clearHistory()
                    historyCount = 0
                }
                .foregroundColor(Theme.danger)
            }
            .listRowBackground(Theme.panel)
        } header: {
            Text("本地数据")
        } footer: {
            Text("所有数据仅保存在本机，不会上传到任何第三方服务器。")
        }
    }

    /* ------------------------------ 关于 ------------------------------ */

    private var aboutSection: some View {
        Section {
            Group {
                HStack {
                    Text("应用")
                    Spacer()
                    Text("Pornhub Mobile 1.0.0")
                        .foregroundColor(Theme.muted)
                }
                HStack {
                    Text("架构")
                    Spacer()
                    Text("SwiftUI + AVPlayer")
                        .foregroundColor(Theme.muted)
                }
                HStack {
                    Text("视频地址解析")
                    Spacer()
                    Text("本机解析，不经过第三方")
                        .foregroundColor(Theme.muted)
                }
            }
            .listRowBackground(Theme.panel)

            Text("本应用不是网页套壳：页面内容与播放地址均由本机解析，视频分片缓存也只存在你的手机上。请遵守所在地区法律法规，仅用于个人学习与娱乐。")
                .font(.system(size: 11))
                .foregroundColor(Theme.muted2)
                .listRowBackground(Theme.panel)
        } header: {
            Text("关于")
        }
    }

    /* ------------------------------ 动作 ------------------------------ */

    private func buildSettings() -> AppSettings {
        var next = model.settings
        next.domain = domain
        next.proxy.enabled = useProxy
        next.proxy.host = proxyHost.isEmpty ? "127.0.0.1" : proxyHost
        next.proxy.port = Int(proxyPort) ?? 7897
        next.playCache = playCache
        next.prefetch = prefetch
        return next
    }

    private func apply() {
        model.save(settings: buildSettings())
        syncFromModel()
    }

    private func test() {
        testing = true
        testMessage = nil
        let next = buildSettings()
        model.save(settings: next, notify: false)
        syncFromModel()

        Task {
            let result = await model.testConnection()
            testing = false
            let text = "\(result.ok ? "连接正常" : "连接失败") · \(result.ms)ms · \(result.message)"
            testMessage = text
            model.showToast(text, kind: result.ok ? .good : .bad)
        }
    }

    private func syncFromModel() {
        let settings = model.settings
        domain = settings.domain
        useProxy = settings.proxy.enabled
        proxyHost = settings.proxy.host
        proxyPort = String(settings.proxy.port)
        playCache = settings.playCache
        prefetch = settings.prefetch
    }

    private func refreshStats() {
        mediaBytes = model.mediaCacheBytes
        historyCount = HistoryStore.all().count
    }
}
