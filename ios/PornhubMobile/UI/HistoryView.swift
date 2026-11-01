import SwiftUI

@MainActor
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        ScrollView {
            if entries.isEmpty {
                EmptyStateView(title: "还没有观看记录",
                               hint: "看过的视频会自动出现在这里，方便继续观看。")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近 \(entries.count) 条记录 · 仅保存在本机")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)

                    LazyVGrid(columns: GridLayout.columns, spacing: 16) {
                        ForEach(entries) { entry in
                            NavigationLink(value: Route.video(vkey: entry.vkey)) {
                                VideoCard(item: entry.asVideoItem,
                                          progress: entry.progressFraction,
                                          durationText: entry.duration)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.bg)
        .navigationTitle("观看历史")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !entries.isEmpty {
                    Button {
                        model.clearHistory()
                        reload()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: model.historyRevision) { _ in reload() }
    }

    private func reload() {
        entries = HistoryStore.all()
    }
}
