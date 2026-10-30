import SwiftUI
import CS2LauncherCore

struct MainView: View {
    @Environment(AppState.self) private var state
    @Binding var showLog: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "scope")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Counter-Strike 2").font(.largeTitle.bold())

            Button {
                state.play()
            } label: {
                Label("Играть", systemImage: "play.fill")
                    .font(.title2.bold())
                    .frame(width: 220, height: 36)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .disabled(state.isLaunching)
            .keyboardShortcut(.defaultAction)

            HStack {
                Button("Стоп", systemImage: "stop.fill") { state.stop() }
                    .disabled(!(state.isSteamRunning || state.isLaunching))
                Button("Открыть Steam", systemImage: "gamecontroller") { state.openSteam() }
                    .disabled(state.isSteamRunning || state.isLaunching)
            }

            HStack(spacing: 6) {
                if state.isBusy { ProgressView().controlSize(.small) }
                Text(state.statusText.isEmpty ? idleText : state.statusText)
                    .font(state.isBusy ? .headline : .body)
                    .foregroundStyle(state.isBusy ? .primary : .secondary)
            }

            summary
            Button("Показать журнал") { showLog = true }
                .buttonStyle(.link)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var idleText: String {
        if state.gameLaunched { return "Игра запущена" }
        return state.isSteamRunning ? "Steam запущен" : "Готово к игре"
    }

    private var summary: some View {
        let s = state.settings
        let items: [(String, Bool)] = [
            ("Metal HUD", s.metalHUD), ("Retina", s.retinaMode), ("MSync", s.msync), ("AVX", s.advertiseAVX),
        ]
        return HStack(spacing: 14) {
            ForEach(items, id: \.0) { item in
                Label(item.0, systemImage: item.1 ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(item.1 ? Color.green : Color.secondary)
            }
            if let fps = s.fpsCap {
                Label("FPS ≤ \(fps)", systemImage: "speedometer").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var state
    @State private var showSetup = false
    @State private var showLog = false

    var body: some View {
        Group {
            if state.isSetupComplete && !showSetup {
                MainView(showLog: $showLog)
            } else {
                OnboardingView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if state.isSetupComplete {
                    Button(showSetup ? "К игре" : "Настройка",
                           systemImage: showSetup ? "play.circle" : "list.bullet.clipboard") {
                        showSetup.toggle()
                    }
                }
                Button("Журнал", systemImage: "text.alignleft") { showLog = true }
            }
        }
        .sheet(isPresented: $showLog) {
            LogView()
                .frame(minWidth: 640, minHeight: 420)
        }
    }
}

#Preview {
    RootView().environment(AppState(backend: PreviewBackend())).frame(width: 760, height: 520)
}
