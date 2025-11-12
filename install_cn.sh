#!/usr/bin/env bash
# install_cn.sh v4.1-pro
# 作者: bobvane
# 生产级一键部署脚本 — Debian 12 专用（最终版 v4.1）
# 说明：部署流程包含系统更新、时间同步、BBR、certbot(80签证)、derper安装/编译、tailscale、go、td安装、自动续签。
set -euo pipefail
export LANG=zh_CN.UTF-8

# 彩色输出
RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

info(){ echo -e "${GREEN}[INFO]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERROR]${RESET} $*"; }

# 常量
REPO_RAW="https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main"
GO_VER="go1.25.4"
GO_URL="https://mirrors.aliyun.com/golang/${GO_VER}.linux-amd64.tar.gz"
GHPROXY_GIT_PREFIX="https://ghproxy.cn/https://github.com"
DERP_CERTDIR="/var/lib/derper/certs"
DERP_WORKDIR="/opt/derper"
CRON_FILE="/etc/cron.d/derper-renew"

# 权限与系统检测
[[ $EUID -ne 0 ]] && { err "请使用 root 权限运行此脚本"; exit 1; }
os_id=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
os_ver=$(awk -F= '/^VERSION_ID=/{print $2}' /etc/os-release | tr -d '"')
if [[ "${os_id}" != "debian" || "${os_ver}" != "12" ]]; then
  err "本脚本仅支持 Debian 12 (bookworm)。当前: ${os_id} ${os_ver} 。"
  exit 1
fi
info "系统检测通过：Debian 12"

# 交互
read -rp "请输入要绑定的域名（例如 derp.bobvane.top）: " DOMAIN
[[ -z "$DOMAIN" ]] && { err "域名不能为空"; exit 1; }
read -rp "请输入服务器公网 IP（留空自动检测）: " SERVER_IP
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP="$(curl -fsSL https://ifconfig.me || curl -fsSL https://ipinfo.io/ip || true)"
fi
info "域名: ${DOMAIN}"
info "服务器 IP: ${SERVER_IP}"

# ---------------- 工具函数 ----------------
_safe_sleep_wait_file(){
  # _safe_sleep_wait_file <file> <timeout_seconds>
  local file="$1"; local timeout="${2:-60}"; local t=0
  while [[ ! -f "$file" && $t -lt $timeout ]]; do
    sleep 1; t=$((t+1))
  done
  [[ -f "$file" ]]
}

# ---------------- 系统准备 ----------------
system_prepare(){
  info "系统更新并安装基础工具..."
  apt update -y
  apt upgrade -y
  apt install -y curl wget git jq dnsutils socat tar ca-certificates bc lsb-release
  info "安装 certbot 与 chrony"
  apt install -y certbot chrony || true
}

setup_time(){
  info "设置时区为 Asia/Shanghai 并启用 chrony 同步"
  timedatectl set-timezone Asia/Shanghai || true
  systemctl enable chrony || true
  systemctl restart chrony || true
  info "当前本地时间: $(date)"
}

enable_bbr(){
  info "启用 BBR（写入 /etc/sysctl.d/99-bbr.conf）"
  cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOF
  sysctl --system >/dev/null 2>&1 || true
  info "BBR 启用已写入（若内核支持）"
}

system_cleanup(){
  info "清理无用缓存"
  apt autoremove -y || true
  apt clean || true
}

# ---------------- 项目清理 ----------------
project_cleanup(){
  info "停止并清理本项目相关服务与文件..."
  systemctl stop derper tailscaled 2>/dev/null || true
  systemctl disable derper 2>/dev/null || true
  killall derper 2>/dev/null || true
  rm -f /etc/systemd/system/derper.service
  systemctl daemon-reload || true
  rm -rf /opt/derper /var/lib/derper /usr/local/bin/derper /tmp/tailscale-src
  rm -f /usr/local/bin/td
  rm -f "$CRON_FILE"
  info "清理完成"
}

# ---------------- install tailscale ----------------
install_tailscale(){
  info "安装 tailscale（官方源）"
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null || true
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null || true
  apt update -y
  apt install -y tailscale || true
  info "tailscale 安装或已存在"
}

# ---------------- install go ----------------
install_go(){
  info "下载并安装 Go: ${GO_VER} (阿里云镜像)"
  if ! wget -q -O /tmp/go.tar.gz "${GO_URL}"; then
    err "Go 下载失败，请检查网络或手动把 Go 包放到 /tmp/go.tar.gz"
    exit 1
  fi
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/99-go-path.sh
  export PATH=/usr/local/go/bin:$PATH
  info "Go 已安装: $(go version || true)"
}

# ---------------- issue cert (HTTP-01) ----------------
generate_self_signed_cert(){
  info "生成自签证书 (fallback)"
  mkdir -p "${DERP_CERTDIR}"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${DERP_CERTDIR}/${DOMAIN}.key" \
    -out "${DERP_CERTDIR}/${DOMAIN}.crt" \
    -subj "/CN=${DOMAIN}" -days 3650
  chmod 640 "${DERP_CERTDIR}/${DOMAIN}.key" || true
  info "自签证书已生成: ${DERP_CERTDIR}/${DOMAIN}.crt"
}

issue_cert_via_80(){
  info "使用 certbot（standalone）在 80 端口申请证书..."
  mkdir -p "${DERP_CERTDIR}"
  systemctl stop derper 2>/dev/null || true
  killall derper 2>/dev/null || true
  fuser -k 80/tcp 2>/dev/null || true

  local success=0
  for try in 1 2 3; do
    info "certbot 尝试第 ${try}/3 次..."
    if certbot certonly --standalone --preferred-challenges http \
        --agree-tos -m "admin@${DOMAIN}" -d "${DOMAIN}" --non-interactive; then
      success=1
      break
    else
      warn "certbot 第 ${try} 次失败，等待后重试..."
      sleep 3
    fi
  done

  if [[ "$success" -ne 1 ]]; then
    warn "certbot 多次失败，回退到自签证书"
    generate_self_signed_cert
    return 1
  fi

  info "等待 certbot 写入证书文件..."
  if ! _safe_sleep_wait_file "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" 60; then
    warn "证书文件写入超时，使用自签证书"
    generate_self_signed_cert
    return 1
  fi

  cp /etc/letsencrypt/live/"${DOMAIN}"/fullchain.pem "${DERP_CERTDIR}/${DOMAIN}.crt"
  cp /etc/letsencrypt/live/"${DOMAIN}"/privkey.pem "${DERP_CERTDIR}/${DOMAIN}.key"
  chmod 640 "${DERP_CERTDIR}/${DOMAIN}.key" || true
  info "✅ Certbot 证书已复制到 ${DERP_CERTDIR}"
  return 0
}

# ---------------- install derper ----------------
install_derper(){
  info "安装 derper (尝试官方包，找不到则源码编译)"
  mkdir -p "${DERP_WORKDIR}" "${DERP_CERTDIR}"
  cd "${DERP_WORKDIR}" || true

  version="$(curl -fsS https://api.github.com/repos/tailscale/tailscale/releases/latest | jq -r '.tag_name' 2>/dev/null || true)"
  [[ -z "$version" ]] && version="v1.90.6"
  arch=$(uname -m)
  [[ "$arch" =~ "x86_64" ]] && asset_arch="amd64" || asset_arch="arm64"
  url="https://pkgs.tailscale.com/stable/tailscale_${version#v}_${asset_arch}.tgz"
  info "尝试下载官方包: $url"
  if wget -q -O tailscale.tgz "$url"; then
    tar -xzf tailscale.tgz 2>/dev/null || true
  else
    warn "下载官方包失败，准备源码编译"
  fi

  DERPER_PATH="$(find . -type f -name 'derper' | head -n1 || true)"
  if [[ -n "$DERPER_PATH" && -f "$DERPER_PATH" ]]; then
    cp "$DERPER_PATH" /usr/local/bin/derper
    chmod +x /usr/local/bin/derper
    info "已安装 derper (来自官方包)"
  else
    warn "官方包无 derper，开始源码编译 (ghproxy 加速)"
    rm -rf /tmp/tailscale-src && mkdir -p /tmp/tailscale-src
    if ! git clone --depth=1 "${GHPROXY_GIT_PREFIX}/tailscale/tailscale.git" /tmp/tailscale-src; then
      err "克隆源码失败"
      exit 1
    fi
    cd /tmp/tailscale-src/cmd/derper || { err "源码目录异常"; exit 1; }
    /usr/local/go/bin/go build -o /usr/local/bin/derper . || { err "derper 编译失败"; exit 1; }
    chmod +x /usr/local/bin/derper
    info "derper 已从源码编译并安装"
  fi
}

# ---------------- create systemd ----------------
create_service(){
  info "创建 systemd 服务 (使用 manual 模式，证书已在 ${DERP_CERTDIR})"
  mkdir -p /var/lib/derper
  cat >/etc/systemd/system/derper.service <<EOF
[Unit]
Description=Tailscale DERP relay server
After=network.target

[Service]
ExecStart=/usr/local/bin/derper --hostname ${DOMAIN} --certmode manual --certdir ${DERP_CERTDIR} --stun --a ":443"
WorkingDirectory=/var/lib/derper
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable derper
  info "systemd 单元已创建并启用"
}

# ---------------- install td ----------------
install_td(){
  info "安装 td 管理工具"
  if wget -q -O /usr/local/bin/td "${REPO_RAW}/td"; then
    chmod +x /usr/local/bin/td
    info "td 已安装到 /usr/local/bin/td"
  else
    warn "下载 td 失败，可稍后手动安装"
  fi
}

# ---------------- auto renew ----------------
setup_auto_renew(){
  info "创建自动续签任务（每周一凌晨3点）"
  cat >"${CRON_FILE}" <<EOF
0 3 * * 1 root certbot renew --quiet && systemctl restart derper
EOF
  chmod 644 "${CRON_FILE}"
  info "自动续签任务已创建: ${CRON_FILE}"
}

# ---------------- main ----------------
main(){
  system_prepare
  setup_time
  enable_bbr
  system_cleanup
  project_cleanup
  install_tailscale
  install_go

  if issue_cert_via_80; then
    info "证书获取成功（使用 Certbot）"
  else
    warn "使用自签证书"
  fi

  install_derper
  create_service
  install_td
  setup_auto_renew

  info "尝试启动 derper..."
  systemctl start derper
  sleep 3
  if systemctl is-active --quiet derper; then
    info "✅ derper 已启动并运行"
  else
    warn "derper 未能启动，请使用: journalctl -u derper -n 50 --no-pager 查看日志"
  fi
}

# ---------------- 执行 ----------------
echo
info "准备部署: ${DOMAIN} -> ${SERVER_IP}"
read -rp "确认继续部署吗？(y/N): " ok
if [[ "${ok,,}" != "y" ]]; then
  info "已取消"
  exit 0
fi

main

echo
info "脚本执行结束。请运行 ${CYAN}td${RESET} 并选择 “注册 Tailscale 客户端” 完成登录步骤。"
info "示例: td -> [7] 注册 Tailscale 客户端"
