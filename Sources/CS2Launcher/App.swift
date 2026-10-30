import SwiftUI
import CS2LauncherCore

@main
struct CS2LauncherApp: App {
    @State private var state = AppState(backend: makeBackend())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .frame(minWidth: 760, minHeight: 520)
                .task { await state.start() }
        }
        Settings {
            SettingsView()
                .environment(state)
        }
    }
}
