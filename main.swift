// InputLock — a stealth keyboard & mouse lock.
//
// While locked the screen looks completely normal (no overlay); the mouse cursor
// still moves. But keystrokes, clicks, scrolling, trackpad gestures and media keys
// do nothing — and the instant anyone tries to interact, macOS's OWN Touch ID /
// login-password dialog appears. Authenticate to unlock. No sleep / no screen lock.
//
// Hotkey:  Control + Option + Command + L   (lock; when locked, opens the unlock dialog)
//
// Build:  see build.sh  (compiles, signs, installs ~/Applications/InputLock.app + login item)
// Logs:   log stream --predicate 'subsystem == "com.local.inputlock"'

import Cocoa
import LocalAuthentication
import IOKit.pwr_mgt
import ApplicationServices
import os

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

// The lock hotkey. Modifiers are fixed to Control+Option+Command.
// Common virtual keycodes:  L=37  K=40  J=38  space=49  \=42  '='=24
let HOTKEY_KEYCODE: Int64 = 37            // "L"

// Seconds to wait after a cancelled/failed attempt before the dialog may re-appear.
let AUTH_COOLDOWN: TimeInterval = 0.6

// Give up on a dialog nobody answers after this long (it re-appears on next touch).
let AUTH_TIMEOUT: TimeInterval = 120

// If macOS can't show the auth dialog this many times in a row, unlock rather than
// leave the Mac permanently unusable.
let MAX_AUTH_UNAVAILABLE = 3

// Keep the cursor this many pixels out of screen corners while locked (hot corners).
let CORNER_GUARD: CGFloat = 8

// Flash a small lock badge for ~1s when locking / unlocking.
let SHOW_LOCK_FLASH = true

let log = Logger(subsystem: "com.local.inputlock", category: "lock")

// ─────────────────────────────────────────────────────────────────────────────
// Event types we intercept (raw values — several have no CGEventType case).
// ─────────────────────────────────────────────────────────────────────────────
enum RawEvent {
    static let leftDown: UInt32 = 1, leftUp: UInt32 = 2, rightDown: UInt32 = 3, rightUp: UInt32 = 4
    static let moved: UInt32 = 5, leftDrag: UInt32 = 6, rightDrag: UInt32 = 7
    static let keyDown: UInt32 = 10, keyUp: UInt32 = 11, flags: UInt32 = 12
    static let systemDefined: UInt32 = 14            // media / brightness / volume keys
    static let rotate: UInt32 = 18, beginGesture: UInt32 = 19, endGesture: UInt32 = 20
    static let scroll: UInt32 = 22
    static let tabletPointer: UInt32 = 23, tabletProximity: UInt32 = 24
    static let otherDown: UInt32 = 25, otherUp: UInt32 = 26, otherDrag: UInt32 = 27
    static let gesture: UInt32 = 29, magnify: UInt32 = 30, swipe: UInt32 = 31
    static let smartMagnify: UInt32 = 32, quickLook: UInt32 = 33, pressure: UInt32 = 34
    static let directTouch: UInt32 = 37, changeMode: UInt32 = 38

    static let all: [UInt32] = [
        leftDown, leftUp, rightDown, rightUp, moved, leftDrag, rightDrag,
        keyDown, keyUp, flags, systemDefined, rotate, beginGesture, endGesture,
        scroll, tabletPointer, tabletProximity, otherDown, otherUp, otherDrag,
        gesture, magnify, swipe, smartMagnify, quickLook, pressure, directTouch, changeMode
    ]
    // Interactions that summon the unlock dialog.
    static let summons: Set<UInt32> = [keyDown, leftDown, rightDown, otherDown, scroll]
    // Plain keyboard traffic allowed through while the dialog is up (password entry).
    static let keyboard: Set<UInt32> = [keyDown, keyUp, flags]
}

// ─────────────────────────────────────────────────────────────────────────────
// Brief lock / unlock badge (like the volume HUD). Never takes clicks or focus.
// ─────────────────────────────────────────────────────────────────────────────
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var icon = NSImageView()
    private var label = NSTextField(labelWithString: "")
    private var generation = 0

    private func makePanel() -> NSPanel {
        let size: CGFloat = 160
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 18
        fx.layer?.masksToBounds = true

        icon.frame = NSRect(x: 40, y: 50, width: 80, height: 80)
        icon.symbolConfiguration = .init(pointSize: 56, weight: .semibold)
        icon.contentTintColor = .labelColor
        label.frame = NSRect(x: 0, y: 18, width: size, height: 24)
        label.alignment = .center
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .labelColor
        fx.addSubview(icon)
        fx.addSubview(label)
        p.contentView = fx
        return p
    }

    func show(locked: Bool) {
        guard SHOW_LOCK_FLASH else { return }
        let p = panel ?? makePanel()
        panel = p
        icon.image = NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open.fill",
                             accessibilityDescription: nil)
        label.stringValue = locked ? "Locked" : "Unlocked"

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + f.height * 0.18))
        }

        generation += 1
        let gen = generation
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
            guard let self = self, self.generation == gen else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 },
                completionHandler: { if self.generation == gen { p.orderOut(nil) } })
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// C callback trampoline for the CGEventTap.
// ─────────────────────────────────────────────────────────────────────────────
func tapCallback(proxy: CGEventTapProxy,
                 type: CGEventType,
                 event: CGEvent,
                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<LockController>.fromOpaque(refcon).takeUnretainedValue()
    return controller.handle(type: type, event: event)
}

// ─────────────────────────────────────────────────────────────────────────────
// Main controller (everything runs on the main thread)
// ─────────────────────────────────────────────────────────────────────────────
final class LockController: NSObject {

    private var locked = false
    private var authActive = false            // native auth dialog is up
    private var systemLocked = false          // macOS lock screen / other user session active
    private var lastAuthEnded = Date.distantPast
    private var authUnavailableCount = 0

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?

    private var displayAssertion: IOPMAssertionID = 0
    private var idleAssertion: IOPMAssertionID = 0

    private var laContext: LAContext?
    private var activityToken: NSObjectProtocol?
    private var displayBounds: [CGRect] = []

    // ── Startup ────────────────────────────────────────────────────────────
    func start() {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "InputLock keeps its input tap responsive")

        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            log.error("Not trusted for Accessibility")
            showAlert("Permission needed",
                "InputLock needs permission to lock the keyboard and mouse.\n\n" +
                "Open  System Settings ▸ Privacy & Security\n" +
                "  • Accessibility → enable InputLock\n" +
                "  • Input Monitoring → enable InputLock\n\n" +
                "Then reopen InputLock.")
            NSApp.terminate(nil)
            return
        }

        guard installTap() else {
            log.error("tapCreate failed")
            showAlert("Permission needed",
                "InputLock could not capture input events.\n\n" +
                "Enable InputLock under BOTH  System Settings ▸ Privacy & Security ▸ Accessibility  " +
                "and  Input Monitoring, then reopen InputLock.")
            NSApp.terminate(nil)
            return
        }

        refreshDisplays()
        observeSystem()

        watchdog = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkTap() }
        RunLoop.main.add(watchdog!, forMode: .common)

        log.notice("InputLock started (pid \(ProcessInfo.processInfo.processIdentifier))")

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "welcomeShown") {
            defaults.set(true, forKey: "welcomeShown")
            showAlert("InputLock is running",
                "Press  ⌃⌥⌘L  (Control-Option-Command-L) to lock.\n\n" +
                "The screen keeps looking normal and the cursor still moves, but typing, " +
                "clicking, scrolling, gestures and media keys do nothing. The moment anyone " +
                "tries to interact, macOS asks for Touch ID or your login password.\n\n" +
                "InputLock runs in the background with no icon.\n" +
                "To quit:  pkill -x InputLock")
        }
    }

    // ── Event tap ──────────────────────────────────────────────────────────
    private func installTap() -> Bool {
        var mask: CGEventMask = 0
        for t in RawEvent.all { mask |= (1 << CGEventMask(t)) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeTap() {
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        runLoopSource = nil
        eventTap = nil
    }

    /// Watchdog: make sure macOS hasn't silently disabled or killed our tap.
    private func checkTap() {
        guard let tap = eventTap, CFMachPortIsValid(tap) else {
            log.error("Event tap invalid — reinstalling")
            removeTap()
            if !installTap() { log.fault("Could not reinstall event tap") }
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            log.error("Event tap was disabled — re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        // A dialog nobody answered: cancel it so the next touch brings a fresh one.
        if authActive, let started = authStarted, let ctx = laContext,
           Date().timeIntervalSince(started) > AUTH_TIMEOUT {
            log.notice("Auth dialog timed out — cancelling")
            ctx.invalidate()
        }
    }
    private var authStarted: Date?

    // ── The tap callback ───────────────────────────────────────────────────
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.notice("Tap disabled by system (\(type.rawValue)) — re-enabling")
            if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }

        let raw = type.rawValue

        // macOS lock screen / fast user switch: never interfere with the real login.
        if systemLocked { return pass }

        if raw == RawEvent.keyDown && isHotkey(event) {
            DispatchQueue.main.async { self.locked ? self.presentAuth() : self.lock() }
            return nil
        }

        if !locked { return pass }

        // ---- Locked ----
        // Cursor keeps moving (so nothing looks amiss), kept clear of hot corners.
        if raw == RawEvent.moved {
            guardCorners(event)
            return pass
        }

        // Media / brightness / volume keys: swallow silently. Other system-defined
        // events (power button etc.) belong to macOS.
        if raw == RawEvent.systemDefined {
            return isAuxKey(event) ? nil : pass
        }

        // Dialog is up: allow plain typing for the password, nothing else (no clicks
        // — they'd fall through the non-modal dialog — and no ⌘/⌃ shortcuts).
        if authActive {
            if RawEvent.keyboard.contains(raw) {
                let f = event.flags
                if f.contains(.maskCommand) || f.contains(.maskControl) { return nil }
                return pass
            }
            return nil
        }

        if RawEvent.summons.contains(raw) {
            DispatchQueue.main.async { self.presentAuth() }
        }
        return nil
    }

    private func isHotkey(_ e: CGEvent) -> Bool {
        let f = e.flags
        return e.getIntegerValueField(.keyboardEventKeycode) == HOTKEY_KEYCODE
            && e.getIntegerValueField(.keyboardEventAutorepeat) == 0
            && f.contains(.maskCommand) && f.contains(.maskAlternate)
            && f.contains(.maskControl) && !f.contains(.maskShift)
    }

    private func isAuxKey(_ e: CGEvent) -> Bool {
        // NX_SUBTYPE_AUX_CONTROL_BUTTONS = 8 (media/volume/brightness/mission-control keys)
        return NSEvent(cgEvent: e)?.subtype.rawValue == 8
    }

    // ── Hot-corner guard ──────────────────────────────────────────────────
    private func refreshDisplays() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        displayBounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private func guardCorners(_ event: CGEvent) {
        let p = event.location
        for b in displayBounds where b.insetBy(dx: -1, dy: -1).contains(p) {
            let m = CORNER_GUARD
            let nearL = p.x < b.minX + m, nearR = p.x > b.maxX - 1 - m
            let nearT = p.y < b.minY + m, nearB = p.y > b.maxY - 1 - m
            if (nearL || nearR) && (nearT || nearB) {
                let q = CGPoint(x: nearL ? b.minX + m : b.maxX - 1 - m, y: p.y)
                event.location = q
                CGWarpMouseCursorPosition(q)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
            return
        }
    }

    // ── Lock / unlock ──────────────────────────────────────────────────────
    private func lock() {
        guard !locked else { return }
        locked = true
        authActive = false
        authUnavailableCount = 0
        preventSleep()
        HUD.shared.show(locked: true)
        log.notice("Locked")
    }

    private func unlock(_ why: String) {
        guard locked else { return }
        locked = false
        authActive = false
        authStarted = nil
        laContext?.invalidate()
        laContext = nil
        allowSleep()
        if why != "macOS screen unlocked" { HUD.shared.show(locked: false) }
        log.notice("Unlocked (\(why, privacy: .public))")
    }

    // ── Native macOS Touch ID / password dialog ───────────────────────────
    private func presentAuth() {
        guard locked, !authActive, !systemLocked else { return }
        guard Date().timeIntervalSince(lastAuthEnded) >= AUTH_COOLDOWN else { return }

        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            authUnavailableCount += 1
            log.error("Auth unavailable (\(err?.localizedDescription ?? "?", privacy: .public)) x\(self.authUnavailableCount)")
            lastAuthEnded = Date()
            if authUnavailableCount >= MAX_AUTH_UNAVAILABLE {
                unlock("authentication unavailable — failing safe")
            }
            return
        }
        authUnavailableCount = 0
        authActive = true
        authStarted = Date()
        laContext = ctx
        log.notice("Showing unlock dialog")

        NSApp.activate(ignoringOtherApps: true)
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "unlock the keyboard and mouse") { [weak self] ok, error in
            DispatchQueue.main.async {
                guard let self = self, self.laContext === ctx else { return }
                self.authActive = false
                self.authStarted = nil
                self.laContext = nil
                self.lastAuthEnded = Date()
                if ok {
                    self.unlock("authenticated")
                } else {
                    let code = (error as? LAError)?.code.rawValue ?? 0
                    log.notice("Auth not completed (LAError \(code)) — staying locked")
                }
            }
        }
    }

    // ── System events ───────────────────────────────────────────────────────
    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            log.notice("Woke from sleep")
            self?.checkTap()
        }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemLocked = true
        }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemLocked = false
            self?.checkTap()
        }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.systemLocked = true
            self.laContext?.invalidate()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.systemLocked = false
            // The owner just passed the real macOS login — no need to ask again.
            self.unlock("macOS screen unlocked")
            self.checkTap()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshDisplays() }
    }

    // ── Sleep / screensaver / auto-lock prevention ─────────────────────────
    private func preventSleep() {
        allowSleep()
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "InputLock: display awake" as CFString, &displayAssertion)
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "InputLock: system awake" as CFString, &idleAssertion)
    }

    private func allowSleep() {
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        if idleAssertion != 0 { IOPMAssertionRelease(idleAssertion); idleAssertion = 0 }
    }

    // ── Utility ─────────────────────────────────────────────────────────────
    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: LockController
    init(controller: LockController) { self.controller = controller }
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}

// Single instance: two taps would fight each other.
let me = ProcessInfo.processInfo.processIdentifier
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id)
       .contains(where: { $0.processIdentifier != me }) {
    log.notice("Another InputLock is already running — exiting")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; background agent
let controller = LockController()
let delegate = AppDelegate(controller: controller)
app.delegate = delegate
app.run()
