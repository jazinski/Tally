//
//  Tally.swift
//  Tally — where did your day go — without telling anyone.
//
//  Panel + app shell. Engines live in ActivityEngine.swift (tracking) and
//  FocusEngine.swift (pomodoro); this file only wires them to the chassis:
//  status card, day strip, focus card, rules card, license card, menu-bar
//  status item. Local-only, zero network ever.
//
//  Conventions per Sashay/AGENTS.md: 344pt panel, floor-clamped labels,
//  GCD DispatchSource timers (never RunLoop Timer), dark Aqua, mono digits
//  for ticking numbers, flock single-instance guard.
//
//  v0.0.1 · Built for client #1.
//

import AppKit
import Combine
import Sparkle

// MARK: - Brand

enum Theme {
    static let accent   = NSColor(red: 1.0, green: 0.58, blue: 0.10, alpha: 1)
    static let wordmark = "Tally"
    static let tagline  = "Where did your day go?"
    static let version  = "v0.0.1"
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
        let privacy = label("Local-only. Nothing ever leaves this Mac.", 11, color: .secondaryLabelColor)
        let updates = linkButton("Updates", #selector(checkForUpdatesTapped))
        let quit = linkButton("Quit", #selector(quitApp))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [privacy, spacer, updates, quit])
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var activity: ActivityEngine!
    private var focus: FocusEngine!
    private var panel: PanelController!
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
        if popover.isShown { popover.performClose(button) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
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
