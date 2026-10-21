import EgideUI
import SwiftData
import SwiftUI

struct ContentView: View {
    enum Route: Hashable {
        case projects
        case sync
    }

    enum Filter: String, CaseIterable, Identifiable {
        case todo = "À faire"
        case today = "Aujourd'hui"
        case upcoming = "À venir"
        case done = "Terminées"
        var id: Self { self }
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \Idea.sortIndex) private var ideas: [Idea]
    @State private var filter: Filter = .todo
    @State private var savedCount = 0
    @State private var sync = SyncService.shared
    @State private var navigation = AppNavigation.shared
    @State private var path = NavigationPath()
    @State private var selectedTag: String?
    @Environment(\.goHome) private var goHome
    @Environment(\.egideIcone) private var icone

    private var allTags: [String] { Tags.all(in: ideas) }
    /// Idées du tag choisi (toutes si aucun tag n'est choisi).
    private var taggedIdeas: [Idea] {
        guard let selectedTag else { return ideas }
        return ideas.filter { Tags.contains($0.tags, selectedTag) }
    }
    private var todoIdeas: [Idea] { taggedIdeas.filter { !$0.isDone }.sorted(by: Idea.todoOrder) }
    private var doneIdeas: [Idea] {
        taggedIdeas.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    private var todayIdeas: [Idea] { ReminderViews.today(taggedIdeas) }
    private var upcomingDays: [(day: Date, ideas: [Idea])] { ReminderViews.upcoming(taggedIdeas) }
    private var visibleIdeas: [Idea] {
        switch filter {
        case .todo: todoIdeas
        case .today: todayIdeas
        case .upcoming: upcomingDays.flatMap(\.ideas)
        case .done: doneIdeas
        }
    }

    private var emptyTitle: String {
        if let selectedTag { return "Rien avec le tag \(selectedTag)" }
        switch filter {
        case .todo: return "Aucune idée"
        case .today: return "Rien pour aujourd'hui"
        case .upcoming: return "Rien à venir"
        case .done: return "Rien de terminé"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .todo: "lightbulb"
        case .today: "sun.max"
        case .upcoming: "calendar"
        case .done: "checkmark.circle"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .todo: "Tape ton idée en bas et valide."
        case .today, .upcoming: "Les idées avec un rappel apparaîtront ici."
        case .done: "Les idées cochées apparaîtront ici."
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Group {
                    if filter == .upcoming {
                        // « À venir » : une section par jour.
                        ForEach(upcomingDays, id: \.day) { group in
                            Section(ReminderViews.dayTitle(group.day)) {
                                ideaRows(group.ideas, movable: false)
                            }
                        }
                    } else {
                        ideaRows(visibleIdeas, movable: filter == .todo)
                    }
                }
                .egideRow()
            }
            .egideList()
            // Glisser la liste vers le bas baisse le clavier.
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if visibleIdeas.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: emptyIcon, description: Text(emptyDescription))
                }
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    #if os(macOS)
                    // Mac : en-tête dans la page, comme les autres onglets d'Égide ; la barre de titre reste vide.
                    EgideHeader("Muse", sousTitre: "Idées, rappels, projets", image: icone) {
                        HStack(spacing: 8) {
                            NavigationLink(value: Route.projects) { Label("Projets", systemImage: "folder") }
                            NavigationLink(value: Route.sync) {
                                Label("Synchro", systemImage: sync.isConfigured ? "icloud" : "icloud.slash")
                            }
                        }
                        .labelStyle(.titleAndIcon)
                    }
                    .padding(.horizontal)
                    .padding(.top, 44)
                    .padding(.bottom, 6)
                    #endif
                    Picker("Filtre", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal)

                    if !allTags.isEmpty {
                        TagFilterBar(tags: allTags, selection: $selectedTag)
                    }
                }
                .padding(.bottom, 8)
                // Tag supprimé de toutes les idées : on enlève le filtre.
                .onChange(of: allTags) { _, tags in
                    if let selectedTag, !Tags.contains(tags, selectedTag) { self.selectedTag = nil }
                }
            }
            .safeAreaInset(edge: .bottom) {
                CaptureBar { text in
                    if IdeaActions.add(text, in: context) != nil {
                        filter = .todo
                        savedCount += 1
                    }
                }
            }
            #if os(macOS)
            .padding(.horizontal, 16)
            .frame(maxWidth: 840)
            .frame(maxWidth: .infinity, alignment: .leading)
            .egideScreen()
            .toolbar(removing: .title)
            #else
            .navigationTitle("Muse")
            #endif
            // Toutes les destinations sont déclarées ici, à la racine de la pile.
            .navigationDestination(for: Idea.self) { IdeaDetailView(idea: $0) }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .projects: ProjectsView()
                case .sync: SyncSettingsView()
                }
            }
            .navigationDestination(for: Project.self) { ProjectDetailView(project: $0) }
            #if os(iOS)
            .toolbar {
                HomeToolbarItem(action: goHome)
                ToolbarItemGroup(placement: .leadingBar) {
                    NavigationLink(value: Route.projects) {
                        Label("Projets", systemImage: "folder")
                    }
                    NavigationLink(value: Route.sync) {
                        Label("Synchro", systemImage: sync.isConfigured ? "icloud" : "icloud.slash")
                    }
                }
                if filter == .todo && !todoIdeas.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
            }
            #endif
            .sensoryFeedback(.success, trigger: savedCount)
            // Demande « noter une idée » (contrôle, Siri) : retour à la liste, champ de saisie prêt.
            .onChange(of: navigation.captureRequests) {
                path = NavigationPath()
                filter = .todo
            }
        }
    }
}

extension ContentView {
    /// Lignes d'idées : ouvrir, cocher (glisser à droite), supprimer, et réordonner dans « À faire ».
    private func ideaRows(_ ideas: [Idea], movable: Bool) -> some View {
        ForEach(ideas) { idea in
            NavigationLink(value: idea) {
                IdeaRow(idea: idea) { IdeaActions.toggle(idea) }
            }
            .swipeActions(edge: .leading) {
                Button {
                    IdeaActions.toggle(idea)
                } label: {
                    Label(idea.isDone ? "À faire" : "Terminée",
                          systemImage: idea.isDone ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(.green)
            }
        }
        .onDelete { offsets in
            for index in offsets { IdeaActions.delete(ideas[index], in: context) }
        }
        .onMove(perform: movable ? { IdeaActions.move(ideas, from: $0, to: $1) } : nil)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: AppSchema.models, inMemory: true)
}
