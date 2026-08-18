import WidgetKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LatestNewsEntry: TimelineEntry {
    let date: Date
    let snapshot: LatestNewsSnapshot
}

struct LatestNewsProvider: TimelineProvider {
    private let store = LatestNewsStore.shared

    func placeholder(in context: Context) -> LatestNewsEntry {
        LatestNewsEntry(
            date: Date(),
            snapshot: LatestNewsSnapshot(
                generatedAt: Date(),
                items: LatestNewsProvider.placeholderItems
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LatestNewsEntry) -> Void) {
        let snapshot = store.load() ?? LatestNewsSnapshot(
            generatedAt: Date(),
            items: LatestNewsProvider.placeholderItems
        )
        completion(LatestNewsEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LatestNewsEntry>) -> Void) {
        let snapshot = store.load() ?? LatestNewsSnapshot(
            generatedAt: Date(),
            items: LatestNewsProvider.placeholderItems
        )
        let entry = LatestNewsEntry(date: Date(), snapshot: snapshot)
        // Refresh periodically; the app triggers reloads on new data.
        let refresh = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private static let placeholderItems: [LatestNewsItem] = [
        LatestNewsItem(
            id: "placeholder-1",
            title: "Updated Fen Lite and now I can't play anything",
            source: "Addons4Kodi Community Subreddit",
            subtitle: "u/ExampleUser • 3 hours ago",
            publishedAt: Date(),
            deeplink: nil,
            imageURL: nil,
            imageData: nil
        ),
        LatestNewsItem(
            id: "placeholder-2",
            title: "Can I use this for multiple devices on a single purchase?",
            source: "Sideloaded",
            subtitle: "5 minutes ago",
            publishedAt: Date(),
            deeplink: nil,
            imageURL: nil,
            imageData: nil
        ),
        LatestNewsItem(
            id: "placeholder-3",
            title: "Downstream 102: Just Like Television",
            source: "Six Colors",
            subtitle: "Podcast highlight",
            publishedAt: Date(),
            deeplink: nil,
            imageURL: nil,
            imageData: nil
        )
    ]
}

struct LatestNewsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: LatestNewsProvider.Entry

    var body: some View {
        let base = content.widgetURL(entry.snapshot.items.first?.deeplink)
        if #available(iOS 17.0, *) {
            base
                .padding(16)
                .containerBackground(for: .widget) {
                    widgetBackground
                }
        } else {
            base
                .padding(16)
                .background(legacyBackground)
        }
    }

    private var header: some View {
        Text("Latest News")
            .font(.headline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func rowView(for item: LatestNewsItem, isFirst: Bool) -> some View {
        Group {
            if let url = item.deeplink {
                Link(destination: url) {
                    rowContent(for: item, isFirst: isFirst)
                }
            } else {
                rowContent(for: item, isFirst: isFirst)
            }
        }
    }

    private func rowContent(for item: LatestNewsItem, isFirst: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let image = image(for: item) {
                image
                    .resizable()
                    .scaledToFill()
                .frame(width: imageSize.width, height: imageSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                placeholder(for: item)
                    .frame(width: imageSize.width, height: imageSize.height)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(item.title)
                    .font(isFirst ? .headline : .subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
    }

    private var maxVisibleItems: Int {
        switch family {
        case .systemLarge: return 8
        case .systemExtraLarge: return 10
        default: return 4
        }
    }

    private var imageSize: CGSize {
        switch family {
        case .systemLarge, .systemExtraLarge:
            return CGSize(width: 54, height: 54)
        default:
            return CGSize(width: 48, height: 48)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(Array(entry.snapshot.items.prefix(maxVisibleItems).enumerated()), id: \.element.id) { index, item in
                rowView(for: item, isFirst: index == 0)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var widgetBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.thinMaterial)
    }

    private var legacyBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(legacyBackgroundColor)
    }

    private var legacyBackgroundColor: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemBackground)
        #elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.secondary.opacity(0.15)
        #endif
    }

    private func placeholder(for item: LatestNewsItem) -> some View {
        let baseColor = colorForID(item.id)
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(baseColor.opacity(0.7))
            Text(monoInitials(for: item))
                .font(.headline.weight(.semibold))
                .foregroundColor(.white.opacity(0.85))
        }
    }

    private func image(for item: LatestNewsItem) -> Image? {
        if let data = item.imageData {
            #if os(iOS)
            if let uiImage = UIImage(data: data) {
                return Image(uiImage: uiImage)
            }
            #endif
        }
        return nil
    }

    private func monoInitials(for item: LatestNewsItem) -> String {
        let tokens = item.source.split(separator: " ")
        if let first = tokens.first?.first {
            if let secondWord = tokens.dropFirst().first?.first {
                return String([first, secondWord]).uppercased()
            }
            return String(first).uppercased()
        }
        return "#"
    }

    private func colorForID(_ id: String) -> Color {
        var hasher = Hasher()
        hasher.combine(id)
        let hashValue = hasher.finalize()
        let normalized = abs(hashValue % 360)
        let hue = Double(normalized) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}

struct LatestNewsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LatestNewsWidget", provider: LatestNewsProvider()) { entry in
            LatestNewsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Latest News")
        .description("Shows the newest 20 items pulled from your RSS and Reddit feeds.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct LatestNewsWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        LatestNewsWidget()
    }
}
