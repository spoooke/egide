import Foundation

/// Contenu d'un fichier roadmap : titres `#`/`##` et cases `- [ ]` / `- [x]`.
struct ParsedRoadmap: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var text: String
        var isDone: Bool
    }

    struct Section: Equatable, Sendable {
        var title: String
        var items: [Item]
    }

    var title: String?
    var sections: [Section]

    var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }
}

enum RoadmapParser {
    static func parse(_ markdown: String) -> ParsedRoadmap {
        var title: String?
        var sections: [ParsedRoadmap.Section] = []
        var current = ParsedRoadmap.Section(title: "", items: [])

        func flush() {
            if !current.items.isEmpty { sections.append(current) }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("# ") {
                if title == nil { title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("## ") || line.hasPrefix("### ") {
                flush()
                current = ParsedRoadmap.Section(title: cleanSectionTitle(line.drop { $0 == "#" }), items: [])
            } else if let match = line.wholeMatch(of: /[-*+]\s+\[([ xX])\]\s+(.+)/) {
                current.items.append(.init(
                    text: String(match.2).trimmingCharacters(in: .whitespaces),
                    isDone: match.1 != " "
                ))
            }
        }
        flush()
        return ParsedRoadmap(title: title, sections: sections)
    }

    /// Texte du fichier sans la case `text` de la section `section` (ou, à défaut, de n'importe quelle section).
    /// `nil` si la case est introuvable. Le reste du fichier est laissé tel quel.
    static func removingItem(text: String, section: String, from markdown: String) -> String? {
        var lines = markdown.components(separatedBy: "\n")
        let key = matchKey(text)
        var candidates: [(index: Int, sameSection: Bool)] = []
        var currentSection = ""

        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") || line.hasPrefix("### ") {
                currentSection = cleanSectionTitle(line.drop { $0 == "#" })
            } else if let match = line.wholeMatch(of: /[-*+]\s+\[([ xX])\]\s+(.+)/),
                      matchKey(String(match.2)) == key {
                candidates.append((index, currentSection == section))
            }
        }

        guard let target = candidates.first(where: \.sameSection) ?? candidates.first else { return nil }
        lines.remove(at: target.index)
        return lines.joined(separator: "\n")
    }

    /// Retire le « ✅ » ajouté quand une phase est finie, pour garder un titre stable.
    static func cleanSectionTitle(_ raw: Substring) -> String {
        raw.replacingOccurrences(of: "✅", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Clé de correspondance entre deux versions du fichier : insensible à la casse,
    /// aux espaces et à la mise en forme Markdown.
    static func matchKey(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
