import SwiftUI
import AppKit
import IOKit
import IOKit.ps
import Darwin
import ServiceManagement

// MARK: - Data Models

struct ChargingPowerSnapshot {
    let isCharging: Bool?
    /// 是否接通交流电源（电池已满时 isCharging 为 false，但仍在用外接电源）
    let isOnACPower: Bool?
    let chargingPowerWatts: Double?
    let batteryVoltageVolts: Double?
    let batteryCurrentAmps: Double?
    let adapterRatedPowerWatts: Double?
    let timestamp: Date

    static var empty: ChargingPowerSnapshot {
        ChargingPowerSnapshot(
            isCharging: nil,
            isOnACPower: nil,
            chargingPowerWatts: nil,
            batteryVoltageVolts: nil,
            batteryCurrentAmps: nil,
            adapterRatedPowerWatts: nil,
            timestamp: Date()
        )
    }
}

struct ProcessEnergyInfo: Identifiable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let cpuUsage: Double
    let estimatedPowerMW: Double

    var formattedCPU: String {
        String(format: "%.1f%%", cpuUsage)
    }

    var formattedPower: String {
        if estimatedPowerMW >= 1000 {
            return String(format: "%.2f W", estimatedPowerMW / 1000)
        } else {
            return String(format: "%.0f mW", estimatedPowerMW)
        }
    }
}

// MARK: - Main App

@main
struct ChargingPowerToolApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

// MARK: - Views

private struct SettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("ChargingPowerTool")
                .font(.headline)
            Text("状态栏充电功率监视器")
                .font(.subheadline)
            Text("数据每 5 秒刷新一次。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("充电提示音设置可从状态栏菜单打开（⌘,）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(width: 260, height: 160)
        .padding()
    }
}

struct ProcessEnergyWindowView: View {
    @StateObject private var collector = ProcessEnergyCollector()
    @State private var sortOrder = [KeyPathComparator(\ProcessEnergyInfo.estimatedPowerMW, order: .reverse)]
    @State private var selectedProcessID: pid_t?

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏
            HStack {
                Text("进程能耗监控")
                    .font(.headline)
                Spacer()
                Button("刷新") {
                    Task {
                        await collector.refresh()
                    }
                }
                .disabled(collector.isRefreshing)
                if let lastUpdate = collector.lastUpdateTime {
                    Text("更新于：\(lastUpdate, style: .time)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()

            // 进程列表表格
            Table(collector.processes, selection: $selectedProcessID, sortOrder: $sortOrder) {
                TableColumn("应用") { process in
                    HStack(spacing: 8) {
                        if let icon = process.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(process.name)
                                .font(.body)
                            if let bundleID = process.bundleIdentifier {
                                Text(bundleID)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .width(min: 200, ideal: 300)

                TableColumn("CPU", value: \.cpuUsage) { process in
                    Text(process.formattedCPU)
                }
                .width(80)

                TableColumn("估算能耗", value: \.estimatedPowerMW) { process in
                    Text(process.formattedPower)
                        .foregroundColor(powerColor(for: process.estimatedPowerMW))
                }
                .width(100)

                TableColumn("PID", value: \.id) { process in
                    Text("\(process.id)")
                        .font(.system(.body, design: .monospaced))
                }
                .width(60)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .onChange(of: sortOrder) { newOrder in
                collector.processes.sort(using: newOrder)
            }

            // 底部操作栏
            HStack {
                if let error = collector.lastError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                Spacer()
                Button("终止进程") {
                    if let pid = selectedProcessID {
                        Task {
                            await terminateProcess(pid: pid)
                        }
                    }
                }
                .disabled(selectedProcessID == nil)
            }
            .padding()
        }
        .frame(width: 700, height: 500)
        .task {
            await collector.startRefreshing()
        }
        .onDisappear {
            collector.stopRefreshing()
        }
    }

    private func powerColor(for powerMW: Double) -> Color {
        if powerMW >= 5000 {
            return .red
        } else if powerMW >= 2000 {
            return .orange
        } else if powerMW >= 500 {
            return .yellow
        } else {
            return .primary
        }
    }

    private func terminateProcess(pid: pid_t) async {
        // 查找进程名称
        let processName = collector.processes.first(where: { $0.id == pid })?.name ?? "未知进程"

        // 显示确认对话框
        let confirmed = await showConfirmationDialog(processName: processName, pid: pid)
        guard confirmed else { return }

        // 执行终止
        let result = collector.terminateProcess(pid: pid)
        switch result {
        case .success:
            collector.lastError = nil
            // 刷新列表
            await collector.refresh()
        case .failure(let error):
            collector.lastError = error.localizedDescription
        }
    }

    private func showConfirmationDialog(processName: String, pid: pid_t) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "确认终止进程"
            alert.informativeText = "是否要终止 \"\(processName)\" (PID: \(pid))？\n\n此操作可能导致未保存的数据丢失。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "终止")
            alert.addButton(withTitle: "取消")

            let response = alert.runModal()
            continuation.resume(returning: response == .alertFirstButtonReturn)
        }
    }
}

// MARK: - App Delegate

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private let powerProvider = PowerDataProvider()
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    // 新增：进程能耗窗口
    private var processEnergyWindow: NSWindow?

    // 新增：充电提示音设置窗口
    private var soundSettingsWindow: NSWindow?

    // 新增：充电状态变化监听（用于即时播放提示音）
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var lastIsCharging: Bool?
    private var lastTransitionDate: Date?
    private var libraryModeItem: NSMenuItem?
    private var launchAtLoginItem: NSMenuItem?

    private let stateMenuItem = NSMenuItem(title: "状态：--", action: nil, keyEquivalent: "")
    private let chargingPowerMenuItem = NSMenuItem(title: "当前充电功率：--", action: nil, keyEquivalent: "")
    private let batteryVoltageMenuItem = NSMenuItem(title: "电池电压：--", action: nil, keyEquivalent: "")
    private let batteryCurrentMenuItem = NSMenuItem(title: "电池电流：--", action: nil, keyEquivalent: "")
    private let adapterRatedMenuItem = NSMenuItem(title: "适配器额定功率：--", action: nil, keyEquivalent: "")
    private let lastUpdatedMenuItem = NSMenuItem(title: "最后更新：--", action: nil, keyEquivalent: "")
    private let versionMenuItem: NSMenuItem = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "--"
        return NSMenuItem(title: "版本 v\(version)", action: nil, keyEquivalent: "")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPowerSourceNotifications()
        SystemChimeController.shared.refreshState()

        let initialSnapshot = powerProvider.collectSnapshot()
        lastIsCharging = initialSnapshot.isCharging
        refreshUI(with: initialSnapshot)

        timer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(handleTimer(_:)), userInfo: nil, repeats: true)
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    @objc private func terminateApp() {
        NSApp.terminate(nil)
    }

    @objc private func handleTimer(_ timer: Timer) {
        processPowerSnapshot(powerProvider.collectSnapshot())
    }

    /// 统一入口：刷新 UI 并检测充电状态变化（提示音）
    private func processPowerSnapshot(_ snapshot: ChargingPowerSnapshot) {
        refreshUI(with: snapshot)
        handleChargingTransition(snapshot.isCharging)
    }

    /// 充电状态发生 插入→拔出 / 拔出→插入 变化时播放提示音（默认关闭，可在设置中开启）
    private func handleChargingTransition(_ newState: Bool?) {
        guard let newState else { return }
        let now = Date()
        if let oldState = lastIsCharging, oldState != newState,
           lastTransitionDate.map({ now.timeIntervalSince($0) > 1.5 }) ?? true {
            lastTransitionDate = now
            let settings = ChargingSoundSettings.shared
            if newState {
                if settings.playOnConnect { settings.playSelectedSound() }
            } else {
                if settings.playOnDisconnect { settings.playSelectedSound() }
            }
        }
        lastIsCharging = newState
    }

    /// 监听系统电源事件（插入/拔出充电器等），即时响应而非等待 5 秒轮询
    private func setupPowerSourceNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { rawContext in
            guard let rawContext else { return }
            Task { @MainActor in
                let appDelegate = Unmanaged<MenuBarAppDelegate>.fromOpaque(rawContext).takeUnretainedValue()
                appDelegate.processPowerSnapshot(appDelegate.powerProvider.collectSnapshot())
            }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = source
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "充电功率")
            button.imagePosition = .imageLeading
            button.image?.isTemplate = true
            button.title = " --"
        }

        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(stateMenuItem)
        menu.addItem(chargingPowerMenuItem)
        menu.addItem(batteryVoltageMenuItem)
        menu.addItem(batteryCurrentMenuItem)
        menu.addItem(adapterRatedMenuItem)
        menu.addItem(.separator())
        menu.addItem(lastUpdatedMenuItem)
        menu.addItem(.separator())

        // 新增：进程能耗监控菜单项
        let energyMenuItem = NSMenuItem(
            title: "进程能耗监控...",
            action: #selector(showProcessEnergyWindow),
            keyEquivalent: "e"
        )
        energyMenuItem.target = self
        menu.addItem(energyMenuItem)
        menu.addItem(.separator())

        // 新增：充电提示音设置与图书馆模式快捷开关
        let soundSettingsItem = NSMenuItem(
            title: "充电提示音设置...",
            action: #selector(showSoundSettingsWindow),
            keyEquivalent: ","
        )
        soundSettingsItem.target = self
        menu.addItem(soundSettingsItem)

        let libraryItem = NSMenuItem(
            title: "图书馆模式（关闭系统充电音）",
            action: #selector(toggleLibraryMode),
            keyEquivalent: ""
        )
        libraryItem.target = self
        menu.addItem(libraryItem)
        libraryModeItem = libraryItem

        let launchItem = NSMenuItem(
            title: "开机自启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        menu.addItem(launchItem)
        launchAtLoginItem = launchItem

        menu.addItem(.separator())
        menu.addItem(versionMenuItem)

        let quitItem = NSMenuItem(title: "退出 ChargingPowerTool", action: #selector(terminateApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func showProcessEnergyWindow() {
        if let existingWindow = processEnergyWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = ProcessEnergyWindowView()
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "进程能耗监控"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        processEnergyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 充电提示音

    @objc private func showSoundSettingsWindow() {
        if let existingWindow = soundSettingsWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = ChargingSoundSettingsView()
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "充电提示音设置"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        soundSettingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 一键开关注释：关闭/恢复 macOS 系统的充电提示音（PowerChime）
    @objc private func toggleLibraryMode() {
        let controller = SystemChimeController.shared
        controller.setDisabled(!(controller.isDisabled ?? false))
    }

    // MARK: 开机自启动

    /// 切换开机自启动（SMAppService），并在需要时弹出系统确认/错误提示
    @objc private func toggleLaunchAtLogin() {
        let result = LoginItemController.shared.toggle()
        switch result {
        case .enabled, .disabled:
            break
        case .requiresApproval:
            showAlert(
                title: "需要在系统设置中允许",
                message: "ChargingPowerTool 已注册为登录项。\n请前往「系统设置 → 通用 → 登录项与扩展」，在列表中允许 ChargingPowerTool。",
                confirmTitle: "打开系统设置"
            ) { _ in
                SMAppService.openSystemSettingsLoginItems()
            }
        case .unavailable:
            showAlert(
                title: "暂不可用",
                message: "开机自启动需要从 .app 应用包运行时才能设置（调试模式 swift run 下不支持）。",
                confirmTitle: "好"
            )
        case .failed(let reason):
            showAlert(title: "设置失败", message: reason, confirmTitle: "好")
        }
        updateLaunchAtLoginItem()
    }

    private func updateLaunchAtLoginItem() {
        guard let item = launchAtLoginItem else { return }
        let controller = LoginItemController.shared
        controller.refreshState()
        switch controller.state {
        case .enabled:
            item.state = .on
            item.title = "开机自启动"
        case .requiresApproval:
            item.state = .mixed
            item.title = "开机自启动（需在系统设置中允许）"
        case .disabled:
            item.state = .off
            item.title = "开机自启动"
        case .unavailable:
            item.state = .off
            item.title = "开机自启动（不可用）"
        }
    }

    private func showAlert(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        let response = alert.runModal()
        onConfirm?(response)
    }

    private func updateLibraryModeItem() {
        guard let item = libraryModeItem else { return }
        switch SystemChimeController.shared.isDisabled {
        case .some(true):
            item.state = .on
            item.title = "图书馆模式（系统充电音已关闭）"
        case .some(false):
            item.state = .off
            item.title = "图书馆模式（关闭系统充电音）"
        case .none:
            item.state = .off
            item.title = "图书馆模式（正在读取状态…）"
            SystemChimeController.shared.refreshState()
        }
    }

    private func refreshUI(with snapshot: ChargingPowerSnapshot) {
        // 图标按语义三态选择：正在充电 / 已接电源（电池已满）/ 使用电池。
        // 不用功率正负判断——电池充满时插着电源电流≈0 甚至微负，
        // 会与用电池状态撞图标（都是 bolt.slash）。
        let iconName: String
        switch snapshot.isCharging {
        case .some(true):
            iconName = "bolt.fill"
        case .some(false):
            iconName = (snapshot.isOnACPower == true) ? "bolt" : "bolt.slash"
        case .none:
            iconName = "bolt"
        }

        let statusTitle: String
        switch snapshot.isCharging {
        case .some(true):
            statusTitle = "状态：正在充电"
        case .some(false):
            statusTitle = (snapshot.isOnACPower == true) ? "状态：已接电源（电池已满/未在充电）" : "状态：使用电池"
        case .none:
            statusTitle = "状态：未知"
        }
        stateMenuItem.title = statusTitle

        if let chargingPower = snapshot.chargingPowerWatts {
            chargingPowerMenuItem.title = String(format: "当前充电功率：%.2f W", chargingPower)
        } else {
            chargingPowerMenuItem.title = "当前充电功率：--"
        }

        if let voltage = snapshot.batteryVoltageVolts {
            batteryVoltageMenuItem.title = String(format: "电池电压：%.2f V", voltage)
        } else {
            batteryVoltageMenuItem.title = "电池电压：--"
        }

        if let current = snapshot.batteryCurrentAmps {
            batteryCurrentMenuItem.title = String(format: "电池电流：%.2f A", current)
        } else {
            batteryCurrentMenuItem.title = "电池电流：--"
        }

        if let rated = snapshot.adapterRatedPowerWatts {
            adapterRatedMenuItem.title = String(format: "适配器额定功率：%.0f W", rated)
        } else {
            adapterRatedMenuItem.title = "适配器额定功率：--"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        lastUpdatedMenuItem.title = "最后更新：" + formatter.string(from: snapshot.timestamp)

        if let button = statusItem?.button {
            if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "充电功率状态") {
                button.image = image
                button.image?.isTemplate = true
            }

            // 保留一位小数：涓流充电（如 0.4W）取整会显示成 0W，容易误判为没在充电
            let primaryPowerText: String
            if let chargingPower = snapshot.chargingPowerWatts {
                primaryPowerText = String(format: "%.1fW", chargingPower)
            } else {
                primaryPowerText = "--"
            }
            button.title = " \(primaryPowerText)"
        }
    }
}

extension MenuBarAppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === processEnergyWindow {
            processEnergyWindow = nil
        }
        if notification.object as? NSWindow === soundSettingsWindow {
            soundSettingsWindow = nil
        }
    }
}

extension MenuBarAppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateLibraryModeItem()
        updateLaunchAtLoginItem()
    }
}

// MARK: - Data Providers

private final class PowerDataProvider {
    func collectSnapshot() -> ChargingPowerSnapshot {
        let adapterDetails = (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]) ?? [:]
        let adapterRatedPowerWatts = value(from: adapterDetails, key: kIOPSPowerAdapterWattsKey as String)

        var isCharging: Bool?
        var isOnACPower: Bool?
        var iopsVoltage: Double?
        var iopsAppleRawCurrent: Double?
        var iopsCurrent: Double?

        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let powerSources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for source in powerSources {
                guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                    continue
                }

                guard let type = description[kIOPSTypeKey as String] as? String,
                      type == kIOPSInternalBatteryType else {
                    continue
                }

                if isCharging == nil, let rawIsCharging = description[kIOPSIsChargingKey as String] as? Bool {
                    isCharging = rawIsCharging
                }

                if isOnACPower == nil, let powerSourceState = description[kIOPSPowerSourceStateKey as String] as? String {
                    isOnACPower = (powerSourceState == kIOPSACPowerValue)
                }

                if iopsVoltage == nil {
                    iopsVoltage = milliValueToBase(from: description, key: kIOPSVoltageKey as String)
                }
                if iopsAppleRawCurrent == nil {
                    iopsAppleRawCurrent = milliValueToBase(from: description, key: appleRawCurrentKey)
                }
                if iopsCurrent == nil {
                    iopsCurrent = milliValueToBase(from: description, key: kIOPSCurrentKey as String)
                }
            }
        }

        var smartVoltage: Double?
        var smartAmperage: Double?
        var smartInstantAmperage: Double?
        if let smartBattery = fetchSmartBatteryProperties() {
            smartVoltage = milliValueToBase(from: smartBattery, key: smartBatteryVoltageKey)
                ?? milliValueToBase(from: smartBattery, key: smartBatteryRawVoltageKey)
            smartAmperage = milliValueToBase(from: smartBattery, key: smartBatteryAmperageKey)
            smartInstantAmperage = milliValueToBase(from: smartBattery, key: smartBatteryInstantAmperageKey)
        }

        // 部分机型的 IOPS 描述里 Current 恒为 0（占位值，实际电流在 AppleSmartBattery 的
        // Amperage/InstantAmperage 里），若按 nil-回退链取值会把它当成有效读数，屏蔽真实
        // 电流导致功率恒为 0W。这里改为：候选里取第一个非零读数；全为零才接受零
        // （电池充满插着电源时电流确实≈0）。
        let batteryVoltageVolts = firstMeaningful([iopsVoltage, smartVoltage])
        let batteryCurrentAmps = firstMeaningful([
            iopsAppleRawCurrent, smartAmperage, smartInstantAmperage, iopsCurrent
        ])

        // 充电功率符号规范化：不同机型/系统的电流符号约定不一致，
        // 统一为 充电=正、用电池=负（幅度小于 0.05W 视为 0，避免出现 -0W）
        var chargingPowerWatts: Double? = nil
        if let current = batteryCurrentAmps, let voltage = batteryVoltageVolts {
            var watts = (current * voltage).rounded(toPlaces: 2)
            if let charging = isCharging, abs(watts) >= 0.05 {
                watts = charging ? abs(watts) : -abs(watts)
            } else if abs(watts) < 0.05 {
                watts = 0
            }
            chargingPowerWatts = watts
        }

        return ChargingPowerSnapshot(
            isCharging: isCharging,
            isOnACPower: isOnACPower,
            chargingPowerWatts: chargingPowerWatts,
            batteryVoltageVolts: batteryVoltageVolts,
            batteryCurrentAmps: batteryCurrentAmps,
            adapterRatedPowerWatts: adapterRatedPowerWatts,
            timestamp: Date()
        )
    }
}

// MARK: - System Helpers

private func fetchSmartBatteryProperties() -> [String: Any]? {
    guard let matching = IOServiceMatching("AppleSmartBattery") else {
        return nil
    }

    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != 0 else {
        return nil
    }
    defer { IOObjectRelease(service) }

    var properties: Unmanaged<CFMutableDictionary>?
    let result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
    guard result == KERN_SUCCESS,
          let dictionary = properties?.takeRetainedValue() as? [String: Any] else {
        return nil
    }
    return dictionary
}

private func value(from dictionary: [String: Any], key: String) -> Double? {
    if let number = dictionary[key] as? NSNumber {
        return number.doubleValue
    }
    if let doubleValue = dictionary[key] as? Double {
        return doubleValue
    }
    if let stringValue = dictionary[key] as? String,
       let doubleValue = Double(stringValue) {
        return doubleValue
    }
    return nil
}

private func milliValueToBase(from dictionary: [String: Any], key: String) -> Double? {
    guard let rawValue = value(from: dictionary, key: key) else {
        return nil
    }
    // 电压、电流字段通常以毫单位（mV/mA）提供，需要转换为基础单位（V/A）。
    return rawValue / 1000.0
}

/// 从候选读数中取第一个非零值；全部为零时取第一个非 nil 值（可能是真实的零）
private func firstMeaningful(_ candidates: [Double?]) -> Double? {
    let available = candidates.compactMap { $0 }
    return available.first(where: { abs($0) > 0.001 }) ?? available.first
}

// MARK: - Extensions

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        guard places >= 0 else { return self }
        let multiplier = pow(10.0, Double(places))
        return (self * multiplier).rounded() / multiplier
    }
}

// MARK: - Constants

private let appleRawCurrentKey = "AppleRawCurrent"
private let smartBatteryVoltageKey = "Voltage"
private let smartBatteryRawVoltageKey = "AppleRawBatteryVoltage"
private let smartBatteryAmperageKey = "Amperage"
private let smartBatteryInstantAmperageKey = "InstantAmperage"
