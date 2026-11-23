//
//  ActivityEngine.swift
//  Tally Ho — where did your day go — without telling anyone.
//
//  Engine layer only. No UI, no notifications, no network (ever). The panel
//  builds on the @Published state, the aggregation queries, and the hooks
//  documented below.
//
//  Conventions per Sashay/AGENTS.md: GCD DispatchSource timers (never
//  RunLoop Timer in an accessory app), UserDefaults cached and re-read on
//  didChangeNotification (never in hot loops), Combine @Published bindings,
//  append-only JSON day files written on a background queue.
//
//  v0.0.1 · Built for client #1.
//

import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

// MARK: - Defaults keys

enum ActivityDefaults {
    static let rules         = "categoryRules"    // [CategoryRule], codable
    static let categories    = "categories"       // [ActivityCategory], codable
    static let idleThreshold = "idleThreshold"    // Double, seconds AFK before accrual stops
    static let enabled       = "trackingEnabled"  // Bool
}

// MARK: - Models

struct ActivityCategory: Codable, Equatable {
    let name: String
    let colorHint: String   // system color name the panel resolves, e.g. "systemGreen"
}

struct CategoryRule: Codable, Equatable, Identifiable {
    var id: UUID
    var pattern: String        // case-insensitive substring on "appName windowTitle"
    var categoryName: String
}

/// One accrual of time, persisted verbatim to the day file.
/// `title` is "" when redacted — sensitive windows never store a title.
struct ActivitySegment: Codable, Equatable {
    var start: Date
    var end: Date
    var app: String        // bundle id when known, else app name
    var title: String
    var category: String   // category name, or "Focus" / "Rest" / "Private"
}

enum Day {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(for date: Date) -> String { formatter.string(from: date) }
}

// MARK: - Day store (append-only JSON day files)

/// All writes go through a serial background queue; the quit path uses the
/// synchronous variant so pending segments land before the process exits.
final class DayStore {

    let daysDirectory: URL
    private let queue = DispatchQueue(label: "com.jazinski.tallyho.store", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL) {
        self.daysDirectory = directory.appendingPathComponent("days", isDirectory: true)
        try? FileManager.default.createDirectory(at: daysDirectory, withIntermediateDirectories: true)
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    func fileURL(forDay day: String) -> URL {
        daysDirectory.appendingPathComponent("\(day).json")
    }

    /// Splits a segment at each local midnight, then appends asynchronously.
    func append(_ segment: ActivitySegment) {
        for piece in Self.splitAtMidnight(segment) {
            queue.async { [daysDirectory, encoder, decoder] in
                Self.write(piece, into: daysDirectory, encoder: encoder, decoder: decoder)
            }
        }
    }

    /// Synchronous append for the app-quit flush. Closes over the serial
    /// queue so every earlier async append lands first.
    func flush(_ segment: ActivitySegment) {
        for piece in Self.splitAtMidnight(segment) {
            queue.sync { Self.write(piece, into: daysDirectory, encoder: encoder, decoder: decoder) }
        }
    }

    /// A day's segments. [] for missing or corrupt files — never crashes the
    /// panel over one bad day.
    func segments(forDay day: String) -> [ActivitySegment] {
        queue.sync { Self.read(day, from: daysDirectory, decoder: decoder) }
    }

    private static func read(_ day: String, from directory: URL, decoder: JSONDecoder) -> [ActivitySegment] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(day).json")) else { return [] }
        return (try? decoder.decode([ActivitySegment].self, from: data)) ?? []
    }

    private static func write(_ segment: ActivitySegment, into directory: URL,
                              encoder: JSONEncoder, decoder: JSONDecoder) {
        let day = Day.string(for: segment.start)
        var existing = read(day, from: directory, decoder: decoder)
        existing.append(segment)
        if let data = try? encoder.encode(existing) {
            try? data.write(to: directory.appendingPathComponent("\(day).json"), options: .atomic)
        }
    }

    /// Splits a segment at each local midnight so day files only own their day.
    static func splitAtMidnight(_ segment: ActivitySegment) -> [ActivitySegment] {
        var pieces: [ActivitySegment] = []
        var cursor = segment.start
        let midnight = DateComponents(hour: 0, minute: 0, second: 0)
        while let next = Calendar.current.nextDate(after: cursor, matching: midnight,
                                                   matchingPolicy: .nextTime),
              next < segment.end {
            pieces.append(ActivitySegment(start: cursor, end: next, app: segment.app,
                                          title: segment.title, category: segment.category))
            cursor = next
        }
        pieces.append(ActivitySegment(start: cursor, end: segment.end, app: segment.app,
                                      title: segment.title, category: segment.category))
        return pieces
    }
}

// MARK: - Engine

final class ActivityEngine: ObservableObject {

    // Published state for the panel
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var isIdle = false
    @Published private(set) var currentApp: String?
    @Published private(set) var currentTitle: String?    // nil when redacted or AX-untrusted
    @Published private(set) var currentCategory: String?
    @Published private(set) var todaySeconds: TimeInterval = 0
    @Published var enabled: Bool = true {
        didSet {
            guard oldValue != enabled else { return }
            UserDefaults.standard.set(enabled, forKey: ActivityDefaults.enabled)
            if enabled {
                if let app = NSWorkspace.shared.frontmostApplication { transition(to: app) }
            } else {
                closeSegment(at: Date())
                currentApp = nil; currentTitle = nil; currentCategory = nil
                isIdle = false
            }
        }
    }

    /// Category override while a focus session or break runs (FocusEngine
    /// drives this — the category switcher is muted for the session).
    private(set) var overrideCategory: String?

    static let defaultCategories: [ActivityCategory] = [
        ActivityCategory(name: "Code", colorHint: "systemGreen"),
        ActivityCategory(name: "Comms", colorHint: "systemBlue"),
        ActivityCategory(name: "Other", colorHint: "systemGray"),
        ActivityCategory(name: "Focus", colorHint: "systemIndigo"),   // focus-session bucket
        ActivityCategory(name: "Rest", colorHint: "systemTeal"),      // break bucket
        ActivityCategory(name: "Private", colorHint: "systemBrown"),  // redacted bucket
    ]

    static let defaultRules: [CategoryRule] = [
        CategoryRule(id: UUID(), pattern: "xcode", categoryName: "Code"),
        CategoryRule(id: UUID(), pattern: "vs code", categoryName: "Code"),
        CategoryRule(id: UUID(), pattern: "cursor", categoryName: "Code"),
        CategoryRule(id: UUID(), pattern: "figma", categoryName: "Other"),   // Design later
        CategoryRule(id: UUID(), pattern: "slack", categoryName: "Comms"),
        CategoryRule(id: UUID(), pattern: "messages", categoryName: "Comms"),
        CategoryRule(id: UUID(), pattern: "mail", categoryName: "Comms"),
        CategoryRule(id: UUID(), pattern: "safari", categoryName: "Other"),
        CategoryRule(id: UUID(), pattern: "chrome", categoryName: "Other"),
        CategoryRule(id: UUID(), pattern: "arc", categoryName: "Other"),
    ]

    /// Frontmost apps whose window titles are never read nor stored. Matched
    /// case-insensitively against bundle id AND display name.
    static let sensitiveAppMatchers = [
        "1password",
        "keychain access",
        "keychainaccess",
        "securityagent",
    ]

    /// System Settings only counts as sensitive on a security-flavored pane.
    /// The pane name comes from the window title, which is checked in memory
    /// and then dropped.
    static let sensitivePaneKeywords = ["security", "privacy", "password", "tracking"]

    private let store: DayStore
    private var segment: ActivitySegment?    // open accrual; nil while idle/paused
    private var currentDay = Day.string(for: Date())
    private var closedTodayBase: TimeInterval = 0
    private var trustTicks = 0

    private var pollTimer: DispatchSourceTimer?
    private var activateObserver: Any?
    private var terminateObserver: Any?
    private var defaultsObserver: Any?

    // Cached settings (no UserDefaults reads in hot loops)
    private var cachedRules: [CategoryRule]
    private var cachedCategories: [ActivityCategory]
    private var cachedIdleThreshold: Double

    var daysDirectory: URL { store.daysDirectory }

    init(storeDirectory: URL? = nil, autostart: Bool = true) {
        let dir = storeDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Tally", isDirectory: true)
        store = DayStore(directory: dir)

        let d = UserDefaults.standard
        d.register(defaults: [
            ActivityDefaults.idleThreshold: 120.0,
            ActivityDefaults.enabled: true,
        ])
        if d.data(forKey: ActivityDefaults.rules) == nil {
            if let data = try? JSONEncoder().encode(Self.defaultRules) {
                d.set(data, forKey: ActivityDefaults.rules)
            }
        }
        if d.data(forKey: ActivityDefaults.categories) == nil {
            if let data = try? JSONEncoder().encode(Self.defaultCategories) {
                d.set(data, forKey: ActivityDefaults.categories)
            }
        }
        cachedRules = Self.loadRules()
        cachedCategories = Self.loadCategories()
        cachedIdleThreshold = d.double(forKey: ActivityDefaults.idleThreshold)
        enabled = d.bool(forKey: ActivityDefaults.enabled)

        watchDefaults()
        if autostart { startTracking() }
    }

    deinit {
        pollTimer?.cancel()
        if let o = activateObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o) }
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Lifecycle

    func startTracking() {
        installPollTimer()
        watchActivation()
        watchTerminate()
        refreshTrust()
        refreshTodayTotal()
    }

    private func installPollTimer() {
        pollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)   // Common Mistakes law: GCD, never RunLoop Timer
        t.schedule(deadline: .now() + 1.0, repeating: .seconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        pollTimer = t
    }

    private func watchActivation() {
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            // An activation with no input behind it (alerts, programmatic
            // switches) must not open a segment while AFK.
            guard self.enabled, self.idleSeconds < self.cachedIdleThreshold else { return }
            self.transition(to: app)
        }
    }

    private func watchTerminate() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.flush() }
    }

    private func watchDefaults() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reloadCaches() }
    }

    private func reloadCaches() {
        let d = UserDefaults.standard
        cachedRules = Self.loadRules()
        cachedCategories = Self.loadCategories()
        cachedIdleThreshold = d.double(forKey: ActivityDefaults.idleThreshold)
        reclassifyOpenSegment()
    }

    /// Rule edits apply from now on: the open segment closes and reopens if
    /// its category would change, so the day bar reflects edits immediately.
    private func reclassifyOpenSegment() {
        guard let seg = segment else { return }
        let newCategory = seg.category == "Private"
            ? "Private"
            : (overrideCategory ?? classify(app: seg.app, title: seg.title))
        guard newCategory != seg.category else { return }
        let now = Date()
        closeSegment(at: now)
        segment = ActivitySegment(start: now, end: now, app: seg.app,
                                  title: seg.title, category: newCategory)
        currentCategory = newCategory
    }

    // MARK: - Idle (Sashay's hardware-idle approach)

    var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: CGEventType(rawValue: CGEventType.RawValue(0xFFFFFFFF))!)
    }

    /// End-timestamp math for the AFK boundary: the segment ends at the last
    /// real input, clamped to the segment start. The idle gap is never
    /// backfilled — on resume a fresh segment starts at the moment activity
    /// returns.
    static func idleEnd(start: Date, now: Date, idleSeconds: TimeInterval) -> Date {
        max(start, now.addingTimeInterval(-idleSeconds))
    }

    private func goIdle(now: Date) {
        guard !isIdle else { return }
        isIdle = true
        closeSegment(at: Self.idleEnd(start: segment?.start ?? now, now: now,
                                      idleSeconds: idleSeconds))
    }

    // MARK: - Sampling

    func refreshTrust() { trusted = AXIsProcessTrusted() }

    // internal: the test harness drives ticks directly (deterministic, no
    // runloop required).
    func tick(now: Date = Date()) {
        trustTicks += 1
        if trustTicks.isMultiple(of: 15) { trusted = AXIsProcessTrusted() }   // ~every 30s

        if Day.string(for: now) != currentDay {
            currentDay = Day.string(for: now)
            closeSegment(at: now)
        }

        guard enabled else { return }

        let idle = idleSeconds
        if idle >= cachedIdleThreshold {
            goIdle(now: now)
            return
        }
        if isIdle { isIdle = false }   // resume: fresh segment, no backfill

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        transition(to: app, now: now)
        publishTodaySeconds(now: now)
    }

    private func transition(to app: NSRunningApplication, now: Date = Date()) {
        let appID = app.bundleIdentifier ?? app.localizedName ?? "Unknown"
        let appName = app.localizedName ?? appID

        // Sensitive apps: never even read the title.
        let sensitiveApp = Self.isSensitiveApp(appID) || Self.isSensitiveApp(appName)
        var title: String?
        if !sensitiveApp, trusted {
            title = Self.readFrontmostTitle(pid: app.processIdentifier)
        }

        let context = Self.classifyContext(appID: appID, appName: appName,
                                           title: title, override: overrideCategory,
                                           rules: cachedRules)

        currentApp = appName
        currentTitle = context.category == "Private" ? nil : title
        currentCategory = context.category

        // Same app + title + category: keep accruing the open segment.
        if segment?.app == context.app, segment?.title == context.title,
           segment?.category == context.category { return }

        closeSegment(at: now)
        segment = ActivitySegment(start: now, end: now, app: context.app,
                                  title: context.title, category: context.category)
        refreshTodayTotal(now: now)
    }

    /// Decides what gets stored for a frontmost context. Pure — testable
    /// without a real NSRunningApplication.
    static func classifyContext(appID: String, appName: String, title: String?,
                                override: String?, rules: [CategoryRule])
    -> (app: String, title: String, category: String) {
        let sensitiveApp = isSensitiveApp(appID) || isSensitiveApp(appName)
        let redact = sensitiveApp || isSensitivePane(appID: appID, appName: appName, title: title)
        let storedTitle = redact ? "" : (title ?? "")
        let category = redact
            ? "Private"
            : (override ?? classify(app: "\(appName) \(appID)", title: storedTitle, rules: rules))
        return (appID, storedTitle, category)
    }

    /// First matching rule wins; default "Other". Case-insensitive substring
    /// against "appName windowTitle" (bundle id rides along for free).
    static func classify(app: String, title: String, rules: [CategoryRule]) -> String {
        let haystack = "\(app) \(title)".lowercased()
        for rule in rules where !rule.pattern.isEmpty {
            if haystack.contains(rule.pattern.lowercased()) { return rule.categoryName }
        }
        return "Other"
    }

    func classify(app: String, title: String) -> String {
        Self.classify(app: app, title: title, rules: cachedRules)
    }

    /// Name/bundle matchers only — checked BEFORE any AX title read.
    static func isSensitiveApp(_ app: String) -> Bool {
        let lowered = app.lowercased()
        return sensitiveAppMatchers.contains { lowered.contains($0) }
    }

    /// System Settings/Preferences counts as sensitive only on
    /// security-flavored panes. The pane name is read in memory, then dropped.
    static func isSensitivePane(appID: String, appName: String, title: String?) -> Bool {
        let haystack = "\(appID) \(appName)".lowercased()
        guard haystack.contains("systempreferences") || haystack.contains("system settings")
                || haystack.contains("system preferences") else { return false }
        guard let t = title?.lowercased() else { return false }
        return sensitivePaneKeywords.contains { t.contains($0) }
    }

    /// Sensitive-window check with the title available (used after an AX read).
    static func isSensitive(app: String, title: String?) -> Bool {
        isSensitiveApp(app) || isSensitivePane(appID: app, appName: app, title: title)
    }

    /// kAXTitleAttribute of the frontmost app's focused window. Short
    /// messaging timeout so a hung app can't stall the tick.
    static func readFrontmostTitle(pid: pid_t) -> String? {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString,
                                            &windowRef) == .success,
              let window = windowRef else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement,
                                            kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        return title
    }

    // MARK: - Segment management

    private func closeSegment(at end: Date) {
        guard var seg = segment else { return }
        segment = nil
        guard end > seg.start else { return }   // zero-length (fully idle) — dropped
        seg.end = end
        store.append(seg)
        refreshTodayTotal(now: end)
    }

    /// FocusEngine hook: while a session runs, all time logs under the given
    /// category ("Focus"/"Rest") regardless of frontmost app. nil restores
    /// rule-based tracking from now on.
    func setOverride(_ category: String?) {
        guard overrideCategory != category else { return }
        overrideCategory = category
        let now = Date()
        closeSegment(at: now)
        if enabled, let app = NSWorkspace.shared.frontmostApplication {
            transition(to: app, now: now)
        }
    }

    /// Closes the open segment and writes it synchronously — app-quit path.
    func flush() {
        guard var seg = segment else { return }
        segment = nil
        let end = Date()
        guard end > seg.start else { return }
        seg.end = end
        store.flush(seg)
    }

    // MARK: - Rules & categories (panel rules card)

    var rules: [CategoryRule] { cachedRules }
    var categories: [ActivityCategory] { cachedCategories }

    func setRules(_ newRules: [CategoryRule]) {
        if let data = try? JSONEncoder().encode(newRules) {
            UserDefaults.standard.set(data, forKey: ActivityDefaults.rules)
        }
        cachedRules = newRules
    }

    func addRule(pattern: String, categoryName: String) {
        var r = cachedRules
        r.append(CategoryRule(id: UUID(), pattern: pattern, categoryName: categoryName))
        setRules(r)
    }

    func removeRule(id: UUID) {
        setRules(cachedRules.filter { $0.id != id })
    }

    func setCategories(_ newCategories: [ActivityCategory]) {
        if let data = try? JSONEncoder().encode(newCategories) {
            UserDefaults.standard.set(data, forKey: ActivityDefaults.categories)
        }
        cachedCategories = newCategories
    }

    private static func loadRules() -> [CategoryRule] {
        guard let data = UserDefaults.standard.data(forKey: ActivityDefaults.rules),
              let rules = try? JSONDecoder().decode([CategoryRule].self, from: data)
        else { return defaultRules }
        return rules
    }

    private static func loadCategories() -> [ActivityCategory] {
        guard let data = UserDefaults.standard.data(forKey: ActivityDefaults.categories),
              let categories = try? JSONDecoder().decode([ActivityCategory].self, from: data)
        else { return defaultCategories }
        return categories
    }

    // MARK: - Aggregations (panel)

    /// Total tracked seconds today, including the open segment.
    func todayTotal() -> TimeInterval {
        todayTotal(at: Date())
    }

    private func todayTotal(at now: Date) -> TimeInterval {
        var total = store.segments(forDay: Day.string(for: now))
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        if let seg = segment { total += now.timeIntervalSince(seg.start) }
        return total
    }

    /// Today's per-category totals, sorted descending.
    func todayByCategory() -> [(name: String, seconds: TimeInterval)] {
        byCategory(onDay: Day.string(for: Date()), now: Date())
    }

    private func byCategory(onDay day: String, now: Date) -> [(name: String, seconds: TimeInterval)] {
        var acc: [String: TimeInterval] = [:]
        for seg in store.segments(forDay: day) {
            acc[seg.category, default: 0] += seg.end.timeIntervalSince(seg.start)
        }
        if day == currentDay, let seg = segment {
            acc[seg.category, default: 0] += now.timeIntervalSince(seg.start)
        }
        return acc.map { (name: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    /// The last 8 hours in 8 equal one-hour bins, oldest first. Each bin
    /// reports its dominant category and total tracked seconds — the panel's
    /// day strip. Empty bins report ("Other", 0).
    func lastEightHours(now: Date = Date()) -> [(categoryName: String, seconds: TimeInterval)] {
        (1...8).reversed().map { i in
            let bin = DateInterval(start: now.addingTimeInterval(Double(-i) * 3600.0),
                                   end: now.addingTimeInterval(Double(-(i - 1)) * 3600.0))
            let dominant = dominantCategory(in: bin, now: now)
            return (categoryName: dominant.best, seconds: dominant.total)
        }
    }

    private func dominantCategory(in interval: DateInterval, now: Date) -> (best: String, total: TimeInterval) {
        var acc: [String: TimeInterval] = [:]
        for day in Set([Day.string(for: interval.start), Day.string(for: interval.end)]) {
            for seg in store.segments(forDay: day) {
                let overlap = min(seg.end, interval.end).timeIntervalSince(max(seg.start, interval.start))
                if overlap > 0 { acc[seg.category, default: 0] += overlap }
            }
        }
        if let seg = segment {
            let overlap = min(now, interval.end).timeIntervalSince(max(seg.start, interval.start))
            if overlap > 0 { acc[seg.category, default: 0] += overlap }
        }
        let total = acc.values.reduce(0, +)
        let best = acc.sorted { $0.value > $1.value }.first?.key ?? "Other"
        return (best, total)
    }

    /// Totals for the last `n` days including today, oldest first. The panel's
    /// Pro gate (Free = 7 days of history) reads this.
    func historyDays(_ n: Int, now: Date = Date()) -> [(dayString: String, totalSeconds: TimeInterval)] {
        var out: [(dayString: String, totalSeconds: TimeInterval)] = []
        for offset in stride(from: n - 1, through: 0, by: -1) {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            let dayString = Day.string(for: day)
            var total = store.segments(forDay: dayString)
                .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            if offset == 0, let seg = segment {
                total += now.timeIntervalSince(seg.start)
            }
            out.append((dayString: dayString, totalSeconds: total))
        }
        return out
    }

    // MARK: - Hooks for the panel & FocusEngine surfaces

    /// Clean hook for a future daily-summary surface (rendered by the panel —
    /// never a notification).
    func summary(forDay day: String) -> (totalSeconds: TimeInterval,
                                         byCategory: [(name: String, seconds: TimeInterval)]) {
        let total = store.segments(forDay: day)
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        return (total, byCategory(onDay: day, now: Date()))
    }

    /// Apps the tracker saw in `interval`, most-used first — the focus
    /// session's end-of-session "what you actually did" list.
    func apps(in interval: DateInterval) -> [(app: String, seconds: TimeInterval)] {
        var acc: [String: TimeInterval] = [:]
        for day in Set([Day.string(for: interval.start), Day.string(for: interval.end)]) {
            for seg in store.segments(forDay: day) {
                let overlap = min(seg.end, interval.end).timeIntervalSince(max(seg.start, interval.start))
                if overlap > 0 { acc[seg.app, default: 0] += overlap }
            }
        }
        if let seg = segment {
            let overlap = min(Date(), interval.end).timeIntervalSince(max(seg.start, interval.start))
            if overlap > 0 { acc[seg.app, default: 0] += overlap }
        }
        return acc.map { (app: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    // MARK: - Today total plumbing

    private func refreshTodayTotal(now: Date = Date()) {
        closedTodayBase = store.segments(forDay: Day.string(for: now))
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        publishTodaySeconds(now: now)
    }

    private func publishTodaySeconds(now: Date) {
        let open = segment.map { now.timeIntervalSince($0.start) } ?? 0
        todaySeconds = closedTodayBase + max(0, open)
    }
}
