import SwiftUI

struct DictateView: View {
    @EnvironmentObject private var dictation: Dictation
    @EnvironmentObject private var models: ModelStore
    @State private var toast: String?
    @State private var stats = DictationStats()
    @State private var showVerbatim = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    SessionCard()
                    if models.installed.isEmpty {
                        NoModelCard()
                    }
                    resultCard
                    StatsStrip(stats: stats)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 180)
            }
            .overlay(alignment: .bottom) { micArea }
            .navigationTitle("Tiro")
            .toast($toast)
            .task(id: dictation.revision) { stats = TranscriptStore.stats(TranscriptStore.allRecords()) }
        }
    }

    @ViewBuilder private var resultCard: some View {
        if let rec = dictation.lastResult {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Last take").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(rec.date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(showVerbatim ? rec.text : rec.shown)
                    .font(.body)
                    .accessibilityIdentifier("dictate.result")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = rec.shown
                        toast = "Copied"
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    ShareLink(item: rec.shown) { Label("Share", systemImage: "square.and.arrow.up") }
                    Spacer()
                    if rec.text != rec.shown {
                        Button(showVerbatim ? "Formatted" : "As said") { showVerbatim.toggle() }
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Tap the mic and talk. Your words appear here and on the clipboard.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    private var micArea: some View {
        VStack(spacing: 12) {
            if let err = dictation.errorMessage {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(Palette.warn)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else if dictation.recording {
                Waveform(level: dictation.level, bars: 24, color: Palette.record.opacity(0.85))
                    .frame(width: 220, height: 32)
            } else {
                Text(statusText).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
                    .frame(height: 32)
                    .contentTransition(.opacity)
            }
            ZStack {
                Button(action: dictation.toggleInApp) {
                    ZStack {
                        Circle()
                            .fill(dictation.recording ? Palette.record : Color.accentColor)
                            .frame(width: 84, height: 84)
                            .shadow(color: (dictation.recording ? Palette.record : .accentColor).opacity(0.35), radius: 16, y: 6)
                        if dictation.transcribing {
                            ProgressView().tint(.white).controlSize(.large)
                        } else {
                            Image(systemName: dictation.recording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(dictation.transcribing)
                .accessibilityLabel(dictation.recording ? "Stop dictating" : "Start dictating")
                .accessibilityIdentifier("dictate.mic")
                .sensoryFeedback(.impact(weight: .medium), trigger: dictation.recording)
            }
            if dictation.recording {
                Button("Cancel", role: .cancel) { dictation.cancel() }.font(.footnote)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
    }

    private var statusText: String {
        if dictation.recording {
            return dictation.lastOrigin == .keyboard ? "Listening — keep talking in your app" : "Listening…"
        }
        if dictation.transcribing { return "Transcribing on this iPhone…" }
        return "Tap to dictate"
    }
}

/// The keyboard session: what it is, whether it's on, and when it ends.
struct SessionCard: View {
    @EnvironmentObject private var dictation: Dictation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: dictation.sessionActive ? "waveform.circle.fill" : "keyboard")
                .font(.title2)
                .foregroundStyle(dictation.sessionActive ? Palette.ok : .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                if dictation.sessionActive {
                    Text(dictation.recording && dictation.lastOrigin == .keyboard ? "Recording for the keyboard" : "Keyboard is live")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("session.title")
                    if dictation.recording && dictation.lastOrigin == .keyboard {
                        Text("Go back to your app (the ◀ at the top left) and keep talking. Tap the Tiro mic there to finish.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if let ends = dictation.sessionEnds {
                        Text("Tap the mic on the Tiro keyboard in any app. Sleeps \(ends, style: .relative).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Dictate in any app").font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("session.title")
                    Text("Switch to the Tiro keyboard and tap its mic. Tiro opens once to start listening, then works from the keyboard.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if dictation.sessionActive {
                Button("End") { dictation.endSession() }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                NavigationLink { KeyboardSetupView() } label: { Text("Set up") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct NoModelCard: View {
    var body: some View {
        NavigationLink { ModelsView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle").font(.title2).foregroundStyle(Palette.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download a speech model").font(.subheadline.weight(.semibold))
                    Text("One-time download. After that Tiro works fully offline.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct StatsStrip: View {
    var stats: DictationStats

    var body: some View {
        HStack(spacing: 0) {
            stat("\(stats.words.formatted())", "words")
            Divider().frame(height: 28)
            stat("\(stats.wpm)", "WPM")
            Divider().frame(height: 28)
            stat("\(stats.minutesSaved)m", "saved")
            Divider().frame(height: 28)
            stat("\(stats.streak)", stats.streak == 1 ? "day" : "days")
        }
        .padding(.vertical, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
