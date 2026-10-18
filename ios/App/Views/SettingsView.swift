import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var dictation: Dictation
    @EnvironmentObject private var models: ModelStore

    @AppStorage(Settings.Key.style, store: Shared.defaults) private var style = "formal"
    @AppStorage(Settings.Key.cleanup, store: Shared.defaults) private var cleanup = "light"
    @AppStorage(Settings.Key.spokenCommands, store: Shared.defaults) private var spokenCommands = true
    @AppStorage(Settings.Key.language, store: Shared.defaults) private var language = "en"
    @AppStorage(Settings.Key.model, store: Shared.defaults) private var model = "base.en"
    @AppStorage(Settings.Key.useVocabBias, store: Shared.defaults) private var vocabBias = true
    @AppStorage(Settings.Key.saveTranscripts, store: Shared.defaults) private var saveTranscripts = true
    @AppStorage(Settings.Key.sessionMinutes, store: Shared.defaults) private var sessionMinutes = 5
    @AppStorage(Settings.Key.haptics, store: Shared.defaults) private var haptics = true
    @AppStorage(Settings.Key.fitToContext, store: Shared.defaults) private var fitToContext = true

    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Style", selection: $style) {
                        Text("Formal").tag("formal")
                        Text("Casual").tag("casual")
                        Text("Very casual").tag("very_casual")
                    }
                    Picker("Cleanup", selection: $cleanup) {
                        Text("Off").tag("none")
                        Text("Light").tag("light")
                        Text("Light + remove um, uh").tag("fillers")
                    }
                    Toggle("Spoken commands", isOn: $spokenCommands)
                        .disabled(cleanup == "none")
                } header: {
                    Text("Writing")
                } footer: {
                    Text(writingFooter)
                }

                Section {
                    NavigationLink {
                        ModelsView()
                    } label: {
                        LabeledContent("Model", value: models.installed.contains(model) ? model : "Not downloaded")
                    }
                    Picker("Language", selection: $language) {
                        ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .disabled(ModelStore.model(named: model)?.englishOnly == true)
                    Toggle("Use Dictionary words", isOn: $vocabBias)
                } header: {
                    Text("Recognition")
                } footer: {
                    Text(ModelStore.model(named: model)?.englishOnly == true
                         ? "The \(model) model is English only. Pick a model without “.en” for other languages."
                         : "Auto-detect picks the language for each take.")
                }

                Section {
                    NavigationLink("Set up the keyboard") { KeyboardSetupView() }
                    Stepper("Stay listening \(sessionMinutes) min", value: $sessionMinutes, in: 1...60)
                    Toggle("Match surrounding text", isOn: $fitToContext)
                    Toggle("Haptics", isOn: $haptics)
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text("After you dictate from the keyboard, Tiro keeps the mic ready in the background for this long, so the next take starts instantly. iOS shows the orange mic dot while it's ready. “Match surrounding text” adds a space and continues mid-sentence in lowercase.")
                }

                Section {
                    Toggle("Save history", isOn: $saveTranscripts)
                    Button("Delete all history", role: .destructive) { confirmDelete = true }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Tiro has no accounts, no analytics and no servers. Your voice is transcribed on this iPhone and never leaves it. The network is used only to download a speech model when you ask.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("Source code (GPLv3)", destination: URL(string: "https://github.com/beckettharriman/tiro")!)
                    Text("Tiro is named for Marcus Tullius Tiro, Cicero's secretary, who invented a shorthand to write speech down as fast as people talked.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete every saved dictation?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete all history", role: .destructive) { TranscriptStore.deleteAll() }
            }
            .onChange(of: model) { dictation.unloadEngine() }
        }
    }

    private var writingFooter: String {
        let sample: String
        switch style {
        case "casual": sample = "Sounds good, see you at 3"
        case "very_casual": sample = "sounds good, see you at 3"
        default: sample = "Sounds good, see you at 3."
        }
        return "Example: “\(sample)”. Spoken commands: say “comma”, “period”, “question mark”, “new line”, “new paragraph”, or “scratch that” to delete the last sentence."
    }
}

enum Languages {
    struct Language { let code: String; let name: String }
    static let all: [Language] = [
        .init(code: "en", name: "English"),
        .init(code: "auto", name: "Auto-detect"),
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "sv", name: "Swedish"),
        .init(code: "pl", name: "Polish"),
        .init(code: "ru", name: "Russian"),
        .init(code: "uk", name: "Ukrainian"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "he", name: "Hebrew"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "vi", name: "Vietnamese"),
        .init(code: "id", name: "Indonesian"),
        .init(code: "el", name: "Greek"),
        .init(code: "cs", name: "Czech"),
        .init(code: "fi", name: "Finnish"),
        .init(code: "da", name: "Danish"),
        .init(code: "no", name: "Norwegian"),
    ]
}

struct ModelsView: View {
    @EnvironmentObject private var models: ModelStore
    @AppStorage(Settings.Key.model, store: Shared.defaults) private var selected = "base.en"

    var body: some View {
        List {
            Section {
                ForEach(ModelStore.catalog) { m in row(m) }
            } footer: {
                Text("Models run entirely on this iPhone. “.en” models are English only and a little more accurate for English. Bigger is more accurate but slower.")
            }
            if let err = models.lastError {
                Section { Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.warn) }
            }
        }
        .navigationTitle("Model")
        .onAppear { models.refresh() }
    }

    private func row(_ m: WhisperModel) -> some View {
        let installed = models.installed.contains(m.name)
        return HStack(spacing: 12) {
            Image(systemName: selected == m.name && installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected == m.name && installed ? Color.accentColor : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(.body.weight(.medium))
                Text("\(m.hint) · \(m.sizeLabel)").font(.caption).foregroundStyle(.secondary)
                if let p = models.progress[m.name] {
                    ProgressView(value: p).padding(.top, 4)
                }
            }
            Spacer()
            if models.progress[m.name] != nil {
                Button { models.cancelDownload(m) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).accessibilityLabel("Cancel download")
            } else if installed {
                Menu {
                    Button(role: .destructive) { models.delete(m) } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            } else {
                Button { models.download(m) } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.borderless).accessibilityLabel("Download \(m.name)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if installed { selected = m.name } else if models.progress[m.name] == nil { models.download(m); selected = m.name }
        }
    }
}

struct KeyboardSetupView: View {
    var body: some View {
        List {
            Section {
                step(1, "Open Settings", "Tap the button below. It opens Tiro's page in the Settings app.")
                step(2, "Keyboards → turn on Tiro", "Then turn on **Allow Full Access**. The keyboard needs it to hand your words over from the Tiro app. Tiro's keyboard never sends anything anywhere.")
                step(3, "Switch to the Tiro keyboard", "In any app, hold the 🌐 key and pick Tiro.")
                step(4, "Tap the mic", "The first time, Tiro opens and starts listening. Go back to your app (◀ at the top left), talk, and tap the mic again to put the text in. After that, the mic works right from the keyboard.")
            }
            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
            }
            Section("Try it") {
                TryItField()
            }
        }
        .navigationTitle("Keyboard")
    }

    private func step(_ n: Int, _ title: String, _ body: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.weight(.bold))
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TryItField: View {
    @State private var text = ""
    var body: some View {
        TextField("Switch to the Tiro keyboard and tap the mic", text: $text, axis: .vertical)
            .lineLimit(3...8)
    }
}
