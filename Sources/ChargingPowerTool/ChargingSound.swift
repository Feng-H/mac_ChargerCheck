import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PowerChime 命令封装
//
// macOS 在插入充电器时通过系统服务 PowerChime.app 播放提示音（"叮"）。
// 由 com.apple.PowerChime 偏好域控制，逻辑（反汇编结论）：
//
//   ChimeOnAllHardware == true            → 响
//   两者均 false / 未设置（默认）           → 由硬件判定（USB-C 笔记本默认响）
//   ChimeOnAllHardware == false
//   且 ChimeOnNoHardware == true          → 不响（唯一的关闭组合）
//
// 注意：网上流传的 `ChimeOnAllHardware -bool false` 在新系统上无效，
// `ChimeOnNoHardware` 必须设为 **true** 才能真正静音。

enum PowerChimeCommands {
    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "PowerChimeCommands",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "`\((path as NSString).lastPathComponent) \(arguments.joined(separator: " "))` 退出码 \(process.terminationStatus)"]
            )
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 容忍失败的命令执行（如 killall 一个未在运行的进程、delete 一个不存在的键）
    @discardableResult
    private static func runTolerant(_ path: String, _ arguments: [String]) -> String {
        (try? run(path, arguments)) ?? ""
    }

    /// 读取系统充电音是否已被关闭（ChimeOnNoHardware == 1）
    static func readDisabledState() -> Bool {
        let output = runTolerant("/usr/bin/defaults", ["read", "com.apple.PowerChime", "ChimeOnNoHardware"])
        return output == "1"
    }

    /// 开启 / 关闭系统充电音。无需管理员权限。
    static func setDisabled(_ disabled: Bool) throws {
        if disabled {
            // 唯一的静音组合：AllHardware=false + NoHardware=true
            try run("/usr/bin/defaults", ["write", "com.apple.PowerChime", "ChimeOnAllHardware", "-bool", "false"])
            try run("/usr/bin/defaults", ["write", "com.apple.PowerChime", "ChimeOnNoHardware", "-bool", "true"])
        } else {
            // 恢复出厂默认：移除两个键（笔记本默认"响"）
            runTolerant("/usr/bin/defaults", ["delete", "com.apple.PowerChime", "ChimeOnNoHardware"])
            runTolerant("/usr/bin/defaults", ["delete", "com.apple.PowerChime", "ChimeOnAllHardware"])
        }
        // PowerChime 由 launchd 按需拉起，每次事件都会重新读取偏好；
        // 结束常驻实例确保下一次插电立即生效。
        runTolerant("/usr/bin/killall", ["PowerChime"])
    }
}

// MARK: - 系统充电音状态控制器

@MainActor
final class SystemChimeController: ObservableObject {
    static let shared = SystemChimeController()

    /// nil 表示尚未读取到状态
    @Published private(set) var isDisabled: Bool?
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?

    func refreshState() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            isDisabled = await Self.readState()
            isBusy = false
        }
    }

    func setDisabled(_ disabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        Task {
            do {
                try await Self.apply(disabled: disabled)
                isDisabled = disabled
            } catch {
                lastError = "设置失败：\(error.localizedDescription)"
                isDisabled = await Self.readState()
            }
            isBusy = false
        }
    }

    private static func readState() async -> Bool {
        await Task.detached(priority: .utility) {
            PowerChimeCommands.readDisabledState()
        }.value
    }

    private static func apply(disabled: Bool) async throws {
        try await Task.detached(priority: .utility) {
            try PowerChimeCommands.setDisabled(disabled)
        }.value
    }
}

// MARK: - 自定义提示音设置

@MainActor
final class ChargingSoundSettings: ObservableObject {
    static let shared = ChargingSoundSettings()

    /// Picker 中"自定义音频"选项的 tag
    static let customSoundTag = "__custom_sound__"

    /// 系统内置提示音（/System/Library/Sounds）
    static let builtinSounds: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    private let defaults: UserDefaults

    @Published var playOnConnect: Bool {
        didSet { defaults.set(playOnConnect, forKey: "sound.playOnConnect") }
    }
    @Published var playOnDisconnect: Bool {
        didSet { defaults.set(playOnDisconnect, forKey: "sound.playOnDisconnect") }
    }
    @Published var selectedSound: String {
        didSet { defaults.set(selectedSound, forKey: "sound.selected") }
    }
    @Published var customSoundPath: String? {
        didSet {
            if let customSoundPath {
                defaults.set(customSoundPath, forKey: "sound.customPath")
            } else {
                defaults.removeObject(forKey: "sound.customPath")
            }
        }
    }
    @Published var customSoundDisplayName: String? {
        didSet {
            if let customSoundDisplayName {
                defaults.set(customSoundDisplayName, forKey: "sound.customDisplayName")
            } else {
                defaults.removeObject(forKey: "sound.customDisplayName")
            }
        }
    }
    /// 0.0 ~ 1.0，仅作用于本应用播放的提示音，不改动系统音量
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: "sound.volume") }
    }

    init() {
        let defaults = UserDefaults(suiteName: "user.feng-h.ChargingPowerTool") ?? .standard
        self.defaults = defaults
        defaults.register(defaults: [
            "sound.playOnConnect": false,
            "sound.playOnDisconnect": false,
            "sound.selected": "Pop",
            "sound.volume": 0.6,
        ])
        playOnConnect = defaults.bool(forKey: "sound.playOnConnect")
        playOnDisconnect = defaults.bool(forKey: "sound.playOnDisconnect")
        selectedSound = defaults.string(forKey: "sound.selected") ?? "Pop"
        customSoundPath = defaults.string(forKey: "sound.customPath")
        customSoundDisplayName = defaults.string(forKey: "sound.customDisplayName")
        volume = defaults.double(forKey: "sound.volume")
        // 兼容旧数据：指向已删除的自定义文件时回退到内置音
        if selectedSound == Self.customSoundTag, customSoundPath == nil {
            selectedSound = "Pop"
        }
    }

    // MARK: 播放

    func playSelectedSound() {
        guard let sound = makeSelectedSound() else { return }
        sound.volume = Float(volume)
        sound.play()
    }

    private func makeSelectedSound() -> NSSound? {
        if selectedSound == Self.customSoundTag, let path = customSoundPath {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return NSSound(contentsOf: url, byReference: true)
        }
        return NSSound(named: selectedSound)
    }
}

// MARK: - 设置窗口视图

struct ChargingSoundSettingsView: View {
    @ObservedObject private var chime = SystemChimeController.shared
    @ObservedObject private var settings = ChargingSoundSettings.shared
    @State private var importError: String?

    var body: some View {
        Form {
            Section("系统充电提示音（macOS 插入电源时播放）") {
                Toggle(isOn: systemChimeBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("关闭系统充电音（图书馆静音）")
                        Text(systemChimeStatusLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(chime.isBusy)

                if let error = chime.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Text("系统充电音由 PowerChime 服务播放，即使系统音量调低也可能发声。此开关通过系统偏好项直接关闭，无需管理员密码，可随时恢复默认。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("自定义充电提示音（由本应用播放，音量可控）") {
                Toggle("插入充电器时播放", isOn: $settings.playOnConnect)
                Toggle("拔出充电器时播放", isOn: $settings.playOnDisconnect)

                Picker("提示音", selection: $settings.selectedSound) {
                    ForEach(ChargingSoundSettings.builtinSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if settings.customSoundPath != nil {
                        Text(settings.customSoundDisplayName ?? "自定义音频")
                            .tag(ChargingSoundSettings.customSoundTag)
                    }
                }

                HStack {
                    Button("选择音频文件…") { importSoundFile() }
                    Text("支持 aiff / wav / mp3 / m4a")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Slider(value: $settings.volume, in: 0...1)
                    Text("\(Int(settings.volume * 100))%")
                        .monospacedDigit()
                        .frame(width: 40)
                    Button("试听") { settings.playSelectedSound() }
                }
            }

            Section {
                Text("推荐组合：想“更换”充电音时，关闭系统充电音 + 开启自定义提示音并选择喜欢的声音；想完全静音则只关闭系统充电音。直接替换系统提示音文件需要关闭 SIP，不推荐。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 580)
        .onAppear { chime.refreshState() }
        .alert(
            "导入音频失败",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var systemChimeBinding: Binding<Bool> {
        Binding(
            get: { chime.isDisabled ?? false },
            set: { chime.setDisabled($0) }
        )
    }

    private var systemChimeStatusLabel: String {
        if chime.isBusy {
            return "正在应用设置…"
        }
        switch chime.isDisabled {
        case .some(true): return "当前状态：已关闭（插入电源不再发声）"
        case .some(false): return "当前状态：系统默认（插入电源会发声）"
        case .none: return "当前状态：正在读取…"
        }
    }

    // MARK: 自定义音频导入

    private func importSoundFile() {
        let panel = NSOpenPanel()
        panel.title = "选择提示音文件"
        panel.message = "选择一个音频文件作为充电提示音（将复制到应用支持目录）"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let storedURL = try Self.storeCustomSound(from: url)
            settings.customSoundPath = storedURL.path
            settings.customSoundDisplayName = url.deletingPathExtension().lastPathComponent
            settings.selectedSound = ChargingSoundSettings.customSoundTag
        } catch {
            importError = error.localizedDescription
        }
    }

    /// 将音频复制到应用支持目录，避免原文件被移动后提示音失效
    private static func storeCustomSound(from url: URL) throws -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChargingPowerTool/Sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}
