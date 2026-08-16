# VPS-Tailscale-DERP-AutoSetup (tderp v2)

Tailscale DERP 中继节点的一键自动部署管理工具（Docker 版）。

全自动：一条命令装机，中文交互式管理菜单，自建镜像供应链，开箱即用。

[![GPL-3.0](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

---

## 特性

- **一条命令全自动安装**：`bash <(curl ...)` 直接装机，自动检测环境
- **Docker 部署**：容器化运行，升级只拉镜像，干净卸载
- **中英文切换**：默认中文，英文模式镜像源自动切换直连
- **证书三选一**：LE自动(域名) / LE自动(纯IP) / 自签名
- **自建镜像供应链**：GitHub Actions 自动构建 derper 镜像到 ghcr.io，国内可用加速地址
- **完整管理菜单**：状态 / 日志 / 重启 / 停止 / 更新 / ACL / 卸载
- **实时状态行**：容器状态 + 域名可达性 + 证书剩余天数
- **防白嫖可选**：verify-clients，仅你 tailnet 内设备可用
- **BBR 加速**：菜单一键配置，不支持的内核自动安装
- **安装回滚**：任一步失败自动清理，不残留

---

## 快速开始

### 0. 系统要求

| 系统 | 版本 | 说明 |
|------|------|------|
| **Debian** | 12+ / 13+ | ✅ 推荐，内核自带 BBR |
| **Ubuntu** | 20.04+ / 22.04+ / 24.04+ | ✅ 兼容 |
| **CentOS / Rocky / AlmaLinux** | 7+ / 8+ / 9+ | ✅ 兼容，旧内核需安装 BBR |
| **其他 Linux** | 内核 ≥ 4.9 | 理论上兼容，未全面测试 |

> BBR 加速：脚本自动检测内核，支持则一键开启。内核不支持（< 4.9）可自动安装新内核，国内用户可选镜像源加速。

### 1. 放行端口（必做）

安装前，先在 VPS 服务商（阿里云/腾讯云等）的**安全组/防火墙**中放行以下端口：

| 端口 | 协议 | 用途 | 说明 |
|------|------|------|------|
| `12345` | TCP | DERP 主服务 | 默认值，安装时可自定义。客户端通过此端口连接中继 |
| `3478` | UDP | STUN 打洞 | 默认值，安装时可自定义。用于 NAT 穿透探测 |
| `80` | TCP | LE 证书验证 | **仅 LE 证书模式需要**（HTTP-01 验证）。自签名模式不需要 |

> **注意：** 如果你用 Cloudflare 做 DNS 解析（域名模式），**必须关闭代理（灰色云朵）**，DERP 需要直连到你的 VPS 而不是通过 CDN 代理。

**放行操作（以阿里云为例）：**
1. 控制台 → 云服务器 ECS → 安全组 → 配置规则
2. 入方向 → 添加规则（出方向默认全通，不用动）：
   - 目的: `12345/12345`，协议: TCP，授权对象: `0.0.0.0/0`
   - 目的: `3478/3478`，协议: UDP，授权对象: `0.0.0.0/0`
   - （LE 模式）目的: `80/80`，协议: TCP，授权对象: `0.0.0.0/0`
3. 如果 VPS 本身有防火墙（iptables/ufw），也需放行

安装过程中脚本也会提示确认端口放行。

### 2. 一键安装

**国外服务器（正常安装）：**
```bash
bash <(curl -sL https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh)
```

**国内服务器（通过加速站）：**
```bash
bash <(curl -sL https://ghproxy.bobvane.top/https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh)
```

> 需要 root 权限。脚本会自动检测：
> - 是否已装 Docker（未装则按地区提示安装）
> - DNS 能否解析镜像源
> - 端口是否被占用
> - 公网 IP

### 2. 安装过程（中文交互）

安装时按提示选择，全程有中文说明：

1. **选择镜像源**：直连 ghcr.io / 国内加速地址 / 自定义
2. **Docker 检测**：未装则自动安装（可选国内/官方源）
3. **输入 DERP 域名/IP**（格式校验，输错不让下一步）
4. **选择端口**：DERP 端口(默认12345) + STUN 端口(默认3478)
5. **选择证书方案**：LE域名 / LE纯IP / 自签名（默认）
6. **（可选）开启防白嫖**：需 VPS 装 tailscale 客户端

### 3. 管理菜单

安装完成后，任意终端输入 `tderp` 进入管理：

```
╔═══════════════════════════════════════════╗
║        Tailscale DERP 管理器             ║
║             tderp v2.0.0                  ║
╚═══════════════════════════════════════════╝

  状态: 🟢 运行中  |  域名/IP: derp.example.com:12345  |  证书: 320天

  1. 中英文切换
  2. Docker 安装
  3. 查看实时日志
  4. 重启服务
  5. 停止服务
  6. 更新 derper
  7. 显示 ACL 配置
  8. 完全卸载
  9. 开启 BBR 加速
  d. DNS 修复（阿里云VPS）
  0. 退出
```

---

## 5. 配置 DERP 到你的 Tailscale

安装完成后（菜单 7 可随时查看），把 ACL 配置加到
[Tailscale Admin 控制台](https://login.tailscale.com/admin/acls) 的 `derpMap.Regions`：

```json
{
  "derpMap": {
    "Regions": {
      "900": {
        "RegionID": 900,
        "RegionCode": "tderp",
        "RegionName": "我的中继",
        "Nodes": [
          {
            "Name": "tderp1",
            "RegionID": 900,
            "HostName": "derp.example.com",
            "IPv4": "1.2.3.4",
            "DERPPort": 12345,
            "STUNPort": 3478
          }
        ]
      }
    }
  }
}
```

> **自签名证书**：需在节点加 `"InsecureForTests": true`（菜单 7 会自动生成带该字段的配置）
>
> **Let's Encrypt**：无需额外字段

保存后重启客户端（`tailscale up`）或等待配置同步。

---

## 命令速查（tderp）

| 命令 | 说明 |
|------|------|
| `tderp` | 打开交互式管理菜单 |
| `tderp status` | 查看服务状态 |
| `tderp logs` | 查看实时日志（Ctrl+C 返回） |
| `tderp restart` | 重启 DERP 容器 |
| `tderp stop` | 停止 DERP 服务 |
| `tderp update` | 更新到最新版本 |
| `tderp acl` | 显示 ACL 配置 |
| `tderp bbr` | 配置 BBR 加速 |
| `tderp dns` | DNS 修复（阿里云VPS） |
| `tderp uninstall` | 完全卸载 |

---

## 证书方案对比

| 方案 | 域名 | 80 端口 | 防白嫖 | 客户端额外配置 |
|------|------|---------|--------|--------------|
| LE 自动（域名） | 需要 | 需要 | 可开 | 无 |
| LE 自动（纯IP） | 不需要 | 需要 | 不可 | 信任证书 |
| 自签名（默认） | 不需要 | 不需要 | 不可 | `InsecureForTests: true` |

---

## 项目结构

```
├── install.sh                # 一键安装 + 管理脚本（核心）
├── Dockerfile                # 多阶段构建 derper 镜像
├── entrypoint.sh             # 容器入口：证书生成 + 启动参数
├── docker-compose.yml        # compose 模板（变量驱动）
├── design-notes-v2.md        # 设计文档
└── .github/workflows/
    └── build-derper-image.yml # 自动构建镜像到 ghcr.io
```

---

## 🔀 Fork 说明（重要）

本项目**完全支持 fork**，fork 后即可自行构建你的镜像供应链：

### 1. 自动构建你 fork 的镜像

fork 后，`.github/workflows/build-derper-image.yml` 会自动把镜像
构建到 **你 fork 的 ghcr.io**（无需改代码，`${{ github.repository }}` 自动适配）。

**首次使用步骤：**
1. Fork 本仓库
2. fork 仓库 → **Settings → Actions → General** → 开启 Actions
3. fork 仓库 → **Actions** 页 → 手动运行一次 `Build DERP image`
   （或在 fork 后打个 tag：`git tag v1.0 && git push --tags`）
4. 等待几分钟，镜像会出现在 `ghcr.io/<你的用户名>/vps-tailscale-derp-autosetup/derper`
   （镜像名会**自动转为全小写**——Docker/GHCR 要求镜像路径必须全小写）

### 2. 更新 install.sh 中的镜像地址

fork 后，install.sh 默认从原仓库拉镜像。要改用你自己的镜像，
把脚本开头的变量改一下：

```bash
# install.sh 头部
GITHUB_REPO="你的用户名/VPS-Tailscale-DERP-AutoSetup"   # ← 改成你的
```

改完保存并 push，你的 install.sh 会：
- 从你的仓库下载 compose 模板
- 从你的 ghcr.io 拉镜像

### 3. 国内加速

默认镜像前缀是 `ghcr.io`。国内服务器安装时在"选择镜像源"步骤
选择 2（推荐加速）或 3（备用加速），脚本会自动替换前缀。

> 加速地址仅影响 `docker pull` 阶段（脚本用 `${MIRROR_PREFIX}` 拼出完整镜像名）。
> 你的 compose 里 `DERP_IMAGE` 会自动带上前缀。

---

## 目录结构（安装后）

```
/opt/tderp/
├── tderp                → /usr/local/bin/tderp 软链
├── tderp.env             → 全部配置（镜像、域名、端口、证书模式…）
├── docker-compose.yml    → 生成的 compose
└── data/certs/           → 证书持久化
```

---

## 常见问题

**Q: 安装时提示 DNS 解析失败？**
国内 VPS 的 DNS 可能被锁定。按提示修改 /etc/resolv.conf 为公共 DNS
（223.5.5.5 / 114.114.114.114）后重试。

**Q: 拉镜像失败？**
用加速地址。重装时在"选择镜像源"选 2 或 3，或在 docker 的
registry-mirrors 配置国内加速。

**Q: 证书过期如何更新？**
LE 模式 derper 自动续期。自签名有效期 10 年，到期重装即可。

**Q: 更新会丢失配置吗？**
不会。更新只拉新镜像重建容器，`/opt/tderp/data` 配置和证书保留。

---

## 协议

[GPL-3.0](LICENSE)

---

## 支持

- 提 [issue](https://github.com/bobvane/VPS-Tailscale-DERP-AutoSetup/issues)
- 或联系作者 [bobvane](https://github.com/bobvane)