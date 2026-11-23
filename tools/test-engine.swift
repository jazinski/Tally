//
//  test-engine.swift — verification harness for ActivityEngine and
//  FocusEngine: classification, sensitive redaction, day-file store,
//  aggregations, focus state machine, and a live tracking smoke run.
//  Fully headless — no AX trust, no runloop; ticks are driven with
//  synthetic clocks.
//
//  Run:  swiftc -parse-as-library -O \
//          -framework AppKit -framework CoreGraphics -framework ApplicationServices \
//          -o build/enginetest ActivityEngine.swift FocusEngine.swift tools/test-engine.swift
//        ./build/enginetest   (exit 0 = all pass)
//

import AppKit
import Foundation

@main
enum EngineTest {

    static var pass = true

    static func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL") \(name)")
        if !ok { pass = false }
    }

    static func near(_ a: Double, _ b: Double, _ tol: Double = 0.001) -> Bool {
        abs(a - b) <= tol
    }

    static func tmp() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tallyho-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func seg(_ start: Date, dur: TimeInterval, app: String, title: String, cat: String) -> ActivitySegment {
        ActivitySegment(start: start, end: start.addingTimeInterval(dur),
                        app: app, title: title, category: cat)
    }

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static func resetFocusStats() {
        let d = UserDefaults.standard
        d.set(0, forKey: FocusDefaults.statCycles)
        d.set(Day.string(for: Date()), forKey: FocusDefaults.statDay)
    }

    static func main() {
        // Hermetic runs: wipe this binary's persistent defaults domain.
        let domain = Bundle.main.bundleIdentifier
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        UserDefaults.standard.removePersistentDomain(forName: domain)

        classifyTests()
        redactionTests()
        storeTests()
        aggregationTests()
        focusTests()
        liveSmoke()

        print(pass ? "✓ all engine tests passed" : "✗ FAILURES")
        exit(pass ? 0 : 1)
    }

    // MARK: - Classification

    static func classifyTests() {
        let e = ActivityEngine(storeDirectory: tmp(), autostart: false)

        check("xcode → Code", e.classify(app: "Xcode", title: "main.swift — Tally") == "Code")
        check("vs code → Code", e.classify(app: "VS Code", title: "engine.swift") == "Code")
        check("cursor → Code (case-insensitive)", e.classify(app: "CURSOR", title: "") == "Code")
        check("slack → Comms", e.classify(app: "Slack", title: "#general") == "Comms")
        check("messages → Comms", e.classify(app: "Messages", title: "Mom") == "Comms")
        check("mail → Comms", e.classify(app: "Mail", title: "Invoice") == "Comms")
        check("safari → Other", e.classify(app: "Safari", title: "the news") == "Other")
        check("chrome → Other", e.classify(app: "Google Chrome", title: "docs") == "Other")
        check("arc → Other", e.classify(app: "Arc", title: "spaces") == "Other")
        check("figma → Other (design later)", e.classify(app: "Figma", title: "Dashboard") == "Other")
        check("unknown → Other", e.classify(app: "WeirdApp", title: "stuff") == "Other")

        // rules card CRUD + persistence. "Notion" sidesteps every built-in
        // rule — first-match-wins means an appended rule never beats them.
        e.addRule(pattern: "linear", categoryName: "Design")
        check("user rule matches window title", e.classify(app: "Notion", title: "Linear — Eng board") == "Design")
        let stored = UserDefaults.standard.data(forKey: ActivityDefaults.rules)
            .flatMap { try? JSONDecoder().decode([CategoryRule].self, from: $0) } ?? []
        check("rule persisted to defaults", stored.contains { $0.pattern == "linear" && $0.categoryName == "Design" })
        if let added = stored.first(where: { $0.pattern == "linear" }) {
            e.removeRule(id: added.id)
            check("rule removed", !e.rules.contains { $0.pattern == "linear" })
        }

        // first matching rule wins
        e.setRules([
            CategoryRule(id: UUID(), pattern: "code", categoryName: "Other"),
            CategoryRule(id: UUID(), pattern: "xcode", categoryName: "Code"),
        ])
        check("first matching rule wins", e.classify(app: "Xcode", title: "") == "Other")
        e.setRules(ActivityEngine.defaultRules)   // restore for later sections
    }

    // MARK: - Sensitive-window redaction

    static func redactionTests() {
        let rules = ActivityEngine.defaultRules

        let onePw = ActivityEngine.classifyContext(appID: "com.1password.1password", appName: "1Password",
                                                   title: "Vault — Bank", override: nil, rules: rules)
        check("1password → Private, no title", onePw.category == "Private" && onePw.title == "")

        let keychain = ActivityEngine.classifyContext(appID: "com.apple.KeychainAccess", appName: "Keychain Access",
                                                      title: nil, override: nil, rules: rules)
        check("keychain access → Private, no title", keychain.category == "Private" && keychain.title == "")

        let agent = ActivityEngine.classifyContext(appID: "com.apple.SecurityAgent", appName: "SecurityAgent",
                                                   title: "Confirm", override: nil, rules: rules)
        check("securityagent → Private", agent.category == "Private" && agent.title == "")

        let secPane = ActivityEngine.classifyContext(appID: "com.apple.systempreferences", appName: "System Settings",
                                                     title: "Privacy & Security", override: nil, rules: rules)
        check("security pane → Private, no title", secPane.category == "Private" && secPane.title == "")

        let dispPane = ActivityEngine.classifyContext(appID: "com.apple.systempreferences", appName: "System Settings",
                                                      title: "Displays", override: nil, rules: rules)
        check("displays pane not redacted", dispPane.category == "Other" && dispPane.title == "Displays")

        let focusOverride = ActivityEngine.classifyContext(appID: "com.apple.dt.Xcode", appName: "Xcode",
                                                           title: "main.swift", override: "Focus", rules: rules)
        check("focus override beats rules", focusOverride.category == "Focus"
              && focusOverride.title == "main.swift")

        check("isSensitive combined", ActivityEngine.isSensitive(app: "1Password", title: nil))
        check("not sensitive normally", !ActivityEngine.isSensitive(app: "Safari", title: "news"))

        // idle trim math: segment ends at last input, never backfilled
        let t0 = date(2026, 1, 1, 10, 0)
        let now = date(2026, 1, 1, 10, 10)
        check("idle end at last input",
              ActivityEngine.idleEnd(start: t0, now: now, idleSeconds: 300) == date(2026, 1, 1, 10, 5))
        check("idle end clamps to start",
              ActivityEngine.idleEnd(start: t0, now: now, idleSeconds: 1200) == t0)
    }

    // MARK: - Day store

    static func storeTests() {
        let store = DayStore(directory: tmp())

        store.flush(seg(date(2026, 1, 1, 9, 0), dur: 1800, app: "com.apple.dt.Xcode",
                      title: "Tally — ActivityEngine.swift", cat: "Code"))
        let day1 = store.segments(forDay: "2026-01-01")
        check("round trip count", day1.count == 1)
        if let s = day1.first {
            check("round trip fields", s.app == "com.apple.dt.Xcode"
                  && s.title == "Tally — ActivityEngine.swift" && s.category == "Code"
                  && near(s.end.timeIntervalSince(s.start), 1800))
        }

        // append-only: a second entry joins the first
        store.flush(seg(date(2026, 1, 1, 10, 0), dur: 600, app: "com.apple.Safari", title: "", cat: "Other"))
        check("append-only growth", store.segments(forDay: "2026-01-01").count == 2)

        // on-disk shape: {start, end, app, title, category}, ISO8601 dates
        let raw = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: store.fileURL(forDay: "2026-01-01")))) as? [[String: Any]] ?? []
        let entry = raw.first ?? [:]
        let iso = ISO8601DateFormatter()
        check("on-disk keys", Set(entry.keys) == ["start", "end", "app", "title", "category"])
        check("on-disk ISO8601 dates", (entry["start"] as? String).flatMap { iso.date(from: $0) } != nil
              && (entry["end"] as? String).flatMap { iso.date(from: $0) } != nil)

        // midnight split
        store.flush(seg(date(2026, 1, 1, 23, 30), dur: 3600, app: "x", title: "", cat: "Other"))
        let before = store.segments(forDay: "2026-01-01")
        let after = store.segments(forDay: "2026-01-02")
        check("midnight split lands in both day files", before.count == 3 && after.count == 1)
        if let tail = before.last, let head = after.first {
            check("midnight split durations", near(tail.end.timeIntervalSince(tail.start), 1800)
                  && near(head.end.timeIntervalSince(head.start), 1800))
        }

        check("missing day → empty", store.segments(forDay: "1999-01-01").isEmpty)
    }

    // MARK: - Aggregations

    static func aggregationTests() {
        let cal = Calendar.current
        // Day files store whole-second ISO8601 stamps; floor the clock so
        // seeded timestamps round-trip exactly and tolerances stay tight.
        let now = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
        var c = cal.dateComponents([.year, .month, .day], from: now)
        (c.hour, c.minute, c.second) = (9, 0, 0)
        let t0900 = cal.date(from: c)!

        // today's file only
        let dirToday = tmp()
        let storeToday = DayStore(directory: dirToday)
        storeToday.flush(seg(t0900, dur: 1800, app: "com.apple.dt.Xcode", title: "x", cat: "Code"))
        storeToday.flush(seg(t0900.addingTimeInterval(3600), dur: 600, app: "com.slack", title: "", cat: "Comms"))
        storeToday.flush(seg(t0900.addingTimeInterval(7200), dur: 600, app: "x2", title: "", cat: "Code"))
        let eToday = ActivityEngine(storeDirectory: dirToday, autostart: false)

        check("todayTotal", near(eToday.todayTotal(), 3000))
        let byCat = eToday.todayByCategory()
        check("todayByCategory sorted desc", byCat.count == 2 && byCat[0].name == "Code"
              && near(byCat[0].seconds, 2400) && byCat[1].name == "Comms"
              && near(byCat[1].seconds, 600))

        let summary = eToday.summary(forDay: Day.string(for: now))
        check("summary hook", near(summary.totalSeconds, 3000) && summary.byCategory.first?.name == "Code")
        let appsIn = eToday.apps(in: DateInterval(start: t0900, duration: 3600))
        check("apps(in) hook", appsIn.first?.app == "com.apple.dt.Xcode"
              && near(appsIn.first?.seconds ?? 0, 1800))

        // history: separate dir, one seed per day (today gets a short one)
        let dirHist = tmp()
        let storeHist = DayStore(directory: dirHist)
        for (offsetDays, hours) in [(2, 2.0), (1, 1.0)] {
            let day = cal.date(byAdding: .day, value: -offsetDays, to: now)!
            var cc = cal.dateComponents([.year, .month, .day], from: day)
            (cc.hour, cc.minute, cc.second) = (9, 0, 0)
            storeHist.flush(seg(cal.date(from: cc)!, dur: hours * 3600, app: "old", title: "", cat: "Code"))
        }
        storeHist.flush(seg(t0900, dur: 1800, app: "today", title: "", cat: "Code"))
        let eHist = ActivityEngine(storeDirectory: dirHist, autostart: false)
        let h = eHist.historyDays(3)
        check("historyDays count + order", h.count == 3
              && h[0].dayString == Day.string(for: cal.date(byAdding: .day, value: -2, to: now)!)
              && h[2].dayString == Day.string(for: now))
        check("historyDays totals", near(h[0].totalSeconds, 7200) && near(h[1].totalSeconds, 3600)
              && near(h[2].totalSeconds, 1800))

        // last 8 hours: own dir, seeds placed in known bins
        let dir8 = tmp()
        let store8 = DayStore(directory: dir8)
        store8.flush(seg(now.addingTimeInterval(-25200), dur: 1800, app: "xcode", title: "", cat: "Code"))   // bin 1
        store8.flush(seg(now.addingTimeInterval(-4500), dur: 900, app: "xcode2", title: "", cat: "Code"))    // bin 6 [−2h,−1h)
        store8.flush(seg(now.addingTimeInterval(-3500), dur: 1800, app: "slack", title: "", cat: "Comms"))   // bin 7
        let e8 = ActivityEngine(storeDirectory: dir8, autostart: false)
        let bins = e8.lastEightHours(now: now)
        check("8 equal bins", bins.count == 8)
        check("bin 1 dominant Code", bins[1].categoryName == "Code" && near(bins[1].seconds, 1800))
        check("bin 6 dominant Code", bins[6].categoryName == "Code" && near(bins[6].seconds, 900))
        check("bin 7 dominant Comms", bins[7].categoryName == "Comms" && near(bins[7].seconds, 1800))
        check("empty bin reports Other/0", bins[0].categoryName == "Other" && bins[0].seconds == 0)
    }

    // MARK: - Focus engine

    static func focusTests() {
        let d = UserDefaults.standard
        d.set(0.5, forKey: FocusDefaults.focusMinutes)      // 30s
        d.set(0.2, forKey: FocusDefaults.breakMinutes)      // 12s
        d.set(0.3, forKey: FocusDefaults.longBreakMinutes)  // 18s
        d.set(2, forKey: FocusDefaults.longBreakCadence)

        resetFocusStats()
        let activity = ActivityEngine(storeDirectory: tmp(), autostart: false)
        let focus = FocusEngine(activity: activity)

        check("starts idle", focus.phase == .idle && focus.remaining == 0)
        focus.startFocus()
        check("startFocus → focusing", focus.phase == .focusing)
        check("focus duration from settings", near(focus.remaining, 30))
        check("focus overrides tracker category", activity.overrideCategory == "Focus")
        check("sessionStartedAt recorded", focus.sessionStartedAt != nil)

        focus.tick(now: Date().addingTimeInterval(31))
        check("focus complete → short break", focus.phase == .breaking(isLong: false))
        check("break duration from settings", near(focus.remaining, 12))
        check("cycle counted", focus.completedCyclesToday == 1)
        check("cycle persisted", d.integer(forKey: FocusDefaults.statCycles) == 1)
        check("break overrides as Rest", activity.overrideCategory == "Rest")

        focus.tick(now: Date().addingTimeInterval(44))
        check("break complete → idle", focus.phase == .idle && focus.remaining == 0)
        check("override cleared", activity.overrideCategory == nil)

        focus.startFocus()
        focus.tick(now: Date().addingTimeInterval(75))
        check("cadence 2 → long break", focus.phase == .breaking(isLong: true))
        check("long break duration from settings", near(focus.remaining, 18))
        check("two cycles counted", focus.completedCyclesToday == 2)
        focus.stop()
        check("stop → idle, override cleared", focus.phase == .idle && activity.overrideCategory == nil)

        // pause / resume
        resetFocusStats()
        let activity2 = ActivityEngine(storeDirectory: tmp(), autostart: false)
        let focus2 = FocusEngine(activity: activity2)
        focus2.startFocus()
        focus2.pause()
        check("pause holds phase", focus2.paused && focus2.phase == .focusing)
        check("pause releases override", activity2.overrideCategory == nil)
        focus2.resume()
        check("resume restores override", !focus2.paused && activity2.overrideCategory == "Focus")

        // skip: break without counting the cycle
        focus2.skip()
        check("skip → short break, uncounted", focus2.phase == .breaking(isLong: false)
              && focus2.completedCyclesToday == 0)
        focus2.stop()
        check("cyclePosition", focus2.cyclePosition == 0)

        // settings persistence across engines
        focus2.focusMinutes = 7
        check("focusMinutes persisted", near(d.double(forKey: FocusDefaults.focusMinutes), 7))
        let focus3 = FocusEngine(activity: activity2)
        focus3.startFocus()
        check("fresh engine reads setting", near(focus3.remaining, 420))
        focus3.stop()

        // restore ship defaults
        d.set(25.0, forKey: FocusDefaults.focusMinutes)
        d.set(5.0, forKey: FocusDefaults.breakMinutes)
        d.set(15.0, forKey: FocusDefaults.longBreakMinutes)
        d.set(4, forKey: FocusDefaults.longBreakCadence)
    }

    // MARK: - Live smoke (real NSWorkspace, no AX trust required)

    static func liveSmoke() {
        guard NSWorkspace.shared.frontmostApplication != nil else {
            print("SKIP live smoke (no frontmost app in headless context)")
            return
        }
        let e = ActivityEngine(storeDirectory: tmp(), autostart: true)
        e.tick()
        if e.currentApp == nil {
            // System idle beyond the threshold — accrual correctly paused.
            print("SKIP live smoke (system idle — nothing to accrue)")
            return
        }
        check("live: frontmost sampled + classified", e.currentCategory != nil)
        e.enabled = false
        _ = e.todayTotal()   // store queue is serial+sync → pending writes land first
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let data = try? Data(contentsOf: e.daysDirectory
            .appendingPathComponent("\(Day.string(for: Date())).json"))
        let segs = data.flatMap { try? dec.decode([ActivitySegment].self, from: $0) } ?? []
        check("live: segment persisted to today's day file", segs.count >= 1)
        if let s = segs.last {
            check("live: segment fields sane", s.end >= s.start && !s.category.isEmpty && !s.app.isEmpty)
        }
    }
}
