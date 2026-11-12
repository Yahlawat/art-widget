import SwiftUI

struct CardActions {
    var resetPosition: () -> Void = {}
    var quit: () -> Void = {}
}

private struct SizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Clear Liquid Glass card, so the wallpaper shows through like macOS 26's own desktop widgets. Follows light/dark mode.
/// Every size is a base value times `scale`, so resizing zooms the whole card evenly.
struct ArtCardView: View {
    /// Transparent margin around the card so the glass edge and shadow aren't clipped by the window.
    static let inset: CGFloat = 16
    static let scaleRange: ClosedRange<Double> = 0.6...2.0

    @ObservedObject var store: ArtStore
    var actions = CardActions()
    var rendersSnapshot = false
    var onSize: (CGSize) -> Void = { _ in }

    @State private var hovering = false
    /// Painting only by default; the info drops down below it. Remembered across launches.
    @AppStorage("showInfo") private var showInfo = false
    /// 1.0 is a 340 pt wide card. Set by dragging the corner handle. Remembered across launches.
    @AppStorage("scale") private var scale = 1.0
    @State private var resizeStart: (scale: Double, width: CGFloat)?

    private var s: CGFloat { CGFloat(scale) }
    private var width: CGFloat { 340 * s }
    /// Apple's desktop widgets: about 22 pt corners and 16 pt content margins.
    private var cornerRadius: CGFloat { 22 * s }
    /// Inner padding. The painting's corners are concentric with the card's.
    private var pad: CGFloat { 16 * s }
    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        card
            .padding(Self.inset)
            .fixedSize()
            .background(GeometryReader { Color.clear.preference(key: SizeKey.self, value: $0.size) })
            .onPreferenceChange(SizeKey.self) { onSize($0) }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            painting
            if showInfo, let art = store.artwork {
                label(Facts.make(art))
            }
        }
        .frame(width: cardWidth)
    }

    @ViewBuilder private var surface: some View {
        if rendersSnapshot {
            // SwiftUI's offscreen renderer cannot composite Liquid Glass.
            cardContent.background(cardShape.fill(Color(red: 0.13, green: 0.16, blue: 0.22)))
                .environment(\.colorScheme, .dark)
        } else {
            cardContent.background(cardShape.fill(.white.opacity(0.10)))
                .glassEffect(.clear, in: cardShape)
        }
    }

    private var card: some View {
        surface
        .overlay(cardShape.strokeBorder(.white.opacity(0.28), lineWidth: 1))
        .overlay(alignment: .topTrailing) { navButtons }
        .overlay(alignment: .topLeading) { websiteButton }
        .overlay(alignment: .bottomTrailing) { resizeHandle }
        .gesture(WindowDragGesture())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Next artwork") { Task { await store.next() } }
            Button("Previous artwork") { Task { await store.back() } }
                .disabled(!store.canGoBack)
            Button(showInfo ? "Hide info" : "Show info") { showInfo.toggle() }
            if let art = store.artwork {
                Button("Open on artic.edu") { NSWorkspace.shared.open(art.pageURL) }
            }
            Divider()
            Button("Reset size") { scale = 1 }
            Button("Reset position") { actions.resetPosition() }
            Button("Quit Art Widget") { actions.quit() }
        }
    }

    /// Full width when the info is open; otherwise the glass hugs the painting.
    private var cardWidth: CGFloat {
        guard !showInfo, let image = store.image else { return width }
        return fittedSize(image).width + 2 * pad
    }

    /// The painting scaled to fit inside the card's image area (max 300 pt tall at scale 1).
    private func fittedSize(_ image: NSImage) -> CGSize {
        let maxW = width - 2 * pad, maxH = 300 * s
        let aspect = image.size.width / max(image.size.height, 1)
        return aspect > maxW / maxH
            ? CGSize(width: maxW, height: maxW / aspect)
            : CGSize(width: maxH * aspect, height: maxH)
    }

    @ViewBuilder private var painting: some View {
        if let image = store.image, let art = store.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius - pad, style: .continuous))
                .frame(width: fittedSize(image).width, height: fittedSize(image).height)
                .accessibilityLabel(art.thumbnail?.altText ?? art.title)
                .overlay(alignment: .bottom) { infoButton }
                .frame(maxWidth: .infinity)
                .padding([.top, .horizontal], pad)
                .padding(.bottom, showInfo ? 0 : pad)
        } else {
            VStack(spacing: 8 * s) {
                ProgressView().controlSize(.small)
                Text("Finding today's painting…")
                    .font(.system(size: 12 * s))
                    .foregroundStyle(.secondary)
            }
            .frame(width: width, height: 180 * s)
        }
    }

    private func label(_ text: CardText) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(text.heading)\(Text(text.date.map { ", \($0)" } ?? "").foregroundStyle(.secondary))")
                .font(.system(size: 15 * s, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let artist = text.artist {
                Text(artist)
                    .font(.system(size: 12 * s))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2 * s)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle().fill(.separator).frame(height: 0.5).padding(.vertical, 10 * s)

            if let blurb = text.blurb {
                Text(blurb)
                    .font(.system(size: 12 * s))
                    .foregroundStyle(.primary)
                    .lineSpacing(1.5 * s)
                    .lineLimit(9)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8 * s)
            }
            VStack(alignment: .leading, spacing: 3 * s) {
                ForEach(text.facts, id: \.self) { fact in
                    Text(fact)
                        .font(.system(size: 11 * s))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, pad + 4 * s)
        .padding(.top, 12 * s)
        .padding(.bottom, 16 * s)
    }

    /// Chevron on the painting's bottom edge that drops the info down (or folds it back up).
    private var infoButton: some View {
        Button {
            showInfo.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(showInfo ? 180 : 0))
                .frame(width: 26, height: 26)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .help(showInfo ? "Hide info" : "Show info")
        .padding(8)
        .opacity(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// Opens the artwork's page on artic.edu. Its own button so clicking the painting does nothing.
    @ViewBuilder private var websiteButton: some View {
        if let art = store.artwork {
            Button {
                NSWorkspace.shared.open(art.pageURL)
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Open on artic.edu")
            .padding(pad + 6)
            .opacity(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }

    /// ← previous painting (only when there is one) and → next painting.
    private var navButtons: some View {
        HStack(spacing: 6) {
            if store.canGoBack {
                Button {
                    Task { await store.back() }
                } label: {
                    Image(systemName: "arrow.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Previous artwork")
            }
            Button {
                Task { await store.next() }
            } label: {
                Group {
                    if store.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.forward")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .frame(width: 26, height: 26)
                .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Next artwork")
        }
        .padding(pad + 6)
        .opacity(hovering || store.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    /// Bottom-right grip. Dragging it right or left zooms the whole card; the top-left corner stays put.
    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 32, height: 32)
            .glassEffect(.regular.interactive(), in: Circle())
            .padding(max(6, cornerRadius * 0.3))
            .contentShape(Rectangle())   // the padding around the grip is grabbable too
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .help("Drag to resize")
            .highPriorityGesture(
                // Window coordinates are stable here because the window grows from its top-left.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = resizeStart ?? (scale, cardWidth)
                        resizeStart = start
                        let target = start.scale * Double((start.width + drag.translation.width) / start.width)
                        scale = min(max(target, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
                    }
                    .onEnded { _ in resizeStart = nil }
            )
            .opacity(hovering || resizeStart != nil ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
