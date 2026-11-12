import AppKit

/// The paintings you've seen, newest last, with one picked per day.
/// Back and Next move through the history; Next fetches a new painting once you're at the newest.
@MainActor
final class ArtStore: ObservableObject {
    @Published private(set) var artwork: Artwork?
    @Published private(set) var image: NSImage?
    @Published private(set) var isLoading = false

    /// History length. Older paintings and their cached images are dropped.
    static let historyLimit = 100

    private struct State: Codable {
        var date: String
        var history: [Artwork]
        var index: Int
        var shown: [Int]

        // Earlier versions kept only one painting, in `artwork`, with its image in current.jpg.
        enum CodingKeys: String, CodingKey { case date, history, index, shown, artwork }

        init(date: String = "", history: [Artwork] = [], index: Int = 0, shown: [Int] = []) {
            self.date = date
            self.history = history
            self.index = index
            self.shown = shown
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
            shown = try c.decodeIfPresent([Int].self, forKey: .shown) ?? []
            if let history = try c.decodeIfPresent([Artwork].self, forKey: .history) {
                self.history = history
                index = try c.decodeIfPresent(Int.self, forKey: .index) ?? history.count - 1
            } else {
                history = (try c.decodeIfPresent(Artwork.self, forKey: .artwork)).map { [$0] } ?? []
                index = history.count - 1
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date)
            try c.encode(history, forKey: .history)
            try c.encode(index, forKey: .index)
            try c.encode(shown, forKey: .shown)
        }

        var current: Artwork? { history.indices.contains(index) ? history[index] : nil }
    }

    private var state: State
    private let stateURL: URL
    private let imagesDir: URL

    var canGoBack: Bool { state.index > 0 }

    init() {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["ART_WIDGET_DIR"] {
            dir = URL(fileURLWithPath: override)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ArtWidget")
        }
        stateURL = dir.appendingPathComponent("state.json")
        imagesDir = dir.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let data = try? Data(contentsOf: stateURL), let saved = try? decoder.decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
        }

        // Move an old single-painting cache into the per-painting folder.
        let legacy = dir.appendingPathComponent("current.jpg")
        if let art = state.current, FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: imageURL(for: art))
            save()
        }

        artwork = state.current
        image = artwork.flatMap { NSImage(contentsOf: imageURL(for: $0)) }
    }

    static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// New painting if the day changed or nothing is cached. Safe to call often.
    func refreshIfNeeded() async {
        if state.date != Self.today() || artwork == nil {
            await fetchNew(daily: true)
        } else if image == nil {
            await show(state.index)
        }
    }

    /// Forward through the history if you went back, otherwise a new painting.
    func next() async {
        if state.index < state.history.count - 1 {
            await show(state.index + 1)
        } else {
            await fetchNew(daily: false)
        }
    }

    func back() async {
        guard canGoBack else { return }
        await show(state.index - 1)
    }

    /// Shows a painting already in the history, re-downloading its image if the cache lost it.
    private func show(_ index: Int) async {
        guard state.history.indices.contains(index), !isLoading else { return }
        let art = state.history[index]
        var img = NSImage(contentsOf: imageURL(for: art))
        if img == nil {
            isLoading = true
            defer { isLoading = false }
            do {
                let data = try await AICClient.imageData(for: art)
                try? data.write(to: imageURL(for: art), options: .atomic)
                img = NSImage(data: data)
            } catch {
                log("image fetch failed: \(error.localizedDescription)")
                return
            }
        }
        state.index = index
        save()
        artwork = art
        image = img
    }

    /// `daily` is the day's shared painting, the same one the iPhone shows; otherwise a random extra.
    /// On failure the old painting stays up and the date isn't advanced, so the next tick retries.
    private func fetchNew(daily: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (art, data) = daily ? try await AICClient.daily(day: DailyPick.day()) : try await pick()
            try data.write(to: imageURL(for: art), options: .atomic)
            state.date = Self.today()
            state.history.append(art)
            state.shown.append(art.id)
            trimHistory()
            state.index = state.history.count - 1
            save()
            artwork = art
            image = NSImage(data: data)
        } catch {
            log("fetch failed: \(error.localizedDescription)")
        }
    }

    private func pick() async throws -> (Artwork, Data) {
        let total = try await AICClient.total()
        guard total > 0 else { throw AICError.nothingFound }
        if state.shown.count >= total { state.shown = [] }
        var lastError: Error = AICError.nothingFound
        for _ in 0..<8 {
            do {
                let art = try await AICClient.artwork(at: Int.random(in: 1...total), total: total)
                if state.shown.contains(art.id) { continue }
                return (art, try await AICClient.imageData(for: art))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Keeps the newest `historyLimit` paintings and drops the cached images of the rest.
    private func trimHistory() {
        let extra = state.history.count - Self.historyLimit
        guard extra > 0 else { return }
        for art in state.history.prefix(extra) {
            try? FileManager.default.removeItem(at: imageURL(for: art))
        }
        state.history.removeFirst(extra)
    }

    private func imageURL(for art: Artwork) -> URL {
        imagesDir.appendingPathComponent("\(art.id).jpg")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("\(Date()) \(message)\n".data(using: .utf8)!)
    }
}
