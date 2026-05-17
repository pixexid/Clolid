import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

private enum AppConstants {
    static let appName = "Clolid"
    static let bundleIdentifier = "com.pixexid.Clolid"
    static let marketingVersion = "0.1.1"
}

private enum LidState: String {
    case open = "No"
    case closed = "Yes"
    case unknown

    var title: String {
        switch self {
        case .open:
            return "Open"
        case .closed:
            return "Closed"
        case .unknown:
            return "Unknown"
        }
    }
}

private enum StatusMode {
    case idle
    case active
    case clamshell
    case error
}

private enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case outline = "Outline"
    case filled = "Filled"
    case compact = "Compact"

    var id: String {
        rawValue
    }
}

private enum KeeperNotificationTone {
    case ok
    case warn
    case danger
}

private enum ScreenLockPolicy: String, CaseIterable, Identifiable {
    case system = "System"
    case immediate = "Immediate"
    case fiveMinutes = "5 min"
    case oneHour = "1 hour"
    case fourHours = "4 hours"
    case eightHours = "8 hours"
    case noLock = "No lock"

    var id: String {
        rawValue
    }

    var sysadminValue: String? {
        switch self {
        case .system:
            return nil
        case .immediate:
            return "immediate"
        case .fiveMinutes:
            return "300"
        case .oneHour:
            return "3600"
        case .fourHours:
            return "14400"
        case .eightHours:
            return "28800"
        case .noLock:
            return "off"
        }
    }

    static func normalized(rawValue: String) -> ScreenLockPolicy {
        switch rawValue {
        case "12 hours", "16 hours", "24 hours":
            return .noLock
        default:
            return ScreenLockPolicy(rawValue: rawValue) ?? .system
        }
    }
}

private struct CommandResult {
    let status: Int32
    let output: String
}

private struct ScreenLockSnapshot: Codable {
    let status: String
}

private enum CommandError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message.isEmpty ? "Command failed." : message
        }
    }
}

private final class Shell {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: output)
    }

    func runSuccessful(_ executable: String, _ arguments: [String]) -> Bool {
        do {
            return try run(executable, arguments).status == 0
        } catch {
            return false
        }
    }
}

private final class KeeperModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lidState = LidState.unknown
    @Published private(set) var sleepDisabled = false
    @Published private(set) var externalDisplayName: String?
    @Published private(set) var isOnACPower = false
    @Published private(set) var screenLockStatus = "Unknown"
    @Published private(set) var isApplyingScreenLock = false
    @Published var lastDisplaySleepAt: Date?
    @Published var lastError: String?
    @Published var startAtLogin = false
    @AppStorage("StartSessionOnLaunch") var startSessionOnLaunch = false
    @AppStorage("DidCompleteWelcome") var didCompleteWelcome = false
    @AppStorage("DidShowAuthorizationPreflight") var didShowAuthorizationPreflight = false
    @AppStorage("SleepDisplayOnLidClose") var sleepDisplayOnLidClose = true
    @AppStorage("NotifyOnLidClose") var notifyOnLidClose = true
    @AppStorage("NotifyOnSessionStart") var notifyOnSessionStart = true
    @AppStorage("RequireExternalPower") var requireExternalPower = false
    @AppStorage("ShowElapsedInMenuBar") var showElapsedInMenuBar = false
    @AppStorage("PollIntervalSeconds") var pollIntervalSeconds = 1.0
    @AppStorage("MenuBarIconStyle") var menuBarIconStyleRaw = MenuBarIconStyle.filled.rawValue
    @AppStorage("ScreenLockPolicy") var screenLockPolicyRaw = ScreenLockPolicy.system.rawValue

    private let shell = Shell()
    private let loginItemManager = LoginItemManager()
    private let notificationManager = NotificationManager()
    private let screenLockManager = ScreenLockManager()
    private var isRefreshingScreenLockStatus = false
    private var lastScreenLockRefreshAt: Date?
    private var caffeinateProcess: Process?
    private var pollTimer: Timer?
    private var startedAt: Date?
    private var lastObservedLidState = LidState.unknown
    private var lastNoExternalDisplayNotificationAt: Date?
    private var lastDisplayRefreshAt: Date?
    private var isRefreshingDisplays = false
    private var caffeinatePIDURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Clolid/caffeinate.pid")
    }

    var elapsed: String {
        guard let startedAt else {
            return "00:00:00"
        }

        let interval = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%02d:%02d:%02d", interval / 3600, interval / 60 % 60, interval % 60)
    }

    var mode: StatusMode {
        if lastError != nil {
            return .error
        }
        if isRunning && lidState == .closed {
            return .clamshell
        }
        if isRunning {
            return .active
        }
        return .idle
    }

    var menuBarIconStyle: MenuBarIconStyle {
        get {
            MenuBarIconStyle(rawValue: menuBarIconStyleRaw) ?? .filled
        }
        set {
            menuBarIconStyleRaw = newValue.rawValue
        }
    }

    var screenLockPolicy: ScreenLockPolicy {
        get {
            ScreenLockPolicy.normalized(rawValue: screenLockPolicyRaw)
        }
        set {
            updateScreenLockPolicy(newValue)
        }
    }

    init() {
        if let legacy = UserDefaults.standard.string(forKey: "ScreenLockDelay") {
            let normalized = ScreenLockPolicy.normalized(rawValue: legacy)
            screenLockPolicyRaw = normalized.rawValue
            UserDefaults.standard.removeObject(forKey: "ScreenLockDelay")
        } else {
            let normalized = ScreenLockPolicy.normalized(rawValue: screenLockPolicyRaw)
            if normalized.rawValue != screenLockPolicyRaw {
                screenLockPolicyRaw = normalized.rawValue
            }
        }
    }

    func refresh() {
        lidState = readLidState()
        sleepDisabled = readSleepDisabled()
        isOnACPower = readIsOnACPower()
        startAtLogin = loginItemManager.isEnabled
        refreshScreenLockStatusIfNeeded()
    }

    func refreshScreenLockStatusIfNeeded(force: Bool = false) {
        guard force || !isRefreshingScreenLockStatus else {
            return
        }
        if !force, let lastScreenLockRefreshAt, Date().timeIntervalSince(lastScreenLockRefreshAt) < 10 {
            return
        }

        isRefreshingScreenLockStatus = true
        lastScreenLockRefreshAt = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }
            let current = self.screenLockManager.currentStatus()
            DispatchQueue.main.async {
                self.screenLockStatus = current.label
                self.isRefreshingScreenLockStatus = false
            }
        }
    }

    func refreshExternalDisplayIfNeeded(force: Bool = false) {
        guard force || lastDisplayRefreshAt.map({ Date().timeIntervalSince($0) > 15 }) ?? true else {
            return
        }
        guard !isRefreshingDisplays else {
            return
        }

        isRefreshingDisplays = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }
            let displayName = self.readExternalDisplayName()
            DispatchQueue.main.async {
                self.externalDisplayName = displayName
                self.lastDisplayRefreshAt = Date()
                self.isRefreshingDisplays = false
            }
        }
    }

    func start() {
        guard !isRunning else {
            return
        }

        if screenLockPolicy != .system {
            let policy = screenLockPolicy
            isApplyingScreenLock = true
            lastError = nil
            PasswordPromptWindowController.shared.requestPassword(
                title: "Start Session",
                message: "Enter your Mac password to set Screen Lock before starting.",
                actionTitle: "Start",
                operation: { [weak self] password in
                    guard let self else {
                        return .failure(CommandError.failed("Clolid is not available."))
                    }
                    do {
                        try self.screenLockManager.apply(policy, password: password)
                        return .success("Screen Lock ready")
                    } catch {
                        return .failure(error)
                    }
                },
                completion: { [weak self] success in
                    guard let self else {
                        return
                    }
                    guard success else {
                        self.isApplyingScreenLock = false
                        self.lastError = nil
                        self.refresh()
                        return
                    }
                    self.start(password: nil)
                }
            )
            return
        }

        start(password: nil)
    }

    private func start(password: String?) {
        do {
            cleanupStaleCaffeinate()
            refresh()
            if requireExternalPower && !isOnACPower {
                throw CommandError.failed("External power is required by your settings.")
            }
            try setClamshellSleepDisabled(true)
            try screenLockManager.apply(screenLockPolicy, password: password)
            try startCaffeinate()
            startedAt = Date()
            lastObservedLidState = readLidState()
            isRunning = true
            isApplyingScreenLock = false
            lastError = nil
            startPolling()
            refresh()
            refreshExternalDisplayIfNeeded(force: true)
            if notifyOnSessionStart {
                notificationManager.post(
                    title: "Session started",
                    body: "Awake mode is on.",
                    tone: .ok
                )
            }
        } catch {
            stop()
            lastError = error.localizedDescription
            notificationManager.post(
                title: "Power change failed",
                body: error.localizedDescription,
                tone: .danger
            )
            refresh()
            isApplyingScreenLock = false
        }
    }

    func stop() {
        stopPolling()
        stopCaffeinate()

        do {
            try screenLockManager.restoreIfNeeded()
            try setClamshellSleepDisabled(false)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        isRunning = false
        startedAt = nil
        refresh()
    }

    func displaySleepNow() {
        if shell.runSuccessful("/usr/bin/pmset", ["displaysleepnow"]) {
            lastDisplaySleepAt = Date()
        }
    }

    func restoreNormalSleep() {
        do {
            stopPolling()
            stopCaffeinate()
            try screenLockManager.restoreIfNeeded()
            try setClamshellSleepDisabled(false)
            isRunning = false
            startedAt = nil
            lastError = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setStartAtLogin(_ enabled: Bool) {
        startAtLogin = enabled
        do {
            try loginItemManager.setEnabled(enabled)
            lastError = nil
            startAtLogin = loginItemManager.isEnabled
        } catch {
            lastError = error.localizedDescription
            startAtLogin = loginItemManager.isEnabled
        }
    }

    func requestNotificationsIfNeeded() {
        notificationManager.requestAuthorization()
    }

    func updatePollInterval(_ interval: Double) {
        pollIntervalSeconds = interval
        if isRunning {
            startPolling()
        }
    }

    func updateScreenLockPolicy(_ policy: ScreenLockPolicy) {
        guard isRunning else {
            screenLockPolicyRaw = policy.rawValue
            refresh()
            return
        }

        isApplyingScreenLock = true
        lastError = nil

        if policy == .system {
            applyScreenLockPolicy(policy, password: nil)
            return
        }

        PasswordPromptWindowController.shared.requestPassword(
            title: "Set Screen Lock",
            message: "Enter your Mac password to set \(policy.rawValue).",
            actionTitle: "Set",
            operation: { [weak self] password in
                guard let self else {
                    return .failure(CommandError.failed("Clolid is not available."))
                }
                do {
                    try self.screenLockManager.apply(policy, password: password)
                    return .success("Set to \(self.screenLockManager.statusLabel())")
                } catch {
                    return .failure(error)
                }
            },
            completion: { [weak self] success in
                guard let self else {
                    return
                }
                if success {
                    self.screenLockPolicyRaw = policy.rawValue
                    self.lastError = nil
                }
                self.isApplyingScreenLock = false
                self.refresh()
            }
        )
    }

    private func applyScreenLockPolicy(_ policy: ScreenLockPolicy, password: String?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            let result: Result<Void, Error>
            do {
                try self.screenLockManager.apply(policy, password: password)
                result = .success(())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.screenLockPolicyRaw = policy.rawValue
                    self.lastError = nil
                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
                self.isApplyingScreenLock = false
                self.refresh()
            }
        }
    }

    private func startCaffeinate() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-s", "-u"]
        try process.run()
        caffeinateProcess = process
        try FileManager.default.createDirectory(
            at: caffeinatePIDURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "\(process.processIdentifier)".write(to: caffeinatePIDURL, atomically: true, encoding: .utf8)
    }

    private func stopCaffeinate() {
        caffeinateProcess?.terminate()
        caffeinateProcess = nil
        cleanupStaleCaffeinate()
        try? FileManager.default.removeItem(at: caffeinatePIDURL)
    }

    private func cleanupStaleCaffeinate() {
        guard let rawPID = try? String(contentsOf: caffeinatePIDURL, encoding: .utf8),
              let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return
        }

        if pid > 0 {
            kill(pid, SIGTERM)
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollIntervalSeconds, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        lastObservedLidState = .unknown
    }

    private func poll() {
        let currentLidState = readLidState()
        let lidJustClosed = currentLidState == .closed && lastObservedLidState != .closed

        if isRunning && lidJustClosed {
            if sleepDisplayOnLidClose {
                displaySleepNow()
            }
            if notifyOnLidClose {
                notificationManager.post(
                    title: "Display asleep",
                    body: "Lid closed. Mac stays awake.",
                    tone: .warn
                )
            }
        }

        if isRunning && requireExternalPower && !readIsOnACPower() {
            lastError = "External power disconnected while session was running."
            notificationManager.post(
                title: "Power unplugged",
                body: "Session stopped.",
                tone: .warn
            )
            stop()
            return
        }

        if isRunning && currentLidState == .closed && externalDisplayName == nil {
            let shouldNotify = lastNoExternalDisplayNotificationAt.map { Date().timeIntervalSince($0) > 600 } ?? true
            if shouldNotify {
                lastNoExternalDisplayNotificationAt = Date()
                notificationManager.post(
                    title: "No external display detected",
                    body: "Lid closed without external display.",
                    tone: .warn
                )
            }
        }

        lastObservedLidState = currentLidState
        refresh()
        refreshExternalDisplayIfNeeded()
    }

    private func readLidState() -> LidState {
        let result = try? shell.run("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "1"])
        guard let output = result?.output else {
            return .unknown
        }

        for line in output.split(separator: "\n") where line.contains("AppleClamshellState") {
            if line.contains("Yes") {
                return .closed
            }
            if line.contains("No") {
                return .open
            }
        }

        return .unknown
    }

    private func readSleepDisabled() -> Bool {
        let result = try? shell.run("/usr/bin/pmset", ["-g"])
        return result?.output.contains("SleepDisabled\t\t1") == true
    }

    private func readExternalDisplayName() -> String? {
        let result = try? shell.run("/usr/sbin/system_profiler", ["SPDisplaysDataType"])
        guard let output = result?.output else {
            return nil
        }

        var insideDisplays = false
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "Displays:" {
                insideDisplays = true
                continue
            }
            guard insideDisplays, line.hasSuffix(":") else {
                continue
            }

            let name = String(line.dropLast())
            if name != "Color LCD" && !name.isEmpty {
                return name
            }
        }

        return nil
    }

    private func readIsOnACPower() -> Bool {
        let result = try? shell.run("/usr/bin/pmset", ["-g", "ps"])
        return result?.output.contains("AC Power") == true
    }

    private func setClamshellSleepDisabled(_ disabled: Bool) throws {
        let value = disabled ? "1" : "0"

        if shell.runSuccessful("/usr/bin/sudo", ["/usr/bin/pmset", "-a", "disablesleep", value]) {
            return
        }

        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
        let result = try shell.run("/usr/bin/osascript", ["-e", script])
        if result.status != 0 {
            throw CommandError.failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private final class ScreenLockManager {
    private let shell = Shell()
    private var sessionPassword: String?

    private var snapshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Clolid/screen-lock-snapshot.json")
    }

    func apply(_ policy: ScreenLockPolicy, password: String?) throws {
        guard let value = policy.sysadminValue else {
            try restoreIfNeeded()
            return
        }

        if !FileManager.default.fileExists(atPath: snapshotURL.path) {
            try saveSnapshot()
        }

        try runScreenLock(value, password: password)
    }

    func restoreIfNeeded() throws {
        guard let snapshot = savedSnapshot() else {
            return
        }

        if let value = sysadminValue(from: snapshot.status) {
            try runScreenLock(value, password: nil)
        }
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    func statusLabel() -> String {
        currentStatus().label
    }

    func currentStatus() -> (label: String, policy: ScreenLockPolicy?) {
        let status = screenLockStatus()
        if status.contains("off") {
            return ("Off", .noLock)
        }
        if status.contains("immediate") {
            return ("Immediate", .immediate)
        }
        if let seconds = status.split(separator: " ").compactMap({ Int($0) }).first {
            if seconds >= 3_600, seconds % 3_600 == 0 {
                let label = "\(seconds / 3_600)h"
                return (label, policy(for: seconds))
            }
            if seconds >= 60, seconds % 60 == 0 {
                let label = "\(seconds / 60)m"
                return (label, policy(for: seconds))
            }
            return ("\(seconds)s", policy(for: seconds))
        }
        return ("Unknown", nil)
    }

    private func policy(for seconds: Int) -> ScreenLockPolicy? {
        switch seconds {
        case 300:
            return .fiveMinutes
        case 3_600:
            return .oneHour
        case 14_400:
            return .fourHours
        case 28_800:
            return .eightHours
        default:
            return nil
        }
    }

    private func saveSnapshot() throws {
        let snapshot = ScreenLockSnapshot(status: screenLockStatus())
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    private func savedSnapshot() -> ScreenLockSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ScreenLockSnapshot.self, from: data)
    }

    private func screenLockStatus() -> String {
        let result = try? shell.run("/usr/sbin/sysadminctl", ["-screenLock", "status"])
        return result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func sysadminValue(from status: String) -> String? {
        if status.contains("off") {
            return "off"
        }
        if status.contains("immediate") {
            return "immediate"
        }
        if let seconds = status.split(separator: " ").compactMap({ Int($0) }).first {
            return "\(seconds)"
        }
        return nil
    }

    private func runScreenLock(_ value: String, password newPassword: String?) throws {
        guard let password = newPassword ?? sessionPassword else {
            throw CommandError.failed("Mac login password is required to change Screen Lock.")
        }
        sessionPassword = password

        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysadminctl")
        process.arguments = ["-screenLock", value, "-password", "-"]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe

        try process.run()
        inputPipe.fileHandleForWriting.write(Data((password + "\n").utf8))
        try? inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 || output.localizedCaseInsensitiveContains("error") {
            sessionPassword = nil
            throw CommandError.failed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

}

private final class LoginItemManager {
    private let shell = Shell()
    private let label = "com.pixexid.Clolid.login"

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            disable()
        }
    }

    private func enable() throws {
        let bundlePath = Bundle.main.bundlePath
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/usr/bin/open</string>
            <string>\(bundlePath)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
        </dict>
        </plist>
        """

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        _ = shell.runSuccessful("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
        _ = shell.runSuccessful("/bin/launchctl", ["enable", "gui/\(getuid())/\(label)"])
    }

    private func disable() {
        _ = shell.runSuccessful("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }
}

private enum PasswordPromptPhase {
    case entry
    case applying
    case success(String)
    case failure(String)
}

private final class PasswordPromptState: ObservableObject {
    let title: String
    let message: String
    let actionTitle: String
    @Published var password = ""
    @Published var phase = PasswordPromptPhase.entry

    init(title: String, message: String, actionTitle: String) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
    }

    var isApplying: Bool {
        if case .applying = phase {
            return true
        }
        return false
    }

    var canSubmit: Bool {
        !password.isEmpty && !isApplying
    }
}

private final class PasswordPromptWindowController: NSObject {
    static let shared = PasswordPromptWindowController()
    private var window: NSWindow?
    private var state: PasswordPromptState?
    private var operation: ((String) -> Result<String, Error>)?
    private var completion: ((Bool) -> Void)?

    func requestPassword(
        title: String,
        message: String,
        actionTitle: String,
        operation: @escaping (String) -> Result<String, Error>,
        completion: @escaping (Bool) -> Void
    ) {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        show(
            title: title,
            message: message,
            actionTitle: actionTitle,
            operation: operation,
            completion: completion
        )
    }

    private func show(
        title: String,
        message: String,
        actionTitle: String,
        operation: @escaping (String) -> Result<String, Error>,
        completion: @escaping (Bool) -> Void
    ) {
        let state = PasswordPromptState(title: title, message: message, actionTitle: actionTitle)
        self.state = state
        self.operation = operation
        self.completion = completion
        let controller = NSHostingController(rootView: ScreenLockPasswordView(
            state: state,
            submit: { [weak self] password in
                self?.submit(password)
            },
            cancel: { [weak self] in
                self?.finish(success: false)
            }
        ))
        let window = NSPanel(contentViewController: controller)
        window.title = "Screen Lock"
        window.setContentSize(NSSize(width: 440, height: 312))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .modalPanel
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.delegate = self
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func submit(_ password: String) {
        guard let state, let operation, state.canSubmit else {
            return
        }

        state.phase = .applying
        DispatchQueue.global(qos: .userInitiated).async {
            let result = operation(password)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state === state else {
                    return
                }
                switch result {
                case .success(let message):
                    state.password = ""
                    state.phase = .success(message)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in
                        guard self?.state === state else {
                            return
                        }
                        self?.finish(success: true)
                    }
                case .failure(let error):
                    state.phase = .failure(error.localizedDescription)
                }
            }
        }
    }
}

extension PasswordPromptWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        finish(success: false)
    }

    private func finish(success: Bool) {
        let completion = completion
        self.completion = nil
        operation = nil
        state = nil
        window?.delegate = nil
        window?.close()
        window = nil
        completion?(success)
    }
}

private struct ScreenLockPasswordView: View {
    @ObservedObject var state: PasswordPromptState
    @FocusState private var isPasswordFocused: Bool
    let submit: (String) -> Void
    let cancel: () -> Void

    private let accent = Color(red: 0.24, green: 0.62, blue: 0.36)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                phaseBadge
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(.system(size: 16, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Mac login password")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                passwordField
                feedbackLine
            }

            Spacer()

            HStack {
                Button("Cancel") {
                    cancel()
                }
                .disabled(state.isApplying)
                Spacer()
                Button(actionTitle) {
                    submit(state.password)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!state.canSubmit)
            }
        }
        .padding(24)
        .frame(width: 440, height: 312)
        .animation(.easeOut(duration: 0.18), value: state.password.isEmpty)
        .onAppear {
            DispatchQueue.main.async {
                isPasswordFocused = true
            }
        }
        .onChange(of: state.password) { _ in
            if case .failure = state.phase {
                state.phase = .entry
            }
        }
    }

    private var phaseBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(badgeColor.opacity(0.14))
            phaseIcon
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(badgeColor)
        }
        .frame(width: 48, height: 48)
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch state.phase {
        case .entry:
            Image(systemName: "lock.shield")
        case .applying:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var badgeColor: Color {
        switch state.phase {
        case .entry, .applying:
            return accent
        case .success:
            return accent
        case .failure:
            return Color(red: 0.86, green: 0.18, blue: 0.14)
        }
    }

    private var subtitle: String {
        switch state.phase {
        case .entry:
            return state.message
        case .applying:
            return "Applying with macOS..."
        case .success:
            return "Done."
        case .failure:
            return "Check the password and try again."
        }
    }

    private var passwordField: some View {
        SecureField("Required", text: $state.password)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(fieldBorderColor, lineWidth: isPasswordFocused ? 1.6 : 1)
            )
            .shadow(color: isPasswordFocused ? accent.opacity(0.22) : .clear, radius: 8, y: 2)
            .focused($isPasswordFocused)
            .disabled(state.isApplying)
            .onSubmit {
                submit(state.password)
            }
            .animation(.easeOut(duration: 0.16), value: isPasswordFocused)
    }

    private var fieldBorderColor: Color {
        if case .failure = state.phase {
            return Color(red: 0.86, green: 0.18, blue: 0.14)
        }
        return isPasswordFocused ? accent : Color.secondary.opacity(0.26)
    }

    @ViewBuilder
    private var feedbackLine: some View {
        switch state.phase {
        case .entry:
            HStack(spacing: 6) {
                Image(systemName: state.password.isEmpty ? "arrow.up.left.and.arrow.down.right" : "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text(state.password.isEmpty ? "Type your Mac password to continue." : "Ready to apply.")
            }
            .font(.system(size: 12))
            .foregroundStyle(state.password.isEmpty ? Color.secondary : accent)
        case .applying:
            Text("Keeping this open while macOS applies the change.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .success(let message):
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text(message)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(accent)
        case .failure(let message):
            Text(message.isEmpty ? "Password was not accepted." : message)
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.86, green: 0.18, blue: 0.14))
                .lineLimit(2)
        }
    }

    private var actionTitle: String {
        switch state.phase {
        case .entry, .failure:
            return state.actionTitle
        case .applying:
            return "Applying"
        case .success:
            return "Done"
        }
    }
}

private final class NotificationManager {
    private let center = UNUserNotificationCenter.current()
    private var lastNotificationByTitle: [String: Date] = [:]

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, tone: KeeperNotificationTone) {
        let now = Date()
        if let last = lastNotificationByTitle[title], now.timeIntervalSince(last) < 30 {
            return
        }
        lastNotificationByTitle[title] = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = tone == .danger ? .default : nil
        content.categoryIdentifier = "Clolid"

        let request = UNNotificationRequest(
            identifier: "\(AppConstants.bundleIdentifier).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}

private final class StartCoordinator {
    static let shared = StartCoordinator()

    func start(model: KeeperModel) {
        if model.didShowAuthorizationPreflight {
            model.start()
        } else {
            AuthorizationWindowController.shared.show(model: model)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = KeeperModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: 36)
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var keyboardMonitor: Any?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configurePopover()
        configureStatusItem()
        model.refresh()
        model.refreshScreenLockStatusIfNeeded(force: true)

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusIcon()
            }
            .store(in: &cancellables)

        model.$startAtLogin
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusIcon()
            }
            .store(in: &cancellables)

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.model.refresh()
            self?.refreshStatusIcon()
        }
        Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.model.refreshExternalDisplayIfNeeded()
        }
        configureKeyboardShortcuts()

        if model.startSessionOnLaunch {
            StartCoordinator.shared.start(model: model)
        } else if !model.didCompleteWelcome {
            WelcomeWindowController.shared.show(model: model)
        }

        refreshStatusIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopOutsideClickMonitor()
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
        if model.isRunning {
            model.stop()
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 320, height: 520)
        popover.contentViewController = NSHostingController(rootView: KeeperPanelView(
            model: model,
            closePopover: { [weak self] in
                self?.closePopover()
            },
            closePopoverThen: { [weak self] action in
                self?.closePopover()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: action)
            }
        ))
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.imagePosition = .imageOnly
        button.title = ""
        button.target = self
        button.action = #selector(togglePopover)
        button.toolTip = AppConstants.appName
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func refreshStatusIcon() {
        statusItem.length = model.showElapsedInMenuBar && model.isRunning ? NSStatusItem.variableLength : statusItemWidth
        statusItem.button?.image = StatusIconFactory.image(for: model.mode, style: model.menuBarIconStyle)
        statusItem.button?.image?.isTemplate = false
        statusItem.button?.title = model.showElapsedInMenuBar && model.isRunning ? " \(model.elapsed)" : ""
        statusItem.button?.setAccessibilityLabel("\(AppConstants.appName): \(accessibilityState)")
    }

    private var accessibilityState: String {
        switch model.mode {
        case .idle:
            return "idle"
        case .active:
            return "session active"
        case .clamshell:
            return "clamshell engaged"
        case .error:
            return "attention needed"
        }
    }

    private var statusItemWidth: CGFloat {
        model.menuBarIconStyle == .compact ? 28 : 36
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            model.refresh()
            model.refreshScreenLockStatusIfNeeded(force: true)
            model.refreshExternalDisplayIfNeeded()
            refreshStatusIcon()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startOutsideClickMonitor()
        }
    }

    private func closePopover() {
        stopOutsideClickMonitor()
        popover.performClose(nil)
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            DispatchQueue.main.async {
                self?.closePopoverIfClickIsOutside(event)
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func closePopoverIfClickIsOutside(_ event: NSEvent) {
        guard popover.isShown else {
            stopOutsideClickMonitor()
            return
        }
        guard let window = popover.contentViewController?.view.window else {
            closePopover()
            return
        }

        let clickPoint = event.locationInWindow
        let popoverFrame = window.frame
        let statusFrame = statusItemButtonScreenFrame()
        if !popoverFrame.contains(clickPoint) && !statusFrame.contains(clickPoint) {
            closePopover()
        }
    }

    private func statusItemButtonScreenFrame() -> NSRect {
        guard let button = statusItem.button,
              let window = button.window
        else {
            return .zero
        }

        let buttonFrame = button.convert(button.bounds, to: nil)
        return window.convertToScreen(buttonFrame)
    }

    private func configureKeyboardShortcuts() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let commandOnly = modifiers == .command
            let commandShift = modifiers == [.command, .shift]
            let key = event.charactersIgnoringModifiers?.lowercased()

            if commandOnly && key == "s" {
                self.model.isRunning ? self.model.stop() : StartCoordinator.shared.start(model: self.model)
                return nil
            }

            if commandShift && key == "l" {
                self.model.displaySleepNow()
                return nil
            }

            if commandOnly && key == "," {
                self.closePopover()
                SettingsWindowController.shared.show(model: self.model)
                return nil
            }

            if commandOnly && key == "q" {
                NSApp.terminate(nil)
                return nil
            }

            return event
        }
    }
}

private enum StatusIconFactory {
    static func image(for mode: StatusMode, style: MenuBarIconStyle) -> NSImage {
        let size = style == .compact ? NSSize(width: 22, height: 22) : NSSize(width: 32, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        NSColor.clear.setFill()
        rect.fill()

        let glyphColor: NSColor = mode == .idle ? .secondaryLabelColor : .labelColor
        let resourceName = mode == .idle ? "clolid-idle" : "clolid-active"
        let iconRect = style == .compact ? NSRect(x: 3, y: 6, width: 16, height: 9) : NSRect(x: 2, y: 5, width: 28, height: 12.5)
        drawResourceIcon(named: resourceName, in: iconRect, color: glyphColor)

        if let badgeColor = badgeColor(for: mode) {
            let badgeRect = style == .compact ? NSRect(x: 15.5, y: 14.5, width: 6, height: 6) : NSRect(x: 25, y: 14.5, width: 6, height: 6)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            badgeColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func drawResourceIcon(named resourceName: String, in rect: NSRect, color: NSColor) {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "svg"),
              let sourceImage = NSImage(contentsOf: url)
        else {
            drawFallbackLid(in: rect, color: color)
            return
        }

        sourceImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceIn)
    }

    private static func badgeColor(for mode: StatusMode) -> NSColor? {
        switch mode {
        case .idle:
            return nil
        case .active:
            return NSColor(red: 0.24, green: 0.62, blue: 0.36, alpha: 1)
        case .clamshell:
            return NSColor(red: 0.92, green: 0.58, blue: 0.18, alpha: 1)
        case .error:
            return NSColor(red: 0.86, green: 0.18, blue: 0.14, alpha: 1)
        }
    }

    private static func drawFallbackLid(in rect: NSRect, color: NSColor) {
        color.setStroke()
        color.setFill()

        let lid = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        lid.lineWidth = 1.6
        lid.stroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: rect.minX + 1, y: rect.minY - 2))
        base.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY - 2))
        base.lineWidth = 2
        base.stroke()
    }
}

private struct KeeperPanelView: View {
    @ObservedObject var model: KeeperModel
    let closePopover: () -> Void
    let closePopoverThen: (@escaping () -> Void) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var active: Bool {
        model.isRunning
    }

    private var lidClosed: Bool {
        model.lidState == .closed
    }

    private var colors: PanelColors {
        PanelColors(scheme: colorScheme)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                header
                actionButton
                sectionLabel("Status")
                statusRow(icon: "power", label: "Session", value: active ? "Running" : "Stopped", tint: active ? colors.accent : colors.text)
                statusRow(icon: "laptopcomputer", label: "Lid", value: model.lidState.title, tint: lidClosed ? colors.warn : colors.text)
                statusRow(icon: "moon", label: "Lid awake", value: model.sleepDisabled ? "On" : "Off", tint: model.sleepDisabled ? colors.accent : colors.dim)
                statusRow(icon: "display", label: "Display", value: model.externalDisplayName ?? "-", tint: colors.dim)
                statusRow(icon: "bolt.fill", label: "Power", value: model.isOnACPower ? "AC Power" : "Battery", tint: model.requireExternalPower && !model.isOnACPower ? colors.warn : colors.dim)
                statusRow(icon: "lock", label: "Screen lock", value: model.screenLockStatus, tint: model.screenLockPolicy == .system ? colors.dim : colors.accent)
                if let lastDisplaySleepAt = model.lastDisplaySleepAt {
                    statusRow(icon: "clock", label: "Last display sleep", value: relativeTime(lastDisplaySleepAt), tint: colors.dim)
                }
                if let lastError = model.lastError {
                    noticeRow(text: lastError)
                }
                divider
                menuButton(icon: "moon.zzz", label: "Sleep display now", shortcut: "⌘⇧L") {
                    model.displaySleepNow()
                }
                divider
                sectionLabel("Preferences")
                toggleRow(label: "Start at login", isOn: Binding(
                    get: { model.startAtLogin },
                    set: { model.setStartAtLogin($0) }
                ))
                toggleRow(label: "Auto-start session", isOn: $model.startSessionOnLaunch)
                pickerRow(label: "Screen lock", selection: Binding(
                    get: { model.screenLockPolicy },
                    set: { policy in
                        if model.isRunning, policy != .system {
                            closePopoverThen {
                                model.updateScreenLockPolicy(policy)
                            }
                        } else {
                            model.updateScreenLockPolicy(policy)
                        }
                    }
                ))
                divider
                menuButton(icon: "gearshape", label: "Settings...", shortcut: "⌘,") {
                    closePopover()
                    SettingsWindowController.shared.show(model: model)
                }
                menuButton(icon: "info.circle", label: "About") {
                    closePopover()
                    AboutWindowController.shared.show()
                }
                menuButton(icon: "rectangle.portrait.and.arrow.right", label: "Quit", shortcut: "⌘Q", danger: true) {
                    NSApp.terminate(nil)
                }
            }
            .padding(.bottom, 6)
            .frame(width: 320)
        }
        .frame(width: 320)
        .frame(maxHeight: 520)
        .background(colors.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PulseDot(active: active, color: stateColor)
                Text(stateLabel)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(stateColor)
                Spacer()
                if active {
                    Text(model.elapsed)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(colors.dim)
                }
            }

            Text(titleText)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(colors.text)

            Text(subtitleText)
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundStyle(colors.dim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(headerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }

    private var actionButton: some View {
        Button {
            active ? model.stop() : StartCoordinator.shared.start(model: model)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: active ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(active ? "Stop session" : "Start session")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                key("⌘", inverted: !active)
                key("S", inverted: !active)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .foregroundStyle(active ? colors.text : colors.surface)
            .background(active ? Color.clear : colors.text)
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(colors.border, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func statusRow(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(colors.dim)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(colors.dim)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .fontDesign(.monospaced)
                .lineLimit(1)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
    }

    private func noticeRow(text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(colors.danger)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(colors.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 5)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        if seconds < 3_600 {
            return "\(seconds / 60)m ago"
        }
        return "\(seconds / 3_600)h ago"
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(colors.faint)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private func menuButton(icon: String, label: String, shortcut: String? = nil, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(danger ? colors.danger : colors.dim)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                Spacer()
                if let shortcut {
                    shortcutKeys(shortcut)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 29)
            .foregroundStyle(danger ? colors.danger : colors.text)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    private func toggleRow(label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(colors.text)
            Spacer()
            KeeperSwitch(isOn: isOn)
                .accessibilityLabel(label)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
    }

    private func pickerRow(label: String, selection: Binding<ScreenLockPolicy>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(colors.text)
            Spacer()
            if model.isApplyingScreenLock {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 112, alignment: .trailing)
            } else {
                Picker("", selection: selection) {
                    ForEach(ScreenLockPolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .labelsHidden()
                .frame(width: 112)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
    }

    private var divider: some View {
        Rectangle()
            .fill(colors.divider)
            .frame(height: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    private func key(_ value: String, inverted: Bool = false) -> some View {
        Text(value)
            .font(.system(size: value.count == 1 ? 12 : 11, weight: .semibold, design: .rounded))
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 4)
            .foregroundStyle(inverted ? Color.white.opacity(0.85) : colors.dim)
            .background(inverted ? Color.white.opacity(0.18) : colors.keyBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func shortcutKeys(_ shortcut: String) -> some View {
        HStack(spacing: 3) {
            ForEach(shortcutTokens(shortcut), id: \.self) { token in
                key(token)
            }
        }
    }

    private func shortcutTokens(_ shortcut: String) -> [String] {
        shortcut.map(String.init)
    }

    private var stateLabel: String {
        if lidClosed && active {
            return "Lid closed"
        }
        if active {
            return "Active"
        }
        return "Idle"
    }

    private var titleText: String {
        if lidClosed && active {
            return "Display asleep. Mac awake."
        }
        if active {
            return "Ready for closed-lid use."
        }
        return "Closed-lid mode is off."
    }

    private var subtitleText: String {
        if lidClosed && active {
            return model.externalDisplayName.map { "Using \($0)." } ?? "No external display found."
        }
        if active {
            return "Close the lid; display sleeps."
        }
        return "Press Start to keep awake."
    }

    private var stateColor: Color {
        if model.lastError != nil {
            return colors.danger
        }
        if lidClosed && active {
            return colors.warn
        }
        if active {
            return colors.accent
        }
        return colors.faint
    }

    private var headerBackground: Color {
        if lidClosed && active {
            return colors.warnBackground
        }
        if active {
            return colors.accentBackground
        }
        return colors.surfaceAlt
    }

}

private struct PanelColors {
    let surface: Color
    let surfaceAlt: Color
    let border: Color
    let divider: Color
    let text: Color
    let dim: Color
    let faint: Color
    let keyBackground: Color
    let accent = Color(red: 0.24, green: 0.62, blue: 0.36)
    let accentBackground = Color(red: 0.24, green: 0.62, blue: 0.36).opacity(0.14)
    let warn = Color(red: 0.92, green: 0.58, blue: 0.18)
    let warnBackground = Color(red: 0.92, green: 0.58, blue: 0.18).opacity(0.16)
    let danger = Color(red: 0.86, green: 0.18, blue: 0.14)

    init(scheme: ColorScheme) {
        if scheme == .dark {
            surface = Color(red: 0.18, green: 0.18, blue: 0.20)
            surfaceAlt = Color(red: 0.22, green: 0.22, blue: 0.24)
            border = Color.white.opacity(0.12)
            divider = Color.white.opacity(0.10)
            text = Color.white.opacity(0.96)
            dim = Color.white.opacity(0.70)
            faint = Color.white.opacity(0.50)
            keyBackground = Color.white.opacity(0.08)
        } else {
            surface = Color(red: 0.985, green: 0.982, blue: 0.965)
            surfaceAlt = Color(red: 0.94, green: 0.935, blue: 0.915)
            border = Color.black.opacity(0.11)
            divider = Color.black.opacity(0.08)
            text = Color(red: 0.18, green: 0.18, blue: 0.20)
            dim = Color(red: 0.48, green: 0.48, blue: 0.52)
            faint = Color(red: 0.62, green: 0.62, blue: 0.66)
            keyBackground = Color.black.opacity(0.06)
        }
    }
}

private struct PulseDot: View {
    let active: Bool
    let color: Color

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .stroke(color.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 14, height: 14)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
    }
}

private struct KeeperSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                isOn.toggle()
            }
        } label: {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(isOn ? Color(red: 0.24, green: 0.62, blue: 0.36) : Color.secondary.opacity(0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(isOn ? Color(red: 0.24, green: 0.62, blue: 0.36) : Color.secondary.opacity(0.18), lineWidth: 1)
                }
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(isOn ? 0.26 : 0.18), radius: isOn ? 1.8 : 1.2, y: 1)
                        .offset(x: isOn ? 13 : 1)
                        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isOn)
                }
                .overlay {
                    if isOn {
                        RoundedRectangle(cornerRadius: 999, style: .continuous)
                            .stroke(Color.white.opacity(0.28), lineWidth: 0.75)
                            .padding(1)
                            .transition(.opacity)
                    }
                }
                .frame(width: 28, height: 16)
                .animation(.easeInOut(duration: 0.16), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        if let image = Self.templateIcon(named: "clolid-active") {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.primary)
                .padding(size * 0.14)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                )
        } else {
            Image(systemName: "laptopcomputer")
                .font(.system(size: size * 0.5))
                .frame(width: size, height: size)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
    }

    private static func templateIcon(named resourceName: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.isTemplate = true
        return image
    }
}

private final class WelcomeWindowController {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    func show(model: KeeperModel) {
        let controller = NSHostingController(rootView: WelcomeView(model: model) { [weak self] in
            self?.window?.close()
        })
        let window = NSWindow(contentViewController: controller)
        window.title = "Welcome"
        window.setContentSize(NSSize(width: 460, height: 470))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: KeeperModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                AppIconView(size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clolid")
                        .font(.system(size: 20, weight: .bold))
                    Text("Version \(AppConstants.marketingVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            Text("Keeps your Mac awake with the lid closed, then sleeps the built-in display.")
                .font(.system(size: 14))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                featureRow("Closed-lid awake", "Turns on disablesleep for the session.")
                featureRow("Lid watcher", "Sleeps the display as the lid closes.")
                featureRow("Clean exit", "Stop or quit restores normal sleep.")
            }

            Text("Power changes use sudo pmset. You will be prompted first.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(12)
                .background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Spacer()

            HStack(spacing: 8) {
                Button("Not now") {
                    model.didCompleteWelcome = true
                    close()
                }
                Spacer()
                Button("Get started") {
                    model.didCompleteWelcome = true
                    model.requestNotificationsIfNeeded()
                    close()
                    StartCoordinator.shared.start(model: model)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460, height: 470)
    }

    private func featureRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(red: 0.24, green: 0.62, blue: 0.36))
                .font(.system(size: 14))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private final class AuthorizationWindowController {
    static let shared = AuthorizationWindowController()
    private var window: NSWindow?

    func show(model: KeeperModel) {
        let controller = NSHostingController(rootView: AuthorizationView(model: model) { [weak self] shouldStart in
            self?.window?.close()
            if shouldStart {
                model.didShowAuthorizationPreflight = true
                model.start()
            }
        })
        let window = NSWindow(contentViewController: controller)
        window.title = "Power Settings"
        window.setContentSize(NSSize(width: 440, height: 390))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AuthorizationView: View {
    @ObservedObject var model: KeeperModel
    let complete: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "power")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color(red: 0.92, green: 0.58, blue: 0.18))
                .frame(width: 48, height: 48)
                .background(Color(red: 0.92, green: 0.58, blue: 0.18).opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("Allow power changes?")
                .font(.system(size: 16, weight: .bold))

            Text("Clolid sets pmset disablesleep on start and restores it on stop.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)

            VStack(spacing: 0) {
                commandRow("On start", "sudo pmset -a disablesleep 1")
                Divider()
                commandRow("While running", "caffeinate -i -s -u")
                Divider()
                commandRow("On stop / quit", "sudo pmset -a disablesleep 0")
            }
            .font(.system(size: 11.5, design: .monospaced))
            .background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Spacer()

            HStack(spacing: 8) {
                Button("Cancel") {
                    complete(false)
                }
                Spacer()
                Button("Continue...") {
                    model.requestNotificationsIfNeeded()
                    complete(true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 440, height: 390)
    }

    private func commandRow(_ label: String, _ command: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(command)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(model: KeeperModel) {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.setContentSize(NSSize(width: 460, height: 720))
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            self.window = window
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: KeeperModel

    var body: some View {
        VStack(spacing: 0) {
            settingsSection("Session")
            settingsRow(
                title: "Auto-start session",
                subtitle: "Run when app opens."
            ) {
                KeeperSwitch(isOn: $model.startSessionOnLaunch)
                    .accessibilityLabel("Auto-start session")
            }
            settingsRow(
                title: "Start at login",
                subtitle: "Open app at login."
            ) {
                KeeperSwitch(isOn: Binding(
                    get: { model.startAtLogin },
                    set: { model.setStartAtLogin($0) }
                ))
                .accessibilityLabel("Start at login")
            }
            settingsRow(
                title: "Lid poll interval",
                subtitle: "How often to check."
            ) {
                Picker("", selection: Binding(
                    get: { model.pollIntervalSeconds },
                    set: { model.updatePollInterval($0) }
                )) {
                    Text("0.5 s").tag(0.5)
                    Text("1.0 s").tag(1.0)
                    Text("2.0 s").tag(2.0)
                }
                .labelsHidden()
                .frame(width: 92)
            }
            settingsRow(
                title: "Screen lock",
                subtitle: "Uses macOS sysadminctl."
            ) {
                Picker("", selection: Binding(
                    get: { model.screenLockPolicy },
                    set: { model.screenLockPolicy = $0 }
                )) {
                    ForEach(ScreenLockPolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .labelsHidden()
                .frame(width: 124)
            }

            settingsSection("Behavior")
            settingsRow(title: "Sleep display on lid close") {
                KeeperSwitch(isOn: $model.sleepDisplayOnLidClose)
                    .accessibilityLabel("Sleep display on lid close")
            }
            settingsRow(title: "Lid close alert") {
                KeeperSwitch(isOn: $model.notifyOnLidClose)
                    .accessibilityLabel("Lid close alert")
            }
            settingsRow(title: "Start alert") {
                KeeperSwitch(isOn: $model.notifyOnSessionStart)
                    .accessibilityLabel("Start alert")
            }
            settingsRow(
                title: "Notifications",
                subtitle: "Ask macOS for banners."
            ) {
                Button("Request") {
                    model.requestNotificationsIfNeeded()
                }
                .controlSize(.small)
            }
            settingsRow(
                title: "Require AC power",
                subtitle: "Block sessions on battery."
            ) {
                KeeperSwitch(isOn: $model.requireExternalPower)
                    .accessibilityLabel("Require AC power")
            }

            settingsSection("Menu-bar icon")
            settingsRow(title: "Style") {
                Picker("", selection: Binding(
                    get: { model.menuBarIconStyle },
                    set: { model.menuBarIconStyle = $0 }
                )) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
            }
            settingsRow(title: "Show elapsed time") {
                KeeperSwitch(isOn: $model.showElapsedInMenuBar)
                    .accessibilityLabel("Show elapsed time")
            }

            settingsSection("Safety")
            settingsRow(
                title: "Restore sleep now",
                subtitle: "Stop session and reset pmset."
            ) {
                Button("Restore") {
                    model.restoreNormalSleep()
                }
                .controlSize(.small)
            }
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func settingsSection(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private func settingsRow<Control: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 20)
        }
    }
}

private final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: AboutView())
            let window = NSWindow(contentViewController: controller)
            window.title = "About Clolid"
            window.setContentSize(NSSize(width: 420, height: 250))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            AppIconView(size: 64)
            Text("Clolid")
                .font(.system(size: 20, weight: .bold))
            Text("Closed-lid awake with instant display sleep.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Text("Version \(AppConstants.marketingVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 420, height: 250)
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
