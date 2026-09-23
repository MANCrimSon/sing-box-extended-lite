# OpenWrt sing-box-extended Lite

[![Build and Release Lite](https://github.com/MANCrimSon/sing-box-extended-lite/actions/workflows/build-and-release.yml/badge.svg)](https://github.com/MANCrimSon/sing-box-extended-lite/actions/workflows/build-and-release.yml)
[![GitHub Release](https://img.shields.io/github/v/release/MANCrimSon/sing-box-extended-lite?style=flat&color=3388ff)](https://github.com/MANCrimSon/sing-box-extended-lite/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

Lightweight, bloat-free OpenWrt builds of [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended). Tailored specifically for home routers running Podkop, Zero-Block, or custom transparent proxies.

---

## ⚡ 1-Line Install / Update (OpenWrt)

Run directly in router SSH terminal:

```sh
sh <(curl -fsSL https://raw.githubusercontent.com/MANCrimSon/sing-box-extended-lite/main/install.sh)
```

*Or via wget if curl is not installed:*
```sh
sh <(wget -qO- https://raw.githubusercontent.com/MANCrimSon/sing-box-extended-lite/main/install.sh)
```

The script automatically detects CPU architecture and flash capacity. If available root flash is below 55 MB, it safely selects the **UPX Lite (~9.5–12.5 MB)** build; otherwise, it installs the **Pure ELF (~46 MB)** build.

### Manual Overrides:
```sh
# Force uncompressed Pure ELF build (~46 MB)
sh <(curl -fsSL https://raw.githubusercontent.com/MANCrimSon/sing-box-extended-lite/main/install.sh) --normal

# Force compressed UPX Lite build (~9.5–12.5 MB)
sh <(curl -fsSL https://raw.githubusercontent.com/MANCrimSon/sing-box-extended-lite/main/install.sh) --compressed

# Install specific version
sh <(curl -fsSL https://raw.githubusercontent.com/MANCrimSon/sing-box-extended-lite/main/install.sh) v1.14.1-extended-2.7.2
```

---

## ✂️ What Was Stripped vs Kept

Standard upstream compiles heavy enterprise/desktop services into a single monolithic binary (>58 MB). We stripped non-router deadweight to save flash and RAM:

### ✅ Kept (Router & VPN Core)
- **VLESS Reality + XTLS Vision** (`with_utls`): Full TLS 1.3 masquerading (`gateway.icloud.com`) and ClientHello fingerprinting.
- **QUIC Transports** (`with_quic`): Hysteria 2 and TUIC v5.
- **WireGuard** (`with_wireguard`): Kernel & Go WireGuard / AmneziaWG support.
- **Clash API** (`with_clash_api`): External controller for LuCI, Podkop, MetaCubeX, and YACD.
- **Core Engine**: TPROXY, TUN, RuleSet binary (`.srs`), GeoIP/GeoSite, FakeIP, DoH/DoT DNS.

### ❌ Stripped (Router Bloat)
- `with_tailscale` (~18 MB savings): Heavy Tailscale daemon and Derp client.
- `with_call` (~5 MB savings): WebRTC voice/video conferencing engine.
- `with_openvpn` / `with_openconnect` (~4 MB savings): Native OpenWrt daemons handle these faster.
- `with_masque` / `with_cloudflared` / `with_usbip` (~5 MB savings): Cloudflare tunnels & USB-over-IP.
- `with_gvisor` (~4 MB savings): Linux kernel TPROXY is faster and uses less RAM.
- `with_acme` / `with_admin_panel` (~2 MB savings): Built-in web dashboards and SSL issuance.

---

## 📊 Size Comparison

| Architecture | Upstream shtorm-7 | sing-box-extended-lite |
| :--- | :--- | :--- |
| **`arm64`** | ~58 MB (20.3 MB UPX) | **~46 MB (9.8 MB UPX)** |
| **`amd64`** | ~65 MB (22.5 MB UPX) | **~51 MB (12.5 MB UPX)** |
| **`mipsle-softfloat`** | ~55 MB (19.8 MB UPX) | **~44 MB (9.5 MB UPX)** |
| **`mips-softfloat`** | ~55 MB (19.8 MB UPX) | **~44 MB (9.5 MB UPX)** |
| **`armv7`** | ~56 MB (20.1 MB UPX) | **~45 MB (9.7 MB UPX)** |

> 💡 *Format: Pure uncompressed ELF (UPX-compressed archive)*

---

## ⚖️ Pure ELF vs UPX Lite: Selection Guide

| Criterion | Normal (`--normal`, Pure ELF) | Compressed (`--compressed`, UPX Lite) |
| :--- | :--- | :--- |
| **Flash Size on Disk** | ~44–51 MB | **~9.5–12.5 MB** |
| **RAM at Startup (Decompression)** | **0 MB extra** (Immediate exec) | **+35–45 MB spike** during in-memory unpacking |
| **Runtime Idle RAM** | ~25–35 MB (shared memory pages) | ~25–35 MB (private anonymous pages) |
| **Repeated `sing-box version` queries** | Instant (~5 ms, 0 MB extra RAM) | Cached via `/etc/sing-box-version.cache` wrapper |
| **Recommended Flash** | **>= 64 MB / 128 MB+ flash** or extroot / x86 | **16 MB – 32 MB flash** |
| **Recommended RAM** | Any (works safely on 128 MB RAM) | **>= 256 MB RAM recommended** (caution on 128 MB) |

### ⚠️ Understanding the UPX RAM Spike on 128 MB Routers
- **The UPX Tradeoff**: UPX unpacks the entire compressed binary into router RAM in a fraction of a second when launching. While uncompressed code sits on flash and loads pages on demand via `mmap`, a UPX binary must allocate **~35–45 MB of RAM** for the decompression buffer and unpacked executable in memory.
- **The 128 MB RAM Danger Zone**: On a router with 128 MB total RAM, OpenWrt system services, LuCI, and kernel buffers usually consume 50–70 MB. If a UPX binary starts without swap, the sudden ~40 MB allocation spike can trigger the Linux kernel Out-Of-Memory (OOM) killer, potentially killing `dnsmasq`, `hostapd`, or `sing-box` itself.
- **Why the Version Wrapper Matters**: When web interfaces (LuCI / Podkop / Zero-Block) poll status, they frequently execute `sing-box version`. Without our caching wrapper, every single status poll would cause a 40 MB decompression spike. Our installer automatically deploys `/etc/sing-box-version.cache` to ensure version checks cost 0 MB of extra RAM.
- **Recommendation**:
  - If your router has **>= 64 MB flash** (or USB extroot) and **128 MB RAM**, ALWAYS prefer `--normal` (Pure ELF). It has zero decompression spikes and pages memory cleanly.
  - If your router is constrained to **16–32 MB flash**, use `--compressed` (UPX Lite). If available RAM is 128 MB, ensure `zram-swap` is enabled (`opkg install zram-swap`) to provide a safety margin during service launches.

---

## 📐 Supported Router Architectures

> 💡 **Automatic Detection**: The installer script automatically detects your router's architecture via `/etc/openwrt_release` (`DISTRIB_ARCH`). Manual selection is not required.

| Target Arch | OpenWrt Target | Popular Chipsets & Router Examples |
| :--- | :--- | :--- |
| **`arm64`** | `aarch64_cortex-a53` | **MediaTek Filogic 820/830** (Xiaomi AX3000T, Redmi AX6000), **Keenetic** Titan (KN-1811) / Hopper (KN-3810), Asus TUF AX4200 |
| **`mipsle-softfloat`** | `mipsel_24kc` | **MediaTek MT7621** (Keenetic Giga/Hero/Viva, Xiaomi AC2100 / Router 3G, D-Link DIR-882) |
| **`armv7`** | `arm_cortex-a7` | **Qualcomm IPQ4019 / Cortex-A7** (MikroTik hAP ac2, Zyxel Keenetic Ultra II/Giga III) |
| **`mips-softfloat`** | `mips_24kc` | **Qualcomm Atheros** (QCA9531, QCA9563, TP-Link Archer C6/C7) |
| **`amd64`** | `x86_64` | **x86-64 Mini PCs** (Intel N100, N5105, J4125), Proxmox / ESXi / Hyper-V VMs |

> 💬 **Don't see your router model or architecture?**  
> If you would like to see your device added to the list or need support for another CPU target, feel free to request it in [Issues](https://github.com/MANCrimSon/sing-box-extended-lite/issues)!


---

## 🤖 Automated Upstream Tracking

The GitHub Actions workflow runs every night at **03:00 UTC** via cron:
1. Checks for new releases in [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended).
2. Automatically compiles native Lite builds across all 5 architectures in both uncompressed and UPX-compressed formats.
3. Generates SHA256 checksums and publishes a new release tagged identically to upstream.

---

## 📜 License & Acknowledgments

This project is open-source and licensed under the **GNU General Public License v3.0 (GPL-3.0)** — see the [LICENSE](LICENSE) file for details.

### Upstream Credits & Attribution
`sing-box-extended-lite` is a customized, bloat-free build distribution based on:
- [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended) by **shtorm-7** — the upstream extended sing-box implementation providing specialized anti-censorship protocols, rule-set handling, and features.
- [sagernet/sing-box](https://github.com/sagernet/sing-box) / [nekohasekai](https://github.com/nekohasekai) — the universal proxy platform created and maintained by the SagerNet / nekohasekai team.

### Special Thanks
- [EikeiDev](https://github.com/EikeiDev) — author of [OpenWRT-sing-box-extended](https://github.com/EikeiDev/OpenWRT-sing-box-extended), whose installer and updater architecture served as the foundation and inspiration for `install.sh`.

All upstream intellectual property and copyright belong to their respective authors under GPL-3.0.
