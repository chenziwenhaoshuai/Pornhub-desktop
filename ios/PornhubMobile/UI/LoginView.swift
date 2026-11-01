import SwiftUI

@MainActor
struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var mode = 0
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var challenge: TwoFactorChallenge?
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var cookieText = ""
    @State private var showWeb = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("登录方式", selection: $mode) {
                        Text("账号密码").tag(0)
                        Text("网页登录").tag(1)
                        Text("Cookie").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Theme.panel)
                }

                if mode == 0 { credentialSection }
                if mode == 1 { webSection }
                if mode == 2 { cookieSection }
                if let errorMessage = errorMessage { errorSection(errorMessage) }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("登录账号")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Theme.accent)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showWeb) {
                WebLoginView(domain: model.settings.domain) { ok in
                    if ok { dismiss() }
                }
                .environmentObject(model)
            }
        }
    }

    /* ------------------------------ 账号密码 ------------------------------ */

    private var credentialSection: some View {
        Section {
            Group {
                TextField("邮箱 / 用户名", text: $email)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                SecureField("密码", text: $password)
                    .textContentType(.password)

                if challenge != nil {
                    TextField("两步验证码", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                }

                Button(busy ? "请稍候…" : (challenge == nil ? "登录" : "验证并登录")) {
                    submit()
                }
                .disabled(busy || email.isEmpty || password.isEmpty)
                .foregroundColor(Theme.accent)
            }
            .listRowBackground(Theme.panel)
        } footer: {
            Text("密码仅用于向站点提交登录请求，不会保存在本机；登录成功后只保存站点 Cookie。")
        }
    }

    /* ------------------------------ 网页登录 ------------------------------ */

    private var webSection: some View {
        Section {
            Group {
                Button("打开站点登录页") {
                    showWeb = true
                }
                .foregroundColor(Theme.accent)

                Text("在网页里完成账号密码、两步验证或人机验证。登录成功后回到这里点“完成”，应用会自动同步 Cookie。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(Theme.panel)
        } header: {
            Text("网页登录")
        } footer: {
            Text("这是最稳的方式：站点的人机验证、两步验证都由网页自己处理，应用只接管登录后的 Cookie。")
        }
    }

    /* ------------------------------ Cookie ------------------------------ */

    private var cookieSection: some View {
        Section {
            Group {
                TextEditor(text: $cookieText)
                    .frame(minHeight: 120)
                    .font(.system(size: 12, design: .monospaced))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .scrollContentBackground(.hidden)
                    .background(Theme.panel2)

                Button(busy ? "导入中…" : "导入 Cookie") {
                    importCookie()
                }
                .disabled(busy || cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .foregroundColor(Theme.accent)
            }
            .listRowBackground(Theme.panel)
        } header: {
            Text("粘贴浏览器 Cookie")
        } footer: {
            Text("在浏览器登录站点后，从开发者工具复制完整的 Cookie 请求头（形如 a=1; b=2; …）粘贴到上面。")
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Theme.panel)
        }
    }

    /* ------------------------------ 动作 ------------------------------ */

    @MainActor
    private func submit() {
        busy = true
        errorMessage = nil
        let pending = challenge

        Task {
            do {
                let result: LoginResult
                if let pending = pending {
                    result = try await model.api.login2FA(challenge: pending, code: code)
                } else {
                    result = try await model.api.login(email: email, password: password)
                }
                busy = false
                handle(result)
            } catch let err {
                errorMessage = (err as? AppError)?.message ?? err.localizedDescription
                busy = false
            }
        }
    }

    @MainActor
    private func importCookie() {
        busy = true
        errorMessage = nil

        Task {
            do {
                let account = try await model.api.importCookies(cookieText)
                busy = false
                model.applyAccount(account)
                model.showToast("Cookie 已导入", kind: .good)
                dismiss()
            } catch let err {
                errorMessage = (err as? AppError)?.message ?? err.localizedDescription
                busy = false
            }
        }
    }

    @MainActor
    private func handle(_ result: LoginResult) {
        switch result {
        case .ok(let account):
            model.applyAccount(account)
            let name = account.username.isEmpty ? "账号" : account.username
            model.showToast("已登录：\(name)", kind: .good)
            dismiss()
        case .twoFactor(let challenge):
            self.challenge = challenge
            self.code = ""
            model.showToast("请输入两步验证码", kind: .info)
        }
    }
}
