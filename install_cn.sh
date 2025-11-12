#!/usr/bin/env bash
# install_cn.sh v1.5 - VPS-Tailscale-DERP-AutoSetup 最终国内优化稳定版
# 作者: bobvane
# 特点：
#  - 自动清理旧环境
#  - 国内加速源（Go + GitHub）
#  - 官方 tailscale 源（可直连）
#  - 自动 SSL 证书 + systemd 管理
set -euo pipefail
LANG=zh_CN.UTF-8
export LANG

REPO="https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main"

# ──────────────── 彩色输出 ────────────────
c_red(){ tput setaf 1 2>/dev/null || true; }
c_green(){ tput setaf 2 2>/dev/null || true; }
c_yellow(){ tput setaf 3 2>/dev/null || true; }
c_reset(){ tput sgr0 2>/dev/null || true; }

info(){ c_green; echo "[INFO] $*"; c_reset; }
warn(){ c_yellow; echo "[WARN] $*"; c_reset; }
err(){ c_red; echo "[ERROR] $*"; c_reset; }

check_root(){
  if [[ $EUID -ne 0 ]]; then
    err "请以 root 权限运行此脚本。"
    exit 1
  fi
}

# ──────────────── 自动清理旧环境 ────────────────
cleanup_old(){
  info "🧹 检测并清理旧版安装..."
  systemctl stop derper 2>/dev/null || true
  systemctl disable derper 2>/dev/null || true
  rm -f /etc/systemd/system/derper.service
  systemctl daemon-reload

  rm -rf /opt/derper /tmp/tailscale-src /usr/local/bin/derper /usr/local/bin/derper-autoupdate.sh
  rm -rf /usr/local/go /tmp/go.tar.gz /etc/profile.d/go-path.sh
  sed -i '/go\/bin/d' ~/.bashrc 2>/dev/null || true

  rm -f /etc/apt/sources.list.d/tailscale.list /usr/share/keyrings/tailscale-archive-keyring.gpg
  rm -f /usr/local/bin/td
  apt autoremove -y >/dev/null 2>&1 || true
  info "✅ 旧环境清理完成。"
}

# ──────────────── 系统与依赖 ────────────────
detect_os(){
  . /etc/os-release
  info "检测到系统：${PRETTY_NAME}"
  info "🌏 启用国内加速模式（Go + GitHub）"
}

install_deps(){
  info "安装依赖环境..."
  apt update -y
  apt install -y curl wget git jq dnsutils cron socat ca-certificates lsb-release tar
}

# ──────────────── 用户输入 ────────────────
choose_domain_and_ip(){
  while true; do
    read -rp "请输入要绑定的域名: " DOMAIN
    [[ -n "$DOMAIN" ]] && break || echo "⚠️ 域名不能为空，请重新输入。"
  done

  read -rp "请输入服务器公网 IP（留空自动检测）: " SERVER_IP
  [[ -z "$SERVER_IP" ]] && SERVER_IP=$(curl -fsSL https://ifconfig.me || curl -fsSL https://ipinfo.io/ip)
  info "域名: $DOMAIN"
  info "服务器 IP: $SERVER_IP"
}

check_dns(){
  info "检测 Cloudflare DNS 解析..."
  digip=$(dig +short "$DOMAIN" A | tail -n1)
  if [[ "$digip" != "$SERVER_IP" ]]; then
    warn "⚠️ DNS 未解析到本机 ($digip)，请确保 Cloudflare 灰云并指向 $SERVER_IP"
    read -rp "是否继续安装？(y/n) [y]: " yn
    [[ "${yn:-y}" =~ ^[Yy]$ ]] || exit 1
  else
    info "✅ 域名解析正确。"
  fi
}

# ──────────────── 安装 tailscale（官方源） ────────────────
install_tailscale(){
  info "安装 tailscale..."
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt update -y && apt install -y tailscale
}

# ──────────────── 安装最新 Go ────────────────
install_go(){
  info "获取最新 Go 版本..."
  GO_LATEST=$(curl -s https://go.dev/VERSION?m=text | head -n1)
  info "下载 Go ${GO_LATEST}（国内镜像优先）..."
  GO_URL_ALI="https://mirrors.aliyun.com/golang/${GO_LATEST}.linux-amd64.tar.gz"
  GO_URL_TUNA="https://mirrors.tuna.tsinghua.edu.cn/golang/${GO_LATEST}.linux-amd64.tar.gz"
  GO_URL_OFFICIAL="https://go.dev/dl/${GO_LATEST}.linux-amd64.tar.gz"

  wget -q -O /tmp/go.tar.gz "$GO_URL_ALI" || \
  wget -q -O /tmp/go.tar.gz "$GO_URL_TUNA" || \
  wget -q -O /tmp/go.tar.gz "$GO_URL_OFFICIAL"

  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
  echo 'export PATH=$PATH:/usr/local/go/bin' >/etc/profile.d/go-path.sh
  export PATH=$PATH:/usr/local/go/bin
  info "✅ Go 环境就绪：$(go version)"
}

# ──────────────── 安装 derper ────────────────
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
  wget -q -O tailscale.tgz "$url"
  tar -xzf tailscale.tgz

  DERPER_PATH=$(find . -type f -name "derper" | head -n 1 || true)
  if [[ -f "$DERPER_PATH" ]]; then
    info "✅ 官方包包含 derper，路径：$DERPER_PATH"
    cp "$DERPER_PATH" /usr/local/bin/derper
  else
    warn "⚙️ 官方包未包含 derper，开始编译..."
    rm -rf /tmp/tailscale-src
    git clone --depth=1 https://ghproxy.cn/https://github.com/tailscale/tailscale.git /tmp/tailscale-src || \
    git clone --depth=1 https://kgithub.com/tailscale/tailscale.git /tmp/tailscale-src || \
    git clone --depth=1 https://github.com/tailscale/tailscale.git /tmp/tailscale-src
    cd /tmp/tailscale-src/cmd/derper
    go build
    cp derper /usr/local/bin/
    info "✅ derper 编译完成。"
  fi

  chmod +x /usr/local/bin/derper
  derper -h >/dev/null 2>&1 && info "✅ derper 验证通过。"
}

# ──────────────── 创建 systemd 服务 ────────────────
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

# ──────────────── 安装 td 工具 ────────────────
install_td(){
  info "安装命令行管理工具 td..."
  wget -q -O /usr/local/bin/td "https://ghproxy.cn/${REPO}/td"
  chmod +x /usr/local/bin/td
}

# ──────────────── 主流程 ────────────────
main(){
  check_root
  detect_os
  cleanup_old
  install_deps
  choose_domain_and_ip
  check_dns
  install_tailscale
  install_go
  install_derper
  create_service
  install_td
  info "✅ 安装完成！输入 td 查看菜单管理。"
}

main "$@"
