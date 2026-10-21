import Foundation

/// Ordre et visibilité des onglets, choisis dans Réglages.
/// Rangé dans les préférences sous forme de texte : « argos,hermes,muse,money|hermes » (ordre|masqués).
struct TabLayout: Equatable {
    private(set) var order: [Module]
    private(set) var hidden: Set<Module>

    static let standard = TabLayout(order: Module.allCases, hidden: [])

    init(order: [Module], hidden: Set<Module>) {
        // Modules inconnus ignorés, modules absents (nouveaux) ajoutés à la fin.
        var seen = Set<Module>()
        let known = order.filter { seen.insert($0).inserted }
        self.order = known + Module.allCases.filter { !seen.contains($0) }
        self.hidden = hidden
    }

    init(storage: String) {
        let parts = storage.split(separator: "|", omittingEmptySubsequences: false)
        func modules(_ index: Int) -> [Module] {
            guard index < parts.count else { return [] }
            return parts[index].split(separator: ",").compactMap { Module(rawValue: String($0)) }
        }
        self.init(order: modules(0), hidden: Set(modules(1)))
    }

    var storage: String {
        order.map(\.rawValue).joined(separator: ",") + "|"
            + order.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }

    var visible: [Module] { order.filter { !hidden.contains($0) } }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
    }

    mutating func setHidden(_ module: Module, _ isHidden: Bool) {
        if isHidden { hidden.insert(module) } else { hidden.remove(module) }
    }
}
