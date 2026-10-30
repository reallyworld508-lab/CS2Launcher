import SwiftUI
import UniformTypeIdentifiers
import CS2LauncherCore

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Настройка")
                    .font(.largeTitle.bold())
                Text("Несколько шагов, и Counter-Strike 2 запустится на вашем Mac.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
                ForEach(SetupStep.allCases) { step in
                    StepRow(step: step, importing: $importing)
                    if step != SetupStep.allCases.last { Divider() }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.diskImage]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                state.chooseGPTK(url: url)
                if scoped { /* sandbox is off; keep access for the install task */ }
            }
        }
    }
}

private struct StepRow: View {
    @Environment(AppState.self) private var state
    let step: SetupStep
    @Binding var importing: Bool

    var body: some View {
        let status = state.status(step)
        let unlocked = state.isUnlocked(step)
        HStack(alignment: .top, spacing: 14) {
            statusIcon(status)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.headline)
                Text(step.explanation).font(.callout).foregroundStyle(.secondary)
                detail(status)
            }
            Spacer(minLength: 12)
            actions(status, unlocked: unlocked)
        }
        .padding(.vertical, 10)
        .opacity(unlocked || status.isDone ? 1 : 0.5)
    }

    @ViewBuilder private func statusIcon(_ s: StepStatus) -> some View {
        switch s {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title2)
        case .running: ProgressView().controlSize(.small)
        case .pending: Image(systemName: step.icon).foregroundStyle(.secondary).font(.title2)
        }
    }

    @ViewBuilder private func detail(_ s: StepStatus) -> some View {
        switch s {
        case .running(let p):
            if let p { ProgressView(value: p).frame(maxWidth: 260) }
            else { Text("Выполняется…").font(.caption).foregroundStyle(.secondary) }
        case .failed(let m):
            Text(m).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        case .done:
            Text("Готово").font(.caption).foregroundStyle(.green)
        case .pending:
            if step == .gptk, let url = state.gptkImage {
                Text("Найден: \(url.path)").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder private func actions(_ s: StepStatus, unlocked: Bool) -> some View {
        let busy = s.isRunning
        HStack {
            switch step {
            case .systemCheck:
                Button("Проверить") { Task { await state.runSystemCheck() } }
                    .disabled(busy)
            case .wine:
                if !s.isDone {
                    Button(failed(s) ? "Повторить" : "Установить") { state.installWine() }
                        .disabled(busy || !unlocked)
                }
            case .gptk:
                if !s.isDone {
                    if let url = state.gptkImage {
                        Button("Использовать") { state.chooseGPTK(url: url) }
                            .disabled(busy || !unlocked)
                    }
                    Button("Выбрать .dmg…") { importing = true }
                        .disabled(busy || !unlocked)
                }
            case .prefix:
                if !s.isDone {
                    Button(failed(s) ? "Повторить" : "Создать") { state.createPrefix() }
                        .disabled(busy || !unlocked)
                }
            case .steam:
                if !s.isDone {
                    Button(failed(s) ? "Повторить" : "Установить") { state.installSteam() }
                        .disabled(busy || !unlocked)
                }
            case .cs2:
                if !s.isDone {
                    Button("Открыть Steam") { state.openSteam() }
                        .disabled(state.isGameRunning || !unlocked)
                    Button("Проверить снова") { state.refresh() }
                        .disabled(!unlocked)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func failed(_ s: StepStatus) -> Bool { if case .failed = s { true } else { false } }
}

#Preview {
    OnboardingView().environment(AppState(backend: PreviewBackend())).frame(width: 760, height: 560)
}
