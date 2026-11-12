import SwiftUI

@MainActor
final class ArtViewModel: ObservableObject {
    @Published var artwork: Artwork?
    @Published var image: UIImage?
    @Published var failed = false

    /// A painting from a widget tap, or today's painting when the app is opened by itself.
    func load(id: Int? = nil) async {
        failed = false
        do {
            if let id {
                guard id != artwork?.id else { return }
                let art = try await AICClient.artwork(id: id)
                let data = try await AICClient.imageData(for: art)
                show(art, data)
            } else {
                let (art, data) = try await AICClient.daily(day: DailyPick.day())
                show(art, data)
            }
        } catch {
            failed = true
        }
    }

    private func show(_ art: Artwork, _ data: Data) {
        artwork = art
        image = UIImage(data: data)
    }
}

/// The info view: the iPhone's version of the Mac card's drop-down.
struct ArtInfoView: View {
    @ObservedObject var model: ArtViewModel

    var body: some View {
        if let art = model.artwork {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let image = model.image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityLabel(art.thumbnail?.altText ?? art.title)
                            .padding(.bottom, 16)
                    }
                    label(Facts.make(art))
                    Link(destination: art.pageURL) {
                        Label("Open on artic.edu", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.top, 16)
                }
                .padding(16)
            }
        } else if model.failed {
            VStack(spacing: 12) {
                Text("Couldn't reach the museum").foregroundStyle(.secondary)
                Button("Try again") { Task { await model.load() } }
            }
        } else {
            ProgressView("Finding today's painting…")
        }
    }

    private func label(_ text: CardText) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(text.heading)\(Text(text.date.map { ", \($0)" } ?? "").foregroundStyle(.secondary))")
                .font(.title3.weight(.semibold))
            if let artist = text.artist {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            Divider().padding(.vertical, 12)
            if let blurb = text.blurb {
                Text(blurb)
                    .font(.body)
                    .padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(text.facts, id: \.self) { fact in
                    Text(fact)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

@main
struct ArtPhoneApp: App {
    @StateObject private var model = ArtViewModel()
    @State private var openedFromWidget = false

    var body: some Scene {
        WindowGroup {
            ArtInfoView(model: model)
                .onOpenURL { url in
                    // artwidget://art/<id>
                    guard url.host == "art", let id = Int(url.lastPathComponent) else { return }
                    openedFromWidget = true
                    Task { await model.load(id: id) }
                }
                .task {
                    // onOpenURL arrives first on a widget tap, so today's painting doesn't overwrite it.
                    if !openedFromWidget { await model.load() }
                }
        }
    }
}
