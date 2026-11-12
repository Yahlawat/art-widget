import Foundation

/// The wall-label text for one artwork, built only from the museum's record.
struct CardText {
    let heading: String
    let date: String?
    let artist: String?
    let blurb: String?
    let facts: [String]
}

enum Facts {
    static func make(_ art: Artwork) -> CardText {
        var facts: [String] = []
        if let place = clean(art.placeOfOrigin) {
            facts.append("Made in \(place)")
        }
        let medium = clean(art.mediumDisplay)
        let size = art.dimensions.flatMap(metricSize)
        if let line = [medium, size].compactMap({ $0 }).joined(separator: ", ").nilIfEmpty {
            facts.append(line)
        }
        if let style = clean(art.styleTitle) {
            facts.append(style.prefix(1).uppercased() + style.dropFirst())
        }
        if let history = art.exhibitionHistory, let shows = exhibitions(history) {
            let noun = shows.count == 1 ? "exhibition" : "exhibitions"
            let since = shows.since.map { " since \($0)" } ?? ""
            facts.append("Shown in \(shows.count) \(noun)\(since)")
        }
        if let year = art.fiscalYear, year > 1800 {
            facts.append("In the museum's collection since \(year)")
        }

        let blurb = (clean(art.shortDescription.map(stripHTML)) ?? clean(art.description.map(stripHTML)))
            .map { wholeSentences($0, maxChars: 300) }

        return CardText(
            heading: art.title,
            date: clean(art.dateDisplay),
            artist: clean(art.artistDisplay?.replacingOccurrences(of: "\n", with: ", ")),
            blurb: blurb,
            facts: facts
        )
    }

    static func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&nbsp;": " ", "&lt;": "<", "&gt;": ">"] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// As many whole sentences as fit in maxChars, always at least one.
    static func wholeSentences(_ text: String, maxChars: Int) -> String {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s { sentences.append(s.trimmingCharacters(in: .whitespaces)) }
        }
        var out = ""
        for s in sentences {
            let next = out.isEmpty ? s : out + " " + s
            if !out.isEmpty && next.count > maxChars { break }
            out = next
        }
        return out.isEmpty ? text : out
    }

    /// "73.6 × 92.3 cm (29 × 36 5/8 in.); Framed: ..." -> "73.6 × 92.3 cm"
    static func metricSize(_ dimensions: String) -> String? {
        let first = dimensions.components(separatedBy: ";")[0]
        let metric = first.components(separatedBy: " (")[0]
        return metric.contains("cm") ? clean(metric) : nil
    }

    /// Exhibition history is one blank-line-separated entry per show, oldest first.
    static func exhibitions(_ history: String) -> (count: Int, since: Int?)? {
        let entries = history.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !entries.isEmpty else { return nil }
        let years = entries[0]
            .matches(of: yearPattern)
            .compactMap { Int(entries[0][$0.range]) }
        return (entries.count, years.min())
    }

    private static let yearPattern = try! Regex(#"\b(1[5-9]\d\d|20\d\d)\b"#)

    private static func clean(_ s: String?) -> String? {
        s?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
