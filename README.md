# Pornhub Desktop

一个基于 **Tauri v2 + Rust** 的 Windows 桌面客户端。它不是网页套壳：页面内容、视频地址都由本地 Rust 服务自行解析，视频流经本机代理转发，界面完全自定义。

## 功能

- 首页推荐、分类浏览、热门 / 最新、搜索、分页
- 视频详情页 + 自研播放器（HLS.js）：画质切换、倍速、画中画、全屏、键盘快捷键
- 相关推荐、分类 / 标签跳转
- 观看历史与续播（仅保存在本机）
- 账号登录（账号密码 / 两步验证 / 浏览器 Cookie 导入），Cookie 持久化
- 本机代理支持（默认 `127.0.0.1:7897`），可在设置中修改或改为直连
- **整片预缓冲**：点开视频后后台把整部视频下载到本机磁盘缓存，拖动进度条几乎无需等待

## 预缓冲与缓存策略

- 打开视频后，后台以 4 路并发把该视频的所有分片下载到 `%APPDATA%\local.ph.desktop\media-cache`，直到视频结束或达到 6 GB 上限。
- 播放器本身也保留了较大的前向缓冲（最长 300 秒 / 512 MB）。
- 已下载的分片会直接由本地磁盘返回，因此回看、拖动、切换清晰度都很快。
- **退出视频时**（切换到其他页面或另一个视频）会自动停止下载并清空缓存。
- **下次启动应用时**也会清空上次残留的缓存，避免占用磁盘。
- 可在「设置 → 播放与缓存」中关闭预缓冲，改为按需缓冲。

## 构建

环境要求：

- Rust（GNU 工具链 `x86_64-pc-windows-gnu`）
- Node.js（仅用于 Tauri CLI）
- Windows 10/11 自带的 `curl.exe`（用于带正确 TLS 指纹地访问站点）
- WebView2 Runtime

```powershell
npm install
npx tauri build            # 生成 NSIS 安装包
npx tauri build --no-bundle  # 只生成 exe
```

产物：

- `src-tauri/target/release/ph-desktop.exe`
- `src-tauri/target/release/bundle/nsis/Pornhub Desktop_1.0.0_x64-setup.exe`

> 安装包会自动带上 `WebView2Loader.dll`，无需手动复制。

开发调试时可用示例程序验证后端链路：

```powershell
cargo run --release --manifest-path src-tauri/Cargo.toml --example selftest
```

## 数据位置

- 设置：`%APPDATA%\local.ph.desktop\settings.json`
- 登录 Cookie：`%APPDATA%\local.ph.desktop\cookies.json`
- 媒体缓存：`%APPDATA%\local.ph.desktop\media-cache`（退出视频或下次启动时清空）

## iOS 客户端

`ios/` 是对应的 **原生 iOS 版本**（SwiftUI + AVPlayer + WebKit），
功能与桌面端对齐：首页 / 分类 / 热门 / 最新 / 搜索 / 详情、画质与倍速、
观看历史与续播、账号登录与 Cookie 导入，以及基于本机分片缓存的「整片预缓冲」。

用 Mac 上的 Xcode 打开 `ios/PornhubMobile.xcodeproj` 即可（iOS 16+，
首次打开会自动拉取 SwiftSoup）。详细说明见 [`ios/README.md`](ios/README.md)。

## 说明

- 站点对 TLS / HTTP 指纹较敏感，因此所有站点请求通过系统 `curl.exe`（Schannel）发出；使用纯 Rust TLS 栈会被返回 403 / 410。
- HLS 签名地址有时效（约 2 小时），过期后可在视频页点击「刷新播放地址」。
- 本项目仅用于个人学习与本地使用，请遵守你所在地区的法律法规。
