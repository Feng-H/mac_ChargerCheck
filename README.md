# ChargingCheck

macOS 状态栏充电功率监视器，使用 IOKit 读取实时电压、电流并估算当前充电功率，同时展示适配器额定功率。支持以 Swift Package 形式构建，已经提供已打包的 `.app` 与 `.zip`。

## 安装 (Installation)

推荐使用 Homebrew 安装：

```bash
brew tap Feng-H/tap
brew install --cask chargingpowertool
```

或者直接使用一行命令安装：

```bash
brew install --cask Feng-H/tap/chargingpowertool
```

也可以在 [Releases](https://github.com/Feng-H/mac_ChargerCheck/releases) 页面下载最新版本的 `.dmg` 或 `.zip` 文件。

## 功能
- 状态栏常驻，显示当前充电功率（瓦）。
- 根据功率正负自动切换图标：正值显示充电图标，负值显示放电图标。
- 菜单中展示最新电池电压、电流、适配器额定功率以及更新时间。
- 若系统暂未提供某项数据，会显示 `--` 以避免误导。

## 目录结构
- `Sources/ChargingPowerTool/`：主程序（SwiftUI + IOKit）。
- `Dist/ChargingPowerTool.app`：已构建的应用包。
- `Dist/ChargingPowerTool.zip`：打包好的压缩文件，可直接分发。

## 构建与运行
```bash
git clone https://github.com/Feng-H/mac_ChargerCheck.git
cd mac_ChargerCheck
swift build         # Debug 构建
swift build -c release
swift run           # 调试模式运行（会在终端保持前台）
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

## 已知限制
- 部分机型/系统可能不公开实时电压或电流，界面会显示 `--`。
- 未使用私有 SMC 接口，无法保证在所有未来硬件上可用。

欢迎根据需要调整刷新频率、UI 样式或添加通知/日志等功能。***

