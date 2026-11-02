import SwiftUI
import CS2LauncherCore

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Параметры запуска") {
                TextField("Аргументы игры", text: $state.settings.gameArgs)
                note("Игра запускается с D3DMetal и DirectX 11, дополнительные флаги не нужны. Размер окна задаётся ниже и заменяет -w/-h.")
                TextField("Аргументы Steam", text: $state.settings.steamArgs)
                TextField("Ограничение FPS", value: $state.settings.fpsCap, format: .number,
                          prompt: Text("Без ограничения"))
                Text("Пустое поле — без ограничения. Добавляется как +fps_max.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Производительность") {
                Toggle("Режим производительности", isOn: $state.settings.performanceMode)
                note("Отключает оверлей Steam для CS2 и фоновые проверки лаунчера во время игры")
                Toggle("Фоновые приложения — на энергоэффективные ядра", isOn: $state.settings.throttleBackgroundApps)
                note("Пока идёт игра, Chrome, Discord, Telegram и др. получают фоновый приоритет macOS (taskpolicy -b) и уходят на E-ядра; после игры приоритет возвращается")
            }
            Section("Движок") {
                Picker("Wine", selection: $state.settings.engine) {
                    Text("Бесплатный движок").tag(EngineKind.free)
                    Text("CrossOver").tag(EngineKind.crossover)
                }
                note("Бесплатный движок собран из исходников CrossOver и работает без лицензии. CrossOver нужен только если он уже установлен.")
            }
            Section("Графика") {
                Toggle("Родное разрешение 16:10", isOn: $state.settings.nativeAspect)
                if !state.settings.nativeAspect {
                    TextField("Ширина окна", value: $state.settings.windowWidth, format: .number)
                    TextField("Высота окна", value: $state.settings.windowHeight, format: .number)
                    note("Картинка 4:3 растягивается на всё окно. По умолчанию 1024×768.")
                }
                Button("Применить рекомендуемую графику") { state.applyRecommendedGraphics() }
                    .disabled(state.engineKind != .free)
                note("Записывает в cs2_video.txt настройки для быстрой игры. Нужен хотя бы один вход в Steam; сам лаунчер делает это один раз при первом запуске.")
                Toggle("Metal HUD", isOn: $state.settings.metalHUD)
                note("Показывает FPS и нагрузку GPU поверх игры.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }
}

#Preview {
    SettingsView().environment(AppState(backend: PreviewBackend()))
}
