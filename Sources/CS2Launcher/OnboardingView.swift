import SwiftUI
import CS2LauncherCore

struct OnboardingView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Настройка")
                    .font(.largeTitle.bold())
                Text("Несколько шагов, и Counter-Strike 2 запустится на вашем Mac.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
                if !state.statusText.isEmpty {
                    HStack(spacing: 8) {
                        if state.isBusy { ProgressView().controlSize(.small) }
                        Text(state.statusText).font(.headline)
                    }
                    .padding(.bottom, 12)
                }
                installAllPanel
                ForEach(SetupStep.allCases) { step in
                    StepRow(step: step)
                    if step != SetupStep.allCases.last { Divider() }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

extension OnboardingView {
    @ViewBuilder var installAllPanel: some View {
        if state.isInstallingAll || state.setupFailure != nil || state.hasPendingAutomaticSteps {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        state.installAll()
                    } label: {
                        Label(state.setupFailure != nil ? "Повторить" : "Установить всё",
                              systemImage: state.setupFailure != nil ? "arrow.clockwise" : "bolt.fill")
                            .font(.headline)
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(state.isInstallingAll || state.isBusy)
                    if !state.isInstallingAll && state.setupFailure == nil {
                        Text("Проверка, Wine, префикс, Steam — автоматически (загрузки ~250 МБ).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if state.isInstallingAll {
                    Text(state.setupProgressText).font(.headline)
                    ProgressView(value: state.overallSetupProgress).frame(maxWidth: 420)
                }
                if let f = state.setupFailure {
                    Text("Остановлено на шаге «\(f.stage.title)»: \(f.message)")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(.bottom, 14)
        }
    }
}

private struct StepRow: View {
    @Environment(AppState.self) private var state
    let step: SetupStep

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
        case .running(let p) where step == .cs2:
            Text("Скачивается: \(Int(((p ?? 0) * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: p ?? 0).frame(maxWidth: 260)
        case .running(let p):
            if let p { ProgressView(value: p).frame(maxWidth: 260) }
            else { Text("Выполняется…").font(.caption).foregroundStyle(.secondary) }
        case .failed(let m):
            Text(m).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        case .done:
            Text("Готово").font(.caption).foregroundStyle(.green)
        case .pending:
            EmptyView()
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
            case .prefix:
                if !s.isDone {
                    if state.prefixNeedsUpdate {
                        Button(failed(s) ? "Повторить" : "Обновить") { state.updatePrefix() }
                            .disabled(busy || !unlocked)
                    } else {
                        Button(failed(s) ? "Повторить" : "Создать") { state.createPrefix() }
                            .disabled(busy || !unlocked)
                    }
                }
            case .steam:
                if !s.isDone {
                    Button(failed(s) ? "Повторить" : "Установить") { state.installSteam() }
                        .disabled(busy || !unlocked)
                }
            case .cs2:
                if !s.isDone {
                    Button("Открыть Steam") { state.openSteam() }
                        .disabled(state.isSteamRunning || state.isLaunching || !unlocked)
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
