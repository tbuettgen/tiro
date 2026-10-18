import AVFoundation
import SwiftUI

struct OnboardingView: View {
    var done: () -> Void
    @EnvironmentObject private var models: ModelStore
    @AppStorage(Settings.Key.model, store: Shared.defaults) private var selected = "base.en"
    @State private var step = 0
    @State private var micGranted = AVAudioApplication.shared.recordPermission == .granted

    private let recommended = ModelStore.model(named: "base.en")!

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                page(icon: "waveform", title: "Talk. Tiro types.",
                     text: "Dictate in any app with the Tiro keyboard. Tiro cleans up the text, follows your spoken commands and learns your words.")
                    .tag(0)
                page(icon: "lock.shield", title: "Nothing leaves your iPhone",
                     text: "Speech is turned into text on this device. No account, no cloud, no analytics, and it's free.")
                    .tag(1)
                micPage.tag(2)
                modelPage.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button(action: next) {
                Text(buttonTitle).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("onboarding.next")
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Button("Skip for now") { done() }
                .font(.footnote)
                .padding(.vertical, 10)
                .opacity(step == 3 && models.installed.isEmpty ? 1 : 0)
                .disabled(!(step == 3 && models.installed.isEmpty))
                .padding(.bottom, 8)
        }
    }

    private var buttonTitle: String {
        switch step {
        case 2: micGranted ? "Continue" : "Allow microphone"
        case 3: models.installed.isEmpty ? (models.progress[recommended.name] != nil ? "Downloading…" : "Download \(recommended.name) (\(recommended.sizeLabel))") : "Start dictating"
        default: "Continue"
        }
    }

    private func next() {
        switch step {
        case 2 where !micGranted:
            Task {
                micGranted = await AVAudioApplication.requestRecordPermission()
                withAnimation { step = 3 }
            }
        case 3:
            if models.installed.isEmpty {
                if models.progress[recommended.name] == nil {
                    selected = recommended.name
                    models.download(recommended)
                }
            } else {
                if !models.installed.contains(selected), let first = models.installed.sorted().first { selected = first }
                done()
            }
        default:
            withAnimation { step += 1 }
        }
    }

    private var micPage: some View {
        page(icon: "mic", title: "Microphone",
             text: "Tiro listens only while you dictate. iOS shows the orange dot whenever the mic is on.")
    }

    private var modelPage: some View {
        VStack(spacing: 16) {
            page(icon: "arrow.down.circle", title: "One download, then offline",
                 text: "Tiro needs a speech model on your iPhone. This is the only time it uses the internet. You can switch models later in Settings.")
            if let p = models.progress[recommended.name] {
                ProgressView(value: p).padding(.horizontal, 48)
            } else if !models.installed.isEmpty {
                Label("Model ready", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
            }
            if let err = models.lastError {
                Text(err).font(.footnote).foregroundStyle(Palette.warn).padding(.horizontal, 32)
            }
        }
    }

    private func page(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(title).font(.title.weight(.bold)).multilineTextAlignment(.center)
            Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }
}
