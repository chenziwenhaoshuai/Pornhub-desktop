# Pornhub Mobile（iOS）

桌面端 **Pornhub Desktop**（`src-tauri/` + `dist/`）的 iOS 原生移植版。
用 **SwiftUI + AVPlayer + WebKit** 重写，页面与播放地址仍由本机解析，
不依赖任何第三方中转服务。

> 这个工程只在你自己的 iPhone / iPad 上侧载使用。成人内容应用无法通过
> App Store 审核，本工程也没有为此做任何规避设计。

## 环境要求

| 项目 | 要求 |
|---|---|
| Xcode | 15 或 16 及以上（推荐 16+） |
| iOS | 16.0 及以上 |
| 依赖 | [SwiftSoup](https://github.com/scinfu/SwiftSoup)（SPM 自动拉取，仅用于 HTML 解析） |
| 账号 | 一个 Apple ID（免费账号即可，签名有效期 7 天；付费开发者账号 1 年） |

## 编译运行

1. 在 Mac 上用 Xcode 打开 `ios/PornhubMobile.xcodeproj`。
2. 首次打开会提示解析 Swift Package（SwiftSoup），点 **Resolve Packages** / 等进度条走完。
   > 需要联网。如果拿不到依赖，删除 `PornhubMobile.xcodeproj`，安装 XcodeGen 后执行
   > `cd ios && xcodegen generate` 重新生成工程。
3. 选中 `PornhubMobile` target → **Signing & Capabilities** → 勾选
   *Automatically manage signing* → 选择你自己的 Team。
   如果 `local.ph.mobile` 这个 Bundle ID 被占用，改成 `com.你的名字.pornhubmobile`。
4. 顶部设备选择你的 iPhone（首次需要在手机上「设置 → 通用 → VPN与设备管理」信任开发者证书），
   或者选一个 iPhone 模拟器先跑起来。
5. `Cmd + R` 运行。

真机调试如果提示 "Untrusted Developer"，去手机的设备管理里信任一次即可。

## 功能对照

| 桌面端 | iOS 端 | 说明 |
|---|---|---|
| 首页推荐 / 分类 / 热门 / 最新 / 搜索 / 分页 | ✅ | `首页` / `分类` / `发现` 三个 Tab |
| 视频详情 + 相关推荐 + 分类标签 | ✅ | 相关视频可继续点进去 |
| 画质切换、倍速、续播、全屏 | ✅ | 播放器用系统 `AVPlayerViewController`，额外提供画质/倍速/从头播放 |
| 画中画（PiP）、AirPlay | ✅ | 系统播放器自带（需要在后台播放音频权限，已配置） |
| 观看历史 / 续播进度 | ✅ | 仅保存在本机 `UserDefaults` |
| 账号登录（账号密码 + 两步验证） | ✅ | 与桌面端一致，走 `/front/authenticate` |
| 浏览器 Cookie 导入 | ✅ | 粘贴 `Cookie:` 请求头 |
| **网页登录** | ✅ 新增 | 用内嵌 `WKWebView` 登录，人机验证/两步验证交给网页自己处理，完成后自动同步 Cookie —— iOS 上最稳的方式 |
| 本机代理（127.0.0.1:7897） | ⚠️ 有限支持 | iOS 不允许 App 强制系统代理；设置里的代理只对应用内请求生效（`connectionProxyDictionary`）。**推荐直接用系统级 VPN / Clash** |
| **整片预缓冲** | ✅ | 通过 `AVAssetResourceLoader` + 本地分片缓存实现：播放的同时后台以 4 路并发下载整片，拖动进度条直接命中磁盘；失败会自动回退直连播放 |
| 退出视频清空缓存 | ✅ | 离开视频页 / 打开下一个视频 / 启动 App 时清空 |
| 打开官网、测试连接 | ✅ | 设置页 |

## 与桌面端的关键实现差异

- **请求层**：桌面端调用系统 `curl.exe`（Schannel）绕开站点对 TLS 指纹的拦截；
  iOS 无法调用外部进程，改用系统 `URLSession`（Apple 网络栈，指纹接近 Safari）。
  万一仍然被拒绝（403 / 410），会自动用 `WKWebView` 真正加载一次页面并取回 DOM
  （`Core/WebFetcher.swift`），保证页面能读到。
- **Cookie**：不再自己实现 CookieJar，直接用 `HTTPCookieStorage`，
  这样 URLSession、网页登录、Cookie 导入三处能共用同一份数据。
- **媒体代理**：桌面端跑了一个 `127.0.0.1` 的 axum 服务来转发视频分片；
  iOS 上不需要 HTTP 服务，改成 `AVAssetResourceLoader` 拦截分片请求，
  先查磁盘缓存、miss 再回源，并把拿到分片写回缓存。
- **解析器**：`Core/Parser.swift` 是 `parse.rs` 的逐条翻译（SwiftSoup ≈ scraper）。
- **修了一个桌面端的小 bug**：分类/标签的链接是绝对地址，桌面端 `url_for`
  只接受 `/` 开头的路径，点分类会报「非法的页面路径」。iOS 端会先转成相对路径。

## 目录结构

```
ios/
├── PornhubMobile.xcodeproj/     # 直接用 Xcode 打开
├── project.yml                  # XcodeGen 备用工程描述
├── tools/
│   └── gen-project.mjs          # 重新生成 pbxproj（新增源文件后跑一次）
└── PornhubMobile/
    ├── App/                     # 入口、全局状态、Tab 导航
    ├── Core/                    # 网络、Cookie、HTML 解析、缓存、预缓冲
    └── UI/                      # 各个页面与组件
```

新增 Swift 文件后，如果不想手动拖进 Xcode：

```bash
node tools/gen-project.mjs
```

（会覆盖 `project.pbxproj`，Xcode 里之前手动加的设置需要重新加。）

## 数据位置

- 设置：`<App 沙盒>/Library/Application Support/PornhubMobile/settings.json`
- 视频缓存：`<App 沙盒>/Library/Application Support/PornhubMobile/media-cache/`
- 观看历史 / 续播进度：`UserDefaults`
- 登录 Cookie：`HTTPCookieStorage`（系统管理）

## 已知限制

- iOS 上无法设置「只对本 App 生效」的 HTTP 代理，必须依赖系统 VPN / Clash 之类的工具。
- 站点的 HLS 签名约 2 小时过期，过期后点「刷新播放地址」。
- 预缓冲是「播放时顺带缓存」，不是离线下载；离开视频页会清空（与桌面端一致）。
- 首次运行会触发一次 SwiftSoup 的 SPM 下载。
- 免费 Apple ID 签名 7 天过期，需要重新连 Mac 运行一次。

## 免责声明

本项目仅用于个人学习与本地使用，不提供、不托管任何内容，
所有页面与视频均来自你配置的站点。请遵守你所在地区的法律法规，并确认你已成年。
