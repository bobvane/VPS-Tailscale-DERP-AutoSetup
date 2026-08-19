# VPS-Tailscale-DERP-AutoSetup 共识实施计划（omh-ralplan）

> 项目：bobvane/VPS-Tailscale-DERP-AutoSetup
> 当前版本：v3.0.4（2026-08-19 验证通过：镜像加速/verify-clients/客户端连接全部正常）
> 计划生成：2026-08-19 03:45（omh-ralplan 共识轮）
> 状态：**待 Bob 审核决策**

---

## 0. 流程说明（诚实记录）

本轮 omh-ralplan 派出 Planner、Architect、Critic 三个子代理独立调研，
**三个子代理的完整正文输出均在传输中出现损坏**（末尾乱码/正文丢失），
但各自的开头研究记录中保留了关键事实性发现（见 §1，均有行号证据）。
本计划由主持人（Hermes）基于三方独立研究中提取到的关键事实 + 对
install.sh（1908行）与 docker-compose.yml（37行）的完整复核综合而成。

这不是"三方充分辩论后的统一意见"，而是"三方独立研究发现 + 主持人
验证整理"。Bob 需对 §6 的决策点做最终选择。

---

## 1. 已验证的关键事实（有证据）

### F1. 更新脚本 CDN 缓存缺陷（REQ-1，已真实发生）
- `menu_update_script()`（install.sh 1356-1410）下载源顺序：
  ghproxy.bobvane.top → cdn.jsdelivr.net → raw.githubusercontent.com
- ghproxy 和 jsDelivr 都**缓存旧版**；版本比较用 `new_ver == VERSION`
  （1391行），缓存旧版 + 本地旧版 = **永远更新不到**
- **已真实发生**：Bob 连续 `u` 更新停在 v3.0.2，直到缓存过期才拉到 v3.0.3
- `main()` 自举（1819-1843）同样有此问题

### F2. 纯IP模式是半成品（B2，Critical 评审确认 + 主持人复核）
- `CERT_LE_IP=true` **从未被 env_set 持久化**（install.sh 967-977 一行都没有）
- `sync_compose_env()`（188-205）只映射 DERP_CERT_MODE / DERP_HTTP_PORT，
  docker-compose.yml 37 行无任何 LE-IP 专用变量 → **derper 容器实际
  拿不到 `--acme-ip-certs` 标志**
- 即：英文菜单选"LE纯IP"后，安装流程只在运行时把 `DERP_DOMAIN` 设为 IP，
  但容器内 derper 是否走 IP 证书逻辑完全取决于镜像 entrypoint 自动检测，
  参数链路是断裂的
- 上游风险：tailscale issue #20660 表明 NAT/云厂商 1:N 映射下 HTTP-01
  经公网 IP 验证会失败 → 悄悄生成错误证书 → 客户端 TLS mismatch

### F3. 英文菜单存在混合体验（B1）
- 菜单项走 `t()`（75-128）有完整英文文案
- 但 `step_mirror_select`、`install_derp` 提示、`menu_uninstall` 说明、
  安装 11 步全是**硬编码中文** → 英文模式下用户看到英文菜单 + 中文流程
- step_cert_select（644-735）：英文 4 选项 vs 中文 2 选项，能力不一致

---

## 2. 共识决策（分优先级）

### 高优先（下一版本必做）

**H1. 修复更新脚本缓存缺陷（REQ-1）**
- 方案（推荐）：
  1. 下载源改为 **raw 优先**（权威无缓存）→ ghproxy 兜底 → jsDelivr 兜底
  2. 版本比较改为 **"下载版本 > 当前版本"才覆盖**，而不是 ==
     - 版本号解析：把 `3.0.4` 拆成数字数组逐段比较（兼容 3.0.10）
  3. 下载后门禁：`bash -n` 语法校验（已有）+ 非空校验 + `VERSION > 当前`
  4. main() 自举同步修
- 风险：raw 偶被墙时降级到 ghproxy 可能拿到旧版 → 但此时">
  门禁"会拦住，提示"已是最新"，用户下次再试即可，不再静默卡死
- 复杂度：S；验收：缓存旧版时更新能正确提示/重试，不卡死

**H2. 处理纯IP半成品模式（B2）——Bob 三选一（§6 D1）**
- 推荐选项：**从英文菜单移除 LE纯IP 选项**（保留 LE域名/CF/自签 3 项），
  代码中最简、零维护成本、避免用户踩坑
- 备选：标注"实验性，不推荐"并强制二次确认
- 备选：完善参数链路后保留（成本高，价值低——Bob 自己不用域名 IP）

**H3. compose 启动前校验 + 失败回滚改进（A3）**
- compose up 前先跑 `docker compose config >/dev/null` 预验证 YAML
- **回滚策略改进**：v3.0.4 当前 compose up 失败会 `rm -rf /opt/tderp`
  全删配置（用户要重输一切）。建议改为：失败时**保留配置**，
  提示用户查看 compose 文件/日志诊断（已有 v3.0.4 教训：sed 缩进错导致
  启动失败→全删→重来）
- 复杂度：S

### 中优先（下一批可选）

**M1. 英文菜单决策（B1）——Bob 三选一（§6 D2）**
- 推荐：**去掉英文安装分支，只保留中文**（诚实结论：目标用户是国内非技术
  用户；英文价值低、维护成本高——每个新选项都要双语）
- 备选：完整双语（成本高，工作量 2-3 倍）
- 备选：保留现状（英文用户看到混合体验，不优雅但不致命）

**M2. 版本号一致性（REQ-2）**
- 菜单标题已显示 v${VERSION} ✅；安装时 env_set INSTALLED_VERSION ✅
- 补：menu_update_script 更新成功后同步 `env_set INSTALLED_VERSION`
- 复杂度：S

### 低优先/暂不做（过度工程审计结论）

| 项 | 结论 | 理由 |
|----|------|------|
| L1. bats/shellcheck 自动化测试 | **暂不做** | Bob 手工卸载重装是真实 fork 流程验证，价值高于模拟测试；自动化成第二套维护负担 |
| L2. 单文件拆分（launcher+lib） | **明确反对** | 破坏 fork 用户"copy 单文件"的一键体验 |
| L3. 监控告警/多节点多区域/备份迁移 | **暂缓** | 对一键 bash 脚本是高复杂度低回报；唯一值得做的是"安装后健康自检" |
| L4. CI/CD（GitHub Actions） | **可选低优** | 可加一个超轻量 workflow：shellcheck + VERSION 递增检查，不强制 |
| L5. README/FAQ 完善 | **值得做 中优先** | 本次 InsecureForTests、纯IP坑、IP直连警告值得写成 FAQ |

---

## 3. 任务清单（建议执行顺序）

| # | 任务 | 依赖 | 复杂度 | 验收标准 |
|---|------|------|--------|----------|
| T1 | H1 更新脚本修复（raw优先+版本>比较+门禁） | 无 | S | 缓存旧版时不卡死；v3.0.5 能正常更新 |
| T2 | H3 compose 预校验 + 失败保留配置 | 无 | S | YAML 错误时不 rm -rf，提示诊断 |
| T3 | H2 纯IP 处理（按 Bob D1 选择） | T1 | S | 菜单不再出现半成品选项/或明确标注 |
| T4 | M2 版本号一致性补丁 | T1 | S | 更新后 INSTALLED_VERSION 同步 |
| T5 | M1 英文菜单决策落实（按 Bob D2） | T2 | M | 语言策略一致 |
| T6 | README/FAQ（InsecureForTests/纯IP坑/警告） | T3 | M | fork 用户常见问题页面可查 |
| T7 | （可选）轻量 CI：shellcheck+VERSION 检查 | T1 | S | Actions 绿 |

每次改动 bump 小版本号 + 推送 GitHub；Bob 每次完整卸载重装验证。

---

## 4. 风险与开放问题

1. **raw 优先在国内偶被墙** → 降级 ghproxy 可能旧版 → 靠门禁拦截，不静默出错
2. **纯IP模式删除后**：已用该模式的存量用户不受影响（只影响新装菜单）——但需确认无文档承诺
3. **bump 策略**：项目已 v3.0.4，小版本号推进至 v3.0.5+ 可持续
4. **多语言未来**：若未来上架国际（如 GitHub Topics 曝光），英文价值才上升——届时再评估双语成本

---

## 5. 共识状态

- 轮次：1（子代理正文输出传输损坏，改为事实提取 + 主持人复核）
- 判定：H1/H2/H3 方案通过；M1/M2 建议采纳待 Bob 决策；L1-L4 明确反对或暂缓
- 待 Bob：§6 决策点 + 计划确认

---

## 6. 待 Bob 决策（选择题）——已确认

> Bob 2026-08-19 上午确认：

**D1. 纯IP证书模式（英文菜单选项2，半成品有坑）怎么处理？**
- ~~A：移除该选项，菜单只留 LE域名/CF/自签~~
- ~~B：保留但标注"实验性，不推荐"，强制确认才能用~~
- **C（Bob 选 ✅）：完善参数链路后保留**——中国很多用户裸跑 IP，值得完善
- 待办：修复 CERT_LE_IP 持久化、compose 传递、--acme-ip-certs 标志、ACL 中 IP 的 HostName 兼容性

**D2. 英文菜单怎么处理？**
- ~~A：去掉英文安装分支，只保留中文~~
- **B（Bob 选 ✅）：完整双语**——所有流程文案补齐英文，按官方标准做
- ~~C：保留现状~~
- 待办：所有硬编码中文函数增加英文文案

**D3. 更新脚本下载源优先级？**
- ~~A：raw 优先 → ghproxy → jsDelivr，版本 > 比较 + 门禁~~
- ~~B：保持 ghproxy 优先 + 尝试缓存穿透参数~~
- **C（Bob 选 ✅）：三个源全下载取版本最大者**
- 待办：多源并行下载 → 解析版本号 → 取最大覆盖；门禁保留

**D4. 自动化测试？**
- ~~A：暂不做，继续 Bob 手工卸载重装验证~~
- ~~B：加超轻量 shellcheck + VERSION 检查（GitHub Actions）~~
- **C（Bob 选 ✅）：完整 bats 测试套件**
- 待办：为 install.sh 关键函数写 bats 测试 + GitHub Actions 自动运行

---

*文件写入：/opt/data/workspace/VPS-Tailscale-DERP-AutoSetup-repo/.omh/plans/ralplan-derp-v304-iteration.md*