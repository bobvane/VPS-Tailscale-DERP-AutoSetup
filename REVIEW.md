# 产品评审记录 (Product Review) — v3.1.1

> 评审视角：产品经理 / 用户视角 / CLI UX / 可测试性 / 优化
> 评审对象：`install.sh`(2419 行)、`entrypoint.sh`、`docker-compose.yml`、`Dockerfile`、`tests/i18n.bats`、`ci.yml`、`build-derper-image.yml`
> 评审结论后已逐项修复，对应版本 **v3.2.0**

---

## 已修复缺陷 (Confirmed Bugs Fixed)

### A1 [致命] Cloudflare API Token 被硬编码丢弃 — `install.sh:1073, 1107`
`fetch_cf_cert` 两处 curl 的 `Authorization` 头写死为 `Bearer ***`，而非 `${cf_token}`。
**后果**：CF Origin CA 模式下 zone 查询与证书签发必定 401 → 安装中止，整个 CF 路径不可用。
**修复**：改为 `Bearer ${cf_token}`。

### A3 [高] 卸载菜单调用 4 个未定义 `msg` key — `install.sh:2058,2060,2063,2064`
`menu_uninstall` 使用 `info_cleanup_tailscale` / `ok_tailscale_logged_out` / `ok_uninstall_done` / `prompt_return`，三者（实为四 key）均未在 `msg()` 定义，回退为原文 key 显示。
**后果**：卸载时屏幕刷出 `info_cleanup_tailscale` 等原文，提示串错乱。
**附带的同类问题**：英文分支 `info_remove_dirs` 文案误写为中文（应为 English）。
**修复**：在 `msg()` 的英文/中文两个 case 分支各补全 4 个 key 的双语文案；并修正 `info_remove_dirs` 英文字串。

### A8 [低] 安装完成摘要显示原始证书模式值 — `install.sh:1592`
`summary_cert` 显示 `CERT_MODE`（manual/letsencrypt），中文用户无法理解。
**修复**：改为显示友好模式名（自签名 / Let's Encrypt / Cloudflare Origin CA）。

### A9 [低] 状态行英文串标泄漏 — `install.sh:1623`
中文菜单下 LE 分支调用 `$(t cert_le)` 显示英文 `Certificate: Let's Encrypt`。
**修复**：改为 `$(t cert_le)` 的中文等价（已在 `t()` 中存在 `cert_le` 中文「证书: Let's Encrypt」），统一用 `t` 不混用。

### A10 [低] 文件头版本声明与实际不符 — `install.sh:4`
注释 `# 版本: 2.0.0` 与实际 `VERSION="3.1.1"` 不一致。
**修复**：同步为 3.2.0。

### A11 [中] docker-compose 无条件映射宿主机 80 端口 — `docker-compose.yml:25`
模板硬映射 `- "80:80"`，但 CF/自签模式 `DERP_HTTP_PORT=-1` 时 derper 不监听 80，映射毫无意义且易与宿主机 80 冲突。
**修复**：`install.sh` 在下载 compose 模板后，若 `HTTP_PORT != 80` 则用 sed 移除 `- "80:80"` 映射行（LE 模式保留）。

### 死代码清理
- `detect_arch()`（`:636`）定义后从未调用 → 删除。
- `step_dns_check()`（`:930`）定义后从未调用（`install_derp` 内联了 DNS 检测）→ 删除，避免维护错觉。

---

## 验证为「非缺陷」的项 (Verified Non-Issues)

### 原 A5 [撤回] BBR 菜单 `if/fi` 括号失配
评审初稿曾怀疑 `menu_bbr` 的 `if/fi` 不平衡、导致 `read` 被推到函数外。
**经栈扫描复核**：整文件 `bash -n` 通过；`menu_bbr` 内三处 `fi`（2304/2305/2306）精确对应 `-f /etc/os-release` / `kernel_choice=1` / `bbr_not_supported` 的 else，且 `read` 位于 `}`(2308) 之前、仍在函数体内。
**结论**：结构正确，无需改动。已撤销该条。

---

## 优化项 (Optimizations Implemented)

| 项 | 位置 | 改动 |
|----|------|------|
| `env_set` sed 注入风险 | `install.sh` `env_set` | 重写为：值含 `/` `&` 时不再破坏 sed；采用「重写整行」安全方式 |
| `get_public_ip` 串行阻塞 | `install.sh:753` | 三源并发（`&`+`wait`），取首个有效 IP，超时 5s→整体更快 |
| `region_id` 每次随机 | `install.sh:1932` | 首次生成后写入 `tderp.env` 的 `REGION_ID`，后续复用，ACL 拷贝稳定 |
| `port_in_use` 全表扫描 | `install.sh:699` | 改用 `ss -tuln` 精确 `sport/dport` 过滤 |

---

## CLI 美化 (CLI Beautification)

- 新增颜色常量 `C_BLUE` / `C_BOLD` / `C_DIM`（`:51` 区）。
- 菜单标题盒、状态行图标（🟢🟡🔴）+ 颜色包裹、step 进度 `[N/11]` 加 `C_CYAN` 强调、摘要框双线圆角、菜单序号彩色。
- 所有颜色经统一包装函数下发，非 TTY 自动禁用（已有机制，未破坏）。

---

## 可测试性 (Testability)

- `tests/i18n.bats` 新增：
  - 4 个新增 `msg` key 的「输出 ≠ key 本身」断言（防止回归 A3）。
  - `summary_cert` 友好名断言。
  - `region_id` 持久化断言。
- CI：`lint-and-test` 增加 `grep -n 'Bearer \*\*\*' install.sh && exit 1`，防止 A1 类硬编码回归。

---

## 发布 (Release)

- 版本：`3.1.1` → **`3.2.0`**（大版本，覆盖上述全部项）。
- `design-notes-v3.md` 同步版本号与「测试数 31」修正为实际数。
- 提交并 push；CI `tag-release` 按 VERSION 自动打 `v3.2.0` tag + GitHub Release。
- 注：历史 `3.1.0`/`3.1.1` 未打 tag（CI 当时未触达），本次一并补打以保持 Release 连续（见提交说明）。
