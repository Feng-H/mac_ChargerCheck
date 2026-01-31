import SwiftUI
import AppKit
import IOKit
import IOKit.ps
import Darwin

// MARK: - Data Models

struct ChargingPowerSnapshot {
    let isCharging: Bool?
    let chargingPowerWatts: Double?
    let batteryVoltageVolts: Double?
    let batteryCurrentAmps: Double?
    let adapterRatedPowerWatts: Double?
    let timestamp: Date

    static var empty: ChargingPowerSnapshot {
        ChargingPowerSnapshot(
            isCharging: nil,
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

    private let stateMenuItem = NSMenuItem(title: "状态：--", action: nil, keyEquivalent: "")
    private let chargingPowerMenuItem = NSMenuItem(title: "当前充电功率：--", action: nil, keyEquivalent: "")
    private let batteryVoltageMenuItem = NSMenuItem(title: "电池电压：--", action: nil, keyEquivalent: "")
    private let batteryCurrentMenuItem = NSMenuItem(title: "电池电流：--", action: nil, keyEquivalent: "")
    private let adapterRatedMenuItem = NSMenuItem(title: "适配器额定功率：--", action: nil, keyEquivalent: "")
    private let lastUpdatedMenuItem = NSMenuItem(title: "最后更新：--", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        refreshUI(with: powerProvider.collectSnapshot())
        timer = Timer.scheduledTimer(timeInterval: 5, target: self, selector: #selector(handleTimer(_:)), userInfo: nil, repeats: true)
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    @objc private func terminateApp() {
        NSApp.terminate(nil)
    }

    @objc private func handleTimer(_ timer: Timer) {
        let snapshot = powerProvider.collectSnapshot()
        refreshUI(with: snapshot)
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

    private func refreshUI(with snapshot: ChargingPowerSnapshot) {
        let statusTitle: String
        switch snapshot.isCharging {
        case .some(true):
            statusTitle = "状态：正在充电"
        case .some(false):
            statusTitle = "状态：未充电"
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
            let powerValue = snapshot.chargingPowerWatts
            let iconName: String
            if let chargingPower = powerValue {
                if chargingPower < 0 {
                    iconName = "bolt.slash"
                } else if chargingPower > 0 {
                    iconName = "bolt.fill"
                } else {
                    iconName = "bolt"
                }
            } else {
                iconName = "bolt"
            }

            if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "充电功率状态") {
                button.image = image
                button.image?.isTemplate = true
            }

            let primaryPowerText: String
            if let chargingPower = powerValue {
                primaryPowerText = String(format: "%.0fW", chargingPower)
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
    }
}

// MARK: - Data Providers

private final class PowerDataProvider {
    func collectSnapshot() -> ChargingPowerSnapshot {
        let adapterDetails = (IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]) ?? [:]
        let adapterRatedPowerWatts = value(from: adapterDetails, key: kIOPSPowerAdapterWattsKey as String)

        var isCharging: Bool?
        var batteryVoltageVolts: Double?
        var batteryCurrentAmps: Double?

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

                if batteryVoltageVolts == nil {
                    batteryVoltageVolts = milliValueToBase(from: description, key: kIOPSVoltageKey as String)
                }

                if batteryCurrentAmps == nil {
                    batteryCurrentAmps = milliValueToBase(from: description, key: appleRawCurrentKey)
                        ?? milliValueToBase(from: description, key: kIOPSCurrentKey as String)
                }
            }
        }

        if let smartBattery = fetchSmartBatteryProperties() {
            if batteryVoltageVolts == nil {
                batteryVoltageVolts = milliValueToBase(from: smartBattery, key: smartBatteryVoltageKey)
            }
            if batteryCurrentAmps == nil {
                batteryCurrentAmps = milliValueToBase(from: smartBattery, key: smartBatteryAmperageKey)
                    ?? milliValueToBase(from: smartBattery, key: smartBatteryInstantAmperageKey)
            }
        }

        let chargingPowerWatts: Double?
        if let current = batteryCurrentAmps, let voltage = batteryVoltageVolts {
            chargingPowerWatts = (current * voltage).rounded(toPlaces: 2)
        } else {
            chargingPowerWatts = nil
        }

        return ChargingPowerSnapshot(
            isCharging: isCharging,
            chargingPowerWatts: chargingPowerWatts,
            batteryVoltageVolts: batteryVoltageVolts,
            batteryCurrentAmps: batteryCurrentAmps,
            adapterRatedPowerWatts: adapterRatedPowerWatts,
            timestamp: Date()
        )
    }
}

@MainActor
final class ProcessEnergyCollector: ObservableObject {
    @Published var processes: [ProcessEnergyInfo] = []
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var lastUpdateTime: Date?

    private var refreshTimer: Timer?
    private var previousCPUTimes: [pid_t: CPUSample] = [:]

    private struct CPUSample {
        let totalTime: UInt64
        let timestamp: Date
    }

    func startRefreshing() async {
        await refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        if let timer = refreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() async {
        isRefreshing = true
        lastError = nil

        var processInfos: [ProcessEnergyInfo] = []
        let runningApps = NSWorkspace.shared.runningApplications

        for app in runningApps {
            let pid = app.processIdentifier

            // 获取 CPU 信息
            guard let cpuInfo = getCPUInfo(for: pid) else {
                continue
            }

            let currentSample = CPUSample(totalTime: cpuInfo.totalTime, timestamp: cpuInfo.timestamp)

            // 计算 CPU 使用率
            let cpuUsage: Double
            if let previousSample = previousCPUTimes[pid] {
                let timeDelta = currentSample.timestamp.timeIntervalSince(previousSample.timestamp)
                guard timeDelta > 0 else { continue }

                let cpuTimeDelta = currentSample.totalTime - previousSample.totalTime
                // CPU 时间是以纳秒为单位，转换为秒
                let cpuTimeSeconds = Double(cpuTimeDelta) / 1_000_000_000.0
                cpuUsage = (cpuTimeSeconds / timeDelta) * 100.0
            } else {
                // 第一次采样，CPU 使用率为 0
                cpuUsage = 0
            }

            // 更新缓存
            previousCPUTimes[pid] = currentSample

            // 过滤掉 CPU 使用率过低的进程
            guard cpuUsage >= 0.5 else { continue }

            // 估算能耗（CPU% × 5W）
            let estimatedPowerMW = cpuUsage * 50.0

            let processInfo = ProcessEnergyInfo(
                id: pid,
                name: app.localizedName ?? "未知",
                bundleIdentifier: app.bundleIdentifier,
                icon: app.icon,
                cpuUsage: cpuUsage,
                estimatedPowerMW: estimatedPowerMW
            )
            processInfos.append(processInfo)
        }

        // 按能耗降序排序
        processes = processInfos.sorted { $0.estimatedPowerMW > $1.estimatedPowerMW }
        lastUpdateTime = Date()
        isRefreshing = false
    }

    func terminateProcess(pid: pid_t) -> Result<Void, ProcessError> {
        // 安全检查
        guard pid != getpid() && pid != 1 else {
            return .failure(.terminationFailed(pid: pid, reason: "不能终止系统关键进程"))
        }

        // 尝试优雅终止
        if let app = NSRunningApplication(processIdentifier: pid) {
            let terminated = app.terminate()
            if terminated {
                return .success(())
            }
        }

        // 强制终止
        let result = kill(pid, SIGTERM)
        if result == 0 {
            return .success(())
        } else {
            let errorMsg = String(cString: strerror(errno))
            return .failure(.terminationFailed(pid: pid, reason: errorMsg))
        }
    }
}

enum ProcessError: LocalizedError {
    case permissionDenied(pid: pid_t)
    case processNotFound(pid: pid_t)
    case terminationFailed(pid: pid_t, reason: String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let pid):
            return "无权限访问进程 \(pid)"
        case .processNotFound(let pid):
            return "进程 \(pid) 不存在或已退出"
        case .terminationFailed(let pid, let reason):
            return "终止进程 \(pid) 失败: \(reason)"
        }
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

private func getCPUInfo(for pid: pid_t) -> (totalTime: UInt64, timestamp: Date)? {
    var info = proc_taskinfo()
    let size = MemoryLayout<proc_taskinfo>.stride
    let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))

    guard result == Int32(size) else {
        return nil
    }

    // CPU 时间 = 用户态时间 + 系统态时间
    let totalTime = info.pti_total_user + info.pti_total_system
    return (totalTime: totalTime, timestamp: Date())
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
private let smartBatteryAmperageKey = "Amperage"
private let smartBatteryInstantAmperageKey = "InstantAmperage"
