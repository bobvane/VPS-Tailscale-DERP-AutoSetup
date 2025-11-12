#!/usr/bin/env bash
# install_cn.sh v2.9 - VPS-Tailscale-DERP AutoSetup
# 作者: bobvane
# 功能:
#   - 自动部署 DERP 中继服务（国内优化版）
#   - 智能检测 derper 二进制是否存在，不存在则自动从源码编译
#   - 实时 Let’s Encrypt 证书申请日志
#   - 自动安装 td 管理工具

set -euo pipefail
LANG=zh_CN.UTF-8
export LANG

REPO="https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main"
GO_VER="go1.25.4"
GO_URL="https://mirrors.aliyun.com/golang/${GO_VER}.linux-amd64.tar.gz"

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
CYAN=$(tput setaf 6)
RESET=$(tput sgr0)

info(){ echo -e "${GREEN}[INFO]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERROR]${RESET} $*"; }

[[ $EUID -ne 0 ]] && { err "请使用 root 权限执行"; exit 1; }

# ────────────── 1️⃣ 清理旧环境 ──────────────
cleanup_old(){
  info "🧹 停止旧服务并清理环境..."
  systemctl stop derper tailscaled 2>/dev/null || true
  killall derper 2>/dev/null || true
  fuser -k 443/tcp 2>/dev/null || true

  rm -f /etc/systemd/system/derper.service
  rm -rf /opt/derper /var/lib/derper /usr/local/bin/derper
  rm -rf /usr/local/go /etc/profile.d/99-go-path.sh /tmp/tailscale-src
  rm -f /usr/local/bin/td
  apt remove -y golang-go golang-1.* golang >/dev/null 2>&1 || true
  apt autoremove -y >/dev/null 2>&1 || true
  systemctl daemon-reload
  info "✅ 旧环境已彻底清理"
}

# ────────────── 2️⃣ 安装依赖 ──────────────
install_deps(){
  info "安装依赖..."
  apt update -y
  apt install -y curl wget git jq dnsutils socat tar ca-certificates lsb-release bc
}

# ────────────── 3️⃣ 用户输入 ──────────────
read -rp "请输入要绑定的域名: " DOMAIN
[[ -z "$DOMAIN" ]] && { err "域名不能为空"; exit 1; }

read -rp "请输入服务器公网 IP（留空自动检测）: " SERVER_IP
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(curl -fsSL https://ifconfig.me || curl -fsSL https://ipinfo.io/ip)
info "域名: $DOMAIN"
info "服务器 IP: $SERVER_IP"

info "检测 DNS 解析..."
digip=$(dig +short "$DOMAIN" A | tail -n1)
if [[ "$digip" != "$SERVER_IP" ]]; then
  warn "⚠️ DNS 未解析到本机 ($digip)，请确保 Cloudflare 灰云并指向 $SERVER_IP"
  read -rp "是否继续安装？(y/n) [y]: " yn
  [[ "${yn:-y}" =~ ^[Yy]$ ]] || exit 1
else
  info "✅ 域名解析正确"
fi

# ────────────── 4️⃣ 安装 tailscale ──────────────
install_tailscale(){
  info "安装 tailscale..."
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt update -y && apt install -y tailscale
}

# ────────────── 5️⃣ 安装 Go ──────────────
install_go(){
  info "下载 Go ${GO_VER}（阿里云源）..."
  wget -q -O /tmp/go.tar.gz "$GO_URL" || { err "❌ Go 下载失败"; exit 1; }
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
  echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/99-go-path.sh
  export PATH=/usr/local/go/bin:$PATH
  info "✅ Go 安装完成：$(go version)"
}

# ────────────── 6️⃣ 安装 derper ──────────────
install_derper(){
  info "安装 derper..."
  mkdir -p /opt/derper /var/lib/derper/certs && cd /opt/derper

  version=$(curl -s https://api.github.com/repos/tailscale/tailscale/releases/latest | jq -r '.tag_name' || true)
  [[ -z "$version" ]] && version="v1.90.6"

  arch=$(uname -m)
  [[ "$arch" =~ "x86_64" ]] && asset_arch="amd64" || asset_arch="arm64"
  url="https://pkgs.tailscale.com/stable/tailscale_${version#v}_${asset_arch}.tgz"

  info "尝试下载官方包：$url"
  wget -q -O tailscale.tgz "$url" || warn "⚠️ 官方包下载失败，将直接编译 derper"
  tar -xzf tailscale.tgz 2>/dev/null || true

  DERPER_PATH=$(find . -type f -name "derper" | head -n 1 || true)

  if [[ -z "$DERPER_PATH" ]]; then
    warn "⚙️ 官方包未包含 derper，开始从源码编译..."
    rm -rf /tmp/tailscale-src && mkdir -p /tmp/tailscale-src
    git clone --depth=1 https://ghproxy.cn/https://github.com/tailscale/tailscale.git /tmp/tailscale-src || {
      err "❌ 克隆源码失败，请检查网络"
      exit 1
    }
    cd /tmp/tailscale-src/cmd/derper
    info "🔧 正在使用 Go 编译 derper..."
    /usr/local/go/bin/go build -o /usr/local/bin/derper . || {
      err "❌ derper 编译失败，请检查 Go 环境"
      exit 1
    }
  else
    cp "$DERPER_PATH" /usr/local/bin/derper
  fi

  chmod +x /usr/local/bin/derper
  info "✅ derper 安装完成：$(/usr/local/bin/derper -version 2>/dev/null || echo 手动构建)"
}

# ────────────── 7️⃣ 创建 systemd 服务 ──────────────
create_service(){
  info "创建 derper 服务..."
  cat >/etc/systemd/system/derper.service <<EOF
[Unit]
Description=Tailscale DERP relay server
After=network.target

[Service]
ExecStart=/usr/local/bin/derper --hostname $DOMAIN --certmode letsencrypt --certdir /var/lib/derper/certs --stun --a ":443"
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
}

# ────────────── 8️⃣ 启动并显示证书日志 ──────────────
start_service_with_log(){
  info "🚀 启动 derper 并显示证书申请日志..."
  systemctl start derper
  sleep 2
  journalctl -u derper -f -n 20 &
  sleep 10
  pkill -f "journalctl -u derper" || true

  if [[ -f /var/lib/derper/certs/${DOMAIN}.crt ]]; then
    info "✅ 证书签发成功：/var/lib/derper/certs/${DOMAIN}.crt"
  else
    err "❌ 证书签发失败，请检查 DNS 与端口"
    exit 1
  fi
}

# ────────────── 9️⃣ 安装 td 管理工具 ──────────────
install_td(){
  info "安装 td 管理工具..."
  wget -q -O /usr/local/bin/td "https://ghproxy.cn/${REPO}/td"
  chmod +x /usr/local/bin/td
}

# ────────────── 🔟 主执行流程 ──────────────
cleanup_old
install_deps
install_tailscale
install_go
install_derper
create_service
start_service_with_log
install_td

info "✅ 安装完成！输入 ${CYAN}td${RESET} 管理 DERP 服务。"
