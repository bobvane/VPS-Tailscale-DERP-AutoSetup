# VPS-Tailscale-DERP-AutoSetup 设计文档（v3.2.1）

> 本文档记录项目当前（v3.2.1）的实际实现架构与关键设计决策。
> 前身 `design-notes-v2.md` 为 v2.0.0 规划稿，已过时，本文件取代之。

---

## 1. 项目定位

一键自动部署 + 管理 **Tailscale DERP 中继节点** 的 Docker 版工具。

- 一条命令装机：`bash <(curl ...)` 或 fork 后自定义
- 安装后通过 `tderp` 命令打开交互式管理菜单（中英文）
- 自建 GitHub Actions → ghcr.io 镜像供应链，国内可用加速地址
- 开箱即用、干净卸载、有人 fork 也能直接跑

适用人群：有公网 VPS（国内/国外均可）但没有或不想折腾域名的用户，以及想自建低延迟中继的 Tailscale 用户。

---

## 2. 总体架构

```
用户 VPS
 ├─ /usr/local/bin/tderp        (install.sh 创建的软链 → 指向 /opt/tderp/install.sh)
 ├─ /opt/tderp/
 │   ├── install.sh             (核心：安装 + 管理菜单，单文件)
 │   ├── tderp.env              (env 持久化：DERP_DOMAIN/PORT/CERT_MODE/...)
 │   ├── docker-compose.yml     (由模板生成)
 │   └── data/certs/            (自签/CF 证书持久化)
 └─ Docker 容器 derper
     └── ghcr.io/<repo>/derper:latest  (自建镜像，每周检测 tailscale 新版自动重建)
```

- **单文件 install.sh**：包含所有安装逻辑 + 12 步交互 + 管理菜单（约 2420 行，纯函数可单测）
- **镜像供应链**：`.github/workflows/build-derper-image.yml` 从源码 `go install tailscale.com/cmd/derper@latest` 编译，推送 ghcr.io；每周一 UTC 03:00 自动检测 tailscale 新版本并构建
- **菜单命令**：`tderp` → `install.sh`；`tderp status|logs|restart|stop|update|acl|bbr|dns|updatescript|uninstall` 为快捷子命令

---

## 3. 安装流程（12 步）

1. 镜像源选择（直连 ghcr.io / 国内加速 / 自定义）
2. Docker 检测（未装则按地区提示安装，可选手动/国内源）
3. DNS 解析检测（镜像源可达性）
4. 端口占用检测（DERP_PORT / STUN_PORT）
5. 输入 DERP 域名或公网 IP（格式校验，输错不让下一步）
6. 选择端口（默认 DERP 12345 / STUN 3478，可自定义）
7. 选择证书方案（见 §4）
8. （可选）防白嫖 verify-clients（需 VPS 装 tailscale 客户端并登录）
9. 生成 `tderp.env` + `docker-compose.yml`
10. `docker compose config` 预校验（失败保留现场，不 rm -rf）
11. `docker compose up -d` 启动
12. 注册 `tderp` 命令（软链到 `/usr/local/bin`）

每个步骤独立函数，输入全程校验。**卸载会清除 tailscale 登录状态**（`tailscale logout`），保证 fork 用户重装时强制重新登录。

---

## 4. 证书方案（关键设计）

| 方案 | 域名 | 80 端口 | 客户端信任机制 | 适用 |
|------|------|---------|----------------|------|
| Let's Encrypt（域名） | 需要 | 需要 | 原生信任 | 国外 / 国内已备案域名 |
| 自签名（域名或纯 IP） | 不需要 | 不需要 | `CertName: "sha256-raw:<指纹>"` | **无域名用户推荐** |
| Cloudflare Origin CA | 需要（CF 托管） | 不需要 | 原生信任 | 国内 VPS + CF 域名推荐 |

### 4.1 纯 IP 模式的真相（重要）

**Tailscale 官方 `derper` 不支持 Let's Encrypt 纯 IP 证书。**

- Let's Encrypt 不对公网 IP 签发证书（CA/Browser 论坛 + LE 策略长期限制）
- derper 内置 ACME 客户端只对接 LE，且其 `cert.go` 有 `hi.ServerName != m.hostname` 硬校验
- GitHub issue #3647（2022）、#11776（2024）至今 open，社区仅有非官方 fork `ip_derper`

因此项目**不提供「LE 自动纯 IP」选项**。纯 IP 场景统一走 **manual 自签名（IP SAN）**，这正是官方原生支持的路径：

- install.sh 将公网 IP 写入 `DERP_DOMAIN`
- entrypoint.sh 检测 `DERP_DOMAIN` 为 IP 时，用 `subjectAltName=IP:<ip>` 生成自签证书
- derper 以 `-hostname <ip> -certmode manual` 运行

### 4.2 自签证书客户端信任：CertName 机制（v3.1.0 修正）

旧版在 derpMap 节点写 `"InsecureForTests": true`。**该字段是 Tailscale 测试专用标志，官方明确「用户不应设置」**，且新版 tailcfg 已不再推荐。

v3.1.0 改为官方推荐的 **CertName 指纹机制**：

- 自签证书生成后，脚本计算其 SHA256 指纹（64 位小写 hex）
- 在 derpMap 节点写入 `"CertName": "sha256-raw:<指纹>"`
- 客户端据此指纹信任该自签证书，无需关闭 TLS 校验

menu_acl（菜单 7）自动完成上述计算与输出，用户复制即可。

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

> CF Origin CA / Let's Encrypt 证书由公共 CA 签发，客户端原生信任，**derpMap 节点无需任何额外字段**。

---

## 5. 镜像供应链（CI/CD）

### 5.1 build-derper-image.yml

- 触发：push tag / workflow_dispatch / 每周一定时
- 多阶段：golang:1-alpine 编译 `derper@latest` → alpine:3.20 运行
- 推送 `ghcr.io/<github.repository>/derper:latest` 和 `:<version>`
- 镜像名**全小写**（ghcr.io 要求仓库路径全小写，已用 `tr '[:upper:]' '[:lower:]'` 处理）

### 5.2 ci.yml（主 CI）

两个 job：

1. **lint-and-test**：装 bats-core 官方包（**非 apt 旧版 bats**，旧版不支持 `setup_file` 聚合），跑 shellcheck + `bats tests/`（39 个测试，覆盖 i18n/版本比较/校验函数/证书模式名/卸载文案/配置持久化等）
2. **tag-release**：push main 时若 `install.sh` 的 `VERSION` 高于最新 `v*` tag，自动打 tag + 建 GitHub Release（解决「Release 停留在旧版本」问题）。**注意：CI 不再单独构建镜像**——镜像包（`ghcr.io/.../derper`）由 `build-derper-image.yml` 独立维护，按 Tailscale 官方版本号命名、有新版才构建，与项目 `VERSION` 解耦。

### 5.3 版本规则

- 每次推送递增小版本号
- **3.0.9 之后直接进 3.1.0**（不出现 3.0.10 这类两位第三段的写法）
- `tag-release` 自动同步 Release，无需手动发

---

## 6. ACL / derpMap 配置

菜单 7（`tderp acl`）输出完整 tailnet policy 片段：

- 自动读取 `DERP_DOMAIN` / `DERP_PORT` / `STUN_PORT` / `PUBLIC_IP` / `CERT_MODE`
- 自签证书自动计算并嵌入 `CertName` 指纹
- `OmitDefaultRegions: false` 保留官方节点兜底

复制整体替换 Tailscale 后台 Access Controls 即可。`tailscale netcheck` 验证延迟。

---

## 7. 已知限制

- 自定义 DERP 不支持设备共享、Mullvad 出口节点、区域路由（Tailscale 官方限制）
- 不能放在防火墙/NAT/负载均衡后（DERP 需直连公网，且 HTTP 升级协议多数 LB 不兼容）
- 纯 IP 自签方案需客户端配置 CertName 指纹（已自动化），旧客户端若仍读 InsecureForTests 会不兼容
- 防白嫖（verify-clients）需 VPS 同机装 tailscale 客户端，且同 git revision 编译

---

## 8. Fork 与国内加速

- fork 后 `build-derper-image.yml` 自动构建到**你的** ghcr.io（无需改代码）
- 国内安装时选镜像源 2/3，脚本自动替换 `ghcr.io` 前缀为加速地址
- 想完全用自己的镜像：改 install.sh 头部 `GITHUB_REPO` 变量

---

*文档版本：v3.2.1 — 与 install.sh VERSION 同步。代码为权威来源，本文档描述其当前行为。*
