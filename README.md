# 🇨🇳 VPS-Tailscale-DERP-AutoSetup（中国优化版 · 稳定生产版）

> 🚀 一键在 **中国大陆服务器** 上部署属于你的 Tailscale DERP 中继节点  
> 自动申请 HTTPS 证书（80 验证）、自动续签、中文交互、含 BBR 加速与系统优化。  
>
> **适用于个人或小型团队自建私有 Tailscale 中继网络。**

---

## 🧭 项目简介

本项目可一键在 VPS 上部署 **Tailscale DERP 中继服务**，用于在 Tailscale 网络中加速 NAT 穿透连接。  
脚本自动完成从环境准备 → 证书申请 → derper 安装 → 启动服务 → 注册客户端 的全流程。

### ✅ 国内优化特点
- 使用 **国内镜像**（阿里云、ghproxy）保证安装稳定；
- 自动申请 **Let’s Encrypt 证书**（HTTP-01 验证，使用 80 端口）；
- 自动启用 **BBR 加速**；
- 自动同步系统时间；
- 含管理命令行工具 **`td`**（彩色菜单，简体中文）；
- 自动续签证书（通过 cron）；
- 可直接在菜单中 **注册 Tailscale 客户端**，加入你的账户。

---

## ⚙️ 系统要求

| 项目 | 推荐配置 |
|------|-----------|
| 系统 | Debian 12 (bookworm) x64 |
| 内存 | ≥ 512MB |
| 公网 IP | 必须具备（IPv4） |
| 权限 | root 用户执行 |
| 域名 | 需提前解析到服务器 IP（推荐使用 Cloudflare） |

---

## 🔐 服务器防火墙 / 端口要求

为保证 derper 正常工作，务必在 **云服务商控制台** 和 **防火墙策略** 中开放下列端口：

| 端口 | 协议 | 说明 |
|------|------|------|
| **22** | TCP | SSH 登录 |
| **80** | TCP | Let’s Encrypt 证书申请验证端口 |
| **443** | TCP / UDP | DERP 中继服务主要通信端口 |
| **3478** | UDP | STUN 服务（NAT 检测） |
| （可选） | - | 关闭其他无关端口以提升安全性 |

> 💡 **Cloudflare 注意事项：**
> - 关闭橙云（即“仅 DNS”模式）；
> - 确保 80/443 均能从公网直接访问；
> - 若使用阿里云 / 腾讯云，请在安全组中放行 80、443、3478。

---

## 🧰 自动安装内容

运行脚本后将自动执行以下任务：

1. 系统更新与依赖安装；
2. 安装常用工具：`curl`、`wget`、`git`、`jq`、`certbot`、`chrony`；
3. 设置时区 `Asia/Shanghai` 并自动校时；
4. 启用 **BBR** 网络拥塞算法；
5. 清理缓存与无用包；
6. 自动安装 **Tailscale 客户端**；
7. 下载并安装 **Go**；
8. 自动签发 HTTPS 证书（80端口验证）；
9. 安装并启动 **derper 服务**；
10. 安装管理工具 `td`；
11. 创建自动续签任务。

---

## 🚀 一键安装

### 1️⃣ 登录 VPS
```bash
ssh root@你的服务器IP
```

### 2️⃣ 执行安装脚本
```bash
bash <(curl -fsSL https://ghproxy.cn/https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install_cn.sh)
```

### 3️⃣ 按提示输入：
- 绑定域名（例：`derp.bobvane.top`）  
- 公网 IP（留空自动检测）

脚本将自动执行全部安装过程。  
**证书申请成功后会自动复制并启动 DERP 服务。**

---

## 🧩 安装完成后

安装成功后终端会显示：
```
✅ derper 已启动并运行
脚本执行结束。请运行 td 并选择 “注册 Tailscale 客户端” 完成登录步骤。
```

### 4️⃣ 执行管理工具
```bash
td
```

---

## 🧭 td 管理菜单功能

| 选项 | 功能说明 |
|------|-----------|
| **1** | 查看 DERP 服务状态 |
| **2** | 重启 DERP 服务 |
| **3** | 停止 DERP 服务 |
| **4** | 查看 Tailscale 客户端状态 |
| **5** | 生成 derpmap.json（用于自定义 region） |
| **6** | 查看证书详情与到期时间 |
| **7** | 注册 Tailscale 客户端（执行 `tailscale up`，输出认证链接） |
| **8** | 立即更新证书并重启 DERP |
| **9** | 卸载并清理所有相关文件 |
| **0** | 退出菜单 |

### 🪄 注册 Tailscale 客户端（选项 7）
执行后会输出类似以下提示：
```
To authenticate, visit:
https://login.tailscale.com/a/ABCDEFG12345
```

请复制此链接，在浏览器中打开并登录你的 Tailscale 账户。  
登录完成后此 VPS 会自动加入你的 Tailscale 网络。

验证：
```bash
tailscale status
```

---

## 🔁 自动续签说明

脚本自动创建 `/etc/cron.d/derper-renew` 定时任务：
```bash
0 3 * * 1 root certbot renew --quiet && systemctl restart derper
```
每周一凌晨 3:00 自动更新证书并重启 DERP。  
（无需人工干预）

---

## 🧹 卸载方式

运行：
```bash
td
```
选择菜单项：
```
9) 卸载本项目（清理文件）
```

或手动执行：
```bash
systemctl stop derper
systemctl disable derper
rm -rf /opt/derper /var/lib/derper /usr/local/bin/derper /usr/local/bin/td /etc/systemd/system/derper.service
```

---

## 🧠 常见问题 FAQ

### 1️⃣ 证书申请失败？
- 检查 Cloudflare 是否 **关闭橙云（仅DNS）**；
- 检查防火墙是否开放 80 端口；
- 检查域名是否正确解析到服务器 IP；
- 可手动执行：
  ```bash
  certbot certonly --standalone -d 你的域名 --preferred-challenges http --agree-tos -m admin@你的域名 --non-interactive
  ```

### 2️⃣ derper 启动失败？
查看日志：
```bash
journalctl -u derper -n 50 --no-pager
```

### 3️⃣ 如何修改域名或重新部署？
重新执行安装脚本会自动清理旧环境并重新配置。

### 4️⃣ 如何确认端口是否正常监听？
```bash
ss -tulnp | grep 443
```
输出中若有 `derper` 表示运行正常。

---

## 🏁 总结

| 模块 | 说明 |
|------|------|
| 部署脚本 | `install_cn.sh` — 一键部署全流程 |
| 管理工具 | `td` — 中文交互式菜单管理 |
| 自动续签 | 每周自动更新证书并重启 |
| 网络加速 | 启用 Linux BBR |
| 适配环境 | 专为中国大陆优化，无需翻墙 |

---

## 💬 作者与鸣谢

- 作者：[@bobvane](https://github.com/bobvane)  
- 协助与测试：文波 (China)  
- 基于项目：[tailscale/derper](https://github.com/tailscale/tailscale)

> **声明**：本项目仅供个人学习与内部使用。  
> 不建议将 DERP 服务用于公开大规模中继用途。  
> 若用于企业或商用，请遵守 Tailscale 官方政策。

---

## 🌟 最后提示

✅ 推荐使用命令：
```bash
td
```

- 查看运行状态  
- 注册 tailscale 客户端  
- 查看证书  
- 重启 / 卸载  
一切操作都可在一个交互菜单中完成。

---
**版本信息：**
- install_cn.sh — v4.1-pro  
- td — v1.5  
- 适配系统：Debian 12 x64
