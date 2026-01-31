# ChargingCheck

macOS 状态栏充电功率监视器与进程能耗管理工具，使用 IOKit 读取实时电压、电流并估算当前充电功率，同时支持监控和管理高能耗应用程序。支持以 Swift Package 形式构建，已经提供已打包的 `.app` 与 `.zip`。

## 功能

### 充电功率监控
- 状态栏常驻，显示当前充电功率（瓦）。
- 根据功率正负自动切换图标：正值显示充电图标，负值显示放电图标。
- 菜单中展示最新电池电压、电流、适配器额定功率以及更新时间。
- 若系统暂未提供某项数据，会显示 `--` 以避免误导。

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
- `Dist/ChargingPowerTool.app`：已构建的应用包。
- `Dist/ChargingPowerTool.zip`：打包好的压缩文件，可直接分发。

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

# 2. 更新 .app 内可执行文件
cp .build/release/ChargingPowerTool Dist/ChargingPowerTool.app/Contents/MacOS/ChargingPowerTool

# 3. 打包成 zip
cd Dist
zip -qry ChargingPowerTool.zip ChargingPowerTool.app
```

如需重新构建 Info.plist，可参考 `Dist/ChargingPowerTool.app/Contents/Info.plist`（`LSUIElement` 已设为 `true`，隐藏 Dock 图标）。

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

