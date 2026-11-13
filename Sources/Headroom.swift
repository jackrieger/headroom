import AppKit
import Combine
import ServiceManagement
import SwiftUI

let usagePageURL = URL(string: "https://claude.ai/settings/usage")!
let refreshOptions = [1, 2, 5, 10, 15, 30]
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
        case .normal: .primary
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
    var model: String? = nil
    var creditsAvailable = false

    func currentPercent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return percent
    }

    func onCredits(at now: Date) -> Bool { creditsAvailable && currentPercent(at: now) >= 100 }

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

struct Credits: Sendable {
    let enabled: Bool
    let currency: String
    var used: Double?
    var limit: Double?
    var balance: Double?

    func format(_ amount: Double) -> String {
        amount.formatted(.currency(code: currency))
    }

    var summary: String {
        guard enabled else { return "Usage credits off" }
        var parts = ["Usage credits on"]
        if let used {
            parts.append("\(format(used))\(limit.map { " of \(format($0))" } ?? "") used this month")
        }
        if limit == nil { parts.append("no monthly limit") }
        if let balance { parts.append("\(format(balance)) left") }
        return parts.joined(separator: " · ")
    }
}

struct Usage: Sendable {
    let plan: String?
    let limits: [Limit]
    let fetchedAt: Date
    var credits: Credits? = nil

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

func money(_ value: Any?, exponent: Int) -> Double? {
    if let amount = value as? [String: Any], let minor = number(amount["amount_minor"]) {
        return minor / pow(10, Double(number(amount["exponent"]).map(Int.init) ?? exponent))
    }
    return number(value).map { $0 / pow(10, Double(exponent)) }
}

func credits(from rateLimits: [String: Any]) -> Credits? {
    let extra = rateLimits["extra_usage"] as? [String: Any]
    let spend = rateLimits["spend"] as? [String: Any]
    guard extra != nil || spend != nil else { return nil }
    let exponent = number(extra?["decimal_places"]).map(Int.init) ?? 2
    let currency = ((spend?["used"] as? [String: Any])?["currency"] as? String) ?? extra?["currency"] as? String ?? "USD"
    var credits = Credits(enabled: (extra?["is_enabled"] as? Bool ?? spend?["enabled"] as? Bool) == true, currency: currency.uppercased())
    credits.used = money(spend?["used"], exponent: exponent) ?? money(extra?["used_credits"], exponent: exponent)
    credits.limit = money(spend?["limit"], exponent: exponent) ?? money(extra?["monthly_limit"], exponent: exponent)
    credits.balance = money(spend?["balance"], exponent: exponent)
    return credits
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
    let extra = rateLimits["extra_usage"] as? [String: Any]
    let creditsAvailable = extra?["is_enabled"] as? Bool == true
        && extra?["spend_limit_reached"] as? Bool != true
        && (number(extra?["utilization"]) ?? 0) < 100
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
            window: limitWindow(kind: kind, group: row["group"] as? String),
            model: model,
            creditsAvailable: creditsAvailable)
    }
    guard !limits.isEmpty else { throw UsageError(message: "Claude Code reported no plan limits.") }
    return Usage(plan: plan, limits: limits, fetchedAt: Date(), credits: credits(from: rateLimits))
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
    @Published var signInNotes: [String: String] = [:]
    @Published var showModelLimits = UserDefaults.standard.object(forKey: "showModelLimits") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showModelLimits, forKey: "showModelLimits") }
    }
    @Published var refreshMinutes = refreshOptions.contains(UserDefaults.standard.integer(forKey: "refreshMinutes"))
        ? UserDefaults.standard.integer(forKey: "refreshMinutes") : 2 {
        didSet {
            UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes")
            refreshIfDue()
        }
    }
    @Published var menuBarStyle = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarStyle") ?? "") ?? .dots {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    var closePopover: (() -> Void)?
    private var signInTimer: Timer?

    init() {
        if let data = UserDefaults.standard.data(forKey: "accounts"),
           let saved = try? JSONDecoder().decode([AccountConfig].self, from: data) {
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

    var visibleAccounts: [AccountConfig] { sortedAccounts.filter { !hiddenAsDuplicate($0) } }

    var tracksTerminalLogin: Bool { accounts.contains { $0.isDefault } }

    private func loginID(_ account: AccountConfig) -> String? {
        state(account).error?.signedOut == true ? nil : state(account).profile.id
    }

    func hiddenAsDuplicate(_ account: AccountConfig) -> Bool {
        guard let id = loginID(account), let index = accounts.firstIndex(of: account) else { return false }
        let others = accounts.indices.filter { $0 != index && loginID(accounts[$0]) == id }
        if account.isDefault { return !others.isEmpty }
        return others.contains { !accounts[$0].isDefault && $0 < index }
    }

    func sharesTerminalLogin(_ account: AccountConfig) -> Bool {
        !account.isDefault && accounts.contains { $0.isDefault && hiddenAsDuplicate($0) && loginID($0) == loginID(account) }
    }

    var refreshing: Bool { states.values.contains { $0.refreshing } }

    var modelLimitNames: [String] {
        Set(visibleAccounts.flatMap { state($0).usage?.limits.compactMap(\.model) ?? [] }).sorted()
    }

    var oldestFetch: Date? { visibleAccounts.compactMap { state($0).usage?.fetchedAt }.min() }

    private func updateProfiles() {
        for account in accounts {
            let current = profile(configDir: account.configDir)
            guard current.id != state(account).profile.id || current.email != state(account).profile.email else { continue }
            let switched = current.id != state(account).profile.id
            states[account.id, default: AccountState()].profile = current
            if switched {
                states[account.id]?.usage = nil
                states[account.id]?.lastAttempt = nil
            }
        }
    }

    func refreshIfStale(olderThan age: TimeInterval) {
        updateProfiles()
        for account in accounts where !hiddenAsDuplicate(account) {
            if let lastAttempt = state(account).lastAttempt, Date().timeIntervalSince(lastAttempt) < age { continue }
            refresh(account)
        }
    }

    func refreshIfDue() { refreshIfStale(olderThan: TimeInterval(refreshMinutes * 60) - 5) }

    func refreshAll() {
        updateProfiles()
        accounts.filter { !hiddenAsDuplicate($0) }.forEach(refresh)
    }

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
        signInNotes[account.id] = nil
        signIns[account.id] = SignInWatch(since: Date(), previousID: profile(configDir: configDir).id)
        if signInTimer == nil {
            signInTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkSignIns() }
            }
        }
        closePopover?()
    }

    func checkSignIns() {
        for (id, watch) in signIns {
            guard let account = accounts.first(where: { $0.id == id }), Date().timeIntervalSince(watch.since) < 15 * 60 else {
                signIns[id] = nil
                continue
            }
            let current = profile(configDir: account.configDir).id
            guard current != nil, current != watch.previousID else { continue }
            signIns[id] = nil
            if let existing = accounts.first(where: { $0.id != id && profile(configDir: $0.configDir).id == current }),
               let configDir = account.configDir {
                signInNotes[id] = "That login is already in Headroom as \(label(existing)). Sign in with a different account."
                states[id] = AccountState(error: UsageError(message: "Not signed in.", signedOut: true))
                Task.detached {
                    if let claude = findClaude() { _ = await runClaude(claude, ["auth", "logout"], configDir: configDir, timeout: 30) }
                }
                continue
            }
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

    func addTerminalLogin() {
        guard !tracksTerminalLogin else { return }
        let account = AccountConfig(id: "default")
        accounts.append(account)
        states[account.id] = AccountState(profile: profile(configDir: nil))
        save()
        refresh(account)
    }

    func remove(_ account: AccountConfig) {
        accounts.removeAll { $0.id == account.id }
        states[account.id] = nil
        signIns[account.id] = nil
        signInNotes[account.id] = nil
        save()
        guard let configDir = account.configDir, configDir.hasPrefix(accountsDirectory.path + "/") else { return }
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
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: percent > 0 ? max(geometry.size.width * min(percent, 100) / 100, 6) : 0)
            }
        }
        .frame(height: 6)
        .padding(.vertical, 3)
    }
}

struct LimitRow: View {
    let limit: Limit
    let now: Date

    var body: some View {
        let percent = limit.currentPercent(at: now)
        let level = Level(percent: percent)
        let onCredits = limit.onCredits(at: now)
        let color = onCredits ? Color(nsColor: .systemBlue) : level.color
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title).font(.callout.weight(.medium))
                Spacer()
                Text("\(Int(percent.rounded()))%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(level == .normal && !onCredits ? Color.primary : color)
            }
            UsageBar(percent: percent, color: color)
            if onCredits {
                Text("Using usage credits\(limit.resetsAt.map { " · limit resets \(whenText($0, now: now))" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(color)
            } else if let resetsAt = limit.resetsAt, resetsAt > now {
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
            if let note = model.signInNotes[account.id] {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let usage = state.usage {
                ForEach(usage.limits.filter { model.showModelLimits || $0.model == nil }) { LimitRow(limit: $0, now: now) }
                if let credits = usage.credits {
                    Text(credits.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    Text(model.sharesTerminalLogin(account) ? "\(email) · also your terminal login" : email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                }
                Divider()
                Button("Remove from Headroom") { model.remove(account) }
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
                let accounts = model.visibleAccounts
                VStack(alignment: .leading, spacing: 14) {
                    if accounts.isEmpty {
                        Text("No accounts yet. Add one below.").font(.callout).foregroundStyle(.secondary)
                    }
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
                if model.tracksTerminalLogin {
                    Button { model.addAccount() } label: {
                        Label("Add account", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Sign in to another Claude account to track it too")
                } else {
                    Menu {
                        Button("Sign In to an Account…") { model.addAccount() }
                        Button("Claude Code's Terminal Login") { model.addTerminalLogin() }
                    } label: {
                        Label("Add account", systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
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
                Text("Refresh every").foregroundStyle(.secondary)
                Spacer()
                Picker("Refresh every", selection: $model.refreshMinutes) {
                    ForEach(refreshOptions, id: \.self) { Text($0 == 1 ? "minute" : "\($0) minutes").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            if !model.modelLimitNames.isEmpty {
                HStack {
                    Toggle(model.modelLimitNames.count == 1 ? "Show \(model.modelLimitNames[0]) limit" : "Show per-model limits",
                           isOn: $model.showModelLimits)
                        .toggleStyle(.checkbox)
                    Spacer()
                }
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
    var sessionOnCredits = false
    var weeklyOnCredits = false

    var sessionColor: NSColor { sessionOnCredits ? .systemBlue : levelColor(session) }
    var weeklyColor: NSColor { weeklyOnCredits ? .systemBlue : levelColor(weekly) }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case dots, hash, horizontal, rings, numbers, vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dots: "Dot matrix"
        case .hash: "Hash and dots"
        case .horizontal: "Horizontal meters"
        case .rings: "Rings"
        case .numbers: "Stacked numbers"
        case .vertical: "Vertical meters"
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
    [(segment.session, segment.sessionColor), (segment.weekly, segment.weeklyColor)].map { value, color in
        NSAttributedString(string: percentText(value), attributes: [.font: numberFont, .foregroundColor: color])
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

func drawHash(in rect: NSRect, _ segment: StatusSegment) {
    let cellWidth: CGFloat = 1.5, pitch: CGFloat = 2.5, dot: CGFloat = 1.5
    let barHeight = (rect.height - 3) / 2
    for (value, color, y) in [(segment.session, segment.sessionColor, rect.minY + barHeight + 3), (segment.weekly, segment.weeklyColor, rect.minY)] {
        let filled = filledCells(value)
        for cell in 0..<10 {
            let x = rect.minX + CGFloat(cell) * pitch
            if cell < filled {
                color.setFill()
                NSRect(x: x, y: y, width: cellWidth, height: barHeight).fill(using: .sourceOver)
            } else {
                NSColor.labelColor.withAlphaComponent(0.45).setFill()
                NSRect(x: x, y: y + (barHeight - dot) / 2, width: dot, height: dot).fill(using: .sourceOver)
            }
        }
    }
}

func drawDots(in rect: NSRect, _ segment: StatusSegment) {
    let dot: CGFloat = 1.5, pitch: CGFloat = 2.5
    for (value, color, y) in [(segment.session, segment.sessionColor, rect.minY + 7), (segment.weekly, segment.weeklyColor, rect.minY + 0.5)] {
        let filled = filledCells(value)
        for column in 0..<10 {
            (column < filled ? color : trackColor).setFill()
            for row in 0..<2 {
                NSBezierPath(ovalIn: NSRect(x: rect.minX + CGFloat(column) * pitch, y: y + CGFloat(row) * pitch, width: dot, height: dot)).fill()
            }
        }
    }
}

func drawHorizontal(in rect: NSRect, _ segment: StatusSegment) {
    let barHeight = (rect.height - 3) / 2
    for (value, color, y) in [(segment.session, segment.sessionColor, rect.minY + barHeight + 3), (segment.weekly, segment.weeklyColor, rect.minY)] {
        trackColor.setFill()
        NSRect(x: rect.minX, y: y, width: rect.width, height: barHeight).fill(using: .sourceOver)
        if let value, value > 0 {
            color.setFill()
            NSRect(x: rect.minX, y: y, width: max(rect.width * min(value, 100) / 100, 1.5), height: barHeight).fill(using: .sourceOver)
        }
    }
}

func drawVertical(in rect: NSRect, _ segment: StatusSegment) {
    let barWidth: CGFloat = 4
    for (value, color, x) in [(segment.session, segment.sessionColor, rect.minX), (segment.weekly, segment.weeklyColor, rect.maxX - barWidth)] {
        trackColor.setFill()
        NSRect(x: x, y: rect.minY, width: barWidth, height: rect.height).fill(using: .sourceOver)
        if let value, value > 0 {
            color.setFill()
            NSRect(x: x, y: rect.minY, width: barWidth, height: max(rect.height * min(value, 100) / 100, 1)).fill(using: .sourceOver)
        }
    }
}

func drawRings(in rect: NSRect, _ segment: StatusSegment) {
    let center = NSPoint(x: rect.midX, y: rect.midY), lineWidth: CGFloat = 2.5
    for (value, color, radius) in [(segment.weekly, segment.weeklyColor, rect.width / 2 - 1.25), (segment.session, segment.sessionColor, rect.width / 2 - 4.75)] {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        trackColor.setStroke()
        track.stroke()
        if let value, value > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * min(value, 100) / 100, clockwise: true)
            arc.lineWidth = lineWidth
            color.setStroke()
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
                case .hash: drawHash(in: rect, segment)
                case .dots: drawDots(in: rect, segment)
                case .horizontal: drawHorizontal(in: rect, segment)
                case .vertical: drawVertical(in: rect, segment)
                case .rings: drawRings(in: rect, segment)
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
        popover.animates = false
        hosting.view.layoutSubtreeIfNeeded()
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
                self?.model.refreshIfDue()
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
        let tracked = model.visibleAccounts.compactMap { account in
            model.state(account).usage.map { (label: model.label(account), usage: $0) }
        }
        let segments = tracked.map { entry in
            StatusSegment(
                session: entry.usage.limit("session")?.currentPercent(at: now),
                weekly: entry.usage.limit("weekly_all")?.currentPercent(at: now),
                sessionOnCredits: entry.usage.limit("session")?.onCredits(at: now) ?? false,
                weeklyOnCredits: entry.usage.limit("weekly_all")?.onCredits(at: now) ?? false)
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
