import AppIntents
import ImageIO
import SwiftUI
import WidgetKit

/// How far ← and → have moved from today's painting. Back to today at midnight.
enum Browse {
    private static let defaults = UserDefaults.standard

    static var offset: Int {
        defaults.integer(forKey: "browseDay") == DailyPick.day() ? defaults.integer(forKey: "browseOffset") : 0
    }

    static func move(by step: Int) {
        let next = offset + step
        defaults.set(DailyPick.day(), forKey: "browseDay")
        defaults.set(next, forKey: "browseOffset")
    }
}

/// ← and → on the widget. They walk the same day-by-day order, so ← is yesterday's painting.
struct BrowseIntent: AppIntent {
    static var title: LocalizedStringResource = "Browse paintings"
    static var isDiscoverable = false

    @Parameter(title: "Step") var step: Int

    init() {}
    init(step: Int) { self.step = step }

    func perform() async throws -> some IntentResult {
        Browse.move(by: step)
        return .result()
    }
}

/// The last painting shown, so the widget still has something if the API is down.
enum WidgetCache {
    private struct Saved: Codable {
        let day: Int
        let artwork: Artwork
    }

    private static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private static let recordURL = dir.appendingPathComponent("painting.json")
    private static let imageURL = dir.appendingPathComponent("painting.jpg")

    static func load() -> (day: Int, artwork: Artwork, image: Data)? {
        guard let record = try? Data(contentsOf: recordURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: record),
              let image = try? Data(contentsOf: imageURL) else { return nil }
        return (saved.day, saved.artwork, image)
    }

    static func save(day: Int, artwork: Artwork, image: Data) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? image.write(to: imageURL, options: .atomic)
        try? JSONEncoder().encode(Saved(day: day, artwork: artwork)).write(to: recordURL, options: .atomic)
    }
}

struct ArtEntry: TimelineEntry {
    let date: Date
    var artwork: Artwork?
    var image: UIImage?
    /// A tiny copy of the painting. Stretched behind it, this gives a soft colour wash.
    var backdrop: UIImage?
    /// False when this is an old painting because the fetch failed.
    var isCurrent = true

    /// Widgets refuse images much bigger than they are drawn, so the 843 px download is shrunk first.
    static func make(artwork: Artwork, data: Data, isCurrent: Bool) -> ArtEntry {
        ArtEntry(
            date: Date(),
            artwork: artwork,
            image: downsample(data, maxPixels: 800),
            backdrop: downsample(data, maxPixels: 24),
            isCurrent: isCurrent
        )
    }

    private static func downsample(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
    }
}

struct ArtProvider: TimelineProvider {
    func placeholder(in context: Context) -> ArtEntry {
        ArtEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ArtEntry) -> Void) {
        if context.isPreview, let saved = WidgetCache.load() {
            completion(.make(artwork: saved.artwork, data: saved.image, isCurrent: true))
        } else {
            Task { completion(await entry()) }
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ArtEntry>) -> Void) {
        Task {
            let entry = await entry()
            let midnight = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400 + 60)
            let retry = Date().addingTimeInterval(30 * 60)
            completion(Timeline(entries: [entry], policy: .after(entry.isCurrent ? midnight : retry)))
        }
    }

    /// The cached painting if it's the right day, otherwise a fresh one. On failure the old one stays up.
    private func entry() async -> ArtEntry {
        let day = DailyPick.day() + Browse.offset
        let saved = WidgetCache.load()
        if let saved, saved.day == day {
            return .make(artwork: saved.artwork, data: saved.image, isCurrent: true)
        }
        do {
            let (art, data) = try await AICClient.daily(day: day)
            WidgetCache.save(day: day, artwork: art, image: data)
            return .make(artwork: art, data: data, isCurrent: true)
        } catch {
            if let saved {
                return .make(artwork: saved.artwork, data: saved.image, isCurrent: false)
            }
            return ArtEntry(date: Date(), isCurrent: false)
        }
    }
}

struct ArtWidgetView: View {
    let entry: ArtEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .padding(14)
            .containerBackground(for: .widget) { backdrop }
            .widgetURL(entry.artwork.flatMap { URL(string: "artwidget://art/\($0.id)") })
    }

    @ViewBuilder private var content: some View {
        if let image = entry.image, let art = entry.artwork {
            if family == .systemMedium {
                // Wide strip: painting on the left, everything else in a column beside it.
                // The painting is sized from its own shape so the column gets all the leftover width.
                // 142 pt is the height inside the padding; 200 pt stops panoramas squeezing the text.
                HStack(spacing: 12) {
                    painting(image, art)
                        .frame(width: min(200, 142 * image.size.width / max(image.size.height, 1)))
                    VStack(alignment: .leading, spacing: 0) {
                        titles(art, titleLines: 3, artistLines: 2)
                        Spacer(minLength: 6)
                        // Pinned right so they stay put as the painting's width changes.
                        browseButtons
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 10) {
                    painting(image, art)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(alignment: .center, spacing: 8) {
                        titles(art, titleLines: 1, artistLines: 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        browseButtons
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.artframe").font(.title)
                Text(entry.isCurrent ? "Finding today's painting…" : "Couldn't reach the museum")
                    .font(.footnote)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func painting(_ image: UIImage, _ art: Artwork) -> some View {
        Image(uiImage: image)
            .resizable()
            .widgetAccentedRenderingMode(.fullColor)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(art.thumbnail?.altText ?? art.title)
    }

    private func titles(_ art: Artwork, titleLines: Int, artistLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(art.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(titleLines)
            // artist_display is "Name (Nationality, dates)" or "Name\nNationality, dates".
            // Just the name fits here; the info view has the rest.
            if let artist = art.artistDisplay?.components(separatedBy: "\n")[0].components(separatedBy: " (")[0] {
                Text(artist)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(artistLines)
            }
        }
        .foregroundStyle(.white)
    }

    private var browseButtons: some View {
        HStack(spacing: 8) {
            browseButton("arrow.backward", step: -1, label: "Previous painting")
            browseButton("arrow.forward", step: 1, label: "Next painting")
        }
    }

    private func browseButton(_ icon: String, step: Int, label: String) -> some View {
        Button(intent: BrowseIntent(step: step)) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                // Not Liquid Glass: glassEffect draws nothing inside a widget.
                .background(.white.opacity(0.2), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The painting's own colours, darkened enough for white text on top.
    @ViewBuilder private var backdrop: some View {
        if let backdrop = entry.backdrop {
            Image(uiImage: backdrop)
                .resizable()
                .scaledToFill()
                .overlay(Color.black.opacity(0.45))
        } else {
            Color(white: 0.15)
        }
    }
}

struct ArtWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ArtWidget", provider: ArtProvider()) { entry in
            ArtWidgetView(entry: entry)
        }
        .configurationDisplayName("Daily Painting")
        .description("A public-domain painting from the Art Institute of Chicago, new each day.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct ArtWidgets: WidgetBundle {
    var body: some Widget {
        ArtWidget()
    }
}
