import SwiftUI
import CS2LauncherCore

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Параметры запуска") {
                TextField("Аргументы игры", text: $state.settings.gameArgs)
                note("Флаг -vulkan добавляется автоматически; чтобы использовать DirectX 11, укажите -dx11.")
                TextField("Аргументы Steam", text: $state.settings.steamArgs)
                TextField("Ограничение FPS", value: $state.settings.fpsCap, format: .number,
                          prompt: Text("Без ограничения"))
                Text("Пустое поле — без ограничения. Добавляется как +fps_max.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Графика и совместимость") {
                Toggle("Metal HUD", isOn: $state.settings.metalHUD)
                note("Показывает FPS и нагрузку GPU поверх игры.")
                Toggle("Retina-режим", isOn: $state.settings.retinaMode)
                note("Рендер в полном разрешении экрана. Красивее, но заметно тяжелее.")
                Toggle("MSync", isOn: $state.settings.msync)
                note("Быстрая синхронизация Wine на macOS. Обычно стоит оставить включённой.")
                Toggle("Сообщать поддержку AVX", isOn: $state.settings.advertiseAVX)
                note("Нужно, чтобы игра запускалась под Rosetta 2. Отключайте только при проблемах.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }
}

#Preview {
    SettingsView().environment(AppState(backend: PreviewBackend()))
}
