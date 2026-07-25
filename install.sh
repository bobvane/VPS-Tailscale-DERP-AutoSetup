#!/usr/bin/bash
# ============================================================
#  tderp - Tailscale DERP 一键管理脚本
#  版本: 1.0.0
#  作者: bobvane
#  项目: https://github.com/bobvane/VPS-Tailscale-DERP-AutoSetup
#  说明: 在 Linux 服务器上一键部署 Tailscale DERP 中继节点
#        域名 + 高位端口 + 自签名证书 + systemd 管理
#  用法: bash <(curl -sL 你的域名/install.sh)
#  安装后: 输入 tderp 进入管理菜单
# ============================================================

set -euo pipefail

# ==================== 版本配置 ====================
TDERP_VERSION="1.0.0"
GO_VERSION="1.24.0"

# ==================== 路径配置 ====================
TDERP_DIR="/etc/tderp"
CERT_DIR="${TDERP_DIR}/certs"
DERP_BIN="/usr/local/bin/derper"
SERVICE_FILE="/etc/systemd/system/tderp.service"
TDERP_CMD="/usr/local/bin/tderp"
TDERP_ENV="${TDERP_DIR}/tderp.env"

# ==================== 颜色定义 ====================
# 参考 kejilion.sh 配色风格
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
PURPLE='\e[35m'
CYAN='\e[36m'
WHITE='\e[37m'
BOLD='\e[1m'
DIM='\e[2m'
RESET='\e[0m'

# ==================== 辅助函数 ====================

# 打印带颜色和前缀的消息
print_ok()   { echo -e " ${GREEN}✅${RESET} $1"; }
print_fail() { echo -e " ${RED}❌${RESET} $1"; }
print_info() { echo -e " ${BLUE}ℹ️${RESET} $1"; }
print_warn() { echo -e " ${YELLOW}⚠️${RESET} $1"; }
print_step() { echo -e " ${CYAN}▶${RESET} $1"; }

# 分隔线
print_line() {
  echo -e "${DIM}─────────────────────────────────────────────────────${RESET}"
}

# 打印大标题
print_banner() {
  echo -e "${CYAN}"
  echo '  ╔═══════════════════════════════════════════════╗'
  echo '  ║              Tailscale DERP 管理器              ║'
  echo '  ║               tderp v'${TDERP_VERSION}'                ║'
  echo '  ╚═══════════════════════════════════════════════╝'
  echo -e "${RESET}"
}

# 打印小标题
print_subtitle() {
  local title="$1"
  echo -e "${BOLD}${CYAN}── ${title} ──${RESET}"
}

# 检查 root 权限
check_root() {
  if [[ $EUID -ne 0 ]]; then
    print_fail "请以 root 权限运行此脚本"
    echo "  请执行: sudo bash $0"
    exit 1
  fi
}

# 检查系统架构
detect_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64)  echo "arm64" ;;
    *)
      print_fail "不支持的架构: $arch（仅支持 amd64/arm64）"
      exit 1
      ;;
  esac
}

# 检查操作系统
detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="$ID"
    OS_VERSION="$VERSION_ID"
  else
    OS_NAME="unknown"
    OS_VERSION="unknown"
  fi
  echo "$OS_NAME $OS_VERSION"
}

# 安装依赖包
install_packages() {
  local pkgs=("$@")
  local missing=()

  # 检查哪些包需要安装
  for pkg in "${pkgs[@]}"; do
    if ! command -v "$pkg" &>/dev/null && ! dpkg -s "$pkg" &>/dev/null 2>&1 && \
       ! rpm -q "$pkg" &>/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi

  print_info "正在安装依赖: ${missing[*]} ..."

  if [[ -f /etc/debian_version ]]; then
    apt-get update -qq && apt-get install -y -qq "${missing[@]}"
  elif [[ -f /etc/redhat-release ]]; then
    yum install -y -q "${missing[@]}"
  elif [[ -f /etc/alpine-release ]]; then
    apk add "${missing[@]}"
  else
    print_warn "未知系统，请手动安装: ${missing[*]}"
    return 1
  fi

  print_ok "依赖安装完成"
}

# 检测是否已安装 Go
check_go() {
  if command -v go &>/dev/null; then
    local current_ver
    current_ver=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+(\.[0-9]+)?' || echo "0")
    print_ok "检测到 Go ${current_ver}"
    return 0
  fi
  return 1
}

# 安装 Go
install_go() {
  local arch
  arch=$(detect_arch)
  local go_tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
  local go_url="https://golang.google.cn/dl/${go_tarball}"
  local go_url_fallback="https://go.dev/dl/${go_tarball}"

  print_step "下载 Go ${GO_VERSION}（${arch}）..."
  print_info "源: golang.google.cn（国内镜像）"

  # 尝试国内镜像，失败则走官方源
  if wget -q --timeout=30 -O "/tmp/${go_tarball}" "${go_url}"; then
    print_ok "Go 下载完成（国内镜像）"
  else
    print_warn "国内镜像下载失败，尝试官方源..."
    if wget -q --timeout=60 -O "/tmp/${go_tarball}" "${go_url_fallback}"; then
      print_ok "Go 下载完成（官方源）"
    else
      print_fail "Go 下载失败，请检查网络连接"
      exit 1
    fi
  fi

  print_step "安装 Go 到 /usr/local/go ..."
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/${go_tarball}"
  rm -f "/tmp/${go_tarball}"

  # 配置 Go 环境变量
  export PATH="/usr/local/go/bin:${PATH}"
  if ! grep -q '/usr/local/go/bin' /etc/profile.d/go.sh 2>/dev/null; then
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    chmod +x /etc/profile.d/go.sh
  fi

  # 设置 Go 模块代理（国内可用）
  go env -w GOPROXY=https://goproxy.cn,direct
  go env -w GO111MODULE=on

  print_ok "Go ${GO_VERSION} 安装完成"
}

# 编译安装 derper
compile_derper() {
  print_step "编译安装 derper（使用 goproxy.cn 国内代理）..."

  go install tailscale.com/cmd/derper@latest

  # 检查编译结果
  if [[ -f "$(go env GOPATH)/bin/derper" ]]; then
    cp "$(go env GOPATH)/bin/derper" "${DERP_BIN}"
    chmod +x "${DERP_BIN}"
    print_ok "derper 编译成功"
  else
    print_fail "derper 编译失败"
    exit 1
  fi
}

# 生成自签名证书
generate_certs() {
  local domain="$1"

  print_step "生成自签名证书（10 年有效期）..."

  mkdir -p "${CERT_DIR}"

  # 生成证书
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "${CERT_DIR}/${domain}.key" \
    -out "${CERT_DIR}/${domain}.crt" \
    -subj "/CN=${domain}" \
    -addext "subjectAltName=DNS:${domain}" 2>/dev/null

  # 设置权限
  chmod 600 "${CERT_DIR}/${domain}.key"
  chmod 644 "${CERT_DIR}/${domain}.crt"

  print_ok "自签名证书生成完成"
  print_info "证书路径: ${CERT_DIR}/${domain}.crt"
  print_info "有效期: 10 年"
}

# 创建 systemd 服务
create_systemd_service() {
  local domain="$1"
  local port="$2"
  local stun_port="$3"
  local verify_clients="$4"

  print_step "创建 systemd 服务..."

  # 保存配置到环境文件
  cat > "${TDERP_ENV}" << EOF
# tderp 配置 - 自动生成
DERP_DOMAIN="${domain}"
DERP_PORT="${port}"
DERP_STUN_PORT="${stun_port}"
DERP_VERIFY_CLIENTS="${verify_clients}"
CERT_DIR="${CERT_DIR}"
EOF

  # 构建 derper 参数
  local derper_args="-hostname ${domain} -a :${port} -http-port -1 -certmode manual -certdir ${CERT_DIR} -stun-port ${stun_port}"
  if [[ "${verify_clients}" == "true" ]]; then
    derper_args="${derper_args} -verify-clients"
  fi

  cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Tailscale DERP Server (tderp)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${DERP_BIN} ${derper_args}
Restart=always
RestartSec=5
LimitNOFILE=1048576

# 安全设置
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  print_ok "systemd 服务创建完成"
}

# 注册 tderp 命令
register_tderp_command() {
  print_step "注册 tderp 命令..."

  # 安装本脚本到系统命令
  cp "$0" "${TDERP_CMD}"
  chmod +x "${TDERP_CMD}"

  # 确保 PATH 中有 /usr/local/bin
  if ! grep -q '/usr/local/bin' /etc/profile.d/tderp-path.sh 2>/dev/null; then
    echo 'export PATH=$PATH:/usr/local/bin' > /etc/profile.d/tderp-path.sh
    chmod +x /etc/profile.d/tderp-path.sh
  fi

  print_ok "tderp 命令已注册"
  print_info "在终端输入 tderp 即可进入管理菜单"
}

# 等待服务启动
wait_for_service() {
  local port="$1"
  local max_wait=15
  local waited=0

  print_step "等待 DERP 服务启动..."

  while [[ $waited -lt $max_wait ]]; do
    if systemctl is-active --quiet tderp; then
      # 检查端口是否在监听
      if ss -tlnp | grep -q ":${port} "; then
        print_ok "DERP 服务已启动，端口 ${port} 监听中"
        return 0
      fi
    fi
    sleep 1
    ((waited++))
  done

  print_warn "服务启动超时，请检查日志: tderp logs"
  return 1
}

# 获取本地公网 IP
get_public_ip() {
  curl -s --max-time 5 https://api.ip.sb/ip 2>/dev/null || \
  curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null || \
  echo "你的公网IP"
}

# ==================== 管理功能 ====================

# 显示状态
show_status() {
  clear
  print_banner
  print_subtitle "服务状态"

  if [[ ! -f "${DERP_BIN}" ]]; then
    print_fail "DERP 未安装"
    return
  fi

  echo ""
  # 服务状态
  if systemctl is-active --quiet tderp; then
    echo -e "  服务状态:  ${GREEN}🟢 运行中${RESET}"
  else
    echo -e "  服务状态:  ${RED}🔴 未运行${RESET}"
  fi

  # 是否开机自启
  if systemctl is-enabled --quiet tderp 2>/dev/null; then
    echo -e "  开机自启:  ${GREEN}✅ 已启用${RESET}"
  else
    echo -e "  开机自启:  ${RED}❌ 未启用${RESET}"
  fi

  echo ""

  # 读取配置
  if [[ -f "${TDERP_ENV}" ]]; then
    source "${TDERP_ENV}"
    echo -e "  域名:      ${CYAN}${DERP_DOMAIN:-未设置}${RESET}"
    echo -e "  DERP 端口: ${CYAN}${DERP_PORT:-未设置}${RESET}"
    echo -e "  STUN 端口: ${CYAN}${DERP_STUN_PORT:-未设置}${RESET}"
    if [[ "${DERP_VERIFY_CLIENTS:-false}" == "true" ]]; then
      echo -e "  客户端验证: ${GREEN}已开启${RESET}"
    else
      echo -e "  客户端验证: ${YELLOW}未开启${RESET}"
    fi
  fi

  echo ""

  # derper 版本
  if [[ -f "${DERP_BIN}" ]]; then
    local ver
    ver=$("${DERP_BIN}" --version 2>/dev/null || echo "未知")
    echo -e "  derper 版本: ${PURPLE}${ver}${RESET}"
  fi

  echo ""

  # 资源占用
  if systemctl is-active --quiet tderp; then
    local pid
    pid=$(systemctl show tderp -p MainPID 2>/dev/null | cut -d= -f2)
    if [[ -n "$pid" && "$pid" -gt 0 ]]; then
      local mem
      mem=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')
      echo -e "  内存占用:  ${CYAN}${mem:-未知}${RESET}"
      echo -e "  进程 PID:  ${CYAN}${pid}${RESET}"
    fi
  fi

  echo ""
  print_line
  echo -e "  ${DIM}按回车键返回菜单${RESET}"
  read -r
}

# 查看日志
view_logs() {
  clear
  print_banner
  print_subtitle "实时日志（按 Ctrl+C 退出）"
  echo ""
  journalctl -u tderp -f -n 50 --no-hostname -o short-iso
  echo ""
  print_info "日志查看结束"
  echo -e "  ${DIM}按回车键返回菜单${RESET}"
  read -r
}

# 重启服务
restart_derper() {
  clear
  print_banner
  print_subtitle "重启服务"

  if systemctl is-active --quiet tderp; then
    systemctl restart tderp
    sleep 2
    if systemctl is-active --quiet tderp; then
      print_ok "DERP 服务已重启"
    else
      print_fail "DERP 服务重启失败"
      print_info "请查看日志: tderp logs"
    fi
  else
    print_warn "DERP 服务未运行，尝试启动..."
    systemctl start tderp
    if systemctl is-active --quiet tderp; then
      print_ok "DERP 服务已启动"
    else
      print_fail "DERP 服务启动失败"
    fi
  fi

  echo ""
  echo -e "  ${DIM}按回车键返回菜单${RESET}"
  read -r
}

# 停止服务
stop_derper() {
  clear
  print_banner
  print_subtitle "停止服务"

  if systemctl is-active --quiet tderp; then
    systemctl stop tderp
    print_ok "DERP 服务已停止"
  else
    print_warn "DERP 服务未运行"
  fi

  echo ""
  echo -e "  ${DIM}按回车键返回菜单${RESET}"
  read -r
}

# 更新 derper
update_derper() {
  clear
  print_banner
  print_subtitle "更新 derper"

  # 检查 Go 是否可用
  if ! command -v go &>/dev/null; then
    print_warn "未检测到 Go 编译环境"
    echo ""
    echo -e "  ${YELLOW}需要先安装 Go 才能编译最新版 derper。${RESET}"
    echo -e "  ${YELLOW}是否现在安装 Go ${GO_VERSION}？${RESET}"
    echo ""
    echo -n "  请输入 (y/n): "
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      install_go
    else
      print_info "取消更新"
      echo ""
      echo -e "  ${DIM}按回车键返回菜单${RESET}"
      read -r
      return
    fi
  fi

  # 获取当前版本
  local old_ver
  old_ver=$("${DERP_BIN}" --version 2>/dev/null || echo "未知")
  echo -e "  当前版本: ${PURPLE}${old_ver}${RESET}"

  print_step "正在编译最新版 derper..."
  go install tailscale.com/cmd/derper@latest

  if [[ -f "$(go env GOPATH)/bin/derper" ]]; then
    cp "$(go env GOPATH)/bin/derper" "${DERP_BIN}"
    chmod +x "${DERP_BIN}"
    print_ok "derper 更新完成"

    local new_ver
    new_ver=$("${DERP_BIN}" --version 2>/dev/null || echo "未知")
    echo -e "  更新后版本: ${PURPLE}${new_ver}${RESET}"

    # 重启服务
    echo ""
    print_step "重启服务以应用新版本..."
    systemctl restart tderp
    if systemctl is-active --quiet tderp; then
      print_ok "服务已重启，新版本生效"
    else
      print_fail "服务重启失败，请手动检查"
    fi
  else
    print_fail "编译失败"
  fi

  echo ""
  echo -e "  ${DIM}按回车键返回菜单${RESET}"
  read -r
}

# 重新生成证书
regenerate_certs() {
  clear
  print_banner
  print_subtitle "重新生成证书"

  if [[ ! -f "${TDERP_ENV}" ]]; then
    print_fail "未找到配置，请先安装"
    echo ""
    echo -e "  ${DIM}按回车键返回菜单${RESET}"
    read -r
    return
  fi

  source "${TDERP_ENV}"
  echo -e "  当前域名: ${CYAN}${DERP_DOMAIN}${RESET}"
  echo ""
  echo -n "  确认重新生成证书? (y/n): "
  read -r confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    print_info "取消"
    echo ""
    echo -e "  ${DIM}按回车键返回菜单${RESET}"
    read -r
    return
  fi

  # 备份旧证书
  if [[ -f "${CERT_DIR}/${DERP_DOMAIN}.crt" ]]; then
    local bak_dir="${TDERP_DIR}/certs-backup-$(date +%Y%m%d%H%M%S)"
    mkdir -p "${bak_dir}"
    cp "${CERT_DIR}/${DERP_DOMAIN}".* "${bak_dir}/" 2>/dev/null || true
    print_info "旧证书已备份到: ${bak_dir}"
  fi

  generate_certs "${DERP_DOMAIN}"

  # 重启服务
  print_step "重启服务以加载新证书..."
  systemctl restart tderp
  if systemctl is-active --quiet tderp; then
    print_ok "服务已重启，新证书生效"
  else
    print_fail "服务重启失败，请手动检查"
  fi

  echo ""
  echo -e "  ${DIM}按回车键返回菜单${RESET}"
  read -r
}

# 显示 ACL 配置
show_acl_config() {
  clear
  print_banner
  print_subtitle "Tailscale ACL 配置"

  if [[ ! -f "${TDERP_ENV}" ]]; then
    print_fail "未找到配置，请先安装"
    echo ""
    echo -e "  ${DIM}按回车键返回菜单${RESET}"
    read -r
    return
  fi

  source "${TDERP_ENV}"

  local public_ip
  public_ip=$(get_public_ip)

  echo ""
  echo -e "  ${BOLD}将以下配置添加到 Tailscale ACL 的 derpMap 中:${RESET}"
  echo ""
  print_line
  cat << ACL_EOF
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
            "HostName": "${DERP_DOMAIN}",
            "IPv4": "${public_ip}",
            "DERPPort": ${DERP_PORT},
            "STUNPort": ${DERP_STUN_PORT},
            "InsecureForTests": true
          }
        ]
      }
    }
  }
ACL_EOF
  print_line

  echo ""
  echo -e "  ${YELLOW}⚠️  注意:${RESET}"
  echo -e "  ${YELLOW}  1. InsecureForTests: true 是因为使用了自签名证书${RESET}"
  echo -e "  ${YELLOW}  2. DERP 仅中继已加密的 WireGuard 流量，服务器无法解密${RESET}"
  echo -e "  ${YELLOW}  3. 配置后可在客户端执行 tailscale netcheck 验证${RESET}"
  echo ""

  print_line
  echo -e "  ${DIM}按回车键返回菜单${RESET}"
  read -r
}

# 卸载
uninstall_derper() {
  clear
  print_banner
  print_subtitle "卸载 DERP"

  echo ""
  echo -e "  ${RED}⚠️  警告: 此操作将完全卸载 DERP 中继节点${RESET}"
  echo -e "  ${RED}     包括: 删除 systemd 服务、证书、配置文件${RESET}"
  echo ""
  echo -n "  请输入域名确认 (输入 'yes' 确认卸载): "
  read -r confirm
  if [[ "$confirm" != "yes" ]]; then
    print_info "取消卸载"
    echo ""
    echo -e "  ${DIM}按回车键返回菜单${RESET}"
    read -r
    return
  fi

  print_step "停止服务..."
  systemctl stop tderp 2>/dev/null || true

  print_step "禁用开机自启..."
  systemctl disable tderp 2>/dev/null || true

  print_step "删除 systemd 服务..."
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload

  print_step "删除 derper 二进制..."
  rm -f "${DERP_BIN}"

  print_step "删除配置和证书..."
  rm -rf "${TDERP_DIR}"

  print_step "删除 tderp 命令..."
  rm -f "${TDERP_CMD}"

  print_ok "DERP 已完全卸载"
  echo ""

  # 询问是否删除 Go
  if command -v go &>/dev/null; then
    echo -n "  是否同时删除 Go 编译环境? (y/n): "
    read -r del_go
    if [[ "$del_go" =~ ^[Yy]$ ]]; then
      rm -rf /usr/local/go
      rm -f /etc/profile.d/go.sh
      print_ok "Go 编译环境已删除"
    fi
  fi

  echo ""
  echo -e "  ${DIM}按回车键退出${RESET}"
  read -r
}

# ==================== 安装向导 ====================

install_wizard() {
  clear
  print_banner
  print_subtitle "安装向导"

  echo ""
  echo -e "  ${BOLD}本脚本将帮助你在服务器上部署 Tailscale DERP 中继节点。${RESET}"
  echo ""
  echo -e "  ${BOLD}方案特点:${RESET}"
  echo -e "  ${GREEN}•${RESET} 域名 + 高位端口 + 自签名证书"
  echo -e "  ${GREEN}•${RESET} 无需备案、无需续期证书"
  echo -e "  ${GREEN}•${RESET} systemd 管理，稳定可靠"
  echo -e "  ${GREEN}•${RESET} 安装后输入 tderp 进入管理菜单"
  echo ""
  print_line
  echo ""

  # ---- 前置检查 ----
  echo -e "  ${YELLOW}${BOLD}⚠️  安装前请确认以下两步已完成：${RESET}"
  echo ""
  echo -e "  ${BOLD}1️⃣  VPS 安全组/防火墙已开放端口${RESET}"
  echo -e "     TCP ${CYAN}${DERP_PORT:-12345}${RESET}（DERP 中继）"
  echo -e "     UDP ${CYAN}${DERP_STUN_PORT:-3478}${RESET}（STUN 打洞）"
  echo ""
  echo -e "  ${BOLD}2️⃣  域名 DNS 已指向本机 IP${RESET}"
  echo -e "     A 记录 → ${CYAN}你的域名${RESET} → ${CYAN}你的 VPS 公网 IP${RESET}"
  echo -e "     ${YELLOW}如果使用 Cloudflare：必须关闭代理（灰色云朵，DNS only）${RESET}"
  echo -e "     ${YELLOW}橙色云朵（代理模式）不支持 UDP 转发，会导致 STUN 失效${RESET}"
  echo ""
  echo -n "  以上两步是否已完成？(y/n): "
  read -r prereq_confirm
  if [[ ! "${prereq_confirm}" =~ ^[Yy]$ ]]; then
    print_warn "请先完成以上两步再运行安装"
    print_info "参考: https://github.com/bobvane/VPS-Tailscale-DERP-AutoSetup#readme"
    exit 0
  fi
  echo ""

  # ---- 收集用户输入 ----

  # 域名
  while true; do
    echo -n "  请输入你的域名 (如: derp.example.com): "
    read -r DERP_DOMAIN
    DERP_DOMAIN=$(echo "${DERP_DOMAIN}" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    if [[ -z "${DERP_DOMAIN}" ]]; then
      print_fail "域名不能为空"
    elif [[ ! "${DERP_DOMAIN}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*\.)+[a-zA-Z]{2,}$ ]]; then
      print_fail "域名格式不正确"
    else
      print_ok "域名: ${DERP_DOMAIN}"
      break
    fi
  done

  echo ""

  # DERP 端口
  DERP_PORT=""
  while true; do
    echo -n "  请输入 DERP 中继端口 (默认: 12345): "
    read -r input_port
    DERP_PORT="${input_port:-12345}"
    if [[ "${DERP_PORT}" =~ ^[0-9]+$ ]] && [[ "${DERP_PORT}" -ge 1024 ]] && [[ "${DERP_PORT}" -le 65535 ]]; then
      print_ok "DERP 端口: ${DERP_PORT}"
      break
    else
      print_fail "端口范围 1024-65535"
    fi
  done

  echo ""

  # STUN 端口
  while true; do
    echo -n "  请输入 STUN 端口 (默认: 3478): "
    read -r input_stun
    DERP_STUN_PORT="${input_stun:-3478}"
    if [[ "${DERP_STUN_PORT}" =~ ^[0-9]+$ ]] && [[ "${DERP_STUN_PORT}" -ge 1024 ]] && [[ "${DERP_STUN_PORT}" -le 65535 ]]; then
      print_ok "STUN 端口: ${DERP_STUN_PORT}"
      break
    elif [[ "${DERP_STUN_PORT}" -ge 1 ]] && [[ "${DERP_STUN_PORT}" -le 1023 ]]; then
      print_warn "建议使用 1024 以上端口"
      echo -n "  确认使用 ${DERP_STUN_PORT}? (y/n): "
      read -r confirm_port
      if [[ "$confirm_port" =~ ^[Yy]$ ]]; then
        break
      fi
    else
      print_fail "端口范围 1-65535"
    fi
  done

  echo ""

  # 客户端验证
  echo -n "  是否开启客户端验证? (需要安装 Tailscale, 默认: n) [y/n]: "
  read -r verify_input
  if [[ "${verify_input}" =~ ^[Yy]$ ]]; then
    DERP_VERIFY_CLIENTS="true"
    print_warn "客户端验证已开启，需要确保服务器已安装 Tailscale 并登录"
  else
    DERP_VERIFY_CLIENTS="false"
    print_info "客户端验证未开启（推荐，DERP 仅中继加密数据）"
  fi

  echo ""
  print_line
  echo ""

  # 确认信息
  echo -e "  ${BOLD}安装配置确认:${RESET}"
  echo -e "    ${CYAN}•${RESET} 域名:        ${BOLD}${DERP_DOMAIN}${RESET}"
  echo -e "    ${CYAN}•${RESET} DERP 端口:   ${BOLD}${DERP_PORT}${RESET}"
  echo -e "    ${CYAN}•${RESET} STUN 端口:   ${BOLD}${DERP_STUN_PORT}${RESET}"
  echo -e "    ${CYAN}•${RESET} 客户端验证:  ${BOLD}${DERP_VERIFY_CLIENTS}${RESET}"
  echo -e "    ${CYAN}•${RESET} 证书类型:    ${BOLD}自签名（10年有效）${RESET}"
  echo ""

  echo -n "  确认开始安装? (y/n): "
  read -r confirm_start
  if [[ ! "${confirm_start}" =~ ^[Yy]$ ]]; then
    print_info "安装已取消"
    exit 0
  fi

  echo ""
  print_line
  echo ""

  # ==================== 开始安装 ====================

  print_subtitle "开始安装"

  # 1. 检查系统
  echo ""
  print_step "检查系统环境..."
  check_root
  local os_info
  os_info=$(detect_os)
  local arch_info
  arch_info=$(detect_arch)
  print_ok "系统: ${os_info} | 架构: ${arch_info}"

  # 2. 安装系统依赖
  echo ""
  print_step "安装系统依赖..."
  install_packages curl wget openssl systemd
  print_ok "系统依赖就绪"

  # 3. 安装 Go
  echo ""
  print_step "安装 Go 编译环境..."
  if ! check_go; then
    install_go
  fi
  # 确保 Go 在 PATH 中
  export PATH="/usr/local/go/bin:${PATH}"

  # 4. 编译 derper
  echo ""
  compile_derper

  # 5. 生成证书
  echo ""
  generate_certs "${DERP_DOMAIN}"

  # 6. 创建 systemd 服务
  echo ""
  create_systemd_service "${DERP_DOMAIN}" "${DERP_PORT}" "${DERP_STUN_PORT}" "${DERP_VERIFY_CLIENTS}"

  # 7. 启动服务
  echo ""
  print_step "启动 DERP 服务..."
  systemctl enable tderp
  systemctl start tderp
  wait_for_service "${DERP_PORT}" || true

  # 8. 注册 tderp 命令
  echo ""
  register_tderp_command

  # ==================== 安装完成 ====================
  echo ""
  print_line
  echo ""
  print_subtitle "🎉 安装完成！"
  echo ""
  echo -e "  ${GREEN}${BOLD}Tailscale DERP 中继节点已部署成功！${RESET}"
  echo ""
  echo -e "  ${CYAN}●${RESET} 服务器: ${BOLD}${DERP_DOMAIN}:${DERP_PORT}${RESET}"
  echo -e "  ${CYAN}●${RESET} 证书:   自签名（10年有效）"
  echo -e "  ${CYAN}●${RESET} 状态:   ${GREEN}运行中${RESET}"
  echo ""

  # 防火墙提醒
  echo -e "  ${YELLOW}⚠️  请确保防火墙/安全组已开放以下端口:${RESET}"
  echo -e "     TCP ${DERP_PORT}  — DERP 中继流量"
  echo -e "     UDP ${DERP_STUN_PORT} — STUN 打洞服务"
  if [[ "${DERP_STUN_PORT}" != "3478" ]]; then
    echo -e "     ${YELLOW}   （STUN 端口非标准 3478，需确保客户端能访问）${RESET}"
  fi
  echo ""

  # 显示 ACL 配置
  local public_ip
  public_ip=$(get_public_ip)
  echo -e "  ${BOLD}请将以下配置添加到 Tailscale ACL 的 derpMap 中:${RESET}"
  echo ""
  print_line
  cat << ACL_EOF
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
            "HostName": "${DERP_DOMAIN}",
            "IPv4": "${public_ip}",
            "DERPPort": ${DERP_PORT},
            "STUNPort": ${DERP_STUN_PORT},
            "InsecureForTests": true
          }
        ]
      }
    }
  }
ACL_EOF
  print_line

  echo ""
  echo -e "  ${BOLD}管理命令:${RESET}"
  echo -e "    ${CYAN}tderp${RESET}        — 打开管理菜单"
  echo -e "    ${CYAN}tderp status${RESET}  — 查看状态"
  echo -e "    ${CYAN}tderp logs${RESET}    — 查看日志"
  echo -e "    ${CYAN}tderp restart${RESET} — 重启服务"
  echo ""

  # 验证提示
  echo -e "  ${BOLD}验证方法:${RESET}"
  echo -e "    在 Tailscale 客户端执行: ${CYAN}tailscale netcheck${RESET}"
  echo -e "    如果看到 ${DERP_DOMAIN} 的延迟，说明配置成功"
  echo ""

  print_line
  echo -e "  ${DIM}按回车键进入管理菜单${RESET}"
  read -r
}

# ==================== 管理菜单 ====================

management_menu() {
  while true; do
    clear
    print_banner

    # 状态栏
    if systemctl is-active --quiet tderp 2>/dev/null; then
      echo -e "  ${GREEN}🟢 运行中${RESET}  ", | tr -d '\n'
    else
      echo -e "  ${RED}🔴 未运行${RESET}  ", | tr -d '\n'
    fi

    if [[ -f "${TDERP_ENV}" ]]; then
      source "${TDERP_ENV}"
      echo -e "  域名: ${CYAN}${DERP_DOMAIN:-?}:${DERP_PORT:-?}${RESET}"
    else
      echo -e "  域名: ${RED}未配置${RESET}"
    fi

    echo ""
    print_line
    echo ""
    echo -e "  ${BOLD}${CYAN}  1.${RESET} 查看状态详情"
    echo -e "  ${BOLD}${CYAN}  2.${RESET} 查看实时日志"
    echo -e "  ${BOLD}${CYAN}  3.${RESET} 重启服务"
    echo -e "  ${BOLD}${CYAN}  4.${RESET} 停止服务"
    echo -e "  ${BOLD}${CYAN}  5.${RESET} 更新 derper"
    echo -e "  ${BOLD}${CYAN}  6.${RESET} 重新生成证书"
    echo -e "  ${BOLD}${CYAN}  7.${RESET} 显示 ACL 配置"
    echo -e "  ${BOLD}${RED}  8.${RESET} 卸载 DERP"
    echo ""
    echo -e "  ${BOLD}${DIM}  0.${RESET} 退出"
    echo ""
    print_line
    echo ""
    echo -n "  请输入选项 [0-8]: "
    read -r choice

    case "${choice}" in
      1) show_status ;;
      2) view_logs ;;
      3) restart_derper ;;
      4) stop_derper ;;
      5) update_derper ;;
      6) regenerate_certs ;;
      7) show_acl_config ;;
      8) uninstall_derper
         # 卸载后回到主菜单判断
         if [[ ! -f "${DERP_BIN}" ]]; then
           return
         fi
         ;;
      0)
        echo ""
        print_ok "再见！"
        exit 0
        ;;
      *)
        print_fail "无效选项"
        sleep 1
        ;;
    esac
  done
}

# ==================== 直接命令处理 ====================

# 支持 tderp status/logs/restart 等直接命令
handle_direct_command() {
  local cmd="$1"

  case "${cmd}" in
    status|state)
      show_status
      return 0
      ;;
    log|logs)
      view_logs
      return 0
      ;;
    restart|reload)
      restart_derper
      return 0
      ;;
    stop)
      stop_derper
      return 0
      ;;
    update|upgrade)
      update_derper
      return 0
      ;;
    acl|config)
      show_acl_config
      return 0
      ;;
    uninstall|remove)
      uninstall_derper
      return 0
      ;;
    help|--help|-h)
      echo "tderp — Tailscale DERP 管理脚本"
      echo ""
      echo "用法:"
      echo "  tderp             打开交互管理菜单"
      echo "  tderp status      查看服务状态"
      echo "  tderp logs        查看实时日志"
      echo "  tderp restart     重启服务"
      echo "  tderp stop        停止服务"
      echo "  tderp update      更新 derper"
      echo "  tderp acl         显示 ACL 配置"
      echo "  tderp uninstall   卸载 DERP"
      echo "  tderp help        显示此帮助"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# ==================== 入口 ====================

main() {
  # 如果带了参数，尝试作为直接命令处理
  if [[ $# -gt 0 ]]; then
    if handle_direct_command "$1"; then
      exit 0
    fi
    # 未知参数，显示帮助
    echo "未知命令: $1"
    echo "可用命令: status, logs, restart, stop, update, acl, uninstall, help"
    exit 1
  fi

  # 检查是否已安装
  if [[ -f "${DERP_BIN}" ]]; then
    management_menu
  else
    install_wizard
  fi
}

main "$@"