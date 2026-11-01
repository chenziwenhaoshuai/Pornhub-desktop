import SwiftUI
import UIKit

/* ------------------------------ 图片 ------------------------------ */

/// 带 Referer / Cookie 的缩略图。图片同样要经过站点校验，所以不能直接用 `AsyncImage`。
@MainActor
struct RemoteImage: View {
    let url: String

    @EnvironmentObject private var model: AppModel
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.panel2
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else if failed {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundColor(Theme.muted2)
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Theme.muted)
                }
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        image = nil
        failed = false
        guard !url.isEmpty else {
            failed = true
            return
        }
        if let cached = ImageLoader.shared.cached(url) {
            image = cached
            return
        }
        if let result = await ImageLoader.shared.image(for: url, http: model.api.http) {
            image = result
        } else {
            failed = true
        }
    }
}

/* ------------------------------ 基础控件 ------------------------------ */

@MainActor
struct Chip: View {
    let text: String
    var active: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundColor(active ? Theme.accent : Theme.text)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.14) : Theme.panel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(active ? Theme.accent.opacity(0.55) : Theme.line, lineWidth: 1)
            )
    }
}

@MainActor
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
            if let trailing = trailing, let action = action {
                Button(action: action) {
                    Text(trailing)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                }
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent)
            )
            .foregroundColor(Color(red: 0.08, green: 0.06, blue: 0.03))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.panel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            )
            .foregroundColor(Theme.text)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/* ------------------------------ 状态视图 ------------------------------ */

@MainActor
struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(Theme.muted)
            Text("加载失败")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.muted)
                .multilineTextAlignment(.center)
            if let retry = retry {
                Button("重试", action: retry)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 24)
    }
}

@MainActor
struct EmptyStateView: View {
    let title: String
    var hint: String = ""

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 28))
                .foregroundColor(Theme.muted2)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.text)
            if !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
    }
}

@MainActor
struct LoadingView: View {
    var text: String = "加载中…"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().tint(Theme.muted)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

@MainActor
struct ToastBanner: View {
    let message: ToastMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(tint)
                .font(.system(size: 14, weight: .semibold))
            Text(message.text)
                .font(.system(size: 13))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.panel3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 14, y: 6)
        .padding(.horizontal, 16)
    }

    private var icon: String {
        switch message.kind {
        case .good: return "checkmark.circle.fill"
        case .bad: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch message.kind {
        case .good: return Theme.accent2
        case .bad: return Theme.danger
        case .info: return Theme.muted
        }
    }
}

/* ------------------------------ 卡片 ------------------------------ */

@MainActor
struct VideoCard: View {
    let item: VideoItem
    var progress: Double = 0
    var durationText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(RemoteImage(url: item.thumb))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) { durationBadge }
                .overlay(alignment: .bottom) { progressBar }

            Text(item.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if !item.author.isEmpty { parts.append(item.author) }
        if !item.views.isEmpty { parts.append(item.views) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var durationBadge: some View {
        let text = durationText ?? item.duration
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(5)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if progress > 0.01 {
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.22))
                Rectangle()
                    .fill(Theme.accent)
                    .scaleEffect(x: min(1, max(0, progress)), y: 1, anchor: .leading)
            }
            .frame(height: 3)
        }
    }
}

@MainActor
struct CategoryCard: View {
    let item: CategoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay(RemoteImage(url: item.thumb))
                .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(item.count)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

/* ------------------------------ 流式布局（标签） ------------------------------ */

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                maxRowWidth = max(maxRowWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth - spacing)
        return CGSize(width: min(max(maxRowWidth, 0), maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/* ------------------------------ 网格 ------------------------------ */

enum GridLayout {
    static let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12, alignment: .top)]
}
