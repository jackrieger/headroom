import AppKit
import Combine
import ServiceManagement
import SwiftUI

let usagePageURL = URL(string: "https://claude.ai/settings/usage")!
let refreshInterval: TimeInterval = 5 * 60
let requestID = "headroom"

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

struct UsageError: Error {
    let message: String
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

func parseUsage(_ output: Data) throws -> Usage {
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

func usage(from body: [String: Any]) throws -> Usage {
    let plan = (body["subscription_type"] as? String).map(planName)
    guard body["rate_limits_available"] as? Bool != false,
          let rateLimits = body["rate_limits"] as? [String: Any]
    else {
        throw UsageError(message: plan == nil
            ? "Claude Code isn't signed in to a Claude plan. Run claude in Terminal and use /login."
            : "Claude Code couldn't read your plan limits just now.")
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

func accountEmail() -> String? {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return (json["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
}

struct RunResult: Sendable {
    let out: Data
    let err: String
}

func askClaudeForUsage(_ claude: URL, timeout: TimeInterval = 45) async -> RunResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Headroom")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = claude
            process.arguments = [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
            ]
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(claude.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            let input = Pipe(), out = Pipe(), err = Pipe()
            process.standardInput = input
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                continuation.resume(returning: RunResult(out: Data(), err: error.localizedDescription))
                return
            }
            let request = #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"get_usage","skip_behaviors":true}}"#
            try? input.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
            try? input.fileHandleForWriting.close()

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

@MainActor
final class Model: ObservableObject {
    @Published var usage: Usage?
    @Published var error: String?
    @Published var refreshing = false
    @Published var email = accountEmail()
    private var lastAttempt: Date?

    func refreshIfStale(olderThan age: TimeInterval) {
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < age { return }
        refresh()
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        lastAttempt = Date()
        Task {
            defer { refreshing = false }
            guard let claude = findClaude() else {
                error = "Headroom reads your limits through Claude Code, which isn't installed."
                return
            }
            let result = await askClaudeForUsage(claude)
            email = accountEmail()
            do {
                usage = try parseUsage(result.out)
                error = nil
            } catch let failure as UsageError {
                let detail = result.out.isEmpty ? result.err.split(whereSeparator: \.isNewline).last.map(String.init) : nil
                error = detail ?? failure.message
            } catch {
                self.error = error.localizedDescription
            }
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

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            TimelineView(.periodic(from: .now, by: 30)) { context in
                limits(now: context.date)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Claude usage").font(.headline)
                    if let plan = model.usage?.plan {
                        Text(plan)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                if let email = model.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.refreshing { ProgressView().controlSize(.mini) }
            Button { NSWorkspace.shared.open(usagePageURL) } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open the usage page on claude.ai")
        }
    }

    private func limits(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let usage = model.usage {
                ForEach(usage.limits) { LimitRow(limit: $0, now: now) }
            } else if model.error == nil {
                Text("Checking…").foregroundStyle(.secondary)
            }
            if let error = model.error {
                Text(model.usage == nil ? error : "Couldn't update: \(error)")
                    .font(.caption)
                    .foregroundStyle(model.usage == nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
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
            if let fetchedAt = model.usage?.fetchedAt {
                Text("Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
            }
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.refreshing)
            .help("Refresh")
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
    }
}

func barsIcon(top: Double?, bottom: Double?) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 14), flipped: false) { _ in
        NSColor.black.set()
        for (value, y) in [(top, 8.0), (bottom, 1.5)] {
            let track = NSRect(x: 0.5, y: y + 0.5, width: 15, height: 4)
            let outline = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1
            outline.stroke()
            if let value, value > 0 {
                let fill = NSRect(x: track.minX, y: track.minY, width: max(track.width * min(value, 100) / 100, 3), height: track.height)
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }
        }
        return true
    }
    image.isTemplate = true
    return image
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var cancellables = Set<AnyCancellable>()
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !UserDefaults.standard.bool(forKey: "registeredLoginItem") {
            UserDefaults.standard.set(true, forKey: "registeredLoginItem")
            try? SMAppService.mainApp.register()
        }

        let hosting = NSHostingController(rootView: ContentView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        }
        updateStatusItem()
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }
            .store(in: &cancellables)

        model.refresh()
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
        let session = model.usage?.limit("session")?.currentPercent(at: now)
        let weekly = model.usage?.limit("weekly_all")?.currentPercent(at: now)
        button.image = barsIcon(top: session, bottom: weekly)
        let headline = model.usage?.headline(at: now)
        let text = headline.map { " \(Int($0.rounded()))%" } ?? " –"
        if let headline, let color = Level(percent: headline).menuBarColor, let font = button.font {
            button.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font])
        } else {
            button.title = text
        }
        let parts = [session.map { "5-hour \(Int($0.rounded()))%" }, weekly.map { "weekly \(Int($0.rounded()))%" }].compactMap { $0 }
        button.toolTip = "Claude usage: " + (parts.isEmpty ? model.error ?? "checking…" : parts.joined(separator: " · "))
    }
}
