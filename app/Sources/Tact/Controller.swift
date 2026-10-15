import AppKit

/// The suggestion lifecycle:
///
///   idle ──hotkey──▶ working ──engine ok, still same chat──▶ shown ──Tab, still same chat──▶ written
///     ▲                 │                                       │
///     └── failed / declined / cancelled ◀───────────────────────┴── Esc, typing, click, chat or input changed
///
/// Every suggestion is bound to the moment it was generated (header
/// fingerprint, chat ID, input text) and is checked again
/// right before it is shown and right before it is written.
@MainActor
final class Controller: NSObject {
    private(set) var config: AppConfig
    private let engine: EngineClient
    private let header: HeaderReader
    let overlay: Overlay
    private let keyTap = KeyTap()
    private var activePlatform: PlatformRegistration?
    private var routeGeneration = 0
    private var requestPlatforms: [String: String] = [:]
    private var runtimeConfig: AppConfig { activePlatform?.runtimeConfig(from: config) ?? config }

    /// The built-in apps' assistants, made the first time each comes to the front.
    private var builtInSessions: [BuiltInApp: ScreenSession] = [:]
    /// A built-in app is in front and turned on: it has the keyboard instead of a plugin.
    private var builtInActive: BuiltInApp?
    /// The assistant of a plugin whose app is read off the screen, while that
    /// plugin's app is in front.
    private var pluginScreen: (id: String, session: ScreenSession)?
    /// The practice chat of the first-run guide, while it is on screen.
    private weak var practice: PracticeChat?
    /// The practice chat is on screen and Tact is in front.
    private var practiceActive = false
    /// The session that has the keyboard: the practice chat, a built-in app's or a plugin's.
    private var activeScreen: ScreenSession? {
        if practiceActive, let practice { return practice }
        if let builtInActive { return session(for: builtInActive) }
        return pluginScreen?.session
    }

    private(set) var hotKey: HotKey?
    private var doubleTap: DoubleTapDetector?
    private(set) var hotKeyProblem: String?
    var ocrTestMode = false
    var saveNextHeader = false

    private struct Trigger {
        let id: String
        let pid: pid_t
        let input: InputSnapshot
        let started: Date
        let platformID: String
        let generation: Int
    }

    private struct Pending {
        let trigger: Trigger
        let text: String
        let mode: String
        let chatID: String
        let chatTitle: String
        let lastMessageID: String
        let headerHash: UInt64
        let input: InputSnapshot
        let background: NSColor?
        let notes: [String]
        let shortNotes: [String]
        let shownAt: Date

        /// The same suggestion shown again over a freshly read input box.
        func restored(input: InputSnapshot) -> Pending {
            Pending(trigger: trigger, text: text, mode: mode, chatID: chatID, chatTitle: chatTitle,
                    lastMessageID: lastMessageID, headerHash: headerHash, input: input, background: background,
                    notes: notes, shortNotes: shortNotes, shownAt: Date())
        }
    }

    private struct Tracking {
        let requestID: String
        let pid: pid_t
        let chatID: String
        let text: String
        var last: String
        let started: Date
    }

    private enum State {
        case idle
        case working(Trigger)
        case shown(Pending)
    }

    private var state: State = .idle
    private var currentCall: EngineCall?
    private var watchTimer: Timer?
    private var trackTimer: Timer?
    private var tracking: Tracking?
    private var chatCache: (hash: UInt64, chatID: String, title: String)?

    // Prefetch: while a chat tool is in front, the engine is asked to resolve the
    // open chat and load its messages ahead of time, so the hotkey only waits
    // for the model. The header is captured again only after a click or a
    // navigation key (the only ways to switch chats); in between, the
    // prepared chat's messages are refreshed by ID.
    private var prepared: (hash: UInt64, chatID: String, at: Date)?
    private var prefetching = false
    private var lastActivity = Date.distantPast
    private var prefetchTimer: Timer?
    private var refreshTimer: Timer?
    private var keyTapRetry: Timer?
    private static let prefetchRefresh: TimeInterval = 15
    private static let activeWindow: TimeInterval = 90

    // Parking: like an editor's inline completion, a whole-sentence
    // suggestion stays attached to its chat and comes back whenever the input
    // is empty again (accepted then deleted, typed over then cleared, chat
    // left and reopened). Sending, Esc, a new trigger or age
    // retire it.
    private var parked: Pending?
    private var parkTimer: Timer?
    private var restoring = false
    private var inputWasEmpty = true
    private var lastSendKeyAt = Date.distantPast
    private var acceptedRequests = Set<String>()
    /// An accepted suggestion is being written; parked suggestions must not
    /// come back over it.
    private var inserting = false
    private static let parkLifetime: TimeInterval = 600
    private var engineProcess: Process?
    /// Write end of the engine's stdin. Never written to: when this process
    /// exits for any reason the pipe closes and the engine shuts itself down.
    private var engineLifeline: Pipe?
    private var engineRestart: Task<Bool, Never>?

    init(config: AppConfig) {
        self.config = config
        self.engine = EngineClient(socketPath: config.socketPath)
        self.header = HeaderReader(config: config)
        self.overlay = Overlay(level: .statusBar)
        super.init()
    }

    private func makeScreenAssistant<Reader: ScreenReader>(_ reader: Reader, platformID: String) -> ScreenAssistant<Reader> {
        let assistant = ScreenAssistant(
            reader: reader, platformID: platformID, overlay: overlay, capture: header,
            callEngine: { [weak self] payload, token in
                guard let self else { throw EngineError.cancelled }
                return try await self.callEngine(payload, token: token)
            },
            sendFeedback: { [engine] payload in
                DispatchQueue.global(qos: .utility).async { _ = try? engine.callSync(payload, timeout: 2) }
            })
        assistant.testMode = { [weak self] in self?.ocrTestMode ?? false }
        return assistant
    }

    private func session(for app: BuiltInApp) -> ScreenSession {
        if let session = builtInSessions[app] { return session }
        let session: ScreenSession
        switch app {
        case .wechat: session = makeScreenAssistant(WeChatAssistant(), platformID: app.platformID)
        case .dingtalk: session = makeScreenAssistant(DingTalkAssistant(), platformID: app.platformID)
        }
        builtInSessions[app] = session
        return session
    }

    /// A plugin whose desktop is read off the screen gets the assistant for
    /// its app; only apps Tact has reading rules for can be.
    private func screenSession(for platform: PlatformRegistration, bundleID: String?) -> ScreenSession? {
        guard platform.desktop?.strategy == PlatformDesktop.screenStrategy else { return nil }
        switch bundleID {
        case TelegramScreen.bundleID: return makeScreenAssistant(TelegramScreen(), platformID: platform.id)
        default: return nil
        }
    }

    /// How the trigger reads to people, from the configuration before the
    /// controller has started.
    var hotKeyDisplay: String {
        if case .doubleTap(_, let display) = TriggerSpec.parse(config.hotkey) { return display }
        if let hotKey { return hotKey.display }
        return config.hotkey
    }

    // MARK: - Setup

    func start() {
        configureTrigger()

        keyTap.handler = { [weak self] type, event in
            MainActor.assumeIsolated { self?.handleTap(type: type, event: event) ?? false }
        }
        if !keyTap.start() {
            Log.info("⚠️ 还不能监听键盘：要先打开辅助功能权限，打开后自动生效")
            waitForKeyTap()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        refreshTimer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(refreshTick),
                                            userInfo: nil, repeats: true)
        parkTimer = Timer.scheduledTimer(timeInterval: 0.4, target: self, selector: #selector(parkTick),
                                         userInfo: nil, repeats: true)
        updateForFrontmost(NSWorkspace.shared.frontmostApplication)
        Task.detached(priority: .utility) { HeaderReader.warmUp() }
    }

    private func configureTrigger() {
        switch TriggerSpec.parse(config.hotkey) {
        case .doubleTap(let modifier, _):
            doubleTap = DoubleTapDetector(modifier: modifier)
        case .combo(let spec):
            setUpCombo(spec)
        case nil:
            hotKeyProblem = L10n.tr("快捷键配置无法解析：\(config.hotkey)", "Invalid keyboard shortcut: \(config.hotkey)")
            Log.info("⚠️ \(hotKeyProblem ?? "")")
        }
    }

    /// The key tap (double ⌃, Tab, Esc) can only be created once
    /// Accessibility is granted, which the user often does after launch:
    /// keep trying instead of needing a restart.
    private func waitForKeyTap() {
        keyTapRetry?.invalidate()
        keyTapRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, AX.isTrusted(prompt: false), self.keyTap.start() else { return }
                timer.invalidate()
                self.keyTapRetry = nil
                self.updateForFrontmost(NSWorkspace.shared.frontmostApplication)
                Log.info("辅助功能权限已生效，开始监听 \(self.hotKeyDisplay)")
            }
        }
    }

    /// Applies settings saved in the settings window without a restart.
    func apply(_ newConfig: AppConfig) {
        let triggerChanged = newConfig.hotkey != config.hotkey
        config = newConfig
        resetPlatformState()
        activePlatform = nil
        updateForFrontmost(NSWorkspace.shared.frontmostApplication)
        guard triggerChanged else { return }
        hotKey?.unregister()
        hotKey = nil
        doubleTap = nil
        hotKeyProblem = nil
        configureTrigger()
        updateForFrontmost(NSWorkspace.shared.frontmostApplication)
    }

    private func setUpCombo(_ spec: String) {
        if let hk = HotKey(spec: spec) {
            hotKey = hk
            hk.onPress = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hotKeyPressed()
                }
            }
            if !hk.installHandler() { hotKeyProblem = L10n.tr("快捷键处理器安装失败", "Could not install the keyboard shortcut handler") }
        } else {
            hotKeyProblem = L10n.tr("快捷键配置无法解析：\(spec)", "Invalid keyboard shortcut: \(spec)")
            Log.info("⚠️ \(hotKeyProblem ?? "")")
        }
    }

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        updateForFrontmost(app)
        if activePlatform != nil { schedulePrefetch(after: 0.3) }
    }

    /// Switching instances retires all UI and asynchronous cache work.
    private func resetPlatformState() {
        routeGeneration += 1
        builtInSessions.values.forEach { $0.reset(detail: "platform_changed") }
        pluginScreen?.session.reset(detail: "platform_changed")
        pluginScreen = nil
        if case .shown(let pending) = state { invalidate(pending, reason: "platform_changed", toast: nil) }
        cancelWorking()
        stopWatch()
        overlay.hide()
        state = .idle
        clearParked()
        chatCache = nil
        prepared = nil
        trackTimer?.invalidate()
        trackTimer = nil
        tracking = nil
        doubleTap?.otherInput()
        prefetchTimer?.invalidate()
        prefetchTimer = nil
        prefetching = false
    }

    private func routeIsCurrent(_ t: Trigger) -> Bool {
        t.generation == routeGeneration && activePlatform?.id == t.platformID
            && config.platformRegistry.match(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.id == t.platformID
    }

    /// Keyboard handling is active only for a uniquely matched platform.
    private func updateForFrontmost(_ frontmost: NSRunningApplication?) {
        let practiceFront = practice != nil && frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if practiceActive && !practiceFront { practice?.reset(detail: "app_deactivated") }
        practiceActive = practiceFront
        let builtInFront = BuiltInApp.app(bundleID: frontmost?.bundleIdentifier).flatMap { config.builtIn.contains($0) ? $0 : nil }
        if let active = builtInActive, active != builtInFront { builtInSessions[active]?.reset(detail: "app_deactivated") }
        builtInActive = builtInFront
        let match = builtInFront != nil ? nil : config.platformRegistry.match(bundleID: frontmost?.bundleIdentifier)
        if activePlatform?.id != match?.id {
            resetPlatformState()
            activePlatform = match
        }
        if let match, pluginScreen == nil, let session = screenSession(for: match, bundleID: frontmost?.bundleIdentifier) {
            pluginScreen = (match.id, session)
        }
        header.config = runtimeConfig
        let inChat = practiceFront || builtInFront != nil || match != nil && match?.manifest?.capabilities["composer.read"] == true
            && match?.manifest?.capabilities["composer.apply"] == true
        keyTap.setEnabled(inChat)
        if !inChat {
            prefetchTimer?.invalidate()
            prefetchTimer = nil
        }
        guard let hk = hotKey else { return }
        if inChat {
            let status = hk.register()
            if status == noErr {
                hotKeyProblem = nil
            } else {
                hotKeyProblem = L10n.tr("快捷键 \(hk.display) 注册失败（\(status)），可能被其他应用占用，请在配置里换一个", "Could not register shortcut \(hk.display) (\(status)). Another app may be using it. Choose another shortcut in settings")
                Log.info("⚠️ \(hotKeyProblem ?? "")")
            }
        } else {
            hk.unregister()
        }
    }

    // MARK: - Practice

    /// The guide's practice chat takes the hotkey, Tab and Esc while it is
    /// on screen and Tact is in front.
    func beginPractice(_ chat: PracticeChat) {
        practice = chat
        updateForFrontmost(NSWorkspace.shared.frontmostApplication)
    }

    func endPractice() {
        practice?.reset(detail: "")
        practice = nil
        updateForFrontmost(NSWorkspace.shared.frontmostApplication)
    }

    /// One suggestion for the practice chat, from the running engine.
    func practiceSuggestion(_ payload: [String: Any]) async -> [String: Any]? {
        try? await callEngine(payload, token: EngineCall())
    }

    // MARK: - Engine process

    func engineReachable() -> Bool {
        (try? engine.callSync(["op": "ping"], timeout: 1)) != nil
    }

    func ensureEngine() {
        if engineReachable() {
            Log.info("引擎已在运行")
            return
        }
        launchEngine()
    }

    private func engineReady() async -> Bool {
        (await engineRequest(["op": "ping"], timeout: 1))?["ok"] as? Bool == true
    }

    private func launchEngine() {
        guard engineProcess?.isRunning != true else { return }
        let command = config.resolvedEngineCommand
        guard let executable = command.first else {
            Log.info("⚠️ 引擎没有运行，也没有配置 app.engine_command；先在终端运行 tactd serve")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst()) + ["--exit-with-stdin"]
        var environment = ProcessInfo.processInfo.environment
        let keyEnv = config.apiKeyEnv.isEmpty ? AppConfig.defaultAPIKeyEnv : config.apiKeyEnv
        if let key = Keychain.read(Keychain.modelKey), !key.isEmpty { environment[keyEnv] = key }
        process.environment = environment
        let lifeline = Pipe()
        process.standardInput = lifeline
        let logPath = Self.engineLogPath
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
            engineProcess = process
            engineLifeline = lifeline
            Log.info("已启动引擎：\(executable)，日志在 \(logPath)")
        } catch {
            Log.info("⚠️ 启动引擎失败：\(error.localizedDescription)")
        }
    }

    /// The engine can disappear (crash, kill, or an orphan from an older run
    /// that later exited); restart it once instead of failing every request.
    private func callEngine(_ payload: [String: Any], token: EngineCall) async throws -> [String: Any] {
        do {
            return try await engine.call(payload, timeout: config.requestTimeout, token: token)
        } catch EngineError.connect {
            Log.info("连不上引擎，重新启动")
            if !(await engineReady()) { launchEngine() }
            for _ in 0..<20 {
                if await engineReady() { break }
                if token.isCancelled { throw EngineError.cancelled }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return try await engine.call(payload, timeout: config.requestTimeout, token: token)
        }
    }

    func shutdown() {
        engineProcess?.terminate()
    }

    /// Restarts the engine so it picks up a changed config or key. Returns
    /// false when the running engine was not started by this app.
    func restartEngine() async -> Bool {
        if let engineRestart { return await engineRestart.value }
        let restart = Task { await self.performEngineRestart() }
        engineRestart = restart
        let result = await restart.value
        engineRestart = nil
        return result
    }

    private func performEngineRestart() async -> Bool {
        if let process = engineProcess, process.isRunning {
            resetPlatformState()
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // A custom engine may ignore termination. Keep ownership and
            // never launch a duplicate while that process is still alive.
            guard !process.isRunning else { return false }
        } else if await engineReady() {
            return false
        } else {
            resetPlatformState()
        }
        engineProcess = nil
        engineLifeline = nil
        chatCache = nil
        prepared = nil
        launchEngine()
        for _ in 0..<30 {
            if await engineReady() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    static var engineLogPath: String { (AppConfig.directory as NSString).appendingPathComponent("engine.log") }

    /// Why the engine did not come back after a restart: in the engine's own
    /// words when it exited (a configuration it refused, say), otherwise the
    /// likely cause, an engine started separately that keeps the socket.
    func engineRestartProblem() -> String {
        if engineProcess?.isRunning != true, let reason = Self.lastLine(ofFile: Self.engineLogPath) {
            return L10n.tr("引擎没能启动：\(reason)", "The engine could not start: \(reason)")
        }
        return L10n.tr("引擎没能重启。如果它是在终端里单独启动的，请先关掉它", "The engine could not restart. If you started it separately in Terminal, stop it first")
    }

    /// The last line written to a log, without the timestamp in front of it.
    static func lastLine(ofFile path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        guard let last = text.split(whereSeparator: \.isNewline).last.map(String.init) else { return nil }
        let line = last.replacingOccurrences(of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} "#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    /// One short request with the current model settings, for the test
    /// connection button.
    func testModel(timeout: TimeInterval = 30) async -> (ok: Bool, message: String) {
        guard let r = try? await engine.call(["op": "model_test"], timeout: timeout) else {
            return (false, L10n.tr("连不上引擎", "Cannot connect to the engine"))
        }
        let response = EngineResponse(r)
        guard response.ok else { return (false, response.error ?? L10n.tr("模型出错", "Model error")) }
        let ms = (r["timing_ms"] as? [String: Any])?["model"] as? NSNumber
        return (true, L10n.tr("连接正常，\(ms?.intValue ?? 0) ms，回复「\(r["note"] as? String ?? "")」", "Connected in \(ms?.intValue ?? 0) ms; reply: “\(r["note"] as? String ?? "")”"))
    }

    /// A plain engine request for the settings window; nil when the engine
    /// cannot be reached.
    func engineRequest(_ payload: [String: Any], timeout: TimeInterval) async -> [String: Any]? {
        try? await engine.call(payload, timeout: timeout)
    }

    /// Only a verified, explicitly selected instance may run a connection
    /// test. Catalog discovery never executes a plugin or reads conversations.
    func checkPlatformConnection(id: String) async -> (ok: Bool, message: String, count: Int?) {
        let matches = config.platformRegistry.registrations.filter { $0.id == id }
        guard matches.count == 1, let registration = matches.first,
              registration.available, let manifest = registration.manifest else {
            return (false, L10n.tr("平台插件不可用，请先检查插件配置", "The platform plugin is unavailable. Check its configuration"), nil)
        }
        var generation = routeGeneration
        for attempt in 0..<2 {
            do {
                let catalog = try await platformCatalog()
                guard generation == routeGeneration else { throw PlatformProbeError.changed }
                try Self.verifyPlatformCatalog(catalog, registration: registration, manifest: manifest)
                let raw = try await engine.call(["op": "platform_test", "platform_id": id], timeout: 30)
                guard generation == routeGeneration else { throw PlatformProbeError.changed }
                let response: PlatformProbeResponse
                do {
                    response = try JSONDecoder().decode(PlatformProbeResponse.self,
                        from: JSONSerialization.data(withJSONObject: raw))
                } catch { throw PlatformProbeError.outdated }
                if response.errorCode == "bad_request", response.platformID == nil {
                    throw PlatformProbeError.outdated
                }
                guard response.platformID == id else { throw PlatformProbeError.mismatch }
                guard response.ok else {
                    return (false, response.error ?? L10n.tr("平台连接失败，请检查账号登录和插件配置", "Could not connect to the platform. Check account sign-in and plugin settings"), nil)
                }
                guard let count = response.count, count >= 0 else { throw PlatformProbeError.outdated }
                return (true, L10n.tr("连接正常，读到 \(count) 个会话", "Connected; read \(count) chats"), count)
            } catch let issue as PlatformProbeError {
                if attempt == 0, issue.canRestart, engineProcess?.isRunning == true {
                    let beforeRestart = routeGeneration
                    if await restartEngine() {
                        guard routeGeneration == beforeRestart + 1 else {
                            return (false, PlatformProbeError.changed.localizedDescription, nil)
                        }
                        generation = routeGeneration
                        continue
                    }
                }
                return (false, issue.localizedDescription, nil)
            } catch {
                return (false, L10n.tr("连不上引擎，请检查引擎是否运行", "Cannot connect to the engine. Check that it is running"), nil)
            }
        }
        return (false, PlatformProbeError.outdated.localizedDescription, nil)
    }

    /// Recover a missing engine before discovering the catalog. An existing
    /// external listener is reused, and launchEngine never replaces a process.
    private func platformCatalog() async throws -> [String: Any] {
        do {
            return try await engine.call(["op": "platforms"], timeout: 5)
        } catch EngineError.connect {
            if !(await engineReady()) { launchEngine() }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if Task.isCancelled { throw EngineError.cancelled }
                if await engineReady() {
                    return try await engine.call(["op": "platforms"], timeout: 5)
                }
                guard engineProcess?.isRunning == true else { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw EngineError.connect(ECONNREFUSED)
        }
    }

    private static func verifyPlatformCatalog(_ raw: [String: Any], registration: PlatformRegistration,
                                              manifest: PlatformManifest) throws {
        let catalog: PlatformProbeCatalog
        do {
            catalog = try JSONDecoder().decode(PlatformProbeCatalog.self,
                from: JSONSerialization.data(withJSONObject: raw))
        } catch { throw PlatformProbeError.outdated }
        guard catalog.ok, let platforms = catalog.platforms else { throw PlatformProbeError.outdated }
        let matches = platforms.filter { $0.id == registration.id }
        guard matches.count == 1, let observed = matches.first else { throw PlatformProbeError.mismatch }
        guard observed.enabled == registration.enabled,
              observed.available == registration.enabled,
              observed.state == (registration.enabled ? "ready" : "disabled"),
              observed.capabilities["conversations.list"] == true,
              observed.capabilities["messages.read"] == true else { throw PlatformProbeError.mismatch }
        let pluginDirectory = URL(fileURLWithPath: registration.manifestPath).deletingLastPathComponent().path
        let override = registration.configuration["command"] as? [String]
        let expectedCommand = (override ?? manifest.entrypoint).map { argument in
            let expanded = argument.replacingOccurrences(of: "${plugin_dir}", with: pluginDirectory)
            return override == nil ? expanded : AppConfig.expand(expanded)
        }
        guard let observedCommand = observed.command else { throw PlatformProbeError.outdated }
        guard observedCommand == expectedCommand else { throw PlatformProbeError.mismatch }
        guard observed.pluginID == manifest.id, observed.version == manifest.version,
              observed.capabilities == manifest.capabilities,
              let actualPath = observed.manifest,
              URL(fileURLWithPath: actualPath).standardizedFileURL.path ==
                URL(fileURLWithPath: registration.manifestPath).standardizedFileURL.path else {
            throw PlatformProbeError.mismatch
        }
    }

    func statsData() async -> StatsData? {
        guard let r = try? await engine.call(["op": "stats"], timeout: 5),
              let data = r["stats_data"] as? [String: Any] else { return nil }
        return StatsData(data)
    }

    // MARK: - Trigger

    private func hotKeyPressed() {
        let app = NSWorkspace.shared.frontmostApplication
        updateForFrontmost(app)
        if let session = activeScreen, let app {
            session.trigger(app)
            return
        }
        guard let app, let platform = activePlatform,
              platform.manifest?.capabilities["composer.read"] == true,
              platform.manifest?.capabilities["composer.apply"] == true else { return }
        if case .shown(let p) = state { dismiss(p, event: "dismissed", detail: "retriggered") }
        cancelWorking()
        clearParked()
        guard let snap = AX.inputSnapshot(pid: app.processIdentifier) else {
            Log.info("没拿到输入框：先点一下聊天应用的输入框再按快捷键")
            NSSound.beep()
            return
        }
        let trigger = Trigger(id: UUID().uuidString, pid: app.processIdentifier, input: snap, started: Date(),
                              platformID: platform.id, generation: routeGeneration)
        if requestPlatforms.count > 1024 { requestPlatforms.removeAll() }
        requestPlatforms[trigger.id] = platform.id
        state = .working(trigger)
        overlay.showWorking(caret: snap.caret, input: snap.frame, fontSize: CGFloat(runtimeConfig.ghostFontSize),
                            offset: CGPoint(x: runtimeConfig.ghostOffsetX, y: runtimeConfig.ghostOffsetY))
        overlay.follow(pid: trigger.pid, frame: snap.windowFrame)
        Task { await self.run(trigger) }
    }

    private func isCurrent(_ id: String) -> Bool {
        if case .working(let t) = state, t.id == id, routeIsCurrent(t) { return true }
        return false
    }

    private func cancelWorking() {
        guard case .working = state else { return }
        currentCall?.cancel()
        currentCall = nil
        state = .idle
        overlay.hide()
    }

    private func fail(_ t: Trigger, _ message: String) {
        state = .idle
        currentCall = nil
        overlay.showToast(message, input: t.input.frame, duration: 3, kind: .warning)
        Log.info("失败：\(message)")
    }

    private func run(_ t: Trigger) async {
        let snap = t.input
        let rect = header.headerRect(input: snap.frame, window: snap.windowFrame)

        let captureStart = Date()
        let window: CGImage
        do {
            window = try await header.captureWindow(pid: t.pid, windowFrame: snap.windowFrame)
        } catch {
            guard isCurrent(t.id) else { return }
            fail(t, (error as? HeaderError)?.errorDescription ?? L10n.tr("截不到顶部栏：\(error.localizedDescription)。检查屏幕录制权限", "Could not capture the header: \(error.localizedDescription). Check screen recording permission"))
            return
        }
        let captureMS = ms(since: captureStart)
        guard isCurrent(t.id) else { return }
        guard let image = HeaderReader.crop(window, windowFrame: snap.windowFrame, to: rect) else {
            fail(t, L10n.tr("顶部栏区域超出了窗口范围，检查插件的 desktop.header 设置", "The header area extends beyond the window. Check the plugin desktop.header settings"))
            return
        }
        // The input's top-right corner is empty when there is no text yet,
        // which is when the ghost (and the placeholder it covers) appears.
        let background = HeaderReader.color(in: window, windowFrame: snap.windowFrame,
                                            at: CGPoint(x: snap.frame.maxX - 6, y: snap.frame.minY + 3))

        if saveNextHeader || config.debugSaveHeader {
            saveNextHeader = false
            let path = (AppConfig.directory as NSString)
                .appendingPathComponent("debug/header-\(Int(Date().timeIntervalSince1970)).png")
            HeaderReader.savePNG(image, to: path)
            Log.info("顶部栏截图已保存：\(path)")
        }

        let hash = HeaderReader.fingerprint(image)
        var payload: [String: Any] = [
            "op": ocrTestMode ? "resolve" : "suggest",
            "request_id": t.id,
            "platform_id": t.platformID,
            "input": snap.value,
        ]
        var lines: [OCRLine] = []
        var ocrMS = 0
        if !ocrTestMode, let cache = chatCache, cache.hash == hash {
            payload["chat_id"] = cache.chatID
        } else {
            let ocrStart = Date()
            do {
                lines = try await Task.detached(priority: .userInitiated, operation: {
                    try HeaderReader.recognize(image)
                }).value
            } catch {
                guard isCurrent(t.id) else { return }
                fail(t, L10n.tr("文字识别失败：\(error.localizedDescription)", "Text recognition failed: \(error.localizedDescription)"))
                return
            }
            ocrMS = ms(since: ocrStart)
            guard isCurrent(t.id) else { return }
            if lines.isEmpty {
                fail(t, L10n.tr("顶部栏没识别出文字。可以在菜单里保存一次顶部栏截图，检查截取位置", "No text was recognized in the header. Save a header screenshot from the menu to check the capture area"))
                return
            }
            payload["ocr_lines"] = lines.map { line -> [String: Any] in ["text": line.text, "height": line.height] }
        }

        let token = EngineCall()
        currentCall = token
        let raw: [String: Any]
        do {
            raw = try await callEngine(payload, token: token)
        } catch EngineError.cancelled {
            return
        } catch {
            guard isCurrent(t.id) else { return }
            fail(t, (error as? LocalizedError)?.errorDescription ?? "\(error)")
            return
        }
        guard isCurrent(t.id) else { return }
        currentCall = nil
        guard raw["platform_id"] as? String == t.platformID else {
            fail(t, L10n.tr("引擎平台配置未生效，请重启引擎后再试", "The platform configuration has not taken effect. Restart the engine and try again"))
            return
        }
        let r = EngineResponse(raw)

        if ocrTestMode {
            state = .idle
            let top = lines.first?.text ?? ""
            let verdict = r.ok ? L10n.tr("匹配到：\(r.chatTitle ?? "?")（\(r.method ?? "")）", "Matched: \(r.chatTitle ?? "?") (\(r.method ?? ""))") : L10n.tr("未匹配：\(r.friendlyError)", "No match: \(r.friendlyError)")
            Log.console("OCR 测试 识别行=\(lines.map { $0.text }) 截图 \(captureMS)ms OCR \(ocrMS)ms \(verdict)")
            overlay.showToast(L10n.tr("识别：\(top)\n\(verdict)\n截图 \(captureMS) ms · OCR \(ocrMS) ms", "Recognized: \(top)\n\(verdict)\nCapture \(captureMS) ms · OCR \(ocrMS) ms"), input: snap.frame, duration: 4)
            return
        }

        guard r.ok else {
            state = .idle
            overlay.showToast(r.friendlyError, input: snap.frame, duration: 3, kind: .warning)
            Log.info("引擎返回 \(r.errorCode ?? "error")")
            return
        }
        if let id = r.chatID { chatCache = (hash, id, r.chatTitle ?? id) }

        guard let text = r.suggestion, !text.isEmpty else {
            state = .idle
            overlay.showToast(L10n.tr("这次不建议", "No suggestion this time"), input: snap.frame, duration: 1.5)
            return
        }

        await AX.waitForStillWindow(pid: t.pid, from: snap.windowFrame)
        guard isCurrent(t.id) else { return }
        // Check before display: same app, same input text, same chat.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == t.pid,
              let now = AX.inputSnapshot(pid: t.pid), now.value == snap.value, CFEqual(now.element, snap.element) else {
            state = .idle
            overlay.hide()
            feedback(t.id, "voided", chatID: r.chatID, detail: "changed_before_display")
            return
        }
        let sameChat = await headerStillMatches(pid: t.pid, snap: now, hash: hash, title: r.chatTitle ?? "")
        guard isCurrent(t.id) else { return }
        guard sameChat, let focused = AX.inputSnapshot(pid: t.pid), focused.value == now.value,
              CFEqual(focused.element, now.element) else {
            state = .idle
            overlay.showToast(L10n.tr("会话已切换，建议作废", "The chat changed. Suggestion discarded"), input: now.frame, duration: 1.5)
            feedback(t.id, "voided", chatID: r.chatID, detail: "chat_changed_before_display")
            return
        }

        let pending = Pending(
            trigger: t, text: text, mode: r.mode, chatID: r.chatID ?? "", chatTitle: r.chatTitle ?? "",
            lastMessageID: r.lastMessageID ?? "", headerHash: hash, input: now, background: background,
            notes: r.notes, shortNotes: r.shortNotes, shownAt: Date()
        )
        display(pending)
        Log.info("建议已显示：\(text.count) 字，模式 \(r.mode)，总耗时 \(ms(since: t.started)) ms（截图 \(captureMS)，OCR \(ocrMS)，引擎 \(r.timing)）")
    }

    /// Fast path: the header pixels did not change. Slow path: OCR again and
    /// look for the chat title.
    private func headerStillMatches(pid: pid_t, snap: InputSnapshot, hash: UInt64, title: String) async -> Bool {
        let rect = header.headerRect(input: snap.frame, window: snap.windowFrame)
        guard let image = try? await header.capture(pid: pid, windowFrame: snap.windowFrame, rect: rect) else {
            return false
        }
        if HeaderReader.fingerprint(image) == hash { return true }
        guard !title.isEmpty else { return false }
        let lines = (try? await Task.detached(priority: .userInitiated, operation: {
            try HeaderReader.recognize(image)
        }).value) ?? []
        if TextUtil.headerMatches(lines: lines, title: title) { return true }
        // Sizes only, never the text: enough to tell a blank capture from
        // other words or a name read differently.
        let lengths = lines.prefix(4).map { TextUtil.normalize($0.text).count }
        Log.info("顶部栏和生成时不同：会话名 \(TextUtil.normalize(title).count) 字，这次读到 \(lines.count) 行（前几行 \(lengths) 字）")
        return false
    }

    // MARK: - Shown

    /// `report` is false when a parked suggestion comes back, so the stats
    /// count each suggestion once.
    private func display(_ p: Pending, report: Bool = true) {
        guard routeIsCurrent(p.trigger) else { return }
        var asGhost = false
        if p.mode == "complete", activePlatform?.manifest?.capabilities["overlay.inline"] == true {
            parked = p
            inputWasEmpty = true
            switch overlay.showGhost(p.text, tags: p.shortNotes, caret: p.input.caret, input: p.input.frame,
                                     fontSize: CGFloat(runtimeConfig.ghostFontSize),
                                     offset: CGPoint(x: runtimeConfig.ghostOffsetX, y: runtimeConfig.ghostOffsetY),
                                     background: p.background) {
            case .shown: asGhost = true
            case .tooWide: Log.info("输入框剩余宽度不足，改用气泡")
            case .tooTall: Log.info("建议换行后超过输入框高度（\(p.text.count) 字），改用气泡")
            }
        }
        if !asGhost {
            overlay.showBubble(p.text, notes: p.notes, input: p.input.frame, fontSize: CGFloat(runtimeConfig.ghostFontSize), rewrite: p.mode == "rewrite")
        }
        state = .shown(p)
        // Smooth while the window is dragged; the watch then redraws the
        // suggestion against the input box where it ends up.
        overlay.follow(pid: p.trigger.pid, frame: p.input.windowFrame)
        startWatch()
        guard report else { return }
        feedback(p.trigger.id, "shown", chatID: p.chatID, mode: p.mode, suggestionLen: p.text.count,
                 latency: ms(since: p.trigger.started), detail: asGhost ? "ghost" : "bubble")
    }

    /// Runs on the main run loop for every modifier change, key press and
    /// click while a chat tool is in front. Returns true to swallow the event.
    private func handleTap(type: CGEventType, event: CGEvent) -> Bool {
        let seconds = Double(event.timestamp) / 1_000_000_000
        if type == .flagsChanged {
            if doubleTap?.flagsChanged(event.flags, at: seconds) == true {
                // Leave the tap callback quickly; the trigger does AX calls.
                DispatchQueue.main.async { self.hotKeyPressed() }
            }
            return false
        }
        doubleTap?.otherInput()
        if let session = activeScreen { return session.handle(type: type, event: event) }
        noteActivity(type: type, event: event)
        if type == .keyDown, isSendKey(event) { noteSend() }
        guard case .shown(let p) = state else { return false }
        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if code == 48 && mods.isEmpty { // Tab
                accept(p)
                return true
            }
            if code == 53 { // Esc
                dismiss(p, event: "dismissed", detail: "esc")
                clearParked()
                return true
            }
            dismiss(p, event: "dismissed", detail: "typing")
            return false
        }
        dismiss(p, event: "dismissed", detail: "click")
        return false
    }

    private func dismiss(_ p: Pending, event: String, detail: String) {
        stopWatch()
        overlay.hide()
        state = .idle
        feedback(p.trigger.id, event, chatID: p.chatID, mode: p.mode, suggestionLen: p.text.count,
                 latency: ms(since: p.shownAt), detail: detail)
    }

    private func invalidate(_ p: Pending, reason: String, toast: String?) {
        dismiss(p, event: "voided", detail: reason)
        if let toast = toast { overlay.showToast(toast, input: p.input.frame, duration: 1.5) }
    }

    private func startWatch() {
        stopWatch()
        watchTimer = Timer.scheduledTimer(timeInterval: 0.35, target: self, selector: #selector(watchTick),
                                          userInfo: nil, repeats: true)
    }

    private func stopWatch() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    @objc private func watchTick() {
        guard case .shown(let p) = state else {
            stopWatch()
            return
        }
        guard routeIsCurrent(p.trigger), NSWorkspace.shared.frontmostApplication?.processIdentifier == p.trigger.pid else {
            invalidate(p, reason: "app_deactivated", toast: nil)
            return
        }
        guard let now = AX.inputSnapshot(pid: p.trigger.pid) else {
            invalidate(p, reason: "input_lost", toast: nil)
            return
        }
        if now.value != p.input.value || !CFEqual(now.element, p.input.element) {
            invalidate(p, reason: "input_changed", toast: nil)
        } else if abs(now.frame.minX - p.input.frame.minX) > 1 || abs(now.frame.minY - p.input.frame.minY) > 1
                    || abs(now.frame.width - p.input.frame.width) > 1 || abs(now.frame.height - p.input.frame.height) > 1 {
            // The same input with the same text, moved or resized with its
            // window: the suggestion follows it.
            display(p.restored(input: now), report: false)
        } else if Date().timeIntervalSince(p.shownAt) > 120 {
            invalidate(p, reason: "timeout", toast: nil)
        }
    }

    // MARK: - Parking

    private func clearParked() {
        parked = nil
        acceptedRequests.removeAll()
    }

    private func isSendKey(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == 36 || code == 76 else { return false }
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        switch activePlatform?.desktop?.sendShortcut {
        case "command+return": return mods == .maskCommand
        case "control+return": return mods == .maskControl
        case "return": return mods.isEmpty
        default: return false
        }
    }

    private func noteSend() {
        lastSendKeyAt = Date()
        // The input had text, so this Return sent it: the parked suggestion is
        // used up, and the prepared history now misses the sent message.
        if !inputWasEmpty { clearParked() }
        if let p = prepared { prepared = (p.hash, p.chatID, .distantPast) }
    }

    /// Watches for the input becoming empty again while a suggestion is parked.
    @objc private func parkTick() {
        guard let pk = parked else { return }
        if Date().timeIntervalSince(pk.trigger.started) > Self.parkLifetime {
            if case .shown(let p) = state, p.trigger.id == pk.trigger.id { invalidate(p, reason: "parked_expired", toast: nil) }
            clearParked()
            return
        }
        guard case .idle = state, !restoring, !inserting, routeIsCurrent(pk.trigger),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pk.trigger.pid,
              let snap = AX.inputSnapshot(pid: pk.trigger.pid) else {
            inputWasEmpty = false // try again as soon as the chat tool is back with an empty input
            return
        }
        let empty = snap.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty && !inputWasEmpty { Task { await restore(pk) } }
        inputWasEmpty = empty
    }

    /// Shows the parked suggestion again if the input is empty and the header
    /// still shows its chat.
    private func restore(_ pk: Pending) async {
        guard !restoring, !inserting, routeIsCurrent(pk.trigger), case .idle = state else { return }
        restoring = true
        defer { restoring = false }
        guard let snap = AX.inputSnapshot(pid: pk.trigger.pid),
              snap.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              await headerStillMatches(pid: pk.trigger.pid, snap: snap, hash: pk.headerHash, title: pk.chatTitle),
              case .idle = state, routeIsCurrent(pk.trigger), parked?.trigger.id == pk.trigger.id else { return }
        guard let now = AX.inputSnapshot(pid: pk.trigger.pid), now.value == snap.value,
              CFEqual(now.element, snap.element) else { return }
        let p = pk.restored(input: now)
        display(p, report: false)
    }

    // MARK: - Prefetch

    private func noteActivity(type: CGEventType, event: CGEvent) {
        lastActivity = Date()
        if type != .keyDown {
            schedulePrefetch(after: 0.6) // a click may have opened another chat
            return
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        let navigation: Set<Int64> = [36, 76, 123, 124, 125, 126] // Return, Enter, arrows
        if !mods.isEmpty || navigation.contains(code) {
            schedulePrefetch(after: 0.6)
        }
    }

    private func schedulePrefetch(after delay: TimeInterval) {
        prefetchTimer?.invalidate()
        prefetchTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.prefetch() }
            }
        }
    }

    private func prefetchTarget() -> (pid: pid_t, snap: InputSnapshot)? {
        guard !prefetching, !ocrTestMode, case .idle = state,
              let app = NSWorkspace.shared.frontmostApplication,
              let platform = config.platformRegistry.match(bundleID: app.bundleIdentifier),
              platform.id == activePlatform?.id, platform.manifest?.capabilities["composer.read"] == true,
              platform.manifest?.capabilities["composer.apply"] == true,
              let snap = AX.inputSnapshot(pid: app.processIdentifier) else { return nil }
        return (app.processIdentifier, snap)
    }

    /// Captures the header and, when it shows a chat that is not prepared yet
    /// (or was prepared a while ago), has the engine load that chat.
    private func prefetch() async {
        guard let target = prefetchTarget(), let platformID = activePlatform?.id else { return }
        let generation = routeGeneration
        if let pk = parked, target.snap.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await restore(pk)
        }
        guard case .idle = state else { return }
        prefetching = true
        defer { if generation == routeGeneration { prefetching = false } }
        let rect = header.headerRect(input: target.snap.frame, window: target.snap.windowFrame)
        guard let image = try? await header.capture(pid: target.pid, windowFrame: target.snap.windowFrame, rect: rect) else {
            return
        }
        guard generation == routeGeneration, activePlatform?.id == platformID else { return }
        let hash = HeaderReader.fingerprint(image)
        if let p = prepared, p.hash == hash, Date().timeIntervalSince(p.at) < Self.prefetchRefresh { return }
        var payload: [String: Any] = ["op": "prepare", "request_id": UUID().uuidString]
        if let cache = chatCache, cache.hash == hash {
            payload["chat_id"] = cache.chatID
        } else {
            let lines = (try? await Task.detached(priority: .utility, operation: {
                try HeaderReader.recognize(image)
            }).value) ?? []
            guard !lines.isEmpty else { return }
            payload["ocr_lines"] = lines.map { line -> [String: Any] in ["text": line.text, "height": line.height] }
        }
        await sendPrepare(payload, hash: hash, platformID: platformID, generation: generation)
    }

    /// Keeps the prepared chat's messages fresh while the user is active,
    /// without capturing the screen: the chat cannot have changed without a
    /// click or key, which would have scheduled a full prefetch.
    @objc private func refreshTick() {
        guard let p = prepared, prefetchTarget() != nil,
              Date().timeIntervalSince(lastActivity) < Self.activeWindow,
              Date().timeIntervalSince(p.at) >= Self.prefetchRefresh else { return }
        guard let platformID = activePlatform?.id else { return }
        let generation = routeGeneration
        prefetching = true
        Task {
            defer { if generation == routeGeneration { prefetching = false } }
            await sendPrepare(["op": "prepare", "request_id": UUID().uuidString, "chat_id": p.chatID],
                              hash: p.hash, platformID: platformID, generation: generation)
        }
    }

    private func sendPrepare(_ payload: [String: Any], hash: UInt64, platformID: String, generation: Int) async {
        guard generation == routeGeneration, activePlatform?.id == platformID else { return }
        var scoped = payload
        scoped["platform_id"] = platformID
        guard let raw = try? await callEngine(scoped, token: EngineCall()),
              generation == routeGeneration, activePlatform?.id == platformID,
              raw["platform_id"] as? String == platformID else { return }
        let r = EngineResponse(raw)
        guard r.ok, let id = r.chatID else { return }
        chatCache = (hash, id, r.chatTitle ?? id)
        prepared = (hash, id, Date())
    }

    // MARK: - Accept

    /// Recheck the platform, header and exact composer before applying a draft.
    private func accept(_ p: Pending) {
        stopWatch()
        state = .idle
        inserting = true
        Task { await self.finishAccept(p) }
    }

    private func finishAccept(_ p: Pending) async {
        defer { inserting = false }
        let pid = p.trigger.pid
        guard routeIsCurrent(p.trigger), activePlatform?.manifest?.capabilities["composer.apply"] == true,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let before = AX.inputSnapshot(pid: pid), before.value == p.input.value,
              CFEqual(before.element, p.input.element),
              await headerStillMatches(pid: pid, snap: before, hash: p.headerHash, title: p.chatTitle),
              routeIsCurrent(p.trigger), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let now = AX.inputSnapshot(pid: pid), now.value == p.input.value,
              CFEqual(now.element, p.input.element) else {
            overlay.hide()
            feedback(p.trigger.id, "voided", chatID: p.chatID, detail: "input_changed_on_accept")
            return
        }
        let outcome = await Inserter.insert(p.text, into: now.element, pid: pid, method: config.insertMethod)
        try? await Task.sleep(nanoseconds: 30_000_000) // one more frame for the chat tool to draw the text
        if case .shown = state {} else { overlay.hide() } // unless a newer suggestion owns the overlay
        guard routeIsCurrent(p.trigger) else { return }

        switch outcome {
        case .inserted(let attempt):
            if acceptedRequests.insert(p.trigger.id).inserted {
                feedback(p.trigger.id, "accepted", chatID: p.chatID, mode: p.mode, suggestionLen: p.text.count,
                         latency: ms(since: p.shownAt), detail: attempt.rawValue)
            }
            inputWasEmpty = false // a Return from here on sends this text
            startTracking(requestID: p.trigger.id, pid: pid, chatID: p.chatID, text: p.text)
        case .mismatch:
            overlay.showToast(L10n.tr("输入框里的内容和建议不一致，发送前检查一下", "The input differs from the suggestion. Review it before sending"), input: now.frame, duration: 3, kind: .warning)
            feedback(p.trigger.id, "voided", chatID: p.chatID, detail: "insert_mismatch")
            Log.info("写入后输入框内容和建议不一致")
        case .notApplied(let leftOnClipboard):
            overlay.showToast(leftOnClipboard ? L10n.tr("没能写入输入框，建议已放在剪贴板，可以 ⌘V 粘贴", "Could not insert into the input. The suggestion is on the clipboard; press ⌘V to paste") : L10n.tr("没能写入输入框", "Could not insert into the input"),
                              input: now.frame, duration: 3, kind: .warning)
            feedback(p.trigger.id, "voided", chatID: p.chatID, detail: "insert_failed")
            Log.info("写入失败（剪贴板\(leftOnClipboard ? "保留了建议" : "未改动")）")
        }
    }

    // MARK: - After accept: how much did the user change before sending?

    private func startTracking(requestID: String, pid: pid_t, chatID: String, text: String) {
        trackTimer?.invalidate()
        tracking = Tracking(requestID: requestID, pid: pid, chatID: chatID, text: text, last: text, started: Date())
        trackTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(trackTick),
                                          userInfo: nil, repeats: true)
    }

    /// When the input box empties right after Return, the message was sent:
    /// report the edit distance between the suggestion and the last text seen.
    /// Emptied without Return means the user deleted it; the parked
    /// suggestion comes back instead and nothing is reported.
    @objc private func trackTick() {
        guard var tr = tracking else {
            trackTimer?.invalidate()
            trackTimer = nil
            return
        }
        if Date().timeIntervalSince(tr.started) > 180 {
            trackTimer?.invalidate()
            trackTimer = nil
            tracking = nil
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == tr.pid,
              let snap = AX.inputSnapshot(pid: tr.pid) else { return }
        let value = snap.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            if Date().timeIntervalSince(lastSendKeyAt) < 3 {
                schedulePrefetch(after: 1) // the sent message is now part of the history
                let distance = TextUtil.editDistance(tr.text, tr.last)
                feedback(tr.requestID, "sent", chatID: tr.chatID, suggestionLen: tr.text.count, editDistance: distance, detail: "")
            }
            trackTimer?.invalidate()
            trackTimer = nil
            tracking = nil
        } else {
            tr.last = value
            tracking = tr
        }
    }

    // MARK: - Helpers

    private func feedback(_ requestID: String, _ event: String, chatID: String? = nil, mode: String? = nil,
                          suggestionLen: Int? = nil, editDistance: Int? = nil, latency: Int? = nil, detail: String) {
        var payload: [String: Any] = ["op": "feedback", "request_id": requestID, "event": event, "detail": detail]
        guard let platformID = requestPlatforms[requestID] else { return }
        payload["platform_id"] = platformID
        if let v = chatID { payload["chat_id"] = v }
        if let v = mode { payload["mode"] = v }
        if let v = suggestionLen { payload["suggestion_len"] = v }
        if let v = editDistance { payload["edit_distance"] = v }
        if let v = latency { payload["latency_ms"] = v }
        let client = engine
        DispatchQueue.global(qos: .utility).async {
            _ = try? client.callSync(payload, timeout: 2)
        }
    }

    private func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}

private enum PlatformProbeError: LocalizedError {
    case outdated, mismatch, changed

    var canRestart: Bool {
        switch self { case .outdated, .mismatch: return true; case .changed: return false }
    }

    var errorDescription: String? {
        switch self {
        case .outdated:
            return L10n.tr("引擎版本过旧，不支持当前平台适配器。请退出并重新打开 Tact；独立运行的引擎需要更新后手动重启。", "The engine is too old for this platform adapter. Quit and reopen Tact. If the engine runs separately, update and restart it manually.")
        case .mismatch:
            return L10n.tr("引擎中的平台配置尚未生效或检测结果与所选平台不一致，请重启引擎后再试。独立运行的引擎需要手动重启。", "The engine platform settings have not taken effect, or the detected platform does not match the selection. Restart the engine and try again. A separate engine must be restarted manually.")
        case .changed:
            return L10n.tr("平台配置已变化，请重新检测连接", "Platform settings changed. Check the connection again")
        }
    }
}

private struct PlatformProbeCatalog: Decodable {
    let ok: Bool
    let platforms: [Declaration]?

    struct Declaration: Decodable {
        let id: String
        let pluginID: String?
        let version: String?
        let enabled: Bool
        let available: Bool
        let state: String
        let manifest: String?
        let capabilities: [String: Bool]
        let command: [String]?

        enum CodingKeys: String, CodingKey {
            case id, version, enabled, available, state, manifest, capabilities, command
            case pluginID = "plugin_id"
        }
    }
}

private struct PlatformProbeResponse: Decodable {
    let ok: Bool
    let platformID: String?
    let count: Int?
    let error: String?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case ok, count, error
        case platformID = "platform_id"
        case errorCode = "error_code"
    }
}
