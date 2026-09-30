# ChargingCheck

macOS 状态栏充电功率监视器与进程能耗管理工具，使用 IOKit 读取实时电压、电流并估算当前充电功率，同时支持监控和管理高能耗应用程序。v2.2.0 起新增**图书馆模式**（一键关闭系统充电提示音）与**自定义充电提示音**，v2.3.0 新增**开机自启动**。支持以 Swift Package 形式构建，已经提供已打包的 `.app`、`.dmg` 与 `.zip`。

## 安装 (Installation)

### 方式一：使用 Homebrew（推荐）

**首次安装：**

```bash
# 添加 tap 仓库
brew tap Feng-H/tap

# 安装应用
brew install --cask chargingpowertool
```

或者使用一行命令直接安装：

```bash
brew install --cask Feng-H/tap/chargingpowertool
```

**更新到最新版本：**

```bash
brew upgrade --cask chargingpowertool
```

**卸载：**

```bash
brew uninstall --cask chargingpowertool
```

### 方式二：手动下载安装

在 [Releases](https://github.com/Feng-H/mac_ChargerCheck/releases) 页面下载最新版本：
- `.dmg` 文件：双击打开，拖拽应用到 Applications 文件夹
- `.zip` 文件：解压后双击运行

**首次运行提示：** 如果系统提示"无法验证开发者"，请右键点击应用，选择"打开"即可。

## 功能

### 充电功率监控
- 状态栏常驻，显示当前充电功率（瓦）。
- 根据功率正负自动切换图标：正值显示充电图标，负值显示放电图标。
- 菜单中展示最新电池电压、电流、适配器额定功率以及更新时间。
- 若系统暂未提供某项数据，会显示 `--` 以避免误导。

### 🆕 开机自启动（v2.3.0 新增）
- 状态栏菜单勾选「开机自启动」即可随登录自动启动，取消勾选即关闭
- 基于 SMAppService（macOS 13+）实现，无需辅助进程与管理员权限
- 若系统要求确认，在「系统设置 → 通用 → 登录项与扩展」中允许 ChargingPowerTool 即可

### 🆕 充电提示音控制（v2.2.0 新增）
- **关闭系统充电音（图书馆模式）**：一键关闭 macOS 插入充电器时系统播放的“叮”声，无需管理员密码，可随时恢复默认
  - 通过 `com.apple.PowerChime` 系统偏好项实现（正确写法为 `ChimeOnNoHardware = true`，旧教程的 `ChimeOnAllHardware -bool false` 在新系统上无效）
- **自定义充电提示音**：可选用应用自己播放提示音代替系统音
  - 支持插入 / 拔出充电器时分别开关
  - 内置 14 种系统提示音（Pop、Ping、Glass、Hero 等），也可导入自定义音频文件（aiff / wav / mp3 / m4a）
  - 独立音量控制，不影响系统音量；支持试听
- 基于 IOPowerSource 通知即时感知插拔（无需等待轮询）

### 🆕 进程能耗监控（v2.0.0 新增）
- 点击菜单"进程能耗监控..."打开专业监控窗口（快捷键 ⌘E）
- 实时显示所有应用的 CPU 使用率和估算能耗
- 支持按能耗、CPU、进程名称等多维度排序
- 能耗颜色编码：绿色（低）→ 黄色 → 橙色 → 红色（高）
- 一键终止高能耗进程（带安全确认对话框）
- 自动过滤 CPU 使用率低于 0.5% 的进程
- 数据每 5 秒自动刷新

## 目录结构
- `Sources/ChargingPowerTool/`：主程序（SwiftUI + IOKit）。
- `Packaging/`：打包模板（`Info.plist`、`AppIcon.icns`），用于组装 `.app`。
- `Dist/`：构建产物目录（`.app` / `.zip` / `.dmg`），已 gitignore，按下方「打包步骤」生成。

## 构建与运行
```bash
swift build              # Debug 构建
swift build -c release   # Release 构建
swift run                # 调试模式运行（会在终端保持前台）
```

## 打包步骤
```bash
# 1. 使用 Release 构建
swift build -c release

# 2. 组装 .app（模板在 Packaging/，发版时记得同步更新其中的版本号）
mkdir -p Dist/ChargingPowerTool.app/Contents/MacOS Dist/ChargingPowerTool.app/Contents/Resources
cp .build/release/ChargingPowerTool Dist/ChargingPowerTool.app/Contents/MacOS/
cp Packaging/Info.plist Dist/ChargingPowerTool.app/Contents/
cp Packaging/AppIcon.icns Dist/ChargingPowerTool.app/Contents/Resources/

# 3. ad-hoc 签名
codesign --force --deep -s - Dist/ChargingPowerTool.app

# 4. 打包 zip / dmg
cd Dist
zip -qry ChargingPowerTool.zip ChargingPowerTool.app
hdiutil create -volname ChargingPowerTool -srcfolder ChargingPowerTool.app -ov -format UDZO ChargingPowerTool.dmg
```

`Packaging/Info.plist` 中 `LSUIElement` 已设为 `true`（隐藏 Dock 图标，仅状态栏常驻）。

## 签名与公证（可选）
1. 使用 Developer ID 证书签名：
   ```bash
   codesign --deep --force --verify --timestamp \
     --options runtime \
     --sign "Developer ID Application: 你的姓名 (TEAMID)" \
     Dist/ChargingPowerTool.app
   ```
2. 压缩后提交 notarize：
   ```bash
   xcrun notarytool submit Dist/ChargingPowerTool.zip \
     --keychain-profile notarize-profile \
     --wait
   ```
3. 成功后执行 `xcrun stapler staple Dist/ChargingPowerTool.app`。

## 使用说明

### 充电监控
1. 启动应用后，状态栏会显示当前充电功率
2. 点击状态栏图标查看详细信息（电压、电流、适配器功率等）

### 进程能耗监控
1. 点击状态栏菜单中的"进程能耗监控..."
2. 窗口显示所有高 CPU 应用及其估算能耗
3. 点击列头可按不同维度排序
4. 选中进程后点击"终止进程"可关闭高能耗应用（需确认）

### 充电提示音控制（v2.2.0+）
1. 状态栏菜单勾选「图书馆模式」→ 一键关闭系统充电提示音（插入电源不再发声），再点一次恢复默认
2. 菜单「充电提示音设置...」（⌘,）可改用本应用播放提示音：插入 / 拔出分别开关、14 种内置系统音或导入自定义音频（aiff/wav/mp3/m4a）、独立音量与试听
3. 想完全静音：只开图书馆模式；想换声音：图书馆模式 + 自定义提示音

### 开机自启动（v2.3.0+）
1. 状态栏菜单勾选「开机自启动」即可随登录自动启动，取消勾选即关闭
2. 若系统要求确认，在「系统设置 → 通用 → 登录项与扩展」中允许一次即可

## 技术实现

### 充电功率采集
- 使用 `IOPSCopyPowerSourcesInfo` 获取电池基本信息
- 通过 `IOServiceMatching("AppleSmartBattery")` 查询详细电压电流
- 计算公式：功率 (W) = 电压 (V) × 电流 (A)

### 进程能耗估算
- 使用 `proc_pidinfo(PROC_PIDTASKINFO)` 获取进程 CPU 时间
- 通过两次采样计算 CPU 使用率
- 估算公式：能耗 (mW) ≈ CPU 使用率 (%) × 50mW
- 仅显示公开 API，无需 root 权限

## 已知限制
- **充电监控**：部分机型/系统可能不公开实时电压或电流，界面会显示 `--`
- **进程监控**：能耗为估算值（基于 CPU），不包含 GPU、网络等其他能耗
- 未使用私有 API，无法保证在所有未来硬件上可用

## 版本历史

### v2.3.0 (2026-09-30)
- 🎉 新增开机自启动：状态栏一键开关，基于 SMAppService（macOS 13+），无需辅助进程与管理员权限
- ✅ 修复全新安装时登录项状态误判为"不可用"的问题

### v2.2.0 (2026-09-30)
- 🎉 新增图书馆模式：一键关闭/恢复 macOS 系统充电提示音（PowerChime），无需管理员密码
- ✅ 自定义充电提示音：插入/拔出分别开关，14 种内置系统音或导入自定义音频，独立音量与试听
- ✅ 基于 IOPowerSource 通知即时感知插拔，不再等待轮询

### v2.1.0 (2026-01-31)
- 进程能耗监控功能增强与细节优化

### v2.0.0 (2026-01-31)
- 🎉 新增进程能耗监控功能
- ✅ 支持查看所有应用的 CPU 使用率和估算能耗
- ✅ 支持一键终止高能耗进程
- ✅ 专业的表格视图，支持多维度排序
- ✅ 能耗颜色编码，一目了然

### v1.0.0
- 基础充电功率监控
- 状态栏显示实时充电功率
- 菜单显示电池详细信息

欢迎根据需要调整刷新频率、UI 样式或添加通知/日志等功能。
