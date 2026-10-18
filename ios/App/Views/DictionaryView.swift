import SwiftUI

/// Hot words, corrections and snippets — the desktop's Vocabulary page.
struct DictionaryView: View {
    enum Page: String, CaseIterable { case words = "Words", corrections = "Corrections", snippets = "Snippets" }

    @State private var page: Page = .words
    @State private var words: [String] = []
    @State private var corrections: [FormatOptions.Pair] = []
    @State private var snippets: [FormatOptions.Pair] = []
    @State private var editing: Editing?

    struct Editing: Identifiable {
        var page: Page
        var index: Int?          // nil = new
        var from = ""
        var to = ""
        var id: String { "\(page.rawValue)-\(index ?? -1)" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("List", selection: $page) {
                        ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(footer).padding(.top, 8)
                }

                switch page {
                case .words:
                    ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                        Button(w) { editing = Editing(page: .words, index: i, from: w) }
                            .foregroundStyle(.primary)
                    }
                    .onDelete { words.remove(atOffsets: $0); WordLists.setHotwords(words) }
                case .corrections:
                    ForEach(Array(corrections.enumerated()), id: \.offset) { i, p in
                        Button { editing = Editing(page: .corrections, index: i, from: p.from, to: p.to) } label: {
                            HStack {
                                Text(p.from).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                                Text(p.to).foregroundStyle(.primary)
                            }
                        }
                    }
                    .onDelete { corrections.remove(atOffsets: $0); WordLists.setCorrections(corrections) }
                case .snippets:
                    ForEach(Array(snippets.enumerated()), id: \.offset) { i, p in
                        Button { editing = Editing(page: .snippets, index: i, from: p.from, to: p.to) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("“\(p.from)”").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(p.to).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .onDelete { snippets.remove(atOffsets: $0); WordLists.setSnippets(snippets) }
                }
            }
            .overlay {
                if isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: emptyIcon, description: Text(emptyHint))
                }
            }
            .navigationTitle("Dictionary")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = Editing(page: page) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add")
                }
            }
            .sheet(item: $editing) { e in
                EntryEditor(editing: e) { saved in save(saved) }
                    .presentationDetents([.medium, .large])
            }
            .onAppear(perform: reload)
        }
    }

    private var isEmpty: Bool {
        switch page {
        case .words: words.isEmpty
        case .corrections: corrections.isEmpty
        case .snippets: snippets.isEmpty
        }
    }

    private var footer: String {
        switch page {
        case .words: "Names, jargon and product words. Tiro primes the speech model with them so it spells them right."
        case .corrections: "When Tiro still hears something wrong, fix it here. Only the text you get is changed; History keeps what you said."
        case .snippets: "Say a cue phrase and get saved text: an email address, a link, a sign-off. Say it alone to get just the snippet."
        }
    }

    private var emptyTitle: String {
        switch page {
        case .words: "No words yet"
        case .corrections: "No corrections yet"
        case .snippets: "No snippets yet"
        }
    }

    private var emptyIcon: String {
        switch page {
        case .words: "textformat.abc"
        case .corrections: "arrow.left.arrow.right"
        case .snippets: "text.badge.plus"
        }
    }

    private var emptyHint: String {
        switch page {
        case .words: "Tap + to add a name like “Beckett” or “PostgreSQL”."
        case .corrections: "Tap + to turn “tyro” into “Tiro”."
        case .snippets: "Tap + to make “my email” type your address."
        }
    }

    private func reload() {
        words = WordLists.hotwords()
        corrections = WordLists.corrections()
        snippets = WordLists.snippets()
    }

    private func save(_ e: Editing) {
        let from = e.from.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = e.to.trimmingCharacters(in: .whitespacesAndNewlines)
        switch e.page {
        case .words:
            guard !from.isEmpty else { return }
            if let i = e.index { words[i] = from } else { words.append(from) }
            WordLists.setHotwords(words)
        case .corrections:
            guard !from.isEmpty, !to.isEmpty else { return }
            let p = FormatOptions.Pair(from, to)
            if let i = e.index { corrections[i] = p } else { corrections.append(p) }
            WordLists.setCorrections(corrections)
        case .snippets:
            guard !from.isEmpty, !to.isEmpty else { return }
            let p = FormatOptions.Pair(from, to)
            if let i = e.index { snippets[i] = p } else { snippets.append(p) }
            WordLists.setSnippets(snippets)
        }
        reload()
    }
}

private struct EntryEditor: View {
    @State var editing: DictionaryView.Editing
    var onSave: (DictionaryView.Editing) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                switch editing.page {
                case .words:
                    TextField("Word or phrase", text: $editing.from)
                        .focused($focused)
                        .autocorrectionDisabled()
                case .corrections:
                    Section("Tiro hears") {
                        TextField("tyro", text: $editing.from).focused($focused).autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Section("You get") {
                        TextField("Tiro", text: $editing.to).autocorrectionDisabled()
                    }
                case .snippets:
                    Section("When you say") {
                        TextField("my email", text: $editing.from).focused($focused).autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Section("Tiro types") {
                        TextField("you@example.com", text: $editing.to, axis: .vertical)
                            .lineLimit(3...10)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
            }
            .navigationTitle(editing.index == nil ? "Add" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(editing); dismiss() }.disabled(!valid)
                }
            }
            .onAppear { focused = true }
        }
    }

    private var valid: Bool {
        let f = !editing.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let t = !editing.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return editing.page == .words ? f : (f && t)
    }
}
