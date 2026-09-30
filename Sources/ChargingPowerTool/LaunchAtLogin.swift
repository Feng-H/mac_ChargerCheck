import Foundation
import ServiceManagement

// MARK: - 开机自启动控制
//
// 基于 SMAppService（macOS 13+）将主应用注册为登录项：
// - 无需独立的辅助（LoginItem）进程，也无需管理员权限
// - 部分系统版本注册后需要用户在「系统设置 → 通用 → 登录项」中手动允许

@MainActor
final class LoginItemController: ObservableObject {
    static let shared = LoginItemController()

    enum LaunchState {
        case enabled
        case disabled
        case requiresApproval
        /// 未经 .app 应用包运行（如 swift run 调试），无法注册
        case unavailable
    }

    enum ToggleResult {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
        case failed(String)
    }

    @Published private(set) var state: LaunchState = .disabled

    func refreshState() {
        state = Self.state(from: SMAppService.mainApp.status)
    }

    /// 切换 开 / 关。返回结果供调用方展示确认弹窗等反馈。
    func toggle() -> ToggleResult {
        switch SMAppService.mainApp.status {
        case .enabled:
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                return .failed("取消开机自启动失败：\(error.localizedDescription)")
            }
        case .requiresApproval:
            // 已注册、等待用户在系统设置中允许，不重复注册
            return .requiresApproval
        case .notRegistered, .notFound:
            // 注意：全新安装时 Background Task Management 尚未记录过本应用，
            // status 会返回 .notFound——这并不代表不可用，仍需调用 register()，
            // 成功后状态才会变为 .enabled / .requiresApproval。
            do {
                try SMAppService.mainApp.register()
            } catch {
                return .failed("设置开机自启动失败：\(error.localizedDescription)")
            }
        @unknown default:
            return .unavailable
        }

        refreshState()
        switch state {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .disabled: return .disabled
        case .unavailable: return .unavailable
        }
    }

    private static func state(from status: SMAppService.Status) -> LaunchState {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // .notFound 多为“从未注册过”的初始状态，仍可尝试注册，归为关闭而非不可用
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .unavailable
        }
    }
}
