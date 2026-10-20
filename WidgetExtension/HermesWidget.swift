import AppKit
import SwiftUI
import WidgetKit

// A grid of recent chats (picture + name). The data comes from the app group the app keeps up to
// date (ShareHandoff / ShareSupport) — the widget can't reach the core. Tapping a chat opens it
// with `hermes://chat?id=<id>`.

struct WidgetChat: Identifiable, Sendable {
    let id: String
    let name: String
    let imageData: Data?
}

struct RecentChatsEntry: TimelineEntry, Sendable {
    let date: Date
    let chats: [WidgetChat]
}

/// Reads the recent chats and their pictures from the shared app group.
enum RecentChatsStore {
    nonisolated static func load() -> [WidgetChat] {
        guard let file = ShareHandoff.recentChatsFile,
              let data = try? Data(contentsOf: file),
              let chats = try? JSONDecoder().decode([ShareHandoff.Chat].self, from: data) else {
            return []
        }
        let avatars = ShareHandoff.avatarsFolder
        return chats.map { chat in
            let image = (chat.hasAvatar ? avatars?.appendingPathComponent("\(chat.id).png") : nil)
                .flatMap { try? Data(contentsOf: $0) }
            return WidgetChat(id: chat.id, name: chat.name, imageData: image)
        }
    }
}

struct Provider: TimelineProvider {
    nonisolated func placeholder(in context: Context) -> RecentChatsEntry {
        RecentChatsEntry(date: Date(), chats: (0..<12).map { WidgetChat(id: "\($0)", name: "", imageData: nil) })
    }

    nonisolated func getSnapshot(in context: Context, completion: @escaping (RecentChatsEntry) -> Void) {
        completion(RecentChatsEntry(date: Date(), chats: RecentChatsStore.load()))
    }

    nonisolated func getTimeline(in context: Context, completion: @escaping (Timeline<RecentChatsEntry>) -> Void) {
        let entry = RecentChatsEntry(date: Date(), chats: RecentChatsStore.load())
        // The app reloads the widget when the chats change; this is just a fallback refresh.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(1800))))
    }
}

struct HermesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentChatsEntry

    var body: some View {
        let (cols, rows) = grid
        GeometryReader { geo in
            let spacing: CGFloat = 8
            let nameHeight: CGFloat = 14
            let cellW = (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
            let cellH = (geo.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let avatar = max(20, min(cellW, cellH - nameHeight))
            let shown = Array(entry.chats.prefix(cols * rows))
            if shown.isEmpty {
                empty
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols), spacing: spacing) {
                    ForEach(shown) { chat in
                        cell(chat, size: avatar)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Hermes to see your chats")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ chat: WidgetChat, size: CGFloat) -> some View {
        Link(destination: url(for: chat.id)) {
            VStack(spacing: 2) {
                ZStack {
                    // Shows through a group composite's gaps as a 5% tint of the text color; a 1:1
                    // photo covers it.
                    Circle().fill(Color.primary.opacity(0.05))
                    Image(nsImage: RoundAvatar.image(chat.imageData.flatMap { NSImage(data: $0) }, name: chat.name, size: 120))
                        .resizable()
                        // Keep photos in full color when the widget is tinted, so they stay visible.
                        .widgetAccentedRenderingMode(.fullColor)
                }
                .frame(width: size, height: size)
                Text(chat.name)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func url(for id: String) -> URL {
        var components = URLComponents()
        components.scheme = ShareHandoff.urlScheme
        components.host = ShareHandoff.chatHost
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url ?? URL(string: "\(ShareHandoff.urlScheme)://\(ShareHandoff.chatHost)")!
    }

    /// How many chats to show, per widget size.
    private var grid: (columns: Int, rows: Int) {
        switch family {
        case .systemSmall: return (2, 2)
        case .systemMedium: return (4, 2)
        case .systemLarge: return (4, 4)
        case .systemExtraLarge: return (6, 3)
        default: return (2, 2)
        }
    }
}

struct HermesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecentChats", provider: Provider()) { entry in
            HermesWidgetView(entry: entry)
        }
        .configurationDisplayName("Recent Chats")
        .description("Your recent chats. Click one to open it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct HermesWidgetBundle: WidgetBundle {
    var body: some Widget {
        HermesWidget()
    }
}
