import Foundation

public enum SetupStage: String, CaseIterable, Sendable {
    case systemCheck, rosetta, engine, gptk, prefix, crossOver, bottle, steam, openSteam, cs2
}

public struct SetupResult: Equatable, Sendable {
    public var completed: [SetupStage]
    public var failed: SetupStage?
    public var cancelled: Bool
    public var succeeded: Bool { failed == nil && !cancelled }
}

/// Pure ordering/skip logic for "Install everything".
public enum SetupPlanner {
    /// Stages the one-click setup performs, in order. CS2 itself is downloaded by Steam, not by us.
    /// `.gptk` is a user action (Apple's download); its stage stops the run until the toolkit is in place.
    public static let automatic: [SetupStage] = automatic(for: .free)

    public static func automatic(for engine: EngineKind) -> [SetupStage] {
        switch engine {
        case .free: [.systemCheck, .rosetta, .engine, .gptk, .prefix, .steam, .openSteam]
        case .crossover: [.systemCheck, .rosetta, .crossOver, .bottle, .steam, .openSteam]
        }
    }

    /// Automatic stages still to do (already completed ones are skipped; order preserved).
    /// A retry after a failure is simply a fresh plan: finished stages drop out, the failed one comes first.
    public static func plan(completed: Set<SetupStage>, engine: EngineKind = .free) -> [SetupStage] {
        automatic(for: engine).filter { !completed.contains($0) }
    }

    /// Setup is complete when everything needed to play exists (the system check is advisory).
    public static func isComplete(_ completed: Set<SetupStage>, engine: EngineKind = .free) -> Bool {
        let needed: [SetupStage] = engine == .free ? [.engine, .gptk, .prefix, .steam, .cs2]
                                                   : [.crossOver, .bottle, .steam, .cs2]
        return needed.allSatisfy(completed.contains)
    }

    /// Overall 0...1 progress for step `index` (0-based) of `total` with the current step at `stepProgress`.
    public static func overallProgress(index: Int, total: Int, stepProgress: Double?) -> Double {
        guard total > 0 else { return 0 }
        let p = max(0, min(1, stepProgress ?? 0))
        return max(0, min(1, (Double(index) + p) / Double(total)))
    }

    /// Runs `plan` in order, stopping at the first stage whose `step` returns false.
    public static func execute(plan: [SetupStage],
                               onStart: (Int, SetupStage) async -> Void = { _, _ in },
                               step: (SetupStage) async -> Bool) async -> SetupResult {
        var done: [SetupStage] = []
        for (i, stage) in plan.enumerated() {
            if Task.isCancelled { return SetupResult(completed: done, failed: nil, cancelled: true) }
            await onStart(i, stage)
            if await step(stage) { done.append(stage) }
            else { return SetupResult(completed: done, failed: stage, cancelled: false) }
        }
        return SetupResult(completed: done, failed: nil, cancelled: false)
    }
}
