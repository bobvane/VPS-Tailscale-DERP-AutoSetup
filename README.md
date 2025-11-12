# VPS-Tailscale-DERP-AutoSetup

一键部署属于你自己的 **Tailscale DERP 中继服务器**  
支持：
- ✅ 自动申请 Let’s Encrypt 证书（443 端口）
- ✅ 自动检测 Cloudflare DNS
- ✅ 每周自动更新 tailscale + derper
- ✅ 中文命令行管理工具 `td`

---

## 🚀 快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh)
```

安装完成后输入：

```bash
td
```
即可打开菜单管理工具。
