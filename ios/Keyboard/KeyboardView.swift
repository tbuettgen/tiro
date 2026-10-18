import SwiftUI
import UIKit

struct KeyboardView: View {
    static let barHeight: CGFloat = 52
    static let height: CGFloat = barHeight + 4 * 54 + 12

    @ObservedObject var model: KeyboardModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            DictationBar(model: model)
                .frame(height: Self.barHeight)
            KeyRows(model: model)
                .padding(.horizontal, 3)
                .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
        .background(Color.clear)
    }
}

// MARK: - The dictation bar

private struct DictationBar: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .recording:
                circleButton("xmark", label: "Cancel", tint: .secondary) { model.cancelTapped() }
                Waveform(level: model.level, bars: 22, color: Palette.record)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                micButton(icon: "stop.fill", title: "Done", color: Palette.record)
            case .transcribing:
                Spacer()
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            default:
                status
                Spacer(minLength: 4)
                micButton(icon: "mic.fill", title: model.appListening ? "Dictate" : "Tiro", color: .accentColor)
            }
        }
        .padding(.horizontal, 10)
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }

    @ViewBuilder private var status: some View {
        if let note = model.note {
            Text(note)
                .font(.caption)
                .foregroundStyle(model.phase == .error || !model.hasFullAccess ? Palette.warn : .secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        } else if model.openingApp {
            Text("Opening Tiro…").font(.caption).foregroundStyle(.secondary)
        } else if model.appListening {
            Label("Ready", systemImage: "circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.ok)
                .labelStyle(DotLabel())
        } else {
            Text("Tap to dictate").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func micButton(icon: String, title: String, color: Color) -> some View {
        Button(action: model.micTapped) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(color, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.phase == .recording ? "Finish dictation" : "Dictate with Tiro")
        .accessibilityIdentifier("tiro.kb.mic")
    }

    private func circleButton(_ icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}

// MARK: - Keys

private struct KeyRows: View {
    @ObservedObject var model: KeyboardModel

    private static let letters = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]
    private static let numbers = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
    ]
    private static let symbols = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
        [".", ",", "?", "!", "'"],
    ]

    var body: some View {
        let rows = model.layer == .letters ? Self.letters : (model.layer == .numbers ? Self.numbers : Self.symbols)
        GeometryReader { geo in
            let unit = (geo.size.width - 9 * 6) / 10
            VStack(spacing: 10) {
                row(rows[0], unit: unit)
                row(rows[1], unit: unit)
                    .padding(.horizontal, model.layer == .letters ? unit / 2 + 3 : 0)
                HStack(spacing: 6) {
                    leftModifier(unit: unit)
                    Spacer(minLength: 0)
                    ForEach(rows[2], id: \.self) { k in
                        CharKey(label: label(k), width: model.layer == .letters ? unit : unit * 1.35) { model.type(k) }
                    }
                    Spacer(minLength: 0)
                    DeleteKey(width: unit * 1.35) { model.backspace() }
                }
                HStack(spacing: 6) {
                    FunctionKey(text: model.layer == .letters ? "123" : "ABC", width: unit * 1.35) {
                        model.layer = model.layer == .letters ? .numbers : .letters
                        model.contextChanged()
                    }
                    if model.needsGlobe {
                        GlobeKey(model: model).frame(width: unit * 1.2, height: 44)
                    }
                    CharKey(label: "space", width: nil, font: .system(size: 16)) { model.space() }
                    FunctionKey(text: model.returnLabel, width: unit * 2.2, prominent: model.returnLabel != "return") { model.returnKey() }
                }
            }
            .padding(.top, 6)
        }
    }

    private func label(_ k: String) -> String {
        model.layer == .letters && (model.shifted || model.capsLock) ? k.uppercased() : k
    }

    private func row(_ keys: [String], unit: CGFloat) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { k in
                CharKey(label: label(k), width: unit) { model.type(k) }
            }
        }
    }

    @ViewBuilder private func leftModifier(unit: CGFloat) -> some View {
        switch model.layer {
        case .letters:
            ShiftKey(model: model, width: unit * 1.35)
        case .numbers:
            FunctionKey(text: "#+=", width: unit * 1.35) { model.layer = .symbols }
        case .symbols:
            FunctionKey(text: "123", width: unit * 1.35) { model.layer = .numbers }
        }
    }
}

private struct KeyFace: ViewModifier {
    var pressed: Bool
    var function = false
    var prominent = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let base: Color = {
            if prominent { return .accentColor }
            if scheme == .dark { return function ? Color(white: 0.27) : Color(white: 0.42) }
            return function ? Color(red: 0.67, green: 0.69, blue: 0.73) : .white
        }()
        content
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pressed ? base.opacity(0.55) : base)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.3), radius: 0, x: 0, y: 1)
            )
            .foregroundStyle(prominent ? .white : .primary)
            .contentShape(Rectangle())
    }
}

private struct CharKey: View {
    var label: String
    var width: CGFloat?
    var font: Font = .system(size: 23)
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(font)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .modifier(KeyFace(pressed: pressed))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true } }
                .onEnded { _ in pressed = false; action() })
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityLabel(label)
            .accessibilityAction { action() }
    }
}

private struct FunctionKey: View {
    var text: String
    var width: CGFloat
    var prominent = false
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .frame(width: width)
            .modifier(KeyFace(pressed: pressed, function: true, prominent: prominent))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true } }
                .onEnded { _ in pressed = false; action() })
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityLabel(text)
            .accessibilityAction { action() }
    }
}

private struct ShiftKey: View {
    @ObservedObject var model: KeyboardModel
    var width: CGFloat
    @State private var lastTap: Date?

    var body: some View {
        Image(systemName: model.capsLock ? "capslock.fill" : (model.shifted ? "shift.fill" : "shift"))
            .font(.system(size: 18, weight: .medium))
            .frame(width: width)
            .modifier(KeyFace(pressed: false, function: !model.shifted))
            .onTapGesture {
                if let t = lastTap, Date().timeIntervalSince(t) < 0.35 {
                    model.capsLockOn()
                    lastTap = nil
                } else {
                    model.toggleShift()
                    lastTap = Date()
                }
            }
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityLabel(model.capsLock ? "Caps lock" : "Shift")
    }
}

/// Backspace with key repeat while held.
private struct DeleteKey: View {
    var width: CGFloat
    var action: () -> Void
    @State private var pressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: pressed ? "delete.left.fill" : "delete.left")
            .font(.system(size: 18, weight: .medium))
            .frame(width: width)
            .modifier(KeyFace(pressed: pressed, function: true))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    action()
                    repeatTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        while !Task.isCancelled {
                            action()
                            try? await Task.sleep(for: .milliseconds(80))
                        }
                    }
                }
                .onEnded { _ in
                    pressed = false
                    repeatTask?.cancel()
                    repeatTask = nil
                })
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityLabel("Delete")
            .accessibilityAction { action() }
    }
}

/// The 🌐 key needs a real UIView so iOS can show its keyboard list.
private struct GlobeKey: UIViewRepresentable {
    @ObservedObject var model: KeyboardModel

    func makeUIView(context: Context) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "globe"), for: .normal)
        b.tintColor = .label
        b.layer.cornerRadius = 6
        b.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1) }
        b.accessibilityLabel = "Next keyboard"
        b.addTarget(context.coordinator, action: #selector(Coordinator.handle(_:event:)), for: .allTouchEvents)
        return b
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.model = model
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject {
        var model: KeyboardModel
        init(model: KeyboardModel) { self.model = model }
        @MainActor @objc func handle(_ sender: UIButton, event: UIEvent) {
            model.switchKeyboard(from: sender, with: event)
        }
    }
}
