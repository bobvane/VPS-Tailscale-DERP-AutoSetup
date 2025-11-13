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
