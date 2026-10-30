import SwiftUI
import CS2LauncherCore

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Параметры запуска") {
                TextField("Аргументы игры", text: $state.settings.gameArgs)
                note("Игра запускается через CrossOver с D3DMetal и DirectX 11, дополнительные флаги не нужны.")
                TextField("Аргументы Steam", text: $state.settings.steamArgs)
                TextField("Ограничение FPS", value: $state.settings.fpsCap, format: .number,
                          prompt: Text("Без ограничения"))
                Text("Пустое поле — без ограничения. Добавляется как +fps_max.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Производительность") {
                Toggle("Режим производительности", isOn: $state.settings.performanceMode)
                note("Отключает оверлей Steam для CS2 и фоновые проверки лаунчера во время игры")
            }
            Section("Графика") {
                Toggle("Metal HUD", isOn: $state.settings.metalHUD)
                note("Показывает FPS и нагрузку GPU поверх игры.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 430)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }
}

#Preview {
    SettingsView().environment(AppState(backend: PreviewBackend()))
}
