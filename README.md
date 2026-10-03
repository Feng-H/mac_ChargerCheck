# ChargingCheck

[简体中文](#简体中文) · [English](#english)

---

## 简体中文

macOS 状态栏充电功率监视器与进程能耗管理工具。基于 IOKit 实时读取电压 / 电流并估算充电功率，内置**图书馆模式**（一键静音系统充电提示音）、**自定义充电提示音**、**进程能耗监控**与**开机自启动**。支持 Swift Package 构建，提供 `.dmg` / `.zip` 安装包。

### 安装

**方式一：Homebrew（推荐）**

```bash
brew install --cask Feng-H/tap/chargingpowertool   # 安装
brew upgrade --cask chargingpowertool               # 更新
brew uninstall --cask chargingpowertool             # 卸载
```

**方式二：手动下载**

在 [Releases](https://github.com/Feng-H/mac_ChargerCheck/releases) 页面下载：
- `.dmg`：双击打开，将应用拖入 Applications 文件夹
- `.zip`：解压后双击运行

> 首次运行若提示"无法验证开发者"，右键点击应用选择"打开"即可。

### 功能

#### 充电功率监控
- 状态栏常驻显示当前充电功率（瓦）；图标三态：正在充电（实心闪电）/ 已接电源·电池已满（空心闪电）/ 使用电池（斜杠闪电）
- 菜单展示电池电压、电流、适配器额定功率与更新时间（底部显示当前版本号）；数据缺失时显示 `--`
- 基于 IOPowerSource 通知即时感知插拔，同时每 5 秒定时刷新

#### 充电提示音控制
- **图书馆模式**：一键关闭 / 恢复 macOS 插入充电器时系统播放的提示音（PowerChime），无需管理员密码
  - 通过 `com.apple.PowerChime` 偏好项实现（正确写法为 `ChimeOnNoHardware = true`，网上旧教程的 `ChimeOnAllHardware -bool false` 在新系统上无效）
- **自定义提示音**：可改由本应用播放提示音
  - 插入 / 拔出充电器分别开关；14 种内置系统音（Pop、Ping、Glass、Hero 等）或导入自定义音频（aiff / wav / mp3 / m4a）
  - 独立音量控制（不影响系统音量），支持试听；设置入口：菜单「充电提示音设置...」（⌘,）

#### 进程能耗监控
- 菜单「进程能耗监控...」（⌘E）打开监控窗口，实时显示各应用 CPU 使用率与估算能耗
- 多维度排序、能耗颜色编码（绿 → 黄 → 橙 → 红）、一键终止高能耗进程（带确认对话框）
- 自动过滤低 CPU 进程，数据每 5 秒刷新

#### 开机自启动
- 菜单勾选「开机自启动」即可随登录启动，基于 SMAppService（macOS 13+），无需辅助进程与管理员权限
- 若系统要求确认，在「系统设置 → 通用 → 登录项与扩展」中允许一次即可

### 目录结构
- `Sources/ChargingPowerTool/`：主程序（SwiftUI + IOKit）
- `Packaging/`：打包模板（`Info.plist`、`AppIcon.icns`），用于组装 `.app`
- `Dist/`：构建产物目录（已 gitignore），按「打包步骤」生成

### 构建与打包

```bash
# 构建
swift build              # Debug
swift build -c release   # Release
swift run                # 调试运行（终端前台）

# 组装 .app（模板在 Packaging/，发版时记得同步更新其中版本号）
mkdir -p Dist/ChargingPowerTool.app/Contents/MacOS Dist/ChargingPowerTool.app/Contents/Resources
cp .build/release/ChargingPowerTool Dist/ChargingPowerTool.app/Contents/MacOS/
cp Packaging/Info.plist Dist/ChargingPowerTool.app/Contents/
cp Packaging/AppIcon.icns Dist/ChargingPowerTool.app/Contents/Resources/

# ad-hoc 签名（Packaging/Info.plist 中 LSUIElement=true，隐藏 Dock 图标仅留状态栏）
codesign --force --deep -s - Dist/ChargingPowerTool.app

# 打包 zip / dmg
cd Dist
zip -qry ChargingPowerTool.zip ChargingPowerTool.app
hdiutil create -volname ChargingPowerTool -srcfolder ChargingPowerTool.app -ov -format UDZO ChargingPowerTool.dmg
```

> 如需 Developer ID 签名与公证：`codesign --options runtime --sign "Developer ID Application: ..."` 后用 `xcrun notarytool submit` 提交并 `stapler`。

### 技术实现
- **充电功率**：`IOPSCopyPowerSourcesInfo` + `IOServiceMatching("AppleSmartBattery")` 读取电压 / 电流，功率 = 电压 × 电流
- **进程能耗**：`proc_pidinfo(PROC_PIDTASKINFO)` 两次采样算 CPU 使用率，能耗 ≈ CPU% × 50mW（启发式估算）
- **充电音控制**：`defaults write com.apple.PowerChime ChimeOnNoHardware -bool true` + `killall PowerChime`
- **开机自启**：`SMAppService.mainApp` 注册登录项
- 仅使用公开 API，无需 root 权限

### 已知限制
- 部分机型 / 系统可能不公开实时电压或电流，界面显示 `--`
- 进程能耗为基于 CPU 的估算值，不含 GPU、网络等
- 未使用私有 API，无法保证在所有未来硬件上可用

### 版本历史
- **v2.3.3**（2026-10-03）：修复充电功率恒为 0W——部分机型 IOPS 的 Current 字段恒为 0（占位值），现改为在多来源读数中优先取非零值；状态栏真正启用三态图标（v2.3.1 的三态逻辑此前未生效）；功率显示保留一位小数
- **v2.3.2**（2026-09-30）：菜单底部新增「版本 vX.Y.Z」显示
- **v2.3.1**（2026-09-30）：状态栏图标三态化（正在充电/已接电源·已满/使用电池），修复插电但电池已满时与用电池图标相同的问题；功率显示符号规范化
- **v2.3.0**（2026-09-30）：新增开机自启动（SMAppService 一键开关）；修复全新安装时登录项状态误判
- **v2.2.0**（2026-09-30）：新增图书馆模式与自定义充电提示音；IOPS 通知即时感知插拔
- **v2.1.0**（2026-01-31）：进程能耗监控增强与细节优化
- **v2.0.0**（2026-01-31）：新增进程能耗监控
- **v1.0.0**：基础充电功率监控

---

## English

A macOS menu-bar utility for monitoring charging power and managing process energy. Built on IOKit for real-time voltage/current readings and estimated charging wattage, featuring **Library Mode** (one-click mute of the system charging chime), **custom charging sounds**, a **process energy monitor**, and **launch-at-login**. Ships as a Swift Package with `.dmg` / `.zip` builds.

### Installation

**Option 1: Homebrew (recommended)**

```bash
brew install --cask Feng-H/tap/chargingpowertool   # install
brew upgrade --cask chargingpowertool               # upgrade
brew uninstall --cask chargingpowertool             # uninstall
```

**Option 2: Manual download**

Grab the latest build from [Releases](https://github.com/Feng-H/mac_ChargerCheck/releases):
- `.dmg`: open and drag the app to your Applications folder
- `.zip`: unzip and run

> On first launch, if macOS says the app "can't be verified", right-click the app and choose "Open".

### Features

#### Charging Power Monitor
- Live charging wattage in the menu bar; three-state icon: charging (solid bolt) / on AC with full battery (outline bolt) / on battery (slashed bolt)
- Menu details: battery voltage, current, adapter rated power, update time, and app version (`--` when unavailable)
- Instant plug/unplug detection via IOPowerSource notifications, plus a 5-second refresh timer

#### Charging Sound Control
- **Library Mode**: one-click mute/restore of the macOS charging chime (PowerChime), no admin password needed
  - Implemented via the `com.apple.PowerChime` preference domain (the correct off-switch is `ChimeOnNoHardware = true`; the widely-circulated `ChimeOnAllHardware -bool false` no longer works on recent macOS)
- **Custom sounds**: let this app play the charge notification instead
  - Separate toggles for charger connect/disconnect; 14 built-in system sounds or import your own audio (aiff / wav / mp3 / m4a)
  - Independent volume (does not touch system volume) with preview; configure via "Charging Sound Settings..." (⌘,)

#### Process Energy Monitor
- Window via "Process Energy Monitor..." (⌘E): live CPU usage and estimated energy per app
- Multi-column sorting, color-coded energy levels (green → yellow → orange → red), one-click terminate with confirmation
- Idle processes filtered out; refreshes every 5 seconds

#### Launch at Login
- Toggle "Launch at Login" in the menu; built on SMAppService (macOS 13+), no helper process or admin rights
- If macOS asks for confirmation, allow it once under System Settings → General → Login Items & Extensions

### Project Layout
- `Sources/ChargingPowerTool/`: the app (SwiftUI + IOKit)
- `Packaging/`: bundle templates (`Info.plist`, `AppIcon.icns`) used to assemble the `.app`
- `Dist/`: build output (gitignored), produced by the packaging steps below

### Build & Package

```bash
# Build
swift build              # debug
swift build -c release   # release
swift run                # run in foreground (debugging)

# Assemble the .app (templates live in Packaging/; bump the version there when releasing)
mkdir -p Dist/ChargingPowerTool.app/Contents/MacOS Dist/ChargingPowerTool.app/Contents/Resources
cp .build/release/ChargingPowerTool Dist/ChargingPowerTool.app/Contents/MacOS/
cp Packaging/Info.plist Dist/ChargingPowerTool.app/Contents/
cp Packaging/AppIcon.icns Dist/ChargingPowerTool.app/Contents/Resources/

# Ad-hoc code sign (Packaging/Info.plist sets LSUIElement=true: menu-bar only, no Dock icon)
codesign --force --deep -s - Dist/ChargingPowerTool.app

# Package zip / dmg
cd Dist
zip -qry ChargingPowerTool.zip ChargingPowerTool.app
hdiutil create -volname ChargingPowerTool -srcfolder ChargingPowerTool.app -ov -format UDZO ChargingPowerTool.dmg
```

> For Developer ID signing & notarization: sign with `codesign --options runtime --sign "Developer ID Application: ..."` then submit via `xcrun notarytool submit` and staple.

### Technical Notes
- **Charging power**: `IOPSCopyPowerSourcesInfo` + `IOServiceMatching("AppleSmartBattery")` for voltage/current; watts = volts × amps
- **Process energy**: CPU usage from two `proc_pidinfo(PROC_PIDTASKINFO)` samples; energy ≈ CPU% × 50mW (heuristic)
- **Chime control**: `defaults write com.apple.PowerChime ChimeOnNoHardware -bool true` + `killall PowerChime`
- **Launch at login**: registers a login item via `SMAppService.mainApp`
- Public APIs only; no root required

### Known Limitations
- Some machines/systems do not expose live voltage/current; the UI shows `--`
- Process energy is a CPU-based estimate (excludes GPU, network, etc.)
- No private APIs are used, so future hardware support can't be guaranteed

### Version History
- **v2.3.3** (2026-10-03): fix wattage stuck at 0W — on some models the IOPS `Current` field is always 0 (placeholder); readings from multiple sources are now merged, preferring the first non-zero one; actually wire up the three-state menu-bar icon (the v2.3.1 logic was never applied); show wattage with one decimal
- **v2.3.2** (2026-09-30): show the app version at the bottom of the menu
- **v2.3.1** (2026-09-30): three-state menu-bar icon (charging / on AC, battery full / on battery); fixed icons colliding between "plugged in, battery full" and "on battery"; normalized wattage sign
- **v2.3.0** (2026-09-30): launch-at-login toggle (SMAppService); fix login-item state misjudged on fresh installs
- **v2.2.0** (2026-09-30): Library Mode + custom charging sounds; instant plug/unplug detection via IOPS notifications
- **v2.1.0** (2026-01-31): process energy monitor improvements
- **v2.0.0** (2026-01-31): process energy monitor
- **v1.0.0**: initial charging power monitor

---

欢迎根据需要调整刷新频率、UI 样式或添加新功能。Feel free to tweak refresh intervals, UI, or add new features.
