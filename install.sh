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
VERSION="2.0.0"
INSTALL_DIR="/opt/tderp"
ENV_FILE="${INSTALL_DIR}/tderp.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
BIN_LINK="/usr/local/bin/tderp"
DATA_DIR="${INSTALL_DIR}/data"
CERTS_DIR="${DATA_DIR}/certs"
COMPOSE_TEMPLATE_URL="https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/docker-compose.yml"

# 项目仓库（用于 fork 说明）
GITHUB_REPO="bobvane/VPS-Tailscale-DERP-AutoSetup"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/main"

# 默认镜像（脚本运行时检测 fork 情况）
DERP_IMAGE_DEFAULT="ghcr.io/${GITHUB_REPO}/derper:latest"

# 国内 ghcr.io 镜像加速地址（需求 10）
MIRROR_LIST=(
  "ghcr.io"                          # 1. 默认直连
  "ghcr.chenby.cn"                   # 2. 推荐加速（CF 边缘）
  "ghcr.milu.moe"                    # 3. 备用加速
)

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
C_BLUE="\033[34m"
C_CYAN="\033[36m"
C_BOLD="\033[1m"

# 非交互环境禁用颜色
if [ ! -t 1 ]; then
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""
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
      opt_lang) echo "1. Switch language (中文/English)" ;;
      opt_install) echo "2. Docker install" ;;
      opt_logs) echo "3. View live logs" ;;
      opt_restart) echo "4. Restart service" ;;
      opt_stop) echo "5. Stop service" ;;
      opt_update) echo "6. Update derper" ;;
      opt_acl) echo "7. Show ACL config" ;;
      opt_uninstall) echo "8. Uninstall (clean)" ;;
      opt_exit) echo "0. Exit" ;;
      prompt_choice) echo -n "Enter option [0-8]: " ;;
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
      opt_lang) echo "1. 中英文切换" ;;
      opt_install) echo "2. Docker 安装" ;;
      opt_logs) echo "3. 查看实时日志" ;;
      opt_restart) echo "4. 重启服务" ;;
      opt_stop) echo "5. 停止服务" ;;
      opt_update) echo "6. 更新 derper" ;;
      opt_acl) echo "7. 显示 ACL 配置" ;;
      opt_uninstall) echo "8. 完全卸载" ;;
      opt_exit) echo "0. 退出" ;;
      prompt_choice) echo -n "请输入选项 [0-8]: " ;;
      *) echo "$key" ;;
    esac
  fi
}

_info()  { echo -e "${C_GREEN}[信息]${C_RESET} $*"; }
_warn()  { echo -e "${C_YELLOW}[警告]${C_RESET} $*"; }
_error() { echo -e "${C_RED}[错误]${C_RESET} $*"; }
_ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
_step()  { echo -e "${C_CYAN}[${1}/${2}]${C_RESET} $3"; }

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
  [ -f "${ENV_FILE}" ] || [ -d "${INSTALL_DIR}" ]
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

ask_yes_no() {
  local prompt="$1" default="${2:-y}"
  local ans
  echo -n "${prompt} [Y/n] "
  read -r ans
  ans=$(echo "$ans" | tr '[:upper:]' '[:lower:]')
  if [ -z "$ans" ]; then ans="$default"; fi
  [ "$ans" = "y" ] || [ "$ans" = "yes" ]
}
# ============================================================
# 安装 Docker 引擎（G2: 区分国内外）
# ============================================================
install_docker_engine() {
  _info "检测到未安装 Docker，准备自动安装..."
  echo ""
  echo "----------------------------------------------"
  echo " Docker 引擎安装方式（按你的服务器所在地选择）"
  echo "----------------------------------------------"
  echo "  1. 国内服务器（使用清华镜像源，速度快）"
  echo "  2. 国外服务器（使用 Docker 官方脚本）"
  echo "  3. 手动安装（跳过，我自行安装）"
  echo "----------------------------------------------"
  local choice
  while true; do
    read -r -p "请选择 [1-3] (默认 2): " choice
    [ -z "$choice" ] && choice=2
    case "$choice" in
      1|2|3) break ;;
      *) _warn "输入无效，请输入 1、2 或 3" ;;
    esac
  done

  case "$choice" in
    1)
      _info "使用清华镜像源安装 Docker..."
      bash <(curl -sSL https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/install.sh) || {
        _error "清华镜像源安装失败，尝试官方脚本..."
        bash <(curl -sSL https://get.docker.com) || { _error "Docker 安装失败"; return 1; }
      }
      ;;
    2)
      _info "使用 Docker 官方脚本安装..."
      curl -fsSL https://get.docker.com | bash || { _error "Docker 安装失败"; return 1; }
      ;;
    3)
      _warn "跳过 Docker 安装。请手动安装后重新运行此脚本。"
      return 1
      ;;
  esac

  systemctl enable --now docker 2>/dev/null || true
  _info "验证 Docker..."
  if docker_installed; then
    _ok "Docker 安装成功: $(docker --version)"
    if [ -z "$(docker_compose_cmd)" ]; then
      _warn "未检测到 docker compose，尝试安装 compose 插件..."
      apt-get update -qq && apt-get install -y -qq docker-compose-plugin 2>/dev/null || \
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2 2>/dev/null || \
      _warn "compose 插件安装失败，请手动安装 docker-compose"
    fi
    return 0
  else
    _error "Docker 安装后仍无法使用，请手动排查"
    return 1
  fi
}

# ============================================================
# DNS 解析检测（B0）— 检测镜像源能否解析
# ============================================================
step_dns_check() {
  local mirror_host="$1"
  _step 1 11 "DNS 解析检测：${mirror_host}"
  if dns_check "${mirror_host}"; then
    _ok "DNS 解析正常"
    return 0
  else
    _error "无法解析 ${mirror_host}，可能是 DNS 被锁定或网络问题"
    echo ""
    echo "  【解决方案】"
    echo "  1. 检查 /etc/resolv.conf 中的 DNS 是否正常"
    echo "  2. 可尝试修改为公共 DNS："
    echo "     echo 'nameserver 223.5.5.5' > /etc/resolv.conf  # 阿里 DNS"
    echo "     echo 'nameserver 114.114.114.114' >> /etc/resolv.conf"
    echo "  3. 修改后重新运行脚本"
    echo ""
    return 1
  fi
}

# ============================================================
# 端口占用检测（B0b）
# ============================================================
step_port_check() {
  local dport="$1" sport="$2"
  _step 2 11 "端口占用检测：TCP ${dport} / UDP ${sport}"
  local ok=true
  if port_in_use "${dport}"; then
    _error "端口 ${dport}(TCP) 已被占用，请更换 DERP 端口或先释放该端口"
    ok=false
  fi
  if port_in_use "${sport}"; then
    _error "端口 ${sport}(UDP) 已被占用，请更换 STUN 端口或先释放该端口"
    ok=false
  fi
  if [ "$ok" = "false" ]; then
    echo ""
    echo "  【解决方案】"
    echo "  1. 查看占用进程: ss -tulnp | grep -E '${dport}|${sport}'"
    echo "  2. 更换端口后重新安装"
    echo ""
    return 1
  fi
  _ok "端口均空闲"
  return 0
}

# ============================================================
# 镜像加速地址选择（需求 10）— 仅中文模式
# ============================================================
step_mirror_select() {
  echo ""
  echo "----------------------------------------------"
  echo " 选择镜像拉取地址（ghcr.io 国内加速）"
  echo "----------------------------------------------"
  echo "  1. 默认直连  ghcr.io              （国外 VPS 推荐）"
  echo "  2. 推荐加速  ghcr.chenby.cn       （国内 VPS 推荐）"
  echo "  3. 备用加速  ghcr.milu.moe        （国内 VPS 备选）"
  echo "  4. 自定义地址（输入你的加速站）"
  echo "----------------------------------------------"
  local choice
  while true; do
    read -r -p "请选择 [1-4] (默认 2): " choice
    [ -z "$choice" ] && choice=2
    case "$choice" in
      1) MIRROR_PREFIX="ghcr.io"; break ;;
      2) MIRROR_PREFIX="ghcr.chenby.cn"; break ;;
      3) MIRROR_PREFIX="ghcr.milu.moe"; break ;;
      4)
        read -r -p "请输入自定义镜像地址（如 my.mirror.com）: " custom
        if [ -n "$custom" ]; then
          MIRROR_PREFIX="${custom}"
          break
        else
          _warn "输入不能为空"
        fi
        ;;
      *) _warn "输入无效" ;;
    esac
  done
  _ok "镜像前缀: ${MIRROR_PREFIX}"
  if ! dns_check "${MIRROR_PREFIX}"; then
    _warn "注意：无法解析 ${MIRROR_PREFIX}，请检查网络或后续拉取可能失败"
  fi
}

# ============================================================
# 证书方案选择（需求 11）
# ============================================================
step_cert_select() {
  echo ""
  echo "----------------------------------------------"
  echo " 证书方式选择（三选一）"
  echo "----------------------------------------------"
  echo "  1. Let's Encrypt 自动证书（域名）"
  echo "     - 需域名已解析到本机（DNS A 记录指向本机 IP）"
  echo "     - 自动申请 + 自动续期，可开启防白嫖"
  echo "     - ★ 本机需开放 80 端口（HTTP-01 验证）"
  echo ""
  echo "  2. Let's Encrypt 自动证书（纯 IP）"
  echo "     - 无需域名，直接为公网 IP 申请证书"
  echo "     - 自动申请 + 自动续期"
  echo "     - ★ 本机需开放 80 端口（HTTP-01 验证）"
  echo ""
  echo "  3. 自签名证书（默认）"
  echo "     - 无需域名、无需开放 80 端口"
  echo "     - 证书自动生成，有效期 10 年"
  echo "     - 客户端需在 ACL 中加 InsecureForTests: true"
  echo "----------------------------------------------"
  local choice
  while true; do
    read -r -p "请选择 [1-3] (默认 3): " choice
    [ -z "$choice" ] && choice=3
    case "$choice" in
      1|2|3) break ;;
      *) _warn "输入无效，请输入 1、2 或 3" ;;
    esac
  done

  case "$choice" in
    1)
      CERT_MODE="letsencrypt"
      HTTP_PORT="80"
      CERT_LE_DOMAIN="true"
      CERT_LE_IP=""
      _info "已选 LE 自动证书（域名模式）"
      ;;
    2)
      CERT_MODE="letsencrypt"
      HTTP_PORT="80"
      CERT_LE_DOMAIN=""
      CERT_LE_IP="true"
      _info "已选 LE 自动证书（纯 IP 模式）"
      ;;
    3)
      CERT_MODE="manual"
      HTTP_PORT="-1"
      CERT_LE_DOMAIN=""
      CERT_LE_IP=""
      _info "已选自签名证书模式"
      ;;
  esac

  echo ""
  echo "──────────────────────────────────────────────"
  if [ "${CERT_MODE}" = "letsencrypt" ] && [ "${CERT_LE_DOMAIN:-}" = "true" ]; then
    echo "  【Let's Encrypt 自动证书 — 配置说明】"
    echo ""
    echo "  1. 请确保域名已解析到本机 IP（以 Cloudflare 为例）："
    echo "     DNS → 添加记录 → A 记录"
    echo "     名称: 你的域名（如 derp.example.com）"
    echo "     内容: ${PUBLIC_IP:-你的VPS公网IP}"
    echo "     代理状态: 关闭（灰色云朵）← 必须！DERP 需要直连"
    echo ""
    echo "  2. 请确保 VPS 防火墙/安全组已开放 80 端口（TCP）"
    echo "     ← LE 证书申请时需要 HTTP-01 验证"
    echo ""
    echo "  3. 证书自动申请和续期，无需额外操作"
    echo ""
    echo "  ★ 此模式支持开启防白嫖（verify-clients）"
  elif [ "${CERT_MODE}" = "letsencrypt" ] && [ "${CERT_LE_IP:-}" = "true" ]; then
    echo "  【Let's Encrypt 自动证书（纯 IP）— 配置说明】"
    echo ""
    echo "  1. 无需域名，公网 IP 即可自动申请证书"
    echo "     （LE 的 ACME IP 证书功能，derper 原生支持）"
    echo ""
    echo "  2. 请确保 VPS 防火墙/安全组已开放 80 端口（TCP）"
    echo ""
    echo "  3. 注意：此模式下客户端需信任该证书"
  else
    echo "  【自签名证书 — 说明】"
    echo ""
    echo "  1. 无需域名、无需开放 80 端口"
    echo "  2. 证书在首次启动时自动生成，有效期 10 年"
    echo "  3. 客户端 ACL 中节点需加 InsecureForTests: true"
    echo "  4. 此模式无法开启防白嫖（verify-clients 需要域名模式）"
  fi
  echo "──────────────────────────────────────────────"
  echo ""
  read -r -p "按回车继续..."
}

# ============================================================
# verify-clients 防白嫖询问（G1）
# ============================================================
step_verify_clients() {
  VERIFY_CLIENTS="false"
  if [ "${CERT_MODE}" != "letsencrypt" ] || [ "${CERT_LE_DOMAIN:-}" != "true" ]; then
    return 0
  fi
  echo ""
  echo "----------------------------------------------"
  echo " 防白嫖（verify-clients）"
  echo "----------------------------------------------"
  echo " 开启后，只有你 tailnet 内的设备才能使用此 DERP 中继"
  echo " 需要 VPS 上安装 tailscale 客户端并登录到你的 tailnet"
  echo " 默认不开启；如果你只自己用，可不开启"
  echo "----------------------------------------------"
  if ask_yes_no "是否开启防白嫖（verify-clients）？" "n"; then
    VERIFY_CLIENTS="true"
    _info "已开启防白嫖。检测 tailscale 客户端..."
    if ! command -v tailscale >/dev/null 2>&1; then
      _warn "未检测到 tailscale 客户端，将自动安装..."
      install_tailscale_client || {
        _warn "tailscale 自动安装失败，请手动安装后重试"
        VERIFY_CLIENTS="false"
      }
    fi
    if [ "${VERIFY_CLIENTS}" = "true" ]; then
      echo ""
      echo "  请确认 tailscale 已登录到你的 tailnet："
      tailscale status 2>/dev/null | head -3 || true
      echo ""
      read -r -p "  tailscale 已登录？（回车继续）..."
    fi
  fi
}

# ============================================================
# 安装 tailscale 客户端（G1 辅助）
# ============================================================
install_tailscale_client() {
  _info "安装 tailscale 客户端..."
  if curl -fsSL https://tailscale.com/install.sh | bash; then
    _ok "tailscale 安装完成"
    echo "  请执行以下命令登录到你的 tailnet："
    echo "    tailscale up"
    echo "  根据提示在浏览器中登录授权"
    return 0
  else
    _error "tailscale 自动安装失败"
    return 1
  fi
}

# ============================================================
# 安装主流程（12 步）
# ============================================================
install_derp() {
  _info "开始安装 Tailscale DERP（Docker 版）"
  echo ""

  if is_installed; then
    _warn "检测到已安装 tderp（${INSTALL_DIR} 已存在）"
    if ! ask_yes_no "是否重新安装（覆盖现有配置）？" "n"; then
      _info "已取消安装"
      return 0
    fi
    _info "清理旧配置..."
    rm -rf "${INSTALL_DIR}"
  fi

  # ---------- B0: DNS 解析检测 ----------
  MIRROR_PREFIX="ghcr.io"
  if [ "${LANG}" = "${LANG_ZH}" ]; then
    step_mirror_select
  fi
  DERP_IMAGE="${MIRROR_PREFIX}/bobvane/VPS-Tailscale-DERP-AutoSetup/derper:latest"
  if ! dns_check "${MIRROR_PREFIX}"; then
    _error "无法解析镜像源 ${MIRROR_PREFIX}"
    echo "请检查网络或修改 DNS 后重试"
    return 1
  fi

  # ---------- B1: Docker 检测 ----------
  _step 3 11 "检测 Docker"
  if ! docker_installed; then
    _warn "未安装 Docker"
    if ! ask_yes_no "是否自动安装 Docker？" "y"; then
      _info "已取消，请手动安装 Docker 后重试"
      return 1
    fi
    install_docker_engine || return 1
  else
    _ok "Docker 已安装: $(docker --version)"
  fi

  # ---------- B3: 输入域名 ----------
  echo ""
  echo "----------------------------------------------"
  echo " 配置 DERP 域名/IP"
  echo "----------------------------------------------"
  if [ "${CERT_MODE:-}" = "letsencrypt" ] && [ "${CERT_LE_IP:-}" = "true" ]; then
    _info "纯 IP 模式：自动获取公网 IP..."
    PUBLIC_IP="$(get_public_ip)"
    if [ -n "${PUBLIC_IP}" ]; then
      _ok "检测到公网 IP: ${PUBLIC_IP}"
      if ask_yes_no "使用此 IP 作为 DERP 地址？" "y"; then
        DERP_DOMAIN="${PUBLIC_IP}"
      else
        while true; do
          read -r -p "请输入公网 IP: " DERP_DOMAIN
          if validate_ip "${DERP_DOMAIN}"; then break; else _warn "IP 格式不正确"; fi
        done
      fi
    else
      _warn "自动获取公网 IP 失败，请手动输入"
      while true; do
        read -r -p "请输入公网 IP: " DERP_DOMAIN
        if validate_ip "${DERP_DOMAIN}"; then break; else _warn "IP 格式不正确"; fi
      done
    fi
  else
    _info "请输入域名（或公网 IP）"
    _info "域名示例: derp.example.com（需已解析到本机，CF 关闭代理/灰色云朵）"
    _info "IP 示例:   1.2.3.4"
    while true; do
      read -r -p "域名/IP: " DERP_DOMAIN
      if validate_domain "${DERP_DOMAIN}" || validate_ip "${DERP_DOMAIN}"; then
        break
      else
        _warn "格式不正确，请输入有效域名或 IP"
      fi
    done
    if validate_domain "${DERP_DOMAIN}"; then
      PUBLIC_IP="$(get_public_ip)" || true
    fi
  fi
  _ok "DERP 地址: ${DERP_DOMAIN}"

  # ---------- B5: DERP 端口 ----------
  echo ""
  echo "----------------------------------------------"
  echo " 配置端口"
  echo "----------------------------------------------"
  read -r -p "DERP 端口 (TCP, 默认 12345, 建议高位端口): " DERP_PORT
  DERP_PORT="${DERP_PORT:-12345}"
  while ! validate_port "${DERP_PORT}"; do
    _warn "端口格式不正确（1-65535）"
    read -r -p "DERP 端口 (TCP, 默认 12345): " DERP_PORT
    DERP_PORT="${DERP_PORT:-12345}"
  done

  # ---------- B6: STUN 端口 ----------
  read -r -p "STUN 端口 (UDP, 默认 3478): " STUN_PORT
  STUN_PORT="${STUN_PORT:-3478}"
  while ! validate_port "${STUN_PORT}"; do
    _warn "端口格式不正确（1-65535）"
    read -r -p "STUN 端口 (UDP, 默认 3478): " STUN_PORT
    STUN_PORT="${STUN_PORT:-3478}"
  done

  # ---------- 端口占用检测（B0b）----------
  _step 4 11 "端口占用检测"
  if ! step_port_check "${DERP_PORT}" "${STUN_PORT}"; then
    return 1
  fi

  # ---------- B7: 证书方案 ----------
  _step 5 11 "选择证书方案"
  step_cert_select

  # ---------- G1: verify-clients ----------
  step_verify_clients

  # ---------- 端口放行指引 ----------
  echo ""
  echo "----------------------------------------------"
  echo " 防火墙/安全组放行提醒"
  echo "----------------------------------------------"
  echo " 请在 VPS 服务商（阿里云/腾讯云等）安全组中放行："
  echo "   - TCP  ${DERP_PORT}  (DERP 中继)"
  echo "   - UDP  ${STUN_PORT}  (STUN)"
  if [ "${HTTP_PORT}" = "80" ]; then
    echo "   - TCP  80  (Let's Encrypt 证书验证)"
  fi
  echo "----------------------------------------------"
  read -r -p "已确认放行？按回车继续..."

  # ---------- B8: 生成 compose + 启动 ----------
  _step 6 11 "创建配置目录"
  mkdir -p "${INSTALL_DIR}" "${CERTS_DIR}"
  _ok "目录已创建: ${INSTALL_DIR}"

  env_set "LANG" "${LANG}"
  env_set "DERP_IMAGE" "${DERP_IMAGE}"
  env_set "DERP_DOMAIN" "${DERP_DOMAIN}"
  env_set "DERP_PORT" "${DERP_PORT}"
  env_set "STUN_PORT" "${STUN_PORT}"
  env_set "CERT_MODE" "${CERT_MODE}"
  env_set "HTTP_PORT" "${HTTP_PORT}"
  env_set "VERIFY_CLIENTS" "${VERIFY_CLIENTS}"
  env_set "PUBLIC_IP" "${PUBLIC_IP:-}"
  env_set "INSTALLED_VERSION" "${VERSION}"
  _ok "配置已写入 ${ENV_FILE}"

  # 下载 compose 模板
  _step 7 11 "获取 docker-compose 模板"
  if ! curl -fsSL "${GITHUB_RAW}/docker-compose.yml" -o "${COMPOSE_FILE}"; then
    _error "下载 compose 模板失败（${GITHUB_RAW}/docker-compose.yml）"
    _warn "回滚：清理配置目录"
    rm -rf "${INSTALL_DIR}"
    return 1
  fi
  _ok "compose 模板已获取"

  # 拉取镜像（B8）
  _step 8 11 "拉取 derper 镜像（${DERP_IMAGE}）"
  if ! docker pull "${DERP_IMAGE}"; then
    _error "拉取镜像失败"
    echo "  【排查建议】"
    echo "  1. 检查镜像源地址是否正确: ${DERP_IMAGE}"
    echo "  2. 若是国内网络，尝试用加速地址（重装时在镜像源步骤选择 2 或 3）"
    echo "  3. 检查 Docker 是否配置了 registry mirror"
    _warn "回滚：清理配置目录"
    rm -rf "${INSTALL_DIR}"
    return 1
  fi
  _ok "镜像拉取成功"

  # 启动容器（B9）
  _step 9 11 "启动 DERP 容器"
  local COMPOSE_CMD
  COMPOSE_CMD="$(docker_compose_cmd)"
  if [ -z "${COMPOSE_CMD}" ]; then
    _error "未找到 docker compose，请先安装"
    return 1
  fi
  cd "${INSTALL_DIR}"
  if ! ${COMPOSE_CMD} up -d --remove-orphans; then
    _error "Docker Compose 启动失败"
    _warn "回滚：停止并清理容器"
    ${COMPOSE_CMD} down 2>/dev/null || true
    rm -rf "${INSTALL_DIR}"
    return 1
  fi

  # 等待容器启动
  _step 10 11 "等待容器就绪"
  sleep 5
  local status
  status="$(container_status)"
  if [ "${status}" = "running" ]; then
    _ok "DERP 容器运行中"
  else
    _warn "容器状态: ${status}，查看日志:"
    ${COMPOSE_CMD} logs --tail 20 derper 2>/dev/null || true
  fi

  # 注册 tderp 命令
  _step 11 11 "注册 tderp 命令"
  cp "$0" "${INSTALL_DIR}/install.sh" 2>/dev/null || true
  chmod +x "${INSTALL_DIR}/install.sh" 2>/dev/null || true
  ln -sf "${INSTALL_DIR}/install.sh" "${BIN_LINK}" 2>/dev/null || true
  _ok "tderp 命令已注册（${BIN_LINK}）"

  echo ""
  echo "══════════════════════════════════════"
  echo "  ✅ 安装完成！"
  echo "══════════════════════════════════════"
  echo ""
  echo "  DERP 地址:   ${DERP_DOMAIN}:${DERP_PORT}"
  echo "  STUN 端口:   ${STUN_PORT} (UDP)"
  echo "  证书方式:    ${CERT_MODE}"
  echo "  管理命令:    tderp"
  echo ""
  echo "  接下来："
  echo "  1. 打开 Tailscale 管理后台 → Access Controls (ACL)"
  echo "  2. 在 derpMap.Regions 中添加以下配置（见菜单 7）"
  echo "  3. 重启你的 tailscale 客户端使配置生效"
  echo ""
  read -r -p "按回车返回菜单..."
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
    local cert
    cert="$(cert_days_left "$domain")"
    if [ -n "$cert" ]; then
      echo "  状态: ${status_text}  |  域名/IP: ${domain}:${port}  |  $(t cert_days "$cert")"
    else
      echo "  状态: ${status_text}  |  域名/IP: ${domain}:${port}"
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
  local cert_mode insecure secure_line
  cert_mode="$(env_get CERT_MODE)"
  if [ "${cert_mode}" = "manual" ]; then
    insecure='            "InsecureForTests": true'
    secure_line='服务器使用自签名证书，客户端需信任该证书（InsecureForTests: true）'
  else
    insecure=''
    secure_line="服务器使用 Let's Encrypt 证书，无需 InsecureForTests"
  fi

  echo ""
  echo "═══════════════════════════════════════════════"
  echo "  Tailscale ACL — derpMap 配置"
  echo "═══════════════════════════════════════════════"
  echo "  复制以下内容，粘贴到 Tailscale 管理后台 →"
  echo "  Access Controls 中的 derpMap.Regions 里："
  echo ""
  echo '{'
  echo '  "derpMap": {'
  echo '    "Regions": {'
  echo "      \"${region_id}\": {"
  echo "        \"RegionID\": ${region_id},"
  echo '        "RegionCode": "tderp",'
  echo '        "RegionName": "我的中继",'
  echo '        "Nodes": ['
  echo '          {'
  echo '            "Name": "tderp1",'
  echo "            \"RegionID\": ${region_id},"
  echo "            \"HostName\": \"${domain}\","
  if [ -n "${public_ip}" ]; then
    echo "            \"IPv4\": \"${public_ip}\","
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
  echo '  }'
  echo '}'
  echo ""
  echo "  ${secure_line}"
  echo ""
  echo "  将 RegionID ${region_id} 替换为你想要的 ID 即可（需与 ACL 中其他配置不冲突）"
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
  echo " 完全卸载将删除："
  echo "  - DERP 容器和镜像"
  echo "  - 全部配置（${INSTALL_DIR}）"
  echo "  - tderp 命令（${BIN_LINK}）"
  echo "  - 证书目录"
  echo "----------------------------------------------"
  if ! ask_yes_no "确认完全卸载？" "n"; then
    _info "已取消"
    return 0
  fi
  _info "停止并删除容器..."
  cd "${INSTALL_DIR}" 2>/dev/null || true
  local COMPOSE_CMD
  COMPOSE_CMD="$(docker_compose_cmd)"
  if [ -n "${COMPOSE_CMD}" ]; then
    ${COMPOSE_CMD} down --remove-orphans 2>/dev/null || true
  else
    docker stop derper 2>/dev/null || true
    docker rm derper 2>/dev/null || true
  fi

  _info "删除镜像..."
  local image
  image="$(env_get DERP_IMAGE)"
  image="${image:-${DERP_IMAGE_DEFAULT}}"
  docker rmi "${image}" 2>/dev/null || true

  _info "删除配置和数据目录..."
  rm -rf "${INSTALL_DIR}"
  rm -f "${BIN_LINK}"

  _ok "卸载完成，已干净清除"
  read -r -p "按回车返回..."
}

# ============================================================
# 主入口
# ============================================================
main() {
  check_root

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
    uninstall) menu_uninstall; exit 0 ;;
    help|-h|--help)
      echo "用法: tderp [命令]"
      echo "  无参数    打开交互式管理菜单"
      echo "  status    查看服务状态"
      echo "  logs      查看实时日志"
      echo "  restart   重启 DERP 容器"
      echo "  stop      停止 DERP 服务"
      echo "  update    更新 derper 到最新版"
      echo "  acl       显示 ACL 配置"
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
      0|q|Q) echo ""; echo "再见！"; exit 0 ;;
      *) _warn "无效选项，请输入 0-8" ; sleep 1 ;;
    esac
  done
}

# 启动（被 source 时不执行主流程，便于测试）
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${BASH_SOURCE[0]}" ]; then
  main "$@"
fi