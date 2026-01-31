# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

ChargingPowerTool 是一个 macOS 状态栏应用,实时监控并显示 Mac 的充电功率。使用 SwiftUI + IOKit 构建,通过读取系统电池和电源适配器信息计算当前充电功率(W)。

## 核心命令

### 开发构建
```bash
swift build              # Debug 构建
swift run                # 运行应用(前台模式,用于调试)
```

### 发布构建和打包
```bash
# 1. Release 构建
swift build -c release

# 2. 更新 .app 包中的可执行文件
cp .build/release/ChargingPowerTool Dist/ChargingPowerTool.app/Contents/MacOS/ChargingPowerTool

# 3. 打包成 zip 用于分发
cd Dist
zip -qry ChargingPowerTool.zip ChargingPowerTool.app
```

### 代码签名(可选)
```bash
codesign --deep --force --verify --timestamp \
  --options runtime \
  --sign "Developer ID Application: 你的姓名 (TEAMID)" \
  Dist/ChargingPowerTool.app

xcrun notarytool submit Dist/ChargingPowerTool.zip \
  --keychain-profile notarize-profile \
  --wait

xcrun stapler staple Dist/ChargingPowerTool.app
```

## 架构说明

### 代码结构
整个应用包含在单个 Swift 文件中 ([Sources/ChargingPowerTool/ChargingPowerTool.swift](Sources/ChargingPowerTool/ChargingPowerTool.swift)),采用模块化设计:

1. **ChargingPowerSnapshot**: 数据快照结构体,封装某一时刻的电池状态(电压、电流、功率、适配器额定功率)

2. **MenuBarAppDelegate**: 核心应用逻辑
   - 管理状态栏图标和菜单
   - 使用 5 秒定时器刷新 UI
   - 根据功率正负值动态切换图标(`bolt.fill` 充电 / `bolt.slash` 放电)
   - 设置为 `.accessory` 模式,不显示 Dock 图标

3. **PowerDataProvider**: IOKit 数据采集层
   - 使用 `IOPSCopyPowerSourcesInfo()` 获取电池基本信息
   - 使用 `IOPSCopyExternalPowerAdapterDetails()` 获取适配器额定功率
   - 查询 `AppleSmartBattery` IOKit 服务获取详细电压电流数据
   - 计算功率: `P = V × I`

### IOKit 数据来源优先级
代码尝试多个数据源以提高兼容性:

**电压获取**:
1. `IOPSCopyPowerSourcesInfo` → `kIOPSVoltageKey`
2. `AppleSmartBattery` → `Voltage` 属性

**电流获取**:
1. `IOPSCopyPowerSourcesInfo` → `AppleRawCurrent` (优先)
2. `IOPSCopyPowerSourcesInfo` → `kIOPSCurrentKey`
3. `AppleSmartBattery` → `Amperage`
4. `AppleSmartBattery` → `InstantAmperage`

### 应用配置
- **Info.plist**: `LSUIElement = true` 隐藏 Dock 图标,仅显示状态栏
- **最低系统**: macOS 13.0
- **刷新频率**: 5 秒

## 已知限制

- 部分 Mac 机型可能不公开实时电压/电流数据,界面会显示 `--`
- 未使用私有 SMC 接口,仅依赖公开的 IOKit API
- 功率计算基于瞬时电压电流,可能存在波动
