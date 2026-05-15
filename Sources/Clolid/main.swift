import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

private enum AppConstants {
    static let appName = "Clolid"
    static let bundleIdentifier = "com.pixexid.Clolid"
    static let marketingVersion = "0.1.0"
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

private struct CommandResult {
    let status: Int32
    let output: String
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

    private let shell = Shell()
    private let loginItemManager = LoginItemManager()
    private let notificationManager = NotificationManager()
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

    func refresh() {
        lidState = readLidState()
        sleepDisabled = readSleepDisabled()
        isOnACPower = readIsOnACPower()
        startAtLogin = loginItemManager.isEnabled
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

        do {
            cleanupStaleCaffeinate()
            refresh()
            if requireExternalPower && !isOnACPower {
                throw CommandError.failed("External power is required by your settings.")
            }
            try setClamshellSleepDisabled(true)
            try startCaffeinate()
            startedAt = Date()
            lastObservedLidState = readLidState()
            isRunning = true
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
        }
    }

    func stop() {
        stopPolling()
        stopCaffeinate()

        do {
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
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configurePopover()
        configureStatusItem()
        model.refresh()

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
        if model.isRunning {
            model.stop()
        }
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 320, height: 560)
        popover.contentViewController = NSHostingController(rootView: KeeperPanelView(
            model: model,
            closePopover: { [weak self] in
                self?.popover.performClose(nil)
            }
        ))
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
            popover.performClose(nil)
        } else {
            model.refresh()
            model.refreshExternalDisplayIfNeeded()
            refreshStatusIcon()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func configureKeyboardShortcuts() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
                self.popover.performClose(nil)
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
        VStack(spacing: 0) {
            header
            actionButton
            sectionLabel("Status")
            statusRow(icon: "power", label: "Session", value: active ? "Running" : "Stopped", tint: active ? colors.accent : colors.text)
            statusRow(icon: "laptopcomputer", label: "Lid", value: model.lidState.title, tint: lidClosed ? colors.warn : colors.text)
            statusRow(icon: "moon", label: "Lid awake", value: model.sleepDisabled ? "On" : "Off", tint: model.sleepDisabled ? colors.accent : colors.dim)
            statusRow(icon: "display", label: "Display", value: model.externalDisplayName ?? "-", tint: colors.dim)
            statusRow(icon: "bolt.fill", label: "Power", value: model.isOnACPower ? "AC Power" : "Battery", tint: model.requireExternalPower && !model.isOnACPower ? colors.warn : colors.dim)
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
        .padding(.vertical, 12)
        .background(headerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
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
        .padding(.vertical, 5)
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
        .padding(.vertical, 6)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        return "\(seconds / 60)m ago"
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
        .padding(.top, 10)
        .padding(.bottom, 4)
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
            .frame(height: 31)
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
        .padding(.vertical, 5)
    }

    private var divider: some View {
        Rectangle()
            .fill(colors.divider)
            .frame(height: 1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
