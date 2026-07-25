# tderp — Tailscale DERP 一键管理脚本

> 在 Linux 服务器上一键部署 Tailscale DERP 中继节点
>
> 域名 + 高位端口 + 自签名证书 + systemd 管理

## 快速安装

```bash
# 一键安装（推荐）
bash <(curl -sL https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh)

# 或下载后运行
wget https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh
chmod +x install.sh && ./install.sh
```

安装过程为交互式中文引导，只需填写：

1. **域名** — 指向本机的域名（如 `derp.example.com`）
2. **DERP 端口** — 高位端口，如 `12345`（无需备案）
3. **STUN 端口** — 默认 `3478`

脚本自动完成：安装 Go → 编译 derper → 生成自签名证书（10年）→ 创建 systemd 服务 → 启动 → 注册 `tderp` 命令。

## 管理命令

安装后，随时输入 `tderp` 进入交互管理菜单：

```
tderp             打开交互菜单
tderp status      查看服务状态（内存、端口、版本）
tderp logs        查看实时日志
tderp restart     重启服务
tderp stop        停止服务
tderp update      更新 derper 到最新版
tderp acl         显示 ACL 配置
tderp uninstall   完全卸载
tderp help        显示帮助
```

## 管理菜单

```
╔═══════════════════════════════════════════╗
║        Tailscale DERP 管理器               ║
║             tderp v1.0.0                   ║
╚═══════════════════════════════════════════╝

  状态: 🟢 运行中  |  域名: derp.example.com:12345

─────────────────────────────────────────────

  1. 查看状态详情
  2. 查看实时日志
  3. 重启服务
  4. 停止服务
  5. 更新 derper
  6. 重新生成证书
  7. 显示 ACL 配置
  8. 卸载 DERP
  0. 退出

请输入选项 [0-8]:
```

## ACL 配置

安装完成后，将输出的配置添加到 [Tailscale ACL](https://tailscale.com/kb/1018/acls/) 的 `derpMap` 中：

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
            "STUNPort": 3478,
            "InsecureForTests": true
          }
        ]
      }
    }
  }
}
```

> `InsecureForTests: true` 是因为自签名证书，DERP 只中继已加密的 WireGuard 数据包，服务器无法解密。

## 验证

在任意 Tailscale 客户端执行：

```bash
tailscale netcheck
```

如果看到你的域名在列表中并显示延迟，说明配置成功。

## 技术方案

| 项目 | 选择 | 理由 |
|------|------|------|
| 安装方式 | Go 编译安装 | 系统级二进制，最轻量 |
| 证书 | 自签名（10 年） | 无需续期，无需备案 |
| 服务管理 | systemd | 系统原生，稳定可靠 |
| Go 代理 | goproxy.cn | 国内加速，阿里云直连 |
| Go 下载 | golang.google.cn | Google 官方国内镜像 |
| 端口 | 用户自定义高位 | 避免 443 备案需求 |

## 系统要求

- Linux 系统（Debian/Ubuntu/CentOS/Alma/Rocky 等）
- root 权限
- 公网 IP（或域名解析到本机）
- 架构: amd64 / arm64
- 安全组开放对应端口（TCP + UDP）