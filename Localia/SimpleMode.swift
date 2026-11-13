import Foundation
import LocaliaCore
import SwiftUI

// Simple mode's view of AppModel: the panel status in plain words, the plain-language errors, the three
// recommended models and the installed-model chooser. Everything here only reads AppModel; the actions
// are AppModel's own (install, download, setDefault, launch).

/// What simple mode tells the user to do when something fails: one sentence, no technical cause.
enum SimpleHint: Equatable {
    case tryAgain
    case checkConnection
    case freeMemory
    case lighterModel
    case setUp
    case installClaude
    case closeOtherSession
    case cloudLogin
    case noModelFits
}

/// A problem as simple mode shows it: a short title, one actionable sentence, and the technical text
/// (advanced mode shows it; simple mode keeps it as a tooltip).
struct SimpleIssue: Equatable {
    let hint: SimpleHint
    var heavyApps: [String] = []
    var detail: String? = nil

    var title: String {
        switch hint {
        case .tryAgain: String(localized: "Something went wrong")
        case .checkConnection: String(localized: "The download did not finish")
        case .freeMemory: String(localized: "Not enough free memory")
        case .lighterModel: String(localized: "This model is too big for now")
        case .setUp: String(localized: "Not set up yet")
        case .installClaude: String(localized: "Claude is not installed")
        case .closeOtherSession: String(localized: "Your AI is busy")
        case .cloudLogin: String(localized: "Claude may ask you to sign in")
        case .noModelFits: String(localized: "No AI model fits this Mac")
        }
    }

    var sentence: String {
        switch hint {
        case .tryAgain: return String(localized: "Try again in a moment.")
        case .checkConnection: return String(localized: "Check your internet connection, then try again.")
        case .freeMemory:
            guard !heavyApps.isEmpty else { return String(localized: "Quit some apps to free memory, then try again.") }
            let apps = heavyApps.formatted(.list(type: .and).locale(Fmt.appLocale))
            return String(localized: "Quit \(apps) to free memory, then try again.")
        case .lighterModel: return String(localized: "Choose a lighter model.")
        case .setUp: return String(localized: "Click Set Up to get your AI ready.")
        case .installClaude: return String(localized: "Click Set Up to install Claude.")
        case .closeOtherSession: return String(localized: "Close the other Claude window, then try again.")
        case .cloudLogin: return String(localized: "To work without an account, turn on Local mode.")
        case .noModelFits: return String(localized: "Claude can still use Anthropic's cloud: leave Local mode off.")
        }
    }
}

extension AppAlert {
    /// The alert as simple mode shows it: the hint's title and sentence (generic "Try again" when the site
    /// set none), the action kept. The technical message is dropped.
    func simplified(heavyApps: [String]) -> AppAlert {
        let issue = SimpleIssue(hint: hint ?? .tryAgain, heavyApps: heavyApps, detail: message)
        return AppAlert(title: issue.title, message: issue.sentence, action: action, hint: hint)
    }
}

/// Steps of the first run still to do when it started.
struct SimpleSetupPlan: Equatable {
    var engine = false
    var claude = false
    var model = true
}

enum SimpleSetupStep: Equatable { case engine, claude, model }

enum SimpleSetupPhase: Equatable {
    case idle
    case running(SimpleSetupStep)
    case failed(SimpleIssue)
    case done
}

/// The status card of the simple panel.
enum SimpleStatus: Equatable {
    case notSetUp
    /// The first run or a model download. `fraction` nil: not known yet.
    case downloading(fraction: Double?, detail: String)
    case starting
    case ready(name: String, speed: SpeedBucket?)
    case needsAttention(SimpleIssue)

    /// Coarse kind, for the panel's layout signature.
    var kind: String {
        switch self {
        case .notSetUp: "notSetUp"
        case .downloading: "downloading"
        case .starting: "starting"
        case .ready: "ready"
        case .needsAttention: "attention"
        }
    }
}

extension SpeedBucket {
    var title: String {
        switch self {
        case .fast: String(localized: "Fast")
        case .ok: String(localized: "OK")
        case .slow: String(localized: "Slow")
        }
    }

    var symbol: String {
        switch self {
        case .fast: "hare.fill"
        case .ok: "gauge.with.dots.needle.50percent"
        case .slow: "tortoise.fill"
        }
    }

    var tint: Color {
        switch self {
        case .fast: Theme.local
        case .ok: Theme.slate
        case .slow: Theme.orange
        }
    }
}

extension MemoryBucket {
    var title: String {
        switch self {
        case .enough: String(localized: "Enough memory")
        case .tight: String(localized: "Memory is tight")
        case .notEnough: String(localized: "Not enough memory")
        }
    }

    var tint: Color {
        switch self {
        case .enough: Theme.local
        case .tight: Theme.orange
        case .notEnough: Theme.red
        }
    }
}

extension AppModel {
    var isSimpleMode: Bool { !settings.advancedMode }

    /// "Qwen3 8B" for a served name, through its llmfit id when Localia downloaded it.
    func friendlyName(for served: String) -> String { ModelDisplayName.human(candidateID(for: served)) }

    func friendlyName(for c: ModelCandidate) -> String { ModelDisplayName.human(c.id) }

    func speedBucket(for served: String) -> SpeedBucket? {
        tokensPerSecond(for: served).map { SpeedBucket(tokensPerSecond: $0.value) }
    }

    /// Memory word of a recommendation, against what models may use on this Mac.
    func memoryBucket(for c: ModelCandidate) -> MemoryBucket {
        MemoryBucket(requiredGB: c.memoryGB, availableGB: profile.usablePoolGB)
    }

    /// The step the first run is on, nil when it is not running.
    var simpleSetupStep: SimpleSetupStep? {
        if case let .running(step) = simpleSetup { return step }
        return nil
    }

    /// The single progress bar of the first run, over the steps it had to do.
    var simpleSetupFraction: Double {
        var steps: [SetupProgress.Step] = []
        let plan = simpleSetupPlan
        let step = simpleSetupStep
        if plan.engine {
            let f = step == .engine ? engineInstallProgress[settings.activeEngine] ?? 0 : 1
            steps.append(.init(weight: SetupProgress.engineWeight, fraction: f))
        }
        if plan.claude {
            let f: Double = step == .engine || step == .claude ? 0 : 1
            steps.append(.init(weight: SetupProgress.claudeWeight, fraction: f))
        }
        if plan.model {
            var f: Double = 0
            if step == .model, let pick = simpleSetupPick {
                f = installedName(for: pick) != nil ? 1 : downloads[pick.id]?.fraction ?? 0
            } else if step == nil {
                f = 1
            }
            steps.append(.init(weight: SetupProgress.modelWeight, fraction: f))
        }
        return SetupProgress.fraction(steps)
    }

    /// What the first run is doing, in plain words.
    var simpleSetupDetail: String {
        guard case let .running(step) = simpleSetup else { return "" }
        switch step {
        case .engine: return String(localized: "Getting things ready…")
        case .claude: return String(localized: "Installing Claude…")
        case .model:
            guard let pick = simpleSetupPick else { return String(localized: "Choosing the best model for this Mac…") }
            return String(localized: "Downloading \(friendlyName(for: pick))…")
        }
    }

    /// The panel's status card. Order: the first run, its failure, a download, nothing installed, a load in
    /// progress, Claude missing, memory, then ready.
    var simpleStatus: SimpleStatus {
        switch simpleSetup {
        case .running:
            // The title already says "Downloading…": the model's name alone once it is known.
            let detail = simpleSetupStep == .model ? simpleSetupPick.map(friendlyName(for:)) : nil
            return .downloading(fraction: simpleSetupFraction, detail: detail ?? simpleSetupDetail)
        case let .failed(issue): return .needsAttention(issue)
        case .idle, .done: break
        }
        if let d = downloads.values.sorted(by: { $0.candidateID < $1.candidateID }).first {
            return .downloading(fraction: d.fraction, detail: ModelDisplayName.human(d.candidateID))
        }
        guard !installed.isEmpty, let served = selectedModel else { return .notSetUp }
        if switchingLocalMode || busyMessage != nil { return .starting }
        if claudeChecked, claudePath == nil { return .needsAttention(SimpleIssue(hint: .installClaude)) }
        if let issue = memoryIssue(for: served) { return .needsAttention(issue) }
        return .ready(name: friendlyName(for: served), speed: speedBucket(for: served))
    }

    /// A model that is not in memory and will not fit: bigger than what models may use (choose a lighter
    /// one), or bigger than the free memory while memory-hungry apps are open (quit them).
    func memoryIssue(for served: String) -> SimpleIssue? {
        guard !loaded.contains(where: { $0.name == served }) else { return nil }
        let needed = requiredGB(for: served, engine: settings.activeEngine)
        if MemoryBucket(requiredGB: needed, availableGB: profile.usablePoolGB) == .notEnough {
            return SimpleIssue(hint: .lighterModel)
        }
        if needed > freeGB, !heavyApps.isEmpty { return SimpleIssue(hint: .freeMemory, heavyApps: heavyApps) }
        return nil
    }

    /// The panel's chooser: installed models with one row per human name, the active engine's first (the same
    /// model on two engines would otherwise be listed twice under one name).
    var simpleModelChoices: [InstalledRow] {
        let active = installed.filter { $0.engine == settings.activeEngine }
        let others = installed.filter { $0.engine != settings.activeEngine }
        var seen = Set<String>()
        return (active + others).filter { seen.insert(friendlyName(for: $0.name)).inserted }
    }

    /// The three models of the simple Models window, from the current recommendation.
    var simplePicks: SimplePicks { recommendation.map(SimplePicks.choose) ?? SimplePicks() }
}
