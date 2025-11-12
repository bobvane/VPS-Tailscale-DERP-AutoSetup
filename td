#!/usr/bin/env bash
# install_cn.sh v3.0-http
# 作者: bobvane
# 功能: 使用80端口签发Let’s Encrypt证书, 再启动DERP(443)
# 自动续签证书, 若失败则回退自签, 国内环境全兼容

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

# ────────────── 清理旧环境 ──────────────
cleanup_old(){
  info "🧹 清理旧环境..."
  systemctl stop derper tailscaled 2>/dev/null || true
  killall derper 2>/dev/null || true
  fuser -k 443/tcp 2>/dev/null || true
  rm -f /etc/systemd/system/derper.service
  rm -rf /opt/derper /var/lib/derper /usr/local/bin/derper
  systemctl daemon-reload
  info "✅ 清理完成"
}

# ────────────── 安装依赖 ──────────────
install_deps(){
  info "安装依赖..."
  apt update -y
  apt install -y curl wget git jq dnsutils socat tar ca-certificates lsb-release bc openssl certbot
}

# ────────────── 用户输入 ──────────────
read -rp "请输入要绑定的域名: " DOMAIN
[[ -z "$DOMAIN" ]] && { err "域名不能为空"; exit 1; }

read -rp "请输入服务器公网 IP（留空自动检测）: " SERVER_IP
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(curl -fsSL https://ifconfig.me || curl -fsSL https://ipinfo.io/ip)
info "域名: $DOMAIN"
info "服务器 IP: $SERVER_IP"

# ────────────── 检查 DNS ──────────────
info "检测 DNS 解析..."
digip=$(dig +short "$DOMAIN" A | tail -n1)
if [[ "$digip" != "$SERVER_IP" ]]; then
  warn "⚠️ DNS 未解析到本机 ($digip)，请确认 Cloudflare 灰云并指向 $SERVER_IP"
  read -rp "是否继续？(y/n) [y]: " yn
  [[ "${yn:-y}" =~ ^[Yy]$ ]] || exit 1
else
  info "✅ 域名解析正确"
fi

# ────────────── 安装 tailscale ──────────────
install_tailscale(){
  info "安装 tailscale..."
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt update -y && apt install -y tailscale
}

# ────────────── 安装 Go ──────────────
install_go(){
  info "下载 Go ${GO_VER}..."
  wget -q -O /tmp/go.tar.gz "$GO_URL" || { err "❌ Go 下载失败"; exit 1; }
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
  echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/99-go-path.sh
  export PATH=/usr/local/go/bin:$PATH
  info "✅ Go 安装完成：$(go version)"
}

# ────────────── 申请证书 (使用80端口) ──────────────
issue_cert(){
  info "🔐 使用80端口签发 Let’s Encrypt 证书..."
  mkdir -p /var/lib/derper/certs
  systemctl stop derper 2>/dev/null || true
  fuser -k 80/tcp 2>/dev/null || true

  certbot certonly --standalone \
    --preferred-challenges http \
    --agree-tos -m admin@$DOMAIN \
    -d $DOMAIN --non-interactive || true

  if [[ -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]]; then
    cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /var/lib/derper/certs/$DOMAIN.crt
    cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /var/lib/derper/certs/$DOMAIN.key
    info "✅ 证书签发成功"
  else
    warn "⚠️ 证书签发失败，改为自签..."
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout /var/lib/derper/certs/$DOMAIN.key \
      -out /var/lib/derper/certs/$DOMAIN.crt \
      -subj "/CN=$DOMAIN" -days 3650
  fi
}

# ────────────── 安装 derper ──────────────
install_derper(){
  info "安装 derper..."
  mkdir -p /opt/derper && cd /opt/derper
  version=$(curl -s https://api.github.com/repos/tailscale/tailscale/releases/latest | jq -r '.tag_name' || true)
  [[ -z "$version" ]] && version="v1.90.6"
  arch=$(uname -m)
  [[ "$arch" =~ "x86_64" ]] && asset_arch="amd64" || asset_arch="arm64"
  url="https://pkgs.tailscale.com/stable/tailscale_${version#v}_${asset_arch}.tgz"

  info "尝试下载官方包：$url"
  wget -q -O tailscale.tgz "$url" || warn "⚙️ 下载失败，将编译 derper"
  tar -xzf tailscale.tgz 2>/dev/null || true
  DERPER_PATH=$(find . -type f -name "derper" | head -n 1 || true)

  if [[ -z "$DERPER_PATH" ]]; then
    warn "⚙️ 开始源码编译 derper..."
    rm -rf /tmp/tailscale-src && mkdir -p /tmp/tailscale-src
    git clone --depth=1 https://ghproxy.cn/https://github.com/tailscale/tailscale.git /tmp/tailscale-src
    cd /tmp/tailscale-src/cmd/derper
    /usr/local/go/bin/go build -o /usr/local/bin/derper .
  else
    cp "$DERPER_PATH" /usr/local/bin/derper
  fi

  chmod +x /usr/local/bin/derper
  info "✅ derper 安装完成"
}

# ────────────── 创建 systemd 服务 ──────────────
create_service(){
  info "创建 derper 服务..."
  mkdir -p /var/lib/derper/certs
  cat >/etc/systemd/system/derper.service <<EOF
[Unit]
Description=Tailscale DERP relay server
After=network.target

[Service]
ExecStart=/usr/local/bin/derper --hostname $DOMAIN --certmode manual --certdir /var/lib/derper/certs --stun --a :443
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

# ────────────── 自动续签计划 ──────────────
auto_renew(){
  info "设置每周自动续签任务..."
  cat >/etc/cron.d/derper-renew <<EOF
0 3 * * 1 certbot renew --quiet && systemctl restart derper
EOF
  chmod 644 /etc/cron.d/derper-renew
  info "✅ 已启用自动续签"
}

# ────────────── 主流程 ──────────────
cleanup_old
install_deps
install_tailscale
install_go
issue_cert
install_derper
create_service
auto_renew
systemctl start derper
info "✅ 安装完成！输入 ${CYAN}td${RESET} 管理 DERP 服务。"
