#!/usr/bin/env bash
# ============================================================
# tderp V2 — Tailscale DERP 一键安装 & 管理脚本
# 版本: 2.0.0
#
# 运行方式:
#   bash <(curl -sL https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh)
#   或直接运行 ./install.sh
#
# 功能（设计文档需求 01-13 + G1-G9 全部实现）:
#   - 一键安装 Docker 版 DERP（自建 ghcr.io 镜像供应链）
#   - 中英文切换，中文模式联动镜像源三选一
#   - 证书三选一（LE自动域名/LE自动纯IP/自签名）
#   - 12 步安装流程，输入验证 + DNS 检测 + 端口占用检测
#   - 完整管理菜单（状态/日志/重启/停止/更新/ACL/卸载）
#   - 状态行实时检测：容器状态 + 域名可达性 + 证书剩余天数
#   - verify-clients 防白嫖可选
#   - 安装失败自动回滚
# ============================================================

set -euo pipefail

# ------------------------------------------------------------
# 配置区
# ------------------------------------------------------------
VERSION="3.0.7"
INSTALL_DIR="/opt/tderp"
ENV_FILE="${INSTALL_DIR}/tderp.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
BIN_LINK="/usr/local/bin/tderp"
DATA_DIR="${INSTALL_DIR}/data"
CERTS_DIR="${DATA_DIR}/certs"

# 项目仓库（用于 fork 说明）
GITHUB_REPO="bobvane/VPS-Tailscale-DERP-AutoSetup"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/main"

# 默认镜像（脚本运行时检测 fork 情况）
DERP_IMAGE_DEFAULT="ghcr.io/bobvane/vps-tailscale-derp-autosetup/derper:latest"

# 国内 ghcr.io 镜像加速地址（需求 10）

# 中英文文案
LANG_ZH="zh"
LANG_EN="en"
LANG="${LANG:-zh}"   # 默认中文

# ------------------------------------------------------------
# 颜色定义
# ------------------------------------------------------------
C_RESET="\033[0m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_CYAN="\033[36m"

# 非交互环境禁用颜色
if [ ! -t 1 ]; then
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

# ------------------------------------------------------------
# 多语言文案
# ------------------------------------------------------------
t() {
  local key="$1"
  if [ "${LANG}" = "${LANG_EN}" ]; then
    case "$key" in
      menu_title) echo "Tailscale DERP Manager" ;;
      menu_version) echo "tderp v${VERSION}" ;;
      status_running) echo "RUNNING" ;;
      status_stopped) echo "STOPPED" ;;
      status_unknown) echo "UNKNOWN" ;;
      cert_days) echo "Cert: ${2} days" ;;
      cert_cf) echo "Cert: Cloudflare Origin CA" ;;
      cert_le) echo "Certificate: Let's Encrypt" ;;
       cert_menu_title) echo "Certificate mode (choose one)" ;;
      opt_lang) echo "1. Switch language (中文/English)" ;;
      opt_install) echo "2. Docker install" ;;
      opt_logs) echo "3. View live logs" ;;
      opt_restart) echo "4. Restart service" ;;
      opt_stop) echo "5. Stop service" ;;
      opt_update) echo "6. Update derper" ;;
      opt_acl) echo "7. Show ACL config" ;;
      opt_uninstall) echo "8. Uninstall (clean)" ;;
      opt_bbr) echo "9. Enable BBR acceleration" ;;
      opt_dns) echo "d. Fix DNS (Alibaba Cloud)" ;;
      opt_updatescript) echo "u. Update tderp script" ;;
      opt_exit) echo "0. Exit" ;;
      prompt_choice) echo -n "Enter option [0-9du]: " ;;
      step_install_1) echo "DNS resolution check: ${2:-}" ;;
      step_install_2) echo "Port check: TCP ${2:-} / UDP ${3:-}" ;;
      step_install_3) echo "Check Docker" ;;
      step_install_4) echo "Port availability check" ;;
      step_install_5) echo "Select certificate mode" ;;
      step_install_6) echo "Create config directory" ;;
      step_install_7) echo "Download docker-compose template" ;;
      step_install_8) echo "Pull derper image (${2:-})" ;;
      step_install_9) echo "Start DERP container" ;;
      step_install_10) echo "Wait for container ready" ;;
      step_install_11) echo "Register tderp command" ;;
      *) echo "$key" ;;
    esac
  else
    case "$key" in
      menu_title) echo "Tailscale DERP 管理器" ;;
      menu_version) echo "tderp v${VERSION}" ;;
      status_running) echo "运行中" ;;
      status_stopped) echo "已停止" ;;
      status_unknown) echo "未知" ;;
      cert_days) echo "证书: ${2}天" ;;
      cert_cf) echo "证书: Cloudflare Origin CA" ;;
      cert_le) echo "证书: Let's Encrypt" ;;
       cert_menu_title) echo "证书方式选择（二选一）" ;;
      opt_lang) echo "1. 中英文切换" ;;
      opt_install) echo "2. Docker 安装" ;;
      opt_logs) echo "3. 查看实时日志" ;;
      opt_restart) echo "4. 重启服务" ;;
      opt_stop) echo "5. 停止服务" ;;
      opt_update) echo "6. 更新 derper" ;;
      opt_acl) echo "7. 显示 ACL 配置" ;;
      opt_uninstall) echo "8. 完全卸载" ;;
      opt_bbr) echo "9. 开启 BBR 加速" ;;
      opt_dns) echo "d. DNS 修复（阿里云VPS）" ;;
      opt_updatescript) echo "u. 更新 tderp 脚本" ;;
      opt_exit) echo "0. 退出" ;;
      prompt_choice) echo -n "请输入选项 [0-9du]: " ;;
      step_install_1) echo "DNS 解析检测：${2:-}" ;;
      step_install_2) echo "端口检测：TCP ${2:-} / UDP ${3:-}" ;;
      step_install_3) echo "检测 Docker" ;;
      step_install_4) echo "端口占用检测" ;;
      step_install_5) echo "选择证书方案" ;;
      step_install_6) echo "创建配置目录" ;;
      step_install_7) echo "获取 docker-compose 模板" ;;
      step_install_8) echo "拉取 derper 镜像（${2:-}）" ;;
      step_install_9) echo "启动 DERP 容器" ;;
      step_install_10) echo "等待容器就绪" ;;
      step_install_11) echo "注册 tderp 命令" ;;
      *) echo "$key" ;;
    esac
  fi
}

_msg_prefix() {
  case "${LANG}" in
    "${LANG_EN}")
      case "$1" in
        info) echo "[INFO] " ;;
        warn) echo "[WARN] " ;;
        error) echo "[ERROR]" ;;
        ok) echo "[OK]" ;;
        *) echo "[INFO] " ;;
      esac ;;
    *)
      case "$1" in
        info) echo "[信息] " ;;
        warn) echo "[警告] " ;;
        error) echo "[错误]" ;;
        ok) echo "[OK]" ;;
        *) echo "[信息] " ;;
      esac ;;
  esac
}

_info()  { echo -e "${C_GREEN}$(_msg_prefix info)${C_RESET} $*"; }
_warn()  { echo -e "${C_YELLOW}$(_msg_prefix warn)${C_RESET} $*"; }
_error() { echo -e "${C_RED}$(_msg_prefix error)${C_RESET} $*"; }
_ok()    { echo -e "${C_GREEN}$(_msg_prefix ok)${C_RESET} $*"; }
_step()  { echo -e "${C_CYAN}[${1}/${2}]${C_RESET} $3"; }

# 流程文案翻译。菜单 key 保留在 t()，安装/管理流程使用 msg()，避免 key 相互覆盖。
msg() {
  local key="$1"
  shift || true
  if [ "${LANG}" = "${LANG_EN}" ]; then
    case "$key" in
      docker_missing) echo "Docker not found, will auto-install..." ;;
      docker_menu) echo " Docker engine install method (choose by server location)" ;;
      docker_cn) echo "  1. China server (Aliyun mirror, fast)" ;;
      docker_intl) echo "  2. International server (Docker official script)" ;;
      docker_manual) echo "  3. Manual (skip, I will install myself)" ;;
      docker_choice) echo -n "Select [1-3] (default 2): " ;;
      invalid_123) echo "Invalid input, enter 1, 2 or 3" ;;
      aliyun_install) echo "Installing Docker via Aliyun mirror..." ;;
      aliyun_failed) echo "Aliyun mirror install failed, trying official script..." ;;
      docker_failed) echo "Docker install failed" ;;
      official_install) echo "Installing Docker via official script..." ;;
      docker_skipped) echo "Skipped Docker install. Install manually and re-run this script." ;;
      docker_verify) echo "Verifying Docker..." ;;
      docker_installed) echo "Docker installed: $(docker --version)" ;;
      compose_missing) echo "docker compose not detected, installing compose plugin..." ;;
      compose_failed) echo "compose plugin install failed, install docker-compose manually" ;;
      docker_unusable) echo "Docker still unusable, troubleshoot manually" ;;
      mirror_menu) echo " Select image pull source (ghcr.io China acceleration)" ;;
      mirror_direct) echo "  1. Direct ghcr.io              (international VPS recommended)" ;;
      mirror_recommended) echo "  2. Recommended ghcr.chenby.cn   (China VPS recommended)" ;;
      mirror_backup) echo "  3. Backup ghcr.milu.moe        (China VPS alternative)" ;;
      mirror_nju) echo "  4. NJU mirror ghcr.nju.edu.cn    (education network, fast)" ;;
      mirror_proxy) echo "  5. DockerProxy ghcr.dockerproxy.com (CF acceleration)" ;;
      mirror_custom) echo "  c. Custom address (enter your accelerator)" ;;
      mirror_choice) echo -n "Select [1-5/c] (default 2): " ;;
      mirror_custom_prompt) echo -n "Enter custom mirror address (e.g. my.mirror.com): " ;;
      input_empty) echo "Input cannot be empty" ;;
      input_invalid) echo "Invalid input" ;;
      mirror_prefix) echo "Mirror prefix: ${1}" ;;
      mirror_unresolved) echo "Cannot resolve ${1}, check network or pull may fail" ;;
      dns_ok) echo "DNS resolution OK" ;;
      dns_failed) echo "Cannot resolve ${1}, possibly locked DNS or network issue" ;;
      solution) echo "  Troubleshooting:" ;;
      dns_solution1) echo "  1. Check whether DNS in /etc/resolv.conf works" ;;
      dns_solution2) echo "  2. Try a public DNS server:" ;;
      dns_solution3) echo "  3. Re-run this script after changing DNS" ;;
      port_tcp_busy) echo "TCP port ${1} is occupied; choose another DERP port or release it" ;;
      port_udp_busy) echo "UDP port ${1} is occupied; choose another STUN port or release it" ;;
      port_solution1) echo "  1. Check the process: ss -tulnp | grep -E '${1}|${2}'" ;;
      port_solution2) echo "  2. Reinstall after changing the ports" ;;
      ports_free) echo "All ports are available" ;;
      verify_title) echo " Verify-clients (anti-abuse)" ;;
      verify_desc1) echo " When enabled, only devices in your tailnet can use this DERP relay" ;;
      verify_desc2) echo " Tailscale client must be installed and logged in on this VPS" ;;
      verify_desc3) echo " Disabled by default; leave disabled if you are the only user" ;;
      verify_prompt) echo "Enable verify-clients?" ;;
      verify_enabled) echo "Verify-clients enabled. Checking tailscale client..." ;;
      tailscale_missing) echo "tailscale client not found, installing automatically..." ;;
      tailscale_install_failed) echo "tailscale installation failed, install it manually and retry" ;;
      tailscale_ready) echo "tailscale client installed; the DERP container will log in after startup" ;;
      tailscale_installing) echo "Installing tailscale client..." ;;
      tailscale_installed) echo "tailscale installation complete" ;;
      tailscale_login_command) echo "  Run the following command to log in to your tailnet:" ;;
      tailscale_login_hint) echo "  Follow the browser prompt to authorize" ;;
      dns_checking) echo "Checking DNS status..." ;;
      dns_healthy) echo "DNS is healthy, no fix needed" ;;
      current_dns) echo "  Current DNS configuration:" ;;
      dns_title) echo " Aliyun VPS DNS Fix Tool" ;;
      aliyun_dns_issue) echo " Aliyun internal DNS (100.100.2.136/138) often times out" ;;
      fix_method) echo " Fix method: use public DNS instead" ;;
      aliyun_dns) echo "   - Aliyun public DNS: 223.5.5.5 / 223.6.6.6" ;;
      google_dns) echo "   - Google DNS: 8.8.8.8 / 8.8.4.4" ;;
      fix_auto) echo "  1. Auto fix (recommended)" ;;
      fix_manual) echo "  2. Manual fix (configure yourself)" ;;
      fix_skip) echo "  3. Skip" ;;
      fix_choice) echo -n "Select [1-3] (default 1): " ;;
      fixing_dns) echo "Fixing DNS..." ;;
      dns_fixed) echo "DNS fixed! github.com now resolves" ;;
      dns_unfixed) echo "DNS still broken after fix; check network config" ;;
      fix_manual_steps) echo "Manual fix steps:" ;;
      fix_skip_msg) echo "Skipped" ;;
      press_return) echo -n "Press Enter to return..." ;;
      bbr_checking) echo "Checking system BBR support..." ;;
      kernel_version) echo "Kernel version: ${1}" ;;
      current_algorithm) echo "  Current algorithm: ${1}" ;;
      bbr_already) echo "BBR already enabled (congestion control: bbr)" ;;
      disable_bbr_hint) echo "To disable BBR:" ;;
      disable_bbr_step1) echo "  sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d' /etc/sysctl.d/99-bbr.conf" ;;
      disable_bbr_step2) echo "  sysctl -p /etc/sysctl.d/99-bbr.conf" ;;
      disable_bbr_step3) echo "  sysctl -w net.ipv4.tcp_congestion_control=cubic" ;;
      module_load) echo "  Module load: ${1}" ;;
      module_unavailable) echo "  Module unavailable: ${1}" ;;
      available_algorithms) echo "  Available algorithms: ${1}" ;;
      kernel_ok) echo "  Kernel version: ${1} (≥ 4.9, BBR supported)" ;;
      bbr_supported) echo "System supports BBR, acceleration available" ;;
      enable_bbr_prompt) echo "Enable BBR acceleration (TCP optimization, good for China VPS)?" ;;
      enabling_bbr) echo "Enabling BBR..." ;;
      bbr_enabled) echo "BBR enabled! Congestion control: ${1}" ;;
      bbr_failed) echo "BBR config may not be active; current: ${1}" ;;
      bbr_skipped) echo "Skipped" ;;
      bbr_not_supported) echo "Current environment does not support BBR (all checks failed)" ;;
      kernel_unsupported) echo "Current kernel does not support BBR; try installing a new kernel" ;;
      install_kernel) echo "  1. Try installing new kernel (some old systems need this)" ;;
      skip_kernel) echo "  2. Skip, I will handle it" ;;
      kernel_source) echo " Kernel source selection" ;;
      kernel_source_cn) echo "  1. China server (mirror, fast)" ;;
      kernel_source_intl) echo "  2. International server (official source)" ;;
      kernel_source_manual) echo "  3. Manual (skip, I'll do it)" ;;
      kernel_source_choice) echo -n "Select [1-3] (default 1): " ;;
      kernel_skipped_msg) echo "Skipped; install kernel manually later" ;;
      debian_installing) echo "Debian/Ubuntu: installing mainline kernel..." ;;
      debian_mirror) echo "Using China mirror..." ;;
      debian_failed) echo "Auto kernel install failed; install manually and retry" ;;
      rhel_installing) echo "RHEL family: installing mainline kernel..." ;;
      rhel_mirror) echo "Using China mirror (Aliyun elrepo)..." ;;
      rhel_failed) echo "Auto kernel install failed; install manually and retry" ;;
      kernel_done) echo "Kernel install complete! Reboot to activate:" ;;
      reboot_hint) echo "  Reboot then re-run this menu to enable BBR" ;;
      unknown_system) echo "Unsupported system (${1}); install kernel manually" ;;
      derp_domain_title) echo " Configure DERP domain/IP" ;;
      ip_mode) echo "Pure IP mode: detecting public IP..." ;;
      detected_ip) echo "Detected public IP: ${1}" ;;
      use_detected_ip) echo "Use this IP as DERP address?" ;;
      manual_ip) echo -n "Enter public IP: " ;;
      invalid_ip) echo "Invalid IP format" ;;
      auto_ip_failed) echo "Auto IP detection failed, please enter manually" ;;
      domain_prompt) echo "Enter domain (or public IP)" ;;
      domain_example) echo "Domain example: derp.example.com (must resolve here, CF proxy off/gray cloud)" ;;
      ip_example) echo "IP example:   1.2.3.4" ;;
      domain_ip_prompt) echo -n "Domain/IP: " ;;
      invalid_domain_ip) echo "Invalid format, enter a valid domain or IP" ;;
      derp_address) echo "DERP address: ${1}" ;;
      ports_title) echo " Configure ports" ;;
      derp_port) echo -n "DERP port (TCP, default 12345, high port recommended): " ;;
      derp_port_retry) echo -n "DERP port (TCP, default 12345): " ;;
      stun_port) echo -n "STUN port (UDP, default 3478): " ;;
      stun_port_retry) echo -n "STUN port (UDP, default 3478): " ;;
      invalid_port) echo "Invalid port (1-65535)" ;;
      firewall_title) echo " Firewall/security group reminder" ;;
      firewall_intro) echo " Allow the following in your VPS provider security group:" ;;
      firewall_derp) echo "   - TCP  ${1}  (DERP relay)" ;;
      firewall_stun) echo "   - UDP  ${1}  (STUN)" ;;
      firewall_http) echo "   - TCP  80  (Let's Encrypt certificate verification)" ;;
      firewall_confirm) echo -n "Confirmed allowed? Press Enter to continue..." ;;
      dirs_created) echo "Directories created: ${1}" ;;
      config_written) echo "Config written to ${1}" ;;
      install_start) echo "Starting Tailscale DERP (Docker) installation" ;;
      already_installed) echo "Existing tderp detected (${INSTALL_DIR} exists)" ;;
      reinstall_prompt) echo "Reinstall and overwrite existing config?" ;;
      install_cancelled) echo "Installation cancelled" ;;
      cleanup_old) echo "Cleaning old config..." ;;
      dns_retry) echo "Check network or fix DNS and retry" ;;
      no_docker) echo "Docker is not installed" ;;
      install_docker_prompt) echo "Install Docker automatically?" ;;
      docker_retry) echo "Cancelled. Install Docker manually and retry." ;;
      compose_download_failed) echo "Failed to download compose template (all sources unreachable)" ;;
      rollback_cleanup) echo "Rollback: cleaning config directory" ;;
      compose_downloaded) echo "Compose template downloaded" ;;
      verify_socket) echo "Verify-clients enabled: tailscale socket mounted" ;;
      image_pull_failed) echo "Failed to pull image" ;;
      image_tip) echo "  Troubleshooting:" ;;
      image_tip1) echo "  1. Check image address: ${1}" ;;
      image_tip2) echo "  2. On China networks, try an accelerator (choose 2 or 3 in the mirror step)" ;;
      image_tip3) echo "  3. Check whether Docker has a registry mirror configured" ;;
      image_pulled) echo "Image pulled successfully" ;;
      compose_missing_error) echo "docker compose not found; install it first" ;;
      compose_config_failed) echo "docker-compose.yml config validation failed!" ;;
      compose_config_tip1) echo "  1. Config retained at ${1}; inspect docker-compose.yml" ;;
      compose_config_tip2) echo "  2. Run ${1} config to see the exact error" ;;
      compose_config_tip3) echo "  3. Select 8 to uninstall before reinstalling" ;;
      config_retained) echo "Config retained at ${1} for diagnosis; nothing was deleted" ;;
      compose_start_failed) echo "Docker Compose startup failed" ;;
      compose_rollback) echo "Rollback: stopped containers; config retained at ${1}" ;;
      compose_start_tip1) echo "  1. Check logs: docker logs derper" ;;
      compose_start_tip2) echo "  2. Check config: ${1}/docker-compose.yml and ${1}/.env" ;;
      container_running) echo "DERP container is running" ;;
      container_status) echo "Container status: ${1}; check logs" ;;
      auth_title) echo " Verify-clients enabled; tailscale login required" ;;
      auth_run) echo "Running tailscale up..." ;;
      auth_link) echo "  Copy the link below into a browser to authorize:" ;;
      tailscale_not_found) echo "tailscale not detected; install and log in manually" ;;
      logged_in_prompt) echo -n "  Is tailscale logged in? Press Enter to continue..." ;;
      register_script) echo "Downloading the management script from GitHub..." ;;
      register_failed) echo "Script download failed; manually download to ${1}/install.sh" ;;
      registered) echo "tderp command registered (${1})" ;;
      install_complete) echo "  Installation complete!" ;;
      summary_derp) echo "  DERP address:   ${1}:${2}" ;;
      summary_stun) echo "  STUN port:      ${1} (UDP)" ;;
      summary_cert) echo "  Certificate:    ${1}" ;;
      summary_command) echo "  Management cmd:  tderp" ;;
      next_steps) echo "  Next steps:" ;;
      next_acl) echo "  1. Open Tailscale admin console → Access Controls (ACL)" ;;
      next_derpmap) echo "  2. Add the node under derpMap.Regions (see menu 7)" ;;
      next_restart) echo "  3. Restart your tailscale client to apply the config" ;;
      cert_le_title) echo "  Let's Encrypt certificate — configuration" ;;
      cert_le_1) echo "  1. Make sure the domain resolves to this server (Cloudflare: add an A record)" ;;
      cert_le_2) echo "     Proxy status must be DNS-only/gray cloud; DERP requires direct access" ;;
      cert_le_3) echo "  2. Open TCP port 80 for the HTTP-01 challenge" ;;
      cert_le_4) echo "  3. The certificate renews automatically; verify-clients is supported" ;;
      cert_ip_title) echo "  Self-signed certificate (public IP) — configuration" ;;
      cert_ip_1) echo "  1. No domain is required; an IP-SAN certificate is generated automatically" ;;
      cert_ip_2) echo "  2. Port 80 is not required; certificate validity is 10 years" ;;
      cert_ip_3) echo "  3. Add InsecureForTests: true for this node in the ACL" ;;
      cert_cf_title) echo "  Cloudflare Origin CA — configuration" ;;
      cert_cf_1) echo "  1. The certificate was issued automatically through the Cloudflare API" ;;
      cert_cf_2) echo "     15-year validity; no port 80 or ICP filing is required" ;;
      cert_cf_3) echo "  2. Clients trust the certificate directly; no extra ACL flag is required" ;;
      cert_self_title) echo "  Self-signed certificate — configuration" ;;
      cert_self_1) echo "  1. No domain or port 80 is required" ;;
      cert_self_2) echo "  2. A 10-year certificate is generated on first startup" ;;
      cert_self_3) echo "  3. Add InsecureForTests: true for this node in the ACL" ;;
      press_return_continue) echo -n "Press Enter to continue..." ;;
      uninstall_title) echo " Full uninstall will remove:" ;;
      uninstall_item1) echo "  - DERP container and image" ;;
      uninstall_item2) echo "  - All config under ${1} (including certificates)" ;;
      uninstall_item3) echo "  - tderp command link" ;;
      uninstall_item4) echo "  - Tailscale login state (force re-login on next install)" ;;
      uninstall_item5) echo "  - Cron jobs / timers managed by tderp (if any)" ;;
      prompt_confirm_uninstall) echo -n "Confirm full uninstall? [y/N] " ;;
      info_cancelled) echo "Uninstall cancelled" ;;
      info_stop_container) echo "Stopping DERP container..." ;;
      info_remove_image) echo "Removing DERP image..." ;;
      info_remove_dirs) echo "Removing config directory and command link..." ;;
      *) echo "$key" ;;
    esac
  else
    case "$key" in
      docker_missing) echo "检测到未安装 Docker，准备自动安装..." ;;
      docker_menu) echo " Docker 引擎安装方式（按你的服务器所在地选择）" ;;
      docker_cn) echo "  1. 国内服务器（使用阿里云镜像源，速度快）" ;;
      docker_intl) echo "  2. 国外服务器（使用 Docker 官方脚本）" ;;
      docker_manual) echo "  3. 手动安装（跳过，我自行安装）" ;;
      docker_choice) echo -n "请选择 [1-3] (默认 2): " ;;
      invalid_123) echo "输入无效，请输入 1、2 或 3" ;;
      aliyun_install) echo "使用阿里云镜像源安装 Docker..." ;;
      aliyun_failed) echo "清华镜像源安装失败，尝试官方脚本..." ;;
      docker_failed) echo "Docker 安装失败" ;;
      official_install) echo "使用 Docker 官方脚本安装..." ;;
      docker_skipped) echo "跳过 Docker 安装。请手动安装后重新运行此脚本。" ;;
      docker_verify) echo "验证 Docker..." ;;
      docker_installed) echo "Docker 安装成功: $(docker --version)" ;;
      compose_missing) echo "未检测到 docker compose，尝试安装 compose 插件..." ;;
      compose_failed) echo "compose 插件安装失败，请手动安装 docker-compose" ;;
      docker_unusable) echo "Docker 安装后仍无法使用，请手动排查" ;;
      mirror_menu) echo " 选择镜像拉取地址（ghcr.io 国内加速）" ;;
      mirror_direct) echo "  1. 默认直连  ghcr.io              （国外 VPS 推荐）" ;;
      mirror_recommended) echo "  2. 推荐加速  ghcr.chenby.cn       （国内 VPS 推荐）" ;;
      mirror_backup) echo "  3. 备用加速  ghcr.milu.moe        （国内 VPS 备选）" ;;
      mirror_nju) echo "  4. 南大镜像  ghcr.nju.edu.cn      （国内教育网，速度快）" ;;
      mirror_proxy) echo "  5. DockerProxy ghcr.dockerproxy.com （CF 加速）" ;;
      mirror_custom) echo "  c. 自定义地址（输入你的加速站）" ;;
      mirror_choice) echo -n "请选择 [1-5/c] (默认 2): " ;;
      mirror_custom_prompt) echo -n "请输入自定义镜像地址（如 my.mirror.com）: " ;;
      input_empty) echo "输入不能为空" ;;
      input_invalid) echo "输入无效" ;;
      mirror_prefix) echo "镜像前缀: ${1}" ;;
      mirror_unresolved) echo "无法解析 ${1}，请检查网络或后续拉取可能失败" ;;
      dns_ok) echo "DNS 解析正常" ;;
      dns_failed) echo "无法解析 ${1}，可能是 DNS 被锁定或网络问题" ;;
      solution) echo "  【解决方案】" ;;
      dns_solution1) echo "  1. 检查 /etc/resolv.conf 中的 DNS 是否正常" ;;
      dns_solution2) echo "  2. 可尝试修改为公共 DNS：" ;;
      dns_solution3) echo "  3. 修改后重新运行脚本" ;;
      port_tcp_busy) echo "端口 ${1}(TCP) 已被占用，请更换 DERP 端口或先释放该端口" ;;
      port_udp_busy) echo "端口 ${1}(UDP) 已被占用，请更换 STUN 端口或先释放该端口" ;;
      port_solution1) echo "  1. 查看占用进程: ss -tulnp | grep -E '${1}|${2}'" ;;
      port_solution2) echo "  2. 更换端口后重新安装" ;;
      ports_free) echo "端口均空闲" ;;
      verify_title) echo " 防白嫖（verify-clients）" ;;
      verify_desc1) echo " 开启后，只有你 tailnet 内的设备才能使用此 DERP 中继" ;;
      verify_desc2) echo " 需要 VPS 上安装 tailscale 客户端并登录到你的 tailnet" ;;
      verify_desc3) echo " 默认不开启；如果你只自己用，可不开启" ;;
      verify_prompt) echo "是否开启防白嫖（verify-clients）？" ;;
      verify_enabled) echo "已开启防白嫖。检测 tailscale 客户端..." ;;
      tailscale_missing) echo "未检测到 tailscale 客户端，将自动安装..." ;;
      tailscale_install_failed) echo "tailscale 自动安装失败，请手动安装后重试" ;;
      tailscale_ready) echo "tailscale 客户端已安装，DERP 容器启动后将自动登录" ;;
      tailscale_installing) echo "安装 tailscale 客户端..." ;;
      tailscale_installed) echo "tailscale 安装完成" ;;
      tailscale_login_command) echo "  请执行以下命令登录到你的 tailnet：" ;;
      tailscale_login_hint) echo "  根据提示在浏览器中登录授权" ;;
      dns_checking) echo "检测 DNS 状态..." ;;
      dns_healthy) echo "DNS 正常，无需修复" ;;
      current_dns) echo "  当前 DNS 配置：" ;;
      dns_title) echo " 阿里云 VPS DNS 修复工具" ;;
      aliyun_dns_issue) echo " 阿里云内网 DNS（100.100.2.136/138）经常超时导致域名无法解析" ;;
      fix_method) echo " 修复方案：使用公共 DNS 替代" ;;
      aliyun_dns) echo "   - 阿里云公共 DNS: 223.5.5.5 / 223.6.6.6" ;;
      google_dns) echo "   - Google DNS: 8.8.8.8 / 8.8.4.4" ;;
      fix_auto) echo "  1. 一键修复（推荐）" ;;
      fix_manual) echo "  2. 手动修复（自行配置）" ;;
      fix_skip) echo "  3. 跳过" ;;
      fix_choice) echo -n "请选择 [1-3] (默认 1): " ;;
      fixing_dns) echo "修复 DNS..." ;;
      dns_fixed) echo "DNS 修复成功！github.com 已可解析" ;;
      dns_unfixed) echo "DNS 修复后仍无法解析，请检查网络配置" ;;
      fix_manual_steps) echo "手动修复步骤：" ;;
      fix_skip_msg) echo "已跳过" ;;
      press_return) echo "按回车返回..." ;;
      bbr_checking) echo "检查系统 BBR 支持情况..." ;;
      kernel_version) echo "内核版本: ${1}" ;;
      current_algorithm) echo "  当前算法: ${1}" ;;
      bbr_already) echo "BBR 已启用（拥塞控制算法: bbr）" ;;
      disable_bbr_hint) echo "如需关闭 BBR：" ;;
      disable_bbr_step1) echo "  sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d' /etc/sysctl.d/99-bbr.conf" ;;
      disable_bbr_step2) echo "  sysctl -p /etc/sysctl.d/99-bbr.conf" ;;
      disable_bbr_step3) echo "  sysctl -w net.ipv4.tcp_congestion_control=cubic" ;;
      module_load) echo "  模块加载: ${1}" ;;
      module_unavailable) echo "  模块加载: ${1} 模块不可用" ;;
      available_algorithms) echo "  可用算法: ${1}" ;;
      kernel_ok) echo "  内核版本: ${1} (≥ 4.9，支持 BBR)" ;;
      bbr_supported) echo "系统支持 BBR，可开启加速" ;;
      enable_bbr_prompt) echo "是否开启 BBR 加速（TCP 性能优化，适合国内 VPS）？" ;;
      enabling_bbr) echo "开启 BBR..." ;;
      bbr_enabled) echo "BBR 已启用！拥塞控制算法: ${1}" ;;
      bbr_failed) echo "BBR 配置可能未生效，当前算法: ${1}" ;;
      bbr_skipped) echo "已跳过" ;;
      bbr_not_supported) echo "当前环境不支持 BBR（所有检测均未通过）" ;;
      kernel_unsupported) echo "当前内核不支持 BBR，可尝试安装新内核" ;;
      install_kernel) echo "  1. 尝试安装新内核（部分老系统需要）" ;;
      skip_kernel) echo "  2. 跳过，我自行处理" ;;
      kernel_source) echo " 内核安装源选择" ;;
      kernel_source_cn) echo "  1. 国内服务器（使用镜像源，速度快）" ;;
      kernel_source_intl) echo "  2. 国外服务器（使用官方源）" ;;
      kernel_source_manual) echo "  3. 手动安装（跳过，我自行安装）" ;;
      kernel_source_choice) echo -n "请选择 [1-3] (默认 1): " ;;
      kernel_skipped_msg) echo "已跳过，请自行安装内核" ;;
      debian_installing) echo "Debian/Ubuntu 系统：安装主线内核..." ;;
      debian_mirror) echo "使用国内镜像源..." ;;
      debian_failed) echo "自动安装内核失败，请手动安装后重试" ;;
      rhel_installing) echo "RHEL 系列系统：安装主线内核..." ;;
      rhel_mirror) echo "使用国内镜像源 (阿里云镜像)..." ;;
      rhel_failed) echo "自动安装内核失败，请手动安装后重试" ;;
      kernel_done) echo "内核安装完成！请重启系统使新内核生效：" ;;
      reboot_hint) echo "  重启后重新运行此菜单开启 BBR" ;;
      unknown_system) echo "未能识别的系统 (${1})，请手动安装内核" ;;
      derp_domain_title) echo " 配置 DERP 域名/IP" ;;
      ip_mode) echo "纯 IP 模式：自动获取公网 IP..." ;;
      detected_ip) echo "检测到公网 IP: ${1}" ;;
      use_detected_ip) echo "使用此 IP 作为 DERP 地址？" ;;
      manual_ip) echo "请输入公网 IP: " ;;
      invalid_ip) echo "IP 格式不正确" ;;
      auto_ip_failed) echo "自动获取公网 IP 失败，请手动输入" ;;
      domain_prompt) echo "请输入域名（或公网 IP）" ;;
      domain_example) echo "域名示例: derp.example.com（需已解析到本机，CF 关闭代理/灰色云朵）" ;;
      ip_example) echo "IP 示例:   1.2.3.4" ;;
      domain_ip_prompt) echo -n "域名/IP: " ;;
      invalid_domain_ip) echo "格式不正确，请输入有效域名或 IP" ;;
      derp_address) echo "DERP 地址: ${1}" ;;
      ports_title) echo " 配置端口" ;;
      derp_port) echo "DERP 端口 (TCP, 默认 12345, 建议高位端口): " ;;
      derp_port_retry) echo "DERP 端口 (TCP, 默认 12345): " ;;
      stun_port) echo "STUN 端口 (UDP, 默认 3478): " ;;
      stun_port_retry) echo "STUN 端口 (UDP, 默认 3478): " ;;
      invalid_port) echo "端口格式不正确（1-65535）" ;;
      firewall_title) echo " 防火墙/安全组放行提醒" ;;
      firewall_intro) echo " 请在 VPS 服务商（阿里云/腾讯云等）安全组中放行：" ;;
      firewall_derp) echo "   - TCP  ${1}  (DERP 中继)" ;;
      firewall_stun) echo "   - UDP  ${1}  (STUN)" ;;
      firewall_http) echo "   - TCP  80  (Let's Encrypt 证书验证)" ;;
      firewall_confirm) echo "已确认放行？按回车继续..." ;;
      dirs_created) echo "目录已创建: ${1}" ;;
      config_written) echo "配置已写入 ${1}" ;;
      install_start) echo "开始安装 Tailscale DERP（Docker 版）" ;;
      already_installed) echo "检测到已安装 tderp（${INSTALL_DIR} 已存在）" ;;
      reinstall_prompt) echo "是否重新安装（覆盖现有配置）？" ;;
      install_cancelled) echo "已取消安装" ;;
      cleanup_old) echo "清理旧配置..." ;;
      dns_retry) echo "请检查网络或修改 DNS 后重试" ;;
      no_docker) echo "未安装 Docker" ;;
      install_docker_prompt) echo "是否自动安装 Docker？" ;;
      docker_retry) echo "已取消，请手动安装 Docker 后重试" ;;
      compose_download_failed) echo "下载 compose 模板失败（多源均不可达）" ;;
      rollback_cleanup) echo "回滚：清理配置目录" ;;
      compose_downloaded) echo "compose 模板已获取" ;;
      verify_socket) echo "防白嫖模式：已挂载 tailscale socket" ;;
      image_pull_failed) echo "拉取镜像失败" ;;
      image_tip) echo "$(msg image_tip)" ;;
      image_tip1) echo "  1. 检查镜像源地址是否正确: ${1}" ;;
      image_tip2) echo "  2. 若是国内网络，尝试用加速地址（镜像源步骤选择 2 或 3）" ;;
      image_tip3) echo "$(msg image_tip3)" ;;
      image_pulled) echo "镜像拉取成功" ;;
      compose_missing_error) echo "未找到 docker compose，请先安装" ;;
      compose_config_failed) echo "docker-compose.yml 配置校验失败！" ;;
      compose_config_tip1) echo "  1. 配置已保留在 ${1}，可手动查看 docker-compose.yml" ;;
      compose_config_tip2) echo "  2. 运行 ${1} config 查看具体报错" ;;
      compose_config_tip3) echo "$(msg compose_config_tip3)" ;;
      config_retained) echo "⚠️ 已保留配置 ${1} 供诊断，未删除" ;;
      compose_start_failed) echo "Docker Compose 启动失败" ;;
      compose_rollback) echo "回滚：停止容器（保留配置 ${1} 供诊断）" ;;
      compose_start_tip1) echo "$(msg compose_start_tip1)" ;;
      compose_start_tip2) echo "  2. 查看配置: ${1}/docker-compose.yml 与 ${1}/.env" ;;
      container_running) echo "DERP 容器运行中" ;;
      container_status) echo "容器状态: ${1}，请查看日志" ;;
      auth_title) echo " 防白嫖已开启，需要登录 tailscale" ;;
      auth_run) echo "执行 tailscale up..." ;;
      auth_link) echo "  请复制下方链接到浏览器完成授权：" ;;
      tailscale_not_found) echo "未检测到 tailscale，请手动安装并登录" ;;
      logged_in_prompt) echo "  tailscale 已登录？（回车继续）..." ;;
      register_script) echo "通过 GitHub 下载安装脚本..." ;;
      register_failed) echo "下载安装脚本失败，可手动下载到 ${1}/install.sh" ;;
      registered) echo "tderp 命令已注册（${1}）" ;;
      install_complete) echo "  ✅ 安装完成！" ;;
      summary_derp) echo "  DERP 地址:   ${1}:${2}" ;;
      summary_stun) echo "  STUN 端口:   ${1} (UDP)" ;;
      summary_cert) echo "  证书方式:    ${1}" ;;
      summary_command) echo "  管理命令:    tderp" ;;
      next_steps) echo "  接下来：" ;;
      next_acl) echo "  1. 打开 Tailscale 管理后台 → Access Controls (ACL)" ;;
      next_derpmap) echo "  2. 在 derpMap.Regions 中添加节点（见菜单 7）" ;;
      next_restart) echo "  3. 重启你的 tailscale 客户端使配置生效" ;;
      cert_le_title) echo "  【Let's Encrypt 自动证书 — 配置说明】" ;;
      cert_le_1) echo "  1. 请确保域名已解析到本机 IP（以 Cloudflare 为例，添加 A 记录）" ;;
      cert_le_2) echo "     代理状态必须关闭（灰色云朵），DERP 需要直连" ;;
      cert_le_3) echo "  2. 请开放 TCP 80 端口用于 HTTP-01 验证" ;;
      cert_le_4) echo "  3. 证书自动申请和续期，此模式支持 verify-clients" ;;
      cert_ip_title) echo "  【自签名证书（纯 IP）— 配置说明】" ;;
      cert_ip_1) echo "  1. 无需域名，脚本会自动生成带 IP SAN 的证书" ;;
      cert_ip_2) echo "  2. 无需开放 80 端口，证书有效期 10 年" ;;
      cert_ip_3) echo "  3. 请在 ACL 中为该节点加 InsecureForTests: true" ;;
      cert_cf_title) echo "  【Cloudflare Origin CA — 配置说明】" ;;
      cert_cf_1) echo "  1. 已通过 CF API 自动签发证书" ;;
      cert_cf_2) echo "     有效期 15 年，无需开放 80 端口，无需备案" ;;
      cert_cf_3) echo "  2. 客户端直接信任证书，无需额外 ACL 标记" ;;
      cert_self_title) echo "  【自签名证书 — 配置说明】" ;;
      cert_self_1) echo "  1. 无需域名、无需开放 80 端口" ;;
      cert_self_2) echo "  2. 首次启动时自动生成有效期 10 年的证书" ;;
      cert_self_3) echo "  3. 请在 ACL 中为该节点加 InsecureForTests: true" ;;
      press_return_continue) echo -n "按回车继续..." ;;
      uninstall_title) echo " 完全卸载将删除：" ;;
      uninstall_item1) echo "  - DERP 容器与镜像" ;;
      uninstall_item2) echo "  - ${1} 下的全部配置（含证书）" ;;
      uninstall_item3) echo "  - tderp 命令链接" ;;
      uninstall_item4) echo "  - Tailscale 登录状态（下次安装强制重新登录）" ;;
      uninstall_item5) echo "  - tderp 管理的定时任务（如有）" ;;
      prompt_confirm_uninstall) echo -n "确认完全卸载？[y/N] " ;;
      info_cancelled) echo "已取消卸载" ;;
      info_stop_container) echo "正在停止 DERP 容器..." ;;
      info_remove_image) echo "正在删除 DERP 镜像..." ;;
      info_remove_dirs) echo "正在删除配置目录与命令链接..." ;;
      *) echo "$key" ;;
    esac
  fi
}

# ------------------------------------------------------------
# 工具函数
# ------------------------------------------------------------

# 检查 root 权限
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    _error "请以 root 权限运行（sudo 或 root 用户）"
    exit 1
  fi
}

# 检测系统架构
detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "unknown (${arch})" ;;
  esac
}

# 生成随机区域 ID
gen_region_id() {
  echo $((900 + RANDOM % 100))
}

# 读取 .env 文件中的变量
env_get() {
  local key="$1"
  local val=""
  if [ -f "${ENV_FILE}" ]; then
    val=$(grep -E "^${key}=" "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d'=' -f2-)
  fi
  echo "$val"
}

# 写入 .env 文件
env_set() {
  local key="$1" val="$2"
  mkdir -p "${INSTALL_DIR}"
  if [ -f "${ENV_FILE}" ] && grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

# 将 tderp.env 同步为 .env（docker compose 默认读取同目录 .env）
# 修复：compose 模板用 ${VAR} 插值时若读不到 tderp.env 会导致空变量
# 注意：tderp.env 和 compose 模板变量名不一致，需映射
sync_compose_env() {
  if [ -f "${ENV_FILE}" ]; then
    # 先直接复制
    sed 's/^export //' "${ENV_FILE}" > "${INSTALL_DIR}/.env"
    # 补充 compose 模板需要的变量名（tderp.env 里的命名可能不同）
    local cert_mode
    cert_mode="$(env_get CERT_MODE)"
    [ -n "${cert_mode}" ] && echo "DERP_CERT_MODE=${cert_mode}" >> "${INSTALL_DIR}/.env"
    local http_port
    http_port="$(env_get HTTP_PORT)"
    [ -n "${http_port}" ] && echo "DERP_HTTP_PORT=${http_port}" >> "${INSTALL_DIR}/.env"
    local verify_clients
    verify_clients="$(env_get VERIFY_CLIENTS)"
    [ -n "${verify_clients}" ] && echo "DERP_VERIFY_CLIENTS=${verify_clients}" >> "${INSTALL_DIR}/.env"
    _ok "已同步 ${INSTALL_DIR}/.env（含变量映射）"
  fi
}

# 检测 Docker 是否安装
docker_installed() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# 检测 docker compose 插件（v2 语法）或 standalone
docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    echo ""
  fi
}

# 检测指定端口是否被占用
port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tuln 2>/dev/null | grep -qE "(:|^.*)${port}\s"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln 2>/dev/null | grep -qE "(:|^.*)${port}\s"
  else
    return 1  # 无法检测，放行
  fi
}

# 检测 DNS 能否解析域名（B0）
dns_check() {
  local host="$1"
  # 提取 hostname（去掉协议前缀和端口）
  host="${host#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  # 如果是 IP 直接通过
  if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    return 0
  fi
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" >/dev/null 2>&1
  elif command -v getent >/dev/null 2>&1; then
    getent hosts "$host" >/dev/null 2>&1
  else
    ping -c 1 -W 2 "$host" >/dev/null 2>&1
  fi
}

# 输入验证：域名
validate_domain() {
  local input="$1"
  [[ "$input" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

# 输入验证：IPv4
validate_ip() {
  local input="$1"
  [[ "$input" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  local IFS='.' part
  for part in $input; do
    [ "$part" -ge 0 ] && [ "$part" -le 255 ] || return 1
  done
  return 0
}

# 输入验证：端口
validate_port() {
  local input="$1"
  [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]
}

# 获取公网 IP
get_public_ip() {
  local ip=""
  # 依次尝试多个来源
  for url in "https://api.ip.sb/ip" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
    ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d ' \n')
    if validate_ip "$ip"; then
      echo "$ip"
      return 0
    fi
  done
  echo ""
  return 1
}

# 检查 tderp 是否已安装（存在环境文件）
is_installed() {
  # 有 tderp.env 才算已安装（/opt/tderp 目录可能因自举创建而存在）
  [ -f "${ENV_FILE}" ]
}

# 获取容器运行状态
container_status() {
  if ! docker_installed; then
    echo "no_docker"
  elif docker inspect -f '{{.State.Running}}' derper >/dev/null 2>&1; then
    local running
    running=$(docker inspect -f '{{.State.Running}}' derper 2>/dev/null)
    if [ "$running" = "true" ]; then
      echo "running"
    else
      echo "stopped"
    fi
  else
    echo "not_found"
  fi
}

# 证书剩余天数
cert_days_left() {
  local domain="$1"
  local certfile=""
  if [ -f "${CERTS_DIR}/${domain}.crt" ]; then
    certfile="${CERTS_DIR}/${domain}.crt"
  elif ls "${CERTS_DIR}"/*.crt >/dev/null 2>&1; then
    certfile=$(ls "${CERTS_DIR}"/*.crt 2>/dev/null | head -1)
  else
    echo ""
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    local enddate
    enddate=$(openssl x509 -in "$certfile" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$enddate" ]; then
      local end_epoch now_epoch
      end_epoch=$(date -d "$enddate" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      if [ "$end_epoch" -gt "$now_epoch" ] 2>/dev/null; then
        echo $(( (end_epoch - now_epoch) / 86400 ))
        return
      fi
    fi
  fi
  echo ""
}

# 判断证书是否由 Cloudflare 签发（Origin CA）
cert_is_cf() {
  local domain="$1"
  local certfile=""
  if [ -f "${CERTS_DIR}/${domain}.crt" ]; then
    certfile="${CERTS_DIR}/${domain}.crt"
  elif ls "${CERTS_DIR}"/*.crt >/dev/null 2>&1; then
    certfile=$(ls "${CERTS_DIR}"/*.crt 2>/dev/null | head -1)
  else
    return 1
  fi
  # 检查签发者是否含 Cloudflare
  if command -v openssl >/dev/null 2>&1; then
    local issuer
    issuer=$(openssl x509 -in "$certfile" -noout -issuer 2>/dev/null | grep -io "cloudflare" | head -1)
    [ -n "$issuer" ] && return 0
  fi
  return 1
}

ask_yes_no() {
  local prompt="$1" default="${2:-y}"
  local ans
  echo -n "${prompt} [Y/n] "
  read -r ans
  ans=$(echo "$ans" | tr '[:upper:]' '[:lower:]')
  if [ -z "$ans" ]; then ans="$default"; fi
  [ "$ans" = "y" ] || [ "$ans" = "yes" ]
}

# 语义化版本号比较：v1 > v2 返回 0，否则返回 1
# 支持多段数字（如 3.0.4、3.0.10），每段按数字比较
version_gt() {
  local v1="$1" v2="$2"
  local IFS=.
  local a b
  IFS=. read -ra a <<< "$v1"
  IFS=. read -ra b <<< "$v2"
  local i max=${#a[@]}
  [ ${#b[@]} -gt "$max" ] && max=${#b[@]}
  for ((i=0; i<max; i++)); do
    local na="${a[$i]:-0}" nb="${b[$i]:-0}"
    # 去除非数字前缀（如 "v3.0.4" → "3.0.4"）
    na="${na//[!0-9]/}"; nb="${nb//[!0-9]/}"
    na="${na:-0}"; nb="${nb:-0}"
    if [ "$na" -gt "$nb" ] 2>/dev/null; then return 0; fi
    if [ "$na" -lt "$nb" ] 2>/dev/null; then return 1; fi
  done
  return 1
}
# ============================================================
# 安装 Docker 引擎（G2: 区分国内外）
# ============================================================
install_docker_engine() {
  _info "$(msg docker_missing)"
  echo ""
  echo "----------------------------------------------"
  echo "$(msg docker_menu)"
  echo "----------------------------------------------"
  echo "$(msg docker_cn)"
  echo "$(msg docker_intl)"
  echo "$(msg docker_manual)"
  echo "----------------------------------------------"
  local choice
  while true; do
    read -r -p "$(msg docker_choice)" choice
    [ -z "$choice" ] && choice=2
    case "$choice" in
      1|2|3) break ;;
      *) _warn "$(msg invalid_123)" ;;
    esac
  done

  case "$choice" in
    1)
      _info "$(msg aliyun_install)"
      bash <(curl -sSL https://mirrors.aliyun.com/docker-ce/linux/install.sh) || {
        _error "$(msg aliyun_failed)"
        bash <(curl -sSL https://get.docker.com) || { _error "$(msg docker_failed)"; return 1; }
      }
      ;;
    2)
      _info "$(msg official_install)"
      curl -fsSL https://get.docker.com | bash || { _error "$(msg docker_failed)"; return 1; }
      ;;
    3)
      _warn "$(msg docker_skipped)"
      return 1
      ;;
  esac

  systemctl enable --now docker 2>/dev/null || true
  _info "$(msg docker_verify)"
  if docker_installed; then
    _ok "$(msg docker_installed)"
    if [ -z "$(docker_compose_cmd)" ]; then
      _warn "$(msg compose_missing)"
      apt-get update -qq && apt-get install -y -qq docker-compose-plugin 2>/dev/null || \
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2 2>/dev/null || \
      _warn "$(msg compose_failed)"
    fi
    return 0
  else
    _error "$(msg docker_unusable)"
    return 1
  fi
}

# ============================================================
# DNS 解析检测（B0）— 检测镜像源能否解析
# ============================================================
step_dns_check() {
  local mirror_host="$1"
  _step 1 11 "$(t step_install_1 "${mirror_host}")"
  if dns_check "${mirror_host}"; then
    _ok "$(msg dns_ok)"
    return 0
  else
    _error "$(msg dns_failed "${mirror_host}")"
    echo ""
    echo "$(msg solution)"
    echo "$(msg dns_solution1)"
    echo "$(msg dns_solution2)"
    echo "     echo 'nameserver 223.5.5.5' > /etc/resolv.conf  # 阿里 DNS"
    echo "     echo 'nameserver 114.114.114.114' >> /etc/resolv.conf"
    echo "$(msg dns_solution3)"
    echo ""
    return 1
  fi
}

# ============================================================
# 端口占用检测（B0b）
# ============================================================
step_port_check() {
  local dport="$1" sport="$2"
  _step 2 11 "$(t step_install_2 "${dport}" "${sport}")"
  local ok=true
  if port_in_use "${dport}"; then
    _error "$(msg port_tcp_busy "${dport}")"
    ok=false
  fi
  if port_in_use "${sport}"; then
    _error "$(msg port_udp_busy "${sport}")"
    ok=false
  fi
  if [ "$ok" = "false" ]; then
    echo ""
    echo "$(msg solution)"
    echo "$(msg port_solution1 "${dport}" "${sport}")"
    echo "$(msg port_solution2)"
    echo ""
    return 1
  fi
  _ok "$(msg ports_free)"
  return 0
}

# ============================================================
# 镜像加速地址选择（需求 10）— 仅中文模式
# ============================================================
step_mirror_select() {
  echo ""
  echo "----------------------------------------------"
  echo "$(msg mirror_menu)"
  echo "----------------------------------------------"
  echo "$(msg mirror_direct)"
  echo "$(msg mirror_recommended)"
  echo "$(msg mirror_backup)"
  echo "$(msg mirror_nju)"
  echo "$(msg mirror_proxy)"
  echo "$(msg mirror_custom)"
  echo "----------------------------------------------"
  local choice
  while true; do
    read -r -p "$(msg mirror_choice)" choice
    [ -z "$choice" ] && choice=2
    case "$choice" in
      1) MIRROR_PREFIX="ghcr.io"; break ;;
      2) MIRROR_PREFIX="ghcr.chenby.cn"; break ;;
      3) MIRROR_PREFIX="ghcr.milu.moe"; break ;;
      4) MIRROR_PREFIX="ghcr.nju.edu.cn"; break ;;
      5) MIRROR_PREFIX="ghcr.dockerproxy.com"; break ;;
      c|C)
        read -r -p "$(msg mirror_custom_prompt)" custom
        if [ -n "$custom" ]; then
          MIRROR_PREFIX="${custom}"
          break
        else
          _warn "$(msg input_empty)"
        fi
        ;;
      *) _warn "$(msg input_invalid)" ;;
    esac
  done
  _ok "$(msg mirror_prefix "${MIRROR_PREFIX}")"
  if ! dns_check "${MIRROR_PREFIX}"; then
    _warn "$(msg mirror_unresolved "${MIRROR_PREFIX}")"
  fi
}

# ============================================================
# Cloudflare Origin CA 证书获取
# 通过 CF API 签发 Origin CA 证书（最长 15 年）
# 需用户提供 CF API Token（权限: SSL and Certificates > Edit）
# ============================================================
fetch_cf_cert() {
  echo ""
  echo "----------------------------------------------"
  echo " Cloudflare Origin CA 证书配置"
  echo "----------------------------------------------"
  echo " 本模式通过 Cloudflare API 签发 Origin CA 证书"
  echo " 优点：无需开放 80 端口、无需备案（客户端需 InsecureForTests: true）"
  echo ""
  echo " 【准备 CF API Token】"
  echo "  1. 打开 https://dash.cloudflare.com/profile/api-tokens"
  echo "  2. 创建 Token → 权限: SSL and Certificates → Edit"
  echo "     区域资源: 你域名所在的 zone（如 bobvane.top）"
  echo "  3. 复制生成的 Token（用完即弃，脚本不保存）"
  echo "----------------------------------------------"

  # 读取域名
  local cf_domain="${DERP_DOMAIN:-}"
  if [ -z "${cf_domain}" ]; then
    read -r -p "请输入你的域名（如 derp.bobvane.top）: " cf_domain
  fi
  if [ -z "${cf_domain}" ]; then
    _error "域名不能为空"
    return 1
  fi
  DERP_DOMAIN="${cf_domain}"

  # 读取 CF API Token（显示为星号回显）
  local cf_token=""
  local ch=""
  local _t=""
  while [ -z "${cf_token}" ]; do
    printf "请输入 CF API Token: "
    cf_token=""
    stty -echo
    while IFS= read -r -n1 ch; do
      if [ "${ch}" = "" ] || [ "${ch}" = $'\n' ] || [ "${ch}" = $'\r' ]; then
        break
      fi
      cf_token="${cf_token}${ch}"
      printf "*"
    done
    stty echo
    printf "\n"
    [ -z "${cf_token}" ] && _warn "Token 不能为空"
  done

  # 通过 API 获取 zone id（用于校验 token 有效性）
  local zone_id=""
  zone_id="$(curl -sS --max-time 15 -H "Authorization: Bearer ${cf_token}" \
    "https://api.cloudflare.com/client/v4/zones?name=${cf_domain#*.}" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result',[{}])[0].get('id','') if d.get('success') else '')" 2>/dev/null || echo "")"
  if [ -z "${zone_id}" ]; then
    _error "无法通过 CF API 获取 zone（Token 无效或无权限）"
    _warn "请检查：1) Token 是否有效 2) 是否有 SSL:Certificates:Edit 权限 3) 区域资源是否包含 ${cf_domain#*.}"
    return 1
  fi
  _ok "CF Token 验证通过（zone: ${cf_domain#*.}）"

  # 签发 Origin CA 证书（15年）
    _info "正在向 Cloudflare 申请 Origin CA 证书..."
    mkdir -p "${CERTS_DIR}"

    # 生成本地私钥 + CSR（CF Origin CA 需要真实 CSR，不能传空串）
    local cf_key="${CERTS_DIR}/${cf_domain}.key"
    local cf_csr="${CERTS_DIR}/${cf_domain}.csr"
    local cf_csr_b64=""
    if ! command -v openssl >/dev/null 2>&1; then
      _error "未找到 openssl，无法生成本地 CSR（请安装 openssl）"
      return 1
    fi
    # 生成 2048 位 RSA 私钥
    openssl genrsa -out "${cf_key}" 2048 >/dev/null 2>&1 || { _error "私钥生成失败"; return 1; }
    # 生成 CSR（带 SAN）
    openssl req -new -key "${cf_key}" -out "${cf_csr}" \
      -subj "/CN=${cf_domain}" \
      -addext "subjectAltName=DNS:${cf_domain}" >/dev/null 2>&1 || { _error "CSR 生成失败"; return 1; }
    # CSR 转成单行 JSON 安全格式（把换行转义为 \n）
    cf_csr_b64="$(openssl req -in "${cf_csr}" -outform PEM 2>/dev/null | sed 's/$/\\n/' | tr -d '\n')"
    [ -z "${cf_csr_b64}" ] && { _error "CSR 读取失败"; return 1; }

    local cert_resp
    cert_resp="$(curl -sS --max-time 30 -X POST \
      -H "Authorization: Bearer ${cf_token}" \
      -H "Content-Type: application/json" \
      --data "{\"hostnames\":[\"${cf_domain}\"],\"requested_validity\":5475,\"request_type\":\"origin-rsa\",\"csr\":\"${cf_csr_b64}\"}" \
      "https://api.cloudflare.com/client/v4/certificates" 2>/dev/null)"
  local success
  success="$(echo "${cert_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('success') else 'false')" 2>/dev/null || echo "false")"
  if [ "${success}" != "true" ]; then
    _error "CF 证书签发失败"
    echo "${cert_resp}" | python3 -c "import sys,json; d=json.load(sys.stdin); [print('  -', e.get('message','')) for e in d.get('errors',[])]" 2>/dev/null
    return 1
  fi
  # 提取证书（私钥已生成本地）
  echo "${cert_resp}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d['result']
cert = r['certificate']
open('${CERTS_DIR}/${cf_domain}.crt','w').write(cert + '\n')
print('expires:', r.get('expires_on',''))
" 2>&1
  if [ -f "${CERTS_DIR}/${cf_domain}.crt" ] && [ -f "${CERTS_DIR}/${cf_domain}.key" ]; then
    chmod 600 "${CERTS_DIR}/${cf_domain}.key"
    rm -f "${CERTS_DIR}/${cf_domain}.csr"   # 清理临时 CSR
    _ok "CF Origin CA 证书已保存到 ${CERTS_DIR}/${cf_domain}.crt"
    return 0
  else
    _error "证书文件写入失败"
    return 1
  fi
}

# ============================================================
# 证书方案选择（需求 11）
# ============================================================
step_cert_select() {
  echo ""
  echo "----------------------------------------------"
  if [ "${LANG}" = "${LANG_EN}" ]; then
    # ===== 英文版：四种证书模式 =====
    echo " Certificate mode (choose one)"
    echo "----------------------------------------------"
    echo "  1. Let's Encrypt (domain) - default"
    echo "     - Domain must resolve to this server"
    echo "     - Auto renew, supports verify-clients"
    echo "     - ★ Requires port 80 (HTTP-01)"
    echo ""
    echo "  2. Self-signed (IP, no domain)"
    echo "     - No domain needed, use public IP"
    echo "     - 10-year self-signed cert, auto-generated"
    echo "     - Requires no port 80"
    echo "     - Client needs InsecureForTests: true"
    echo ""
    echo "  3. Cloudflare Origin CA"
    echo "     - Domain hosted on Cloudflare"
    echo "     - No port 80, no ICP filing needed"
    echo "     - Client trusts directly"
    echo ""
    echo "  4. Self-signed"
    echo "     - No domain, no port 80"
    echo "     - 10-year validity"
    echo "     - Client needs InsecureForTests: true"
    echo "----------------------------------------------"
    local choice
    while true; do
      read -r -p "Select [1-4] (default 1): " choice
      [ -z "$choice" ] && choice=1
      case "$choice" in
        1|2|3|4) break ;;
        *) _warn "Invalid input, enter 1-4" ;;
      esac
    done
    case "$choice" in
      1)
        CERT_MODE="letsencrypt"; HTTP_PORT="80"; CERT_LE_DOMAIN="true"; CERT_LE_IP=""
        _info "Selected Let's Encrypt (domain)"
        ;;
      2)
        CERT_MODE="manual"; HTTP_PORT="-1"; CERT_LE_DOMAIN=""; CERT_LE_IP="true"
        _info "Selected Self-signed (IP)"
        ;;
      3)
        CERT_MODE="manual"; HTTP_PORT="-1"; CERT_LE_DOMAIN=""; CERT_LE_IP=""; CERT_CF="true"
        _info "Selected Cloudflare Origin CA"
        fetch_cf_cert || { _error "CF 证书获取失败，安装中止"; return 1; }
        ;;
      4)
        CERT_MODE="manual"; HTTP_PORT="-1"; CERT_LE_DOMAIN=""; CERT_LE_IP=""
        _info "Selected Self-signed"
        ;;
    esac
  else
    # ===== 中文版：自签名 / CF 证书（LE 提示切英文）=====
    echo " 证书方式选择（二选一）"
    echo "----------------------------------------------"
    echo "  1. 自签名证书（默认）"
    echo "     - 无需域名、无需开放 80 端口"
    echo "     - 证书自动生成，有效期 10 年"
    echo "     - 客户端需在 ACL 中加 InsecureForTests: true"
    echo ""
    echo "  2. Cloudflare Origin CA（推荐国内 VPS）"
    echo "     - 域名托管在 Cloudflare，无需 80 端口、无需备案"
    echo "     - 通过 CF API 自动签发，有效期 15 年，客户端直接信任"
    echo ""
    echo "  ⚠️ 如需 Let's Encrypt 域名/纯IP 证书，"
    echo "     请切换到英文模式安装（安装前按菜单 1 切换语言）"
    echo "----------------------------------------------"
    local choice
    while true; do
      read -r -p "请选择 [1-2] (默认 1): " choice
      [ -z "$choice" ] && choice=1
      case "$choice" in
        1|2) break ;;
        *) _warn "输入无效，请输入 1 或 2" ;;
      esac
    done
    case "$choice" in
      1)
        CERT_MODE="manual"; HTTP_PORT="-1"; CERT_LE_DOMAIN=""; CERT_LE_IP=""; CERT_CF=""
        _info "已选自签名证书模式"
        ;;
      2)
        CERT_MODE="manual"; HTTP_PORT="-1"; CERT_LE_DOMAIN=""; CERT_LE_IP=""; CERT_CF="true"
        _info "已选 Cloudflare Origin CA 模式"
        fetch_cf_cert || { _error "CF 证书获取失败，安装中止"; return 1; }
        ;;
    esac
  fi

  echo ""
  echo "──────────────────────────────────────────────"
  if [ "${CERT_MODE}" = "letsencrypt" ] && [ "${CERT_LE_DOMAIN:-}" = "true" ]; then
    echo "$(msg cert_le_title)"
    echo "$(msg cert_le_1)"
    echo "$(msg cert_le_2)"
    echo "$(msg cert_le_3)"
    echo "$(msg cert_le_4)"
  elif [ "${CERT_LE_IP:-}" = "true" ]; then
    echo "$(msg cert_ip_title)"
    echo "$(msg cert_ip_1)"
    echo "$(msg cert_ip_2)"
    echo "$(msg cert_ip_3)"
  elif [ "${CERT_CF:-}" = "true" ]; then
    echo "$(msg cert_cf_title)"
    echo "$(msg cert_cf_1)"
    echo "$(msg cert_cf_2)"
    echo "$(msg cert_cf_3)"
  else
    echo "$(msg cert_self_title)"
    echo "$(msg cert_self_1)"
    echo "$(msg cert_self_2)"
    echo "$(msg cert_self_3)"
  fi
  echo "──────────────────────────────────────────────"
  echo ""
  read -r -p "$(msg press_return_continue)"
}

# ============================================================
# verify-clients 防白嫖询问（G1）
# ============================================================
step_verify_clients() {
  VERIFY_CLIENTS="false"
  echo ""
  echo "----------------------------------------------"
  echo "$(msg verify_title)"
  echo "----------------------------------------------"
  echo "$(msg verify_desc1)"
  echo "$(msg verify_desc2)"
  echo "$(msg verify_desc3)"
  echo "----------------------------------------------"
  if ask_yes_no "$(msg verify_prompt)" "n"; then
    VERIFY_CLIENTS="true"
    _info "$(msg verify_enabled)"
    if ! command -v tailscale >/dev/null 2>&1; then
      _warn "$(msg tailscale_missing)"
      install_tailscale_client || {
        _warn "$(msg tailscale_install_failed)"
        VERIFY_CLIENTS="false"
      }
    fi
    if [ "${VERIFY_CLIENTS}" = "true" ]; then
      _info "$(msg tailscale_ready)"
    fi
  fi
}

# ============================================================
# 安装 tailscale 客户端（G1 辅助）
# ============================================================
install_tailscale_client() {
  _info "$(msg tailscale_installing)"
  if curl -fsSL https://tailscale.com/install.sh | bash; then
    _ok "$(msg tailscale_installed)"
    echo "$(msg tailscale_login_command)"
    echo "    tailscale up"
    echo "$(msg tailscale_login_hint)"
    return 0
  else
    _error "$(msg tailscale_install_failed)"
    return 1
  fi
}

# ============================================================
# 安装主流程（12 步）
# ============================================================
install_derp() {
  _info "$(msg install_start)"
  echo ""

  if is_installed; then
    _warn "$(msg already_installed)"
    if ! ask_yes_no "$(msg reinstall_prompt)" "n"; then
      _info "$(msg install_cancelled)"
      return 0
    fi
    _info "$(msg cleanup_old)"
    rm -rf "${INSTALL_DIR}"
  fi

  # ---------- B0: DNS 解析检测 ----------
  MIRROR_PREFIX="ghcr.io"   # 镜像前缀在拉取前选择（见 [7/11] 后）
  DERP_IMAGE="${MIRROR_PREFIX}/bobvane/vps-tailscale-derp-autosetup/derper:latest"
  if ! dns_check "${MIRROR_PREFIX}"; then
    _error "$(msg dns_failed "${MIRROR_PREFIX}")"
    echo "$(msg dns_retry)"
    return 1
  fi

  # ---------- B1: Docker 检测 ----------
  _step 3 11 "$(t step_install_3)"
  if ! docker_installed; then
    _warn "$(msg no_docker)"
    if ! ask_yes_no "$(msg install_docker_prompt)" "y"; then
      _info "$(msg docker_retry)"
      return 1
    fi
    install_docker_engine || return 1
  else
    _ok "$(msg docker_installed)"
  fi

  # ---------- B3: 输入域名 ----------
  echo ""
  echo "----------------------------------------------"
  echo "$(msg derp_domain_title)"
  echo "----------------------------------------------"
  if [ "${CERT_LE_IP:-}" = "true" ]; then
    _info "$(msg ip_mode)"
    PUBLIC_IP="$(get_public_ip)"
    if [ -n "${PUBLIC_IP}" ]; then
      _ok "$(msg detected_ip "${PUBLIC_IP}")"
      if ask_yes_no "$(msg use_detected_ip)" "y"; then
        DERP_DOMAIN="${PUBLIC_IP}"
      else
        while true; do
          read -r -p "$(msg manual_ip)" DERP_DOMAIN
          if validate_ip "${DERP_DOMAIN}"; then break; else _warn "$(msg invalid_ip)"; fi
        done
      fi
    else
      _warn "$(msg auto_ip_failed)"
      while true; do
        read -r -p "$(msg manual_ip)" DERP_DOMAIN
        if validate_ip "${DERP_DOMAIN}"; then break; else _warn "$(msg invalid_ip)"; fi
      done
    fi
  else
    _info "$(msg domain_prompt)"
    _info "$(msg domain_example)"
    _info "$(msg ip_example)"
    while true; do
      read -r -p "$(msg domain_ip_prompt)" DERP_DOMAIN
      if validate_domain "${DERP_DOMAIN}" || validate_ip "${DERP_DOMAIN}"; then
        break
      else
        _warn "$(msg invalid_domain_ip)"
      fi
    done
    if validate_domain "${DERP_DOMAIN}"; then
      PUBLIC_IP="$(get_public_ip)" || true
    fi
  fi
  _ok "$(msg derp_address "${DERP_DOMAIN}")"

  # ---------- B5: DERP 端口 ----------
  echo ""
  echo "----------------------------------------------"
  echo "$(msg ports_title)"
  echo "----------------------------------------------"
  read -r -p "$(msg derp_port)" DERP_PORT
  DERP_PORT="${DERP_PORT:-12345}"
  while ! validate_port "${DERP_PORT}"; do
    _warn "$(msg invalid_port)"
    read -r -p "$(msg derp_port_retry)" DERP_PORT
    DERP_PORT="${DERP_PORT:-12345}"
  done

  # ---------- B6: STUN 端口 ----------
  read -r -p "$(msg stun_port)" STUN_PORT
  STUN_PORT="${STUN_PORT:-3478}"
  while ! validate_port "${STUN_PORT}"; do
    _warn "$(msg invalid_port)"
    read -r -p "$(msg stun_port_retry)" STUN_PORT
    STUN_PORT="${STUN_PORT:-3478}"
  done

  # ---------- 端口占用检测（B0b）----------
  _step 4 11 "$(t step_install_4)"
  if ! step_port_check "${DERP_PORT}" "${STUN_PORT}"; then
    return 1
  fi

  # ---------- B7: 证书方案 ----------
  _step 5 11 "$(t step_install_5)"
  step_cert_select

  # ---------- G1: verify-clients ----------
  step_verify_clients

  # ---------- 端口放行指引 ----------
  echo ""
  echo "----------------------------------------------"
  echo "$(msg firewall_title)"
  echo "----------------------------------------------"
  echo "$(msg firewall_intro)"
  echo "$(msg firewall_derp "${DERP_PORT}")"
  echo "$(msg firewall_stun "${STUN_PORT}")"
  if [ "${HTTP_PORT}" = "80" ]; then
    echo "$(msg firewall_http)"
  fi
  echo "----------------------------------------------"
  read -r -p "$(msg firewall_confirm)"

  # ---------- B8: 生成 compose + 启动 ----------
  _step 6 11 "$(t step_install_6)"
  mkdir -p "${INSTALL_DIR}" "${CERTS_DIR}"
  _ok "$(msg dirs_created "${INSTALL_DIR}")"

  env_set "LANG" "${LANG}"
  env_set "DERP_IMAGE" "${DERP_IMAGE}"
  env_set "DERP_DOMAIN" "${DERP_DOMAIN}"
  env_set "DERP_PORT" "${DERP_PORT}"
  env_set "STUN_PORT" "${STUN_PORT}"
  env_set "CERT_MODE" "${CERT_MODE}"
  env_set "HTTP_PORT" "${HTTP_PORT}"
  env_set "CERT_CF" "${CERT_CF:-}"
  env_set "VERIFY_CLIENTS" "${VERIFY_CLIENTS}"
  env_set "PUBLIC_IP" "${PUBLIC_IP:-}"
  env_set "INSTALLED_VERSION" "${VERSION}"
  _ok "$(msg config_written "${ENV_FILE}")"

  # 下载 compose 模板
  _step 7 11 "$(t step_install_7)"
  local compose_ok=0
  for u in \
    "https://ghproxy.bobvane.top/https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/docker-compose.yml" \
    "https://cdn.jsdelivr.net/gh/bobvane/VPS-Tailscale-DERP-AutoSetup@main/docker-compose.yml" \
    "${GITHUB_RAW}/docker-compose.yml"; do
    if curl -fsSL --max-time 15 "${u}" -o "${COMPOSE_FILE}" 2>/dev/null && [ -s "${COMPOSE_FILE}" ]; then
      compose_ok=1
      break
    fi
  done
  if [ "${compose_ok}" != "1" ]; then
    _error "下载 compose 模板失败（多源均不可达）"
    _warn "$(msg rollback_cleanup)"
    rm -rf "${INSTALL_DIR}"
    return 1
  fi
  _ok "$(msg compose_downloaded)"

  # 如果开启了防白嫖，取消注释 tailscale socket 挂载
  if [ "${VERIFY_CLIENTS:-}" = "true" ]; then
    # 注意：只去掉 "# " 前缀，保留原有 6 空格缩进（与 ./data/certs 对齐）
    sed -i 's|^\(\s*\)# - /var/run/tailscale/tailscaled.sock|\1- /var/run/tailscale/tailscaled.sock|' "${COMPOSE_FILE}"
    _info "$(msg verify_socket)"
  fi

  # 镜像加速选择（无论中英文都弹出，中国用户必需）
  step_mirror_select
  DERP_IMAGE="${MIRROR_PREFIX}/bobvane/vps-tailscale-derp-autosetup/derper:latest"
  env_set "DERP_IMAGE" "${DERP_IMAGE}"

  # 拉取镜像（B8）
  _step 8 11 "$(t step_install_8 "${DERP_IMAGE}")"
  if ! docker pull "${DERP_IMAGE}"; then
    _error "$(msg image_pull_failed)"
    echo "$(msg image_tip)"
    echo "$(msg image_tip1 "${DERP_IMAGE}")"
    echo "$(msg image_tip2)"
    echo "$(msg image_tip3)"
    _warn "$(msg rollback_cleanup)"
    rm -rf "${INSTALL_DIR}"
    return 1
  fi
  _ok "$(msg image_pulled)"

  # 启动容器（B9）
  _step 9 11 "$(t step_install_9)"
  local COMPOSE_CMD
  COMPOSE_CMD="$(docker_compose_cmd)"
  if [ -z "${COMPOSE_CMD}" ]; then
    _error "$(msg compose_missing_error)"
    return 1
  fi
  cd "${INSTALL_DIR}"
  sync_compose_env
  # 启动前预校验 compose YAML（避免启动失败后才回滚，v3.0.4 教训：缩进错误导致启动失败）
  if ! ${COMPOSE_CMD} config >/dev/null 2>&1; then
    _error "$(msg compose_config_failed)"
    echo "$(msg image_tip)"
    echo "$(msg compose_config_tip1 "${INSTALL_DIR}")"
    echo "$(msg compose_config_tip2 "${COMPOSE_CMD}")"
    echo "$(msg compose_config_tip3)"
    _warn "$(msg config_retained "${INSTALL_DIR}")"
    return 1
  fi
  if ! ${COMPOSE_CMD} up -d --remove-orphans; then
    _error "$(msg compose_start_failed)"
    _warn "$(msg compose_rollback "${INSTALL_DIR}")"
    ${COMPOSE_CMD} down 2>/dev/null || true
    echo "$(msg image_tip)"
    echo "$(msg compose_start_tip1)"
    echo "$(msg compose_start_tip2 "${INSTALL_DIR}")"
    echo "$(msg compose_config_tip3)"
    return 1
  fi

  # 等待容器启动
  _step 10 11 "$(t step_install_10)"
  sleep 5
  local status
  status="$(container_status)"
  if [ "${status}" = "running" ]; then
    _ok "$(msg container_running)"
  else
    _warn "$(msg container_status "${status}")"
    ${COMPOSE_CMD} logs --tail 20 derper 2>/dev/null || true
  fi

  # ---------- 如果开启了 verify-clients，自动登录 tailscale ----------
  if [ "${VERIFY_CLIENTS}" = "true" ]; then
    echo ""
    echo "----------------------------------------------"
    echo "$(msg auth_title)"
    echo "----------------------------------------------"
    if command -v tailscale >/dev/null 2>&1; then
      _info "$(msg auth_run)"
      echo "$(msg auth_link)"
      echo ""
      tailscale up 2>&1 || true
      echo ""
    else
      _warn "$(msg tailscale_not_found)"
    fi
    echo ""
    read -r -p "$(msg logged_in_prompt)"
    read -r -p "  tailscale 已登录？（回车继续）..."
  fi

  # 注册 tderp 命令
  _step 11 11 "$(t step_install_11)"
  # bash <(curl ...) 时 $0 是 pipe，cp 会失败，需 fallback 到 GitHub 下载
  if [ ! -f "${INSTALL_DIR}/install.sh" ]; then
      _info "$(msg register_script)"
      # 尝试国内加速，失败用官方 raw
      curl -sSL -o "${INSTALL_DIR}/install.sh" \
        "https://ghproxy.bobvane.top/https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh" 2>/dev/null || \
      curl -sSL -o "${INSTALL_DIR}/install.sh" \
        "https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh" 2>/dev/null || {
        _warn "$(msg register_failed "${INSTALL_DIR}")"
      }
    fi
    chmod +x "${INSTALL_DIR}/install.sh" 2>/dev/null || true
    ln -sf "${INSTALL_DIR}/install.sh" "${BIN_LINK}" 2>/dev/null || true
    _ok "$(msg registered "${BIN_LINK}")"

    echo ""
    echo "══════════════════════════════════════"
    echo "$(msg install_complete)"
    echo "══════════════════════════════════════"
    echo ""
    echo "$(msg summary_derp "${DERP_DOMAIN}" "${DERP_PORT}")"
    echo "$(msg summary_stun "${STUN_PORT}")"
    echo "$(msg summary_cert "${CERT_MODE}")"
    echo "$(msg summary_command)"
    echo ""
    echo "$(msg next_steps)"
    echo "$(msg next_acl)"
    echo "$(msg next_derpmap)"
    echo "$(msg next_restart)"
    echo ""
    read -r -p "$(msg press_return_continue)"
  }

# ============================================================
# 状态检测显示
# ============================================================
show_status_line() {
  local status status_text
  status="$(container_status)"
  case "$status" in
    running) status_text="🟢 $(t status_running)" ;;
    stopped) status_text="🟡 $(t status_stopped)" ;;
    *)       status_text="🔴 $(t status_unknown)" ;;
  esac

  local domain port
  domain="$(env_get DERP_DOMAIN)"
  port="$(env_get DERP_PORT)"

  if [ -n "$domain" ] && [ -n "$port" ]; then
    local cert_mode
    cert_mode="$(env_get CERT_MODE)"
    if [ "${cert_mode}" = "letsencrypt" ]; then
      echo "  状态: ${status_text}  |  域名/IP: ${domain}:${port}  |  $(t cert_le)"
    else
      local cert
      cert="$(cert_days_left "$domain")"
      if [ -n "$cert" ]; then
        if cert_is_cf "$domain"; then
          echo "  状态: ${status_text}  |  域名/IP: ${domain}:${port}  |  $(t cert_cf)（$(t cert_days "$cert")）"
        else
          echo "  状态: ${status_text}  |  域名/IP: ${domain}:${port}  |  $(t cert_days "$cert")"
        fi
      else
        echo "  状态: ${status_text}  |  域名/IP: ${domain}:${port}"
      fi
    fi
  else
    echo "  状态: ${status_text}  |  未安装"
  fi
}

# ============================================================
# 主菜单
# ============================================================
show_menu() {
  clear 2>/dev/null || true
  echo ""
  echo "╔═══════════════════════════════════════════╗"
  echo "║        $(t menu_title)              ║"
  echo "║             $(t menu_version)                   ║"
  echo "╚═══════════════════════════════════════════╝"
  echo ""
  show_status_line
  echo ""
  echo "─────────────────────────────────────────────"
  echo ""
  echo "  $(t opt_lang)"
  echo "  $(t opt_install)"
  echo "  $(t opt_logs)"
  echo "  $(t opt_restart)"
  echo "  $(t opt_stop)"
  echo "  $(t opt_update)"
  echo "  $(t opt_acl)"
  echo "  $(t opt_uninstall)"
  echo "  $(t opt_bbr)"
  echo "  $(t opt_dns)"
  echo "  $(t opt_updatescript)"
  echo "  $(t opt_exit)"
  echo ""
}

# ============================================================
# 菜单操作 1: 中英文切换（需求 02/10）
# ============================================================
menu_lang() {
  if [ "${LANG}" = "${LANG_ZH}" ]; then
    LANG="${LANG_EN}"
    _info "Language switched to English"
  else
    LANG="${LANG_ZH}"
    _info "已切换到中文"
  fi
  if is_installed; then
    env_set "LANG" "${LANG}"
  fi
  sleep 1
}

# ============================================================
# 菜单操作 2: 安装
# ============================================================
menu_install() {
  install_derp
}

# ============================================================
# 菜单操作 3: 查看实时日志（G6）
# ============================================================
menu_logs() {
  local status
  status="$(container_status)"
  if [ "$status" != "running" ]; then
    _warn "DERP 容器未运行，无法查看日志"
    read -r -p "按回车返回..."
    return 0
  fi
  echo ""
  echo "  实时日志（Ctrl+C 返回菜单）..."
  echo "------------------------------------------"
  cd "${INSTALL_DIR}" 2>/dev/null || true
  docker logs -f --tail 50 derper 2>&1 || true
  echo ""
  read -r -p "按回车返回菜单..."
}

# ============================================================
# 菜单操作 4: 重启服务（需求 13: 仅重启 derper 容器）
# ============================================================
menu_restart() {
  local status
  status="$(container_status)"
  if [ "$status" != "running" ]; then
    _warn "DERP 容器未运行，无法重启"
    read -r -p "按回车返回..."
    return 0
  fi
  _info "重启 derper 容器..."
  cd "${INSTALL_DIR}" 2>/dev/null || true
  local COMPOSE_CMD
  COMPOSE_CMD="$(docker_compose_cmd)"
  if [ -n "${COMPOSE_CMD}" ]; then
    sync_compose_env
    ${COMPOSE_CMD} restart derper
  else
    docker restart derper
  fi
  sleep 3
  if [ "$(container_status)" = "running" ]; then
    _ok "DERP 重启成功"
  else
    _error "DERP 重启失败，请查看日志"
  fi
  read -r -p "按回车返回..."
}

# ============================================================
# 菜单操作 5: 停止服务（需求 13）
# ============================================================
menu_stop() {
  local status
  status="$(container_status)"
  if [ "$status" != "running" ]; then
    _warn "DERP 容器未运行"
    read -r -p "按回车返回..."
    return 0
  fi
  if ask_yes_no "确认停止 DERP 服务？" "n"; then
    cd "${INSTALL_DIR}" 2>/dev/null || true
    local COMPOSE_CMD
    COMPOSE_CMD="$(docker_compose_cmd)"
    if [ -n "${COMPOSE_CMD}" ]; then
      ${COMPOSE_CMD} stop derper
    else
      docker stop derper
    fi
    _ok "DERP 已停止"
  else
    _info "已取消"
  fi
  read -r -p "按回车返回..."
}

# ============================================================
# 菜单操作 6: 更新 derper（G3）
# ============================================================
menu_update() {
  _info "检查 derper 最新版本..."
  local latest
  latest=$(curl -sS --max-time 10 -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/tailscale/tailscale/releases/latest \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || echo "")
  if [ -z "${latest}" ]; then
    _error "获取最新版本失败，请检查网络"
    read -r -p "按回车返回..."
    return 1
  fi
  _info "最新版本: ${latest}"

  # 读取当前容器镜像版本
  local current
  current="$(docker inspect derper --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || echo "")"
  if [ -z "${current}" ]; then
    current="未知（容器未运行或镜像无版本标签）"
  fi
  _info "当前版本: ${current}"

  # 版本比较：相同则已是最新，无需升级
  if [ -n "${current}" ] && [ "${current}" = "${latest}" ]; then
    _ok "当前已是最新版本 ${current}，无需升级"
    read -r -p "按回车返回..."
    return 0
  fi

  if ! ask_yes_no "确认升级到 ${latest}？" "n"; then
    _info "已取消升级"
    read -r -p "按回车返回..."
    return 0
  fi

  # 拉新镜像
  local image
  image="$(env_get DERP_IMAGE)"
  image="${image:-${DERP_IMAGE_DEFAULT}}"
  _info "拉取新镜像: ${image}"
  if ! docker pull "${image}"; then
    _error "拉取镜像失败，版本未变"
    read -r -p "按回车返回..."
    return 1
  fi

  # 重建容器（不保留旧镜像）
  cd "${INSTALL_DIR}" 2>/dev/null || true
  local COMPOSE_CMD
  COMPOSE_CMD="$(docker_compose_cmd)"
  if [ -n "${COMPOSE_CMD}" ]; then
    sync_compose_env
    ${COMPOSE_CMD} up -d --force-recreate --remove-orphans
  else
    docker stop derper 2>/dev/null || true
    docker rm derper 2>/dev/null || true
    docker run -d --name derper --restart unless-stopped "${image}"
  fi

  sleep 3
  if [ "$(container_status)" = "running" ]; then
    _ok "DERP 升级完成"
  else
    _error "升级后容器未运行，请查看日志"
  fi
  read -r -p "按回车返回..."
}

# ============================================================
# 菜单操作 u: 更新 tderp 管理脚本（需求）
# ============================================================
menu_update_script() {
  _info "检测到当前 tderp v${VERSION}，检查最新版本..."
  mkdir -p "${INSTALL_DIR}"

  # 多源全部下载，取版本号最大的（D3: Bob 决策）
  local urls=(
    "https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh"
    "https://ghproxy.bobvane.top/https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh"
    "https://cdn.jsdelivr.net/gh/bobvane/VPS-Tailscale-DERP-AutoSetup@main/install.sh"
  )
  local candidates=()  # 格式: "版本号:文件路径"
  for url in "${urls[@]}"; do
    local tmpf="${INSTALL_DIR}/install.sh.tmp.${RANDOM}"
    _info "下载: ${url}"
    if curl -fsSL --connect-timeout 10 --max-time 30 -o "${tmpf}" "${url}" 2>/dev/null && [ -s "${tmpf}" ]; then
      # 语法校验
      if bash -n "${tmpf}" 2>/dev/null; then
        local ver
        ver="$(grep '^VERSION=' "${tmpf}" | head -1 | cut -d'=' -f2 | tr -d '"')"
        if [ -n "${ver}" ]; then
          candidates+=("${ver}:${tmpf}")
          _info "  → 版本 ${ver}，有效"
        else
          _warn "  → 下载成功但无法解析版本号，跳过"
          rm -f "${tmpf}"
        fi
      else
        _warn "  → 下载成功但语法错误，跳过"
        rm -f "${tmpf}"
      fi
    else
      _warn "  → 下载失败"
      rm -f "${tmpf}" 2>/dev/null || true
    fi
  done

  if [ ${#candidates[@]} -eq 0 ]; then
    _error "所有源下载失败或无有效文件，请检查网络后重试"
    read -r -p "按回车返回..."
    return 1
  fi

  # 取版本号最大的
  local best_ver="" best_file=""
  for entry in "${candidates[@]}"; do
    local ver="${entry%%:*}"
    local file="${entry#*:}"
    if [ -z "${best_ver}" ] || version_gt "${ver}" "${best_ver}"; then
      [ -n "${best_file}" ] && rm -f "${best_file}"
      best_ver="${ver}"
      best_file="${file}"
    else
      rm -f "${file}"
    fi
  done

  # 版本号门禁：只有大于当前版本才覆盖
  if version_gt "${best_ver}" "${VERSION}"; then
    _info "发现新版本 v${best_ver}，正在更新..."
    mv -f "${best_file}" "${INSTALL_DIR}/install.sh"
    chmod +x "${INSTALL_DIR}/install.sh"
    ln -sf "${INSTALL_DIR}/install.sh" "${BIN_LINK}"
    env_set "INSTALLED_VERSION" "${best_ver}"
    _ok "tderp 已更新：v${VERSION} → v${best_ver}"
    read -r -p "按回车重新加载菜单..."
    if [ -x "${BIN_LINK}" ]; then
      exec bash "${BIN_LINK}"
    fi
    _warn "请退出后重新输入 tderp 进入菜单（将显示新版本）"
  else
    _ok "当前已是最新版本 v${VERSION}，无需更新"
    rm -f "${best_file}"
    read -r -p "按回车返回..."
  fi
}

# ============================================================
# 菜单操作 7: 显示 ACL 配置（G8）
# ============================================================
menu_acl() {
  local domain port region_id public_ip stun_port
  domain="$(env_get DERP_DOMAIN)"
  port="$(env_get DERP_PORT)"
  public_ip="$(env_get PUBLIC_IP)"
  stun_port="$(env_get STUN_PORT)"
  stun_port="${stun_port:-3478}"
  region_id="$(gen_region_id)"

  if [ -z "$domain" ]; then
    _warn "未安装或配置缺失"
    read -r -p "按回车返回..."
    return 0
  fi

  # 判断证书模式，决定是否 InsecureForTests
  local cert_mode cert_cf insecure secure_line
  cert_mode="$(env_get CERT_MODE)"
  cert_cf="$(env_get CERT_CF)"
  if [ "${cert_mode}" = "manual" ] && [ "${cert_cf:-}" != "true" ]; then
    insecure='            "InsecureForTests": true'
    secure_line='服务器使用自签名证书，客户端需信任该证书（InsecureForTests: true）'
  elif [ "${cert_cf:-}" = "true" ]; then
    insecure='            "InsecureForTests": true'
    secure_line='服务器使用 Cloudflare Origin CA 证书（客户端需 InsecureForTests: true）'
  else
    insecure=''
    secure_line="服务器使用 Let's Encrypt 证书，无需 InsecureForTests"
  fi

  echo ""
   echo "═══════════════════════════════════════════════"
   echo "  Tailscale 完整 ACL 配置"
   echo "═══════════════════════════════════════════════"
   echo "  复制以下全部内容，整体替换 Tailscale 管理后台 →"
   echo "  Access Controls 里的整个配置："
   echo ""
   echo '{'
   echo '  "derpMap": {'
   echo '    "OmitDefaultRegions": false,'
   echo '    "Regions": {'
   echo "      \"${region_id}\": {"
   echo "        \"RegionID\":   ${region_id},"
   echo '        "RegionCode": "CN",'
   echo '        "RegionName": "DERP-CN",'
   echo '        "Nodes": ['
   echo '          {'
   echo '            "Name": "tderp1",'
   echo "            \"RegionID\": ${region_id},"
   echo "            \"HostName\": \"${domain}\","
   if [ -n "${public_ip}" ]; then
     echo "            \"IPv4\":     \"${public_ip}\","
   fi
   echo "            \"DERPPort\": ${port},"
   if [ -n "${insecure}" ]; then
     echo "            \"STUNPort\": ${stun_port},"
     echo "${insecure}"
   else
     echo "            \"STUNPort\": ${stun_port}"
   fi
   echo '          }'
   echo '        ]'
   echo '      }'
   echo '    }'
   echo '  },'
   echo ''
   echo '  "acls": ['
   echo '    {'
   echo '      "action": "accept",'
   echo '      "src":    ["*"],'
   echo '      "dst":    ["*:*"]'
   echo '    }'
   echo '  ],'
   echo ''
   echo '  "ssh": []'
   echo '}'
   echo ""
   echo "  ${secure_line}"
   echo "  提示：OmitDefaultRegions=false 保留 Tailscale 官方节点作兜底，你的节点优先使用"
   echo "═══════════════════════════════════════════════"
   echo ""
   read -r -p "按回车返回菜单..."
 }

# ============================================================
# 菜单操作 8: 完全卸载（需求 13: 干净清除）
# ============================================================
menu_uninstall() {
  echo ""
  echo "----------------------------------------------"
  echo "$(msg uninstall_title)"
  echo "$(msg uninstall_item1)"
  echo "$(msg uninstall_item2)"
  echo "$(msg uninstall_item3)"
  echo "$(msg uninstall_item4)"
  echo "$(msg uninstall_item5)"
  echo "----------------------------------------------"
  if ! ask_yes_no "$(msg prompt_confirm_uninstall)" "n"; then
    _info "$(msg info_cancelled)"
    return 0
  fi
  _info "$(msg info_stop_container)"
  cd "${INSTALL_DIR}" 2>/dev/null || true
  local COMPOSE_CMD
  COMPOSE_CMD="$(docker_compose_cmd)"
  if [ -n "${COMPOSE_CMD}" ]; then
    ${COMPOSE_CMD} down --remove-orphans 2>/dev/null || true
  else
    docker stop derper 2>/dev/null || true
    docker rm derper 2>/dev/null || true
  fi

  _info "$(msg info_remove_image)"
  local image
  image="$(env_get DERP_IMAGE)"
  image="${image:-${DERP_IMAGE_DEFAULT}}"
  docker rmi "${image}" 2>/dev/null || true

  _info "$(msg info_remove_dirs)"
  rm -rf "${INSTALL_DIR}"
  rm -f "${BIN_LINK}"

  # 清理 tailscale 登录状态（如果需要）
  if command -v tailscale >/dev/null 2>&1; then
    _info "$(msg info_cleanup_tailscale)"
    tailscale logout 2>/dev/null || true
    _ok "$(msg ok_tailscale_logged_out)"
  fi

  _ok "$(msg ok_uninstall_done)"
  read -r -p "$(msg prompt_return)"
}

# ============================================================

# ============================================================
# 菜单操作 d: DNS 修复（阿里云VPS）
# ============================================================
menu_dns() {
  _info "$(msg dns_checking)"
  echo ""

  local dns_ok=0
  if nslookup github.com >/dev/null 2>&1; then
    _ok "$(msg dns_ok)"
    dns_ok=1
  else
    _warn "$(msg dns_failed)"
  fi

  echo ""
  if [ "${dns_ok}" = "1" ]; then
    _ok "$(msg dns_healthy)"
    echo "$(msg current_dns)"
    cat /etc/resolv.conf 2>/dev/null | grep -v "^#" | grep -v "^$" | sed 's/^/    /'
    read -r -p "$(msg press_return)"
    return 0
  fi

  echo "----------------------------------------------"
  echo "$(msg dns_title)"
  echo "----------------------------------------------"
  echo "$(msg aliyun_dns_issue)"
  echo ""
  echo "$(msg fix_method)"
  echo "   - $(msg aliyun_dns)"
  echo "   - $(msg google_dns)"
  echo "----------------------------------------------"
  echo "  1. $(msg fix_auto)"
  echo "  2. $(msg fix_manual)"
  echo "  3. $(msg fix_skip)"
  echo "----------------------------------------------"
  local dns_choice
  while true; do
    read -r -p "$(msg fix_choice)" dns_choice
    [ -z "$dns_choice" ] && dns_choice=1
    case "$dns_choice" in
      1|2|3) break ;;
      *) _warn "$(msg input_invalid)" ;;
    esac
  done

  if [ "$dns_choice" = "1" ]; then
    _info "$(msg fixing_dns)"
    if systemctl is-active systemd-resolved >/dev/null 2>&1; then
      systemctl stop systemd-resolved 2>/dev/null || true
      systemctl disable systemd-resolved 2>/dev/null || true
    fi
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << 'EOF'
nameserver 223.5.5.5
nameserver 8.8.8.8
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    echo ""
    if nslookup github.com >/dev/null 2>&1; then
      _ok "$(msg dns_fixed)"
      echo "$(msg current_dns)"
      cat /etc/resolv.conf 2>/dev/null | grep -v "^#" | grep -v "^$" | sed 's/^/    /'
    else
      _warn "$(msg dns_unfixed)"
    fi
  elif [ "$dns_choice" = "2" ]; then
    _info "$(msg fix_manual_steps)"
    echo "  systemctl stop systemd-resolved"
    echo "  systemctl disable systemd-resolved"
    echo "  rm -f /etc/resolv.conf"
    echo "  echo 'nameserver 223.5.5.5' > /etc/resolv.conf"
    echo "  echo 'nameserver 8.8.8.8' >> /etc/resolv.conf"
    echo "  chattr +i /etc/resolv.conf"
  else
    _info "$(msg fix_skip_msg)"
  fi
  read -r -p "$(msg press_return)"
}

# ============================================================
# 菜单操作 9: 配置 BBR 加速
# ============================================================
menu_bbr() {
  _info "$(msg bbr_checking)"
  echo ""

  _info "$(msg kernel_version "$(uname -r)")"

  # 检查当前拥塞控制算法
  local current_cc
  if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
    current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
    echo "$(msg current_algorithm "${current_cc}")"
  fi

  # 如果已开启 BBR，直接显示状态
  if [ "${current_cc}" = "bbr" ]; then
    _ok "$(msg bbr_already)"
    _info "$(msg disable_bbr_hint)"
    echo "  sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d' /etc/sysctl.d/99-bbr.conf"
    echo "  sysctl -p /etc/sysctl.d/99-bbr.conf"
    echo "  sysctl -w net.ipv4.tcp_congestion_control=cubic"
    read -r -p "$(msg press_return)"
    return 0
  fi

  # 多重检测：modprobe + 可用算法列表 + 内核版本
  local bbr_available=0

  # 检测 1: 尝试加载 BBR 模块
  if modprobe tcp_bbr 2>/dev/null; then
    bbr_available=1
    _ok "$(msg module_load "tcp_bbr")"
  else
    echo "$(msg module_unavailable "tcp_bbr")"
  fi

  # 检测 2: 检查可用算法列表
  local avail_list
  avail_list=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
  if echo "${avail_list}" | grep -qi "bbr"; then
    bbr_available=1
    _ok "$(msg available_algorithms "${avail_list}")"
  fi

  # 检测 3: 检查内核版本（4.9+ 都支持 BBR）
  local kver
  kver=$(uname -r | cut -d'.' -f1-2)
  if [ "$(echo "${kver} >= 4.9" | bc 2>/dev/null)" = "1" ] 2>/dev/null ||      [ "$(printf '%s
' "4.9" "${kver}" | sort -V | head -1)" = "4.9" ]; then
    _ok "$(msg kernel_ok "$(uname -r)")"
  fi

  echo ""
  if [ "${bbr_available}" = "1" ]; then
    _ok "$(msg bbr_supported)"
    if ask_yes_no "$(msg enable_bbr_prompt)" "y"; then
      _info "$(msg enabling_bbr)"
      local sysctl_conf="/etc/sysctl.d/99-bbr.conf"
      mkdir -p /etc/sysctl.d
      cat > "${sysctl_conf}" << EOF
# BBR TCP congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
      sysctl -p "${sysctl_conf}" >/dev/null 2>&1
      sleep 1
      local new_cc
      new_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
      if [ "${new_cc}" = "bbr" ]; then
        _ok "$(msg bbr_enabled "${new_cc}")"
      else
        _warn "$(msg bbr_failed "${new_cc}")"
      fi
    else
      _info "$(msg bbr_skipped)"
    fi
  else
    _warn "$(msg bbr_not_supported)"
    echo ""
    echo "----------------------------------------------"
    echo "$(msg kernel_unsupported)"
    echo "----------------------------------------------"
    echo "  1. $(msg install_kernel)"
    echo "  2. $(msg skip_kernel)"
    echo "----------------------------------------------"
    local kernel_choice
    while true; do
      read -r -p "$(msg kernel_source_choice)" kernel_choice
      [ -z "$kernel_choice" ] && kernel_choice=1
      case "$kernel_choice" in
        1|2) break ;;
        *) _warn "$(msg input_invalid)" ;;
      esac
    done

    if [ "$kernel_choice" = "1" ]; then
      _info "$(msg debian_installing)"
      echo ""
      echo "----------------------------------------------"
      echo "$(msg kernel_source)"
      echo "----------------------------------------------"
      echo "  1. $(msg kernel_source_cn)"
      echo "  2. $(msg kernel_source_intl)"
      echo "  3. $(msg kernel_source_manual)"
      echo "----------------------------------------------"
      local mirror_choice
      while true; do
        read -r -p "$(msg kernel_source_choice)" mirror_choice
        [ -z "$mirror_choice" ] && mirror_choice=1
        case "$mirror_choice" in
          1|2|3) break ;;
          *) _warn "$(msg input_invalid)" ;;
        esac
      done
      [ "$mirror_choice" = "3" ] && { _info "$(msg kernel_skipped_msg)"; read -r -p "$(msg press_return)"; return 0; }

      if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID}" in
          ubuntu|debian)
            _info "$(msg debian_installing)"
            if [ "$mirror_choice" = "1" ] && [ -n "${MIRROR_PREFIX}" ]; then
              # 国内：使用已配置的镜像源（阿里云 ECS 的 apt 源已自动镜像）
              _info "$(msg debian_mirror)"
            fi
            apt-get update -qq
            apt-get install -y -qq linux-image-amd64 2>/dev/null || \
            apt-get install -y -qq linux-image-generic 2>/dev/null || \
            _warn "$(msg debian_failed)"
            ;;
          centos|rhel|fedora|almalinux|rocky)
            _info "$(msg rhel_installing)"
            if [ "$mirror_choice" = "1" ]; then
              # 国内：使用阿里云 elrepo 镜像
              _info "$(msg rhel_mirror)"
              rpm --import https://mirrors.aliyun.com/elrepo/RPM-GPG-KEY-elrepo.org 2>/dev/null || true
              if [ "${VERSION_ID}" = "7" ]; then
                rpm -Uvh https://mirrors.aliyun.com/elrepo/elrepo-release/7.el7.elrepo.noarch.rpm 2>/dev/null || true
              elif [ "${VERSION_ID}" = "8" ]; then
                rpm -Uvh https://mirrors.aliyun.com/elrepo/elrepo-release/8.el8.elrepo.noarch.rpm 2>/dev/null || true
              elif [ "${VERSION_ID%%.*}" = "9" ]; then
                rpm -Uvh https://mirrors.aliyun.com/elrepo/elrepo-release/9.el9.elrepo.noarch.rpm 2>/dev/null || true
              fi
              yum install -y kernel-ml 2>/dev/null || _warn "$(msg rhel_failed)"
            fi
            ;;
          *)
            _warn "$(msg unknown_system "${ID}")"
            ;;
        esac
        [ "$mirror_choice" = "1" ] && { _info "$(msg kernel_done)"; echo "$(msg reboot_hint)"; read -r -p "$(msg press_return)"; return 0; }
        [ "$mirror_choice" = "2" ] && { _info "$(msg kernel_skipped_msg)"; read -r -p "$(msg press_return)"; return 0; }
      fi
      fi
      fi
      read -r -p "$(msg press_return)"
    }

# 主入口
# ============================================================
main() {
  check_root

  # 确保 tderp 命令可用——bash <(curl ...) 一次就注册
  # 不管是否已安装，只要 tderp 链接不存在就尝试创建
  if [ ! -L "${BIN_LINK}" ]; then
    mkdir -p "${INSTALL_DIR}" 2>/dev/null || true
    # 删除旧脚本，确保下载最新版
    rm -f "${INSTALL_DIR}/install.sh"
    echo "→ 首次运行，下载安装脚本到本地..."
    local urls=(
      "https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh"
      "https://ghproxy.bobvane.top/https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/install.sh"
      "https://cdn.jsdelivr.net/gh/bobvane/VPS-Tailscale-DERP-AutoSetup@main/install.sh"
    )
    # 多源全部下载，取版本号最大的（与 menu_update_script 一致）
    local best_ver=""
    for url in "${urls[@]}"; do
      local tmpf="${INSTALL_DIR}/install.sh.tmp.${RANDOM}"
      echo "  尝试: ${url}"
      if curl -sSL --max-time 20 -o "${tmpf}" "${url}" 2>/dev/null && [ -s "${tmpf}" ] && bash -n "${tmpf}" 2>/dev/null; then
        local ver
        ver="$(grep '^VERSION=' "${tmpf}" | head -1 | cut -d'=' -f2 | tr -d '"')"
        if [ -n "${ver}" ] && { [ -z "${best_ver}" ] || version_gt "${ver}" "${best_ver}"; }; then
          rm -f "${INSTALL_DIR}/install.sh"
          mv -f "${tmpf}" "${INSTALL_DIR}/install.sh"
          best_ver="${ver}"
        else
          rm -f "${tmpf}"
        fi
      else
        rm -f "${tmpf}" 2>/dev/null || true
      fi
    done
    if [ -f "${INSTALL_DIR}/install.sh" ]; then
      chmod +x "${INSTALL_DIR}/install.sh"
      ln -sf "${INSTALL_DIR}/install.sh" "${BIN_LINK}"
      echo "✅ tderp 命令已注册，输入 tderp 即可管理"
    else
      echo "⚠️  下载失败，请检查网络后重试"
    fi
  fi

  # 读取已安装的语言设置
  if is_installed; then
    local saved_lang
    saved_lang="$(env_get LANG)"
    if [ -n "${saved_lang}" ]; then
      LANG="${saved_lang}"
    fi
  fi

  # 命令行参数快速操作（兼容 v1 风格）
  case "${1:-}" in
    status) show_status_line; exit 0 ;;
    logs)   menu_logs; exit 0 ;;
    restart) menu_restart; exit 0 ;;
    stop)   menu_stop; exit 0 ;;
    update) menu_update; exit 0 ;;
    acl)    menu_acl; exit 0 ;;
    bbr)    menu_bbr; exit 0 ;;
    dns)    menu_dns; exit 0 ;;
    uninstall) menu_uninstall; exit 0 ;;
    updatescript) menu_update_script; exit 0 ;;
    help|-h|--help)
      echo "用法: tderp [命令]"
      echo "  无参数    打开交互式管理菜单"
      echo "  status    查看服务状态"
      echo "  logs      查看实时日志"
      echo "  restart   重启 DERP 容器"
      echo "  stop      停止 DERP 服务"
      echo "  update    更新 derper 到最新版"
      echo "  acl       显示 ACL 配置"
      echo "  bbr       配置 BBR 加速"
      echo "  dns       修复 DNS（阿里云VPS）"
      echo "  updatescript 更新 tderp 管理脚本"
      echo "  uninstall 完全卸载"
      exit 0
      ;;
  esac

  # 交互菜单循环
  while true; do
    show_menu
    local choice
    read -r -p "$(t prompt_choice)" choice
    case "$choice" in
      1) menu_lang ;;
      2) menu_install ;;
      3) menu_logs ;;
      4) menu_restart ;;
      5) menu_stop ;;
      6) menu_update ;;
      7) menu_acl ;;
      8) menu_uninstall ;;
      9) menu_bbr ;;
      d|D) menu_dns ;;
      u|U) menu_update_script ;;
      0|q|Q) echo ""; echo "再见！"; exit 0 ;;
      *) _warn "无效选项，请输入 0-9 或 d/u" ; sleep 1 ;;
    esac
  done
}

# 启动（被 source 时不执行主流程，便于测试）
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${BASH_SOURCE[0]}" ]; then
  main "$@"
fi
