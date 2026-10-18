import AppKit
import QuartzCore
import SwiftUI
import UserNotifications

extension Notification.Name {
    static let calendarPanelWillShow = Notification.Name("CalendarPanelWillShow")
    static let calendarNotificationDayRequested = Notification.Name("CalendarNotificationDayRequested")
    static let calendarSystemDayChanged = Notification.Name("CalendarSystemDayChanged")
}

@main
struct GoldenGateCalendarApp: App {
    @NSApplicationDelegateAdaptor(CalendarApplicationDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(settings: delegate.settings, login: delegate.login, importer: delegate.importer, cloud: delegate.cloud, store: delegate.store)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .preferredColorScheme(delegate.settings.theme.preferredColorScheme)
                .onAppear { delegate.login.refresh() }
        }
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("О приложении «Календарь»") {
                        NSApp.orderFrontStandardAboutPanel(nil)
                    }
                }
                CommandGroup(replacing: .appTermination) {
                    Button("Завершить приложение") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
    }
}

@MainActor
final class CalendarApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var panel: CalendarPanel?
    private var sheetsHiddenWithPanel: [NSWindow] = []
    private var panelPresentedAt: TimeInterval = 0
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var dateTimer: Timer?
    private var sharedDataObserver: NSObjectProtocol?
    private var pendingWidgetLink: WidgetDeepLink?
    private var lastKnownDay = Calendar.current.startOfDay(for: Date())
    let store = CalendarStore()
    let settings = AppSettings()
    let login = LoginItemManager()
    let importer = ISTUImportController()
    let cloud = CloudController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        store.onCommit = { [weak self] in WidgetBridge.notifyDataChanged(); self?.cloud.localDataChanged() }
        importer.attach(store: store)
        cloud.attach(store: store, importer: importer)
        cloud.notifications = NativeNotificationCoordinator(store: store, cloud: cloud)
        observeSystemChanges()
        login.attemptFirstLaunchRegistration()
        let defaults = UserDefaults.standard
        let firstPresentationKey = "interface.initialPanelPresented.v1"
        if !defaults.bool(forKey: firstPresentationKey) {
            DispatchQueue.main.async { [weak self] in
                self?.showPanel()
                if self?.panel?.isVisible == true {
                    defaults.set(true, forKey: firstPresentationKey)
                }
            }
        }
        if let pendingWidgetLink {
            self.pendingWidgetLink = nil
            handleWidgetLink(pendingWidgetLink)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let link = urls.compactMap(WidgetDeepLink.init(url:)).first else { return }
        guard statusItem != nil else { pendingWidgetLink = link; return }
        handleWidgetLink(link)
    }

    private func handleWidgetLink(_ link: WidgetDeepLink) {
        guard let date = link.day.date(in: .current) else { return }
        showPanel()
        // Let the newly installed SwiftUI root subscribe before sending a route.
        DispatchQueue.main.async {
            let name: Notification.Name = switch link {
            case .chooseDate: .calendarWidgetDateRequested
            case .openDay: .calendarWidgetDayRequested
            }
            NotificationCenter.default.post(name: name, object: nil, userInfo: ["date": date])
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Календарь и дела")
            button.image?.isTemplate = true
            button.toolTip = "Календарь и дела"
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            // Toggle on mouse-down, before AppKit begins tracking the menu-bar button.
            // Waiting for mouse-up allows an outside-click dismissal to race the toggle.
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
            button.setAccessibilityLabel("Календарь и дела")
        }
        statusItem = item
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Открыть календарь", action: #selector(openCalendar), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Завершить приложение", action: #selector(terminateApplication), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
            return
        }
        if panel?.isVisible == true { closePanel(includingSheets: true) } else { showPanel() }
    }

    @objc private func openCalendar() { showPanel() }
    @objc private func terminateApplication() { NSApp.terminate(nil) }

    private func makePanel() -> CalendarPanel {
        let panel = CalendarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 730),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Календарь и дела"
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        // Keep the same panel and editor state visible when the user changes Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        let content = CalendarPanelView(store: store, settings: settings, login: login, importer: importer, cloud: cloud)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let hostingView = RoundedPanelHostingView(rootView: content)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = CalendarPanel.cornerRadius
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        panel.updateRoundedFrameMask()
        return panel
    }

    private func showPanel() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let available = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let size = NSSize(width: min(1160, available.width), height: min(730, available.height))
        let x = min(max(anchor.midX - size.width / 2, available.minX), available.maxX - size.width)
        let y = min(max(anchor.minY - size.height - 8, available.minY), available.maxY - size.height)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
        login.refresh()
        store.reloadFromDisk()
        checkCurrentDay()
        NotificationCenter.default.post(name: .calendarPanelWillShow, object: nil)
        panelPresentedAt = ProcessInfo.processInfo.systemUptime
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.updateRoundedFrameMask()
        for sheet in sheetsHiddenWithPanel where sheet.sheetParent != nil {
            sheet.makeKeyAndOrderFront(nil)
        }
        sheetsHiddenWithPanel.removeAll()
        startEventMonitors()
    }

    private func closePanel(includingSheets: Bool = false) {
        guard let panel else { return }
        guard includingSheets || panel.attachedSheet == nil else { return }
        if includingSheets {
            // Do not end the sheet session: SwiftUI keeps unsaved form values intact.
            sheetsHiddenWithPanel.removeAll()
            var nextSheet = panel.attachedSheet
            while let sheet = nextSheet {
                sheetsHiddenWithPanel.append(sheet)
                nextSheet = sheet.attachedSheet
            }
            for sheet in sheetsHiddenWithPanel.reversed() { sheet.orderOut(nil) }
        }
        panel.orderOut(nil)
        stopEventMonitors()
    }

    private func isInsideStatusButton(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let screenRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return screenRect.contains(screenPoint)
    }

    private func startEventMonitors() {
        stopEventMonitors()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53, panel.attachedSheet == nil {
                self.closePanel()
                return nil
            }
            if event.type != .keyDown,
               !self.isInsideStatusButton(NSEvent.mouseLocation),
               event.window !== panel,
               event.window !== panel.attachedSheet,
               event.window !== self.statusItem?.button?.window,
               !panel.frame.contains(NSEvent.mouseLocation) {
                self.closePanel()
            }
            return event
        }
        // Mouse monitoring requires no Accessibility or Screen Recording permission.
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let screenPoint = NSEvent.mouseLocation
            let eventTimestamp = event.timestamp
            Task { @MainActor [weak self] in
                guard let self,
                      eventTimestamp >= self.panelPresentedAt,
                      !self.isInsideStatusButton(screenPoint) else { return }
                self.closePanel()
            }
        }
    }

    private func stopEventMonitors() {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        localEventMonitor = nil
        globalEventMonitor = nil
    }

    private func observeSystemChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NativeNotificationCoordinator.openDay, object: nil, queue: .main) { [weak self] notification in
            let day = notification.userInfo?["day"] as? CivilDay
            Task { @MainActor [weak self] in
                guard let self, let day else { return }
                self.showPanel()
                NotificationCenter.default.post(name: .calendarNotificationDayRequested, object: nil, userInfo: ["day": day])
            }
        })
        sharedDataObserver = DistributedNotificationCenter.default().addObserver(
            forName: .plannerSharedDataChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.store.reloadFromDisk() }
        }
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkCurrentDay(force: true)
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.login.refresh()
                self?.store.reloadFromDisk()
                self?.checkCurrentDay()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.panel?.isVisible == true { self?.showPanel() }
            }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkCurrentDay(force: true)
                self?.cloud.notifications?.refresh()
                self?.login.refresh()
            }
        })
        dateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkCurrentDay()
                self?.store.reloadFromDisk()
                self?.cloud.notifications?.refresh()
            }
        }
        if let dateTimer { RunLoop.main.add(dateTimer, forMode: .common) }
    }

    private func checkCurrentDay(force: Bool = false) {
        let currentDay = Calendar.current.startOfDay(for: Date())
        if force || currentDay != lastKnownDay {
            lastKnownDay = currentDay
            NotificationCenter.default.post(name: .calendarSystemDayChanged, object: nil)
        }
    }

    func windowDidResize(_ notification: Notification) {
        (notification.object as? CalendarPanel)?.updateRoundedFrameMask()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        (notification.object as? CalendarPanel)?.updateRoundedFrameMask()
    }

    func windowDidUpdate(_ notification: Notification) {
        (notification.object as? CalendarPanel)?.updateRoundedFrameMask()
    }

    func windowWillBeginSheet(_ notification: Notification) {
        refreshFrameMaskAfterSheetLayout(notification)
    }

    func windowDidEndSheet(_ notification: Notification) {
        refreshFrameMaskAfterSheetLayout(notification)
    }

    private func refreshFrameMaskAfterSheetLayout(_ notification: Notification) {
        guard let panel = notification.object as? CalendarPanel else { return }
        panel.updateRoundedFrameMask()
        // AppKit may install or replace the sheet's dimming view after its notification.
        DispatchQueue.main.async { [weak panel] in panel?.updateRoundedFrameMask() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEventMonitors()
        cloud.stop()
        dateTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let sharedDataObserver { DistributedNotificationCenter.default().removeObserver(sharedDataObserver) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

final class CalendarPanel: NSPanel {
    static let cornerRadius: CGFloat = 24
    private let roundedFrameMask = CAShapeLayer()
    private weak var maskedFrameView: NSView?
    private var maskedBounds = NSRect.null
    private var maskedScale: CGFloat = 0

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Sheet dimming is inserted outside NSHostingView. Clip the complete window
    /// view tree, using only public NSView ancestry and Core Animation APIs.
    func updateRoundedFrameMask() {
        guard var frameView = contentView else { return }
        while let parent = frameView.superview { frameView = parent }
        let bounds = frameView.bounds
        guard !bounds.isEmpty else { return }
        if !frameView.wantsLayer { frameView.wantsLayer = true }
        guard let layer = frameView.layer else { return }
        let scale = backingScaleFactor
        guard maskedFrameView !== frameView || maskedBounds != bounds || maskedScale != scale || layer.mask !== roundedFrameMask else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if maskedFrameView !== frameView, maskedFrameView?.layer?.mask === roundedFrameMask {
            maskedFrameView?.layer?.mask = nil
        }
        roundedFrameMask.frame = bounds
        roundedFrameMask.contentsScale = scale
        roundedFrameMask.fillColor = NSColor.black.cgColor
        roundedFrameMask.path = CGPath(
            roundedRect: CGRect(origin: .zero, size: bounds.size),
            cornerWidth: Self.cornerRadius,
            cornerHeight: Self.cornerRadius,
            transform: nil
        )
        layer.masksToBounds = true
        layer.mask = roundedFrameMask
        CATransaction.commit()
        maskedFrameView = frameView
        maskedBounds = bounds
        maskedScale = scale
    }
}

private final class RoundedPanelHostingView<Content: View>: NSHostingView<Content> {
    override func layout() {
        super.layout()
        (window as? CalendarPanel)?.updateRoundedFrameMask()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        (window as? CalendarPanel)?.updateRoundedFrameMask()
    }
}
