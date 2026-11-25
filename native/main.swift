// Desk Clawd — a native macOS host for desk-clawd.html.
// A borderless, transparent panel that floats above normal windows and joins every Space,
// including full-screen apps. No Dock icon (LSUIElement); controls live in the menu bar.

import ApplicationServices
import Cocoa
import ServiceManagement
import WebKit

final class ClickWebView: WKWebView {
    // Let the first click land on Clawd without activating the app first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private var panel: OverlayPanel!
    private var web: ClickWebView!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var lastMouse = NSPoint(x: -1, y: -1)
    private var lastPointerSent: TimeInterval = 0

    // What the page last told us.
    private var hitRects: [NSRect] = []      // page coordinates (top-left origin)
    private var captureAll = false           // dragging or Clawd's own menu is open
    private var size = "M", color = "Clay", stay = false, sleeping = false
    private var food = 0, energy = 0, mood = 0
    private var envTicks = 0
    private var lastWindowsJSON = ""

    // Seeing the interface (Accessibility). Opt-in from the menu bar; nothing is stored or sent anywhere.
    private var axObserver: AXObserver?
    private var axApp: AXUIElement?
    private let systemWide = AXUIElementCreateSystemWide()
    private var trustTimer: Timer?
    private var lastWindowTitle = ""
    private var lastSeenMouse = NSPoint(x: -1, y: -1)
    private var lastMoveAt: TimeInterval = 0
    private var hoverChecked = true
    private var seeUI: Bool {
        get { UserDefaults.standard.object(forKey: "seeUI") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "seeUI") }
    }
    private var uiOn: Bool { seeUI && AXIsProcessTrusted() }

    private static let sizes = ["S", "M", "L"]
    private static let colors = ["Clay", "Sand", "Ink"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = targetFrame()
        panel = OverlayPanel(contentRect: frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        // Above normal and floating windows, below alerts, pop-up menus and the screen saver.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "clawd")
        web = ClickWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        panel.contentView = web

        if let url = Bundle.main.url(forResource: "clawd", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        panel.orderFrontRegardless()

        setUpStatusItem()

        // The panel ignores the mouse except over Clawd. Swift hit-tests the cursor against the rects
        // the page sends, so click-through flips without a round trip to the page.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.01
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // What Clawd knows about you: how long you've been idle, where your windows' top edges are
        // (so Clawd can stand on them), and which app you just switched to. None of it leaves the Mac.
        let e = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.envTick() }
        e.tolerance = 0.05
        RunLoop.main.add(e, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        if uiOn { watch(NSWorkspace.shared.frontmostApplication) }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Let the page save before quitting; its periodic save may be up to 5 s old.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var replied = false
        let reply = { if !replied { replied = true; sender.reply(toApplicationShouldTerminate: true) } }
        web.evaluateJavaScript("window.clawdNative && window.clawdNative.save()") { _, _ in reply() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { reply() }
        return .terminateLater
    }

    /// The primary display (the one with the menu bar), minus the menu bar and Dock.
    private func targetFrame() -> NSRect {
        (NSScreen.screens.first ?? NSScreen.main!).visibleFrame
    }

    @objc private func screensChanged() {
        panel.setFrame(targetFrame(), display: true)
    }

    private func tick() {
        guard panel.isVisible else { return }
        let m = NSEvent.mouseLocation
        let f = panel.frame
        let p = NSPoint(x: m.x - f.minX, y: f.maxY - m.y)
        let over = captureAll || hitRects.contains { $0.contains(p) }
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }

        let now = ProcessInfo.processInfo.systemUptime
        // Once the cursor rests for a moment, look at what it's resting on.
        if m != lastSeenMouse { lastSeenMouse = m; lastMoveAt = now; hoverChecked = false }
        else if !hoverChecked && now - lastMoveAt > 0.7 { hoverChecked = true; checkHover(m) }

        // Eye tracking only: 15 updates a second is plenty, and nothing is sent while the mouse is still.
        guard m != lastMouse else { return }
        guard now - lastPointerSent >= 1.0 / 15.0 else { return }
        lastMouse = m
        lastPointerSent = now
        web.evaluateJavaScript("window.clawdNative && window.clawdNative.pointer(\(p.x), \(p.y))", completionHandler: nil)
    }

    // MARK: what Clawd can see

    private func envTick() {
        guard panel.isVisible else { return }
        envTicks += 1
        if envTicks % 4 == 0 {
            let anyInput = CGEventType(rawValue: ~0)!
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
            let keys = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
            web.evaluateJavaScript("window.clawdNative && window.clawdNative.idle(\(idle), \(keys))", completionHandler: nil)
        }
        sendWindows()
    }

    /// Visible top edges of normal windows, in page coordinates, front-most first.
    /// Bounds need no Screen Recording permission; window titles (which would) are never read.
    private func sendWindows() {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let f = panel.frame
        let pageTop = self.pageTop
        var wins: [(id: Int, r: CGRect)] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.1,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            wins.append((id, CGRect(x: r.minX - f.minX, y: r.minY - pageTop, width: r.width, height: r.height)))
        }
        var out: [String] = []
        for (i, w) in wins.enumerated() where w.r.width >= 120 && w.r.height >= 80 {
            let y = w.r.minY
            var segs: [(CGFloat, CGFloat)] = [(w.r.minX, w.r.maxX)]
            // Cut out the parts hidden by windows in front (covering the edge or the space just above it).
            for front in wins[..<i] where front.r.minY <= y + 2 && front.r.maxY >= y - 24 {
                let fr = front.r
                segs = segs.flatMap { s -> [(CGFloat, CGFloat)] in
                    if fr.maxX <= s.0 || fr.minX >= s.1 { return [s] }
                    var keep: [(CGFloat, CGFloat)] = []
                    if fr.minX > s.0 { keep.append((s.0, fr.minX)) }
                    if fr.maxX < s.1 { keep.append((fr.maxX, s.1)) }
                    return keep
                }
            }
            for s in segs where s.1 - s.0 >= 60 {
                out.append("{\"id\":\(w.id),\"x1\":\(Int(s.0)),\"x2\":\(Int(s.1)),\"y\":\(Int(y)),\"wx\":\(Int(w.r.minX))}")
            }
        }
        let json = "[" + out.joined(separator: ",") + "]"
        guard json != lastWindowsJSON else { return }
        lastWindowsJSON = json
        web.evaluateJavaScript("window.clawdNative && window.clawdNative.windows(\(json))", completionHandler: nil)
    }

    /// Page y = 0, in global top-left (CoreGraphics / Accessibility) coordinates.
    private var pageTop: CGFloat {
        let f = panel.frame
        return (NSScreen.screens.first?.frame.height ?? f.maxY) - f.maxY
    }

    @objc private func appActivated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if uiOn { watch(app) }
        let args = [app.bundleIdentifier ?? "", app.localizedName ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: args), let list = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.clawdNative && window.clawdNative.app(...\(list))", completionHandler: nil)
    }

    // MARK: page → app

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "hit":
            captureAll = (body["all"] as? Bool) ?? false
            hitRects = ((body["rects"] as? [[Double]]) ?? []).compactMap { r in
                r.count == 4 ? NSRect(x: r[0], y: r[1], width: r[2], height: r[3]) : nil
            }
            tick()
        case "state":
            size = (body["size"] as? String) ?? size
            color = (body["color"] as? String) ?? color
            stay = (body["stay"] as? Bool) ?? stay
            sleeping = (body["sleeping"] as? Bool) ?? sleeping
            food = (body["food"] as? Int) ?? food
            energy = (body["energy"] as? Int) ?? energy
            mood = (body["joy"] as? Int) ?? mood
        case "hide":
            setVisible(false)
        default:
            break
        }
    }

    // MARK: menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.trayImage()
        statusItem.button?.toolTip = "Desk Clawd"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt on every open so titles and checkmarks match the page.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let needs = NSMenuItem(title: "Food \(food)%  ·  Energy \(energy)%  ·  Mood \(mood)%", action: nil, keyEquivalent: "")
        needs.isEnabled = false
        menu.addItem(needs)
        menu.addItem(.separator())
        menu.addItem(item(panel.isVisible ? "Hide Clawd" : "Show Clawd", #selector(toggleVisible)))
        menu.addItem(.separator())
        menu.addItem(item("Pet Clawd", #selector(petClawd)))
        menu.addItem(item("Drop a snack", #selector(dropSnack)))
        menu.addItem(item("Throw the ball", #selector(throwBall)))
        menu.addItem(item(sleeping ? "Wake up" : "Take a nap", #selector(nap)))
        menu.addItem(item("Stay put", #selector(toggleStay), on: stay))
        menu.addItem(submenu("Size", Self.sizes, current: size, #selector(pickSize(_:))))
        menu.addItem(submenu("Color", Self.colors, current: color, #selector(pickColor(_:))))
        menu.addItem(.separator())
        if AXIsProcessTrusted() {
            menu.addItem(item("See the Interface", #selector(toggleSeeUI), on: seeUI))
        } else {
            menu.addItem(item("Let Clawd See the Interface…", #selector(askAccessibility)))
        }
        menu.addItem(item("Open at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        let quit = NSMenuItem(title: "Quit Desk Clawd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    private func submenu(_ title: String, _ keys: [String], current: String, _ action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for k in keys {
            let i = item(k, action, on: k == current)
            i.representedObject = k
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    private func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil); panel.ignoresMouseEvents = true }
        if visible && uiOn { watch(NSWorkspace.shared.frontmostApplication) } else if !visible { stopWatching() }
        // Hidden means the page stops animating entirely.
        web.evaluateJavaScript("window.clawdNative && window.clawdNative.visible(\(visible))", completionHandler: nil)
    }

    private func js(_ call: String) {
        if !panel.isVisible { setVisible(true) }
        web.evaluateJavaScript("window.clawdNative && window.clawdNative.\(call)", completionHandler: nil)
    }

    @objc private func toggleVisible() { setVisible(!panel.isVisible) }
    @objc private func petClawd() { js("pet()") }
    @objc private func dropSnack() { js("snack()") }
    @objc private func throwBall() { js("ball()") }
    @objc private func nap() { js("nap()") }
    @objc private func toggleStay() { js("stay()") }
    @objc private func pickSize(_ sender: NSMenuItem) {
        if let k = sender.representedObject as? String, Self.sizes.contains(k) { js("size('\(k)')") }
    }
    @objc private func pickColor(_ sender: NSMenuItem) {
        if let k = sender.representedObject as? String, Self.colors.contains(k) { js("color('\(k)')") }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sendUI(["type": "status", "trusted": AXIsProcessTrusted(), "on": uiOn])
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Clawd's silhouette as a menu bar template image (eyes cut out).
    private static func trayImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let unit: CGFloat = 1.0           // grid spans x -2..14 (16 units), y 0..10
            let ox: CGFloat = 3, oy: CGFloat = 4
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: ox + x * unit, y: oy + y * unit, width: w * unit, height: h * unit)
            }
            NSColor.black.setFill()
            let body = NSBezierPath(rect: r(0, 0, 12, 8))
            body.append(NSBezierPath(rect: r(-2, 4, 2, 2)))
            body.append(NSBezierPath(rect: r(12, 4, 2, 2)))
            for x: CGFloat in [1, 3, 8, 10] { body.append(NSBezierPath(rect: r(x, 8, 1, 2))) }
            body.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(rect: r(2, 2, 1, 2)).fill()
            NSBezierPath(rect: r(9, 2, 1, 2)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// MARK: - Seeing the interface (Accessibility)

// A plain function, not a global closure constant: in main.swift, globals below `app.run()` are never initialised.
private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue().axEvent(element, notification as String)
}

extension AppDelegate {
    @objc fileprivate func askAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { uiGranted(); return }
        trustTimer?.invalidate()
        // Wait for the switch in System Settings, then start without needing a relaunch.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            self?.uiGranted()
        }
    }

    private func uiGranted() {
        seeUI = true
        watch(NSWorkspace.shared.frontmostApplication)
        sendUI(["type": "granted"])
    }

    @objc fileprivate func toggleSeeUI() {
        seeUI.toggle()
        if uiOn { watch(NSWorkspace.shared.frontmostApplication) } else { stopWatching() }
        sendUI(["type": "status", "trusted": AXIsProcessTrusted(), "on": uiOn])
    }

    /// Listen to the front app only: focus moves, new windows and sheets, window title changes.
    func watch(_ app: NSRunningApplication?) {
        stopWatching()
        guard uiOn, let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.25)
        // Chromium browsers and Electron apps keep their accessibility tree off until a client asks for it.
        let manual = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        debugLog("watch \(app.localizedName ?? "?") manualAX=\(manual.rawValue)")
        var obs: AXObserver?
        guard AXObserverCreate(app.processIdentifier, axCallback, &obs) == .success, let obs else { return }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                  kAXWindowCreatedNotification, kAXSheetCreatedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(obs, el, n as CFString, ref)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        axObserver = obs
        axApp = el
        lastWindowTitle = ""
        if let win = attr(el, kAXFocusedWindowAttribute) { windowFocused(win as! AXUIElement) }
    }

    func stopWatching() {
        if let obs = axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode) }
        axObserver = nil
        axApp = nil
    }

    fileprivate func axEvent(_ el: AXUIElement, _ n: String) {
        debugLog("event \(n)")
        switch n {
        case kAXFocusedUIElementChangedNotification: focusChanged(el)
        case kAXFocusedWindowChangedNotification: windowFocused(el)
        case kAXWindowCreatedNotification, kAXSheetCreatedNotification: if isDialog(el) { reportDialog(el) }
        case kAXTitleChangedNotification: if string(el, kAXRoleAttribute) == kAXWindowRole { reportTitle(el) }
        default: break
        }
    }

    private func windowFocused(_ win: AXUIElement) {
        if isDialog(win) { reportDialog(win) }
        reportTitle(win)
    }

    private func reportTitle(_ win: AXUIElement) {
        guard let title = string(win, kAXTitleAttribute), !title.isEmpty, title != lastWindowTitle else { return }
        lastWindowTitle = title
        sendUI(["type": "window", "title": String(title.prefix(200))])
    }

    private func isDialog(_ el: AXUIElement) -> Bool {
        let role = string(el, kAXRoleAttribute), sub = string(el, kAXSubroleAttribute)
        return role == kAXSheetRole || sub == kAXDialogSubrole || sub == kAXSystemDialogSubrole
    }

    private func reportDialog(_ el: AXUIElement) {
        var texts: [String] = [], buttons: [String] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 6, texts.count < 8 else { return }
            let role = string(e, kAXRoleAttribute) ?? ""
            if role == kAXStaticTextRole, let v = string(e, kAXValueAttribute), !v.isEmpty { texts.append(String(v.prefix(200))) }
            if role == kAXButtonRole, buttons.count < 6, let t = string(e, kAXTitleAttribute), !t.isEmpty { buttons.append(t) }
            for c in ((attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(40) { walk(c, depth + 1) }
        }
        walk(el, 0)
        var msg: [String: Any] = ["type": "dialog", "title": string(el, kAXTitleAttribute) ?? "",
                                  "text": texts.joined(separator: " "), "buttons": buttons]
        if let r = pageRect(el) { msg["rect"] = r }
        sendUI(msg)
    }

    private func focusChanged(_ el: AXUIElement) {
        let role = string(el, kAXRoleAttribute) ?? "", sub = string(el, kAXSubroleAttribute) ?? ""
        let kind: String
        if sub == kAXSecureTextFieldSubrole { kind = "password" }
        else if sub == kAXSearchFieldSubrole || isInSearchField(el) { kind = "search" }
        else if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { kind = "text" }
        else { kind = "other" }
        var msg: [String: Any] = ["type": "focus", "kind": kind]
        if kind != "other", let r = pageRect(el) { msg["rect"] = r }
        sendUI(msg)
    }

    /// Standard search fields put focus on an inner text editor; the search subrole is on its parent.
    private func isInSearchField(_ el: AXUIElement) -> Bool {
        guard let parent = attr(el, kAXParentAttribute) else { return false }
        return string(parent as! AXUIElement, kAXSubroleAttribute) == kAXSearchFieldSubrole
    }

    /// The button, link or menu item under a resting cursor (its label only).
    fileprivate func checkHover(_ m: NSPoint) {
        guard uiOn, panel.isVisible else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(m.x), Float(primaryHeight - m.y), &found) == .success, let el = found else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let role = string(el, kAXRoleAttribute) ?? ""
        guard [kAXButtonRole, kAXMenuItemRole, kAXMenuButtonRole, kAXPopUpButtonRole, "AXLink"].contains(role) else { return }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute].lazy.compactMap { self.string(el, $0) }.first { !$0.isEmpty } ?? ""
        guard !label.isEmpty else { return }
        sendUI(["type": "hover", "role": role, "label": String(label.prefix(80))])
    }

    // MARK: helpers

    private func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

    private func pageRect(_ el: AXUIElement) -> [Int]? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        let f = panel.frame
        return [Int(pt.x - f.minX), Int(pt.y - pageTop), Int(sz.width), Int(sz.height)]
    }

    func sendUI(_ msg: [String: Any]) {
        debugLog("send \(msg)")
        guard let data = try? JSONSerialization.data(withJSONObject: msg), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.clawdNative && window.clawdNative.ui && window.clawdNative.ui(\(json))", completionHandler: nil)
    }
}


/// Off unless `defaults write local.deskclawd debugLog -bool true`; writes to ~/Library/Logs/DeskClawd.log.
func debugLog(_ m: String) {
    guard UserDefaults.standard.bool(forKey: "debugLog") else { return }
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DeskClawd.log")
    let line = Data("\(Date()) \(m)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { try? line.write(to: url) }
}
