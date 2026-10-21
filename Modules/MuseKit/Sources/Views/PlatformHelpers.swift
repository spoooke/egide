import SwiftUI

// Petites différences iPhone / Mac regroupées ici.

extension ToolbarItemPlacement {
    /// À gauche de la barre de navigation sur iPhone, zone de navigation sur Mac.
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
}

extension View {
    /// Titre compact sur iPhone ; sans effet sur Mac.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
