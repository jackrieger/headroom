import AppKit
import Combine
import ServiceManagement
import SwiftUI

let usagePageURL = URL(string: "https://claude.ai/settings/usage")!
let refreshInterval: TimeInterval = 5 * 60
let requestID = "headroom"
let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Headroom")
let accountsDirectory = supportDirectory.appendingPathComponent("Accounts")

enum Level {
    case normal, warning, critical

    init(percent: Double) {
        self = percent >= 95 ? .critical : percent >= 80 ? .warning : .normal
    }

    var color: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }

    var menuBarColor: NSColor? {
        switch self {
        case .normal: nil
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
}

struct Limit: Identifiable, Sendable {
    let id: String
    let kind: String
    let title: String
    let percent: Double
    let resetsAt: Date?
    let window: TimeInterval?

    func currentPercent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return percent
    }

    func elapsedFraction(at now: Date) -> Double? {
        guard let resetsAt, let window, resetsAt > now else { return nil }
        return min(max(1 - resetsAt.timeIntervalSince(now) / window, 0), 1)
    }

    func projectedFull(at now: Date) -> Date? {
        guard let resetsAt, let window, let elapsed = elapsedFraction(at: now),
              elapsed >= 0.1, percent >= 20, percent < 100 else { return nil }
        let full = now.addingTimeInterval((100 - percent) / percent * elapsed * window)
        return full < resetsAt ? full : nil
    }
}

struct Usage: Sendable {
    let plan: String?
    let limits: [Limit]
    let fetchedAt: Date

    func limit(_ kind: String) -> Limit? { limits.first { $0.kind == kind } }

    func headline(at now: Date) -> Double? {
        let main = limits.filter { $0.kind == "session" || $0.kind == "weekly_all" }
        return (main.isEmpty ? limits : main).map { $0.currentPercent(at: now) }.max()
    }
}

struct UsageError: Error, Sendable {
    let message: String
    var signedOut = false
}

func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

func date(_ value: Any?) -> Date? {
    if let seconds = number(value) { return Date(timeIntervalSince1970: seconds) }
    guard let text = value as? String else { return nil }
    let withoutFraction = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: withoutFraction)
}

func planName(_ type: String) -> String {
    ["pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise"][type] ?? type.capitalized
}

func limitTitle(kind: String, model: String?) -> String {
    switch kind {
    case "session": return "5-hour session"
    case "weekly_all": return "Weekly · all models"
    case "weekly_scoped": return "Weekly · \(model ?? "one model")"
    default:
        let name = kind.replacingOccurrences(of: "_", with: " ").capitalized
        return model.map { "\(name) · \($0)" } ?? name
    }
}

func limitWindow(kind: String, group: String?) -> TimeInterval? {
    if kind == "session" || group == "session" { return 5 * 3600 }
    if kind.hasPrefix("weekly") || group == "weekly" { return 7 * 86400 }
    return nil
}

func parseUsage(_ output: Data) throws(UsageError) -> Usage {
    for line in output.split(separator: UInt8(ascii: "\n")) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              response["request_id"] as? String == requestID
        else { continue }
        if response["subtype"] as? String == "error" {
            throw UsageError(message: response["error"] as? String ?? "Claude Code returned an error.")
        }
        guard let body = response["response"] as? [String: Any] else { break }
        return try usage(from: body)
    }
    throw UsageError(message: "Claude Code didn't answer.")
}

func usage(from body: [String: Any]) throws(UsageError) -> Usage {
    let plan = (body["subscription_type"] as? String).map(planName)
    guard body["rate_limits_available"] as? Bool != false,
          let rateLimits = body["rate_limits"] as? [String: Any]
    else {
        if plan == nil { throw UsageError(message: "Not signed in.", signedOut: true) }
        throw UsageError(message: "Claude Code couldn't read your plan limits just now.")
    }
    let rows = rateLimits["limits"] as? [[String: Any]] ?? []
    let limits = rows.enumerated().compactMap { index, row -> Limit? in
        guard let percent = number(row["percent"]) else { return nil }
        let kind = row["kind"] as? String ?? "limit"
        let model = ((row["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        return Limit(
            id: "\(kind)-\(index)",
            kind: kind,
            title: limitTitle(kind: kind, model: model),
            percent: percent,
            resetsAt: date(row["resets_at"]),
            window: limitWindow(kind: kind, group: row["group"] as? String))
    }
    guard !limits.isEmpty else { throw UsageError(message: "Claude Code reported no plan limits.") }
    return Usage(plan: plan, limits: limits, fetchedAt: Date())
}

func findClaude() -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
}

struct Profile: Sendable {
    var id: String?
    var email: String?
}

func profile(configDir: String?) -> Profile {
    let directory = configDir.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(".claude.json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let account = json["oauthAccount"] as? [String: Any]
    else { return Profile() }
    return Profile(id: account["accountUuid"] as? String, email: account["emailAddress"] as? String)
}

func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct RunResult: Sendable {
    let out: Data
    let err: String
}

func runClaude(_ claude: URL, _ arguments: [String], configDir: String?, input: String? = nil, timeout: TimeInterval = 45) async -> RunResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = claude
            process.arguments = arguments
            process.currentDirectoryURL = supportDirectory
            // Clean on purpose: inherited CLAUDE_CODE_* and ANTHROPIC_* variables can switch which account claude reads
            let inherited = ProcessInfo.processInfo.environment
            var environment = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL"].reduce(into: [String: String]()) { $0[$1] = inherited[$1] }
            environment["PATH"] = "\(claude.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
            environment["CLAUDE_CONFIG_DIR"] = configDir
            process.environment = environment
            let stdin = Pipe(), out = Pipe(), err = Pipe()
            if input != nil {
                process.standardInput = stdin
            } else {
                process.standardInput = FileHandle.nullDevice
            }
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                continuation.resume(returning: RunResult(out: Data(), err: error.localizedDescription))
                return
            }
            if let input {
                try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }

            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            var errData = Data()
            let errDone = DispatchGroup()
            errDone.enter()
            DispatchQueue.global().async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                errDone.leave()
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            errDone.wait()
            process.waitUntilExit()
            deadline.cancel()
            continuation.resume(returning: RunResult(out: outData, err: String(decoding: errData, as: UTF8.self)))
        }
    }
}

func fetchUsage(configDir: String?) async -> Result<Usage, UsageError> {
    guard let claude = findClaude() else {
        return .failure(UsageError(message: "Headroom reads your limits through Claude Code, which isn't installed."))
    }
    let request = #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"get_usage","skip_behaviors":true}}"#
    let arguments = [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
    ]
    let result = await runClaude(claude, arguments, configDir: configDir, input: request + "\n")
    do {
        return .success(try parseUsage(result.out))
    } catch {
        let detail = result.out.isEmpty ? result.err.split(whereSeparator: \.isNewline).last.map(String.init) : nil
        return .failure(detail.map { UsageError(message: $0) } ?? error)
    }
}

struct AccountConfig: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var configDir: String?
    var name: String?

    var isDefault: Bool { configDir == nil }
}

struct AccountState {
    var usage: Usage?
    var error: UsageError?
    var refreshing = false
    var profile = Profile()
    var lastAttempt: Date?
}

struct SignInWatch {
    let since: Date
    let previousID: String?
}

@MainActor
final class Model: ObservableObject {
    @Published private(set) var accounts: [AccountConfig]
    @Published var states: [String: AccountState] = [:]
    @Published var signIns: [String: SignInWatch] = [:]
    @Published var menuBarStyle = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarStyle") ?? "") ?? .hash {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    var closePopover: (() -> Void)?
    private var signInTimer: Timer?

    init() {
        if let data = UserDefaults.standard.data(forKey: "accounts"),
           let saved = try? JSONDecoder().decode([AccountConfig].self, from: data), !saved.isEmpty {
            accounts = saved
        } else {
            accounts = [AccountConfig(id: "default")]
        }
        for account in accounts {
            states[account.id] = AccountState(profile: profile(configDir: account.configDir))
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: "accounts")
    }

    func state(_ account: AccountConfig) -> AccountState { states[account.id] ?? AccountState() }

    func label(_ account: AccountConfig) -> String {
        let state = state(account)
        return account.name
            ?? state.usage?.plan
            ?? state.profile.email.map { String($0.prefix { $0 != "@" }) }
            ?? (account.isDefault ? "Claude Code" : "New account")
    }

    var sortedAccounts: [AccountConfig] {
        accounts.sorted { label($0).localizedStandardCompare(label($1)) == .orderedAscending }
    }

    func duplicate(of account: AccountConfig) -> String? {
        let sorted = sortedAccounts
        guard let id = state(account).profile.id, let index = sorted.firstIndex(of: account) else { return nil }
        return sorted[..<index].first { state($0).profile.id == id }.map(label)
    }

    var refreshing: Bool { states.values.contains { $0.refreshing } }

    var oldestFetch: Date? { accounts.compactMap { state($0).usage?.fetchedAt }.min() }

    func refreshIfStale(olderThan age: TimeInterval) {
        for account in accounts {
            if let lastAttempt = state(account).lastAttempt, Date().timeIntervalSince(lastAttempt) < age { continue }
            refresh(account)
        }
    }

    func refreshAll() { accounts.forEach(refresh) }

    func refresh(_ account: AccountConfig) {
        guard !state(account).refreshing else { return }
        states[account.id, default: AccountState()].refreshing = true
        states[account.id]?.lastAttempt = Date()
        Task {
            let result = await fetchUsage(configDir: account.configDir)
            guard accounts.contains(where: { $0.id == account.id }) else { return }
            var state = self.state(account)
            state.refreshing = false
            state.profile = profile(configDir: account.configDir)
            switch result {
            case .success(let usage):
                state.usage = usage
                state.error = nil
            case .failure(let error):
                state.error = error
            }
            states[account.id] = state
        }
    }

    func addAccount() {
        let account = AccountConfig(id: UUID().uuidString, configDir: accountsDirectory.appendingPathComponent(UUID().uuidString).path)
        do {
            try FileManager.default.createDirectory(atPath: account.configDir!, withIntermediateDirectories: true)
        } catch {
            NSSound.beep()
            return
        }
        accounts.append(account)
        states[account.id] = AccountState(error: UsageError(message: "Not signed in.", signedOut: true))
        save()
        signIn(account)
    }

    func signIn(_ account: AccountConfig) {
        guard let configDir = account.configDir, let claude = findClaude() else { return }
        let script = """
        #!/bin/zsh
        rm -f "$0"
        clear
        print -P "%BAdd a Claude account to Headroom%b"
        print "Your browser opens next. Make sure it's signed in to the Claude account you want to add."
        print "After you approve, copy the code the page shows, paste it below and press Return."
        print
        CLAUDE_CONFIG_DIR=\(shellQuote(configDir)) \(shellQuote(claude.path)) auth login
        print
        read -sk '?Press any key to close.'

        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-sign-in-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
        signIns[account.id] = SignInWatch(since: Date(), previousID: profile(configDir: configDir).id)
        if signInTimer == nil {
            signInTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkSignIns() }
            }
        }
        closePopover?()
    }

    private func checkSignIns() {
        for (id, watch) in signIns {
            guard let account = accounts.first(where: { $0.id == id }), Date().timeIntervalSince(watch.since) < 15 * 60 else {
                signIns[id] = nil
                continue
            }
            let current = profile(configDir: account.configDir).id
            guard current != nil, current != watch.previousID else { continue }
            signIns[id] = nil
            Task {
                try? await Task.sleep(for: .seconds(2))
                refresh(account)
            }
        }
        if signIns.isEmpty {
            signInTimer?.invalidate()
            signInTimer = nil
        }
    }

    func rename(_ account: AccountConfig, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[index].name = trimmed.isEmpty ? nil : trimmed
        save()
    }

    func remove(_ account: AccountConfig) {
        guard let configDir = account.configDir, configDir.hasPrefix(accountsDirectory.path + "/") else { return }
        accounts.removeAll { $0.id == account.id }
        states[account.id] = nil
        signIns[account.id] = nil
        save()
        Task.detached {
            if let claude = findClaude() {
                _ = await runClaude(claude, ["auth", "logout"], configDir: configDir, timeout: 30)
            }
            try? FileManager.default.removeItem(atPath: configDir)
        }
    }
}

func shortDuration(_ seconds: TimeInterval) -> String {
    let minutes = max(Int(seconds / 60), 1)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60, restMinutes = minutes % 60
    if hours < 24 { return restMinutes == 0 ? "\(hours)h" : "\(hours)h \(restMinutes)m" }
    let days = hours / 24, restHours = hours % 24
    return restHours == 0 ? "\(days)d" : "\(days)d \(restHours)h"
}

func whenText(_ date: Date, now: Date) -> String {
    let seconds = date.timeIntervalSince(now)
    if seconds < 86400 { return "in \(shortDuration(seconds))" }
    return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

struct UsageBar: View {
    let percent: Double
    let elapsed: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(Level(percent: percent).color)
                    .frame(width: percent > 0 ? max(geometry.size.width * min(percent, 100) / 100, 6) : 0)
                if let elapsed {
                    Capsule()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 2, height: geometry.size.height + 6)
                        .offset(x: geometry.size.width * elapsed - 1)
                }
            }
        }
        .frame(height: 6)
        .padding(.vertical, 3)
        .help(elapsed == nil ? "" : "The tick marks how much of this window has passed")
    }
}

struct LimitRow: View {
    let limit: Limit
    let now: Date

    var body: some View {
        let percent = limit.currentPercent(at: now)
        let level = Level(percent: percent)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title).font(.callout.weight(.medium))
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(level == .normal ? Color.primary : level.color)
            }
            UsageBar(percent: percent, elapsed: limit.elapsedFraction(at: now))
            if let resetsAt = limit.resetsAt, resetsAt > now {
                Text("\(percent >= 100 ? "Limit reached · resets" : "Resets") \(whenText(resetsAt, now: now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let full = limit.projectedFull(at: now) {
                Text("At this pace you'll hit it \(whenText(full, now: now))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct AccountSection: View {
    @ObservedObject var model: Model
    let account: AccountConfig
    let now: Date
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let state = model.state(account)
        VStack(alignment: .leading, spacing: 12) {
            title(state)
            if let original = model.duplicate(of: account) {
                Text("This is the same login as \(original). Sign in again with a different account.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let usage = state.usage {
                ForEach(usage.limits) { LimitRow(limit: $0, now: now) }
            }
            if model.signIns[account.id] != nil, state.usage == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Finish signing in in Terminal…").font(.callout).foregroundStyle(.secondary)
                }
            } else if let error = state.error {
                problem(error, hasUsage: state.usage != nil)
            } else if state.usage == nil {
                Text("Checking…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func title(_ state: AccountState) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .frame(maxWidth: 180)
                        .onAppear { nameFocused = true }
                        .onSubmit {
                            model.rename(account, to: draft)
                            renaming = false
                        }
                        .onExitCommand { renaming = false }
                } else {
                    HStack(spacing: 6) {
                        Text(model.label(account)).font(.headline)
                        if let plan = state.usage?.plan, plan != model.label(account) {
                            Text(plan)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                }
                if let email = state.profile.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.refreshing { ProgressView().controlSize(.mini) }
            Menu {
                Button("Rename…") {
                    draft = model.label(account)
                    renaming = true
                }
                if !account.isDefault {
                    Button("Sign In Again…") { model.signIn(account) }
                    Divider()
                    Button("Remove Account") { model.remove(account) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func problem(_ error: UsageError, hasUsage: Bool) -> some View {
        if error.signedOut && account.isDefault && !hasUsage {
            Text("Claude Code isn't signed in. Run claude in Terminal and use /login.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } else if error.signedOut && !account.isDefault {
            HStack {
                Text(hasUsage ? "Signed out. These numbers are old." : "Not signed in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign In…") { model.signIn(account) }
                    .controlSize(.small)
            }
        } else {
            Text(hasUsage ? "Couldn't update: \(error.message)" : error.message)
                .font(.caption)
                .foregroundStyle(hasUsage ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let accounts = model.sortedAccounts
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(accounts) { account in
                        if account != accounts.first { Divider() }
                        AccountSection(model: model, account: account, now: context.date)
                    }
                }
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { model.addAccount() } label: {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Sign in to another Claude account to track it too")
                Spacer()
                if let fetched = model.oldestFetch {
                    Text("Updated \(fetched.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                }
                Button { model.refreshAll() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.refreshing)
                .help("Refresh")
                Button { NSWorkspace.shared.open(usagePageURL) } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help("Open the usage page on claude.ai")
            }
            HStack {
                Text("Menu bar style").foregroundStyle(.secondary)
                Spacer()
                Picker("Menu bar style", selection: $model.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            HStack {
                Toggle("Open at login", isOn: $openAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: openAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
        .font(.caption)
    }
}

func percentText(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))%" } ?? "–"
}

func levelColor(_ value: Double?) -> NSColor {
    value.flatMap { Level(percent: $0).menuBarColor } ?? .labelColor
}

struct StatusSegment {
    let session: Double?
    let weekly: Double?
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case hash, dots, horizontal, vertical, rings, numbers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hash: "Hash and dots"
        case .dots: "Dot matrix"
        case .horizontal: "Horizontal meters"
        case .vertical: "Vertical meters"
        case .rings: "Rings"
        case .numbers: "Stacked numbers"
        }
    }
}

let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
var trackColor: NSColor { NSColor.labelColor.withAlphaComponent(0.25) }

func filledCells(_ value: Double?, of cells: Int = 10) -> Int {
    guard let value, value > 0 else { return 0 }
    return max(Int((min(value, 100) / 100 * Double(cells)).rounded()), 1)
}

func numberLines(_ segment: StatusSegment) -> [NSAttributedString] {
    [segment.session, segment.weekly].map {
        NSAttributedString(string: percentText($0), attributes: [.font: numberFont, .foregroundColor: levelColor($0)])
    }
}

func segmentSize(_ style: MenuBarStyle, _ segment: StatusSegment) -> NSSize {
    switch style {
    case .hash, .dots: NSSize(width: 24, height: 12)
    case .horizontal: NSSize(width: 20, height: 13)
    case .vertical: NSSize(width: 10, height: 16)
    case .rings: NSSize(width: 17, height: 17)
    case .numbers: NSSize(width: ceil(numberLines(segment).map { $0.size().width }.max() ?? 0), height: 18)
    }
}

func drawHash(in rect: NSRect, session: Double?, weekly: Double?) {
    let cellWidth: CGFloat = 1.5, pitch: CGFloat = 2.5, dot: CGFloat = 1.5
    let barHeight = (rect.height - 3) / 2
    for (value, y) in [(session, rect.minY + barHeight + 3), (weekly, rect.minY)] {
        let filled = filledCells(value)
        for cell in 0..<10 {
            let x = rect.minX + CGFloat(cell) * pitch
            if cell < filled {
                levelColor(value).setFill()
                NSRect(x: x, y: y, width: cellWidth, height: barHeight).fill(using: .sourceOver)
            } else {
                NSColor.labelColor.withAlphaComponent(0.45).setFill()
                NSRect(x: x, y: y + (barHeight - dot) / 2, width: dot, height: dot).fill(using: .sourceOver)
            }
        }
    }
}

func drawDots(in rect: NSRect, session: Double?, weekly: Double?) {
    let dot: CGFloat = 1.5, pitch: CGFloat = 2.5
    for (value, y) in [(session, rect.minY + 7), (weekly, rect.minY + 0.5)] {
        let filled = filledCells(value)
        for column in 0..<10 {
            (column < filled ? levelColor(value) : trackColor).setFill()
            for row in 0..<2 {
                NSBezierPath(ovalIn: NSRect(x: rect.minX + CGFloat(column) * pitch, y: y + CGFloat(row) * pitch, width: dot, height: dot)).fill()
            }
        }
    }
}

func drawHorizontal(in rect: NSRect, session: Double?, weekly: Double?) {
    let barHeight = (rect.height - 3) / 2
    for (value, y) in [(session, rect.minY + barHeight + 3), (weekly, rect.minY)] {
        trackColor.setFill()
        NSRect(x: rect.minX, y: y, width: rect.width, height: barHeight).fill(using: .sourceOver)
        if let value, value > 0 {
            levelColor(value).setFill()
            NSRect(x: rect.minX, y: y, width: max(rect.width * min(value, 100) / 100, 1.5), height: barHeight).fill(using: .sourceOver)
        }
    }
}

func drawVertical(in rect: NSRect, session: Double?, weekly: Double?) {
    let barWidth: CGFloat = 4
    for (value, x) in [(session, rect.minX), (weekly, rect.maxX - barWidth)] {
        trackColor.setFill()
        NSRect(x: x, y: rect.minY, width: barWidth, height: rect.height).fill(using: .sourceOver)
        if let value, value > 0 {
            levelColor(value).setFill()
            NSRect(x: x, y: rect.minY, width: barWidth, height: max(rect.height * min(value, 100) / 100, 1)).fill(using: .sourceOver)
        }
    }
}

func drawRings(in rect: NSRect, session: Double?, weekly: Double?) {
    let center = NSPoint(x: rect.midX, y: rect.midY), lineWidth: CGFloat = 2.5
    for (value, radius) in [(weekly, rect.width / 2 - 1.25), (session, rect.width / 2 - 4.75)] {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        trackColor.setStroke()
        track.stroke()
        if let value, value > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * min(value, 100) / 100, clockwise: true)
            arc.lineWidth = lineWidth
            levelColor(value).setStroke()
            arc.stroke()
        }
    }
}

func drawNumbers(in rect: NSRect, segment: StatusSegment) {
    let lines = numberLines(segment), gap: CGFloat = 3
    let bottomBaseline = (rect.midY - (numberFont.capHeight * 2 + gap) / 2).rounded()
    for (line, baseline) in zip(lines, [bottomBaseline + numberFont.capHeight + gap, bottomBaseline]) {
        line.draw(at: NSPoint(x: rect.maxX - line.size().width, y: baseline + numberFont.descender))
    }
}

func statusImage(_ segments: [StatusSegment], style: MenuBarStyle, appearance: NSAppearance) -> NSImage {
    let height: CGFloat = 22, gap: CGFloat = 11
    let sizes = segments.map { segmentSize(style, $0) }
    let width = sizes.map(\.width).reduce(0, +) + gap * CGFloat(segments.count - 1)
    return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        appearance.performAsCurrentDrawingAppearance {
            var x: CGFloat = 0
            for (segment, size) in zip(segments, sizes) {
                let rect = NSRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
                switch style {
                case .hash: drawHash(in: rect, session: segment.session, weekly: segment.weekly)
                case .dots: drawDots(in: rect, session: segment.session, weekly: segment.weekly)
                case .horizontal: drawHorizontal(in: rect, session: segment.session, weekly: segment.weekly)
                case .vertical: drawVertical(in: rect, session: segment.session, weekly: segment.weekly)
                case .rings: drawRings(in: rect, session: segment.session, weekly: segment.weekly)
                case .numbers: drawNumbers(in: rect, segment: segment)
                }
                x += size.width + gap
            }
        }
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var cancellables = Set<AnyCancellable>()
    var timer: Timer?
    var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !UserDefaults.standard.bool(forKey: "registeredLoginItem") {
            UserDefaults.standard.set(true, forKey: "registeredLoginItem")
            try? SMAppService.mainApp.register()
        }

        let hosting = NSHostingController(rootView: ContentView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        model.closePopover = { [weak self] in self?.popover.performClose(nil) }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.updateStatusItem() }
            }
        }
        updateStatusItem()
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }
            .store(in: &cancellables)

        model.refreshAll()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshIfStale(olderThan: refreshInterval - 5)
                self?.updateStatusItem()
            }
        }
        timer?.tolerance = 10
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        model.refreshIfStale(olderThan: 60)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let now = Date()
        let tracked = model.sortedAccounts.compactMap { account in
            model.state(account).usage.map { (label: model.label(account), usage: $0) }
        }
        let segments = tracked.map { entry in
            StatusSegment(
                session: entry.usage.limit("session")?.currentPercent(at: now),
                weekly: entry.usage.limit("weekly_all")?.currentPercent(at: now))
        }
        button.image = statusImage(
            segments.isEmpty ? [StatusSegment(session: nil, weekly: nil)] : segments,
            style: model.menuBarStyle,
            appearance: button.effectiveAppearance)

        let lines = tracked.map { entry -> String in
            let parts = [
                entry.usage.limit("session").map { "5-hour \(percentText($0.currentPercent(at: now)))" },
                entry.usage.limit("weekly_all").map { "weekly \(percentText($0.currentPercent(at: now)))" },
            ].compactMap { $0 }
            return "\(entry.label): \(parts.joined(separator: " · "))"
        }
        button.toolTip = lines.isEmpty ? "Claude usage: checking…" : lines.joined(separator: "\n")
        button.setAccessibilityLabel(button.toolTip)
    }
}
