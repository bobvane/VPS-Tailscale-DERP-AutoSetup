# 🌐 VPS-Tailscale-DERP-AutoSetup

> 一键部署属于你自己的 **Tailscale DERP 中继服务器**  
> 自动申请 SSL 证书、自动更新、中文交互、永久免费使用  
> 🧰 适用于：个人自用、自建加速、跨设备连接优化

## ✳️ 工具简介

`VPS-Tailscale-DERP-AutoSetup` 是一个为个人用户设计的  
**Tailscale DERP 一键部署与管理工具**。

通过它，你可以在任意 VPS（阿里云 / 腾讯云 / Google Cloud / AWS）上，  
几分钟内搭建一个 **完全属于自己的 DERP 中继服务器**，  
实现：
- 🌍 设备之间更快的 Tailscale 连接  
- 🔒 完全自控的数据中转（不经过 Tailscale 官方服务器）  
- ⚙️ 自动 SSL 证书与自动更新机制  
- 🧩 命令行中文菜单管理（命令：`td`）

## ⚡ 为什么个人只需要搭建一个 DERP 服务就足够了？

Tailscale 默认使用全球分布的官方 DERP 中继节点。  
但对于个人用户来说，存在以下问题：

| 官方 DERP | 自建 DERP |
|------------|------------|
| 🌀 节点在境外，延迟较高 | ⚡ 部署在自己附近（如阿里云/腾讯云） |
| 🔒 数据中转经过第三方服务器 | 🔐 数据只经过你自己的 VPS |
| 💸 无法定制优先路由 | 🧠 可完全掌控路径与带宽 |
| ⚙️ 无法脱离官方控制面 | ✅ 可结合自建 Headscale 完全独立（可选） |

> ✅ 个人使用场景下，只要你部署 **一个 DERP 节点**（例如部署在你常用的 VPS 上），  
> 就能极大提升连接速度，并确保数据路径可控。  
> 因为 Tailscale 在直连失败时，只会使用你自建的 DERP 节点进行中继，  
> 所以一个节点即可覆盖你所有设备。

## ⚙️ 安装前准备

在运行此工具之前，请确保：

✅ 一台 VPS | 建议使用 Debian 12 或 Ubuntu 22+

更新系统源 & 软件包
```bash
apt update && apt upgrade -y
```
安装常用基础命令（非常重要）
```bash
apt install -y curl wget git unzip vim nano htop jq net-tools dnsutils ca-certificates lsb-release cron
```
设置时区与时间同步（防止证书签发失败）
```bash
timedatectl set-timezone Asia/Shanghai
```
```bash
apt install -y systemd-timesyncd
systemctl enable --now systemd-timesyncd
timedatectl timesync-status
```
开启 TCP BBR 加速（提升网络吞吐）
```bash
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
```
清理无用缓存（保持系统干净）
```bash
apt autoremove -y && apt clean
```
重启一次（让所有内核参数生效）
```bash
reboot
```

✅ 公网 IP | 必须为公网可访问地址

✅ 一个已备案的域名 | 示例：`xxxxxx.top`

✅ 域名托管在 Cloudflare | 免费、支持 DNS API

✅ 已在 Cloudflare 添加 A 记录 | 将 `derp.xxxxxx.top` 指向你的 VPS IP
⚠️ 关闭代理（灰云） | 仅 DNS 模式，否则 SSL 申请失败

✅ 端口开放 | 用于 HTTPS 与 STUN 服务
| 端口           | 协议  | 是否必须                           | 用途说明                      |
| ------------ | --- | ------------------------------ | ------------------------- |
| **22/tcp**   | TCP | ✅ 必需                           | SSH 登录管理 VPS（不是 DERP 的功能） |
| **443/tcp**  | TCP | ✅ 必需                           | DERP 加密中继通道（客户端 HTTPS 连接） |
| **443/udp**  | UDP | ✅ 强烈推荐                         | STUN 探测，用于 NAT 穿透、加速连接    |
| **3478/udp** | UDP | ⚙️ 可选（备用 STUN 端口）              |                           |
| **80/tcp**   | TCP | ⚙️ 可选（Let’s Encrypt HTTP 验证备用） |                           |
| **其他端口**     | -   | ❌ 不需要                          | Tailscale 连接全部通过加密通道或直连   |

## 🚀 一键安装命令

> ⚠️ 请使用 root 用户执行（或 sudo 运行）
中国大陆服务器，请运行：
```bash
bash <(curl -fsSL https://ghproxy.cn/https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install_cn.sh)
```
国外服务器（比如香港），请运行：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh)
```


安装过程将自动：

检测系统版本与 IP；

检查 Cloudflare DNS；

下载并安装最新版 tailscale 与 derper；

自动申请 Let’s Encrypt 证书；

注册 systemd 服务；

设置每周自动更新任务；

安装命令行管理工具 td。

🧰 命令行管理工具 td

安装完成后，你可以通过命令：

td

打开交互式管理菜单：

===========================================
 Tailscale DERP 管理工具
-------------------------------------------
 1. 启动 DERP 服务
 2. 停止 DERP 服务
 3. 重启 DERP 服务
 4. 查看运行状态
 5. 修改绑定域名
 6. 修改监听端口
 7. 重新申请 SSL 证书
 8. 手动更新 derper/tailscale
 9. 查看日志
10. 退出
===========================================

🧩 服务运行与验证
检查服务是否正常运行
systemctl status derper


输出中出现：

Active: active (running)


表示运行成功。

验证 DERP 节点在工作

在任意 Tailscale 客户端运行：

tailscale netcheck


若输出包含：

DERP region: derp.bobvane.top


说明自建中继已启用。

🔁 自动更新机制

本工具自带自动更新功能，每周一凌晨 05:00 自动执行：

检查 Tailscale 最新版

检查 DERPER 最新版

自动下载更新并重启服务

可手动执行更新：

/usr/local/bin/derper-autoupdate.sh

🧠 常见问题 FAQ

Q1：Cloudflare 开了橙云可以用吗？
❌ 不行。橙云会使 Let’s Encrypt 证书申请失败，请设置为灰云。

Q2：443 端口被占用怎么办？
可以用 td 修改监听端口（如 5443）。

Q3：证书到期会自动续签吗？
✅ 会。--certmode letsencrypt 自动管理证书签发与续期。

Q4：可以搭配 Headscale 使用吗？
✅ 可以。只需在 Headscale 的配置文件中添加你的 DERP 节点地址。

📜 License

MIT License © 2025 bobvane

❤️ 致个人用户

本工具完全开源、无依赖、无后门。
它的意义在于让每一个 Tailscale 用户都能拥有：

自己掌控的中继节点；

无需担心封锁或隐私；

永久免费的网络加速方案。

🌱 一台 VPS，一个命令，一次部署，就够了。
