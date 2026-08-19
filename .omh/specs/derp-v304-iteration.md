# VPS-Tailscale-DERP-AutoSetup 迭代需求规格书

> 项目：bobvane/VPS-Tailscale-DERP-AutoSetup
> 当前版本：v3.0.4（2026-08-19 晨间迭代）
> 流程：omh-deep-interview → omh-ralplan → agent-skills 开发
> 状态：草案待审核

---

## 1. 背景与目标

本项目为 Tailscale DERP 中继一键部署脚本（bash，单文件 install.sh，1900+ 行），
目标用户是**fork 后直接可用的任何人**（含非技术用户、国内 VPS、无编程基础）。

2026-08-18 晚至 08-19 晨，Bob 在真实 VPS（阿里云）上完整卸载重装验证时发现系列 bug。
本规格书将已验证的 bug 固化为需求，并纳入流程化修复，避免反复打地鼠。

## 2. 用户核心约束（每次开发强制遵守）

| # | 约束 | 来源 |
|---|------|------|
| C1 | 每次改动必须升小版本号（如 3.0.4 → 3.0.5），推送 GitHub | Bob 明确要求 |
| C2 | 每次改动 Bob 都会完整卸载重装验证 fork 流程 | Bob 反复强调 |
| C3 | 脚本/安装器必须一键连贯，不允许要求用户手动跑额外命令 | Bob 明确要求 |
| C4 | 必须走 omh 流程（deep-interview → ralplan → agent-skills） | Bob 反复强调 |
| C5 | 更新菜单：版本相同提示已是最新返回；只有检测到新版本才询问升级 | USER.md |
| C6 | 菜单标题必须实时显示正确版本号 | Bob 实测反馈 |
| C7 | 修改已有源码禁止 write_file 整体覆盖，必须 patch 局部编辑 | MEMORY（事故教训） |
| C8 | 改/删文件前备份到 /opt/data/workspace/Bak/ | MEMORY |

## 3. 已验证 Bug 清单（成为本次需求）

### BUG-1：verify-clients 客户端全部被拒
- **现象**：`docker logs derper` 显示所有客户端 `rejected: failed to query local tailscaled status ... dial unix ... no such file or directory`
- **根因**：docker-compose 未挂载宿主机 `/var/run/tailscale/tailscaled.sock`，derper 容器内无法验证客户端身份
- **已修复（v3.0.2）**：VERIFY_CLIENTS=true 时 sed 取消注释 socket 挂载
- **遗留风险**：见 BUG-4（sed 缩进）

### BUG-2：镜像加速选择不弹出（CDN 缓存连锁）
- **现象**：安装时无镜像加速选择，直接 ghcr.io 直连，国内拉取极慢
- **根因A**：step_mirror_select 仅在 LANG=zh 时调用
- **根因B（结构性）**：menu_update_script 用 ghproxy（可缓存旧版）做第一下载源 + 版本**相等**才判断"已是最新"→ CDN 缓存未过期时永远更新不到，连锁导致用户 VPS 上的 tderp 一直旧版
- **已修复（v3.0.3）**：镜像选择移到 [7/11] 后无条件弹出
- **未修复（本次重点）**：更新脚本的 CDN 缓存/版本比较结构性缺陷

### BUG-3：完全卸载后重装误判"已安装"
- **现象**：完全卸载后重装弹出"检测到已安装 tderp（/opt/tderp 已存在）"
- **根因**：main() 自举逻辑创建 /opt/tderp 目录放 install.sh，is_installed() 用"目录存在"判断
- **已修复（v3.0.3）**：is_installed() 只认 tderp.env

### BUG-4：防白嫖 socket 挂载 YAML 缩进错误 → compose 启动失败
- **现象**：`go-yaml load error ... did not find expected '-' indicator at L36.C7-L38.C13`
- **根因**：sed 替换串 `      - /var/run/...`（6空格）替换在原本 6 空格缩进行上变成 12 空格，嵌套层级错乱
- **已修复（v3.0.4）**：sed 改为 `s|^\(\s*\)# - path|\1- path|`，保留原缩进

### BUG-5：CF Origin CA 证书相关（v3.0.1 已修，需回归确认）
- CSR 必须预生成本地私钥+CSR 传 CF（result 是对象非数组）
- Token 星号回显
- CF Origin CA 证书客户端不信任，ACL 必须 InsecureForTests: true，浏览器也需高级继续

### BUG-6：tailscale 登录 URL 被 grep 过滤（v3.0.1 已修，需回归）
- `tailscale up` 输出**不能** grep 过滤，卸载必须 tailscale logout

### BUG-7：is_installed 只认 tderp.env（v3.0.3 已修）
- 避免卸载后目录残留误判

## 4. 本次迭代剩余需求（REQ）

### REQ-1：修复更新脚本结构性缺陷（CDN 缓存 + 版本比较）
- 下载源顺序：GitHub raw 优先还是 ghproxy 优先？（需 ralplan 辩论）
- 版本比较：改为"下载版本 > 当前版本才更新"而非"相等才是最新"？
- 增加更新后校验：下载脚本的 VERSION 必须 > 当前才覆盖

### REQ-2：版本号显示一致性
- 菜单顶部实时显示当前 tderp 脚本版本
- 安装完成后 /opt/tderp/install.sh 必须与 GitHub 最新一致
- 已安装的 INSTALLED_VERSION 与脚本 VERSION 联动

### REQ-3：完整回归测试（fork 干净流程）
- 全新 VPS：下载脚本 → 安装（CF 证书 + 防白嫖 + 镜像加速）→ 容器启动 → verify-clients 生效 → ACL 输出正确 → 卸载 → 重装不误判
- 二次重装：卸载后清 tailscale 登录 → 重装弹新登录链接

### REQ-4：（待定）更新 tderp 脚本时是否需要保留用户自定义配置
- 当前 menu_update_script 直接覆盖 install.sh，tderp.env 不受影响（分开存储）
- 需确认：更新脚本是否只更脚本、不碰配置

## 5. 验收标准

1. 国内 VPS 从 `bash <(curl -sL ...)` 到容器运行，全流程零手动干预（除必填输入：域名/Token/端口/镜像选择）
2. 防白嫖开启时容器正常启动，无 YAML 错误，客户端不被拒
3. 完全卸载后重装不弹"已安装"误判
4. `u` 更新脚本能可靠拉到最新版（即使 CDN 缓存旧版），且菜单版本号正确显示
5. 每次推送版本号递增

## 6. 待 ralplan 决策的问题

1. 更新脚本下载源优先级与缓存穿透策略
2. 版本比较策略（> 而非 ==）
3. 是否需要安装流程预检（如 compose 文件 YAML 校验再启动）
4. 是否需要自动化测试（shellcheck / bats / 冒烟脚本），还是仅靠 Bob 手工卸载重装
5. 配置保留策略（更新脚本 vs 重装）