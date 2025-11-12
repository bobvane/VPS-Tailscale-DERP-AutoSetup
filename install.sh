#!/usr/bin/env bash
# install.sh - 主安装脚本（中文交互、自动检测、Let’s Encrypt + 443）
set -euo pipefail
LANG=zh_CN.UTF-8
export LANG

REPO="https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main"
DEFAULT_DOMAIN="derp.bobvane.top"

# ────────────────────────────── 颜色函数 ──────────────────────────────
c_red(){ tput setaf 1 2>/dev/null || true; }
c_green(){ tput setaf 2 2>/dev/null || true; }
c_yellow(){ tput setaf 3 2>/dev/null || true; }
c_reset(){ tput sgr0 2>/dev/null || true; }

info(){ c_green; echo "[INFO] $*"; c_reset; }
warn(){ c_yellow; echo "[WARN] $*"; c_reset; }
err(){ c_red; echo "[ERROR] $*"; c_reset; }

confirm(){
  read -rp "$1 (y/n) [y]: " yn
  yn=${yn:-y}
  [[ $yn =~ ^[Yy] ]] && return 0 || return 1
}

check_root(){
  if [[ $EUID -ne 0 ]]; then
    err "请以 root 或 sudo 运行此脚本。"
    exit 1
  fi
}

# ────────────────────────────── 系统检测 ──────────────────────────────
detect_os(){
  . /etc/os-release
  OS_ID=$ID
  info "检测到系统：${PRETTY_NAME}"
}

install_deps(){
  info "安装依赖环境..."
  apt update && apt install -y curl wget git jq dnsutils cron socat
}

# ────────────────────────────── 交互输入 ──────────────────────────────
choose_domain_and_ip(){
  while true; do
    read -rp "请输入要绑定的域名: " DOMAIN
    if [[ -n "$DOMAIN" ]]; then
      break
    else
      echo "⚠️ 域名不能为空，请重新输入。"
    fi
  done

  echo "请输入服务器公网 IP（留空自动检测）："
  read -rp "> " SERVER_IP
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(curl -fsSL https://ifconfig.me || curl -fsSL https://ipinfo.io/ip)
  fi
  info "域名: $DOMAIN"
  info "服务器 IP: $SERVER_IP"
}

check_cloudflare(){
  info "检测 Cloudflare DNS 解析..."
  digip=$(dig +short "$DOMAIN" A | tail -n1)
  if [[ "$digip" != "$SERVER_IP" ]]; then
    warn "⚠️ DNS 未解析到本机 ($digip)，请在 Cloudflare 关闭代理（灰云）并指向 $SERVER_IP"
    confirm "是否继续?" || exit 1
  else
    info "✅ 域名解析正确。"
  fi
}

# ────────────────────────────── 安装 Tailscale ──────────────────────────────
install_tailscale(){
  info "安装 tailscale..."
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt update && apt install -y tailscale
}

# ────────────────────────────── 安装 DERPER ──────────────────────────────
install_derper(){
  info "安装 derper..."
  mkdir -p /opt/derper && cd /opt/derper
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) asset_arch="amd64" ;;
    aarch64|arm64) asset_arch="arm64" ;;
    *) asset_arch="amd64" ;;
  esac
  latest=$(curl -s https://api.github.com/repos/tailscale/tailscale/releases/latest)
  version=$(echo "$latest" | jq -r '.tag_name')
  url="https://pkgs.tailscale.com/stable/tailscale_${version#v}_${asset_arch}.tgz"
  wget -O tailscale.tgz "$url"
  tar -xzf tailscale.tgz
  cd tailscale_*/ || exit 1
  cp derper /usr/local/bin/
  chmod +x /usr/local/bin/derper
  info "✅ derper 安装成功 (版本: ${version})"
}

# ────────────────────────────── systemd 服务 ──────────────────────────────
create_service(){
  info "创建 systemd 服务..."
  cat >/etc/systemd/system/derper.service <<EOF
[Unit]
Description=Tailscale DERP relay server
After=network.target

[Service]
ExecStart=/usr/local/bin/derper --hostname $DOMAIN --certmode letsencrypt --stun --a ":443"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now derper
}

# ────────────────────────────── 自动更新脚本 ──────────────────────────────
setup_autoupdate(){
  info "创建自动更新任务..."
  cat >/usr/local/bin/derper-autoupdate.sh <<'EOF'
#!/usr/bin/env bash
set -e
apt update && apt install -y tailscale
cd /opt/derper
arch=$(uname -m)
case "$arch" in
  x86_64|amd64) asset_arch="linux_amd64" ;;
  aarch64|arm64) asset_arch="linux_arm64" ;;
  *) asset_arch="linux_amd64" ;;
esac
latest=$(curl -s https://api.github.com/repos/tailscale/tailscale/releases/latest)
url=$(echo "$latest" | jq -r ".assets[].browser_download_url | select(test(\"derper.*${asset_arch}\"))" | head -n1)
wget -O derper.tgz "$url"
tar -xzf derper.tgz --strip-components=1
mv derper /usr/local/bin/derper
chmod +x /usr/local/bin/derper
systemctl restart derper
EOF
  chmod +x /usr/local/bin/derper-autoupdate.sh
  (crontab -l 2>/dev/null; echo "0 5 * * 1 /usr/local/bin/derper-autoupdate.sh >/dev/null 2>&1") | crontab -
}

# ────────────────────────────── 菜单工具 ──────────────────────────────
install_td(){
  info "安装命令行管理工具 td..."
  wget -O /usr/local/bin/td "$REPO/td"
  chmod +x /usr/local/bin/td
}

# ────────────────────────────── 主流程 ──────────────────────────────
main(){
  check_root
  detect_os
  install_deps
  choose_domain_and_ip
  check_cloudflare
  install_tailscale
  install_derper
  create_service
  setup_autoupdate
  install_td
  info "✅ 安装完成！输入 td 管理 DERP 服务。"
}

main "$@"

