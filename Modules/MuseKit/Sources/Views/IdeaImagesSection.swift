import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Section « Captures » du détail : coller ou choisir dans Photos.
/// L'affichage en grand, ⌘V et le glisser-déposer (Mac) sont branchés sur tout l'écran
/// par `imageHandling` : une feuille attachée dans une ligne de formulaire ne s'affiche pas toujours.
struct IdeaImagesSection: View {
    @Bindable var idea: Idea
    @Binding var shownImage: IdeaImage?
    @Environment(\.modelContext) private var context
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 8)]

    var body: some View {
        Section {
            if !idea.sortedImages.isEmpty {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(idea.sortedImages) { image in
                        Button { shownImage = image } label: {
                            ImageThumbnail(image: image)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Supprimer la capture", systemImage: "trash", role: .destructive) {
                                IdeaActions.removeImage(image, from: idea, in: context)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            HStack(spacing: 12) {
                // Bouton système : colle sans demander d'autorisation à chaque fois.
                PasteButton(supportedContentTypes: [.image]) { providers in
                    IdeaImageInput.add(providers, to: idea, in: context)
                }
                .labelStyle(.titleAndIcon)

                PhotosPicker(selection: $pickedItems, maxSelectionCount: 10, matching: .images) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
        } header: {
            Text("Captures")
        } footer: {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                #if os(macOS)
                Text("Colle une capture avec ⌘V ou glisse une image ici.")
                #else
                Text("Copie une capture (Partager › Copier) puis touche Coller, ou choisis-la dans Photos.")
                #endif
            }
        }
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { addImage(data) }
                }
                pickedItems = []
            }
        }
    }

    private func addImage(_ data: Data) {
        errorMessage = IdeaActions.addImage(data, to: idea, in: context) ? nil : "Ce contenu n'est pas une image."
    }
}

/// Ajout d'images venues du presse-papiers ou d'un glisser-déposer.
@MainActor
enum IdeaImageInput {
    static func add(_ providers: [NSItemProvider], to idea: Idea, in context: ModelContext) {
        // Le chargement se termine hors du thread principal : on n'y emporte que des valeurs partageables.
        let ideaID = idea.persistentModelID
        let container = context.container
        for provider in providers {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    let context = container.mainContext
                    guard let idea = context.model(for: ideaID) as? Idea else { return }
                    IdeaActions.addImage(data, to: idea, in: context)
                }
            }
        }
    }
}

extension View {
    /// Affichage en grand des captures et, sur Mac, ⌘V et glisser-déposer sur tout l'écran.
    func imageHandling(for idea: Idea, shownImage: Binding<IdeaImage?>, context: ModelContext) -> some View {
        self
            #if os(macOS)
            .onPasteCommand(of: [.image]) { providers in IdeaImageInput.add(providers, to: idea, in: context) }
            .onDrop(of: [.image], isTargeted: nil) { providers in
                IdeaImageInput.add(providers, to: idea, in: context)
                return true
            }
            #endif
            .sheet(item: shownImage) { image in
                ImageViewer(image: image) {
                    IdeaActions.removeImage(image, from: idea, in: context)
                    shownImage.wrappedValue = nil
                }
            }
    }
}

/// Miniature carrée, décodée en petite taille.
private struct ImageThumbnail: View {
    let image: IdeaImage

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let data = image.data, let cgImage = ImageProcessing.downsampled(data, maxPixelSize: 300) {
                    Image(decorative: cgImage, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Venue d'un autre appareil, pas encore téléchargée.
                    ProgressView()
                }
            }
            .clipShape(.rect(cornerRadius: 8))
    }
}

/// Affichage en grand d'une capture.
private struct ImageViewer: View {
    let image: IdeaImage
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let data = image.data, let cgImage = ImageProcessing.downsampled(data, maxPixelSize: ImageProcessing.maxPixelSize) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: cgImage, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .containerRelativeFrame([.horizontal, .vertical])
                    }
                } else {
                    ProgressView("Téléchargement…")
                }
            }
            .navigationTitle("Capture")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Supprimer", systemImage: "trash", role: .destructive, action: onDelete)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 450)
        #endif
    }
}
