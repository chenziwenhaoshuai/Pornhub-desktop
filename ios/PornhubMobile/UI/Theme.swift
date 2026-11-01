import SwiftUI

/// 与桌面端 `dist/styles.css` 一致的配色。
enum Theme {
    static let bg = Color(red: 0.031, green: 0.031, blue: 0.043)        // #08080B
    static let bgSoft = Color(red: 0.051, green: 0.051, blue: 0.070)    // #0D0D12
    static let panel = Color(red: 0.071, green: 0.071, blue: 0.094)     // #121218
    static let panel2 = Color(red: 0.090, green: 0.090, blue: 0.122)    // #17171F
    static let panel3 = Color(red: 0.118, green: 0.118, blue: 0.157)    // #1E1E28
    static let line = Color(red: 0.149, green: 0.149, blue: 0.184)      // #26262F
    static let text = Color(red: 0.953, green: 0.953, blue: 0.965)      // #F3F3F6
    static let muted = Color(red: 0.604, green: 0.604, blue: 0.671)     // #9A9AAB
    static let muted2 = Color(red: 0.435, green: 0.435, blue: 0.494)    // #6F6F7E
    static let accent = Color(red: 1.0, green: 0.565, blue: 0.0)        // #FF9000
    static let accent2 = Color(red: 1.0, green: 0.702, blue: 0.251)     // #FFB340
    static let danger = Color(red: 1.0, green: 0.302, blue: 0.369)      // #FF4D5E

    static let corner: CGFloat = 12
}

extension View {
    /// 统一的卡片背景（面板色 + 细描边）。
    func panelBackground(corner: CGFloat = Theme.corner) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
    }
}
