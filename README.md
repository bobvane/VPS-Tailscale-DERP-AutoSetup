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


即可打开菜单管理工具。

⚙️ 注意事项

请在 Cloudflare 中关闭代理（灰云 ☁️）。

确保域名 www.xxxxx.top 指向你的 VPS 公网 IP。

服务器需开放 TCP/UDP 443 端口。

🧩 功能命令
命令	说明
td	打开命令行菜单
systemctl status derper	查看运行状态
journalctl -u derper -f	查看实时日志
/usr/local/bin/derper-autoupdate.sh	手动更新版本
