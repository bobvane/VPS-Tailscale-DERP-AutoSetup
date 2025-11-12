#!/usr/bin/env bash
# install_cn.sh v2.6 - VPS-Tailscale-DERP-AutoSetup
# 作者: bobvane
# 更新说明：
#   ✅ 固定 Go 版本 go1.25.4
#   ✅ 固定使用阿里云镜像下载（不测速）
#   ✅ 简化逻辑，提高成功率
#   ✅ 保留 tailscale + derper + SSL + td 全流程

set -euo pipefail
LANG=zh_CN.UTF-8
export LANG

REPO="https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main"
GO_VER="go1.25.4"
GO_URL="https://mirrors.aliyun.com/golang/${GO_VER}.linux-amd64.tar.gz"

# ────────────── 彩色输出 ──────────────
c_red(){ tput setaf 1 2>/dev/null || true; }
c_green(){ tput setaf 2 2>/dev/null || true; }
c_yellow(){ tput setaf 3 2>/dev/null || true; }
c_reset(){ tput sgr0 2>/dev/null || true; }

info(){ c_green; echo "[INFO] $*"; c_reset; }
warn(){ c_yellow; echo "[WARN] $*"; c_reset; }
err(){ c_red; echo "[ERROR] $*"; c_reset; }

# ────────────── 权限检查 ──────────────
check_root(){
  if [[ $EUID -ne 0 ]]; then
    err "请以 root 权限运行此脚本。"
    exit 1
  fi
}

# ────────────── 清理旧环境 ──────────────
cleanup_old(){
  info "🧹 清理旧环境..."
  systemctl stop derper 2>/dev/null || true
  systemctl disable derper 2>/dev/null || true
  rm -f /etc/systemd/system/derper.service
  systemctl daemon-reload || true

  rm -rf /opt/derper /tmp/tailscale-src /usr/local/bin/derper
  rm -rf /usr/local/go /tmp/go.tar.gz /etc/profile.d/99-go-path.sh
  apt remove -y golang-go golang-1.* golang >/dev/null 2>&1 || true
  apt autoremove -y >/dev/null 2>&1 || true
  info "✅ 清理完成。"
}

# ────────────── 安装依赖 ──────────────
install_deps(){
  info "安装依赖包..."
  apt update -y
  apt install -y curl wget git jq dnsutils socat tar ca-certificates lsb-release
}

# ────────────── 用户输入 ──────────────
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
  info "下载 Go ${GO_VER}（阿里云源）..."
  wget -q --user-agent="Mozilla/5.0" -O /tmp/go.tar.gz "$GO_URL" || {
    err "❌ 下载失败，请手动确认网络或手动上传 go.tar.gz 至 /tmp 目录"
    exit 1
  }

  info "解压 Go..."
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tar.gz
  echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/99-go-path.sh
  export PATH=/usr/local/go/bin:$PATH
  info "✅ Go 安装完成：$(go version)"
}

# ────────────── Go 模块代理 ──────────────
setup_goproxy(){
  info "配置 Go 模块代理 (https://goproxy.cn)"
  go env -w GOPROXY=https://goproxy.cn,direct
  go env -w GOSUMDB=off
  info "✅ 模块代理配置完成"
}

# ────────────── 安装 derper ──────────────
install_derper(){
  info "安装 derper..."
  mkdir -p /opt/derper && cd /opt/derper
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) asset_arch="amd64" ;;
    aarch64|arm64) asset_arch="arm64" ;;
    *) asset_arch="amd64" ;;
  esac

  version=$(curl -s https://api.github.com/repos/tailscale/tailscale/releases/latest | jq -r '.tag_name' || true)
  [[ -z "$version" ]] && version="v1.0.0"
  url="https://pkgs.tailscale.com/stable/tailscale_${version#v}_${asset_arch}.tgz"
  info "下载 tailscale 包: $url"
  wget -q -O tailscale.tgz "$url" || { err "下载失败"; exit 1; }
  tar -xzf tailscale.tgz

  DERPER_PATH=$(find . -type f -name "derper" | head -n 1 || true)
  if [[ -f "$DERPER_PATH" ]]; then
    info "✅ 官方包包含 derper"
    cp "$DERPER_PATH" /usr/local/bin/derper
  else
    warn "⚙️ 官方包无 derper，开始编译..."
    rm -rf /tmp/tailscale-src
    git clone --depth=1 https://ghproxy.cn/https://github.com/tailscale/tailscale.git /tmp/tailscale-src || \
    git clone --depth=1 https://github.com/tailscale/tailscale.git /tmp/tailscale-src
    cd /tmp/tailscale-src/cmd/derper
    go build
    cp derper /usr/local/bin/
    info "✅ derper 编译完成。"
  fi

  chmod +x /usr/local/bin/derper
  derper -h >/dev/null 2>&1 && info "✅ derper 验证通过"
}

# ────────────── 创建 systemd 服务 ──────────────
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

# ────────────── 安装 td 工具 ──────────────
install_td(){
  info "安装 td 管理工具..."
  wget -q -O /usr/local/bin/td "https://ghproxy.cn/${REPO}/td"
  chmod +x /usr/local/bin/td
}

# ────────────── 主流程 ──────────────
main(){
  check_root
  cleanup_old
  install_deps
  choose_domain_and_ip
  check_dns
  install_tailscale
  install_go
  setup_goproxy
  install_derper
  create_service
  install_td
  info "✅ 安装完成！输入 td 管理 DERP 服务。"
}

main "$@"
