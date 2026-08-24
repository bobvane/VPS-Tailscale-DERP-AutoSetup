# VPS-Tailscale-DERP-AutoSetup（tderp）

> 一键在 VPS 上部署并管理你自己的 **Tailscale DERP 中继节点**，让 Tailscale 流量走你自己的中继，延迟更低、更可控。

---

## 一、这个工具解决什么问题

Tailscale 默认借用官方 DERP 服务器中转流量。但官方节点在国内的延迟往往很高，跨运营商更明显。
本项目让你**一条命令**在自己的 VPS 上跑一个 DERP 中继，Tailscale 客户端就会优先用你这个节点——尤其适合：

- 有一台公网 VPS（国内/国外均可），但**不想折腾域名**的用户（支持纯 IP 部署）
- 想给自己的 tailnet 加一个低延迟中继的用户
- 想 fork 一份、用自己的镜像供应链自己维护的用户

全程 Docker 化、交互式菜单、中文友好，**没有域名也能跑**。

---

## 二、快速开始

在 VPS 上执行一条命令，剩下的跟着菜单走：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh)
```

装完后，随时在终端输入 `tderp` 就能重新打开管理菜单。

---

## 三、安装时你要做的 3 个决定

脚本会引导你完成安装，关键就 3 个选择：

### 1. 镜像源（国内 VPS 选加速）
默认从 `ghcr.io` 拉镜像。国内网络拉不动时，菜单里选「国内加速」即可，脚本自动换前缀。

### 2. 用域名还是公网 IP？
- **有域名**：填域名（如 `derp.example.com`），证书体验最好
- **没域名**：直接填 VPS 公网 IP，走自签名方案（本项目推荐的无域名路径）

> 输入会做格式校验，填错不让下一步。

### 3. 证书方案（见第四节）

### 可选：防白嫖（verify-clients）
开启后只有登录了你同一 tailnet 的设备才能用你的中继。需要 VPS 本机也装了 Tailscale 客户端并登录。

---

## 四、证书方案怎么选

| 方案 | 需要域名 | 需要开放 80 端口 | 客户端额外配置 | 适用场景 |
|------|---------|----------------|--------------|---------|
| **自签名（纯 IP / 域名）** | 不需要 | 不需要 | 自动（见下方） | **无域名用户推荐** |
| **Cloudflare Origin CA** | 需要（CF 托管） | 不需要 | 无 | 国内 VPS + CF 域名推荐 |
| **Let's Encrypt（域名）** | 需要 | 需要 | 无 | 国外 VPS / 国内已备案域名 |

### 关于「纯 IP + 证书」的真相（重要）

**Tailscale 官方 `derper` 不支持用 Let's Encrypt 给纯 IP 签发证书。**

- Let's Encrypt 不对公网 IP 签发证书（CA/Browser 论坛长期限制）
- derper 内置 ACME 客户端只对接 LE，且对 SNI 与主机名做硬校验
- 因此本项目**不提供「LE 自动纯 IP」选项**，纯 IP 场景统一走官方原生支持的**自签名（IP SAN）**方案

### 自签证书如何让客户端信任（CertName 机制）

自签证书不是公共 CA 签发，客户端默认不信任。本项目采用 Tailscale 官方推荐的 **`CertName` 指纹机制**（不是已弃用的 `InsecureForTests` 测试字段）：

1. 自签证书生成后，脚本算出它的 SHA256 指纹
2. 在 ACL 的 derpMap 节点里写入 `CertName: "sha256-raw:<指纹>"`
3. 客户端据此指纹信任该证书，无需关闭 TLS 校验

**你不用手动算**——菜单 7（`tderp acl`）会自动生成带指纹的完整配置，复制即用。

---

## 五、安装后：日常管理

打开管理菜单：

```bash
tderp
```

菜单选项：

| 输入 | 功能 |
|------|------|
| `1` | 切换语言（中文 / English） |
| `2` | 安装 / 重装 Docker 服务 |
| `3` | 查看实时日志 |
| `4` | 重启服务 |
| `5` | 停止服务 |
| `6` | 更新 derper 镜像（拉最新重建容器） |
| `7` | 显示 ACL 配置（含 CertName 指纹，复制去 Tailscale 后台） |
| `8` | 完全卸载（含清除 Tailscale 登录状态，保证重装强制重新登录） |
| `9` | 开启 BBR 加速（优化 TCP） |
| `d` | 修复 DNS（阿里云 VPS 内网 DNS 超时场景） |
| `u` | 更新 tderp 脚本本身 |
| `0` | 退出 |

也有等价的命令行快捷方式，不用进菜单：

```bash
tderp status        # 状态
tderp logs          # 日志
tderp restart       # 重启
tderp stop          # 停止
tderp update        # 更新 derper 镜像
tderp acl           # 显示 ACL 配置
tderp bbr           # 开启 BBR
tderp dns           # 修复 DNS
tderp updatescript  # 更新脚本
tderp uninstall     # 完全卸载
```

---

## 六、让客户端连上你的节点

1. 在 VPS 上跑 `tderp acl`，复制输出的配置
2. 打开 Tailscale 管理后台 → **Access Controls (ACL)**
3. 把配置整体粘贴进去保存
4. 重启你的 Tailscale 客户端使配置生效

自签证书场景，生成的节点会自动带上 `CertName` 指纹，例如：

```json
{
  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "900": {
        "RegionID": 900,
        "RegionCode": "CN",
        "RegionName": "DERP-CN",
        "Nodes": [
          {
            "Name": "tderp1",
            "RegionID": 900,
            "HostName": "1.2.3.4",
            "IPv4": "1.2.3.4",
            "DERPPort": 12345,
            "STUNPort": 3478,
            "CertName": "sha256-raw:ce47386eed13374d71033b0012bbcee35fcb7a6e724d5f0f4e2ed1b4a30da2bc"
          }
        ]
      }
    }
  }
}
```

> `OmitDefaultRegions: false` 保留 Tailscale 官方节点作兜底；想只用你的中继改成 `true`。
> CF Origin CA / Let's Encrypt 证书由公共 CA 签发，客户端原生信任，**节点无需任何额外字段**。

用 `tailscale netcheck` 验证你的节点是否出现在列表中、延迟是否更优。

---

## 七、进阶

### 防白嫖（verify-clients）
开启后只有登录了你 tailnet 的设备能用中继。需在 VPS 本机装 Tailscale 客户端并登录，且与本项目同 git revision 编译。

### Fork 与国内加速
- fork 后 GitHub Actions 会自动把镜像构建到**你的** `ghcr.io`（无需改代码）
- 国内安装时选镜像源 2/3，脚本自动替换 `ghcr.io` 前缀为加速地址
- 想完全用自己的镜像：改 `install.sh` 头部的 `GITHUB_REPO` 变量

### 镜像供应链
`.github/workflows/build-derper-image.yml` 从源码编译 `derper@latest` 并推送到 `ghcr.io`。每周一自动检测 Tailscale 新版本重建镜像。

---

## 八、常见问题

**Q: 安装时提示 DNS 解析失败？**
国内 VPS 的 DNS 可能被锁定。按提示修改 `/etc/resolv.conf` 为公共 DNS（223.5.5.5 / 114.114.114.114）后重试，或用菜单 `d` 自动修复（阿里云场景）。

**Q: 拉镜像失败？**
用加速地址。重装时在「选择镜像源」选 2 或 3，或在 docker 的 registry-mirrors 配置国内加速。

**Q: 证书过期如何更新？**
LE / CF 模式自动续期或长期有效。自签名有效期 10 年，到期重装即可。

**Q: 更新会丢失配置吗？**
不会。更新只拉新镜像重建容器，`/opt/tderp/data` 配置和证书保留。

**Q: DERP 中继和 Tailscale 客户端有什么关系？更新有影响吗？**
两者独立。`derper` 是你 VPS 上的 Docker 容器；Tailscale 客户端装在系统上（仅防白嫖时需要）。两者版本互不依赖。

**Q: 如何更新 tderp 管理脚本本身？**
菜单 `u`，或命令行 `tderp updatescript`。脚本从多源（ghproxy→jsDelivr→raw）下载最新版，校验语法后替换，失败保留原版。

---

## 九、已知限制

- 自定义 DERP 不支持设备共享、Mullvad 出口节点、区域路由（Tailscale 官方限制）
- 不能放在防火墙 / NAT / 负载均衡后（DERP 需直连公网）
- 纯 IP 自签方案需客户端配置 CertName 指纹（已自动化）；极旧的客户端若仍读 `InsecureForTests` 会不兼容
- 防白嫖需 VPS 同机装 Tailscale 客户端

---

## 十、项目结构

```
├── install.sh                # 一键安装 + 管理脚本（核心，单文件）
├── Dockerfile                # 多阶段构建 derper 镜像
├── entrypoint.sh             # 容器入口：证书生成 + 启动参数
├── docker-compose.yml        # compose 模板（变量驱动）
├── design-notes-v3.md        # 设计文档（当前实现 v3.1.0+）
└── .github/workflows/
    └── build-derper-image.yml # 自动构建镜像到 ghcr.io
```

---

## 协议与支持

- 协议：[GPL-3.0](LICENSE)
- 问题反馈：[issue](https://github.com/bobvane/VPS-Tailscale-DERP-AutoSetup/issues)
- 作者：[@bobvane](https://github.com/bobvane)
