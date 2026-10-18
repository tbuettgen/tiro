//! The Tiro keyboard. Keyboards can't use the microphone on iOS, so the mic
//! key drives the Tiro app over the Bridge: the app listens in the
//! background, transcribes on device, and hands the text back for the
//! keyboard to insert at the cursor.

import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var model: KeyboardModel!
    private var host: UIHostingController<KeyboardView>!
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        Settings.register()
        model = KeyboardModel(controller: self)
        host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        let h = view.heightAnchor.constraint(equalToConstant: KeyboardView.height)
        h.priority = .defaultHigh
        h.isActive = true
        heightConstraint = h
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.activate()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.deactivate()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.contextChanged()
    }

    /// Open the containing app. Extensions may not call UIApplication.open
    /// directly; the responder chain reaches the host's UIApplication, and
    /// calling its open method by selector is the long-standing way keyboard
    /// extensions launch their app.
    func openContainingApp(_ url: URL) -> Bool {
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.isKind(of: UIApplication.self), let imp = r.method(for: sel) {
                typealias OpenFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(imp, to: OpenFn.self)
                open(r, sel, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = r.next
        }
        return false
    }
}

/// Keyboard state: the key layer, shift, and the dictation session as the
/// app reports it.
@MainActor
final class KeyboardModel: ObservableObject {
    enum Layer { case letters, numbers, symbols }

    @Published var layer: Layer = .letters
    @Published var shifted = true
    @Published var capsLock = false
    @Published private(set) var phase: SessionPhase = .off
    @Published private(set) var level: Float = 0
    @Published private(set) var note: String?
    @Published private(set) var hasFullAccess = false
    @Published private(set) var openingApp = false

    private weak var controller: KeyboardViewController?
    private var tokens: [Int32] = []
    private var timer: Timer?
    private var lastSpace: Date?
    private let tap = UIImpactFeedbackGenerator(style: .light)

    init(controller: KeyboardViewController) {
        self.controller = controller
    }

    var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }
    var needsGlobe: Bool { controller?.needsInputModeSwitchKey ?? true }
    var returnLabel: String {
        switch proxy?.returnKeyType {
        case .go: "go"
        case .google, .search, .yahoo: "search"
        case .send: "send"
        case .done: "done"
        case .next: "next"
        case .join: "join"
        case .route: "route"
        case .continue: "continue"
        default: "return"
        }
    }

    var appListening: Bool { phase != .off && Bridge.appIsListening }

    func activate() {
        hasFullAccess = controller?.hasFullAccess ?? false
        tokens.append(Bridge.observe(Bridge.stateChanged) { [weak self] in
            Task { @MainActor in self?.refresh() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        refresh()
        contextChanged()
    }

    func deactivate() {
        tokens.forEach(Bridge.stopObserving)
        tokens.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private var pollCount = 0

    private func poll() {
        pollCount += 1
        if phase == .recording {
            level = Bridge.level
        } else if level != 0 {
            level = 0
        }
        if pollCount % 20 == 0 { refresh() } // pick up a session that timed out
    }

    func refresh() {
        guard hasFullAccess else { phase = .off; return }
        var p = Bridge.phase
        if p != .off && !Bridge.appIsListening { p = .off }
        if p != .off { openingApp = false }
        phase = p
        switch p {
        case .done:
            if let text = Bridge.takeResult() { insertTake(text) }
            note = nil
        case .error:
            note = Bridge.message
        case .idle:
            note = Bridge.message
        default:
            note = nil
        }
    }

    // MARK: Dictation

    func micTapped() {
        guard hasFullAccess else {
            note = "Turn on Allow Full Access for Tiro in Settings → General → Keyboard → Keyboards."
            return
        }
        haptic()
        if appListening {
            switch phase {
            case .recording:
                Bridge.send(.stop)
            case .transcribing:
                break
            default:
                note = nil
                phase = .recording // optimistic; the app confirms within a few ms
                Bridge.send(.start)
            }
            return
        }
        // No live session: open Tiro, which starts one and begins recording.
        Bridge.requestRecordOnOpen()
        if controller?.openContainingApp(URL(string: "tiro://dictate")!) == true {
            openingApp = true
            note = nil
        } else {
            note = "Open the Tiro app once to start listening, then come back."
        }
    }

    func cancelTapped() {
        haptic()
        Bridge.send(.cancel)
    }

    private func insertTake(_ text: String) {
        guard let proxy else { return }
        let fitted = Settings.fitToContext ? ContextFitter.fit(text, before: proxy.documentContextBeforeInput) : text
        proxy.insertText(fitted)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: Typing

    func type(_ s: String) {
        haptic()
        let out = (shifted || capsLock) && layer == .letters ? s.uppercased() : s
        proxy?.insertText(out)
        if shifted && !capsLock { shifted = false }
        lastSpace = nil
    }

    func space() {
        haptic()
        // Double space → ". " like the system keyboard.
        if let last = lastSpace, Date().timeIntervalSince(last) < 0.4,
           let before = proxy?.documentContextBeforeInput, before.hasSuffix(" "),
           let prev = before.dropLast().last, prev.isLetter || prev.isNumber {
            proxy?.deleteBackward()
            proxy?.insertText(". ")
            lastSpace = nil
            shifted = true
            return
        }
        proxy?.insertText(" ")
        lastSpace = Date()
        if layer != .letters { layer = .letters }
        contextChanged()
    }

    func backspace() {
        proxy?.deleteBackward()
        lastSpace = nil
        contextChanged()
    }

    func returnKey() {
        haptic()
        proxy?.insertText("\n")
        contextChanged()
    }

    func toggleShift() {
        haptic()
        if capsLock { capsLock = false; shifted = false } else { shifted.toggle() }
    }

    func capsLockOn() { capsLock = true; shifted = true }

    func contextChanged() {
        guard !capsLock, layer == .letters else { return }
        let before = proxy?.documentContextBeforeInput ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let autoCap = proxy?.autocapitalizationType ?? .sentences
        guard autoCap != UITextAutocapitalizationType.none else { shifted = false; return }
        shifted = trimmed.isEmpty || before.hasSuffix("\n") || (before.hasSuffix(" ") && ".!?".contains(trimmed.last ?? " "))
    }

    func switchKeyboard(from view: UIView, with event: UIEvent) {
        controller?.handleInputModeList(from: view, with: event)
    }

    private func haptic() {
        if hasFullAccess && Settings.haptics { tap.impactOccurred(intensity: 0.6) }
    }
}
