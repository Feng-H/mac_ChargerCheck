import Foundation
import AppKit
import Darwin

// MARK: - 进程能耗数据采集
//
// 通过 proc_pidinfo 两次采样计算各进程 CPU 使用率，按启发式（CPU% × 50mW）估算能耗，
// 供进程能耗监控窗口（ProcessEnergyWindowView）展示。

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
        // Sample A
        await refresh()

        // Wait 1 second for differential sample to populate initial data
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Sample B (Immediate feedback)
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
        let allPIDs = getAllPIDs()
        let currentTimestamp = Date()

        // Optimize: Batch fetch NSRunningApplications for GUI apps
        let runningApps = NSWorkspace.shared.runningApplications
        var runningAppsMap: [pid_t: NSRunningApplication] = [:]
        for app in runningApps {
            runningAppsMap[app.processIdentifier] = app
        }

        for pid in allPIDs {
            // Get CPU Info
            guard let cpuInfo = getCPUInfo(for: pid) else {
                continue
            }

            let currentSample = CPUSample(totalTime: cpuInfo.totalTime, timestamp: cpuInfo.timestamp)

            // Calculate CPU Usage
            let cpuUsage: Double
            if let previousSample = previousCPUTimes[pid] {
                let timeDelta = currentSample.timestamp.timeIntervalSince(previousSample.timestamp)
                guard timeDelta > 0 else { continue }

                let cpuTimeDelta = max(0, currentSample.totalTime - previousSample.totalTime)
                // CPU time is in ns
                let cpuTimeSeconds = Double(cpuTimeDelta) / 1_000_000_000.0
                cpuUsage = (cpuTimeSeconds / timeDelta) * 100.0

                // Update cache
                previousCPUTimes[pid] = currentSample

                // Filter: Show processes with > 0.1% CPU to include active background tasks
                // but reduce noise from completely idle processes
                if cpuUsage < 0.1 {
                    continue
                }
            } else {
                // First sample, save baseline
                previousCPUTimes[pid] = currentSample
                continue
            }

            // Estimate Power (CPU% * 50mW - heuristic)
            let estimatedPowerMW = cpuUsage * 50.0

            // Metadata
            let name: String
            let bundleID: String?
            let icon: NSImage?

            if let app = runningAppsMap[pid] {
                name = app.localizedName ?? getProcessName(pid: pid) ?? "Process \(pid)"
                bundleID = app.bundleIdentifier
                icon = app.icon
            } else {
                name = getProcessName(pid: pid) ?? "Process \(pid)"
                bundleID = nil
                icon = nil
            }

            let processInfo = ProcessEnergyInfo(
                id: pid,
                name: name,
                bundleIdentifier: bundleID,
                icon: icon,
                cpuUsage: cpuUsage,
                estimatedPowerMW: estimatedPowerMW
            )
            processInfos.append(processInfo)
        }

        // Clean up cache for terminated processes
        let currentPIDSet = Set(allPIDs)
        let cachedPIDs = Array(previousCPUTimes.keys)
        for pid in cachedPIDs {
            if !currentPIDSet.contains(pid) {
                previousCPUTimes.removeValue(forKey: pid)
            }
        }

        // Sort descending by power
        processes = processInfos.sorted { $0.estimatedPowerMW > $1.estimatedPowerMW }
        lastUpdateTime = currentTimestamp
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

// MARK: - 进程信息辅助

private func getAllPIDs() -> [pid_t] {
    let limit = 4096 // Typical pid max
    var pids = [pid_t](repeating: 0, count: limit)
    let count = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * limit))
    if count > 0 {
        // proc_listallpids returns number of bytes, so divide by size of pid_t
        let numPids = Int(count) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(numPids))
    }
    return []
}

private func getProcessName(pid: pid_t) -> String? {
    var buffer = [Int8](repeating: 0, count: 4096)
    let result = proc_name(pid, &buffer, UInt32(buffer.count))
    if result > 0 {
        let validBytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: validBytes, as: UTF8.self)
    }
    return nil
}

private func getProcessPath(pid: pid_t) -> String? {
    var buffer = [Int8](repeating: 0, count: 4096)
    let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    if result > 0 {
        let validBytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: validBytes, as: UTF8.self)
    }
    return nil
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
