import AppKit
import AVFoundation
import Darwin
import Foundation
import SwiftUI

struct SessionLine: Decodable {
    struct Message: Decodable {
        struct ContentItem: Decodable {
            let type: String
            let id: String?
            let name: String?
            let text: String?
        }

        let role: String?
        let content: [ContentItem]?
        let toolCallId: String?
        let stopReason: String?
    }

    let type: String
    let timestamp: String?
    let message: Message?
}

enum OverlayState: Equatable {
    case idle
    case thinking
    case taskStarting
    case tooling
    case completed
    case sleeping
}

struct AppConfig {
    let openClawRoot: String
    let assetsDir: String
    let quickPromptsPath: String
    let adminURL: URL
    let activeWindowSeconds: TimeInterval
    let gatewayURL: URL
    let gatewayToken: String?
    let openClawStartScript: String?

    static func load() -> AppConfig {
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let cwd = FileManager.default.currentDirectoryPath
        let explicitAssets = env["DESK_SPRITE_ASSETS"]
        let quickPromptsPath = env["DESK_SPRITE_CONSOLE_CONFIG"] ?? "\(cwd)/console_config.json"
        let adminPort = env["DESK_SPRITE_CONSOLE_PORT"] ?? "17890"
        let adminURL = URL(string: env["DESK_SPRITE_CONSOLE_URL"] ?? "http://127.0.0.1:\(adminPort)/") ??
            URL(string: "http://127.0.0.1:17890/")!
        let pickedAssets = resolveAssetsDir(explicitAssets: explicitAssets, cwd: cwd)

        let rootCandidates: [String] = [
            env["OPENCLAW_ROOT"] ?? "",
            "\(home)/.openclaw",
            "\(home)/Openclaw_Workspace",
            "\(home)/OpenClaw"
        ]
        let root = rootCandidates.first { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) } ??
            (env["OPENCLAW_ROOT"] ?? "\(home)/.openclaw")
        let gatewayURL = URL(string: env["OPENCLAW_GATEWAY_URL"] ?? "ws://127.0.0.1:18789") ?? URL(string: "ws://127.0.0.1:18789")!
        let gatewayEnv = mergedGatewayEnvironment(primaryRoot: root, home: home, processEnv: env)
        let explicitToken = resolveGatewayTokenCandidate(env["OPENCLAW_GATEWAY_TOKEN"], env: gatewayEnv)
        let discoveredToken = explicitToken ?? discoverGatewayToken(primaryRoot: root, home: home, gatewayEnv: gatewayEnv)

        return AppConfig(
            openClawRoot: root,
            assetsDir: pickedAssets,
            quickPromptsPath: quickPromptsPath,
            adminURL: adminURL,
            activeWindowSeconds: Double(env["OPENCLAW_ACTIVE_WINDOW_SECONDS"] ?? "20") ?? 20,
            gatewayURL: gatewayURL,
            gatewayToken: discoveredToken,
            openClawStartScript: env["OPENCLAW_START_SCRIPT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func resolveAssetsDir(explicitAssets: String?, cwd: String) -> String {
        let required = [
            "intro-seed.mov",
            "idle-core.mov",
            "focus-loop.mov",
            "work-in.mov",
            "work-loop.mov",
            "work-out.mov",
            "nap-in.mov",
            "nap-loop.mov",
            "nap-out.mov",
            "nap-to-deep.mov",
            "deep-loop.mov",
            "deep-to-nap.mov",
            "deep-out.mov"
        ]

        func containsAssets(at path: String) -> Bool {
            for name in required {
                if FileManager.default.fileExists(atPath: "\(path)/\(name)") {
                    return true
                }
            }
            return false
        }

        func addCandidate(_ value: String?, to list: inout [String], seen: inout Set<String>) {
            guard let value, !value.isEmpty else { return }
            let normalized = URL(fileURLWithPath: value).path
            guard !seen.contains(normalized) else { return }
            seen.insert(normalized)
            list.append(normalized)
        }

        var candidates: [String] = []
        var seen: Set<String> = []

        addCandidate(explicitAssets, to: &candidates, seen: &seen)

        let cwdURL = URL(fileURLWithPath: cwd)
        addCandidate(cwdURL.appendingPathComponent("media").path, to: &candidates, seen: &seen)
        addCandidate(cwdURL.deletingLastPathComponent().appendingPathComponent("media").path, to: &candidates, seen: &seen)
        addCandidate(cwdURL.appendingPathComponent("assets").path, to: &candidates, seen: &seen)

        if let binaryPath = CommandLine.arguments.first, !binaryPath.isEmpty {
            var dirURL = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()
            for _ in 0..<6 {
                addCandidate(dirURL.appendingPathComponent("media").path, to: &candidates, seen: &seen)
                addCandidate(dirURL.deletingLastPathComponent().appendingPathComponent("media").path, to: &candidates, seen: &seen)
                dirURL.deleteLastPathComponent()
            }
        }

        for candidate in candidates where containsAssets(at: candidate) {
            return candidate
        }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }

        let fallback = cwdURL.deletingLastPathComponent().appendingPathComponent("media").path
        return fallback
    }

    private static func discoverGatewayToken(primaryRoot: String, home: String, gatewayEnv: [String: String]) -> String? {
        let candidates = [
            "\(primaryRoot)/openclaw.json",
            "\(home)/.openclaw/openclaw.json"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            guard
                let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let gateway = raw["gateway"] as? [String: Any]
            else { continue }

            if
                let auth = gateway["auth"] as? [String: Any],
                let token = resolveGatewayTokenCandidate(auth["token"] as? String, env: gatewayEnv)
            {
                return token
            }

            if
                let remote = gateway["remote"] as? [String: Any],
                let token = resolveGatewayTokenCandidate(remote["token"] as? String, env: gatewayEnv)
            {
                return token
            }
        }
        return resolveGatewayTokenCandidate(gatewayEnv["OPENCLAW_GATEWAY_TOKEN"], env: gatewayEnv)
    }

    private static func mergedGatewayEnvironment(primaryRoot: String, home: String, processEnv: [String: String]) -> [String: String] {
        // Use the same precedence as common dotenv loaders: .env < .env.local < process env.
        let dotenvCandidates = [
            "\(home)/.openclaw/.env",
            "\(home)/.openclaw/.env.local",
            "\(primaryRoot)/.env",
            "\(primaryRoot)/.env.local"
        ]

        var merged: [String: String] = [:]
        for path in dotenvCandidates where FileManager.default.fileExists(atPath: path) {
            let parsed = parseDotEnv(at: path)
            for (key, value) in parsed {
                merged[key] = value
            }
        }
        for (key, value) in processEnv {
            merged[key] = value
        }
        return merged
    }

    private static func resolveGatewayTokenCandidate(_ rawValue: String?, env: [String: String]) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }

        if value.hasPrefix("${"), value.hasSuffix("}"), value.count > 3 {
            let key = String(value.dropFirst(2).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            let resolved = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return resolved.isEmpty ? nil : resolved
        }

        if value.hasPrefix("$"), value.count > 1, !value.contains(" ") {
            let key = String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            let resolved = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return resolved.isEmpty ? nil : resolved
        }

        return value
    }

    private static func parseDotEnv(at path: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }

        var result: [String: String] = [:]
        for rawLine in content.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count))
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }

            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if let commentIndex = value.firstIndex(of: "#") {
                value = String(value[..<commentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !value.isEmpty else { continue }

            result[key] = value
        }
        return result
    }
}

final class OverlayViewModel: ObservableObject {
    private let mainSessionKey = "agent:main:main"
    private let webSyncSessionKey = "main"

    @Published var overlayState: OverlayState = .idle
    @Published var bubbleVisible: Bool = false
    @Published var bubbleText: String = ""
    @Published var bubbleTools: [String] = []
    @Published var bubbleSingleLine: Bool = false
    @Published var bubbleLoadingOnly: Bool = false
    @Published var quickPromptText: String = "开始任务"
    @Published var quickPromptPrev2Text: String = ""
    @Published var quickPromptPrevText: String = ""
    @Published var quickPromptNextText: String = ""
    @Published var quickPromptNext2Text: String = ""
    @Published var quickPromptIcon: String = "sparkles"
    @Published var quickPromptToken: Int = 0
    @Published var quickPromptDirection: Int = 1
    @Published var quickPromptScrollProgress: CGFloat = 0
    @Published var quickPromptVisible: Bool = true
    @Published var openClawRunning: Bool = false
    @Published var openClawServiceActionInProgress: Bool = false

    let config: AppConfig

    private let monitorQueue = DispatchQueue(label: "sprite.monitor")
    private let sessionsDir: URL
    private var timer: DispatchSourceTimer?
    private var wsSession: URLSession?
    private var wsTask: URLSessionWebSocketTask?
    private var wsConnected = false
    private var wsLastEventAt: Date?
    private var wsActiveRuns: Set<String> = []
    private var wsToolingRuns: Set<String> = []
    private var wsConnectRequestId: String?
    private var wsLastPingAt: Date?
    private var reconnectWorkItem: DispatchWorkItem?
    private var stateCache: OverlayState = .idle
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private var fallbackSessionId: String?
    private var fallbackSessionKey: String?
    private var latestMainSessionKey: String = "agent:main:main"
    private var trackedSessionIds: Set<String> = []
    private var filePhase: OverlayState = .idle
    private var lastActivityAt: Date = Date()
    private var latestThinkingText: String = ""
    private var latestOutputText: String = ""
    private var latestOutputAt: Date?
    private var lastOutputEnqueuedAt: Date?
    private var lastOutputSnapshotText: String = ""
    private var lastCompletionAt: Date?
    private var lastCompletedRunId: String?
    private var lastRunStartedAt: Date?
    private var suppressToolAfterCompletion = false
    private var outputQueue: [String] = []
    private var outputDisplayText: String = ""
    private var outputDisplayAt: Date?
    private var outputDisplayDuration: TimeInterval = 0
    private var toolingDisplayText: String = ""
    private var toolingDisplayAt: Date?
    private var lastBubbleState: OverlayState = .idle
    private var completedBubbleExitAt: Date?
    private var latestToolNames: [String] = []
    private var workflowLines: [String] = []
    private var pendingSubagentChildKeys: Set<String> = []
    private var taskStartingUntil: Date?
    private var wsRunTouchedAt: [String: Date] = [:]
    private var wsToolCallsByRun: [String: Set<String>] = [:]
    private var wsToolTouchedAt: [String: Date] = [:]
    private var completedUntil: Date?
    private let completedBubbleSeconds: TimeInterval = 15.0
    private let sleepStartAfterIdleSeconds: TimeInterval = 10.0
    private let awaitingAssistantAfterUserSeconds: TimeInterval = 20.0
    private let activeRunSilenceHoldSeconds: TimeInterval = 14.0
    private let outputCharsPerSecond: Double = 10.0
    private let outputFreshWindowSeconds: TimeInterval = 30.0
    private let toolingMinDisplaySeconds: TimeInterval = 1.4
    private var lastToolSignalAt: Date?
    private var quickPromptPool: [String] = []
    private var quickPromptIndex: Int = 0
    private var quickPromptLastRotateAt: Date = .distantPast
    private let quickPromptRotateSeconds: TimeInterval = 10
    private let quickPromptIcons: [String] = [
        "sparkles",
        "wand.and.stars",
        "dice.fill",
        "shuffle",
        "bolt.fill",
        "lightbulb.fill",
        "paperplane.fill",
        "scribble.variable",
        "target",
        "scope"
    ]
    private var pendingQuickPromptToSend: String?
    private var quickPromptCurrentIcon: String = "sparkles"
    private var quickPromptHovering = false
    private var quickPromptScrollAccumulator: CGFloat = 0
    private var quickPromptScrollEventMonitor: Any?
    private var quickPromptScrollResetWorkItem: DispatchWorkItem?
    private var quickPromptLastDirection: Int = 1
    private let quickPromptRevealDelaySeconds: TimeInterval = 0.45
    private var quickPromptInFlightCache: Bool = false
    private var quickPromptIdleSince: Date?
    private var quickPromptVisibleCache: Bool = true
    private let openClawControlQueue = DispatchQueue(label: "sprite.openclaw.control", qos: .utility)
    private let openClawGatewayPort = 18789
    private let openClawHealthCheckInterval: TimeInterval = 5
    private var lastOpenClawHealthCheckAt: Date = .distantPast
    private var openClawRunningCache: Bool = false
    private var openClawServiceActionInProgressCache: Bool = false
    private struct PendingChatRequest {
        let message: String
        let sessionKey: String
        let mainFallbackTried: Bool
    }
    private var pendingChatRequests: [String: PendingChatRequest] = [:]

    private struct FileInsights {
        let phase: OverlayState
        let thinkingText: String
        let outputText: String
        let outputAt: Date?
        let latestUserAt: Date?
        let toolNames: [String]
        let workflowLines: [String]
        let pendingSubagentChildKeys: [String]
    }

    init(config: AppConfig) {
        self.config = config
        self.sessionsDir = URL(fileURLWithPath: config.openClawRoot)
            .appendingPathComponent("agents/main/sessions", isDirectory: true)
        start()
    }

    deinit {
        timer?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsSession?.invalidateAndCancel()
        reconnectWorkItem?.cancel()
        removeQuickPromptScrollMonitor()
    }

    private func start() {
        startWebSocket()
        installQuickPromptScrollMonitorIfNeeded()
        let t = DispatchSource.makeTimerSource(queue: monitorQueue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        timer = t
        monitorQueue.async { [weak self] in
            self?.refreshOpenClawServiceStatus(force: true, now: Date())
            self?.refreshFromFiles(captureDetails: true)
            self?.bootstrapQuickPrompts()
        }
    }

    private func tick() {
        let now = Date()
        let wsFresh: Bool = {
            guard wsConnected else { return false }
            guard let last = wsLastEventAt else { return false }
            return now.timeIntervalSince(last) <= 10
        }()

        if wsConnected {
            let shouldPing: Bool = {
                guard let lastPing = wsLastPingAt else { return true }
                return now.timeIntervalSince(lastPing) >= 12
            }()
            if shouldPing {
                wsLastPingAt = now
                sendWebSocketPing()
            }
        }

        cleanupStaleWebSocketRuns(now: now)
        refreshOpenClawServiceStatus(force: false, now: now)
        refreshFromFiles(captureDetails: true)

        let hasWebSocketInFlight = !wsToolingRuns.isEmpty || !wsActiveRuns.isEmpty || ((completedUntil ?? .distantPast) > now)
        let targetState: OverlayState = (wsFresh || hasWebSocketInFlight) ? resolveStateFromWebSocket(now: now) : resolveStateFromFiles(now: now)
        if targetState == .idle {
            if let fallback = fallbackStateDuringIdle(now: now) {
                applyLiveState(fallback)
            } else {
                let idleAge = now.timeIntervalSince(lastActivityAt)
                applyLiveState(idleAge >= sleepStartAfterIdleSeconds ? .sleeping : .idle)
            }
        } else {
            applyLiveState(targetState)
        }

        reconcileQuickPromptVisibility(now: now)
        refreshBubble(now: now)
        tickQuickPromptRotation(now: now)
    }

    private func resolveStateFromWebSocket(now: Date) -> OverlayState {
        if hasPendingSubagentChildWork() {
            if taskStartingUntil == nil, stateCache != .taskStarting, stateCache != .tooling {
                taskStartingUntil = now.addingTimeInterval(1.05)
            }
            if let until = taskStartingUntil, now < until {
                return .taskStarting
            }
            taskStartingUntil = nil
            completedUntil = nil
            suppressToolAfterCompletion = false
            lastToolSignalAt = now
            return .tooling
        }
        if let until = completedUntil, now < until {
            return .completed
        }
        if filePhase == .completed {
            clearTransientRunSignalsAfterCompletion()
            completedUntil = now.addingTimeInterval(completedBubbleSeconds)
            lastCompletionAt = now
            suppressToolAfterCompletion = true
            lastToolSignalAt = nil
            return .completed
        }
        if suppressToolAfterCompletion {
            return .idle
        }
        let recentToolSignal = {
            guard let lastToolSignalAt else { return false }
            guard completedUntil == nil || now >= completedUntil! else { return true }
            return now.timeIntervalSince(lastToolSignalAt) <= 20
        }()
        let toolingSignal = !wsToolingRuns.isEmpty || filePhase == .tooling || (recentToolSignal && !wsActiveRuns.isEmpty)
        if toolingSignal {
            if taskStartingUntil == nil, stateCache != .taskStarting, stateCache != .tooling {
                taskStartingUntil = now.addingTimeInterval(1.05)
            }
            if let until = taskStartingUntil, now < until {
                return .taskStarting
            }
            taskStartingUntil = nil
            return .tooling
        }

        taskStartingUntil = nil
        if !wsActiveRuns.isEmpty, filePhase == .completed {
            if completedUntil == nil {
                completedUntil = now.addingTimeInterval(completedBubbleSeconds)
                lastCompletionAt = now
                suppressToolAfterCompletion = true
            }
            return .completed
        }
        if !wsActiveRuns.isEmpty {
            return .thinking
        }
        completedUntil = nil
        if !recentToolSignal {
            lastToolSignalAt = nil
        }
        return .idle
    }

    private func resolveStateFromFiles(now: Date) -> OverlayState {
        if hasPendingSubagentChildWork() {
            if taskStartingUntil == nil, stateCache != .taskStarting, stateCache != .tooling {
                taskStartingUntil = now.addingTimeInterval(1.05)
            }
            if let until = taskStartingUntil, now < until {
                return .taskStarting
            }
            taskStartingUntil = nil
            completedUntil = nil
            suppressToolAfterCompletion = false
            lastToolSignalAt = now
            return .tooling
        }
        if let until = completedUntil, now < until {
            return .completed
        }
        if suppressToolAfterCompletion, filePhase != .completed {
            return .idle
        }
        if filePhase == .tooling {
            if taskStartingUntil == nil, stateCache != .taskStarting, stateCache != .tooling {
                taskStartingUntil = now.addingTimeInterval(1.05)
            }
            if let until = taskStartingUntil, now < until {
                return .taskStarting
            }
            taskStartingUntil = nil
            return .tooling
        }

        taskStartingUntil = nil
        switch filePhase {
        case .thinking:
            return .thinking
        case .completed:
            clearTransientRunSignalsAfterCompletion()
            if completedUntil == nil {
                completedUntil = now.addingTimeInterval(completedBubbleSeconds)
                lastCompletionAt = now
                suppressToolAfterCompletion = true
                lastToolSignalAt = nil
            }
            return .completed
        case .sleeping:
            return .sleeping
        case .taskStarting:
            return .taskStarting
        case .idle:
            completedUntil = nil
            return .idle
        case .tooling:
            return .tooling
        }
    }

    private func hasPendingSubagentChildWork() -> Bool {
        !pendingSubagentChildKeys.isEmpty
    }

    private func cleanupStaleWebSocketRuns(now: Date) {
        for runId in Array(wsActiveRuns) {
            let touched = wsRunTouchedAt[runId] ?? Date.distantPast
            if now.timeIntervalSince(touched) > 180 {
                wsActiveRuns.remove(runId)
                wsToolCallsByRun.removeValue(forKey: runId)
            }
        }

        for (runId, calls) in Array(wsToolCallsByRun) {
            var filtered = calls
            for callId in calls {
                let key = "\(runId)|\(callId)"
                let touched = wsToolTouchedAt[key] ?? wsRunTouchedAt[runId] ?? Date.distantPast
                if now.timeIntervalSince(touched) > 180 {
                    filtered.remove(callId)
                    wsToolTouchedAt.removeValue(forKey: key)
                }
            }
            if filtered.isEmpty {
                wsToolCallsByRun.removeValue(forKey: runId)
            } else {
                wsToolCallsByRun[runId] = filtered
            }
        }

        for (runId, touchedAt) in Array(wsRunTouchedAt) {
            if now.timeIntervalSince(touchedAt) > 60, !wsActiveRuns.contains(runId), (wsToolCallsByRun[runId] ?? []).isEmpty {
                wsRunTouchedAt.removeValue(forKey: runId)
            }
        }

        syncToolingRunsFromToolCalls()
    }

    private func clearTransientRunSignalsAfterCompletion() {
        wsActiveRuns.removeAll()
        wsToolingRuns.removeAll()
        wsToolCallsByRun.removeAll()
        wsToolTouchedAt.removeAll()
        wsRunTouchedAt.removeAll()
        taskStartingUntil = nil
    }

    private func syncToolingRunsFromToolCalls() {
        wsToolingRuns = Set(wsToolCallsByRun.compactMap { key, calls in
            calls.isEmpty ? nil : key
        })
    }

    private func refreshFromFiles(captureDetails: Bool) {
        do {
            let indexURL = sessionsDir.appendingPathComponent("sessions.json")
            let data = try Data(contentsOf: indexURL)
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let sessionEntries: [(key: String, sessionId: String, updatedAt: Double)] = raw.compactMap { key, value in
                guard
                    let item = value as? [String: Any],
                    let sessionId = item["sessionId"] as? String,
                    let updatedAt = item["updatedAt"] as? Double
                else {
                    return nil
                }
                return (key: key, sessionId: sessionId, updatedAt: updatedAt)
            }

            let relevantEntries = sessionEntries.filter { entry in
                isSupportedSessionKey(normalizedSessionKey(entry.key))
            }

            if let latestMain = sessionEntries
                .filter({ isMainConversationSessionKey(normalizedSessionKey($0.key)) })
                .max(by: { $0.updatedAt < $1.updatedAt })
            {
                latestMainSessionKey = latestMain.key
            }

            guard let target = relevantEntries.max(by: { $0.updatedAt < $1.updatedAt }) else {
                trackedSessionIds.removeAll()
                filePhase = .idle
                pendingSubagentChildKeys.removeAll()
                return
            }
            trackedSessionIds = Set(relevantEntries.map(\.sessionId))
            fallbackSessionId = target.sessionId
            fallbackSessionKey = target.key

            let now = Date()
            let ageSec = (now.timeIntervalSince1970 * 1000 - target.updatedAt) / 1000
            if ageSec > max(config.activeWindowSeconds * 6, 90) {
                filePhase = .idle
                pendingSubagentChildKeys.removeAll()
                return
            }

            let insights = try inspectMainSession(id: target.sessionId, now: now)
            pendingSubagentChildKeys = Set(insights.pendingSubagentChildKeys)
            let previousPhase = filePhase
            let shouldIgnoreStalePhase: Bool = {
                guard suppressToolAfterCompletion, insights.phase != .completed else { return false }
                guard let completedAt = lastCompletionAt else { return false }
                if let latestUserAt = insights.latestUserAt {
                    return latestUserAt <= completedAt
                }
                return true
            }()
            if shouldIgnoreStalePhase {
                filePhase = .idle
                taskStartingUntil = nil
                return
            }
            filePhase = insights.phase
            registerRunStartIfNeeded(from: previousPhase, to: filePhase, now: now)
            if insights.phase == .tooling {
                lastToolSignalAt = now
            }
            guard captureDetails else { return }

            if !insights.outputText.isEmpty {
                latestOutputText = insights.outputText
                if let outputAt = insights.outputAt {
                    latestOutputAt = outputAt
                } else if latestOutputAt == nil {
                    latestOutputAt = now
                }
            }
            if !insights.toolNames.isEmpty {
                latestToolNames = insights.toolNames
            }
            if !insights.workflowLines.isEmpty {
                workflowLines = insights.workflowLines
            }
        } catch {
            filePhase = .idle
            pendingSubagentChildKeys.removeAll()
        }
    }

    private func publish(state: OverlayState) {
        guard state != stateCache else { return }
        stateCache = state

        DispatchQueue.main.async {
            self.overlayState = state
        }
    }

    private func publishBubble(
        visible: Bool,
        text: String = "",
        tools: [String] = [],
        singleLine: Bool = false,
        loadingOnly: Bool = false
    ) {
        DispatchQueue.main.async {
            self.bubbleVisible = visible
            self.bubbleText = text
            self.bubbleTools = tools
            self.bubbleSingleLine = singleLine
            self.bubbleLoadingOnly = loadingOnly
        }
    }

    private func publishQuickPromptVisible(_ visible: Bool) {
        guard visible != quickPromptVisibleCache else { return }
        quickPromptVisibleCache = visible
        DispatchQueue.main.async {
            self.quickPromptVisible = visible
        }
    }

    private func refreshBubble(now: Date) {
        if stateCache == .completed {
            completedBubbleExitAt = nil
        } else if lastBubbleState == .completed, completedBubbleExitAt == nil {
            completedBubbleExitAt = now
        }

        if stateCache != .tooling {
            toolingDisplayText = ""
            toolingDisplayAt = nil
        }

        let completedExitElapsed = now.timeIntervalSince(completedBubbleExitAt ?? now)
        let keepCompletedBubbleDuringJitter =
            stateCache != .completed &&
            !isActiveRunPhase(stateCache) &&
            completedBubbleExitAt != nil &&
            completedExitElapsed < 1.3 &&
            !outputDisplayText.isEmpty

        if keepCompletedBubbleDuringJitter {
            publishBubble(visible: true, text: outputDisplayText, tools: [], singleLine: false)
            lastBubbleState = stateCache
            return
        }

        if lastBubbleState == .completed, stateCache != .completed {
            let shouldClearCompletedOutput =
                isActiveRunPhase(stateCache) ||
                (completedBubbleExitAt != nil && completedExitElapsed >= 1.3)
            if shouldClearCompletedOutput {
                outputQueue.removeAll()
                outputDisplayText = ""
                outputDisplayAt = nil
                outputDisplayDuration = 0
                lastOutputEnqueuedAt = nil
                lastOutputSnapshotText = ""
            }
        }
        switch stateCache {
        case .idle, .sleeping:
            publishBubble(visible: false)
        case .thinking:
            _ = now
            publishBubble(visible: true, text: "", tools: [], singleLine: true, loadingOnly: true)
        case .taskStarting:
            publishBubble(visible: true, text: "开始干活啦~", tools: [], singleLine: true)
        case .tooling:
            let workflowText = dynamicWorkflowText(now: now)
            if toolingDisplayText.isEmpty || now.timeIntervalSince(toolingDisplayAt ?? now) >= toolingMinDisplaySeconds {
                toolingDisplayText = workflowText
                toolingDisplayAt = now
            }
            publishBubble(
                visible: true,
                text: toolingDisplayText,
                tools: Array(latestToolNames.suffix(30).reversed()),
                singleLine: false
            )
        case .completed:
            let output = sanitizeDisplayText(latestOutputText)
            let outputFresh: Bool = {
                guard let latestOutputAt else { return false }
                if let lastRunStartedAt {
                    return latestOutputAt >= lastRunStartedAt.addingTimeInterval(-1.0)
                }
                if let lastCompletionAt {
                    return latestOutputAt >= lastCompletionAt.addingTimeInterval(-outputFreshWindowSeconds)
                }
                return !output.isEmpty
            }()
            if outputFresh && !output.isEmpty {
                let shouldEnqueue: Bool = {
                    if let latestOutputAt {
                        if let lastOutputEnqueuedAt {
                            if latestOutputAt > lastOutputEnqueuedAt {
                                return true
                            }
                            return output != sanitizeDisplayText(lastOutputSnapshotText)
                        }
                        return true
                    }
                    return output != sanitizeDisplayText(lastOutputSnapshotText) || (outputDisplayText.isEmpty && outputQueue.isEmpty)
                }()
                if shouldEnqueue {
                    if let chunk = incrementalOutputChunk(current: output, previous: lastOutputSnapshotText), !chunk.isEmpty {
                        outputQueue.append(chunk)
                    }
                    lastOutputSnapshotText = output
                    lastOutputEnqueuedAt = latestOutputAt ?? now
                }
            }
            let canAdvance = outputDisplayAt == nil ||
                (now.timeIntervalSince(outputDisplayAt ?? now) >= outputDisplayDuration)
            if outputDisplayText.isEmpty {
                if let next = outputQueue.first {
                    outputQueue.removeFirst()
                    outputDisplayText = next
                    outputDisplayAt = now
                    outputDisplayDuration = outputDisplayDuration(for: next)
                }
            } else if canAdvance, !outputQueue.isEmpty {
                let next = outputQueue.removeFirst()
                outputDisplayText = next
                outputDisplayAt = now
                outputDisplayDuration = outputDisplayDuration(for: next)
            }
            if outputDisplayText.isEmpty {
                publishBubble(visible: false)
            } else {
                if let until = completedUntil, now >= until {
                    completedUntil = now.addingTimeInterval(completedBubbleSeconds)
                }
                publishBubble(visible: true, text: outputDisplayText, tools: [], singleLine: false)
            }
        }
        lastBubbleState = stateCache
    }

    private func isActiveRunPhase(_ phase: OverlayState) -> Bool {
        phase == .thinking || phase == .tooling || phase == .taskStarting
    }

    private func registerRunStartIfNeeded(from old: OverlayState, to new: OverlayState, now: Date) {
        guard isActiveRunPhase(new), !isActiveRunPhase(old) else { return }
        latestOutputText = ""
        latestOutputAt = nil
        lastOutputEnqueuedAt = nil
        lastOutputSnapshotText = ""
        lastRunStartedAt = now
        lastCompletionAt = nil
        completedUntil = nil
        suppressToolAfterCompletion = false
        outputQueue.removeAll()
        outputDisplayText = ""
        outputDisplayAt = nil
        outputDisplayDuration = 0
    }

    private func applyLiveState(_ phase: OverlayState) {
        if phase == .thinking || phase == .taskStarting || phase == .tooling || phase == .completed {
            lastActivityAt = Date()
        }
        publish(state: phase)
    }

    private func fallbackStateDuringIdle(now: Date) -> OverlayState? {
        if let until = taskStartingUntil, now < until {
            return .taskStarting
        }
        if filePhase == .taskStarting {
            return .taskStarting
        }
        if !pendingChatRequests.isEmpty || pendingQuickPromptToSend != nil {
            return .thinking
        }
        // After we have already emitted completed state, ignore stale run/tool snapshots
        // until a new run explicitly starts.
        if suppressToolAfterCompletion {
            return nil
        }
        if !wsToolingRuns.isEmpty || filePhase == .tooling {
            return .tooling
        }
        if let lastToolSignalAt, now.timeIntervalSince(lastToolSignalAt) <= 2.0 {
            return .tooling
        }
        if !wsActiveRuns.isEmpty || filePhase == .thinking {
            return .thinking
        }
        if shouldHoldActiveStateDuringSilentRun(now: now) {
            return .thinking
        }
        return nil
    }

    private func shouldHoldActiveStateDuringSilentRun(now: Date) -> Bool {
        guard !suppressToolAfterCompletion else { return false }
        guard isActiveRunPhase(stateCache) else { return false }
        guard let startedAt = lastRunStartedAt else { return false }
        if let completedAt = lastCompletionAt, completedAt >= startedAt {
            return false
        }
        if let latestOutputAt, latestOutputAt >= startedAt {
            return false
        }
        return now.timeIntervalSince(startedAt) <= activeRunSilenceHoldSeconds
    }

    private func shouldHideQuickPrompt(now: Date) -> Bool {
        if stateCache == .thinking || stateCache == .tooling || stateCache == .taskStarting {
            return true
        }
        if !wsActiveRuns.isEmpty || !wsToolingRuns.isEmpty {
            return true
        }
        if let until = taskStartingUntil, now < until {
            return true
        }
        if !pendingChatRequests.isEmpty || pendingQuickPromptToSend != nil {
            return true
        }
        if let toolSignal = lastToolSignalAt, now.timeIntervalSince(toolSignal) <= 1.0 {
            return true
        }
        return false
    }

    private func reconcileQuickPromptVisibility(now: Date) {
        let shouldHide = shouldHideQuickPrompt(now: now)
        if shouldHide {
            quickPromptInFlightCache = true
            quickPromptIdleSince = nil
            publishQuickPromptVisible(false)
            return
        }

        guard quickPromptInFlightCache else {
            publishQuickPromptVisible(true)
            return
        }

        if quickPromptIdleSince == nil {
            quickPromptIdleSince = now
        }
        let idleFor = now.timeIntervalSince(quickPromptIdleSince ?? now)
        if idleFor >= quickPromptRevealDelaySeconds {
            quickPromptInFlightCache = false
            quickPromptIdleSince = nil
            publishQuickPromptVisible(true)
        } else {
            publishQuickPromptVisible(false)
        }
    }

    func rotateQuickPrompt() {
        monitorQueue.async { [weak self] in
            self?.rotateQuickPromptInternal(animated: true)
        }
    }

    func browseQuickPrompt(step: Int) {
        monitorQueue.async { [weak self] in
            self?.browseQuickPromptInternal(step: step, animated: true)
        }
    }

    func sendCurrentQuickPrompt() {
        monitorQueue.async { [weak self] in
            self?.sendCurrentQuickPromptInternal()
        }
    }

    func sendTypedPrompt(_ text: String) {
        monitorQueue.async { [weak self] in
            self?.sendTypedPromptInternal(text)
        }
    }

    func handleOpenClawControlTap() {
        monitorQueue.async { [weak self] in
            self?.handleOpenClawControlTapInternal()
        }
    }

    func openAdminPanel() {
        let url = config.adminURL
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    func setQuickPromptHovering(_ hovering: Bool) {
        monitorQueue.async { [weak self] in
            guard let self else { return }
            self.quickPromptHovering = hovering
            if !hovering {
                self.quickPromptScrollAccumulator = 0
                self.quickPromptScrollResetWorkItem?.cancel()
                self.quickPromptScrollResetWorkItem = nil
                DispatchQueue.main.async {
                    self.quickPromptScrollProgress = 0
                }
            }
        }
    }

    private func tickQuickPromptRotation(now: Date) {
        guard !quickPromptPool.isEmpty else { return }
        if quickPromptLastRotateAt == .distantPast {
            quickPromptLastRotateAt = now
            return
        }
        guard now.timeIntervalSince(quickPromptLastRotateAt) >= quickPromptRotateSeconds else { return }
        rotateQuickPromptInternal(animated: true, now: now)
    }

    private func bootstrapQuickPrompts() {
        quickPromptPool = defaultQuickPromptPool()
        if quickPromptPool.isEmpty {
            quickPromptPool = ["开始任务"]
        }
        quickPromptIndex = Int.random(in: 0 ..< quickPromptPool.count)
        quickPromptLastRotateAt = Date()
        publishQuickPrompt(animated: false)
    }

    private func rotateQuickPromptInternal(animated: Bool, now: Date = Date()) {
        if quickPromptPool.isEmpty {
            bootstrapQuickPrompts()
            return
        }
        let oldIndex = quickPromptIndex
        if quickPromptPool.count > 1 {
            var nextIndex = quickPromptIndex
            while nextIndex == quickPromptIndex {
                nextIndex = Int.random(in: 0 ..< quickPromptPool.count)
            }
            quickPromptIndex = nextIndex
            let count = quickPromptPool.count
            let forward = (nextIndex - oldIndex + count) % count
            let backward = (oldIndex - nextIndex + count) % count
            quickPromptLastDirection = forward <= backward ? 1 : -1
        }
        quickPromptLastRotateAt = now
        publishQuickPrompt(animated: animated)
    }

    private func browseQuickPromptInternal(step: Int, animated: Bool, now: Date = Date()) {
        guard step != 0 else { return }
        if quickPromptPool.isEmpty {
            bootstrapQuickPrompts()
            return
        }
        guard !quickPromptPool.isEmpty else { return }
        let count = quickPromptPool.count
        let normalizedStep = step % count
        let next = (quickPromptIndex + normalizedStep + count) % count
        quickPromptIndex = next
        quickPromptLastDirection = step >= 0 ? 1 : -1
        quickPromptLastRotateAt = now
        publishQuickPrompt(animated: animated)
    }

    private func publishQuickPrompt(animated: Bool) {
        guard !quickPromptPool.isEmpty else { return }
        let safeIndex = min(max(quickPromptIndex, 0), quickPromptPool.count - 1)
        let prev2Text = quickPromptPool[(safeIndex - 2 + quickPromptPool.count) % quickPromptPool.count]
        let text = quickPromptPool[safeIndex]
        let prevText = quickPromptPool[(safeIndex - 1 + quickPromptPool.count) % quickPromptPool.count]
        let nextText = quickPromptPool[(safeIndex + 1) % quickPromptPool.count]
        let next2Text = quickPromptPool[(safeIndex + 2) % quickPromptPool.count]
        let icon = nextQuickPromptIcon(excluding: quickPromptCurrentIcon)
        quickPromptCurrentIcon = icon
        DispatchQueue.main.async {
            self.quickPromptPrev2Text = prev2Text
            self.quickPromptText = text
            self.quickPromptPrevText = prevText
            self.quickPromptNextText = nextText
            self.quickPromptNext2Text = next2Text
            self.quickPromptIcon = icon
            self.quickPromptDirection = self.quickPromptLastDirection
            if animated {
                self.quickPromptToken += 1
            }
        }
    }

    private func nextQuickPromptIcon(excluding oldIcon: String?) -> String {
        guard !quickPromptIcons.isEmpty else { return "sparkles" }
        if quickPromptIcons.count == 1 {
            return quickPromptIcons[0]
        }
        let available = quickPromptIcons.filter { $0 != oldIcon }
        if let picked = available.randomElement() {
            return picked
        }
        return quickPromptIcons.randomElement() ?? "sparkles"
    }

    private func installQuickPromptScrollMonitorIfNeeded() {
        guard quickPromptScrollEventMonitor == nil else { return }
        quickPromptScrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            guard self.quickPromptHovering else { return event }
            let delta = event.scrollingDeltaY
            if abs(delta) < 0.1 {
                return nil
            }
            self.monitorQueue.async { [weak self] in
                self?.consumeQuickPromptScroll(deltaY: delta)
            }
            return nil
        }
    }

    private func removeQuickPromptScrollMonitor() {
        guard let monitor = quickPromptScrollEventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        quickPromptScrollEventMonitor = nil
    }

    private func consumeQuickPromptScroll(deltaY: CGFloat) {
        quickPromptScrollResetWorkItem?.cancel()
        quickPromptScrollAccumulator += deltaY
        let threshold: CGFloat = 18
        let snapTrigger = threshold * 0.72
        let clampedProgress = max(-1, min(1, quickPromptScrollAccumulator / threshold))
        DispatchQueue.main.async {
            self.quickPromptScrollProgress = clampedProgress
        }

        while abs(quickPromptScrollAccumulator) >= snapTrigger {
            if quickPromptScrollAccumulator > 0 {
                browseQuickPromptInternal(step: -1, animated: true)
                quickPromptScrollAccumulator -= threshold
            } else {
                browseQuickPromptInternal(step: 1, animated: true)
                quickPromptScrollAccumulator += threshold
            }
            let residualProgress = max(-1, min(1, quickPromptScrollAccumulator / threshold))
            DispatchQueue.main.async {
                self.quickPromptScrollProgress = residualProgress
            }
        }

        let settle = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.84, blendDuration: 0.05)) {
                    self.quickPromptScrollProgress = 0
                }
            }
        }
        quickPromptScrollResetWorkItem = settle
        monitorQueue.asyncAfter(deadline: .now() + 0.14, execute: settle)
    }

    private func sendCurrentQuickPromptInternal() {
        if quickPromptPool.isEmpty {
            bootstrapQuickPrompts()
        }
        guard !quickPromptPool.isEmpty else { return }
        let safeIndex = min(max(quickPromptIndex, 0), quickPromptPool.count - 1)
        let message = quickPromptPool[safeIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        sendPromptInternal(message, workflowHint: "收到快捷任务")
    }

    private func sendTypedPromptInternal(_ rawText: String) {
        let message = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        sendPromptInternal(message, workflowHint: "收到输入任务")
    }

    private func sendPromptInternal(_ message: String, workflowHint: String) {
        let now = Date()
        latestThinkingText = "正在准备执行"
        completedUntil = nil
        taskStartingUntil = now.addingTimeInterval(1.05)
        appendWorkflowLine(workflowHint)
        applyLiveState(.taskStarting)
        reconcileQuickPromptVisibility(now: now)
        refreshBubble(now: Date())

        let preferredSession = resolvedQuickSendSessionKey()
        if sendChatMessageViaControlUI(message) {
            pendingQuickPromptToSend = nil
            appendWorkflowLine("已同步到网页聊天")
            if !wsConnected {
                startWebSocket()
            }
            return
        }

        if sendChatMessageViaCLI(message, sessionKey: preferredSession) {
            latestMainSessionKey = preferredSession
            pendingQuickPromptToSend = nil
            if !wsConnected {
                startWebSocket()
            }
            return
        }

        if wsConnected {
            sendChatMessage(message)
        } else {
            pendingQuickPromptToSend = message
            startWebSocket()
        }
    }

    private func handleOpenClawControlTapInternal() {
        guard !openClawServiceActionInProgressCache else { return }
        let shouldRestart = openClawRunningCache || checkOpenClawServiceRunning()
        openClawRunningCache = shouldRestart
        DispatchQueue.main.async {
            self.openClawRunning = shouldRestart
        }
        openClawServiceActionInProgressCache = true
        publishOpenClawServiceActionInProgress(true)

        openClawControlQueue.async { [weak self] in
            guard let self else { return }
            if shouldRestart {
                self.stopOpenClawService()
            }
            self.startOpenClawService()
            self.monitorQueue.async {
                self.openClawServiceActionInProgressCache = false
                self.publishOpenClawServiceActionInProgress(false)
                self.refreshOpenClawServiceStatus(force: true, now: Date())
            }
        }
    }

    private func refreshOpenClawServiceStatus(force: Bool, now: Date) {
        guard force || now.timeIntervalSince(lastOpenClawHealthCheckAt) >= openClawHealthCheckInterval else { return }
        lastOpenClawHealthCheckAt = now
        let running = checkOpenClawServiceRunning()
        openClawRunningCache = running
        DispatchQueue.main.async {
            self.openClawRunning = running
        }
    }

    private func checkOpenClawServiceRunning() -> Bool {
        if wsConnected {
            return true
        }
        return runShellCommand("/usr/sbin/lsof -tiTCP:\(openClawGatewayPort) -sTCP:LISTEN >/dev/null 2>&1") == 0
    }

    private func startOpenClawService() {
        if let script = config.openClawStartScript,
           !script.isEmpty,
           FileManager.default.fileExists(atPath: script)
        {
            _ = runProcess(executablePath: "/bin/zsh", arguments: [script])
            return
        }
        _ = runProcess(executablePath: "/usr/bin/env", arguments: ["openclaw", "gateway", "start"])
    }

    private func stopOpenClawService() {
        _ = runShellCommand(
            """
            if command -v openclaw >/dev/null 2>&1; then
              openclaw gateway stop >/tmp/openclaw-desk-sprite.stop.log 2>&1 || true
            fi
            pids="$(/usr/sbin/lsof -tiTCP:\(openClawGatewayPort) -sTCP:LISTEN 2>/dev/null || true)"
            if [ -n "$pids" ]; then
              kill $pids >/dev/null 2>&1 || true
              sleep 0.4
            fi
            """
        )
    }

    private func publishOpenClawServiceActionInProgress(_ inProgress: Bool) {
        DispatchQueue.main.async {
            self.openClawServiceActionInProgress = inProgress
        }
    }

    @discardableResult
    private func runShellCommand(_ command: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.environment = buildShellEnvironment()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    @discardableResult
    private func runProcess(executablePath: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = buildShellEnvironment()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private func buildShellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let defaultPathParts = [
            "\(NSHomeDirectory())/.petclaw/node/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existingParts = (env["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        var mergedParts: [String] = []
        var seen = Set<String>()

        for part in defaultPathParts + existingParts where seen.insert(part).inserted {
            mergedParts.append(part)
        }

        env["PATH"] = mergedParts.joined(separator: ":")
        env["HOME"] = NSHomeDirectory()
        return env
    }

    private func resolvedQuickSendSessionKey() -> String {
        let candidates = [
            latestMainSessionKey,
            webSyncSessionKey,
            mainSessionKey
        ]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if isMainConversationSessionKey(normalizedSessionKey(trimmed)) {
                return trimmed
            }
        }
        return webSyncSessionKey
    }

    private func sendChatMessage(
        _ message: String,
        sessionKeyOverride: String? = nil,
        mainFallbackTried: Bool = false
    ) {
        let sessionKey = {
            let preferred = sessionKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !preferred.isEmpty {
                return preferred
            }
            return resolvedQuickSendSessionKey()
        }()
        let requestId = UUID().uuidString
        let params: [String: Any] = [
            "sessionKey": sessionKey,
            "message": message,
            "deliver": false,
            "idempotencyKey": requestId
        ]
        let frame: [String: Any] = [
            "type": "req",
            "id": requestId,
            "method": "chat.send",
            "params": params
        ]
        pendingChatRequests[requestId] = PendingChatRequest(
            message: message,
            sessionKey: sessionKey,
            mainFallbackTried: mainFallbackTried
        )
        sendWebSocketJSON(frame)
    }

    private func sendChatMessageViaControlUI(_ message: String) -> Bool {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return false }
        guard let messageLiteral = javaScriptStringLiteral(trimmedMessage) else { return false }

        let js = """
        (() => {
          const app = document.querySelector('openclaw-app');
          if (!app) return 'NO_APP';
          if (typeof app.handleSendChat !== 'function') return 'NO_SEND_API';
          if (!app.connected) return 'NOT_CONNECTED';
          try {
            const req = app.handleSendChat(\(messageLiteral));
            if (req && typeof req.catch === 'function') {
              req.catch(() => {});
            }
            return 'OK';
          } catch (err) {
            return 'ERROR:' + String(err);
          }
        })();
        """

        let browserApps = ["Google Chrome", "Safari"]
        for appName in browserApps {
            if runChatInjectionAppleScript(appName: appName, javaScript: js) {
                return true
            }
        }
        return false
    }

    private func runChatInjectionAppleScript(appName: String, javaScript: String) -> Bool {
        let escapedJS = appleScriptStringLiteral(javaScript)
        let urlPrefixChecks = openClawDashboardURLPrefixes()
            .map { "(tabUrl starts with \"\($0)\")" }
            .joined(separator: " or ")
        guard !urlPrefixChecks.isEmpty else { return false }

        let executeLine: String
        if appName == "Safari" {
            executeLine = "set jsResult to (do JavaScript \(escapedJS) in tabRef)"
        } else {
            executeLine = "set jsResult to (execute tabRef javascript \(escapedJS))"
        }

        let scriptLines = [
            "set foundResult to \"NOT_FOUND\"",
            "tell application \"\(appName)\"",
            "if not running then return \"NOT_RUNNING\"",
            "repeat with winRef in windows",
            "repeat with tabRef in tabs of winRef",
            "set tabUrl to URL of tabRef as text",
            "if \(urlPrefixChecks) then",
            executeLine,
            "if jsResult is missing value then return \"OK\"",
            "return jsResult as text",
            "end if",
            "end repeat",
            "end repeat",
            "end tell",
            "return foundResult"
        ]

        guard let rawResult = runAppleScript(lines: scriptLines) else { return false }
        return rawResult.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "OK"
    }

    private func runAppleScript(lines: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

        var args: [String] = []
        for line in lines {
            args.append("-e")
            args.append(line)
        }
        process.arguments = args
        process.environment = buildShellEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func javaScriptStringLiteral(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              var encoded = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        guard encoded.count >= 2 else { return nil }
        encoded.removeFirst()
        encoded.removeLast()
        return encoded
    }

    private func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func openClawDashboardURLPrefixes() -> [String] {
        let port = openClawGatewayPort
        return [
            "http://127.0.0.1:\(port)",
            "https://127.0.0.1:\(port)",
            "http://localhost:\(port)",
            "https://localhost:\(port)"
        ]
    }

    private func sendChatMessageViaCLI(_ message: String, sessionKey: String) -> Bool {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSession = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty, !trimmedSession.isEmpty else { return false }

        let params: [String: Any] = [
            "sessionKey": trimmedSession,
            "message": trimmedMessage,
            "deliver": false,
            "idempotencyKey": UUID().uuidString
        ]
        guard
            let paramsData = try? JSONSerialization.data(withJSONObject: params),
            let paramsJSON = String(data: paramsData, encoding: .utf8)
        else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "openclaw",
            "gateway",
            "call",
            "chat.send",
            "--json",
            "--timeout",
            "15000",
            "--params",
            paramsJSON
        ]

        var childEnv = ProcessInfo.processInfo.environment
        childEnv["OPENCLAW_ROOT"] = config.openClawRoot
        childEnv["OPENCLAW_GATEWAY_URL"] = config.gatewayURL.absoluteString
        if let token = config.gatewayToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            childEnv["OPENCLAW_GATEWAY_TOKEN"] = token
        }
        process.environment = childEnv

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    private func isMissingWriteScopeError(_ raw: [String: Any]) -> Bool {
        guard
            let error = raw["error"] as? [String: Any],
            let message = error["message"] as? String
        else {
            return false
        }
        return message.lowercased().contains("missing scope: operator.write")
    }

    private func dynamicThinkingText(now: Date) -> String {
        let dots = [".", "..", "..."][Int(now.timeIntervalSince1970 * 1.5) % 3]
        let hints = [
            "正在分析需求",
            "正在规划步骤",
            "正在整理方案"
        ]
        let hint = hints[Int(now.timeIntervalSince1970 / 2.6) % hints.count]
        return "思考中\(dots) \(hint)"
    }

    private func dynamicWorkflowText(now: Date) -> String {
        _ = now
        if workflowLines.isEmpty {
            if let tool = latestToolNames.last {
                return resolveToolDisplay(raw: tool).summary
            }
            return "正在执行任务流程"
        }
        return sanitizeDisplayText(workflowLines.last ?? "正在执行任务流程")
    }

    private func outputDisplayDuration(for text: String) -> TimeInterval {
        let cleaned = sanitizeDisplayText(text)
        let count = max(cleaned.count, 1)
        let seconds = ceil(Double(count) / outputCharsPerSecond)
        return max(2, seconds)
    }

    private func appendWorkflowLine(_ line: String) {
        let cleaned = sanitizeDisplayText(line)
        guard !cleaned.isEmpty else { return }
        if workflowLines.last == cleaned {
            return
        }
        workflowLines.append(cleaned)
        if workflowLines.count > 24 {
            workflowLines = Array(workflowLines.suffix(24))
        }
    }

    private func appendToolChip(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        latestToolNames.append(cleaned)
        if latestToolNames.count > 30 {
            latestToolNames = Array(latestToolNames.suffix(30))
        }
    }

    private func inspectMainSession(id: String, now: Date) throws -> FileInsights {
        let lines = try tailLines(path: sessionsDir.appendingPathComponent("\(id).jsonl").path, maxLines: 520)
        let parsed = lines.compactMap(decodeLine)

        var pending: [String: (name: String, at: Date)] = [:]
        var latestToolCallAt: Date?
        var latestToolResultAt: Date?
        var latestToolUseStopAt: Date?
        var latestThinkingAt: Date?
        var latestUserAt: Date?
        var latestAssistantAt: Date?
        var latestThinkingText = ""
        var latestAssistantText = ""
        var toolNamesHistory: [String] = []
        var workflow: [String] = []
        var pendingSubagentChildren: Set<String> = []

        for line in parsed where line.type == "message" {
            guard let msg = line.message else { continue }
            let lineDate = parseDate(line.timestamp) ?? now

            if msg.role == "assistant", let content = msg.content {
                for item in content {
                    let itemType = item.type.lowercased()
                    if itemType == "toolcall" || itemType == "tool_call" {
                        let raw = (item.name ?? "tool").trimmingCharacters(in: .whitespacesAndNewlines)
                        let mapped = resolveToolDisplay(raw: raw)
                        toolNamesHistory.append(mapped.badge)
                        if let toolId = item.id {
                            pending[toolId] = (mapped.badge, lineDate)
                        }
                        latestToolCallAt = maxDate(latestToolCallAt, lineDate)
                        workflow.append(mapped.summary)
                        continue
                    }

                    if itemType == "thinking" {
                        latestThinkingAt = maxDate(latestThinkingAt, lineDate)
                        if let t = item.text.map(sanitizeDisplayText), !t.isEmpty {
                            latestThinkingText = t
                        }
                        continue
                    }

                    if itemType == "text" {
                        if let t = item.text.map(sanitizeDisplayText), !t.isEmpty {
                            latestAssistantText = t
                            latestAssistantAt = maxDate(latestAssistantAt, lineDate)
                        }
                    }
                }
                if msg.stopReason == "toolUse" {
                    latestToolUseStopAt = maxDate(latestToolUseStopAt, lineDate)
                    workflow.append("等待工具执行结果")
                }
            }

            if msg.role == "toolResult" {
                latestToolResultAt = maxDate(latestToolResultAt, lineDate)
                var toolKey = "tool"
                if let toolId = msg.toolCallId, let pendingItem = pending[toolId] {
                    toolKey = pendingItem.name
                    pending.removeValue(forKey: toolId)
                }
                workflow.append(resolveToolDisplay(raw: toolKey).summary)

                if toolKey == "sessions_spawn" {
                    let textBlob = (msg.content ?? []).compactMap(\.text).joined(separator: "\n")
                    let spawn = parseSubagentSpawnStatus(textBlob)
                    if
                        let childKey = spawn.childSessionKey,
                        !childKey.isEmpty,
                        isPendingSubagentStatus(spawn.status)
                    {
                        pendingSubagentChildren.insert(childKey)
                        workflow.append("子任务执行中，等待回传")
                    }
                }
            }

            if msg.role == "user" {
                let rawUserText = (msg.content ?? []).compactMap(\.text).joined(separator: "\n")
                if let completion = parseSubagentCompletionEvent(rawUserText), !completion.sessionKey.isEmpty {
                    if isTerminalSubagentStatus(completion.status) {
                        pendingSubagentChildren.remove(completion.sessionKey)
                    } else if isPendingSubagentStatus(completion.status) {
                        pendingSubagentChildren.insert(completion.sessionKey)
                    }
                }

                let userText = sanitizeDisplayText(rawUserText)
                if !isSyntheticRuntimeUserMessage(userText) {
                    latestUserAt = maxDate(latestUserAt, lineDate)
                }
            }
        }

        let recentTool = isRecent(latestToolCallAt, now: now, thresholdSeconds: 16) ||
            isRecent(latestToolResultAt, now: now, thresholdSeconds: 16) ||
            isRecent(latestToolUseStopAt, now: now, thresholdSeconds: 16)
        let hasRecentPending = pending.values.contains { now.timeIntervalSince($0.at) <= 600 }

        let phase: OverlayState
        if !pendingSubagentChildren.isEmpty {
            phase = .tooling
        } else if hasRecentPending || recentTool {
            phase = .tooling
        } else if isRecent(latestAssistantAt, now: now, thresholdSeconds: 5), !latestAssistantText.isEmpty {
            phase = .completed
        } else {
            let awaitingAssistantAfterUser: Bool = {
                guard isRecent(latestUserAt, now: now, thresholdSeconds: awaitingAssistantAfterUserSeconds) else { return false }
                guard let latestUserAt else { return false }
                if let latestAssistantAt {
                    return latestUserAt > latestAssistantAt
                }
                return true
            }()
            let recentThinking = isRecent(latestThinkingAt, now: now, thresholdSeconds: 10) || awaitingAssistantAfterUser
            phase = recentThinking ? .thinking : .idle
        }

        let recentTools = Array(toolNamesHistory.suffix(30))
        let compactWorkflow = Array(workflow.suffix(24))

        return FileInsights(
            phase: phase,
            thinkingText: latestThinkingText,
            outputText: latestAssistantText,
            outputAt: latestAssistantAt,
            latestUserAt: latestUserAt,
            toolNames: recentTools,
            workflowLines: compactWorkflow,
            pendingSubagentChildKeys: Array(pendingSubagentChildren)
        )
    }

    private func decodeLine(_ line: String) -> SessionLine? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionLine.self, from: data)
    }

    private func parseDate(_ timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        if let d = isoFormatter.date(from: timestamp) {
            return d
        }
        return isoFormatterNoFraction.date(from: timestamp)
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let rhs else { return lhs }
        guard let lhs else { return rhs }
        return lhs > rhs ? lhs : rhs
    }

    // MARK: - Gateway WebSocket (Primary channel)
    private func startWebSocket() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsSession?.invalidateAndCancel()
        reconnectWorkItem?.cancel()
        wsConnected = false

        let session = URLSession(configuration: .default)
        wsSession = session
        let task = session.webSocketTask(with: config.gatewayURL)
        wsTask = task
        task.resume()
        receiveWebSocketMessage()
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.startWebSocket()
        }
        reconnectWorkItem = item
        monitorQueue.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    private func receiveWebSocketMessage() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            self.monitorQueue.async {
                switch result {
                case .failure:
                    self.wsConnected = false
                    self.scheduleReconnect()
                case let .success(message):
                    switch message {
                    case let .string(text):
                        self.handleWebSocketText(text)
                    case let .data(data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleWebSocketText(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveWebSocketMessage()
                }
            }
        }
    }

    private func handleWebSocketText(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = raw["type"] as? String
        else { return }

        if type == "event" {
            guard let event = raw["event"] as? String else { return }
            let payload = raw["payload"] as? [String: Any] ?? [:]
            wsLastEventAt = Date()
            switch event {
            case "connect.challenge":
                sendWebSocketConnect()
            case "chat":
                handleChatEvent(payload)
            case "agent":
                handleAgentEvent(payload)
            default:
                break
            }
            return
        }

        if type == "res" {
            let id = raw["id"] as? String
            if let id, let pendingChat = pendingChatRequests.removeValue(forKey: id) {
                let ok = raw["ok"] as? Bool ?? false
                if !ok {
                    if isMissingWriteScopeError(raw),
                       sendChatMessageViaCLI(pendingChat.message, sessionKey: webSyncSessionKey)
                    {
                        appendWorkflowLine("已通过本地网关发送")
                        return
                    }
                    let triedMain = pendingChat.mainFallbackTried || normalizedSessionKey(pendingChat.sessionKey) == webSyncSessionKey
                    if !triedMain {
                        latestMainSessionKey = webSyncSessionKey
                        appendWorkflowLine("主会话重试发送")
                        sendChatMessage(
                            pendingChat.message,
                            sessionKeyOverride: webSyncSessionKey,
                            mainFallbackTried: true
                        )
                    } else {
                        pendingQuickPromptToSend = pendingChat.message
                        wsConnected = false
                        scheduleReconnect()
                    }
                }
                return
            }
            guard id == wsConnectRequestId else { return }
            let ok = raw["ok"] as? Bool ?? false
            if ok {
                wsConnected = true
                wsLastEventAt = Date()
                wsLastPingAt = nil
                wsActiveRuns.removeAll()
                wsToolingRuns.removeAll()
                wsRunTouchedAt.removeAll()
                wsToolCallsByRun.removeAll()
                wsToolTouchedAt.removeAll()
                pendingChatRequests.removeAll()
                taskStartingUntil = nil
                lastToolSignalAt = nil
                if let pending = pendingQuickPromptToSend {
                    pendingQuickPromptToSend = nil
                    sendChatMessage(pending)
                }
            } else {
                wsConnected = false
                scheduleReconnect()
            }
        }
    }

    private func sendWebSocketConnect() {
        let reqId = UUID().uuidString
        wsConnectRequestId = reqId

        var auth: [String: Any] = [:]
        if let token = config.gatewayToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            auth["token"] = token
        }

        let params: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": [
                "id": "cli",
                "version": "1.0.0",
                "platform": "macOS",
                "mode": "cli",
                "instanceId": UUID().uuidString
            ],
            "role": "operator",
            "scopes": [
                "operator.admin",
                "operator.approvals",
                "operator.pairing",
                "operator.chat",
                "operator.read",
                "operator.write"
            ],
            "caps": ["tool-events"],
            "auth": auth,
            "userAgent": "desk-sprite",
            "locale": Locale.current.identifier
        ]

        let frame: [String: Any] = [
            "type": "req",
            "id": reqId,
            "method": "connect",
            "params": params
        ]
        sendWebSocketJSON(frame)
    }

    private func sendWebSocketJSON(_ object: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else { return }
        wsTask?.send(.string(text)) { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.monitorQueue.async {
                    if let latest = self.pendingChatRequests.values.first {
                        self.pendingQuickPromptToSend = latest.message
                    }
                    self.pendingChatRequests.removeAll()
                    self.wsConnected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func sendWebSocketPing() {
        wsTask?.sendPing { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.monitorQueue.async {
                    self.wsConnected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleChatEvent(_ payload: [String: Any]) {
        updatePreferredMainSessionKey(payload: payload, data: [:])
        guard shouldAcceptMainSessionEvent(payload: payload, data: [:]) else { return }
        let rawRunId = (payload["runId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let runId = rawRunId.isEmpty ? resolvedRunId(payload: payload, data: [:]) : rawRunId
        let state = (payload["state"] as? String ?? "").lowercased()
        let messageText = extractChatText(payload)
        let now = Date()
        if shouldIgnoreLateEvent(runId: runId, now: now), state != "final" {
            return
        }
        switch state {
        case "delta":
            markRunActive(runId, now: now)
            if !messageText.isEmpty {
                latestThinkingText = messageText
            }
            appendWorkflowLine("整理回答内容")
            completedUntil = nil
            suppressToolAfterCompletion = false
        case "final":
            finishRun(runId, completed: true, now: now)
            if !messageText.isEmpty {
                latestOutputText = messageText
                latestOutputAt = now
            }
            latestThinkingText = ""
            appendWorkflowLine("输出完成")
            completedUntil = now.addingTimeInterval(completedBubbleSeconds)
            lastCompletionAt = now
            lastCompletedRunId = runId
            suppressToolAfterCompletion = true
            lastToolSignalAt = nil
        case "error", "aborted":
            finishRun(runId, completed: false, now: now)
            completedUntil = nil
        default:
            break
        }
        refreshStateFromWebSocketRuns()
    }

    private func handleAgentEvent(_ payload: [String: Any]) {
        let stream = (payload["stream"] as? String ?? "").lowercased()
        let data = payload["data"] as? [String: Any] ?? [:]
        updatePreferredMainSessionKey(payload: payload, data: data)
        guard shouldAcceptMainSessionEvent(payload: payload, data: data) else { return }
        let phase = (data["phase"] as? String ?? "").lowercased()
        let runId = resolvedRunId(payload: payload, data: data)
        let now = Date()

        if stream != "lifecycle", shouldIgnoreLateEvent(runId: runId, now: now) {
            return
        }

        if stream == "tool" {
            if phase == "start" {
                lastToolSignalAt = now
                let (badge, summary) = resolveToolDisplay(from: data)
                appendToolChip(badge)
                appendWorkflowLine(summary)
                markRunActive(runId, now: now)
                let callId = resolvedToolCallId(data: data)
                trackToolStart(runId: runId, toolCallId: callId, now: now)
                completedUntil = nil
                suppressToolAfterCompletion = false
            } else if phase == "update" {
                lastToolSignalAt = now
                markRunActive(runId, now: now)
                let callId = resolvedToolCallId(data: data)
                trackToolUpdate(runId: runId, toolCallId: callId, now: now)
            } else if phase == "result" || phase == "end" {
                lastToolSignalAt = now
                let (badge, _) = resolveToolDisplay(from: data)
                markRunActive(runId, now: now)
                let callId = resolvedToolCallId(data: data)
                if isToolResultPending(data: data) {
                    appendWorkflowLine("\(badge) 正在等待结果")
                    trackToolUpdate(runId: runId, toolCallId: callId, now: now)
                } else {
                    appendWorkflowLine("\(badge) 执行完成")
                    trackToolEnd(runId: runId, toolCallId: callId, now: now)
                }
            }
            refreshStateFromWebSocketRuns()
            return
        }

        if stream == "assistant" {
            markRunActive(runId, now: now)
            if let text = data["text"] as? String {
                let cleaned = sanitizeDisplayText(text)
                if !cleaned.isEmpty {
                    latestThinkingText = cleaned
                }
            }
            refreshStateFromWebSocketRuns()
            return
        }

        if stream == "lifecycle" {
            if phase == "start" {
                if shouldIgnoreLateEvent(runId: runId, now: now) {
                    return
                }
                markRunActive(runId, now: now)
                completedUntil = nil
                suppressToolAfterCompletion = false
                refreshStateFromWebSocketRuns()
                return
            }
            if phase == "end" || phase == "error" {
                finishRun(runId, completed: phase == "end", now: now)
                if phase == "end" {
                    latestThinkingText = ""
                }
                completedUntil = phase == "end" ? now.addingTimeInterval(completedBubbleSeconds) : nil
                if phase == "end" {
                    lastCompletionAt = now
                    lastCompletedRunId = runId
                    suppressToolAfterCompletion = true
                    lastToolSignalAt = nil
                }
                refreshStateFromWebSocketRuns()
            }
        }
    }

    private func refreshStateFromWebSocketRuns() {
        let now = Date()
        cleanupStaleWebSocketRuns(now: now)
        let target = resolveStateFromWebSocket(now: now)
        if target == .idle {
            if let fallback = fallbackStateDuringIdle(now: now) {
                applyLiveState(fallback)
            } else {
                let idleAge = now.timeIntervalSince(lastActivityAt)
                applyLiveState(idleAge >= sleepStartAfterIdleSeconds ? .sleeping : .idle)
            }
        } else {
            applyLiveState(target)
        }
        reconcileQuickPromptVisibility(now: now)
        refreshBubble(now: now)
    }

    private func shouldIgnoreLateEvent(runId: String, now: Date) -> Bool {
        guard suppressToolAfterCompletion else { return false }
        guard let lastId = lastCompletedRunId, !lastId.isEmpty else { return false }
        if runId.isEmpty { return false }
        if let completedAt = lastCompletionAt, now.timeIntervalSince(completedAt) > 120 {
            return false
        }
        return runId == lastId
    }

    private func markRunActive(_ runId: String, now: Date) {
        guard !runId.isEmpty else { return }
        if let lastId = lastCompletedRunId, lastId != runId {
            lastCompletedRunId = nil
        }
        if wsActiveRuns.isEmpty, wsToolCallsByRun.isEmpty {
            latestToolNames.removeAll()
            workflowLines.removeAll()
            latestOutputText = ""
            latestOutputAt = nil
            lastOutputEnqueuedAt = nil
            lastOutputSnapshotText = ""
            lastRunStartedAt = now
            lastCompletionAt = nil
            completedUntil = nil
            suppressToolAfterCompletion = false
            outputQueue.removeAll()
            outputDisplayText = ""
            outputDisplayAt = nil
            outputDisplayDuration = 0
        }
        wsActiveRuns.insert(runId)
        wsRunTouchedAt[runId] = now
    }

    private func finishRun(_ runId: String, completed: Bool, now: Date) {
        guard !runId.isEmpty else { return }
        wsActiveRuns.remove(runId)
        wsRunTouchedAt[runId] = now
        wsToolCallsByRun.removeValue(forKey: runId)
        syncToolingRunsFromToolCalls()
        if completed {
            taskStartingUntil = nil
            lastToolSignalAt = nil
        }
    }

    private func resolvedRunId(payload: [String: Any], data: [String: Any]) -> String {
        let candidates = [
            payload["runId"] as? String,
            payload["run_id"] as? String,
            data["runId"] as? String,
            data["run_id"] as? String
        ]
        if let direct = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }) {
            return direct
        }
        if wsActiveRuns.count == 1, let single = wsActiveRuns.first {
            return single
        }
        if wsToolCallsByRun.count == 1, let single = wsToolCallsByRun.keys.first {
            return single
        }
        if let recent = wsRunTouchedAt.max(by: { $0.value < $1.value }),
           Date().timeIntervalSince(recent.value) <= 120
        {
            return recent.key
        }
        if let sid = fallbackSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty {
            return sid
        }
        return mainSessionKey
    }

    private func normalizedSessionKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isMainConversationSessionKey(_ normalizedKey: String) -> Bool {
        guard !normalizedKey.isEmpty else { return false }
        if isCronSessionKey(normalizedKey) || normalizedKey.contains(":subagent:") || normalizedKey.contains(":feishu:") {
            return false
        }
        if normalizedKey == "main" || normalizedKey == "agent:main" || normalizedKey == mainSessionKey.lowercased() {
            return true
        }
        return normalizedKey.hasPrefix("agent:main:")
    }

    private func isCronSessionKey(_ key: String) -> Bool {
        key.contains(":cron:") || key.contains("cron:")
    }

    private func isSupportedSessionKey(_ normalizedKey: String) -> Bool {
        guard !normalizedKey.isEmpty else { return false }
        if isCronSessionKey(normalizedKey) || normalizedKey.contains(":subagent:") {
            return false
        }

        if normalizedKey.contains(":feishu:") {
            return true
        }

        return normalizedKey == mainSessionKey.lowercased() ||
            normalizedKey == "agent:main" ||
            normalizedKey.contains("agent:main:main") ||
            normalizedKey.hasSuffix(":main")
    }

    private func shouldAcceptMainSessionEvent(payload: [String: Any], data: [String: Any]) -> Bool {
        let sessionKeyCandidates = [
            payload["sessionKey"] as? String,
            payload["session_key"] as? String,
            data["sessionKey"] as? String,
            data["session_key"] as? String
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let normalizedSessionKeys = sessionKeyCandidates.map(normalizedSessionKey)
        if normalizedSessionKeys.contains(where: isCronSessionKey) {
            return false
        }

        if normalizedSessionKeys.contains(where: { $0.contains(":subagent:") }) {
            return false
        }

        if normalizedSessionKeys.contains(where: isSupportedSessionKey) {
            return true
        }

        let sessionIdCandidates = [
            payload["sessionId"] as? String,
            payload["session_id"] as? String,
            data["sessionId"] as? String,
            data["session_id"] as? String
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        let strictCandidates = sessionIdCandidates.filter { looksLikeUUID($0) }
        if !strictCandidates.isEmpty {
            if !trackedSessionIds.isEmpty {
                return strictCandidates.contains(where: trackedSessionIds.contains)
            }
            if let sid = fallbackSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty {
                return strictCandidates.contains(sid)
            }
            if !normalizedSessionKeys.isEmpty {
                return false
            }
        }

        // If no explicit session identity is attached, only accept events from runs we already
        // know; this avoids unrelated background traffic making the sprite "talk to itself".
        let runCandidates = [
            payload["runId"] as? String,
            payload["run_id"] as? String,
            data["runId"] as? String,
            data["run_id"] as? String
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        if runCandidates.isEmpty {
            return false
        }
        return runCandidates.contains { runId in
            wsActiveRuns.contains(runId) || wsToolCallsByRun[runId] != nil || wsRunTouchedAt[runId] != nil
        }
    }

    private func updatePreferredMainSessionKey(payload: [String: Any], data: [String: Any]) {
        let candidates = [
            payload["sessionKey"] as? String,
            payload["session_key"] as? String,
            data["sessionKey"] as? String,
            data["session_key"] as? String
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        for candidate in candidates {
            let normalized = normalizedSessionKey(candidate)
            if isMainConversationSessionKey(normalized) {
                latestMainSessionKey = candidate
                return
            }
        }
    }

    private func looksLikeUUID(_ value: String) -> Bool {
        let p = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.count == 36 else { return false }
        return p.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
        }
    }

    private func resolvedToolCallId(data: [String: Any]) -> String {
        let candidates = [
            data["toolCallId"] as? String,
            data["tool_call_id"] as? String,
            data["id"] as? String
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "__active__"
    }

    private func trackToolStart(runId: String, toolCallId: String, now: Date) {
        guard !runId.isEmpty else { return }
        var calls = wsToolCallsByRun[runId] ?? Set<String>()
        calls.insert(toolCallId)
        wsToolCallsByRun[runId] = calls
        wsToolTouchedAt["\(runId)|\(toolCallId)"] = now
        wsRunTouchedAt[runId] = now
        syncToolingRunsFromToolCalls()
    }

    private func trackToolUpdate(runId: String, toolCallId: String, now: Date) {
        guard !runId.isEmpty else { return }
        if wsToolCallsByRun[runId] == nil {
            wsToolCallsByRun[runId] = [toolCallId]
        }
        wsToolTouchedAt["\(runId)|\(toolCallId)"] = now
        wsRunTouchedAt[runId] = now
        syncToolingRunsFromToolCalls()
    }

    private func trackToolEnd(runId: String, toolCallId: String, now: Date) {
        guard !runId.isEmpty else { return }
        if toolCallId == "__active__" {
            wsToolCallsByRun.removeValue(forKey: runId)
        } else if var calls = wsToolCallsByRun[runId] {
            calls.remove(toolCallId)
            if calls.isEmpty {
                wsToolCallsByRun.removeValue(forKey: runId)
            } else {
                wsToolCallsByRun[runId] = calls
            }
        }
        wsToolTouchedAt.removeValue(forKey: "\(runId)|\(toolCallId)")
        wsRunTouchedAt[runId] = now
        syncToolingRunsFromToolCalls()
    }

    private func isToolResultPending(data: [String: Any]) -> Bool {
        let result = data["result"] as? [String: Any]
        let details = result?["details"] as? [String: Any]
        let statusCandidates = [
            result?["status"] as? String,
            details?["status"] as? String,
            result?["state"] as? String,
            details?["state"] as? String
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        let pendingSet: Set<String> = [
            "pending", "running", "processing", "queued", "waiting", "wait", "in_progress", "accepted", "approval-pending"
        ]
        if statusCandidates.contains(where: { pendingSet.contains($0) }) {
            return true
        }
        if let done = result?["done"] as? Bool, !done {
            return true
        }
        if let finished = result?["finished"] as? Bool, !finished {
            return true
        }
        return false
    }

    private func extractChatText(_ payload: [String: Any]) -> String {
        guard
            let message = payload["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else { return "" }
        var chunks: [String] = []
        for block in content {
            guard (block["type"] as? String ?? "").lowercased() == "text" else { continue }
            if let text = block["text"] as? String {
                let cleaned = sanitizeDisplayText(text)
                if !cleaned.isEmpty {
                    chunks.append(cleaned)
                }
            }
        }
        return chunks.joined(separator: "\n")
    }

    private func sanitizeDisplayText(_ text: String) -> String {
        var output = text
        let directControlTokens = [
            "[[reply_to_current]]",
            "[[reply_to_thread]]",
            "[[reply]]",
            "[reply_to_current]",
            "[reply_to_thread]"
        ]
        for token in directControlTokens {
            output = output.replacingOccurrences(of: token, with: " ", options: [.caseInsensitive])
        }

        let patterns = [
            #"\[\[[^\[\]]+\]\]"#, // Remove channel control directives wrapped by [[...]]
            #"<\s*/?\s*think(?:ing)?(?:_[a-zA-Z0-9_-]+)?\s*>"#, // Remove complete <think...> tags
            #"<\s*/?\s*think[^\s>]*"# // Remove incomplete think-tag fragments like </think_never_used_xxx
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let fullRange = NSRange(location: 0, length: (output as NSString).length)
                output = regex.stringByReplacingMatches(in: output, options: [], range: fullRange, withTemplate: " ")
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func incrementalOutputChunk(current: String, previous: String) -> String? {
        let currentText = sanitizeDisplayText(current)
        guard !currentText.isEmpty else { return nil }

        let previousText = sanitizeDisplayText(previous)
        if previousText.isEmpty {
            return currentText
        }
        if currentText == previousText {
            return nil
        }

        if currentText.hasPrefix(previousText) {
            let suffix = String(currentText.dropFirst(previousText.count))
            let chunk = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            return chunk.isEmpty ? nil : chunk
        }

        if previousText.hasPrefix(currentText) {
            return nil
        }

        return currentText
    }

    private func parseSubagentSpawnStatus(_ text: String) -> (status: String, childSessionKey: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }

        if
            let data = trimmed.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let status = (raw["status"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let child = (raw["childSessionKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (status, child.isEmpty ? nil : child)
        }

        let statusRegex = try? NSRegularExpression(pattern: #""status"\s*:\s*"([^"]+)""#, options: [.caseInsensitive])
        let childRegex = try? NSRegularExpression(pattern: #""childSessionKey"\s*:\s*"([^"]+)""#, options: [.caseInsensitive])
        let ns = trimmed as NSString
        let full = NSRange(location: 0, length: ns.length)

        var status = ""
        if
            let statusRegex,
            let match = statusRegex.firstMatch(in: trimmed, options: [], range: full),
            match.numberOfRanges > 1
        {
            status = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var childSessionKey: String?
        if
            let childRegex,
            let match = childRegex.firstMatch(in: trimmed, options: [], range: full),
            match.numberOfRanges > 1
        {
            let child = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !child.isEmpty {
                childSessionKey = child
            }
        }
        return (status, childSessionKey)
    }

    private func parseSubagentCompletionEvent(_ text: String) -> (sessionKey: String, status: String)? {
        let lower = text.lowercased()
        guard lower.contains("source: subagent") || lower.contains("[internal task completion event]") else { return nil }

        let sessionRegex = try? NSRegularExpression(pattern: #"session_key:\s*([^\n\r]+)"#, options: [.caseInsensitive])
        let statusRegex = try? NSRegularExpression(pattern: #"status:\s*([^\n\r]+)"#, options: [.caseInsensitive])
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        guard
            let sessionRegex,
            let sessionMatch = sessionRegex.firstMatch(in: text, options: [], range: full),
            sessionMatch.numberOfRanges > 1
        else { return nil }

        let sessionKey = ns.substring(with: sessionMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionKey.isEmpty else { return nil }

        var status = ""
        if
            let statusRegex,
            let statusMatch = statusRegex.firstMatch(in: text, options: [], range: full),
            statusMatch.numberOfRanges > 1
        {
            status = ns.substring(with: statusMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return (sessionKey, status)
    }

    private func isPendingSubagentStatus(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let keywords = [
            "accepted", "pending", "running", "processing", "queued", "in_progress", "in progress", "waiting"
        ]
        return keywords.contains { normalized.contains($0) }
    }

    private func isTerminalSubagentStatus(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let keywords = [
            "completed", "success", "succeeded", "timed out", "timeout", "failed", "error", "cancelled", "canceled", "blocked"
        ]
        return keywords.contains { normalized.contains($0) }
    }

    private func isSyntheticRuntimeUserMessage(_ text: String) -> Bool {
        let normalized = sanitizeDisplayText(text).lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized.contains("openclaw runtime context (internal)") && normalized.contains("runtime-generated") {
            return true
        }
        if normalized.contains("an async command the user already approved has completed") {
            return true
        }
        return false
    }

    private func resolveToolDisplay(from data: [String: Any]) -> (badge: String, summary: String) {
        let rawCandidates = [
            data["tool"] as? String,
            data["toolName"] as? String,
            data["name"] as? String
        ]
        let raw = rawCandidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "process"
        return resolveToolDisplay(raw: raw)
    }

    private func resolveToolDisplay(raw: String) -> (badge: String, summary: String) {
        let key = raw.lowercased().replacingOccurrences(of: "-", with: "_")
        let table: [String: (String, String)] = [
            "web_search": ("web_search", "正在使用 Web Search 技能"),
            "web_fetch": ("web_fetch", "正在抓取网页内容"),
            "browser": ("browser", "正在操作浏览器"),
            "read": ("read", "正在读取文件"),
            "write": ("write", "正在写入文件"),
            "exec": ("exec", "正在执行命令"),
            "process": ("process", "正在整理与分析"),
            "memory_search": ("memory_search", "正在检索记忆"),
            "memory_get": ("memory_get", "正在读取记忆"),
            "sessions_spawn": ("sessions_spawn", "正在创建子任务"),
            "gateway": ("gateway", "正在连接网关"),
            "canvas": ("canvas", "正在更新可视化")
        ]
        if let mapped = table[key] {
            return mapped
        }
        return (raw, "正在整理与处理中")
    }

    private func loadQuickPromptPoolFromSkills() -> [String] {
        var values: [String] = []
        var seen = Set<String>()
        let files = discoverSkillMarkdownFiles()

        for fileURL in files {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            guard let phrase = phraseFromSkillMarkdown(url: fileURL, content: content) else { continue }
            let cleaned = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count <= 7 else { continue }
            if seen.insert(cleaned).inserted {
                values.append(cleaned)
            }
        }

        for fallback in defaultQuickPromptPool() {
            if seen.insert(fallback).inserted {
                values.append(fallback)
            }
        }

        return values
    }

    private func discoverSkillMarkdownFiles() -> [URL] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: config.openClawRoot, isDirectory: true)
        let scanRoots = [
            root.appendingPathComponent("workspace/skills", isDirectory: true),
            root.appendingPathComponent("workspace/.disabled-skills", isDirectory: true),
            root.appendingPathComponent("extensions/openclaw-lark/skills", isDirectory: true)
        ]

        var urls: [URL] = []
        for scanRoot in scanRoots where fm.fileExists(atPath: scanRoot.path) {
            guard let enumerator = fm.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent == "SKILL.md" else { continue }
                urls.append(fileURL)
            }
        }

        return urls.sorted { $0.path < $1.path }
    }

    private func phraseFromSkillMarkdown(url: URL, content: String) -> String? {
        let slug = url.deletingLastPathComponent().lastPathComponent.lowercased()
        let lower = content.lowercased()
        let corpus = slug + "\n" + String(lower.prefix(5000))

        let mappings: [([String], String)] = [
            (["calendar", "日历", "event"], "安排日程"),
            (["weather", "天气"], "查下天气"),
            (["search", "tavily", "brave", "web"], "查找资料"),
            (["mail", "email"], "写封邮件"),
            (["doc", "文档", "wiki"], "整理文档"),
            (["task", "todo", "reminder"], "安排待办"),
            (["feishu", "wechat", "channel", "im"], "处理消息"),
            (["image", "img", "图像"], "生成配图"),
            (["video", "mov", "短视频"], "生成视频"),
            (["news", "资讯"], "总结资讯"),
            (["coding", "code", "修复"], "修复代码"),
            (["audit", "review"], "代码审计"),
            (["schedule", "cron", "scheduler", "定时"], "安排定时"),
            (["browser", "desktop", "operator"], "打开网页"),
            (["content", "writing", "article", "写作"], "写篇内容"),
            (["translate", "翻译"], "翻译一下"),
            (["memory", "知识"], "查历史记录"),
            (["price", "arbitrage", "比价"], "比价分析"),
            (["xhs", "小红书"], "整理小红书"),
            (["skill", "creator", "evolver"], "优化技能")
        ]

        for (keys, phrase) in mappings {
            if keys.contains(where: { corpus.contains($0) }) {
                return phrase
            }
        }
        return nil
    }

    private func defaultQuickPromptPool() -> [String] {
        let fromConfig = loadQuickPromptPoolFromConfig()
        if !fromConfig.isEmpty {
            return fromConfig
        }
        return [
            "查个天气吧~",
            "看下最新的前沿 AI 消息",
            "自我进化",
            "换一个快的大模型！",
            "看看有没有新版本？",
            "检查下这两天的重要邮件。",
            "给朋友发消息，通知已经遛狗了！"
        ]
    }

    private func loadQuickPromptPoolFromConfig() -> [String] {
        let path = config.quickPromptsPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = raw["quickPrompts"] as? [String]
        else { return [] }
        var seen = Set<String>()
        var cleaned: [String] = []
        for value in values {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if seen.insert(text).inserted {
                cleaned.append(text)
            }
        }
        return cleaned
    }

    private func tailLines(path: String, maxLines: Int) throws -> [String] {
        let fileURL = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        let size = try handle.seekToEnd()
        let tailBytes: UInt64 = 256 * 1024
        let start = size > tailBytes ? size - tailBytes : 0
        try handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else {
            return []
        }
        return content.split(separator: "\n", omittingEmptySubsequences: true).suffix(maxLines).map(String.init)
    }

    private func isRecent(_ date: Date?, now: Date, thresholdSeconds: TimeInterval) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) <= thresholdSeconds
    }
}

struct SpriteVideoView: NSViewRepresentable {
    let assetsDir: String
    let phase: OverlayState

    func makeNSView(context: Context) -> SpriteVideoPlayerView {
        let view = SpriteVideoPlayerView(assetsDir: assetsDir)
        view.setPhase(phase)
        return view
    }

    func updateNSView(_ nsView: SpriteVideoPlayerView, context: Context) {
        nsView.setPhase(phase)
    }
}

final class SpriteVideoPlayerView: NSView {
    private enum AnimState {
        case begin
        case `static`
        case listening
        case taskStart
        case taskLoop
        case taskLeave
        case sleepStart
        case sleepLoop
        case sleepToDeepSleep
        case deepSleepLoop
        case deepSleepToSleep
        case deepSleepLeave
        case sleepLeave
    }

    private struct AnimItem {
        let url: URL?
        let loop: Bool
        let next: AnimState?
    }

    private let assetsDir: String
    private let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let fallbackLabel = NSTextField(labelWithString: "Sprite")
    private let maxDisplayWidth: CGFloat = 160
    private var currentVideoAspect: CGFloat = 1.0

    private var map: [AnimState: AnimItem] = [:]
    private var current: AnimState = .begin
    private var queued: AnimState?
    private var runMode = false
    private var phase: OverlayState = .idle
    private var idleSince: Date?
    private var currentEndObserver: NSObjectProtocol?
    private var idleTimer: Timer?
    private var deepSleepLoopStartedAt: Date?
    private let playbackWatchdogInterval: TimeInterval = 0.8
    private let deepSleepCycleSeconds: TimeInterval = 10
    private var deferredPhase: OverlayState?
    private var isProcessingClipEnd = false

    init(assetsDir: String) {
        self.assetsDir = assetsDir
        super.init(frame: .zero)
        setupView()
        buildMap()
        play(.begin)
        startIdleTimer()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        if let currentEndObserver {
            NotificationCenter.default.removeObserver(currentEndObserver)
        }
        idleTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        let aspect = currentVideoAspect > 0 ? currentVideoAspect : 1.0
        var targetWidth = min(maxDisplayWidth, bounds.width)
        var targetHeight = targetWidth * aspect
        if targetHeight > bounds.height {
            let scale = bounds.height / max(targetHeight, 1)
            targetWidth = targetWidth * scale
            targetHeight = bounds.height
        }
        let originX = (bounds.width - targetWidth) / 2
        let originY = (bounds.height - targetHeight) / 2
        playerLayer.frame = CGRect(x: originX, y: originY, width: targetWidth, height: targetHeight)
        fallbackLabel.frame = bounds
    }

    func setPhase(_ phase: OverlayState) {
        if self.phase == phase, deferredPhase == nil {
            if isLockedPlaybackState(current) {
                ensureCurrentPlaybackIfNeeded()
                return
            }
            applyPhaseUnlocked(phase)
            ensureCurrentPlaybackIfNeeded()
            return
        }
        self.phase = phase
        if isLockedPlaybackState(current) {
            deferredPhase = phase
            return
        }
        deferredPhase = nil
        applyPhaseUnlocked(phase)
    }

    private func applyPhaseUnlocked(_ phase: OverlayState) {
        if phase != .sleeping, scheduleWakeTransitionIfNeeded(for: phase) {
            return
        }
        if phase != .sleeping {
            deepSleepLoopStartedAt = nil
        }

        if phase == .thinking {
            idleSince = nil
            queued = nil
            // Keep task loop running while a task is still in progress (before completed phase).
            if runMode {
                if current == .taskStart || current == .taskLoop {
                    ensureCurrentPlaybackIfNeeded()
                    return
                }
                if current == .taskLeave {
                    queued = .taskLoop
                    return
                }
                play(.taskLoop)
                return
            }
            runMode = false
            if current == .listening {
                ensureCurrentPlaybackIfNeeded()
                return
            }
            play(.listening)
            return
        }

        if phase == .taskStarting {
            runMode = true
            idleSince = nil
            queued = nil
            // Protect against duplicate work-in re-entry caused by transient
            // upstream phase jitter while a run is already in task animation flow.
            if current == .taskStart || current == .taskLoop {
                ensureCurrentPlaybackIfNeeded()
                return
            }
            if current == .taskLeave {
                queued = .taskLoop
                return
            }
            play(.taskStart)
            return
        }

        if phase == .tooling {
            runMode = true
            idleSince = nil
            queued = nil
            if current == .taskStart || current == .taskLoop {
                ensureCurrentPlaybackIfNeeded()
                return
            }
            play(.taskLoop)
            return
        }

        if phase == .completed {
            let hadToolTaskFlow = runMode || current == .taskLoop || current == .taskStart || current == .taskLeave
            runMode = false
            idleSince = Date()
            if hadToolTaskFlow {
                if current == .taskLoop {
                    queued = .taskLeave
                    ensureCurrentPlaybackIfNeeded()
                    return
                }
                play(.taskLeave)
                queued = .static
            } else if current == .listening {
                // Pure Q&A: finish from listening directly back to static, no work-out flourish.
                queued = nil
                play(.static)
            } else if current != .static {
                play(.static)
            }
            return
        }

        if phase == .sleeping {
            runMode = false
            idleSince = Date()
            if isSleepingAnimationState(current) {
                ensureCurrentPlaybackIfNeeded()
                return
            }
            if current == .taskLoop {
                deferredPhase = .sleeping
                queued = .taskLeave
                ensureCurrentPlaybackIfNeeded()
                return
            }
            if current == .static || current == .listening {
                queued = .sleepStart
                ensureCurrentPlaybackIfNeeded()
                return
            }
            if current == .begin || current == .taskLeave {
                play(.sleepStart)
                return
            }
            play(.sleepStart)
            return
        }

        runMode = false
        if current == .taskLoop || current == .taskStart {
            if current == .taskLoop {
                queued = .taskLeave
                idleSince = Date()
                ensureCurrentPlaybackIfNeeded()
                return
            }
            play(.taskLeave)
            queued = .static
            idleSince = Date()
            return
        }

        if current == .listening {
            queued = nil
            play(.static)
            idleSince = Date()
            return
        }

        if current == .static {
            ensureCurrentPlaybackIfNeeded()
            return
        }

        if idleSince == nil {
            idleSince = Date()
        }

        if current != .static && current != .begin {
            play(.static)
        }
    }

    private func scheduleWakeTransitionIfNeeded(for targetPhase: OverlayState) -> Bool {
        guard targetPhase != .sleeping else { return false }
        let wakeState: AnimState
        switch current {
        case .sleepStart, .sleepLoop, .sleepToDeepSleep, .deepSleepToSleep, .sleepLeave:
            wakeState = .sleepLeave
        case .deepSleepLoop, .deepSleepLeave:
            wakeState = .deepSleepLeave
        default:
            return false
        }
        deferredPhase = targetPhase
        if current == wakeState {
            if player.timeControlStatus == .playing {
                return true
            }
            return !hasCurrentClipEnded()
        }
        queued = wakeState
        ensureCurrentPlaybackIfNeeded()
        return true
    }

    private func isSleepingAnimationState(_ state: AnimState) -> Bool {
        switch state {
        case .sleepStart, .sleepLoop, .sleepToDeepSleep, .deepSleepLoop, .deepSleepToSleep, .sleepLeave, .deepSleepLeave:
            return true
        default:
            return false
        }
    }

    private func hasCurrentClipEnded() -> Bool {
        guard let item = player.currentItem else { return false }
        let duration = item.duration.seconds
        let current = item.currentTime().seconds
        guard duration.isFinite, duration > 0, current.isFinite else { return false }
        return current >= max(0, duration - 0.05)
    }

    private func ensureCurrentPlaybackIfNeeded() {
        guard let item = map[current], let expectedURL = item.url else { return }

        let currentURL = (player.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != expectedURL {
            play(current)
            return
        }

        if item.loop {
            if hasCurrentClipEnded(), transitionToQueuedStateIfAny() {
                return
            }
            if player.timeControlStatus == .playing {
                return
            }
            if hasCurrentClipEnded() {
                player.seek(to: .zero)
            }
            player.play()
            return
        }

        if hasCurrentClipEnded() {
            processClipEnd(state: current, item: item)
            return
        }

        if player.timeControlStatus != .playing {
            player.play()
        }
    }

    private func transitionToQueuedStateIfAny() -> Bool {
        guard let queued else { return false }
        self.queued = nil
        play(queued)
        return true
    }

    private func processClipEnd(state: AnimState, item: AnimItem) {
        guard current == state else { return }
        guard !isProcessingClipEnd else { return }
        isProcessingClipEnd = true
        defer { isProcessingClipEnd = false }

        if item.loop {
            if transitionToQueuedStateIfAny() {
                return
            }
            applyDeferredPhaseIfNeeded()
            if transitionToQueuedStateIfAny() {
                return
            }
            player.seek(to: .zero)
            player.play()
            return
        }

        if transitionToQueuedStateIfAny() {
            return
        }
        if let next = item.next {
            play(next)
            applyDeferredPhaseIfNeeded()
            return
        }
        applyDeferredPhaseIfNeeded()
        _ = transitionToQueuedStateIfAny()
    }

    private func isLockedPlaybackState(_ state: AnimState) -> Bool {
        switch state {
        case .begin, .taskStart, .taskLeave:
            return true
        default:
            return false
        }
    }

    private func applyDeferredPhaseIfNeeded() {
        guard let deferred = deferredPhase else { return }
        guard !isLockedPlaybackState(current) else { return }
        deferredPhase = nil
        DispatchQueue.main.async { [weak self] in
            self?.setPhase(deferred)
        }
    }

    private func clearObserver() {
        if let currentEndObserver {
            NotificationCenter.default.removeObserver(currentEndObserver)
            self.currentEndObserver = nil
        }
    }

    private func setupView() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor

        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)

        fallbackLabel.alignment = .center
        fallbackLabel.font = .systemFont(ofSize: 36, weight: .bold)
        fallbackLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        fallbackLabel.backgroundColor = NSColor(white: 0.2, alpha: 0.9)
        fallbackLabel.wantsLayer = true
        fallbackLabel.layer?.cornerRadius = 60
        fallbackLabel.layer?.masksToBounds = true
        fallbackLabel.isHidden = true
        addSubview(fallbackLabel)
    }

    private func buildMap() {
        map[.begin] = AnimItem(url: preferredURL(baseName: "intro-seed"), loop: false, next: .static)
        map[.static] = AnimItem(url: preferredURL(baseName: "idle-core"), loop: true, next: nil)
        map[.listening] = AnimItem(url: preferredURL(baseName: "focus-loop"), loop: true, next: nil)
        map[.taskStart] = AnimItem(url: preferredURL(baseName: "work-in"), loop: false, next: .taskLoop)
        map[.taskLoop] = AnimItem(url: preferredLoopURL(), loop: true, next: nil)
        map[.taskLeave] = AnimItem(url: preferredURL(baseName: "work-out"), loop: false, next: .static)
        map[.sleepStart] = AnimItem(url: preferredURL(baseName: "nap-in"), loop: false, next: .sleepLoop)
        map[.sleepLoop] = AnimItem(url: preferredURL(baseName: "nap-loop"), loop: false, next: .sleepToDeepSleep)
        map[.sleepToDeepSleep] = AnimItem(url: preferredURL(baseName: "nap-to-deep"), loop: false, next: .deepSleepLoop)
        map[.deepSleepLoop] = AnimItem(url: preferredURL(baseName: "deep-loop"), loop: true, next: nil)
        map[.deepSleepToSleep] = AnimItem(url: preferredURL(baseName: "deep-to-nap"), loop: false, next: .sleepLoop)
        map[.deepSleepLeave] = AnimItem(url: preferredURL(baseName: "deep-out"), loop: false, next: nil)
        map[.sleepLeave] = AnimItem(url: preferredURL(baseName: "nap-out"), loop: false, next: nil)
    }

    private func preferredURL(baseName: String) -> URL? {
        let mov = URL(fileURLWithPath: assetsDir).appendingPathComponent("\(baseName).mov")
        if FileManager.default.fileExists(atPath: mov.path) { return mov }
        return nil
    }

    private func preferredLoopURL() -> URL? {
        let candidates = [
            "work-loop.mov"
        ]
        for name in candidates {
            let url = URL(fileURLWithPath: assetsDir).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func updateVideoAspect(from asset: AVAsset) {
        Task { [weak self] in
            guard
                let tracks = try? await asset.loadTracks(withMediaType: .video),
                let track = tracks.first,
                let naturalSize = try? await track.load(.naturalSize),
                let preferredTransform = try? await track.load(.preferredTransform)
            else { return }
            let transformedSize = naturalSize.applying(preferredTransform)
            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)
            guard width > 0, height > 0 else { return }
            await MainActor.run {
                self?.currentVideoAspect = height / width
                self?.needsLayout = true
            }
        }
    }

    private func play(_ state: AnimState) {
        guard let item = map[state], let url = item.url else {
            fallbackLabel.isHidden = false
            return
        }

        if current == state,
           let currentAsset = player.currentItem?.asset as? AVURLAsset,
           currentAsset.url == url
        {
            if item.loop {
                ensureCurrentPlaybackIfNeeded()
            } else if player.timeControlStatus != .playing, !hasCurrentClipEnded() {
                player.play()
            }
            return
        }

        queued = nil
        current = state
        if state == .deepSleepLoop, deepSleepLoopStartedAt == nil {
            deepSleepLoopStartedAt = Date()
        }
        if state != .deepSleepLoop {
            deepSleepLoopStartedAt = nil
        }
        fallbackLabel.isHidden = true

        clearObserver()

        let playerItem = AVPlayerItem(url: url)
        updateVideoAspect(from: playerItem.asset)
        player.replaceCurrentItem(with: playerItem)
        player.seek(to: .zero)
        player.playImmediately(atRate: 1.0)
        needsLayout = true

        self.currentEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.processClipEnd(state: state, item: item)
        }
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: playbackWatchdogInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ensureCurrentPlaybackIfNeeded()
            guard self.phase == .sleeping else {
                self.deepSleepLoopStartedAt = nil
                return
            }
            guard self.current == .deepSleepLoop else {
                self.deepSleepLoopStartedAt = nil
                return
            }
            if self.deepSleepLoopStartedAt == nil {
                self.deepSleepLoopStartedAt = Date()
            }
            guard let started = self.deepSleepLoopStartedAt else { return }
            if Date().timeIntervalSince(started) >= deepSleepCycleSeconds {
                if self.queued == nil {
                    self.queued = .deepSleepToSleep
                }
                self.deepSleepLoopStartedAt = nil
            }
        }
        if let idleTimer {
            RunLoop.main.add(idleTimer, forMode: .common)
        }
    }
}

struct NativeGlassCapsule: NSViewRepresentable {
    let cornerRadius: CGFloat
    let tintOpacity: CGFloat
    let clearStyle: Bool

    func makeNSView(context: Context) -> NSView {
        if clearStyle {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.appearance = NSAppearance(named: .aqua)
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            effect.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
            return effect
        }

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.tintColor = NSColor.black.withAlphaComponent(tintOpacity)
            return glass
        }
        #endif

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        effect.layer?.backgroundColor = NSColor.black.withAlphaComponent(tintOpacity * 0.55).cgColor
        return effect
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if clearStyle {
            if let effect = nsView as? NSVisualEffectView {
                effect.material = .menu
                effect.blendingMode = .behindWindow
                effect.state = .active
                effect.appearance = NSAppearance(named: .aqua)
                effect.wantsLayer = true
                effect.layer?.cornerRadius = cornerRadius
                effect.layer?.masksToBounds = true
                effect.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
            }
            return
        }

        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            glass.tintColor = NSColor.black.withAlphaComponent(tintOpacity)
            return
        }
        #endif

        if let effect = nsView as? NSVisualEffectView {
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.appearance = NSAppearance(named: .darkAqua)
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.backgroundColor = NSColor.black.withAlphaComponent(tintOpacity * 0.55).cgColor
        }
    }
}

struct BubbleView: View {
    let text: String
    let singleLine: Bool
    let loadingOnly: Bool
    let bubbleWidth: CGFloat
    let maxTextHeight: CGFloat
    private var isThinkingStyle: Bool { loadingOnly }
    private let minTextHeight: CGFloat = 22
    private let bubbleHorizontalPadding: CGFloat = 12
    private var bubbleTextBodyWidth: CGFloat {
        max(80, bubbleWidth - bubbleHorizontalPadding * 2)
    }
    private var naturalTextHeight: CGFloat {
        measureNaturalTextHeight(text, width: bubbleTextBodyWidth)
    }
    private var shouldUseScrollableText: Bool {
        naturalTextHeight > maxTextHeight
    }
    private var adaptiveTextContainerHeight: CGFloat {
        min(maxTextHeight, max(minTextHeight, naturalTextHeight))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isThinkingStyle {
                HStack(spacing: 0) {
                    ThinkingLoadingIcon()
                }
                .frame(width: 54, height: 16, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
            } else if singleLine {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.88))
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if shouldUseScrollableText {
                    ScrollView(.vertical, showsIndicators: true) {
                        bubbleTextContent
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(height: adaptiveTextContainerHeight, alignment: .topLeading)
                    .scrollIndicators(.automatic)
                } else {
                    bubbleTextContent
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ZStack {
                NativeGlassCapsule(cornerRadius: 20, tintOpacity: 0.12, clearStyle: true)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.03), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.07), .clear],
                            center: .topLeading,
                            startRadius: 1,
                            endRadius: 56
                        )
                    )
                    .blendMode(.screen)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.38), lineWidth: 0.8)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1.6)
                    .blur(radius: 0.8)
                    .mask(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white, .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
            }
        )
    }

    private var bubbleTextContent: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.88))
            .lineSpacing(1.1)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func measureNaturalTextHeight(_ value: String, width: CGFloat) -> CGFloat {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return minTextHeight }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1.1

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .paragraphStyle: paragraph
        ]
        let bounds = (cleaned as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(bounds.height)
    }
}

private struct BubbleToolRowWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct BubbleToolTickerView: View {
    let tools: [String]
    let availableWidth: CGFloat
    @State private var rowWidth: CGFloat = 0

    private let rowSpacing: CGFloat = 6
    private let loopGap: CGFloat = 18
    private let edgeFadeDistance: CGFloat = 18
    private let horizontalInset: CGFloat = 6
    private var trackWidth: CGFloat {
        max(40, availableWidth - horizontalInset * 2)
    }

    private var shouldMarquee: Bool {
        rowWidth > trackWidth + 1
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if shouldMarquee {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let cycleWidth = max(1, rowWidth + loopGap)
                    let speed: CGFloat = 22
                    let travel = CGFloat((t * Double(speed)).truncatingRemainder(dividingBy: Double(cycleWidth)))

                    HStack(spacing: loopGap) {
                        chipRow
                        chipRow
                    }
                    .offset(x: -travel)
                }
            } else {
                chipRow
            }
        }
        .frame(width: trackWidth, alignment: .leading)
        .frame(height: 26, alignment: .center)
        .clipped()
        .mask(edgeFadeMask)
        .padding(.horizontal, horizontalInset)
        .background(
            chipRow
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: BubbleToolRowWidthPreferenceKey.self, value: proxy.size.width)
                    }
                )
                .hidden()
        )
        .onPreferenceChange(BubbleToolRowWidthPreferenceKey.self) { value in
            rowWidth = value
        }
    }

    private var chipRow: some View {
        HStack(spacing: rowSpacing) {
            ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                ToolChip(text: tool)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var edgeFadeMask: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fade = min(edgeFadeDistance, width * 0.28)
            let startOpaque = min(0.48, fade / width)
            let endOpaque = max(0.52, 1 - fade / width)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: startOpaque),
                    .init(color: .white, location: endOpaque),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

private struct FocusedPromptChipWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ThinkingLoadingIcon: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0 ..< 3, id: \.self) { index in
                    let phase = t * 3.0 - Double(index) * 0.42
                    let wave = (sin(phase * .pi) + 1) / 2
                    Circle()
                        .fill(Color.black.opacity(0.24 + wave * 0.52))
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.78 + wave * 0.32)
                }
            }
        }
        .accessibilityLabel("Loading")
    }
}

struct ToolChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.8))
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                ZStack {
                    NativeGlassCapsule(cornerRadius: 9, tintOpacity: 0.1, clearStyle: true)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.4), lineWidth: 0.8)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.04), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            )
    }
}

struct QuickPromptBarView: View {
    let promptText: String
    let promptPrev2Text: String
    let promptPrevText: String
    let promptNextText: String
    let promptNext2Text: String
    let randomIcon: String
    let token: Int
    let direction: Int
    let scrollProgress: CGFloat
    let sendAction: () -> Void
    let typedSendAction: (String) -> Void
    let hoverChanged: (Bool) -> Void
    @State private var hovering = false
    @State private var inputHovering = false
    @State private var inputMode = false
    @State private var inputText: String = ""
    @State private var shimmerPhase: CGFloat = -1.0
    @State private var wheelSlideOffsetY: CGFloat = 0
    @State private var focusedChipWidth: CGFloat = 0
    @State private var hoverGlowActive = false
    @State private var hoverGlowTravel: CGFloat = -0.8
    @State private var hoverGlowOpacity: Double = 0
    @State private var hoverGlowSequence: Int = 0
    @State private var inputPopGlowActive = false
    @State private var inputPopGlowTravel: CGFloat = -0.8
    @State private var inputPopGlowOpacity: Double = 0
    @State private var inputPopGlowSequence: Int = 0
    @State private var inputReturnMonitor: Any?
    @FocusState private var inputFocused: Bool

    private let interactionStageWidth: CGFloat = 248
    private let interactionStageHeight: CGFloat = 44
    private var centerScaleTransition: AnyTransition {
        .scale(scale: 0.92, anchor: .center).combined(with: .opacity)
    }
    private var centerPopTransition: AnyTransition {
        .scale(scale: 0.82, anchor: .center).combined(with: .opacity)
    }

    var body: some View {
        ZStack {
            if inputMode {
                inputComposer
                    .transition(
                        .asymmetric(insertion: centerScaleTransition, removal: centerScaleTransition)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                defaultBar
                    .transition(
                        .asymmetric(insertion: centerScaleTransition, removal: centerScaleTransition)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(width: interactionStageWidth, height: interactionStageHeight, alignment: .center)
        .animation(.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.1), value: inputMode)
        .onAppear {
            installInputReturnMonitorIfNeeded()
        }
        .onDisappear {
            removeInputReturnMonitor()
        }
    }

    private var defaultBar: some View {
        HStack(spacing: 8) {
            quickPromptButton
            typingEntryButton
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08), value: token)
    }

    private var quickPromptButton: some View {
        Button(action: sendAction) {
            focusedPromptChip
                .overlay(alignment: .center) {
                    if hovering {
                        hoverPromptList
                            .frame(width: max(0, focusedChipWidth), alignment: .center)
                            .allowsHitTesting(false)
                    }
                }
            .onChange(of: token) { _ in
                guard hovering else { return }
                wheelSlideOffsetY = direction >= 0 ? 8 : -8
                withAnimation(.spring(response: 0.22, dampingFraction: 0.72, blendDuration: 0.05)) {
                    wheelSlideOffsetY = 0
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { over in
            hovering = over
            hoverChanged(over)
            if over {
                triggerHoverGlow()
            }
        }
        .onPreferenceChange(FocusedPromptChipWidthPreferenceKey.self) { width in
            if width > 0 {
                focusedChipWidth = width
            }
        }
        .scaleEffect(hovering ? 0.97 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.78, blendDuration: 0.08), value: token)
        .animation(.spring(response: 0.28, dampingFraction: 0.72, blendDuration: 0.05), value: hovering)
    }

    private var typingEntryButton: some View {
        Button(action: enterInputMode) {
            Image(systemName: "keyboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.7))
                .frame(width: 34, height: 26)
                .background(
                    ZStack {
                        NativeGlassCapsule(cornerRadius: 11, tintOpacity: 0.1, clearStyle: true)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        capsuleOverlay(cornerRadius: 11)
                    }
                )
        }
        .buttonStyle(.plain)
        .onHover { over in
            if over, !inputMode {
                enterInputMode()
            }
        }
        .help("输入需求")
    }

    private var inputComposer: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.55))

            TextField("发给 OpenClaw", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.84))
                .focused($inputFocused)
                .onSubmit {
                    submitTypedInput()
                }

            Button(action: submitTypedInput) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.black.opacity(0.36) : Color.black.opacity(0.74))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.28))
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: 192)
        .background(
            ZStack {
                NativeGlassCapsule(cornerRadius: 12, tintOpacity: 0.12, clearStyle: true)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                capsuleOverlay(cornerRadius: 12)
                if inputPopGlowActive {
                    accentSurfaceGlowOverlay(
                        cornerRadius: 12,
                        phase: inputPopGlowTravel,
                        opacity: inputPopGlowOpacity
                    )
                    .transition(.opacity)
                }
            }
        )
        .onHover { over in
            inputHovering = over
            if !over {
                exitInputMode(resetText: true)
            }
        }
        .scaleEffect(inputHovering ? 0.97 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.72, blendDuration: 0.05), value: inputHovering)
        .onAppear {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                inputFocused = true
            }
        }
    }

    private var hoverPromptList: some View {
        VStack(alignment: .center, spacing: 8) {
            hoverPickerLine(promptPrev2Text, opacity: 0.26, weight: .medium)
                .transition(centerPopTransition)
            hoverPickerLine(promptPrevText, opacity: 0.5, weight: .medium)
                .transition(centerPopTransition)
            hoverPickerLine(promptText, opacity: 0.0, weight: .semibold)
                .transition(centerPopTransition)
            hoverPickerLine(promptNextText, opacity: 0.5, weight: .medium)
                .transition(centerPopTransition)
            hoverPickerLine(promptNext2Text, opacity: 0.26, weight: .medium)
                .transition(centerPopTransition)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .offset(y: wheelSlideOffsetY + scrollProgress * 18)
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .white, location: 0.18),
                    .init(color: .white, location: 0.82),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.85, blendDuration: 0.03), value: scrollProgress)
        .animation(.spring(response: 0.26, dampingFraction: 0.78, blendDuration: 0.06), value: token)
    }

    private var focusedPromptChip: some View {
        Text(promptText)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.88))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: 16, alignment: .center)
            .id("prompt-\(token)")
            .transition(centerPopTransition)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    NativeGlassCapsule(cornerRadius: 11, tintOpacity: 0.1, clearStyle: true)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    capsuleOverlay(cornerRadius: 11)
                    if hoverGlowActive {
                        accentSurfaceGlowOverlay(
                            cornerRadius: 11,
                            phase: hoverGlowTravel,
                            opacity: hoverGlowOpacity
                        )
                        .transition(.opacity)
                    }
                }
            )
            .fixedSize(horizontal: true, vertical: false)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: FocusedPromptChipWidthPreferenceKey.self, value: proxy.size.width)
                }
            )
    }

    private func hoverPickerLine(_ text: String, opacity: Double, weight: Font.Weight) -> some View {
        Text(text)
            .font(.system(size: 11.8, weight: weight))
            .foregroundStyle(Color.black.opacity(opacity))
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 12, alignment: .center)
    }

    private func capsuleOverlay(cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.03), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.07), .clear],
                        center: .topLeading,
                        startRadius: 1,
                        endRadius: 36
                    )
                )
                .blendMode(.screen)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.38), lineWidth: 0.8)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1.6)
                .blur(radius: 0.8)
                .mask(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white, .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        }
    }

    private func accentSurfaceGlowOverlay(cornerRadius: CGFloat, phase: CGFloat, opacity: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 46 / 255, green: 255 / 255, blue: 228 / 255, opacity: 0.42),
                                Color(red: 72 / 255, green: 206 / 255, blue: 1.0, opacity: 0.38),
                                Color(red: 184 / 255, green: 116 / 255, blue: 1.0, opacity: 0.32)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(opacity * 0.82)

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color(red: 38 / 255, green: 255 / 255, blue: 231 / 255, opacity: 0.72),
                                Color(red: 102 / 255, green: 219 / 255, blue: 1.0, opacity: 0.68),
                                Color(red: 194 / 255, green: 132 / 255, blue: 1.0, opacity: 0.56),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 1.85, height: proxy.size.height * 1.9)
                    .rotationEffect(.degrees(-9))
                    .offset(x: phase * width * 0.92)
                    .blur(radius: 2.8)
                    .blendMode(.screen)
                    .opacity(opacity * 0.85)

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.white.opacity(0.72),
                                Color(red: 168 / 255, green: 249 / 255, blue: 1.0, opacity: 0.62),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 1.25, height: proxy.size.height * 1.35)
                    .offset(x: phase * width * 0.96)
                    .blur(radius: 1.35)
                    .blendMode(.screen)
                    .opacity(opacity * 0.75)

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color(red: 78 / 255, green: 250 / 255, blue: 230 / 255, opacity: 0.58), lineWidth: 1.0)
                    .opacity(opacity * 0.82)
                    .blendMode(.screen)
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func enterInputMode() {
        hovering = false
        hoverChanged(false)
        inputHovering = false
        triggerInputPopGlow()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.1)) {
            inputMode = true
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            inputFocused = true
        }
    }

    private func exitInputMode(resetText: Bool) {
        inputFocused = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.84, blendDuration: 0.08)) {
            inputMode = false
        }
        if resetText {
            inputText = ""
        }
    }

    private func triggerInputPopGlow() {
        inputPopGlowSequence += 1
        let sequence = inputPopGlowSequence
        inputPopGlowActive = true
        inputPopGlowTravel = -0.8
        inputPopGlowOpacity = 0
        withAnimation(.easeOut(duration: 0.1)) {
            inputPopGlowOpacity = 0.68
        }
        withAnimation(.linear(duration: 0.78)) {
            inputPopGlowTravel = 1.05
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) {
            guard sequence == inputPopGlowSequence else { return }
            withAnimation(.easeOut(duration: 0.24)) {
                inputPopGlowOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.82) {
            guard sequence == inputPopGlowSequence else { return }
            inputPopGlowActive = false
            inputPopGlowTravel = -0.8
        }
    }

    private func triggerHoverGlow() {
        hoverGlowSequence += 1
        let sequence = hoverGlowSequence
        hoverGlowActive = true
        hoverGlowTravel = -0.8
        hoverGlowOpacity = 0
        withAnimation(.easeOut(duration: 0.1)) {
            hoverGlowOpacity = 0.66
        }
        withAnimation(.linear(duration: 0.78)) {
            hoverGlowTravel = 1.05
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard sequence == hoverGlowSequence else { return }
            withAnimation(.easeOut(duration: 0.24)) {
                hoverGlowOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.82) {
            guard sequence == hoverGlowSequence else { return }
            hoverGlowActive = false
            hoverGlowTravel = -0.8
        }
    }

    private func installInputReturnMonitorIfNeeded() {
        guard inputReturnMonitor == nil else { return }
        inputReturnMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard inputMode, inputFocused else { return event }
            guard event.keyCode == 36 || event.keyCode == 76 else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let disallowed: NSEvent.ModifierFlags = [.command, .option, .control]
            guard flags.intersection(disallowed).isEmpty else { return event }

            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
               editor.hasMarkedText() {
                return event
            }

            submitTypedInput()
            return nil
        }
    }

    private func removeInputReturnMonitor() {
        guard let monitor = inputReturnMonitor else { return }
        NSEvent.removeMonitor(monitor)
        inputReturnMonitor = nil
    }

    private func submitTypedInput() {
        let cleaned = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        typedSendAction(cleaned)
        exitInputMode(resetText: true)
    }
}

struct OpenClawStatusControlView: View {
    let running: Bool
    let busy: Bool
    let onTap: () -> Void
    let onSettingsTap: () -> Void
    @State private var hovering = false

    private var expanded: Bool { hovering || busy }
    private var statusColor: Color {
        running
            ? Color(red: 88 / 255, green: 246 / 255, blue: 150 / 255)
            : Color(red: 255 / 255, green: 92 / 255, blue: 92 / 255)
    }

    private var labelText: String {
        if busy {
            return "处理中..."
        }
        return running ? "重载" : "启动"
    }

    private var expandedWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let textWidth = (labelText as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 32
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onTap) {
                ZStack(alignment: .leading) {
                    statusDot
                        .padding(.leading, 5)

                    Text(labelText)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, 22)
                        .opacity(expanded ? 1 : 0)
                }
                .frame(width: expanded ? expandedWidth : 18, height: 24, alignment: .leading)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(expanded ? 0.52 : 0))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(expanded ? 0.22 : 0), lineWidth: 1)
                )
                .clipShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(busy)

            if hovering {
                Button(action: onSettingsTap) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.55))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .onHover { over in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.8, blendDuration: 0.08)) {
                hovering = over
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.8, blendDuration: 0.08), value: expanded)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: statusColor.opacity(0.58), radius: expanded ? 6 : 2, x: 0, y: 0)
    }
}

struct SiriLoadingOrbView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let p1 = CGFloat(sin(t * 1.32))
            let p2 = CGFloat(cos(t * 1.18))
            let p3 = CGFloat(sin(t * 0.92))
            let spin = Angle.degrees(t * 22)
            let counterSpin = Angle.degrees(-t * 17)

            ZStack {
                ZStack {
                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 32 / 255, green: 246 / 255, blue: 216 / 255, opacity: 0.88),
                                    Color(red: 88 / 255, green: 201 / 255, blue: 1.0, opacity: 0.82)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 96, height: 58)
                        .rotationEffect(.degrees(Double(24 + p1 * 20)))
                        .offset(x: p2 * 18, y: p1 * 14)
                        .blur(radius: 1.1)
                        .blendMode(.screen)

                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 255 / 255, green: 88 / 255, blue: 170 / 255, opacity: 0.82),
                                    Color(red: 208 / 255, green: 112 / 255, blue: 1.0, opacity: 0.72)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 104, height: 64)
                        .rotationEffect(.degrees(Double(-30 + p2 * 18)))
                        .offset(x: p1 * -16, y: p3 * -12)
                        .blur(radius: 1.3)
                        .blendMode(.screen)

                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 170 / 255, green: 130 / 255, blue: 1.0, opacity: 0.76),
                                    Color(red: 96 / 255, green: 232 / 255, blue: 1.0, opacity: 0.64)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 88, height: 56)
                        .rotationEffect(.degrees(Double(112 + p3 * 24)))
                        .offset(x: p3 * 14, y: p2 * 12)
                        .blur(radius: 1.8)
                        .blendMode(.screen)
                }
                .rotationEffect(spin)
                .mask(Circle())

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.62),
                                Color(red: 188 / 255, green: 250 / 255, blue: 1.0, opacity: 0.28),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 48
                        )
                    )
                    .rotationEffect(counterSpin)
                    .blendMode(.screen)

                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                Color(red: 94 / 255, green: 228 / 255, blue: 1.0, opacity: 0.3),
                                Color(red: 182 / 255, green: 140 / 255, blue: 1.0, opacity: 0.24)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .compositingGroup()
            .drawingGroup()
        }
        .accessibilityHidden(true)
    }
}

struct OverlayContentView: View {
    @ObservedObject var vm: OverlayViewModel
    private let spriteVideoSize: CGFloat = 208
    private let bubbleWidth: CGFloat = 186
    private let overlayFrameHeight: CGFloat = 398
    private let bubbleOffsetY: CGFloat = -186

    private var bubbleMaxTextHeight: CGFloat {
        let topSafeInset: CGFloat = 12
        let toolsHeight: CGFloat = vm.bubbleTools.isEmpty ? 0 : 32
        let bubbleVerticalPadding: CGFloat = 20
        let available = overlayFrameHeight - abs(bubbleOffsetY) - topSafeInset - toolsHeight - bubbleVerticalPadding
        return min(500, max(90, available))
    }

    private var shouldShowQuickPromptBar: Bool {
        vm.quickPromptVisible
    }
    private var shouldShowThinkingOrb: Bool {
        vm.overlayState == .thinking
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottom) {
                SpriteVideoView(assetsDir: vm.config.assetsDir, phase: vm.overlayState)
                    .frame(width: spriteVideoSize, height: spriteVideoSize)
                    .background(alignment: .center) {
                        if shouldShowThinkingOrb {
                            SiriLoadingOrbView()
                                .frame(width: spriteVideoSize * 0.6, height: spriteVideoSize * 0.6)
                                .transition(.scale(scale: 0.86, anchor: .center).combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: spriteVideoSize, height: spriteVideoSize, alignment: .center)
                    .offset(y: -20)

                if vm.bubbleVisible {
                    VStack(spacing: 6) {
                        if !vm.bubbleTools.isEmpty {
                            BubbleToolTickerView(tools: vm.bubbleTools, availableWidth: bubbleWidth)
                                .frame(width: bubbleWidth, alignment: .center)
                        }

                        BubbleView(
                            text: vm.bubbleText,
                            singleLine: vm.bubbleSingleLine,
                            loadingOnly: vm.bubbleLoadingOnly,
                            bubbleWidth: bubbleWidth,
                            maxTextHeight: bubbleMaxTextHeight
                        )
                        .frame(width: bubbleWidth, alignment: .center)
                    }
                    .offset(y: bubbleOffsetY)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.86, anchor: .bottom).combined(with: .opacity),
                            removal: .scale(scale: 0.93, anchor: .bottom).combined(with: .opacity)
                        )
                    )
                }

                if shouldShowQuickPromptBar {
                    QuickPromptBarView(
                        promptText: vm.quickPromptText,
                        promptPrev2Text: vm.quickPromptPrev2Text,
                        promptPrevText: vm.quickPromptPrevText,
                        promptNextText: vm.quickPromptNextText,
                        promptNext2Text: vm.quickPromptNext2Text,
                        randomIcon: vm.quickPromptIcon,
                        token: vm.quickPromptToken,
                        direction: vm.quickPromptDirection,
                        scrollProgress: vm.quickPromptScrollProgress,
                        sendAction: {
                            vm.sendCurrentQuickPrompt()
                        },
                        typedSendAction: { text in
                            vm.sendTypedPrompt(text)
                        },
                        hoverChanged: { hovering in
                            vm.setQuickPromptHovering(hovering)
                        }
                    )
                    .offset(y: -30)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.94, anchor: .bottom)),
                            removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottom))
                        )
                    )
                }
            }

            OpenClawStatusControlView(
                running: vm.openClawRunning,
                busy: vm.openClawServiceActionInProgress,
                onTap: {
                    vm.handleOpenClawControlTap()
                },
                onSettingsTap: {
                    vm.openAdminPanel()
                }
            )
            .padding(.top, 18)
            .padding(.trailing, 14)
        }
        .frame(width: 292, height: overlayFrameHeight, alignment: .bottom)
        .background(Color.clear)
        .animation(.spring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.1), value: vm.bubbleVisible)
        .animation(.spring(response: 0.3, dampingFraction: 0.82, blendDuration: 0.08), value: shouldShowQuickPromptBar)
        .animation(.spring(response: 0.3, dampingFraction: 0.82, blendDuration: 0.08), value: shouldShowThinkingOrb)
    }
}

final class FloatingWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = true
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum WindowPositionStore {
        static let x = "deskSprite.window.origin.x"
        static let y = "deskSprite.window.origin.y"
    }

    private var window: FloatingWindow?
    private var viewModel: OverlayViewModel?
    private var moveObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let vm = OverlayViewModel(config: AppConfig.load())
        self.viewModel = vm
        print("[desk-sprite] assetsDir=\(vm.config.assetsDir)")

        let host = NSHostingView(rootView: OverlayContentView(vm: vm))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.borderWidth = 0
        host.layer?.shadowOpacity = 0

        let panelSize = NSSize(width: 292, height: 398)
        let anchorScreen = NSScreen.main ?? NSScreen.screens.first
        let visible = anchorScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultOrigin = NSPoint(
            x: visible.midX - panelSize.width / 2,
            y: visible.minY + 56
        )
        let restoredOrigin = restoreWindowOrigin(defaultOrigin: defaultOrigin, panelSize: panelSize)
        let startX = restoredOrigin.x
        let startY = restoredOrigin.y
        let panel = FloatingWindow(contentRect: NSRect(x: startX, y: startY, width: panelSize.width, height: panelSize.height))
        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.borderWidth = 0
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        panel.hasShadow = false
        panel.orderFrontRegardless()
        panel.level = .mainMenu
        NSApp.activate(ignoringOtherApps: true)

        self.window = panel
        installMoveObserver(for: panel)
        ensureWindowVisible(panel, panelSize: panelSize)
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistWindowPosition()
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
    }

    private func installMoveObserver(for panel: NSWindow) {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.persistWindowPosition()
        }
    }

    private func persistWindowPosition() {
        guard let frame = window?.frame else { return }
        UserDefaults.standard.set(frame.origin.x, forKey: WindowPositionStore.x)
        UserDefaults.standard.set(frame.origin.y, forKey: WindowPositionStore.y)
    }

    private func restoreWindowOrigin(defaultOrigin: NSPoint, panelSize: NSSize) -> NSPoint {
        let defaults = UserDefaults.standard
        guard
            defaults.object(forKey: WindowPositionStore.x) != nil,
            defaults.object(forKey: WindowPositionStore.y) != nil
        else {
            return clampWindowOrigin(defaultOrigin, panelSize: panelSize, visible: bestVisibleFrame())
        }

        let saved = NSPoint(
            x: defaults.double(forKey: WindowPositionStore.x),
            y: defaults.double(forKey: WindowPositionStore.y)
        )
        guard saved.x.isFinite, saved.y.isFinite else {
            return clampWindowOrigin(defaultOrigin, panelSize: panelSize, visible: bestVisibleFrame())
        }

        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(NSRect(origin: saved, size: panelSize)) }) {
            return clampWindowOrigin(saved, panelSize: panelSize, visible: screen.visibleFrame)
        }
        return clampWindowOrigin(saved, panelSize: panelSize, visible: bestVisibleFrame())
    }

    private func bestVisibleFrame() -> NSRect? {
        if let main = NSScreen.main?.visibleFrame {
            return main
        }
        if let first = NSScreen.screens.first?.visibleFrame {
            return first
        }
        return nil
    }

    private func clampWindowOrigin(_ origin: NSPoint, panelSize: NSSize, visible: NSRect?) -> NSPoint {
        let frame = visible ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxX = max(frame.minX, frame.maxX - panelSize.width)
        let maxY = max(frame.minY, frame.maxY - panelSize.height)
        return NSPoint(
            x: min(max(origin.x, frame.minX), maxX),
            y: min(max(origin.y, frame.minY), maxY)
        )
    }

    private func ensureWindowVisible(_ panel: NSWindow, panelSize: NSSize) {
        let validateAndFix = { [weak self] in
            guard let self else { return }
            let frame = panel.frame
            let isVisibleOnAnyScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
            guard !isVisibleOnAnyScreen else { return }

            let fallback = bestVisibleFrame() ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let origin = clampWindowOrigin(
                NSPoint(x: fallback.maxX - panelSize.width - 28, y: fallback.minY + 40),
                panelSize: panelSize,
                visible: fallback
            )
            panel.setFrameOrigin(origin)
            panel.orderFrontRegardless()
            persistWindowPosition()
        }

        validateAndFix()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            validateAndFix()
        }
    }
}

@main
struct DeskSpriteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
