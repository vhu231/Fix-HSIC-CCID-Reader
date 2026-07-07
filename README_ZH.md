# Fix-HSIC-CCID-Reader

[English README](README.md)

针对 Linux 上 **HSIC CCID-Reader**（USB `1d99:0016`）的 [libccid/ccid](https://github.com/LudovicRousseau/CCID) 补丁与安装脚本。

> **名称说明：** 本文中的 **HSIC** 指 [**上海华申智能卡应用系统有限公司**](https://ccid.apdu.fr/ccid/readers/HSIC_CCID-Reader.txt)（该 CCID 读卡器的制造商），而非其他使用相同缩写的机构或技术（例如 High-Speed Inter-Chip、硬件安全模块等）。

原版 [libccid/ccid](https://github.com/LudovicRousseau/CCID) 驱动（pcsc-lite 的 CCID IFD 驱动——Debian/Ubuntu 发行版包名为 `libccid`，其他发行版常见为 `ccid`）无法可靠地使用该读卡器：即使已插入 SIM，固件对 `GetSlotStatus` 仍始终返回 **「无 ICC 卡」**，驱动因此不会对卡上电。部分 SIM 返回的 ATR 还缺少 TCK 校验字节，会导致 `SCardConnect` 失败。

本项目从源码构建 [libccid/ccid](https://github.com/LudovicRousseau/CCID)，应用针对性补丁，并将修补后的驱动安装到 pcsc-lite 驱动目录。

## 读卡器规格

在 Linux 上识别为 **HSIC CCID-Reader**（`1d99:0016`）。完整 CCID 描述符见：[ccid.apdu.fr — HSIC_CCID-Reader](https://ccid.apdu.fr/ccid/readers/HSIC_CCID-Reader.txt)。

| 属性 | 值 |
|------|-----|
| 厂商 ID | `0x1D99`（HSIC） |
| 产品 ID | `0x0016` |
| 产品名称 | CCID-Reader |
| 固件版本（`bcdDevice`） | 1.00 |
| CCID 版本 | 1.10 |
| 卡槽数 | 1（`bMaxSlotIndex: 0`） |
| 供电电压 | 5.0 V、3.0 V |
| 协议 | T=0、T=1 |
| 时钟 | 4.000 MHz（默认与最高） |
| 波特率 | 10752、15625、31250、62500、125000、250000 bps |
| 特性 | TPDU 级交换（`dwFeatures: 0x00010000`） |
| 最大 CCID 消息长度 | 271 字节 |
| 端点 | bulk-IN、bulk-OUT、Interrupt-IN |

## 快速开始

```bash
git clone https://github.com/vhu231/Fix-HSIC-CCID-Reader.git
cd Fix-HSIC-CCID-Reader
chmod +x install.sh

# 推荐：基础卡在位检测修复（对合规卡安全，含物理 eSIM）
sudo ./install.sh install slot

# 若 SCardConnect 仍报 607 错误，可再启用 ATR 修复
sudo ./install.sh install all

./install.sh status
```

重新插拔读卡器或重启 `pcscd`，然后用 `pcsc_scan` 验证。

## 补丁集

| 集 | 补丁 | 修复内容 |
|----|------|----------|
| `slot` | `01_hsic_slot_status.patch` | 用去抖后的 `NotifySlotChange` + 在 `IFDHICCPresence` 轮询时做 ATR 探测，替代失效的 `GetSlotStatus`。**推荐默认。** |
| `atr` | `02_hsic_malformed_atr.patch` | 补全缺失的 ATR TCK 字节，必要时回退到默认 T=0 参数。 |
| `all` | 两者 | 当 (U)SIM 的 ATR 被原版驱动拒绝时使用。 |

**兼容性：** 对符合标准的卡（含物理 eSIM），仅 `slot` 通常即可。只有遇到 ATR / `SCardConnect` 错误时才需要 `atr` 或 `all`。

## 系统要求

- 已安装 pcsc-lite（`pcscd`）的 Linux 系统
- 安装/卸载需要 root 权限
- 构建工具：meson、ninja、gcc、flex、libusb、zlib（安装脚本会通过包管理器自动安装）

驱动基于上游 [libccid/ccid 1.6.2](https://github.com/LudovicRousseau/CCID) 构建，该版本已在支持读卡器列表中包含 `1d99:0016`。较旧发行版 `libccid`/`ccid` 包（< 1.6.2）可能无法识别该 VID/PID，需手动编辑 `Info.plist` —— 本构建无需此步骤。

## 配置

可在 `install.sh` 同目录下创建可选的 `.env` 文件：

```bash
CCID_VERSION=1.6.2   # 要构建的上游 libccid 标签
PATCH_SET=slot       # `install` 无参数时的默认补丁集
```

## 卸载

```bash
sudo ./install.sh uninstall
```

将移除补丁标记、解除对发行版 `libccid`/`ccid` 包的 hold（如 Debian/Ubuntu 的 `libccid`、Fedora/Arch 的 `ccid`），并恢复原版驱动。

## 背景

这些补丁最初为 [VoWiFi gateway](https://github.com/pagecat/vowifi_gateway) 项目开发，现作为独立修复维护，供在 Linux 上使用 HSIC 读卡器的用户参考。

### 各补丁说明

**01 — 卡槽状态：** 读卡器的中断端点会发送 `RDR_to_PC_NotifySlotChange` 消息。Notify 仅设置 `hsic_presence_pending` 标志（去抖）。每次 `IFDHICCPresence` 轮询时，驱动通过 `IccPowerOn`/ATR 探测卡在位状态，并恢复之前的上电状态。首次轮询且状态未知时会执行初始探测。

**02 — 畸形 ATR：** HSIC 固件在 ATR 末尾省略 TCK 字节。补丁在上电时按 ISO 7816-3 XOR 规则计算并补全。若解析仍失败，则应用默认 T=0 协议参数，以便继续 TPDU 交换。

## 许可证

补丁修改的是 [libccid/ccid](https://github.com/LudovicRousseau/CCID)，其许可证为 LGPL-2.1+。详见[上游 CCID 项目](https://github.com/LudovicRousseau/CCID)。
