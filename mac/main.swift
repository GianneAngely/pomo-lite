import Cocoa
import WebKit

// Borderless window: only the console is visible
final class ConsoleWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Clicking the console body (not a button or the screen) drags the window
final class ConsoleView: WKWebView {
    var dragOK = false
    override func mouseDown(with event: NSEvent) {
        if dragOK { window?.performDrag(with: event) } else { super.mouseDown(with: event) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    let consoleWidth: CGFloat = 560 // console width in points; +56 leaves room for its shadow
    var window: ConsoleWindow!
    var web: ConsoleView!
    var activity: NSObjectProtocol?
    var timers: [String: DispatchSourceTimer] = [:]
    var sounds: [String: NSSound] = [:]
    var pomo = (phase: "focus", endAt: 0.0, focus: 0.0, brk: 0.0, long: 0.0, every: 4, round: 0, auto: true)
    var muted = false

    func applicationDidFinishLaunching(_ note: Notification) {
        // App Nap would delay the native timers, so keep it off while the app runs
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Pomodoro timer")
        buildMenu()

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "alarm")
        config.userContentController.add(self, name: "drag")
        config.userContentController.add(self, name: "mini")
        config.mediaTypesRequiringUserActionForPlayback = []
        #if SNAPSHOT
        debugConfig(config)
        #endif
        web = ConsoleView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        #if SNAPSHOT
        web.navigationDelegate = self
        #endif

        let size = NSSize(width: consoleWidth + 56, height: (consoleWidth * 0.44 + 56).rounded())
        window = ConsoleWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.title = "Pomo Lite"
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("PomoLite")
        window.setContentSize(size)

        let page = Bundle.main.url(forResource: "index", withExtension: "html")!
        web.loadHTMLString((try? String(contentsOf: page, encoding: .utf8)) ?? "", baseURL: URL(string: "https://pomolite.local/"))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        NSApp.activate(ignoringOtherApps: true)
    }

    func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Hide Pomo Lite", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Close Window", action: #selector(closeWindow), keyEquivalent: "w").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pomo Lite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem()
        item.submenu = menu
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(item)
    }

    // Closing only hides the window so alarms keep running; click the Dock icon to bring it back
    @objc func closeWindow() { window.orderOut(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    // Messages from index.html: alarm schedules per timer ("pomo" / "count") and the drag region
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "drag" { web.dragOK = message.body as? Bool ?? false; return }
        if message.name == "mini" { setMini(message.body as? Bool ?? false); return }
        if message.name == "log" { print(message.body); return }
        guard let m = message.body as? [String: Any], let kind = m["kind"] as? String else { return }
        muted = m["muted"] as? Bool ?? false
        if m["stop"] as? Bool == true { sounds[kind]?.stop() }
        let endAt = (m["endAt"] as? Double ?? 0) / 1000
        if kind == "pomo" {
            pomo = (m["phase"] as? String ?? "focus", endAt, (m["focus"] as? Double ?? 0) / 1000, (m["brk"] as? Double ?? 0) / 1000,
                    (m["long"] as? Double ?? 0) / 1000, m["every"] as? Int ?? 4, m["round"] as? Int ?? 0, m["auto"] as? Bool ?? true)
        }
        arm(kind, at: endAt)
    }

    // Mini mode: a small pill that stays above other windows; the top-left corner stays put
    func setMini(_ on: Bool) {
        let size = on ? NSSize(width: 280, height: 84) : NSSize(width: consoleWidth + 56, height: (consoleWidth * 0.44 + 56).rounded())
        var f = window.frame
        guard f.size != size else { return }
        f.origin.y += f.height - size.height
        f.size = size
        window.setFrame(f, display: true, animate: true)
        window.level = on ? .floating : .normal
    }

    // Wall-clock timers stay on time even when the window is hidden or the Mac wakes from sleep
    func arm(_ kind: String, at t: Double) {
        timers[kind]?.cancel()
        timers[kind] = nil
        let wait = t - Date().timeIntervalSince1970
        print("arm \(kind) \(t > 0 ? String(format: "%.1fs", wait) : "off")")
        guard t > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + max(0, wait), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.ring(kind) }
        timer.resume()
        timers[kind] = timer
    }

    func ring(_ kind: String) {
        var tune = "count"
        if kind == "pomo" {
            tune = pomo.phase == "focus" ? "break" : "focus" // focus just ended, so play the "break" tune
            // the cycle keeps going on its own (same rules as flip() in index.html); after sleep, skip ahead to the current phase
            let now = Date().timeIntervalSince1970, ok = pomo.focus > 0 && pomo.brk > 0
            repeat {
                if pomo.phase == "focus" {
                    pomo.round += 1
                    pomo.phase = pomo.round >= pomo.every ? "long" : "break"
                } else {
                    if pomo.phase == "long" { pomo.round = 0 }
                    pomo.phase = "focus"
                }
                pomo.endAt += pomo.phase == "focus" ? pomo.focus : pomo.phase == "long" && pomo.long > 0 ? pomo.long : pomo.brk
            } while ok && pomo.auto && pomo.endAt <= now
            arm("pomo", at: ok && pomo.auto ? pomo.endAt : 0) // auto-start off: the page waits for A
        } else {
            arm("count", at: 0)
        }
        print("ring \(tune)\(muted ? " (muted)" : "")")
        if !muted, let url = Bundle.main.url(forResource: tune, withExtension: "wav") {
            sounds[kind]?.stop()
            sounds[kind] = NSSound(contentsOf: url, byReference: true)
            sounds[kind]?.play()
        }
        _ = NSApp.requestUserAttention(.informationalRequest)
    }
}

#if SNAPSHOT
// Debug build (./build.sh --snapshot): logs JS errors, runs JS from POMO_JS, hides the window with POMO_HIDE,
// and saves a webview snapshot to POMO_SNAPSHOT. Handy for testing without Screen Recording permission.
extension AppDelegate: WKNavigationDelegate {
    func debugConfig(_ config: WKWebViewConfiguration) {
        setvbuf(stdout, nil, _IOLBF, 0)
        config.userContentController.add(self, name: "log")
        config.userContentController.addUserScript(WKUserScript(source: """
            addEventListener('error', e => webkit.messageHandlers.log.postMessage('JS error: ' + e.message));
            const ce = console.error;
            console.error = (...a) => { webkit.messageHandlers.log.postMessage('console.error: ' + a.join(' ')); ce(...a); };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let env = ProcessInfo.processInfo.environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let js = env["POMO_JS"] { webView.evaluateJavaScript(js) { r, e in print("js:", r ?? "nil", e.map { "\($0)" } ?? "") } }
            if env["POMO_HIDE"] != nil { self.window.orderOut(nil) }
            guard let out = env["POMO_SNAPSHOT"] else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["POMO_WAIT"] ?? "") ?? 1)) {
                webView.takeSnapshot(with: nil) { image, _ in
                    guard let tiff = image?.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return print("snapshot failed") }
                    try? png.write(to: URL(fileURLWithPath: out))
                    print("snapshot saved")
                }
            }
        }
    }
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
