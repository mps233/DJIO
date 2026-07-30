# DJIO

<p align="center">
  <img src="docs/assets/djio-icon.png" width="160" alt="DJIO 应用图标">
</p>

DJIO 是一款原生 macOS 工具，可将受支持的蜂窝 USB 模块用作 Mac 的便携式
4G 网卡，并提供短信、接码和来电号码记录功能。它可以配置 ECM 网络、收发短信、
接收验证码，以及记录来电号码和时间。

DJIO 只记录来电号码，不能接听电话、传输通话音频、提供语音信箱，也不实现
VoWiFi/IMS 通话。

## 功能

- 将兼容模块配置为 ECM 网卡，并可转换第一代大疆 4G 模块的原厂 USB 身份
- 显示连接、SIM 卡、运营商、无线制式、信号和本机流量信息
- 收发短信，支持长短信、GSM 7-bit 和 Unicode
- 将验证码作为普通短信接收
- 为新短信和来电显示 macOS 通知
- 在本机保存短信、发件记录、来电记录和流量统计
- 支持菜单栏运行和登录时自动启动

## 界面预览

> 以下截图均使用内置演示数据，不包含真实短信、电话号码或网络信息。

### 连接

![DJIO 连接页面](docs/screenshots/connection.png)

### 短信

![DJIO 短信页面](docs/screenshots/messages.png)

### 来电

![DJIO 来电记录页面](docs/screenshots/calls.png)

## Mac 和 iPad

DJIO 本身运行于 macOS。

模块配置为 ECM 模式后，兼容的 USB-C iPad 也可以将其数据连接用作 USB
以太网。iPad 能否使用取决于模块固件、iPad 型号、iPadOS 版本、线材、USB
供电、APN 和运营商。

DJIO 不包含 iPadOS 应用。短信管理和来电提醒需要将模块连接到正在运行 DJIO
的 Mac。

## 硬件支持

| USB 标识 | 支持情况 |
| --- | --- |
| `2CA3:4006` | 第一代大疆 4G 模块的原厂 USB 身份；DJIO 可将其转换为 `2C7C:0125` 并配置 ECM，转换流程尚待原厂状态设备实机验证 |
| `2C7C:0125` | 转换后的 Quectel EC25 兼容身份；已实机验证，可直接使用 ECM、短信和来电记录 |

DJIO 也可以通过兼容的 `/dev/cu.*` AT 串口以 115200 波特率工作。

检测到原厂 `2CA3:4006` 时，经用户确认后，DJIO 会先使用
`AT+QCFG="usbcfg",...` 将模块持久转换为 `2C7C:0125`，再通过
`AT+QCFG="usbnet",1` 配置 ECM，并以 `AT+CFUN=1,1` 软重启模块。USB 身份转换
只修改模块内部配置，不会刷写或替换模块固件。设置断电后仍会保留。
转换和重新枚举验证期间，请只连接一只受支持的 4G 模块。

控制通道尽量使用标准 AT 指令，同时包含少量 Quectel 专用行为，因此支持 AT
指令的模块不一定能直接使用 DJIO。来电记录还依赖模块和运营商提供 `RING`、
`+CLIP` 或 `AT+CLCC` 信息。隐藏或无法获取的来电号码会记录为未知号码。

DJIO 不会分离 ECM 内核驱动、切换主机侧 USB configuration 或抢占 ECM 接口。
仅在用户明确确认后，应用会修改模块内部的 USB 身份和网络模式并执行软重启；
macOS 仍负责管理 ECM 网络接口。

## 构建

环境要求：

- 运行 macOS 26 的 Apple 芯片 Mac
- Xcode 26.6 或更高版本
- Homebrew `libusb` 和 `pkgconf`

```bash
brew install libusb pkgconf
swift test
./scripts/build-app.sh
open -n ../outputs/DJIO.app --args --demo
```

构建脚本会生成 `../outputs/DJIO.app`，嵌入 Homebrew 提供的 `libusb` 动态库，
重写其加载路径，并为应用添加本地临时签名。

## 本地数据与隐私

DJIO 不使用账号、分析统计、云同步或外部应用服务器。短信、发件状态、来电记录和
流量统计均保存在 `~/Library/Application Support/CellularBridge/`。这里有意
保留了旧版内部目录名，确保升级为 DJIO 后仍可继续使用已有数据。

你发送的短信和网络流量仍会经过移动运营商。通知内容是否在锁定屏幕上显示由
macOS 通知设置决定。流量统计来自 macOS 网络接口计数器，并非运营商账单数据。

## 限制

- DJIO 只记录来电号码和时间
- 不能接听、拒接或挂断电话
- 不提供通话音频、语音信箱、VoWiFi 或 IMS 通话
- 不保证支持列表之外的硬件
- 来电号码能否获取取决于模块、SIM 卡、运营商和网络

## 分发说明

当前嵌入的 Homebrew `libusb` 仅支持 arm64，并且以 macOS 26 为最低目标，适合
在当前配置上本地构建，但不适合作为通用二进制版本发布。正式分发时应嵌入面向预期
系统版本构建的通用 `libusb`，并使用 Developer ID 完成签名和公证。

## 独立声明

DJIO 是独立、非官方项目，与大疆、Quectel 或任何移动运营商均无关联。
