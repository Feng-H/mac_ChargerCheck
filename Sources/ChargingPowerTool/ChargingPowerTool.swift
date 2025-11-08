import SwiftUI
import AppKit
import IOKit
import IOKit.ps

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

@main
struct ChargingPowerToolApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

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

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private let powerProvider = PowerDataProvider()
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

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
        let quitItem = NSMenuItem(title: "退出 ChargingPowerTool", action: #selector(terminateApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
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

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        guard places >= 0 else { return self }
        let multiplier = pow(10.0, Double(places))
        return (self * multiplier).rounded() / multiplier
    }
}

private let appleRawCurrentKey = "AppleRawCurrent"
private let smartBatteryVoltageKey = "Voltage"
private let smartBatteryAmperageKey = "Amperage"
private let smartBatteryInstantAmperageKey = "InstantAmperage"
