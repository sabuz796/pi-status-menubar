import Cocoa

final class DashboardPopoverController: NSObject, NSPopoverDelegate {
    private let store: DashboardStore
    private let popover = NSPopover()
    private let content: DashboardViewController
    private var timer: Timer?

    var isShown: Bool { popover.isShown }

    init(store: DashboardStore) {
        self.store = store
        self.content = DashboardViewController(store: store)
        super.init()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 440, height: 640)
        popover.contentViewController = content
        popover.delegate = self
    }

    // Only called from menuDidClose, so the popover never competes with the menu
    // that is still tracking when the item's action fires.
    func show(relativeTo anchor: NSView) {
        _ = content.view // loaded before the first show, so it is never blank
        content.apply(store.snapshot)
        if !popover.isShown {
            // A transient popover closes the instant the app resigns active, and
            // this accessory app resigns the moment the status menu stops
            // tracking. Activating first is what keeps it on screen.
            NSApp.activate(ignoringOtherApps: true)
            // The default popover appearance is the vibrant material (glass).
            // The standard system look is solid and follows the machine's
            // light or dark setting.
            popover.appearance = NSApp.effectiveAppearance
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        startTimer()
        store.refresh { [weak self] snapshot in self?.content.apply(snapshot) }
    }

    private func startTimer() {
        timer?.invalidate()
        let tick = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.store.refresh { [weak self] snapshot in self?.content.apply(snapshot) }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    func popoverDidClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

final class DashboardTabsViewController: NSTabViewController {
    var onSelect: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelect?()
    }
}

final class DashboardViewController: NSViewController {
    private let store: DashboardStore
    private let hero = NSTextField(labelWithString: "")
    private let metricLabel = NSTextField(labelWithString: "")
    private let updated = NSTextField(labelWithString: "")
    private let rangeControl = NSSegmentedControl()
    private let refreshButton = PanelButton()
    private let refreshSpinner = NSProgressIndicator()
    private let tabs = DashboardTabsViewController()
    private var tabControllers: [DashboardTabController] = []
    private var current = DashboardSnapshot()

    init(store: DashboardStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        tabs.tabStyle = .segmentedControlOnTop
        tabs.transitionOptions = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : [.crossfade]
        let definitions: [(String, DashboardTabController)] = [
            ("Overview", OverviewTabController()),
            ("Languages", LanguagesTabController()),
            ("Models", ModelsTabController()),
            ("Projects", ProjectsTabController()),
            ("Usage", UsageTabController()),
        ]
        for (title, controller) in definitions {
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            tabs.addTabViewItem(item)
            tabControllers.append(controller)
        }
        tabs.selectedTabViewItemIndex = 0
        tabs.onSelect = { [weak self] in self?.applyVisibleTab() }
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let card = CardView(frame: NSRect(x: 0, y: 0, width: 440, height: 640))
        let title = NSTextField(labelWithString: "Pi Stats")
        title.font = Format.text(.title2, weight: .semibold)
        updated.font = Format.caption
        updated.textColor = .secondaryLabelColor
        hero.alignment = .right
        metricLabel.font = Format.caption
        metricLabel.textColor = .secondaryLabelColor
        metricLabel.alignment = .right

        rangeControl.segmentCount = StatsRange.allCases.count
        for (index, range) in StatsRange.allCases.enumerated() {
            rangeControl.setLabel(range.label, forSegment: index)
        }
        rangeControl.segmentStyle = .rounded
        rangeControl.trackingMode = .selectOne
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged(_:))
        rangeControl.setAccessibilityLabel("Time range")

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.imagePosition = .imageOnly
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped(_:))
        refreshButton.setAccessibilityLabel("Refresh")

        refreshSpinner.style = .spinning
        refreshSpinner.controlSize = .small
        refreshSpinner.isDisplayedWhenStopped = false
        refreshSpinner.isHidden = true

        let logo = LogoView()

        addChild(tabs)
        let headerViews: [NSView] = [logo, title, updated, rangeControl, refreshButton, refreshSpinner, hero, metricLabel, tabs.view]
        for subview in headerViews {
            subview.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            logo.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            logo.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            logo.widthAnchor.constraint(equalToConstant: 26),
            logo.heightAnchor.constraint(equalToConstant: 26),
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 9),
            updated.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            updated.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            refreshButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            refreshSpinner.centerXAnchor.constraint(equalTo: refreshButton.centerXAnchor),
            refreshSpinner.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            rangeControl.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -6),
            rangeControl.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            hero.topAnchor.constraint(equalTo: updated.bottomAnchor, constant: 8),
            hero.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            metricLabel.topAnchor.constraint(equalTo: hero.bottomAnchor),
            metricLabel.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
            tabs.view.topAnchor.constraint(equalTo: metricLabel.bottomAnchor, constant: 8),
            tabs.view.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            tabs.view.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            tabs.view.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        view = card
        applyVisibleTab()
    }

    func apply(_ snapshot: DashboardSnapshot) {
        current = snapshot
        hero.attributedStringValue = Format.hero(Format.heroValue(snapshot))
        metricLabel.stringValue = snapshot.metric.listLabel
        updated.stringValue = "Updated " + Format.time(snapshot.generatedAt)
        if let index = StatsRange.allCases.firstIndex(of: snapshot.range) {
            rangeControl.selectedSegment = index
        }
        applyVisibleTab()
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard index >= 0, index < StatsRange.allCases.count else { return }
        store.setRange(StatsRange.allCases[index])
        refreshFromStore(showProgress: true)
    }

    @objc private func refreshTapped(_ sender: NSButton) {
        refreshFromStore(showProgress: true)
    }

    // setRange publishes without a callback, so a refresh after it is what
    // delivers the rebuilt snapshot to the view.
    private func refreshFromStore(showProgress: Bool = false) {
        if showProgress { beginProgress() }
        let started = Date()
        store.refresh { [weak self] snapshot in
            guard let self = self else { return }
            self.apply(snapshot)
            guard showProgress else { return }
            // Hold the indicator for a moment even when the pass returns at
            // once, so the click is always visibly acknowledged.
            let remaining = max(0, 0.45 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.endProgress()
            }
        }
    }

    private func beginProgress() {
        refreshButton.isHidden = true
        refreshSpinner.isHidden = false
        refreshSpinner.startAnimation(nil)
    }

    private func endProgress() {
        refreshSpinner.stopAnimation(nil)
        refreshSpinner.isHidden = true
        refreshButton.isHidden = false
    }

    // Only the visible tab is re-applied; a hidden one catches up on selection.
    private func applyVisibleTab() {
        let index = tabs.selectedTabViewItemIndex
        guard index >= 0, index < tabControllers.count else { return }
        tabControllers[index].apply(current)
    }
}
