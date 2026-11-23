//
//  Tally.swift
//  Tally — where did your day go — without telling anyone.
//
//  Panel + app shell. Engines live in ActivityEngine.swift (tracking) and
//  FocusEngine.swift (pomodoro); this file only wires them to the chassis:
//  status card, day strip, focus card, rules card, license card, menu-bar
//  status item, and the sidebar Settings window (Direction A chassis from
//  Align — SettingsWindowController/NavButton/PaneScrollView copy verbatim).
//  Local-only, zero network ever.
//
//  Conventions per Sashay/AGENTS.md: 344pt panel, floor-clamped labels,
//  GCD DispatchSource timers (never RunLoop Timer), dark Aqua, mono digits
//  for ticking numbers, flock single-instance guard.
//
//  v0.1.0 · Built for client #1.
//

import AppKit
import Combine
import Sparkle

// MARK: - Brand

enum Theme {
    static let accent   = NSColor(red: 1.0, green: 0.58, blue: 0.10, alpha: 1)
    static let wordmark = "Tally"
    static let tagline  = "Where did your day go?"
    static let version  = "v0.1.0"
}

// MARK: - Category colors (engine stores system-color hints as strings)

enum CategoryColor {
    private static let map: [String: NSColor] = [
        "systemRed": .systemRed, "systemGreen": .systemGreen,
        "systemBlue": .systemBlue, "systemOrange": .systemOrange,
        "systemPurple": .systemPurple, "systemPink": .systemPink,
        "systemTeal": .systemTeal, "systemIndigo": .systemIndigo,
        "systemBrown": .systemBrown, "systemYellow": .systemYellow,
        "systemGray": .systemGray,
    ]

    static func resolve(hint: String?) -> NSColor { map[hint ?? ""] ?? .systemGray }
}

// MARK: - Day strip

/// Last 8 hours: 8 equal cells, fill height = tracked fraction of the hour,
/// fill color = dominant category color. Oldest bin on the left.
final class DayBarView: NSView {
    var bins: [(categoryName: String, seconds: TimeInterval)] = [] {
        didSet { needsDisplay = true }
    }
    var colorForCategory: (String) -> NSColor = { _ in .systemGray }

    override func draw(_ dirtyRect: NSRect) {
        guard bins.count == 8, bounds.width > 16 else { return }
        let gap: CGFloat = 2
        let w = (bounds.width - 7 * gap) / 8
        for (i, bin) in bins.enumerated() {
            let x = CGFloat(i) * (w + gap)
            let cell = NSRect(x: x, y: 0, width: w, height: bounds.height)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: cell, xRadius: 2, yRadius: 2).fill()
            let fraction = CGFloat(min(1, bin.seconds / 3600))
            guard fraction > 0 else { continue }
            let fillHeight = max(2, cell.height * fraction)
            colorForCategory(bin.categoryName).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: w, height: fillHeight),
                         xRadius: 2, yRadius: 2).fill()
        }
    }
}

// MARK: - Panel

final class PanelController: NSViewController {

    private let activity: ActivityEngine
    private let focus: FocusEngine
    private let updater: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()
    private var uiTimer: DispatchSourceTimer?
    private var lastPhase: FocusPhase = .idle
    private var lastSessionApps: [(app: String, seconds: TimeInterval)] = []
    private var lastTrusted = true
    private var categoryColorCache: [String: NSColor] = [:]

    // Outlets (built in loadView)
    private var statusLabel: NSTextField!
    private var totalLabel: NSTextField!
    private var currentLabel: NSTextField!
    private var trustRow: NSView!
    private var topRows: [(row: NSStackView, dot: NSView, name: NSTextField, time: NSTextField)] = []
    private var dayBar: DayBarView!
    private var phaseBadge: NSTextField!
    private var remainingLabel: NSTextField!
    private var dotsStack: NSStackView!
    private var startButton: NSButton!
    private var pauseButton: NSButton!
    private var skipButton: NSButton!
    private var stopButton: NSButton!
    private var focusSlider: NSSlider!
    private var breakSlider: NSSlider!
    private var longBreakSlider: NSSlider!
    private var cadenceSlider: NSSlider!
    private var focusValueLabel: NSTextField!
    private var breakValueLabel: NSTextField!
    private var longBreakValueLabel: NSTextField!
    private var cadenceValueLabel: NSTextField!
    private var sessionCard: NSView!
    private var sessionRows: [(row: NSStackView, name: NSTextField, time: NSTextField)] = []
    private var rulesList: NSStackView!
    private var ruleField: NSTextField!
    private var categoryPopup: NSPopUpButton!
    private var licenseStack: NSStackView!
    private var keyField: NSTextField!
    private var licenseError: NSTextField!

    init(activity: ActivityEngine, focus: FocusEngine, updater: SPUStandardUpdaterController) {
        self.activity = activity
        self.focus = focus
        self.updater = updater
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("nope") }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let container = NSView()
        container.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view = container
        view.appearance = NSAppearance(named: .darkAqua)

        root.addArrangedSubview(headerRow())
        root.addArrangedSubview(statusCard())
        root.addArrangedSubview(dayBarCard())
        root.addArrangedSubview(focusCard())
        sessionCard = buildSessionCard()
        root.addArrangedSubview(sessionCard)
        root.addArrangedSubview(rulesCard())
        root.addArrangedSubview(licenseCard())
        root.addArrangedSubview(separator())
        root.addArrangedSubview(footerRow())

        let inset = root.edgeInsets.left + root.edgeInsets.right
        for row in root.arrangedSubviews {
            row.setContentHuggingPriority(.init(249), for: .horizontal)
            row.setContentCompressionResistancePriority(.init(499), for: .horizontal)
            row.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -inset).isActive = true
        }

        bind()
        refreshPanel()
        preferredContentSize = NSSize(width: 344, height: view.fittingSize.height)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        activity.refreshTrust()
        refreshPanel()
        startUITimer()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopUITimer()
    }

    deinit {
        uiTimer?.cancel()
    }

    // MARK: - Header

    private func headerRow() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "chart.bar",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        let title = label(Theme.wordmark, 15)
        title.font = roundedFont(15, .heavy)
        let tag = label(Theme.tagline, 11, color: .secondaryLabelColor)
        let titles = NSStackView(views: [title, tag])
        titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 2
        let ver = label(Theme.version, 11, weight: .semibold, color: .secondaryLabelColor, mono: true)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        return NSStackView(views: [icon, titles, spacer, ver])
    }

    // MARK: - Status card

    private func statusCard() -> NSView {
        // Track-activity switch
        let swTitle = label("Track activity", 12)
        let sw = NSSwitch()
        sw.state = activity.enabled ? .on : .off
        sw.target = self
        sw.action = #selector(toggleTracking(_:))
        sw.setAccessibilityLabel("Track activity")
        let swSpacer = NSView()
        swSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let switchRow = NSStackView(views: [swTitle, swSpacer, sw])
        switchRow.spacing = 8

        // Status line + today total (mono, ticks live)
        statusLabel = label("Tracking", 13)
        statusLabel.font = roundedFont(13, .semibold)
        totalLabel = label("0m", 15, weight: .semibold, mono: true)
        let todayCap = label("today", 11, color: .secondaryLabelColor)
        let stSpacer = NSView()
        stSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let statusRow = NSStackView(views: [statusLabel, stSpacer, totalLabel, todayCap])
        statusRow.spacing = 4

        currentLabel = label("Nothing tracked yet", 12, color: .secondaryLabelColor)

        // Accessibility trust warning
        let warn = label("Grant Accessibility to see window titles", 12, color: .systemYellow)
        warn.lineBreakMode = .byTruncatingTail
        warn.setContentHuggingPriority(.init(1), for: .horizontal)
        let grant = NSButton(title: "Grant", target: self, action: #selector(grantAccess))
        grant.bezelStyle = .rounded
        grant.setAccessibilityLabel("Grant Accessibility access")
        trustRow = NSStackView(views: [warn, grant])
        (trustRow as? NSStackView)?.spacing = 8
        trustRow.isHidden = activity.trusted

        // Top 3 categories today
        var views: [NSView] = [switchRow, statusRow, currentLabel, trustRow]
        for _ in 0..<3 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            let name = label("", 12)
            let time = label("", 12, color: .secondaryLabelColor, mono: true)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [dot, name, spacer, time])
            row.spacing = 8
            row.isHidden = true
            views.append(row)
            topRows.append((row: row, dot: dot, name: name, time: time))
        }
        return cardView(views)
    }

    // MARK: - Day bar card

    private func dayBarCard() -> NSView {
        let title = label("Last 8 hours", 12, weight: .semibold, color: .secondaryLabelColor)
        dayBar = DayBarView()
        dayBar.colorForCategory = { [weak self] name in self?.color(for: name) ?? .systemGray }
        dayBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        dayBar.setAccessibilityElement(true)
        let capAgo = label("8h ago", 11, color: .secondaryLabelColor)
        let capNow = label("now", 11, color: .secondaryLabelColor)
        let capSpacer = NSView()
        capSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let caption = NSStackView(views: [capAgo, capSpacer, capNow])
        caption.spacing = 4
        return cardView([title, dayBar, caption])
    }

    // MARK: - Focus card

    private func focusCard() -> NSView {
        let title = label("Focus sessions", 12, weight: .semibold, color: .secondaryLabelColor)
        phaseBadge = label("Idle", 11, weight: .semibold, color: .secondaryLabelColor)
        let headSpacer = NSView()
        headSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [title, headSpacer, phaseBadge])

        remainingLabel = label("25:00", 15, weight: .semibold, mono: true)
        dotsStack = NSStackView()
        dotsStack.orientation = .horizontal
        dotsStack.spacing = 4
        dotsStack.setAccessibilityElement(true)
        let dotsSpacer = NSView()
        dotsSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let timerRow = NSStackView(views: [remainingLabel, dotsSpacer, dotsStack])

        startButton = NSButton(title: "Start Focus", target: self, action: #selector(startFocus))
        pauseButton = NSButton(title: "Pause", target: self, action: #selector(togglePause))
        skipButton = NSButton(title: "Skip", target: self, action: #selector(skipPhase))
        stopButton = NSButton(title: "Stop", target: self, action: #selector(stopFocus))
        for b in [startButton!, pauseButton!, skipButton!, stopButton!] {
            b.bezelStyle = .rounded
            b.controlSize = .regular
        }
        startButton.setAccessibilityLabel("Start focus session")
        skipButton.setAccessibilityLabel("Skip to next phase")
        stopButton.setAccessibilityLabel("Stop session")
        let buttons = NSStackView(views: [startButton, pauseButton, skipButton, stopButton])
        buttons.spacing = 8

        let focusRow = makeSliderRow(title: "Focus", min: 5, max: 60,
                                     value: focus.focusMinutes, action: #selector(focusSliderChanged(_:)))
        focusSlider = focusRow.slider; focusValueLabel = focusRow.valueLabel
        let breakRow = makeSliderRow(title: "Break", min: 1, max: 15,
                                     value: focus.breakMinutes, action: #selector(breakSliderChanged(_:)))
        breakSlider = breakRow.slider; breakValueLabel = breakRow.valueLabel
        let longRow = makeSliderRow(title: "Long break", min: 5, max: 30,
                                    value: focus.longBreakMinutes, action: #selector(longBreakSliderChanged(_:)))
        longBreakSlider = longRow.slider; longBreakValueLabel = longRow.valueLabel
        let cadenceRow = makeSliderRow(title: "Cadence", min: 2, max: 6,
                                       value: Double(focus.longBreakCadence), action: #selector(cadenceSliderChanged(_:)))
        cadenceSlider = cadenceRow.slider; cadenceValueLabel = cadenceRow.valueLabel
        syncSliderLabels()

        return cardView([head, timerRow, buttons, focusRow.row, breakRow.row,
                         longRow.row, cadenceRow.row])
    }

    private func makeSliderRow(title: String, min: Double, max: Double,
                               value: Double, action: Selector)
    -> (row: NSView, slider: NSSlider, valueLabel: NSTextField) {
        let t = label(title, 12)
        t.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        s.isContinuous = true
        s.setAccessibilityLabel(title)
        s.setContentHuggingPriority(.init(1), for: .horizontal)
        let v = label("", 12, weight: .semibold, mono: true)
        v.alignment = .right
        v.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let row = NSStackView(views: [t, s, v])
        row.spacing = 8
        return (row, s, v)
    }

    private func syncSliderLabels() {
        focusValueLabel?.stringValue = "\(Int(focus.focusMinutes)) min"
        breakValueLabel?.stringValue = "\(Int(focus.breakMinutes)) min"
        longBreakValueLabel?.stringValue = "\(Int(focus.longBreakMinutes)) min"
        cadenceValueLabel?.stringValue = "every \(focus.longBreakCadence)"
    }

    // MARK: - End-of-session card ("what you actually did")

    private func buildSessionCard() -> NSView {
        let title = label("During focus", 12, weight: .semibold, color: .secondaryLabelColor)
        var views: [NSView] = [title]
        for _ in 0..<3 {
            let name = label("", 12)
            let time = label("", 12, color: .secondaryLabelColor, mono: true)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [name, spacer, time])
            row.spacing = 8
            row.isHidden = true
            views.append(row)
            sessionRows.append((row: row, name: name, time: time))
        }
        let card = cardView(views)
        card.isHidden = true
        return card
    }

    private func updateSessionCard() {
        sessionCard.isHidden = lastSessionApps.isEmpty
        for (i, r) in sessionRows.enumerated() {
            r.row.isHidden = i >= lastSessionApps.count
            if i < lastSessionApps.count {
                r.name.stringValue = lastSessionApps[i].app
                r.time.stringValue = formatTotal(lastSessionApps[i].seconds)
            }
        }
        syncHeight()
    }

    // MARK: - Rules card

    private func rulesCard() -> NSView {
        let title = label("Category rules", 12, weight: .semibold, color: .secondaryLabelColor)

        rulesList = NSStackView()
        rulesList.orientation = .vertical
        rulesList.alignment = .leading
        rulesList.spacing = 4
        rebuildRules()

        ruleField = NSTextField()
        ruleField.placeholderString = "e.g. figma"
        ruleField.font = .systemFont(ofSize: 12)
        ruleField.bezelStyle = .roundedBezel
        ruleField.target = self
        ruleField.action = #selector(addRule(_:))
        ruleField.setContentHuggingPriority(.init(1), for: .horizontal)
        ruleField.setAccessibilityLabel("Rule pattern")

        categoryPopup = NSPopUpButton()
        categoryPopup.addItems(withTitles: activity.categories.map { $0.name })
        categoryPopup.setAccessibilityLabel("Category")

        let add = NSButton(title: "Add", target: self, action: #selector(addRule(_:)))
        add.bezelStyle = .rounded
        let addRow = NSStackView(views: [ruleField, categoryPopup, add])
        addRow.spacing = 8

        return cardView([title, rulesList, addRow])
    }

    private func rebuildRules() {
        guard rulesList != nil else { return }
        rulesList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for rule in activity.rules {
            let pattern = label(rule.pattern, 12)
            pattern.lineBreakMode = .byTruncatingMiddle
            let category = label(rule.categoryName, 12, color: .secondaryLabelColor)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let remove = smallToolButton(symbol: "xmark",
                                         accLabel: "Remove rule \(rule.pattern)",
                                         action: #selector(removeRule(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(rawValue: rule.id.uuidString)
            let row = NSStackView(views: [pattern, spacer, category, remove])
            row.spacing = 8
            rulesList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rulesList.widthAnchor).isActive = true
        }
    }

    // MARK: - License card

    private func licenseCard() -> NSView {
        licenseStack = NSStackView()
        licenseStack.orientation = .vertical
        licenseStack.alignment = .leading
        licenseStack.spacing = 8
        updateLicenseCard()
        let card = cardView([licenseStack])
        return card
    }

    private func updateLicenseCard() {
        guard licenseStack != nil else { return }
        licenseStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let title = label("License", 12, weight: .semibold, color: .secondaryLabelColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        if LicenseManager.shared.isPro, let lic = LicenseManager.shared.license {
            let head = NSStackView(views: [title, spacer, chip("Pro", a11y: "Pro licensed")])
            head.spacing = 8
            licenseStack.addArrangedSubview(head)
            let line = label("Pro — unlimited history. \(lic.email)", 12, color: .secondaryLabelColor)
            licenseStack.addArrangedSubview(line)
            let deactivate = linkButton("Deactivate", #selector(deactivateLicense))
            let deactSpacer = NSView()
            deactSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let deactRow = NSStackView(views: [deactSpacer, deactivate])
            licenseStack.addArrangedSubview(deactRow)
        } else {
            let head = NSStackView(views: [title, spacer, chip("Free", a11y: "Free plan")])
            head.spacing = 8
            licenseStack.addArrangedSubview(head)
            let line = label("Free — 7 days of history.", 12, color: .secondaryLabelColor)
            licenseStack.addArrangedSubview(line)
            let buy = linkButton("Buy Pro — $9.99", #selector(buyPro))
            buy.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
            licenseStack.addArrangedSubview(buy)

            keyField = NSTextField()
            keyField.placeholderString = "License key"
            keyField.font = .systemFont(ofSize: 12)
            keyField.bezelStyle = .roundedBezel
            keyField.target = self
            keyField.action = #selector(activateLicense(_:))
            keyField.setContentHuggingPriority(.init(1), for: .horizontal)
            keyField.setAccessibilityLabel("License key")
            let activate = NSButton(title: "Activate", target: self, action: #selector(activateLicense(_:)))
            activate.bezelStyle = .rounded
            let keyRow = NSStackView(views: [keyField, activate])
            keyRow.spacing = 8
            licenseStack.addArrangedSubview(keyRow)

            licenseError = label("", 11, color: .systemRed)
            licenseStack.addArrangedSubview(licenseError)
        }
        for row in licenseStack.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: licenseStack.widthAnchor).isActive = true
        }
    }

    private func chip(_ text: String, a11y: String) -> NSView {
        let l = label(text, 11, weight: .semibold, color: Theme.accent)
        let box = NSView()
        box.wantsLayer = true
        box.layer?.borderColor = Theme.accent.cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 4
        box.addSubview(l)
        l.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            l.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
        ])
        box.setAccessibilityElement(true)
        box.setAccessibilityLabel(a11y)
        return box
    }

    // MARK: - Footer

    private func footerRow() -> NSView {
        let privacy = label("Local-only, zero telemetry.", 11, color: .secondaryLabelColor)
        let settings = linkButton("Settings ⌘,", #selector(openSettings))
        let updates = linkButton("Updates", #selector(checkForUpdatesTapped))
        let quit = linkButton("Quit", #selector(quitApp))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [privacy, spacer, settings, updates, quit])
        row.spacing = 8
        return row
    }

    private func linkButton(_ title: String, _ action: Selector) -> LinkButton {
        let b = LinkButton(title: title, target: self, action: action)
        b.bezelStyle = .inline
        b.font = .systemFont(ofSize: 11)
        b.controlSize = .small
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        return b
    }

    private func smallToolButton(symbol: String, accLabel: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accLabel) ?? NSImage()
        let b = NSButton(image: image, target: self, action: action)
        b.isBordered = false
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = .secondaryLabelColor
        b.setAccessibilityLabel(accLabel)
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    // MARK: - Bindings

    private func bind() {
        focus.$phase
            .sink { [weak self] phase in self?.handlePhaseChange(phase) }
            .store(in: &cancellables)
        focus.$paused
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateFocusControls() }
            .store(in: &cancellables)
        focus.$remaining
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.focus.phase != .idle else { return }
                self.remainingLabel.stringValue = formatClock(self.focus.remaining)
            }
            .store(in: &cancellables)
        activity.$trusted
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPanel() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .licenseChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateLicenseCard()
                self?.syncHeight()
            }
            .store(in: &cancellables)
    }

    private func handlePhaseChange(_ phase: FocusPhase) {
        defer { lastPhase = phase }
        guard isViewLoaded else { return }
        if phase == .focusing {
            lastSessionApps = []
            updateSessionCard()
            announce("Focus session started")
        }
        if case .breaking = phase, lastPhase == .focusing {
            if let start = focus.sessionStartedAt {
                lastSessionApps = Array(activity.apps(in: DateInterval(start: start, end: Date())).prefix(3))
                updateSessionCard()
            }
            announce("Focus complete — break started")
        }
        updateFocusControls()
    }

    // MARK: - 1s UI refresh (popover open only)

    private func startUITimer() {
        stopUITimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.2, repeating: .seconds(1))
        t.setEventHandler { [weak self] in self?.refreshPanel() }
        t.resume()
        uiTimer = t
    }

    private func stopUITimer() {
        uiTimer?.cancel()
        uiTimer = nil
    }

    // MARK: - Refresh

    private func refreshPanel() {
        guard isViewLoaded else { return }

        totalLabel.stringValue = formatTotal(activity.todayTotal())

        if !activity.enabled {
            statusLabel.stringValue = "Paused"
            statusLabel.textColor = .secondaryLabelColor
            currentLabel.stringValue = "Tracking off"
        } else if activity.isIdle {
            statusLabel.stringValue = "Idle"
            statusLabel.textColor = .secondaryLabelColor
            currentLabel.stringValue = "Away — not tracking"
        } else {
            statusLabel.stringValue = "Tracking"
            statusLabel.textColor = .systemGreen
            let app = activity.currentApp ?? "Nothing tracked yet"
            let category = activity.currentCategory.map { " — \($0)" } ?? ""
            currentLabel.stringValue = app + category
        }

        let trusted = activity.trusted
        trustRow.isHidden = trusted
        if trusted != lastTrusted {
            lastTrusted = trusted
            syncHeight()
        }

        let cats = Array(activity.todayByCategory().prefix(3))
        for (i, r) in topRows.enumerated() {
            r.row.isHidden = i >= cats.count
            if i < cats.count {
                r.name.stringValue = cats[i].name
                r.time.stringValue = formatTotal(cats[i].seconds)
                r.dot.layer?.backgroundColor = color(for: cats[i].name).cgColor
            }
        }

        dayBar.bins = activity.lastEightHours()
        let tracked = dayBar.bins.reduce(0) { $0 + $1.seconds }
        let top = dayBar.bins.max { $0.seconds < $1.seconds }
        var summary = "Last 8 hours: \(formatTotal(tracked)) tracked"
        if let top, top.seconds > 0 { summary += ", mostly \(top.categoryName)" }
        dayBar.setAccessibilityLabel(summary)

        updateFocusControls()
    }

    private func updateFocusControls() {
        guard isViewLoaded else { return }
        let phase = focus.phase
        let paused = focus.paused

        phaseBadge.stringValue = phase.label
        phaseBadge.textColor = phase == .idle ? .secondaryLabelColor : .systemGreen

        if phase == .idle {
            remainingLabel.stringValue = formatClock(focus.focusMinutes * 60)
            remainingLabel.textColor = .secondaryLabelColor
        } else {
            remainingLabel.stringValue = formatClock(focus.remaining)
            remainingLabel.textColor = paused ? .systemYellow : .labelColor
        }

        startButton.isHidden = phase != .idle
        pauseButton.isHidden = phase == .idle
        skipButton.isHidden = phase == .idle
        stopButton.isHidden = phase == .idle
        pauseButton.title = paused ? "Resume" : "Pause"
        pauseButton.setAccessibilityLabel(paused ? "Resume focus session" : "Pause focus session")

        rebuildDots()
    }

    private func rebuildDots() {
        dotsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let cadence = focus.longBreakCadence
        let position = focus.cyclePosition
        for i in 0..<cadence {
            let d = NSView()
            d.wantsLayer = true
            d.layer?.backgroundColor = (i < position ? Theme.accent : NSColor.quaternaryLabelColor).cgColor
            d.layer?.cornerRadius = 3
            d.widthAnchor.constraint(equalToConstant: 6).isActive = true
            d.heightAnchor.constraint(equalToConstant: 6).isActive = true
            dotsStack.addArrangedSubview(d)
        }
        dotsStack.setAccessibilityLabel("Focus cycle \(position) of \(cadence)")
    }

    private func color(for category: String) -> NSColor {
        if let cached = categoryColorCache[category] { return cached }
        let hint = activity.categories.first { $0.name == category }?.colorHint
            ?? ActivityEngine.defaultCategories.first { $0.name == category }?.colorHint
        let c = CategoryColor.resolve(hint: hint)
        categoryColorCache[category] = c
        return c
    }

    private func syncHeight() {
        guard isViewLoaded else { return }
        preferredContentSize = NSSize(width: 344, height: view.fittingSize.height)
    }

    private func announce(_ text: String) {
        guard isViewLoaded else { return }
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: text])
    }

    // MARK: - Actions

    @objc private func toggleTracking(_ sw: NSSwitch) {
        let on = sw.state == .on
        activity.enabled = on
        announce(on ? "Tracking resumed" : "Tracking paused")
        refreshPanel()
    }

    @objc private func grantAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func startFocus() { focus.startFocus() }

    @objc private func togglePause() {
        if focus.paused { focus.resume() } else { focus.pause() }
        updateFocusControls()
    }

    @objc private func skipPhase() { focus.skip() }

    @objc private func stopFocus() { focus.stop() }

    @objc private func focusSliderChanged(_ s: NSSlider) {
        focus.focusMinutes = s.doubleValue.rounded()
        focusValueLabel.stringValue = "\(Int(focus.focusMinutes)) min"
        if focus.phase == .idle { updateFocusControls() }
    }

    @objc private func breakSliderChanged(_ s: NSSlider) {
        focus.breakMinutes = s.doubleValue.rounded()
        breakValueLabel.stringValue = "\(Int(focus.breakMinutes)) min"
    }

    @objc private func longBreakSliderChanged(_ s: NSSlider) {
        focus.longBreakMinutes = s.doubleValue.rounded()
        longBreakValueLabel.stringValue = "\(Int(focus.longBreakMinutes)) min"
    }

    @objc private func cadenceSliderChanged(_ s: NSSlider) {
        focus.longBreakCadence = Int(s.doubleValue.rounded())
        cadenceValueLabel.stringValue = "every \(focus.longBreakCadence)"
        rebuildDots()
    }

    @objc private func addRule(_ sender: Any?) {
        let pattern = ruleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            announce("Enter a pattern first")
            return
        }
        let category = categoryPopup.titleOfSelectedItem ?? "Other"
        activity.addRule(pattern: pattern, categoryName: category)
        ruleField.stringValue = ""
        rebuildRules()
        syncHeight()
        announce("Rule added")
    }

    @objc private func removeRule(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue, let id = UUID(uuidString: idString) else { return }
        activity.removeRule(id: id)
        rebuildRules()
        syncHeight()
        announce("Rule removed")
    }

    @objc private func buyPro() {
        if let url = URL(string: "https://buy.stripe.com/9B6cMY0Tnf3ygn8dCR4Vy01") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func activateLicense(_ sender: Any?) {
        if LicenseManager.shared.activate(keyField.stringValue) {
            announce("Pro activated")
        } else {
            licenseError.stringValue = "Invalid license key"
            announce("Invalid license key")
            return
        }
        updateLicenseCard()
        syncHeight()
    }

    @objc private func deactivateLicense() {
        LicenseManager.shared.deactivate()
    }

    @objc private func openSettings() {
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }

    @objc private func checkForUpdatesTapped() { updater.checkForUpdates(nil) }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

// MARK: - Helpers

private func label(_ text: String, _ size: CGFloat = 12, floor: CGFloat = 11,
                   weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
    let clamped = max(size, floor)
    let f: NSFont = mono
        ? .monospacedDigitSystemFont(ofSize: clamped, weight: weight)
        : .systemFont(ofSize: clamped, weight: weight)
    let t = NSTextField(labelWithString: text)
    t.font = f
    t.textColor = color
    return t
}

private func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let desc = base.fontDescriptor.withDesign(.rounded),
       let f = NSFont(descriptor: desc, size: 0) { return f }
    return base
}

private func cardView(_ subviews: [NSView]) -> NSView {
    let stack = NSStackView(views: subviews)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    for s in stack.arrangedSubviews {
        s.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    let box = NSView()
    box.wantsLayer = true
    box.layer?.cornerRadius = 10
    box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    box.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
        stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
        stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
        stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
    ])
    return box
}

private func separator() -> NSView {
    let box = NSBox()
    box.boxType = .separator
    return box
}

private func formatTotal(_ t: TimeInterval) -> String {
    let m = Int(t / 60)
    if m >= 60 { return "\(m / 60)h \(m % 60)m" }
    return "\(m)m"
}

private func formatClock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
}

final class LinkButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Launch at Login (LaunchAgent)

enum LoginItem {
    private static let label = "com.jazinski.tally"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ on: Bool) {
        if on {
            let exe = URL(fileURLWithPath: CommandLine.arguments[0])
                .resolvingSymlinksInPath().path
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(label)</string>
                <key>ProgramArguments</key>
            <array><string>\(exe)</string></array>
                <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            try? FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
            runLaunchctl("load", plistURL.path)
        } else {
            runLaunchctl("unload", plistURL.path)
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func runLaunchctl(_ args: String...) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - Settings window (Direction A — sidebar chassis from Align)

/// Rectangle/System-Settings-style window: 200pt source-list sidebar left,
/// grouped cards right. Portfolio chassis — SettingsWindowController,
/// NavButton and PaneScrollView copy into any app with no dependencies
/// beyond AppKit (Sparkle only feeds the update row). Owned by AppDelegate;
/// torn down on close so every open rebuilds fresh.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    enum Section: Int, CaseIterable {
        case general, tracking, focus, license, about

        var title: String {
            switch self {
            case .general: return "General"
            case .tracking: return "Tracking"
            case .focus: return "Focus"
            case .license: return "License"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .tracking: return "chart.bar"
            case .focus: return "timer"
            case .license: return "lock"
            case .about: return "info.circle"
            }
        }

        var isNew: Bool { false }
    }

    private let activity: ActivityEngine
    private let focus: FocusEngine
    private let updater: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()
    private var navButtons: [NavButton] = []
    private var paneScroll: PaneScrollView!
    private var section = Section.general
    private var trackingSwitch: NSSwitch?
    private var stepperRows: [(stepper: NSStepper, readout: NSTextField,
                               format: (Int) -> String)] = []
    private var licenseKeyField: NSTextField?
    private var licenseError: NSTextField?

    /// The owner nils its reference here so controller and window deallocate
    /// once close() has unwound — that IS the rebuild-fresh-on-open behavior.
    var onTeardown: (() -> Void)?

    init(activity: ActivityEngine, focus: FocusEngine,
         updater: SPUStandardUpdaterController) {
        self.activity = activity
        self.focus = focus
        self.updater = updater
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Tally Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        // ARC plus the strong owner make isReleasedWhenClosed an over-release;
        // deferred teardown (windowWillClose) delivers the same lifecycle.
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = buildRoot()
        select(.general)
        wireState()
    }

    required init?(coder: NSCoder) { fatalError("nope") }

    // MARK: Chassis

    private func buildRoot() -> NSView {
        let root = NSView()
        root.appearance = NSAppearance(named: .darkAqua)

        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        root.addSubview(sidebar)

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        root.addSubview(hairline)

        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 4
        nav.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        sidebar.addSubview(nav)

        for section in Section.allCases {
            let button = NavButton(section: section,
                                   target: self, action: #selector(navTapped(_:)))
            navButtons.append(button)
            nav.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true
        }

        paneScroll = PaneScrollView()
        paneScroll.hasVerticalScroller = true
        paneScroll.scrollerStyle = .overlay
        paneScroll.borderType = .noBorder
        paneScroll.drawsBackground = false
        paneScroll.contentView.drawsBackground = false
        root.addSubview(paneScroll)

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        hairline.translatesAutoresizingMaskIntoConstraints = false
        nav.translatesAutoresizingMaskIntoConstraints = false
        paneScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            hairline.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: root.topAnchor),
            hairline.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),
            paneScroll.leadingAnchor.constraint(equalTo: hairline.trailingAnchor),
            paneScroll.topAnchor.constraint(equalTo: root.topAnchor),
            paneScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            paneScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            nav.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
        ])
        return root
    }

    private func select(_ section: Section) {
        self.section = section
        for button in navButtons { button.isActive = button.section == section }
        rebuildPane()
    }

    private func rebuildPane() {
        stepperRows.removeAll()
        trackingSwitch = nil
        licenseKeyField = nil
        licenseError = nil

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: section.title)
        heading.attributedStringValue = NSAttributedString(
            string: "   \(section.title)",
            attributes: [.font: NSFont.systemFont(ofSize: 19, weight: .bold),
                         .kern: -0.4,
                         .foregroundColor: NSColor.labelColor])

        let stack = NSStackView(views: [heading] + sectionGroups())
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor,
                                          constant: -20),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
        ])
        for group in stack.arrangedSubviews.dropFirst() {
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        paneScroll.documentView = document
        document.widthAnchor.constraint(
            equalTo: paneScroll.contentView.widthAnchor).isActive = true
        document.heightAnchor.constraint(
            greaterThanOrEqualTo: paneScroll.contentView.heightAnchor).isActive = true
        paneScroll.contentView.scroll(to: .zero)
    }

    private func sectionGroups() -> [NSView] {
        switch section {
        case .general: return buildGeneral()
        case .tracking: return buildTracking()
        case .focus: return buildFocus()
        case .license: return buildLicense()
        case .about: return buildAbout()
        }
    }

    // MARK: Row builders (portfolio settings chassis)

    /// Grouped card: cornerRadius 10, semantic fill, hairline between rows.
    private func cardGroup(_ rows: [NSView]) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        for (index, row) in rows.enumerated() {
            if index > 0 { addHairline(to: stack) }
            addRow(row, to: stack)
        }
        return box
    }

    private func addRow(_ row: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addHairline(to stack: NSStackView) {
        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.separatorColor.cgColor
        stack.addArrangedSubview(hairline)
        hairline.heightAnchor.constraint(equalToConstant: 1).isActive = true
        hairline.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// Label column + trailing control on the mockup's grouped 12pt row.
    /// Text yields horizontally (compression 499) so the chassis width pins
    /// always win — long captions wrap instead of widening the window.
    private func rowBase(title: String, detail: String?, monoDetail: Bool = false,
                         trailing: NSView,
                         titleColor: NSColor = .labelColor,
                         titleWeight: NSFont.Weight = .regular) -> NSView {
        let text = label(title, 13, weight: titleWeight, color: titleColor)
        text.setContentCompressionResistancePriority(.init(499), for: .horizontal)
        var columnViews = [text]
        if let detail {
            columnViews.append(monoDetail
                ? label(detail, 11, color: .secondaryLabelColor, mono: true)
                : rowCaption(detail))
        }
        let column = NSStackView(views: columnViews)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.setContentCompressionResistancePriority(.init(499), for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [column, spacer, trailing])
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        return row
    }

    private func rowCaption(_ text: String) -> NSTextField {
        let caption = label(text, 11, color: .secondaryLabelColor)
        caption.cell?.wraps = true
        caption.lineBreakMode = .byWordWrapping
        caption.maximumNumberOfLines = 0
        caption.setContentCompressionResistancePriority(.init(499), for: .horizontal)
        return caption
    }

    private func headerRow(title: String) -> NSView {
        rowBase(title: title, detail: nil, trailing: NSView(),
                titleColor: .secondaryLabelColor, titleWeight: .semibold)
    }

    private func infoRow(title: String, detail: String?, trailing: String,
                         trailingColor: NSColor = .secondaryLabelColor,
                         monoDetail: Bool = false) -> NSView {
        let status = label(trailing, 12, weight: .semibold, color: trailingColor)
        return rowBase(title: title, detail: detail, monoDetail: monoDetail,
                       trailing: status)
    }

    private func actionRow(title: String, detail: String?, buttonTitle: String,
                           action: Selector) -> NSView {
        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.bezelStyle = .rounded
        return rowBase(title: title, detail: detail, trailing: button)
    }

    private func switchRow(title: String, detail: String?, isOn: Bool,
                           action: Selector) -> (NSView, NSSwitch) {
        let sw = NSSwitch()
        sw.state = isOn ? .on : .off
        sw.target = self
        sw.action = action
        sw.setAccessibilityLabel(title)
        return (rowBase(title: title, detail: detail, trailing: sw), sw)
    }

    private func stepperRow(title: String, detail: String?, id: String,
                            min: Double, max: Double, step: Double, value: Double,
                            format: @escaping (Int) -> String) -> NSView {
        let readout = label(format(Int(value.rounded())), 12, weight: .semibold,
                            color: .secondaryLabelColor, mono: true)
        let stepper = NSStepper()
        stepper.identifier = NSUserInterfaceItemIdentifier(rawValue: id)
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = step
        stepper.doubleValue = value
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        stepper.setAccessibilityLabel(title)
        stepper.setAccessibilityValue(format(Int(value.rounded())))
        stepper.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        stepperRows.append((stepper, readout, format))

        let cluster = NSStackView(views: [readout, stepper])
        cluster.spacing = 8
        return rowBase(title: title, detail: detail, trailing: cluster)
    }

    // MARK: Sections

    private func buildGeneral() -> [NSView] {
        let (track, sw) = switchRow(title: "Track activity",
                                    detail: "Pause accrual without quitting — nothing is logged while off",
                                    isOn: activity.enabled,
                                    action: #selector(toggleTracking(_:)))
        trackingSwitch = sw
        let (login, _) = switchRow(title: "Launch at Login",
                                   detail: "Start Tally when you sign in",
                                   isOn: LoginItem.isEnabled,
                                   action: #selector(toggleLogin(_:)))
        let updates = actionRow(title: "Check for updates",
                                detail: "The signed appcast is Tally's only network call — tracking itself never phones home",
                                buttonTitle: "Check Now",
                                action: #selector(checkUpdates(_:)))
        return [cardGroup([track, login]), cardGroup([updates])]
    }

    private func buildTracking() -> [NSView] {
        let idle = stepperRow(title: "Idle threshold",
                              detail: "Time away from the Mac before tracking pauses",
                              id: "idle",
                              min: 30, max: 600, step: 30,
                              value: UserDefaults.standard.double(forKey: ActivityDefaults.idleThreshold),
                              format: { "\($0) s" })
        let rules = infoRow(title: "Classification rules",
                            detail: "First matching pattern wins — patterns are managed from the panel's Category rules card",
                            trailing: "In panel")
        let privacy = rowBase(title: "Privacy",
                              detail: "1Password & Keychain logged title-less as Private. Window titles never leave this Mac.",
                              trailing: NSView())
        return [cardGroup([idle]), cardGroup([rules, privacy])]
    }

    private func buildFocus() -> [NSView] {
        let focusRow = stepperRow(title: "Focus length",
                                  detail: "Minutes per focus session",
                                  id: "focus", min: 5, max: 60, step: 1,
                                  value: focus.focusMinutes, format: { "\($0) min" })
        let breakRow = stepperRow(title: "Break length",
                                  detail: "Minutes per short break",
                                  id: "break", min: 1, max: 15, step: 1,
                                  value: focus.breakMinutes, format: { "\($0) min" })
        let longRow = stepperRow(title: "Long break",
                                 detail: "Minutes per long break",
                                 id: "long", min: 5, max: 30, step: 1,
                                 value: focus.longBreakMinutes, format: { "\($0) min" })
        let cadenceRow = stepperRow(title: "Long-break cadence",
                                    detail: "Focus sessions before a long break",
                                    id: "cadence", min: 2, max: 6, step: 1,
                                    value: Double(focus.longBreakCadence),
                                    format: { "every \($0)" })
        return [cardGroup([focusRow, breakRow, longRow, cadenceRow])]
    }

    private func buildLicense() -> [NSView] {
        let free = infoRow(title: "Free tier", detail: "7 days of history",
                           trailing: LicenseManager.shared.isPro ? "" : "Current")
        let pro = infoRow(title: "Pro",
                          detail: "Unlimited + all updates — $9.99 one-time",
                          trailing: LicenseManager.shared.isPro ? "Current" : "")
        let buy = actionRow(title: "Buy Pro",
                            detail: "One-time purchase — the key arrives by email",
                            buttonTitle: "Buy Pro",
                            action: #selector(buyProTapped(_:)))

        var stateRows: [NSView] = []
        if LicenseManager.shared.isPro, let lic = LicenseManager.shared.license {
            stateRows.append(infoRow(title: "Status", detail: lic.email,
                                     trailing: "Pro", trailingColor: .systemGreen))
            stateRows.append(actionRow(title: "Deactivate",
                                       detail: "Removes the key from this Mac",
                                       buttonTitle: "Deactivate",
                                       action: #selector(deactivateTapped(_:))))
        } else {
            let field = NSTextField()
            field.placeholderString = "License key"
            field.font = .systemFont(ofSize: 12)
            field.bezelStyle = .roundedBezel
            field.target = self
            field.action = #selector(activateTapped(_:))
            field.widthAnchor.constraint(equalToConstant: 220).isActive = true
            field.setAccessibilityLabel("License key")
            licenseKeyField = field
            let activate = NSButton(title: "Activate", target: self,
                                    action: #selector(activateTapped(_:)))
            activate.bezelStyle = .rounded
            let cluster = NSStackView(views: [field, activate])
            cluster.spacing = 8
            stateRows.append(rowBase(title: "License key",
                                     detail: "Paste the key from your purchase email",
                                     trailing: cluster))
            let error = label("Invalid license key", 11, color: .systemRed)
            error.isHidden = true
            licenseError = error
            stateRows.append(error)
        }
        return [cardGroup([free, pro, buy]), cardGroup(stateRows)]
    }

    private func buildAbout() -> [NSView] {
        let icon = NSImageView(image: NSImage(systemSymbolName: "chart.bar",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        let wordmark = label(Theme.wordmark, 15)
        wordmark.font = roundedFont(15, .heavy)
        let version = label(Theme.version, 11, weight: .semibold,
                            color: .secondaryLabelColor, mono: true)
        let tagline = label(Theme.tagline, 12, color: .secondaryLabelColor)

        let support = LinkButton(title: "Support ↗", target: self,
                                 action: #selector(openSupport(_:)))
        support.bezelStyle = .inline
        support.font = .systemFont(ofSize: 12)
        support.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true

        let copyright = label("© 2026 Sashay Portfolio — local-only, zero telemetry.",
                              11, color: .tertiaryLabelColor)

        let column = NSStackView(views: [icon, wordmark, version, tagline, support, copyright])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 8
        [wordmark, version, tagline, support, copyright].forEach {
            $0.setContentCompressionResistancePriority(.init(499), for: .horizontal)
        }
        column.setContentCompressionResistancePriority(.init(499), for: .horizontal)

        let holder = NSView()
        holder.addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            column.topAnchor.constraint(equalTo: holder.topAnchor, constant: 32),
            column.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor,
                                           constant: -16),
        ])
        return [holder]
    }

    // MARK: Wiring

    private func wireState() {
        activity.$enabled
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                self?.trackingSwitch?.state = on ? .on : .off
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .licenseChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.section == .license else { return }
                self.rebuildPane()
            }
            .store(in: &cancellables)
    }

    // MARK: Actions

    @objc private func navTapped(_ button: NavButton) { select(button.section) }

    @objc private func toggleTracking(_ sw: NSSwitch) {
        activity.enabled = sw.state == .on
        announce(sw.state == .on ? "Tracking resumed" : "Tracking paused")
    }

    @objc private func toggleLogin(_ sw: NSSwitch) { LoginItem.setEnabled(sw.state == .on) }

    @objc private func checkUpdates(_ sender: NSButton) { updater.checkForUpdates(sender) }

    @objc private func stepperChanged(_ stepper: NSStepper) {
        let v = Int(stepper.doubleValue.rounded())
        switch stepper.identifier?.rawValue {
        case "idle":
            UserDefaults.standard.set(stepper.doubleValue, forKey: ActivityDefaults.idleThreshold)
        case "focus": focus.focusMinutes = Double(v)
        case "break": focus.breakMinutes = Double(v)
        case "long": focus.longBreakMinutes = Double(v)
        case "cadence": focus.longBreakCadence = v
        default: break
        }
        if let row = stepperRows.first(where: { $0.stepper == stepper }) {
            row.readout.stringValue = row.format(v)
            stepper.setAccessibilityValue(row.format(v))
        }
    }

    @objc private func buyProTapped(_ sender: NSButton) {
        if let url = URL(string: "https://buy.stripe.com/9B6cMY0Tnf3ygn8dCR4Vy01") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func activateTapped(_ sender: Any?) {
        guard let field = licenseKeyField else { return }
        if LicenseManager.shared.activate(field.stringValue) {
            announce("Pro activated")
        } else {
            licenseError?.isHidden = false
            announce("Invalid license key")
        }
    }

    @objc private func deactivateTapped(_ sender: NSButton) {
        LicenseManager.shared.deactivate()
    }

    @objc private func openSupport(_ sender: Any?) {
        if let url = URL(string: "https://github.com/jazinski/sashay-support") {
            NSWorkspace.shared.open(url)
        }
    }

    private func announce(_ text: String) {
        guard let element = window?.contentView else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: text])
    }

    // MARK: Keyboard navigation

    /// NSWindowController sits in the responder chain after the window, so
    /// unconsumed ↑/↓ land here and walk the sidebar selection.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: moveSelection(-1)
        case 125: moveSelection(1)
        default: super.keyDown(with: event)
        }
    }

    private func moveSelection(_ delta: Int) {
        let order = Section.allCases
        guard let current = order.firstIndex(of: section) else { return }
        select(order[(current + delta + order.count) % order.count])
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { self.onTeardown?() }
    }
}

/// Source-list nav item. Active: amber-tinted rounded fill, amber semibold
/// title, accent-tinted template symbol (mockup `.nav.active`).
private final class NavButton: NSButton {
    let section: SettingsWindowController.Section
    var isActive = false { didSet { render() } }
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    init(section: SettingsWindowController.Section, target: AnyObject?, action: Selector) {
        self.section = section
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 8

        iconView.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        if section.isNew { addBadge() }
        self.target = target
        self.action = action
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("Settings, \(section.title) section")
        render()
    }

    required init?(coder: NSCoder) { fatalError("nope") }

    private func render() {
        iconView.contentTintColor = isActive ? Theme.accent : .secondaryLabelColor
        layer?.backgroundColor = isActive
            ? Theme.accent.withAlphaComponent(0.14).cgColor : nil
        titleLabel.font = .systemFont(ofSize: 13, weight: isActive ? .semibold : .regular)
        titleLabel.textColor = isActive ? Theme.accent : .secondaryLabelColor
        titleLabel.stringValue = section.title
    }

    private func addBadge() {
        let badge = NSTextField(labelWithString: "NEW")
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .secondaryLabelColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

/// Arrows drive sidebar navigation, never pane scrolling.
private final class PaneScrollView: NSScrollView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 125 || event.keyCode == 126 {
            nextResponder?.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var activity: ActivityEngine!
    private var focus: FocusEngine!
    private var panel: PanelController!
    private var settings: SettingsWindowController?
    private var cmdCommaMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    private lazy var chartIcon: NSImage = {
        let i = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: nil) ?? NSImage()
        i.isTemplate = true
        return i
    }()
    private lazy var timerIcon: NSImage = {
        let i = NSImage(systemSymbolName: "timer", accessibilityDescription: nil) ?? NSImage()
        i.isTemplate = true
        return i
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ActivityEngine()
        focus = FocusEngine(activity: activity)
        panel = PanelController(activity: activity, focus: focus, updater: updater)

        popover = NSPopover()
        popover.contentViewController = panel
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.behavior = .transient
        popover.animates = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = chartIcon
        statusItem.button?.imagePosition = .imageLeading
        imagePadding = 4
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        statusItem.button?.toolTip = "Tally"
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        applyStatusPresentation()

        focus.$phase.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyStatusPresentation() }.store(in: &cancellables)
        focus.$remaining.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyStatusPresentation() }.store(in: &cancellables)
        focus.$paused.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyStatusPresentation() }.store(in: &cancellables)
        activity.$enabled.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyStatusPresentation() }.store(in: &cancellables)

        // ⌘, opens Settings whenever Tally is active — popover included.
        cmdCommaMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "," else { return event }
            self.openSettings()
            return nil
        }
    }

    /// Menu-bar symbol law: outline template symbols. chart.bar normally,
    /// timer while a session runs, with remaining minutes in the a11y label.
    private func applyStatusPresentation() {
        guard let button = statusItem?.button else { return }
        let phase = focus.phase
        button.image = phase == .idle ? chartIcon : timerIcon
        if phase == .idle {
            button.title = ""
            button.setAccessibilityLabel(activity.enabled ? "Tally — Tracking" : "Tally — Paused")
        } else {
            button.title = formatClock(focus.remaining)
            if focus.paused {
                button.setAccessibilityLabel("Tally — paused, \(phase.label)")
            } else {
                let minutes = Int((focus.remaining / 60).rounded(.up))
                button.setAccessibilityLabel("Tally — \(minutes) min left, \(phase.label)")
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()
            let settingsItem = NSMenuItem(title: "Settings…",
                                          action: #selector(openSettings),
                                          keyEquivalent: ",")
            settingsItem.target = self
            menu.addItem(settingsItem)
            menu.addItem(.separator())
            let quitItem = NSMenuItem(title: "Quit Tally",
                                      action: #selector(NSApplication.terminate(_:)),
                                      keyEquivalent: "q")
            quitItem.target = NSApp
            menu.addItem(quitItem)
            // Pop the menu once without replacing the button's click action.
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown { popover.performClose(button) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    @objc func openSettings() {
        if settings == nil {
            let controller = SettingsWindowController(activity: activity, focus: focus,
                                                       updater: updater)
            controller.onTeardown = { [weak self] in self?.settings = nil }
            settings = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
    }
}

#if !SKIP_APP_MAIN
@main
enum TallyApp {
    static func main() {
        let lockPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Caches/com.jazinski.tally.lock")
        let fd = lockPath.withCString { open($0, O_CREAT | O_RDWR, 0o644) }
        if fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0 { exit(0) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
#endif
