import SwiftUI

@main
struct TiroApp: App {
    @StateObject private var models: ModelStore
    @StateObject private var dictation: Dictation
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Settings.register()
        let m = ModelStore()
        _models = StateObject(wrappedValue: m)
        _dictation = StateObject(wrappedValue: Dictation(models: m))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(models)
                .environmentObject(dictation)
                .onOpenURL { url in
                    // tiro://dictate — sent by the keyboard to start a session.
                    if url.scheme == "tiro", url.host == "dictate" {
                        dictation.openedFromKeyboard()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    dictation.unloadEngine()
                }
        }
    }
}
