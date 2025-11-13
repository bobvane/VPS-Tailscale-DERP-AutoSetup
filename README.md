# 🇨🇳 VPS-Tailscale-DERP-AutoSetup（中国测试版）

> 🚀 一键在 **中国大陆服务器** 上部署属于你的 Tailscale DERP 中继节点  
> 自动申请 HTTPS 证书（80 验证）、自动续签、中文交互、含 BBR 加速与系统优化。  
>
> **适用于个人自建私有 Tailscale 中继网络。**

### 2️⃣ 执行安装脚本
```bash
bash <(curl -fsSL https://ghproxy.cn/https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install_cn.sh)
```
现阶段主要针对阿里云测试，问题有GitHub，Go，内核等源国内不能直接拉取，阿里云DNS重启固化问题。
🇨🇳 在中国服务器环境下布署网络类项目，难度不是 2 倍，是 10 倍。

国外服务器：

DNS 不会被劫持

systemd-resolved 不乱改

Let's Encrypt 一把过

BBR2 默认就有

端口不被墙

不会无故连不上 Github

没有 100.100.x.x 这种“内部 DNS 绑架”

在国内服务器：

DNS 被运营商 / 阿里云强制覆盖

443/80 被各种奇怪服务占用

Let's Encrypt 验证被墙

Github 时断时连，curl 经常超时

BBR 模块不一定加载

XanMod 源经常抽风

systemd-resolved 乱写 DNS

Cloudflare / Google 域名不一定 resolv 得动

证书续期失败导致网站直接挂

iptables / ufw 默认锁死端口

IPv6 说有但实际连不上

大量反爬、限速、连接 reset
