import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var dictation: Dictation
    @State private var records: [TranscriptRecord] = []
    @State private var query = ""
    @State private var toast: String?

    private var filtered: [TranscriptRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return records }
        return records.filter { $0.shown.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q) }
    }

    private var byDay: [(String, [TranscriptRecord])] {
        var order: [String] = []
        var groups: [String: [TranscriptRecord]] = [:]
        for r in filtered {
            if groups[r.day] == nil { order.append(r.day) }
            groups[r.day, default: []].append(r)
        }
        return order.map { ($0, groups[$0]!) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(byDay, id: \.0) { day, recs in
                    Section(dayTitle(day)) {
                        ForEach(recs) { rec in
                            row(rec)
                        }
                        .onDelete { idx in
                            for i in idx { TranscriptStore.delete(recs[i]) }
                            reload()
                        }
                    }
                }
            }
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView("No dictations yet", systemImage: "waveform",
                                           description: Text("Everything you dictate is saved here, on this iPhone only."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search everything you've said")
            .navigationTitle("History")
            .toast($toast)
            .task(id: dictation.revision) { reload() }
            .refreshable { reload() }
        }
    }

    private func row(_ rec: TranscriptRecord) -> some View {
        Button {
            UIPasteboard.general.string = rec.shown
            toast = "Copied"
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(rec.shown).lineLimit(4).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(rec.date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                    Text("·")
                    Text(duration(rec.secs))
                    Text("·")
                    Text(rec.model)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { UIPasteboard.general.string = rec.shown; toast = "Copied" } label: { Label("Copy", systemImage: "doc.on.doc") }
            if rec.text != rec.shown {
                Button { UIPasteboard.general.string = rec.text; toast = "Copied as said" } label: { Label("Copy as said", systemImage: "quote.bubble") }
            }
            ShareLink(item: rec.shown) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { TranscriptStore.delete(rec); reload() } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func reload() { records = TranscriptStore.allRecords() }

    private func duration(_ secs: Double) -> String {
        let s = Int(secs.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func dayTitle(_ day: String) -> String {
        guard let d = TranscriptStore.dayFormatter.date(from: day) else { return day }
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}
