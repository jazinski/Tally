//
//  FocusEngine.swift
//  Tally Ho — pomodoro focus sessions, fused with the tracker.
//
//  A focus session LOGS AS TRACKED TIME tagged "Focus" and mutes the category
//  switcher for its duration; breaks count toward "Rest", never "Other". The
//  timer and the tracker are one product, not two bolted together.
//
//  Integration: FocusEngine drives ActivityEngine.setOverride, so segments
//  opened mid-session carry the session's category. The panel reads
//  sessionStartedAt + ActivityEngine.apps(in:) for the end-of-session
//  "what you actually did during the 25" card.
//
//  GCD DispatchSource timer only (Common Mistakes law). Settings cached,
//  re-read on UserDefaults.didChangeNotification.
//
//  v0.0.1 · Built for client #1.
//

import Combine
import Foundation

// MARK: - Defaults keys

enum FocusDefaults {
    static let focusMinutes     = "focusMinutes"      // Double, minutes
    static let breakMinutes     = "breakMinutes"      // Double, minutes
    static let longBreakMinutes = "longBreakMinutes"  // Double, minutes
    static let longBreakCadence = "longBreakCadence"  // Int, focus sessions per long break
    static let statCycles       = "stats.focusCycles" // Int, completed today
    static let statDay          = "stats.focusDay"    // String "yyyy-MM-dd"
}

// MARK: - Phase

enum FocusPhase: Equatable {
    case idle
    case focusing
    case breaking(isLong: Bool)

    var label: String {
        switch self {
        case .idle:                    return "Idle"
        case .focusing:                return "Focus"
        case .breaking(let isLong):    return isLong ? "Long break" : "Break"
        }
    }
}

// MARK: - Engine

final class FocusEngine: ObservableObject {

    @Published private(set) var phase: FocusPhase = .idle
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var paused = false
    @Published private(set) var completedCyclesToday = 0
    /// When the current focus session started — pairs with
    /// ActivityEngine.apps(in:) for the end-of-session card.
    @Published private(set) var sessionStartedAt: Date?

    private let activity: ActivityEngine
    private var timer: DispatchSourceTimer?
    private var defaultsObserver: Any?
    private var lastTick: Date?
    private var pausedPhase: FocusPhase?

    // Cached settings (no UserDefaults reads in hot loops)
    private var cachedFocusSeconds: TimeInterval
    private var cachedBreakSeconds: TimeInterval
    private var cachedLongBreakSeconds: TimeInterval
    private var cachedLongBreakCadence: Int

    init(activity: ActivityEngine) {
        self.activity = activity
        let d = UserDefaults.standard
        d.register(defaults: [
            FocusDefaults.focusMinutes: 25.0,
            FocusDefaults.breakMinutes: 5.0,
            FocusDefaults.longBreakMinutes: 15.0,
            FocusDefaults.longBreakCadence: 4,
        ])
        cachedFocusSeconds = d.double(forKey: FocusDefaults.focusMinutes) * 60
        cachedBreakSeconds = d.double(forKey: FocusDefaults.breakMinutes) * 60
        cachedLongBreakSeconds = d.double(forKey: FocusDefaults.longBreakMinutes) * 60
        cachedLongBreakCadence = max(1, d.integer(forKey: FocusDefaults.longBreakCadence))

        rollDailyCyclesIfNeeded()
        completedCyclesToday = d.integer(forKey: FocusDefaults.statCycles)

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reloadSettings() }
    }

    deinit {
        timer?.cancel()
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
        if phase != .idle { activity.setOverride(nil) }
    }

    // MARK: - Controls (panel focus card)

    func startFocus() {
        guard phase == .idle else { return }
        beginPhase(.focusing)
    }

    func pause() {
        guard phase != .idle, !paused else { return }
        paused = true
        pausedPhase = phase
        lastTick = nil
        activity.setOverride(nil)   // paused time is regular tracked time
    }

    func resume() {
        guard paused, let restored = pausedPhase else { return }
        paused = false
        pausedPhase = nil
        lastTick = Date()
        activity.setOverride(restored == .focusing ? "Focus" : "Rest")
    }

    /// Skip to whatever comes next. Skipping focus early starts a short
    /// break WITHOUT counting the cycle as completed.
    func skip() {
        guard phase != .idle else { return }
        if phase == .focusing {
            beginPhase(.breaking(isLong: false))
        } else {
            beginPhase(.idle)
        }
    }

    /// Abandon everything — back to idle, nothing counted.
    func stop() {
        beginPhase(.idle)
    }

    // MARK: - Timer (GCD only)

    private func installTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // internal: the test harness drives ticks with synthetic clocks.
    func tick(now: Date = Date()) {
        guard phase != .idle, !paused, let last = lastTick else { return }
        let elapsed = max(0, last.distance(to: now))
        lastTick = now
        remaining -= elapsed
        if remaining <= 0 { phaseComplete() }
    }

    private func phaseComplete() {
        switch phase {
        case .focusing:
            completedCyclesToday += 1
            persistCycles()
            let long = completedCyclesToday.isMultiple(of: max(1, cachedLongBreakCadence))
            beginPhase(.breaking(isLong: long))
        case .breaking:
            beginPhase(.idle)   // session set complete; the panel offers the next start
        case .idle:
            break
        }
    }

    private func beginPhase(_ newPhase: FocusPhase) {
        phase = newPhase
        paused = false
        pausedPhase = nil
        lastTick = newPhase == .idle ? nil : Date()
        switch newPhase {
        case .idle:
            remaining = 0
            sessionStartedAt = nil
            activity.setOverride(nil)
            timer?.cancel()
            timer = nil
        case .focusing:
            remaining = cachedFocusSeconds
            sessionStartedAt = Date()
            activity.setOverride("Focus")
            installTimer()
        case .breaking(let isLong):
            remaining = isLong ? cachedLongBreakSeconds : cachedBreakSeconds
            activity.setOverride("Rest")
            installTimer()
        }
    }

    // MARK: - Settings (panel sliders; cached, persisted)

    var focusMinutes: Double {
        get { cachedFocusSeconds / 60 }
        set {
            UserDefaults.standard.set(newValue, forKey: FocusDefaults.focusMinutes)
            cachedFocusSeconds = newValue * 60
        }
    }

    var breakMinutes: Double {
        get { cachedBreakSeconds / 60 }
        set {
            UserDefaults.standard.set(newValue, forKey: FocusDefaults.breakMinutes)
            cachedBreakSeconds = newValue * 60
        }
    }

    var longBreakMinutes: Double {
        get { cachedLongBreakSeconds / 60 }
        set {
            UserDefaults.standard.set(newValue, forKey: FocusDefaults.longBreakMinutes)
            cachedLongBreakSeconds = newValue * 60
        }
    }

    var longBreakCadence: Int {
        get { cachedLongBreakCadence }
        set {
            let clamped = max(1, newValue)
            UserDefaults.standard.set(clamped, forKey: FocusDefaults.longBreakCadence)
            cachedLongBreakCadence = clamped
        }
    }

    /// Position within the current cycle set — the panel's cycle dots.
    var cyclePosition: Int { completedCyclesToday % max(1, cachedLongBreakCadence) }

    private func reloadSettings() {
        let d = UserDefaults.standard
        cachedFocusSeconds = d.double(forKey: FocusDefaults.focusMinutes) * 60
        cachedBreakSeconds = d.double(forKey: FocusDefaults.breakMinutes) * 60
        cachedLongBreakSeconds = d.double(forKey: FocusDefaults.longBreakMinutes) * 60
        cachedLongBreakCadence = max(1, d.integer(forKey: FocusDefaults.longBreakCadence))
    }

    // MARK: - Daily stats

    private func rollDailyCyclesIfNeeded() {
        let d = UserDefaults.standard
        let today = Day.string(for: Date())
        if d.string(forKey: FocusDefaults.statDay) != today {
            d.set(0, forKey: FocusDefaults.statCycles)
            d.set(today, forKey: FocusDefaults.statDay)
        }
    }

    private func persistCycles() {
        UserDefaults.standard.set(completedCyclesToday, forKey: FocusDefaults.statCycles)
    }
}
