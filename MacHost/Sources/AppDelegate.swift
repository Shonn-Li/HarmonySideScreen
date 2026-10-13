import Cocoa
import SwiftUI
import Combine
import ApplicationServices
import os.log
@preconcurrency import ScreenCaptureKit

// Debug file logger - writes to /tmp/harmonyscreen.log
func debugLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    print(message)
    if let data = line.data(using: .utf8) {
        let url = URL(fileURLWithPath: "/tmp/harmonyscreen.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Gesture State Machine

enum GestureState {
    case idle
    case pending          // Touch down, waiting to determine gesture
    case scrolling        // 1-finger scroll
    case longPressReady   // Long press detected, waiting for drag or release
    case dragging         // Long press + drag (left mouse drag)
    case twoFingerScroll  // 2-finger scroll
    case pinching         // Pinch zoom
}

struct GestureThresholds {
    static let tapMaxDistance: CGFloat = 15
    static let tapMaxTime: UInt64 = 250_000_000       // 250ms
    static let doubleTapMaxTime: UInt64 = 400_000_000  // 400ms
    static let doubleTapMaxDistance: CGFloat = 20
    static let longPressTime: UInt64 = 500_000_000     // 500ms
    static let scrollSensitivity: CGFloat = 1.2
    static let pinchMinDistance: CGFloat = 20
    static let minTouchInterval: UInt64 = 8_000_000    // ~120Hz
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var streamingServer: StreamingServer?
    var screenCapture: ScreenCapture?
    var virtualDisplayManager: VirtualDisplayManager?
    var settings = DisplaySettings()
    let supportPolicy = SupportPromptPolicy()
    var settingsWindow: SettingsWindowController?
    var statusItem: NSStatusItem?
    let pairedDeviceStore = PairedDeviceStore()
    /// Name of the wireless device currently streaming (nil when no wireless client is active).
    /// Used to roll its `lastConnected` timestamp forward every status refresh tick so the UI
    /// shows "just now" while connected and freezes at the disconnect moment afterward.
    private var currentWirelessDevice: String?
    private var cancellables = Set<AnyCancellable>()
    private var permissionCheckTimer: Timer?
    private var statusRefreshTimer: Timer?
    /// Reentrancy latch for startServer() — a second Start (double-clicked menu
    /// item, auto-start racing a manual click) must not build a second virtual
    /// display / server. Main-actor confined.
    private var isStartingServer = false
    private var streamRecovery = StreamRecoveryPolicy()
    /// The effective refresh rate the running pipeline was built with — lets
    /// the refresh-rate observer skip restarts that would change nothing.
    private var lastAppliedRefreshRate: Int?
    private var phoneGeometry: PhoneDisplayGeometry?
    private var appliedPhoneLayout: PhoneDisplayLayout?
    private var layoutWork: DispatchWorkItem?
    private var idleDisplayWork: DispatchWorkItem?
    private var displayPreparationTask: Task<Void, Never>?
    private var displayPreparationID: UUID?
    private var checkingUSB = false
    private var configuringUSB = false
    private var lastUSBDevices: [String] = []
    private var preservedDisplayOrigins: [CGDirectDisplayID: CGPoint] = [:]

    private func preserveOtherDisplays() {
        preservedDisplayOrigins = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayVendorNumber(id) != 0xEEED else { return nil }
            return (id, CGDisplayBounds(id).origin)
        })
    }

    private func restoreOtherDisplays() {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        for (id, p) in preservedDisplayOrigins where CGDisplayIsOnline(id) != 0 {
            CGConfigureDisplayOrigin(config, id, Int32(p.x), Int32(p.y))
        }
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    private var orientationCode: UInt8 {
        settings.phoneOrientation == "portrait" ? 1 : settings.phoneOrientation == "landscape" ? 2 : 0
    }

    private func referenceDisplay() -> CGDirectDisplayID {
        let main = CGMainDisplayID()
        if main != virtualDisplayManager?.displayID { return main }
        return NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }.first { CGDisplayIsBuiltin($0) != 0 } ?? main
    }

    private func phoneLayout() -> PhoneDisplayLayout? {
        guard settings.autoFitPhone, let phone = phoneGeometry else { return nil }
        let reference = referenceDisplay()
        return phone.layout(matchMac: settings.matchMacScale,
                            referenceBounds: CGDisplayBounds(reference), referenceMM: CGDisplayScreenSize(reference))
    }

    @discardableResult
    private func arrangePhoneDisplay(placement: PhonePlacement? = nil) -> Bool {
        guard settings.autoFitPhone || placement != nil else { return true }
        guard let manager = virtualDisplayManager, let id = manager.displayID else { return true }
        let bounds = CGDisplayBounds(id)
        let origin = DisplayPlacement.origin(reference: CGDisplayBounds(referenceDisplay()), desktop: bounds.size,
                                             side: placement?.side ?? settings.placementSide,
                                             alignment: placement?.alignment ?? settings.placementAlignment)
        let snapped = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        if bounds.origin != snapped {
            do { try manager.setDisplayPosition(x: Int32(snapped.x), y: Int32(snapped.y)) }
            catch { debugLog("Could not move phone display: \(error)"); return false }
        }
        return true
    }

    private func schedulePhoneLayout() {
        layoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isStartingServer || self.displayPreparationTask != nil { self.schedulePhoneLayout(); return }
            let layout = self.phoneLayout()
            if let layout {
                var summary = "\(layout.pixelWidth) × \(layout.pixelHeight) pixels · desktop \(layout.logicalWidth) × \(layout.logicalHeight)"
                if let mm = layout.millimeters {
                    summary += String(format: "\nEstimated panel %.1f × %.1f cm", mm.width / 10, mm.height / 10)
                } else { summary += "\nPanel DPI unavailable; using native Retina size" }
                self.settings.phoneSizeSummary = summary
            }
            guard self.settings.isRunning, self.settings.displayCreated else { return }
            if layout != self.appliedPhoneLayout {
                self.restartRunningServer(reason: "Phone or Mac display geometry changed")
            } else {
                self.arrangePhoneDisplay()
                self.streamingServer?.sendPhonePlacement(PhonePlacement(side: self.settings.placementSide,
                                                                        alignment: self.settings.placementAlignment))
            }
        }
        layoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(900), execute: work)
    }

    var isDaemonMode = false // Deprecated: keeping variable for ABI compatibility but unused

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("✅ App launched")

        // Create menu bar item
        setupMenuBar()

        // Setup settings window
        setupSettingsWindow()

        // Setup settings observers
        setupSettingsObservers()
        if let values = UserDefaults.standard.array(forKey: "HarmonyScreen_phoneGeometry") as? [Double], values.count == 4,
           (320...8192).contains(values[0]), (320...8192).contains(values[1]) {
            phoneGeometry = PhoneDisplayGeometry(width: Int(values[0]), height: Int(values[1]), dpiX: values[2], dpiY: values[3])
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.schedulePhoneLayout() }.store(in: &cancellables)
        Publishers.CombineLatest(settings.$autoFitPhone, settings.$matchMacScale)
            .dropFirst().sink { [weak self] _ in self?.schedulePhoneLayout() }.store(in: &cancellables)
        Publishers.CombineLatest(settings.$placementSide, settings.$placementAlignment)
            .dropFirst().sink { [weak self] _ in
                self?.schedulePhoneLayout()
            }.store(in: &cancellables)
        settings.$phoneOrientation.dropFirst().sink { [weak self] value in
            self?.streamingServer?.setPhoneOrientation(value == "portrait" ? 1 : value == "landscape" ? 2 : 0)
        }.store(in: &cancellables)

        // Check permissions
        Task {
            await checkPermissions()
        }

        // Periodic status refresh for the per-mode checklist (ADB / WiFi / Listening IP).
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatusIndicators()
            }
        }
        // Initial refresh so the UI isn't blank for 2 seconds.
        Task { @MainActor in
            refreshStatusIndicators()
        }

        if #available(macOS 13.0, *) {
            if DaemonManager.shared.isEnabled {
                print("🚀 Launch at Login is enabled - starting silently in background")
                // Do not show settings window automatically.
                // applicationShouldHandleReopen will show it if the user manually launched the app.
            } else {
                showSettings()
            }
        } else {
            showSettings()
        }

        // Declarative auto-start (no Mac interaction): start the server in the
        // chosen Startup mode if enabled. No blocking permission modal here —
        // it cannot be acted on when the Mac is headless.
        if settings.autoStartStreamingOnLaunch {
            settings.connectionMode = settings.startupMode
            Task {
                await self.checkPermissions()
                if self.settings.hasScreenRecordingPermission {
                    await self.startServer()
                } else {
                    debugLog("Auto-start skipped: Screen Recording permission not granted")
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showSettings()
        }
        return true
    }

    @MainActor
    private func refreshStatusIndicators() {
        if !settings.isRunning, !isStartingServer,
           streamRecovery.shouldRetry(at: ProcessInfo.processInfo.systemUptime) {
            Task { @MainActor [weak self] in
                guard let self, self.streamRecovery.shouldRetry(at: ProcessInfo.processInfo.systemUptime) else { return }
                await self.startServer(continuingSupportSession: true)
            }
        }
        settings.hdcInstalled = StatusDetector.hdcInstalled()
        settings.wifiConnected = StatusDetector.wifiReachable()
        settings.listeningAddress = LANAddressResolver.primaryIPv4()

        // "Displays have separate Spaces" off → any fullscreen app blanks the
        // virtual display (#50). Nothing we can do about it from capture side;
        // surface it so the user knows why the tablet went black.
        let separateSpaces = NSScreen.screensHaveSeparateSpaces
        if separateSpaces != settings.displaysHaveSeparateSpaces {
            settings.displaysHaveSeparateSpaces = separateSpaces
            if !separateSpaces {
                debugLog("WARNING: 'Displays have separate Spaces' is OFF — fullscreen apps on the Mac will blank the tablet (#50)")
            }
        }

        // While a wireless client is actively streaming, keep its lastConnected
        // rolling forward so the UI shows "just now". On disconnect, the
        // onClientDisconnected handler clears currentWirelessDevice — from that
        // point lastConnected stays frozen at the disconnect moment, so the
        // "X minutes ago" label counts up correctly.
        if let name = currentWirelessDevice {
            pairedDeviceStore.upsert(name: name, lastConnected: Date())
        }

        guard !checkingUSB else { return }
        checkingUSB = true
        let port = Int(settings.port)
        Task.detached { [weak self] in
            let snapshot = HDCBridge.snapshot(port: port)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.checkingUSB = false
                guard Int(self.settings.port) == port, let snapshot else { return }
                let devices = snapshot.devices
                let reverseOK = snapshot.reverseConfigured
                if !self.lastUSBDevices.isEmpty && self.lastUSBDevices != devices {
                    debugLog("USB device disappeared or changed — ending its display session")
                    self.streamingServer?.disconnectUSBClient()
                }
                self.lastUSBDevices = devices
                
                let isConnected = !devices.isEmpty

                self.settings.usbDeviceConnected = isConnected
                self.settings.hdcReverseConfigured = reverseOK

                // Self-healing USB bridge (level-triggered, not edge-triggered):
                // whenever the server is running and an authorized device is
                // present but HDC reverse is missing, (re)establish it. Wireless
                // mode also accepts loopback clients; it must not disable USB.
                // Covers replug, HDC server restart, etc. The server lifecycle
                // is NOT tied to device events — it stays up and the tablet
                // reconnects via its own connect button.
                if isConnected
                    && self.settings.isRunning
                    && !reverseOK {
                    debugLog("🔌 USB bridge missing while running — (re)establishing HDC reverse")
                    Task { await self.setupHDCReverse() }
                }
            }
        }
    }

    @MainActor
    private func handleConnectionModeChange(to mode: ConnectionMode) async {
        debugLog("Connection mode changed to: \(mode.rawValue)")
        // Disconnect any active client immediately (per spec §6 / fix #2).
        let wasRunning = settings.isRunning
        if wasRunning {
            stopServer()
        }
        if mode == .wireless {
            // Generate token if missing; the QR will reflect it.
            _ = WirelessAuth.loadOrCreate()
        }
        if wasRunning {
            await startServer(continuingSupportSession: true)
        }
    }

    /// Check permissions on demand (called when settings window opens or manually)
    func refreshPermissions() {
        Task {
            await checkPermissions()
        }
    }

    func setupSettingsObservers() {
        // Observer cho gaming boost changes
        settings.$gamingBoost
            .dropFirst() // Skip initial value
            .sink { [weak self] gamingBoost in
                guard let self = self, self.settings.isRunning else { return }
                print("🎮 Gaming Boost \(gamingBoost ? "ENABLED" : "DISABLED")")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: self.settings.effectiveBitrate,
                    quality: self.settings.effectiveQuality,
                    gamingBoost: gamingBoost
                )
            }
            .store(in: &cancellables)

        // Observer cho bitrate/quality changes (chỉ khi không gaming boost)
        Publishers.CombineLatest(settings.$bitrate, settings.$quality)
            .dropFirst()
            .sink { [weak self] bitrate, quality in
                guard let self = self, self.settings.isRunning, !self.settings.gamingBoost else { return }
                print("⚙️ Settings updated: \(bitrate)Mbps, \(quality)")
                self.screenCapture?.updateEncoderSettings(
                    bitrateMbps: bitrate,
                    quality: quality,
                    gamingBoost: false
                )
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(settings.$rotation, settings.$flipHorizontal, settings.$flipVertical)
            .dropFirst()
            .sink { [weak self] rotation, flipHorizontal, flipVertical in
                guard let self = self, self.settings.isRunning else { return }
                print("🔄 Display transform changed: \(rotation)°, h=\(flipHorizontal), v=\(flipVertical)")
                self.streamingServer?.updateDisplayTransform(rotation: rotation, flipHorizontal: flipHorizontal, flipVertical: flipVertical)
            }
            .store(in: &cancellables)

        // Observer cho touch enable/disable - propagate to streaming server so
        // incoming touch frames from the client are dropped early when off.
        settings.$touchEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.streamingServer?.touchEnabled = enabled
            }
            .store(in: &cancellables)

        // Observer cho connection mode changes — restart server with new auth/ADB policy.
        settings.$connectionMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.handleConnectionModeChange(to: mode)
                }
            }
            .store(in: &cancellables)

        // Observer cho resolution changes — the virtual display is created at
        // server start, so a new resolution (list row or custom Apply) needs a
        // stop/start cycle to take effect, same as a connection-mode change.
        // Without this, changing resolution mid-run silently did nothing.
        settings.$resolution
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] resolution in
                self?.restartRunningServer(reason: "Resolution changed to \(resolution)")
            }
            .store(in: &cancellables)

        // Refresh rate shapes the virtual display mode AND the capture
        // interval, so it needs the same rebuild as a resolution change.
        // Debounced: the custom-FPS slider (issue #41) emits continuously
        // while dragging — restart once the value settles. The effective-rate
        // guard skips no-op restarts (drag ends back on the applied value, or
        // Gaming Boost is pinning the rate to 120).
        settings.$refreshRate
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(1.2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    let effective = self.settings.effectiveRefreshRate
                    guard effective != self.lastAppliedRefreshRate else { return }
                    self.restartRunningServer(reason: "Refresh rate changed to \(effective) Hz")
                }
            }
            .store(in: &cancellables)
    }

    /// Stop-and-restart the server to rebuild the virtual display and capture
    /// pipeline. No-op while stopped.
    private func restartRunningServer(reason: String) {
        Task { @MainActor in
            guard self.settings.isRunning, self.settings.displayCreated else { return }
            debugLog("\(reason) — restarting server to rebuild virtual display")
            self.preserveOtherDisplays()
            self.tearDownServerResources(saveDisplayPosition: true, keepDisplay: true)
            self.restoreOtherDisplays()
            await self.startServer(continuingSupportSession: true)
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Harmony Side Screen")
        }

        // Items are rebuilt on every open (menuNeedsUpdate) so the menu always
        // reflects live server/connection state.
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem?.menu = menu

        // Dim the menu bar icon while the server is stopped — at-a-glance
        // state without opening the menu.
        settings.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.statusItem?.button?.appearsDisabled = !running
            }
            .store(in: &cancellables)
    }

    @objc private func toggleServerFromMenu() {
        if settings.isRunning || settings.isRecovering {
            stopServer()
        } else {
            Task { [weak self] in
                await self?.startServer()
            }
        }
    }

    @objc private func selectUSBMode() {
        guard settings.connectionMode != .usb else { return }
        settings.connectionMode = .usb
    }

    @objc private func selectWirelessMode() {
        guard settings.connectionMode != .wireless else { return }
        settings.connectionMode = .wireless
    }

    func setupSettingsWindow() {
        settingsWindow = SettingsWindowController(settings: settings)

        settings.onToggleServer = { [weak self] in
            guard let self else { return }
            if self.settings.isRunning || self.settings.isRecovering {
                self.stopServer()
            } else {
                Task { [weak self] in
                    await self?.startServer()
                }
            }
        }
    }

    @objc func showSettings() {
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func checkPermissions() async {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        debugLog("checkPermissions — macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")

        // Check Screen Recording permission using CoreGraphics API
        let hasScreenCapture = CGPreflightScreenCaptureAccess()
        await MainActor.run {
            settings.hasScreenRecordingPermission = hasScreenCapture
        }
        if hasScreenCapture {
            debugLog("Screen recording permission granted (CGPreflight)")

            // On macOS 26+, also verify ScreenCaptureKit is actually functional
            if version.majorVersion >= 26 {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    debugLog("SCShareableContent verification OK — \(content.displays.count) displays found")
                } catch {
                    debugLog("WARNING: CGPreflight OK but SCShareableContent failed on macOS 26: \(error.localizedDescription)")
                    debugLog("CGDisplayStream fallback will likely activate at capture time")
                }
            }
        } else {
            debugLog("Screen recording permission not granted yet")
            CGRequestScreenCaptureAccess()
        }

        // Check Accessibility permission (required for touch/mouse injection)
        await checkAccessibilityPermission()
    }

    func checkAccessibilityPermission() async {
        let trusted = AXIsProcessTrusted()
        await MainActor.run {
            settings.hasAccessibilityPermission = trusted
        }
        if trusted {
            print("✅ Accessibility permission granted")
        } else {
            print("⚠️  Accessibility permission not granted - touch control will not work")
        }
    }

    @MainActor
    func promptAccessibilityPermission() {
        // This will show the system prompt to grant Accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        settings.hasAccessibilityPermission = trusted

        if !trusted {
            print("⚠️  User needs to grant Accessibility permission in System Settings")
        }
    }

    /// Establish the existing HDC reverse tunnel; do not implement USB authentication ourselves.
    @MainActor
    func setupHDCReverse() async {
        guard !configuringUSB else { return }
        configuringUSB = true
        defer { configuringUSB = false }
        let port = Int(settings.port)
        let result = await Task.detached(priority: .utility) {
            HDCBridge.configure(port: port)
        }.value
        debugLog(result ? "HDC USB tunnel ready" : "HDC tunnel unavailable: connect exactly one authorized USB device")
    }

    @MainActor
    func showPermissionAlert() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let isMacOS26 = version.majorVersion >= 26

        let alert = NSAlert()
        if isMacOS26 {
            alert.messageText = "Screen & System Audio Recording Permission Required"
            alert.informativeText = "Please grant Screen & System Audio Recording permission in System Settings > Privacy & Security."
        } else {
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "Please grant Screen Recording permission in System Settings > Privacy & Security."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    @MainActor
    func startServer(continuingSupportSession: Bool = false) async {
        let canStart = await MainActor.run { () -> Bool in
            guard !isStartingServer, !settings.isRunning else { return false }
            isStartingServer = true
            return true
        }
        guard canStart else {
            debugLog("startServer() ignored — already starting or already running")
            return
        }
        defer { isStartingServer = false }
        streamRecovery.requestStart(continuing: continuingSupportSession)
        debugLog("🚀 startServer() invoked. Check permission: \(settings.hasScreenRecordingPermission)")
        guard settings.hasScreenRecordingPermission else {
            debugLog("❌ startServer aborted: Missing Screen Recording permission")
            streamRecovery.stop()
            settings.isRecovering = false
            settings.streamError = "Allow Screen Recording in System Settings, then click Start."
            return
        }

        do {
            // Listening does not require an active virtual monitor or capture.
            await setupHDCReverse()
            guard streamRecovery.requested else { return }
            // Setup server
            streamingServer = StreamingServer(port: settings.port)
            streamingServer?.onPhonePlacement = { [weak self, weak server = streamingServer] placement in
                DispatchQueue.main.async {
                    guard let self, let server, self.streamingServer === server else { return }
                    if let placement, self.arrangePhoneDisplay(placement: placement) {
                        self.settings.placementSide = placement.side
                        self.settings.placementAlignment = placement.alignment
                        self.virtualDisplayManager?.saveDisplayPosition()
                    }
                    server.sendPhonePlacement(PhonePlacement(side: self.settings.placementSide,
                                                             alignment: self.settings.placementAlignment))
                }
            }
            streamingServer?.touchEnabled = settings.touchEnabled
            streamingServer?.phoneOrientation = orientationCode
            streamingServer?.onPhoneViewport = { [weak self] geometry in
                DispatchQueue.main.async {
                    guard let self, self.phoneGeometry != geometry else { return }
                    self.phoneGeometry = geometry
                    UserDefaults.standard.set([Double(geometry.width), Double(geometry.height), geometry.dpiX, geometry.dpiY], forKey: "HarmonyScreen_phoneGeometry")
                    debugLog("Phone viewport: \(geometry.width)x\(geometry.height), reported DPI \(geometry.dpiX)x\(geometry.dpiY)")
                    self.schedulePhoneLayout()
                }
            }
            if settings.connectionMode == .wireless {
                streamingServer?.expectedAuthToken = WirelessAuth.loadOrCreate()
                configurePairingCode(on: streamingServer)
                streamingServer?.onWirelessClientPaired = { [weak self] deviceName in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.currentWirelessDevice = deviceName
                        self.settings.currentWirelessDevice = deviceName
                        self.pairedDeviceStore.upsert(name: deviceName, lastConnected: Date())
                    }
                }
            }
            streamingServer?.onPrepareStream = { [weak self, weak server = streamingServer] codec, completion in
                DispatchQueue.main.async {
                    guard let self, let server, self.streamingServer === server else { completion(false); return }
                    self.idleDisplayWork?.cancel()
                    let previous = self.displayPreparationTask
                    previous?.cancel()
                    let preparationID = UUID()
                    self.displayPreparationID = preparationID
                    self.displayPreparationTask = Task { @MainActor in
                        await previous?.value
                        defer {
                            if self.displayPreparationID == preparationID {
                                self.displayPreparationTask = nil
                                self.displayPreparationID = nil
                            }
                        }
                        do {
                            try await self.prepareDisplay(for: server, codec: codec)
                            completion(true)
                        } catch {
                            if self.displayPreparationID == preparationID && self.streamingServer === server {
                                self.removeIdleDisplay()
                                if !(error is CancellationError) {
                                    debugLog("Display preparation failed: \(error.localizedDescription)")
                                    self.settings.streamError = "Could not prepare the display. Reconnect to retry. \(error.localizedDescription)"
                                }
                            }
                            completion(false)
                        }
                    }
                }
            }
            streamingServer?.onClientConnected = { [weak self, weak server = streamingServer] in
                DispatchQueue.main.async {
                    guard let self, let server, self.streamingServer === server else { return }
                    self.idleDisplayWork?.cancel()
                    self.settings.clientConnected = true
                    self.screenCapture?.requestKeyframeOrReplayCachedFrame(force: true)
                }
            }
            streamingServer?.onCodecNegotiated = { [weak self, weak server = streamingServer] codec in
                guard let self, let server, self.streamingServer === server, let capture = self.screenCapture else { return }
                capture.negotiate(codec: codec, clientLimit: server.clientDecodeLimits)
                let enc = capture.encodeSize(for: codec)
                server.setDisplaySize(width: enc.width, height: enc.height,
                    rotation: self.appliedPhoneLayout == nil ? self.settings.rotation : 0,
                    flipHorizontal: self.appliedPhoneLayout == nil && self.settings.flipHorizontal,
                    flipVertical: self.appliedPhoneLayout == nil && self.settings.flipVertical)
            }
            streamingServer?.onKeyframeRequested = { [weak self] force in
                self?.screenCapture?.requestKeyframeOrReplayCachedFrame(force: force)
            }

            streamingServer?.onClientDisconnected = { [weak self, weak server = streamingServer] in
                DispatchQueue.main.async {
                    guard let self, let server, self.streamingServer === server else { return }
                    self.settings.clientConnected = false
                    self.displayPreparationTask?.cancel()
                    self.scheduleIdleDisplayRemoval()
                    self.supportPolicy.pauseCounting()
                    // Final lastConnected snapshot at the disconnect moment, then
                    // freeze (currentWirelessDevice = nil stops the rolling update
                    // in refreshStatusIndicators).
                    if let name = self.currentWirelessDevice {
                        self.pairedDeviceStore.upsert(name: name, lastConnected: Date())
                        self.currentWirelessDevice = nil
                        self.settings.currentWirelessDevice = nil
                    }
                }
            }

            streamingServer?.onTouchEvent = { [weak self] x, y, action, pointerCount, x2, y2 in
                self?.handleTouch(x: x, y: y, action: action, pointerCount: pointerCount, x2: x2, y2: y2)
            }

            streamingServer?.onStats = { [weak self] fps, mbps in
                let captured = self
                Task { @MainActor in
                    captured?.settings.currentFPS = fps
                    captured?.settings.currentBitrate = mbps
                    if let self = captured {
                        self.supportPolicy.observeFrames(at: ProcessInfo.processInfo.systemUptime,
                                                         connected: self.settings.clientConnected, fps: fps)
                    }
                }
            }

            guard let server = streamingServer else {
                throw NSError(
                    domain: "HarmonyScreen.Startup",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The streaming server could not be created."]
                )
            }
            try await server.start()
            guard streamRecovery.requested else {
                tearDownServerResources(saveDisplayPosition: false)
                return
            }
            await MainActor.run {
                supportPolicy.beginSession(continuing: continuingSupportSession)
                streamRecovery.started()
                settings.isRecovering = false
                settings.streamError = nil
                settings.isRunning = true
            }

            if settings.displayCreated { scheduleIdleDisplayRemoval() }
            print("✅ Server started on port \(settings.port)")
        } catch {
            debugLog("Failed to start stream: \(error.localizedDescription)")
            await MainActor.run {
                self.tearDownServerResources(saveDisplayPosition: false)
                streamRecovery.failed(at: ProcessInfo.processInfo.systemUptime)
                settings.isRecovering = streamRecovery.requested
                settings.streamError = streamRecovery.requested ?
                    "Reconnecting automatically. \(error.localizedDescription)" : nil
            }
        }
    }

    @MainActor
    private func checkDisplayPreparation(for server: StreamingServer) throws {
        try Task.checkCancellation()
        guard streamRecovery.requested, streamingServer === server else { throw CancellationError() }
    }

    @MainActor
    private func prepareDisplay(for server: StreamingServer, codec: StreamCodec) async throws {
        try checkDisplayPreparation(for: server)
        screenCapture?.stopStreaming()
        screenCapture = nil
        preserveOtherDisplays()
        // Reuse display identity across short reconnects and layout changes.
        if virtualDisplayManager == nil { virtualDisplayManager = VirtualDisplayManager() }
        let layout = phoneLayout()
        appliedPhoneLayout = layout
        let size = layout.map { (width: $0.logicalWidth, height: $0.logicalHeight) } ?? settings.resolutionSize
        try virtualDisplayManager?.createDisplay(
            width: size.width,
            height: size.height,
            refreshRate: settings.refreshRate,
            hiDPI: layout != nil || settings.hiDPI,
            name: "HarmonyScreen",
            physicalSizeMM: layout?.millimeters
        )

        // Disable mirror mode (may fail if already in extend mode)
        do {
            try virtualDisplayManager?.disableMirrorMode()
        } catch {
            // Not critical - continue anyway
        }

        await MainActor.run {
            settings.displayCreated = true
        }

        try await Task.sleep(nanoseconds: 500_000_000)
        try checkDisplayPreparation(for: server)

        try virtualDisplayManager?.selectMode(width: size.width, height: size.height, hiDPI: layout != nil || settings.hiDPI)
        restoreOtherDisplays()
        virtualDisplayManager?.restoreDisplayPosition()
        arrangePhoneDisplay()

        // Verify display is registered in the system
        if let vdm = virtualDisplayManager {
            let registered = vdm.verifyDisplayRegistered()
            if !registered {
                debugLog("WARNING: Virtual display not found in online display list — capture may fail")
            }
        }

        // Setup capture
        guard let displayID = virtualDisplayManager?.displayID else {
            throw NSError(
                domain: "HarmonyScreen.Startup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The virtual display was created without a display ID."]
            )
        }
        let capture = try await ScreenCapture()
        var prepared = false
        defer { if !prepared { capture.stopStreaming() } }
        try checkDisplayPreparation(for: server)
        screenCapture = capture
        capture.onCaptureMethodChanged = { [weak self, weak capture] method in
            DispatchQueue.main.async {
                guard let self, self.screenCapture === capture else { return }
                self.settings.captureMethod = method
            }
        }
        if let layout { capture.panelOutputSize = (layout.pixelWidth, layout.pixelHeight) }
        lastAppliedRefreshRate = settings.effectiveRefreshRate
        try await capture.setupForVirtualDisplay(displayID, refreshRate: settings.effectiveRefreshRate)
        try checkDisplayPreparation(for: server)
        capture.negotiate(codec: codec, clientLimit: server.clientDecodeLimits)
        let encoded = capture.encodeSize(for: codec)
        server.setDesktopSize(width: size.width, height: size.height)
        server.setDisplaySize(width: encoded.width, height: encoded.height,
            rotation: layout == nil ? settings.rotation : 0,
            flipHorizontal: layout == nil && settings.flipHorizontal,
            flipVertical: layout == nil && settings.flipVertical)
        capture.startStreaming(to: server, bitrateMbps: settings.effectiveBitrate,
            quality: settings.effectiveQuality, gamingBoost: settings.gamingBoost,
            frameRate: settings.effectiveRefreshRate)
        prepared = true
        settings.streamError = nil
    }

    @MainActor
    private func scheduleIdleDisplayRemoval() {
        idleDisplayWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.settings.clientConnected else { return }
            self.displayPreparationTask?.cancel()
            self.removeIdleDisplay()
        }
        idleDisplayWork = work
        // Brief transport/rotation reconnects should not move the user's windows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func removeIdleDisplay() {
        guard virtualDisplayManager != nil || screenCapture != nil else { return }
        debugLog("No display client — removing virtual display; listener stays ready")
        virtualDisplayManager?.saveDisplayPosition()
        screenCapture?.stopStreaming()
        screenCapture = nil
        virtualDisplayManager?.destroyDisplay()
        virtualDisplayManager = nil
        settings.displayCreated = false
        settings.currentFPS = 0
        settings.currentBitrate = 0
        settings.captureMethod = "Waiting for phone"
    }

    /// Code pairing (issue #35): issue a fresh one-time code for this wireless
    /// session. The server consumes/invalidates the code atomically on its
    /// network queue (one-time use, 5-attempt budget); these callbacks only
    /// install the replacement.
    private func configurePairingCode(on server: StreamingServer?) {
        guard let server = server else { return }
        rotatePairingCode(on: server)
        server.pairingMacName = Host.current().localizedName ?? "Mac"
        server.onPairingSuccess = { [weak self, weak server] deviceName in
            guard let self = self else { return }
            self.rotatePairingCode(on: server)
            Task { @MainActor in
                self.pairedDeviceStore.upsert(name: deviceName, lastConnected: Date())
            }
        }
        server.onPairingCodeExhausted = { [weak self, weak server] in
            debugLog("Pairing attempt budget exhausted — rotating code")
            self?.rotatePairingCode(on: server)
        }
    }

    private func rotatePairingCode(on server: StreamingServer?) {
        let code = PairingCode.generate()
        server?.expectedPairingCode = code
        Task { @MainActor in
            // A rotation queued just before Stop must not resurrect the code
            // in the UI after stopServer() cleared it.
            guard self.settings.isRunning || self.isStartingServer else { return }
            self.settings.pairingCode = code
        }
    }

    private func tearDownServerResources(saveDisplayPosition: Bool, keepDisplay: Bool = false) {
        supportPolicy.endedSession()
        idleDisplayWork?.cancel()
        displayPreparationID = nil
        displayPreparationTask?.cancel()
        displayPreparationTask = nil
        if saveDisplayPosition {
            virtualDisplayManager?.saveDisplayPosition()
        }
        settings.pairingCode = nil
        streamingServer?.expectedPairingCode = nil

        screenCapture?.stopStreaming()
        streamingServer?.stop()
        if !keepDisplay { virtualDisplayManager?.destroyDisplay() }

        screenCapture = nil
        streamingServer = nil
        if !keepDisplay { virtualDisplayManager = nil }
        currentWirelessDevice = nil

        settings.isRunning = false
        settings.displayCreated = keepDisplay && virtualDisplayManager?.displayID != nil
        settings.clientConnected = false
        settings.currentWirelessDevice = nil
        settings.currentFPS = 0
        settings.currentBitrate = 0
    }

    func stopServer() {
        streamRecovery.stop()
        settings.isRecovering = false
        settings.streamError = nil
        tearDownServerResources(saveDisplayPosition: true)

        print("⏹️ Server stopped")
    }

    // MARK: - Gesture Properties

    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var accessibilityWarningShown = false
    private var gestureState: GestureState = .idle
    private var lastTouchTime: UInt64 = 0

    // Touch tracking
    private var touchStartPosition: CGPoint = .zero
    private var touchLastPosition: CGPoint = .zero
    private var touchStartTime: UInt64 = 0
    private var touchLastMoveTime: UInt64 = 0
    private var lastScrollDeltaX: CGFloat = 0
    private var lastScrollDeltaY: CGFloat = 0

    // Double tap tracking
    private var lastTapTime: UInt64 = 0
    private var lastTapPosition: CGPoint = .zero

    // Long press timer
    private var longPressTimer: DispatchWorkItem?

    // 2-finger tracking
    private var initialPinchDistance: CGFloat = 0
    private var lastPinchDistance: CGFloat = 0

    // Momentum scrolling
    private var momentumTimer: Timer?
    private var momentumVelocityX: CGFloat = 0
    private var momentumVelocityY: CGFloat = 0
    private var lastMomentumPosition: CGPoint = .zero

    // MARK: - Touch Entry Point

    func handleTouch(x: Float, y: Float, action: Int, pointerCount: Int = 1, x2: Float = 0, y2: Float = 0) {
        guard settings.touchEnabled else { return }

        if !AXIsProcessTrusted() {
            if !accessibilityWarningShown {
                accessibilityWarningShown = true
                print("⚠️  Accessibility not granted - touch ignored")
                Task { @MainActor in
                    settings.hasAccessibilityPermission = false
                }
            }
            return
        }

        guard let displayID = virtualDisplayManager?.displayID else { return }
        let bounds = CGDisplayBounds(displayID)

        let p1 = CGPoint(
            x: bounds.origin.x + CGFloat(x) * bounds.width,
            y: bounds.origin.y + CGFloat(y) * bounds.height
        )
        let p2 = CGPoint(
            x: bounds.origin.x + CGFloat(x2) * bounds.width,
            y: bounds.origin.y + CGFloat(y2) * bounds.height
        )

        if pointerCount >= 2 {
            handleTwoFingerTouch(p1: p1, p2: p2, action: action)
        } else {
            handleOneFingerTouch(at: p1, action: action)
        }
    }

    // MARK: - 1-Finger Gesture State Machine

    private func handleOneFingerTouch(at point: CGPoint, action: Int) {
        switch action {
        case 0: oneFingerDown(at: point)
        case 1: oneFingerMove(to: point)
        case 2: oneFingerUp(at: point)
        default: break
        }
    }

    private func oneFingerDown(at point: CGPoint) {
        stopMomentumScroll()
        cancelLongPressTimer()

        touchStartPosition = point
        touchLastPosition = point
        touchStartTime = DispatchTime.now().uptimeNanoseconds
        touchLastMoveTime = touchStartTime
        gestureState = .pending

        // Move cursor to touch position (absolute)
        moveCursor(to: point)

        // Start long press timer
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.gestureState == .pending else { return }
            self.gestureState = .longPressReady
        }
        longPressTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .nanoseconds(Int(GestureThresholds.longPressTime)),
            execute: timer
        )
    }

    private func oneFingerMove(to point: CGPoint) {
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastTouchTime < GestureThresholds.minTouchInterval { return }
        lastTouchTime = now

        let deltaX = point.x - touchLastPosition.x
        let deltaY = point.y - touchLastPosition.y
        let totalDistance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            if totalDistance > GestureThresholds.tapMaxDistance {
                cancelLongPressTimer()
                gestureState = .scrolling
                let sx = deltaX * GestureThresholds.scrollSensitivity
                let sy = deltaY * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .longPressReady:
            if totalDistance > GestureThresholds.tapMaxDistance {
                // Long press + drag → left mouse drag
                gestureState = .dragging
                injectMouseDown(at: touchStartPosition)
                injectMouseDragged(to: point)
            }

        case .scrolling:
            let sx = deltaX * GestureThresholds.scrollSensitivity
            let sy = deltaY * GestureThresholds.scrollSensitivity
            injectScrollEvent(deltaX: sx, deltaY: sy, at: point)
            let timeDelta = now - touchLastMoveTime
            if timeDelta > 0 && timeDelta < 100_000_000 {
                lastScrollDeltaX = sx
                lastScrollDeltaY = sy
            }

        case .dragging:
            injectMouseDragged(to: point)

        default:
            break
        }

        touchLastPosition = point
        touchLastMoveTime = now
    }

    private func oneFingerUp(at point: CGPoint) {
        cancelLongPressTimer()
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - touchStartTime
        let distance = hypot(point.x - touchStartPosition.x, point.y - touchStartPosition.y)

        switch gestureState {
        case .pending:
            // Quick release, no movement → tap or double tap
            if distance < GestureThresholds.tapMaxDistance && elapsed < GestureThresholds.tapMaxTime {
                // Check double tap
                let timeSinceLastTap = now - lastTapTime
                let distFromLastTap = hypot(point.x - lastTapPosition.x, point.y - lastTapPosition.y)

                if timeSinceLastTap < GestureThresholds.doubleTapMaxTime
                    && distFromLastTap < GestureThresholds.doubleTapMaxDistance {
                    performDoubleClick(at: point)
                    lastTapTime = 0  // Reset so triple tap doesn't trigger
                } else {
                    performClick(at: point)
                    lastTapTime = now
                    lastTapPosition = point
                }
            }

        case .longPressReady:
            // Held long but didn't drag → right click
            performRightClick(at: point)

        case .scrolling:
            // Check momentum
            let timeSinceLastMove = now - touchLastMoveTime
            if timeSinceLastMove < 50_000_000 {
                let threshold: CGFloat = 2.0
                if abs(lastScrollDeltaX) > threshold || abs(lastScrollDeltaY) > threshold {
                    startMomentumScroll(
                        velocityX: lastScrollDeltaX * 6.0,
                        velocityY: lastScrollDeltaY * 6.0,
                        at: point
                    )
                }
            }

        case .dragging:
            injectMouseUp(at: point)

        default:
            break
        }

        gestureState = .idle
    }

    // MARK: - 2-Finger Gestures

    private func handleTwoFingerTouch(p1: CGPoint, p2: CGPoint, action: Int) {
        let distance = hypot(p2.x - p1.x, p2.y - p1.y)
        let midpoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

        switch action {
        case 0: // Down
            cancelLongPressTimer()
            stopMomentumScroll()
            gestureState = .idle  // Reset so 2-finger detection starts fresh
            initialPinchDistance = distance
            lastPinchDistance = distance
            touchLastPosition = midpoint

        case 1: // Move
            let distanceChange = abs(distance - initialPinchDistance)
            let midDelta = hypot(midpoint.x - touchLastPosition.x, midpoint.y - touchLastPosition.y)

            // Determine mode if not yet decided
            if gestureState != .twoFingerScroll && gestureState != .pinching {
                if distanceChange > GestureThresholds.pinchMinDistance {
                    gestureState = .pinching
                } else if midDelta > GestureThresholds.tapMaxDistance {
                    gestureState = .twoFingerScroll
                }
            }

            switch gestureState {
            case .twoFingerScroll:
                let dx = (midpoint.x - touchLastPosition.x) * GestureThresholds.scrollSensitivity
                let dy = (midpoint.y - touchLastPosition.y) * GestureThresholds.scrollSensitivity
                injectScrollEvent(deltaX: dx, deltaY: dy, at: midpoint)

            case .pinching:
                let scaleDelta = distance - lastPinchDistance
                // Cmd + scroll = zoom in most Mac apps
                let zoomAmount = Int32(scaleDelta * 0.5)
                if zoomAmount != 0 {
                    injectZoomEvent(delta: zoomAmount, at: midpoint)
                }
                lastPinchDistance = distance

            default:
                break
            }

            touchLastPosition = midpoint

        case 2: // Up
            gestureState = .idle
            // Reset 1-finger tracking so leftover moves don't trigger scroll
            touchStartPosition = .zero
            touchLastPosition = .zero

        default:
            break
        }
    }

    // MARK: - Event Injection

    private func moveCursor(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func performClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performDoubleClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 2)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 2)
            up.post(tap: .cghidEventTap)
        }
    }

    private func performRightClick(at point: CGPoint) {
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) {
            up.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDown(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseDragged(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseUp(at point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectScrollEvent(deltaX: CGFloat, deltaY: CGFloat, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        scrollEvent.post(tap: .cghidEventTap)
    }

    private func injectZoomEvent(delta: Int32, at position: CGPoint) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        scrollEvent.location = position
        // Set Cmd flag for zoom
        scrollEvent.flags = .maskCommand
        scrollEvent.post(tap: .cghidEventTap)
    }

    // MARK: - Long Press Timer

    private func cancelLongPressTimer() {
        longPressTimer?.cancel()
        longPressTimer = nil
    }

    // MARK: - Momentum Scrolling

    private func startMomentumScroll(velocityX: CGFloat, velocityY: CGFloat, at position: CGPoint) {
        stopMomentumScroll()
        momentumVelocityX = velocityX
        momentumVelocityY = velocityY
        lastMomentumPosition = position
        momentumTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.momentumTick()
        }
    }

    private func momentumTick() {
        let decay: CGFloat = 0.92
        let minVelocity: CGFloat = 0.5

        if abs(momentumVelocityX) < minVelocity && abs(momentumVelocityY) < minVelocity {
            stopMomentumScroll()
            return
        }

        injectScrollEvent(deltaX: momentumVelocityX, deltaY: momentumVelocityY, at: lastMomentumPosition)
        momentumVelocityX *= decay
        momentumVelocityY *= decay
    }

    private func stopMomentumScroll() {
        momentumTimer?.invalidate()
        momentumTimer = nil
        momentumVelocityX = 0
        momentumVelocityY = 0
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop momentum scrolling
        stopMomentumScroll()

        // Stop server and cleanup
        stopServer()

        // Cancel all combine subscriptions
        cancellables.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - Menu bar quick actions

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Live status line (not clickable)
        let statusTitle: String
        if settings.isRunning {
            if settings.clientConnected {
                let device = settings.currentWirelessDevice ?? "tablet"
                statusTitle = "🟢 Connected — \(device)"
            } else {
                statusTitle = "🟡 Waiting for tablet on port \(settings.port)"
            }
        } else {
            statusTitle = "⚪️ Server stopped"
        }
        let statusLine = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        // Start / Stop
        let toggle = NSMenuItem(
            title: settings.isRunning ? "Stop Streaming" : "Start Streaming",
            action: #selector(toggleServerFromMenu),
            keyEquivalent: "t"
        )
        toggle.target = self
        // Mirror the settings-window Start button: starting needs the Screen
        // Recording permission, stopping is always allowed.
        toggle.isEnabled = settings.isRunning || settings.hasScreenRecordingPermission
        menu.addItem(toggle)

        // Connection mode (switching while running restarts the server, same
        // as changing it in the settings window)
        let modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        let usb = NSMenuItem(title: "USB", action: #selector(selectUSBMode), keyEquivalent: "")
        usb.target = self
        usb.state = settings.connectionMode == .usb ? .on : .off
        modeMenu.addItem(usb)
        let wireless = NSMenuItem(title: "Wireless", action: #selector(selectWirelessMode), keyEquivalent: "")
        wireless.target = self
        wireless.state = settings.connectionMode == .wireless ? .on : .off
        modeMenu.addItem(wireless)
        let modeItem = NSMenuItem(title: "Connection Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: "s")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Harmony Side Screen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
