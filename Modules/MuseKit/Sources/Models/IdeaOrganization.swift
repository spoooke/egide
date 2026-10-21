import SwiftUI

/// Priorité d'une idée : 0 aucune, 1 basse, 2 moyenne, 3 haute.
enum Priority: Int, CaseIterable, Identifiable, Sendable {
    case none = 0, low, medium, high

    var id: Self { self }

    /// « ! », « !! », « !!! » (vide si aucune).
    var marks: String { String(repeating: "!", count: rawValue) }

    var label: String {
        switch self {
        case .none: "Aucune"
        case .low: "!"
        case .medium: "!!"
        case .high: "!!!"
        }
    }

    var color: Color {
        switch self {
        case .none: .secondary
        case .low: .blue
        case .medium: .orange
        case .high: .red
        }
    }
}

/// Lecture de la saisie rapide : `#tag` et `!!` / `!!!` sont retirés du texte.
/// Un `!` isolé reste du texte : en français on écrit « Super ! ».
enum CaptureParser {
    struct Result: Equatable {
        var text: String
        var tags: [String]
        var priority: Priority
    }

    static func parse(_ raw: String) -> Result {
        var words: [Substring] = []
        var tags: [String] = []
        var priority = Priority.none

        for word in raw.split(whereSeparator: \.isWhitespace) {
            if word == "!!!" {
                priority = .high
            } else if word == "!!", priority != .high {
                priority = .medium
            } else if word.hasPrefix("#"), let tag = Tags.normalized(String(word.dropFirst())) {
                Tags.insert(tag, into: &tags)
            } else {
                words.append(word)
            }
        }
        return Result(text: words.joined(separator: " "), tags: tags, priority: priority)
    }
}

/// Règles communes aux tags : sans « # », sans espaces autour, sans doublon (casse ignorée).
enum Tags {
    static func normalized(_ raw: String) -> String? {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#,.;:")))
        return tag.isEmpty ? nil : tag
    }

    static func contains(_ tags: [String], _ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    static func insert(_ tag: String, into tags: inout [String]) {
        if !contains(tags, tag) { tags.append(tag) }
    }

    /// Tous les tags utilisés, sans doublon, triés.
    static func all(in ideas: [Idea]) -> [String] {
        var result: [String] = []
        for tag in ideas.flatMap(\.tags) { insert(tag, into: &result) }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Couleur stable pour un tag (même couleur sur tous les appareils).
    static func color(for tag: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown, .cyan, .mint,
                                Color(red: 0.8, green: 0.25, blue: 0.5)]
        // Empreinte FNV-1a : stable d'un lancement et d'un appareil à l'autre, et bien répartie.
        var hash: UInt32 = 2_166_136_261
        for byte in tag.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

extension Idea {
    var priorityLevel: Priority {
        get { Priority(rawValue: priority) ?? .none }
        set { priority = newValue.rawValue }
    }

    /// Ordre de « À faire » : priorité la plus haute d'abord, puis l'ordre choisi.
    static func todoOrder(_ a: Idea, _ b: Idea) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        return a.sortIndex < b.sortIndex
    }
}
