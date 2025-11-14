# VPS-Tailscale-DERP-AutoSetup（中国VPS部署带域名版）

🚀 一键在 中国大陆服务器 上部署属于你的 Tailscale DERP 中继节点
✔ 自动申请 HTTPS 证书（HTTP-01 / DNS-01）
✔ 自动续签
✔ 全中文交互
✔ 自带 BBR 网络优化
✔ 不安装 Tailscale 客户端（干净、轻量）

安装完成后，输入 td 管理 DERP 节点。
适合个人自建私有 Tailscale 中继网络。

### 🛠 1️⃣ 安装命令
```bash
bash <(curl -fsSL https://ghproxy.cn/https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install_cn.sh)
```

### 🔑 2️⃣ 域名证书申请说明（重要）

中国大陆服务器申请 Let’s Encrypt 难度极高（污染、验证失败、DNS 不稳定）。
建议 优先使用 DNS-01 模式，并推荐 Cloudflare。

⚠ 注意：如果你 Fork 了项目，在自己的VPS上跑通了此程序后，请删除 install_cn.sh 第 713 行的 --staging 参数。
这是测试环境参数（也可用，但是是测试域名证书，可能客户端会出问题），正式证书必须去掉它。

📌 API Token 获取方式
Cloudflare（推荐）

路径：
My Profile → API Tokens → Create Token → DNS Edit 模板
只赋予最小权限（Zone.DNS）

阿里云（AliDNS）

RAM → 创建子用户 → 授权 AliDNSFullAccess → 创建 AccessKey

DNSPod

登录 → 控制台 → API Token → 创建 Token

DNS-01 测试通过情况：

DNS 服务商	状态
Cloudflare	✔ 完全可用
阿里云 AliDNS	⚠️ 未测试充分
DNSPod	⚠️ 未测试充分
### 🧪 3️⃣ 为什么此项目主要针对阿里云做适配？

因为中国大陆 VPS 部署网络类项目时，遇到的问题远超想象：

🇨🇳 在国内服务器，你会遇到：

DNS 被运营商 / 阿里云强制覆盖

systemd-resolved 乱写 resolv.conf

100.100.x.x 内部 DNS 强制注入

80/443 被莫名其妙的服务占用

Let's Encrypt 验证被墙

Github 时断时连、curl 超时

Cloudflare / Google 域名解析不稳定

BBR 模块不一定存在

XanMod 内核源经常抽风

IPv6 “宣传有，实际没”

默认限制端口、防火墙配置奇怪

### 🌍 在国外服务器，这些不存在：

DNS 不会被劫持

443/80 通畅

Let’s Encrypt 一把过

Github 拉取随便跑

BBR2 本身就支持

Cloudflare/Google 域名解析稳定

端口不被墙

无奇怪的内部 DNS 注入

真心感叹：在中国服务器部署网络项目，难度不是 2 倍，是 10 倍。

### ⭐ 4️⃣ 欢迎测试与 Fork

🙏 欢迎大家测试本项目，也欢迎 Fork 修改。
如果本项目对你有帮助，请给一个 Star⭐，对我非常重要！

💡 Fork 后请务必 注明项目原出处：
https://github.com/bobvane/VPS-Tailscale-DERP-AutoSetup
