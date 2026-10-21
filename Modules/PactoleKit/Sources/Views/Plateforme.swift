import SwiftData
import SwiftUI

// Petites différences iPhone / Mac regroupées ici (Money existe sur les deux).

extension View {
    /// Pavé numérique (montants) sur iPhone ; sans effet sur Mac.
    func clavierMontant(entier: Bool = false) -> some View {
        #if os(iOS)
        keyboardType(entier ? .numberPad : .decimalPad)
        #else
        self
        #endif
    }

    /// Titre compact sur iPhone ; sans effet sur Mac.
    func titreCompact() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Pas de majuscule automatique (motifs de règles) sur iPhone ; sans effet sur Mac.
    func sansMajuscules() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// « Supprimer » au clic droit (Mac) ou à l'appui long (iPhone), en plus du glissement.
    func menuSupprimer(_ action: @escaping () -> Void) -> some View {
        contextMenu {
            Button("Supprimer", systemImage: "trash", role: .destructive, action: action)
        }
    }
}

extension View {
    /// Appui long (iPhone) ou clic droit (Mac) sur une dépense : changer de poste, supprimer ; frais pro : remboursé.
    func menuDepense(_ depense: Depense, postes: [Poste], context: ModelContext) -> some View {
        contextMenu {
            Menu("Changer de poste", systemImage: "arrow.left.arrow.right") {
                ForEach(postes, id: \.persistentModelID) { poste in
                    Button {
                        depense.posteID = poste.syncID
                        if poste.syncID != Poste.pro { depense.rembourseLe = nil }
                        depense.aVerifier = false
                        depense.modifiedAt = .now
                        try? context.save()
                    } label: {
                        Label(poste.nom, systemImage: poste.syncID == depense.posteID ? "checkmark" : poste.symbole)
                    }
                }
            }
            if depense.posteID == Poste.pro {
                Button(depense.rembourseLe == nil ? "Marquer remboursé" : "Annuler le remboursement",
                       systemImage: depense.rembourseLe == nil ? "checkmark.circle" : "arrow.uturn.backward") {
                    depense.rembourseLe = depense.rembourseLe == nil ? .now : nil
                    depense.modifiedAt = .now
                    try? context.save()
                }
            }
            if depense.source == .banque { MenuFraisFixe(depense: depense) }
            Button("Supprimer", systemImage: "trash", role: .destructive) {
                Suppressions.supprimer(depense, dans: context)
                try? context.save()
            }
        }
    }
}

extension ToolbarItemPlacement {
    /// À gauche de la barre sur iPhone, zone de navigation sur Mac.
    static var aGauche: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
}
