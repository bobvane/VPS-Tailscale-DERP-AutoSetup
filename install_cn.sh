#!/usr/bin/env bash
# install_cn.sh v1.4-CN
# 国内优化版：使用阿里云/清华/ghproxy 镜像加速所有下载与克隆操作
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

# ──────────────── 基础环境 ────────────────
detect_os(){
  . /etc/os-release
  info "检测到系统：${PRETTY_NAME}"
  info "🌏 启用国内源加速模式"
}

install_deps(){
  info "安装依赖环境..."
  apt update -y
  apt install -y curl wget git jq dnsutils cron socat ca-certificates lsb-release tar
}

# ──────────────── 域名输入 ────────────────
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

check_cloudflare(){
  info "检测 Cloudflare DNS 解析..."
  digip=$(dig +short "$DOMAIN" A | tail -n1)
  if [[ "$digip" != "$SERVER_IP" ]]; then
    warn "⚠️ DNS 未解析到本机 ($digip)，请确保 Cloudflare 关闭代理（灰云）并指向 $SERVER_IP"
    read -rp "是否继续安装？(y/n) [y]: " yn
    [[ "${yn:-y}" =~ ^[Yy]$ ]] || exit 1
  else
    info "✅ 域名解析正确。"
  fi
}

# ──────────────── 安装 tailscale ────────────────
install_tailscale(){
  info "安装 tailscale..."
  echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://mirror.ghproxy.cn/https://pkgs.tailscale.com/stable/debian bookworm main" >/etc/apt/sources.list.d/tailscale.list
  curl -fsSL https://mirror.ghproxy.cn/https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  apt update -y && apt install -y tailscale
}

# ──────────────── 安装最新 Go ────────────────
install_latest_go(){
  info "获取最新 Go 版本..."
  GO_LATEST=$(curl -s https://go.dev/VERSION?m=text | head -n1)
  info "下载 Go ${GO_LATEST}（国内镜像优先）..."
  GO_URL_ALI="https://mirrors.aliyun.com/golang/${GO_LATEST}.linux-amd64.tar.gz"
  GO_URL_CSU="https://mirrors.cqu.edu.cn/golang/${GO_LATEST}.linux-amd64.tar.gz"
  GO_URL_OFFICIAL="https://go.dev/dl/${GO_LATEST}.linux-amd64.tar.gz"

  wget --connect-timeout=10 -q -O /tmp/go.tar.gz "$GO_URL_ALI" || \
  wget --connect-timeout=10 -q -O /tmp/go.tar.gz "$GO_URL_CSU" || \
  wget --connect-timeout=10 -q -O /tmp/go.tar.gz "$GO_URL_OFFICIAL"

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
  url="https://mirror.ghproxy.cn/https://pkgs.tailscale.com/stable/tailscale_${version#v}_${asset_arch}.tgz"
  info "下载 tailscale 包: $url"
  wget --connect-timeout=10 -q -O tailscale.tgz "$url" || \
  wget -q -O tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${version#v}_${asset_arch}.tgz"
  tar -xzf tailscale.tgz

  DERPER_PATH=$(find . -type f -name "derper" | head -n 1 || true)
  if [[ -f "$DERPER_PATH" ]]; then
    info "✅ 官方包包含 derper，路径：$DERPER_PATH"
    cp "$DERPER_PATH" /usr/local/bin/derper
  else
    warn "⚙️ 官方包未包含 derper，开始从镜像源编译..."
    rm -rf /tmp/tailscale-src
    git clone --depth=1 https://ghproxy.cn/https://github.com/tailscale/tailscale.git /tmp/tailscale-src || \
    git clone --depth=1 https://kgithub.com/tailscale/tailscale.git /tmp/tailscale-src || \
    git clone --depth=1 https://github.com/tailscale/tailscale.git /tmp/tailscale-src
    cd /tmp/tailscale-src/cmd/derper
    info "🔧 使用 Go $(go version) 编译中..."
    go build
    cp derper /usr/local/bin/
    info "✅ derper 编译完成。"
    rm -rf /tmp/tailscale-src
  fi

  chmod +x /usr/local/bin/derper
  derper -h >/dev/null 2>&1 && info "✅ derper 验证通过。" || { err "❌ derper 启动失败"; exit 1; }
}

# ──────────────── systemd ────────────────
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

# ──────────────── 自动更新 ────────────────
setup_autoupdate(){
  info "配置自动更新任务..."
  cat >/usr/local/bin/derper-autoupdate.sh <<'EOF'
#!/usr/bin/env bash
set -e
export PATH=$PATH:/usr/local/go/bin
cd /opt/derper
arch=$(uname -m)
case "$arch" in
  x86_64|amd64) asset_arch="amd64" ;;
  aarch64|arm64) asset_arch="arm64" ;;
  *) asset_arch="amd64" ;;
esac
latest=$(curl -s https://api.github.com/repos/tailscale/tailscale/releases/latest)
version=$(echo "$latest" | jq -r '.tag_name')
url="https://mirror.ghproxy.cn/https://pkgs.tailscale.com/stable/tailscale_${version#v}_${asset_arch}.tgz"
wget -q -O tailscale.tgz "$url" || \
wget -q -O tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${version#v}_${asset_arch}.tgz"
tar -xzf tailscale.tgz
DERPER_PATH=$(find . -type f -name "derper" | head -n 1 || true)
if [[ -f "$DERPER_PATH" ]]; then
  cp "$DERPER_PATH" /usr/local/bin/derper
else
  git clone --depth=1 https://ghproxy.cn/https://github.com/tailscale/tailscale.git /tmp/tailscale-src
  cd /tmp/tailscale-src/cmd/derper
  go build
  cp derper /usr/local/bin/
  rm -rf /tmp/tailscale-src
fi
chmod +x /usr/local/bin/derper
systemctl restart derper
EOF
  chmod +x /usr/local/bin/derper-autoupdate.sh
  (crontab -l 2>/dev/null; echo "0 5 * * 1 /usr/local/bin/derper-autoupdate.sh >/dev/null 2>&1") | crontab -
}

# ──────────────── 安装 td ────────────────
install_td(){
  info "安装命令行管理工具 td..."
  wget -q -O /usr/local/bin/td "https://ghproxy.cn/${REPO}/td"
  chmod +x /usr/local/bin/td
}

# ──────────────── 主流程 ────────────────
main(){
  check_root
  detect_os
  install_deps
  choose_domain_and_ip
  check_cloudflare
  install_tailscale
  install_latest_go
  install_derper
  create_service
  setup_autoupdate
  install_td
  info "✅ 安装完成！输入 td 管理 DERP 服务。"
}

main "$@"
