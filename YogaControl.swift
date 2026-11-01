import SwiftUI
import IOKit
import IOKit.ps
import ObjectiveC
import ServiceManagement

let perfNames = ["Q": "安静", "B": "均衡", "P": "性能"]

final class IdeaVPC: ObservableObject {
    @Published var available = false
    @Published var perfMode = "—"
    @Published var funcMode = "—"
    @Published var dytcRevision = "—"
    @Published var conservation = false
    @Published var alwaysOnUSB = false
    @Published var fnLock = false
    @Published var version = "—"
    @Published var cycleCount = "—"
    @Published var mfgDate = "—"
    @Published var lastError = ""
    @Published var fnQEnabled = UserDefaults.standard.object(forKey: "FnQEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fnQEnabled, forKey: "FnQEnabled") }
    }

    @Published var onAC = false
    @Published var charging = false
    @Published var batteryPercent: Int?
    // "" = don't switch automatically
    @Published var acMode = UserDefaults.standard.string(forKey: "ACMode") ?? "" {
        didSet { UserDefaults.standard.set(acMode, forKey: "ACMode"); if onAC { applyPowerMode() } }
    }
    @Published var batteryMode = UserDefaults.standard.string(forKey: "BatteryMode") ?? "" {
        didSet { UserDefaults.standard.set(batteryMode, forKey: "BatteryMode"); if !onAC { applyPowerMode() } }
    }

    private var timer: Timer?
    private var connect: io_connect_t = 0
    private var powerSource: CFRunLoopSource?
    fileprivate static weak var current: IdeaVPC?

    init() {
        IdeaVPC.current = self
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        startPowerMonitor()
    }

    private func startPowerMonitor() {
        updatePower(initial: true)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<IdeaVPC>.fromOpaque(ctx).takeUnretainedValue().updatePower(initial: false)
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        powerSource = src
    }

    // Power notifications also fire on capacity changes; only switch modes when AC is plugged or unplugged
    private func updatePower(initial: Bool) {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let ac = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            charging = d[kIOPSIsChargingKey] as? Bool ?? false
            batteryPercent = d[kIOPSCurrentCapacityKey] as? Int
        }
        let changed = ac != onAC
        onAC = ac
        if initial || changed { applyPowerMode(showHUD: !initial) }
    }

    private func applyPowerMode(showHUD: Bool = false) {
        let mode = onAC ? acMode : batteryMode
        guard !mode.isEmpty, mode != perfSelection else { return }
        setPerf(mode)
        if showHUD { ModeHUD.shared.show(perfNames[mode]!, icon: IdeaVPC.icon(for: mode)) }
    }

    var powerStatus: String {
        let pct = batteryPercent.map { " · \($0)%" } ?? ""
        if !onAC { return "使用电池" + pct }
        return (charging ? "接通电源（充电中）" : "接通电源") + pct
    }

    // YogaSMCUserClient: selector 0 = open; notifications are SMCNotificationMessage { header, event, data, ref }
    private func listenForKeys() {
        let s = service()
        guard s != 0 else { return }
        defer { IOObjectRelease(s) }
        var c: io_connect_t = 0
        guard IOServiceOpen(s, mach_task_self_, 0, &c) == KERN_SUCCESS else { return }
        guard IOConnectCallScalarMethod(c, 0, nil, 0, nil, nil) == KERN_SUCCESS,
              let port = CFMachPortCreate(kCFAllocatorDefault, { _, msg, _, _ in
                  guard let msg else { return }
                  let offset = MemoryLayout<mach_msg_header_t>.size
                  let event = msg.load(fromByteOffset: offset, as: UInt32.self)
                  let data = msg.load(fromByteOffset: offset + 4, as: UInt32.self)
                  DispatchQueue.main.async { IdeaVPC.current?.handleEvent(event, data) }
              }, nil, nil),
              IOConnectSetNotificationPort(c, 0, CFMachPortGetPort(port), 0) == KERN_SUCCESS else {
            IOServiceClose(c)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .commonModes)
        connect = c
    }

    private func handleEvent(_ event: UInt32, _ data: UInt32) {
        // VPC bit 0 = special button; 0x40 / 0x01 = Fn+Q
        guard fnQEnabled, event == 0, data == 0x40 || data == 0x01 else { return }
        let next: String
        switch perfSelection {
        case "Q": next = "B"
        case "B": next = "P"
        case "P": next = "Q"
        default: next = "B"
        }
        setPerf(next)
        ModeHUD.shared.show(perfNames[next]!, icon: IdeaVPC.icon(for: next))
    }

    private func service() -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("IdeaVPC"))
    }

    func refresh() {
        let s = service()
        guard s != 0 else { available = false; return }
        defer { IOObjectRelease(s) }
        if connect == 0 { listenForKeys() }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(s, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { available = false; return }
        available = true
        if let d = props["DYTC"] as? [String: Any] {
            perfMode = d["PerfMode"] as? String ?? "—"
            funcMode = d["FuncMode"] as? String ?? "—"
            if let r = d["Revision"] as? Int { dytcRevision = String(r) }
        }
        conservation = props["ConservationMode"] as? Bool ?? false
        alwaysOnUSB = props["AlwaysOnUSBMode"] as? Bool ?? false
        fnLock = props["FnlockMode"] as? Bool ?? false
        version = props["VersionInfo"] as? String ?? "—"
        if let b = props["Battery 0"] as? [String: Any] {
            cycleCount = b["Cycle count"] as? String ?? "—"
            mfgDate = b["Manufacture date"] as? String ?? "—"
        }
    }

    private func set(_ key: String, _ value: CFTypeRef) {
        let s = service()
        guard s != 0 else { lastError = "找不到 IdeaVPC（YogaSMC 驱动未加载）"; return }
        defer { IOObjectRelease(s) }
        let kr = IORegistryEntrySetCFProperty(s, key as CFString, value)
        lastError = kr == KERN_SUCCESS ? "" : "写入 \(key) 失败：0x\(String(kr, radix: 16))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    func setPerf(_ code: String) { set("DYTCMode", code as CFString) }
    func setBool(_ key: String, _ on: Bool) { set(key, on ? kCFBooleanTrue : kCFBooleanFalse) }

    var menuIcon: String { IdeaVPC.icon(for: perfSelection) }

    static func icon(for code: String) -> String {
        switch code {
        case "Q": return "tortoise"
        case "B": return "gauge.with.dots.needle.50percent"
        case "P": return "hare"
        default: return "laptopcomputer"
        }
    }

    var perfSelection: String {
        switch perfMode {
        case "Quiet": return "Q"
        case "Balance": return "B"
        case _ where perfMode.hasPrefix("Performance"): return "P"
        default: return ""
        }
    }
}

struct ContentView: View {
    @ObservedObject var vpc: IdeaVPC

    var body: some View {
        Form {
            if !vpc.available {
                Text("未检测到 YogaSMC 驱动（IdeaVPC）。请确认 config.plist 中 YogaSMC.kext 已启用。")
                    .foregroundStyle(.red)
            }

            Section("性能模式") {
                Picker("模式", selection: Binding(get: { vpc.perfSelection }, set: { vpc.setPerf($0) })) {
                    Text("安静").tag("Q")
                    Text("均衡").tag("B")
                    Text("性能").tag("P")
                }
                .pickerStyle(.segmented)
                LabeledContent("当前", value: "\(vpc.perfMode) / \(vpc.funcMode)")
                Toggle("Fn+Q 循环切换性能模式", isOn: $vpc.fnQEnabled)
            }

            Section("电源") {
                LabeledContent("当前电源", value: vpc.powerStatus)
                Picker("接通电源时", selection: $vpc.acMode) { autoModeOptions }
                Picker("使用电池时", selection: $vpc.batteryMode) { autoModeOptions }
                Text("插拔电源时自动切换；启动软件时按当前电源切换一次。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("电池与接口") {
                Toggle("电池养护模式（充电上限约 60%）", isOn: Binding(get: { vpc.conservation }, set: { vpc.setBool("ConservationMode", $0) }))
                Toggle("关机时 USB 供电", isOn: Binding(get: { vpc.alwaysOnUSB }, set: { vpc.setBool("AlwaysOnUSBMode", $0) }))
            }

            Section("键盘") {
                Toggle("Fn 锁", isOn: Binding(get: { vpc.fnLock }, set: { vpc.setBool("FnlockMode", $0) }))
                Text("键盘背光用 Fn+空格 切换。").font(.caption).foregroundStyle(.secondary)
            }

            Section("信息") {
                LabeledContent("电池循环次数", value: vpc.cycleCount)
                LabeledContent("电池生产日期", value: vpc.mfgDate)
                LabeledContent("DYTC 版本", value: vpc.dytcRevision)
                LabeledContent("YogaSMC", value: vpc.version)
            }

            if !vpc.lastError.isEmpty {
                Text(vpc.lastError).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@ViewBuilder var autoModeOptions: some View {
    Text("不自动切换").tag("")
    Text("安静").tag("Q")
    Text("均衡").tag("B")
    Text("性能").tag("P")
}

final class PanelWindow: NSObject, NSWindowDelegate {
    static let shared = PanelWindow()
    private var window: NSWindow?

    func show(_ vpc: IdeaVPC) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ContentView(vpc: vpc)))
            w.title = "Yoga 14s 控制"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func hideToMenuBar() {
        window?.close()
        NSApp.setActivationPolicy(.accessory)
    }
}

final class ModeHUD {
    static let shared = ModeHUD()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, icon: String) {
        let view = VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 44))
            Text(text).font(.title2.bold())
        }
        .frame(width: 160, height: 140)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))

        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p
        }
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(NSSize(width: 160, height: 140))
        if let screen = NSScreen.main?.frame {
            panel.setFrameOrigin(NSPoint(x: screen.midX - 80, y: screen.minY + screen.height * 0.2))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel?.animator().alphaValue = 0 },
                                                 completionHandler: { panel?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

struct MenuContent: View {
    @ObservedObject var vpc: IdeaVPC
    @State private var launchAtLogin = LoginItem.isEnabled || SMAppService.mainApp.status == .enabled

    var body: some View {
        Picker("性能模式", selection: Binding(get: { vpc.perfSelection }, set: { vpc.setPerf($0) })) {
            Text("安静").tag("Q")
            Text("均衡").tag("B")
            Text("性能").tag("P")
        }
        .pickerStyle(.inline)
        Toggle("Fn+Q 切换性能模式", isOn: $vpc.fnQEnabled)
        Text("电源：\(vpc.powerStatus)")

        Divider()
        Toggle("电池养护模式", isOn: Binding(get: { vpc.conservation }, set: { vpc.setBool("ConservationMode", $0) }))
        Toggle("关机时 USB 供电", isOn: Binding(get: { vpc.alwaysOnUSB }, set: { vpc.setBool("AlwaysOnUSBMode", $0) }))
        Toggle("Fn 锁", isOn: Binding(get: { vpc.fnLock }, set: { vpc.setBool("FnlockMode", $0) }))

        Divider()
        Button("打开面板…") { PanelWindow.shared.show(vpc) }
        Toggle("登录时启动", isOn: Binding(get: { launchAtLogin }, set: { on in
            do {
                try LoginItem.setEnabled(on)
            } catch {
                vpc.lastError = "登录项设置失败：\(error.localizedDescription)"
            }
            launchAtLogin = LoginItem.isEnabled
        }))
        Divider()
        Button("退出") {
            AppDelegate.allowTerminate = true
            NSApp.terminate(nil)
        }
    }
}

// SF Symbols differ in aspect ratio; fit each into the same box so the menu bar icon size stays constant
func menuBarImage(_ name: String) -> NSImage {
    let box = NSSize(width: 25, height: 18)
    let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return NSImage() }
    let s = symbol.size
    let scale = min(box.width / s.width, box.height / s.height)
    let size = NSSize(width: s.width * scale, height: s.height * scale)
    let image = NSImage(size: box, flipped: false) { _ in
        symbol.draw(in: NSRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2,
                               width: size.width, height: size.height))
        return true
    }
    image.isTemplate = true
    return image
}

// Dock 的“退出”和 Command-Q 都走 NSApplication.terminate；只有菜单里的“退出”会放行
enum TerminateGuard {
    static func install() {
        guard let original = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.terminate(_:))),
              let swizzled = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.yoga_terminate(_:)))
        else { return }
        method_exchangeImplementations(original, swizzled)
    }
}

extension NSApplication {
    @objc func yoga_terminate(_ sender: Any?) {
        guard AppDelegate.allowTerminate else {
            PanelWindow.shared.hideToMenuBar()
            return
        }
        yoga_terminate(sender)
    }
}

enum LoginItem {
    static let label = "local.yoga14s.YogaControl"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ on: Bool) throws {
        try? SMAppService.mainApp.unregister()
        if !on {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["bootout", "gui/\(getuid())/\(label)"]
            try? task.run()
            task.waitUntilExit()
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
            return
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/Applications/YogaControl.app/Contents/MacOS/YogaControl</string>
                <string>--launched-at-login</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>LimitLoadToSessionType</key><string>Aqua</string>
            <key>AssociatedBundleIdentifiers</key>
            <array><string>\(label)</string></array>
        </dict>
        </plist>
        """
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try xml.write(to: plistURL, atomically: true, encoding: .utf8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var allowTerminate = false
    private var suppressReopenUntil = Date.distantPast

    override init() {
        super.init()
        TerminateGuard.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SMAppService.mainApp.status == .enabled { try? LoginItem.setEnabled(true) }
        if CommandLine.arguments.contains("--launched-at-login") {
            suppressReopenUntil = Date().addingTimeInterval(3)
        } else {
            DispatchQueue.main.async { self.showPanel() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard Date() >= suppressReopenUntil else { return false }
        showPanel()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func showPanel() {
        if let vpc = IdeaVPC.current { PanelWindow.shared.show(vpc) }
    }
}

@main
struct YogaControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vpc = IdeaVPC()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(vpc: vpc)
        } label: {
            Image(nsImage: menuBarImage(vpc.menuIcon))
        }
    }
}
