#!/usr/bin/env bash
# install_cn.sh v1.8 - VPS-Tailscale-DERP-AutoSetup (智能多源测速版)
# 特性：
#  - 多镜像测速并自动选最快 Go 镜像下载
#  - 自动卸载系统旧 Go 并强制使用 /usr/local/go
#  - 自动设置 GOPROXY=https://goproxy.cn,direct
#  - 官方 tailscale 源（直连） + 国内加速 GitHub fetch
#  - 完整自动化：一键安装 / 编译 / 启动 / 安装 td 管理工具

set -euo pipefail
LANG=zh_CN.UTF-8
export LANG

REPO="https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main"

# ---------- 彩色输出 ----------
c_red(){ tput setaf 1 2>/dev/null || true; }
c_green(){ tput setaf 2 2>/dev/null || true; }
c_yellow(){ tput setaf 3 2>/dev/null || true; }
c_reset(){ tput sgr0 2>/dev/null || true; }

info(){ c_green; echo "[INFO] $*"; c_reset; }
warn(){ c_yellow; echo "[WARN] $*"; c_reset; }
err(){ c_red; echo "[ERROR] $*"; c_reset; }

# ---------- 权限检查 ----------
check_root(){
  if [[ $EUID -ne 0 ]]; then
    err "请以 root 权限运行此脚本。"
    exit 1
  fi
}

# ---------- 清理旧环境 ----------
cleanup_old(){
  info "🧹 检测并清理旧版安装..."
  systemctl stop derper 2>/dev/null || true
  systemctl disable derper 2>/dev/null || true
  rm -f /etc/systemd/system/derper.service
  systemctl daemon-reload || true

  rm -rf /opt/derper /tmp/tailscale-src /usr/local/bin/derper /usr/local/bin/derper-autoupdate.sh
  rm -rf /usr/local/go /tmp/go.tar.gz /etc/profile.d/go-path.sh /etc/profile.d/99-go-path.sh
  sed -i '/go\/bin/d' ~/.bashrc 2>/dev/null || true

  rm -f /etc/apt/sources.list.d/tailscale.list /usr/share/keyrings/tailscale-archive-keyring.gpg
  rm -f /usr/local/bin/td

  apt remove -y golang-go golang-1.* golang >/dev/null 2>&1 || true
  apt autoremove -y >/dev/null 2>&1 || true
  info "✅ 旧环境清理完成。"
}

# ---------- 系统检测 ----------
detect_os(){
  . /etc/os-release
  info "检测到系统：${PRETTY_NAME}"
  info "启用国内加速模式（Go 镜像测速 + GOPROXY）"
}

# ---------- 依赖安装 ----------
install_deps(){
  info "安装依赖环境..."
  apt update -y
  apt install -y curl wget git jq dnsutils cron socat ca-certificates lsb-release tar
}

# ---------- 用户输入 ----------
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

# ---------- 安装 tailscale (官方源) ----------
install_tailscale(){
  info "安装 tailscale（使用官方源）..."
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt update -y && apt install -y tailscale
}

# ---------- 获取并选择最快的 Go 镜像 ----------
get_latest_go_version_and_source(){
  info "获取最新 Go 版本号并在镜像源中测速..."
  # 镜像列表（可扩展）
  sources=(
    "https://mirrors.aliyun.com/golang/VERSION?m=text"
    "https://mirrors.tuna.tsinghua.edu.cn/golang/VERSION?m=text"
    "https://mirrors.huaweicloud.com/golang/VERSION?m=text"
    "https://go.dev/VERSION?m=text"
  )

  best_ver=""
  best_src=""
  best_time=999999

  for src in "${sources[@]}"; do
    start=$(date +%s%3N 2>/dev/null || date +%s000)
    # 连接与读取时间控制，短超时避免卡住
    ver=$(curl -s --connect-timeout 3 --max-time 5 "$src" | head -n1 || true)
    end=$(date +%s%3N 2>/dev/null || date +%s000)
    elapsed=$((end-start))
    if [[ -n "$ver" ]]; then
      info "测速：$src → ${elapsed}ms （$ver）"
      if (( elapsed < best_time )); then
        best_time=$elapsed
        best_ver="$ver"
        best_src="$src"
      fi
    else
      warn "测速：$src → 超时/失败"
    fi
  done

  if [[ -z "$best_ver" ]]; then
    err "无法从镜像或官方获取 Go 版本，尝试使用官方默认地址..."
    # 最后兜底尝试官方（可能会失败，但让调用者决定）
    best_ver=$(curl -fsSL --connect-timeout 5 --max-time 6 "https://go.dev/VERSION?m=text" || true)
    best_src="https://go.dev"
  fi

  if [[ -z "$best_ver" ]]; then
    err "获取 Go 版本失败，请检查网络。"
    exit 1
  fi

  # 输出选中信息并导出两个变量
  info "选用最快源：$best_src ，版本：$best_ver"
  echo "$best_ver|$best_src"
}

# ---------- 安装 Go（使用选中的镜像源下载） ----------
install_go_by_source(){
  local ver="$1"
  local src="$2"
  info "准备从镜像下载 Go ${ver} (source: ${src})"
  # 根据源构建下载 URL（兼容常见镜像路径）
  # src 可能是带路径的 VERSION URL 或 go.dev
  # 尝试若为镜像根则构造对应 tar.gz URL
  if [[ "$src" =~ mirrors.aliyun.com ]]; then
    url="https://mirrors.aliyun.com/golang/${ver}.linux-amd64.tar.gz"
  elif [[ "$src" =~ tuna.tsinghua.edu.cn ]]; then
    url="https://mirrors.tuna.tsinghua.edu.cn/golang/${ver}.linux-amd64.tar.gz"
  elif [[ "$src" =~ huaweicloud.com ]]; then
    url="https://mirrors.huaweicloud.com/golang/${ver}.linux-amd64.tar.gz"
  else
    url="https://go.dev/dl/${ver}.linux-amd64.tar.gz"
  fi

  info "尝试下载：$url"
  # 下载三路尝试：首选构造好的 url，再 fallback 到清华/阿里/官方
  wget --connect-timeout=10 -q -O /tmp/go.tar.gz "$url" || \
  wget --connect-timeout=10 -q -O /tmp/go.tar.gz "https://mirrors.aliyun.com/golang/${ver}.linux-amd64.tar.gz" || \
  wget --connect-timeout=10 -q -O /tmp/go.tar.gz "https://mirrors.tuna.tsinghua.edu.cn/golang/${ver}.linux-amd64.tar.gz" || \
  wget --connect-timeout=10 -q -O /tmp/go.tar.gz "https://go.dev/dl/${ver}.linux-amd64.tar.gz"

  if [[ ! -s /tmp/go.tar.gz ]]; then
    err "下载 Go 包失败（所有镜像均不可用）"
    exit 1
  fi

  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz

  # 删除系统旧 go 包并强制使用 /usr/local/go
  apt remove -y golang-go golang-1.* golang >/dev/null 2>&1 || true
  echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/99-go-path.sh
  export PATH=/usr/local/go/bin:$PATH

  info "✅ Go 环境就绪：$(go version)"
}

# ---------- 设置 Go 模块代理 ----------
setup_goproxy(){
  info "配置 Go 模块代理(goproxy.cn)..."
  go env -w GOPROXY=https://goproxy.cn,direct
  go env -w GOSUMDB=off
  info "✅ Go 模块代理已生效：$(go env GOPROXY)"
}

# ---------- 安装 derper ----------
install_derper(){
  info "安装 derper..."
  mkdir -p /opt/derper && cd /opt/derper
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) asset_arch="amd64" ;;
    aarch64|arm64) asset_arch="arm64" ;;
    *) asset_arch="amd64" ;;
  esac

  latest_json=$(curl -s https://api.github.com/repos/tailscale/tailscale/releases/latest)
  version=$(echo "$latest_json" | jq -r '.tag_name' || true)
  if [[ -z "$version" ]]; then
    warn "无法获取 tailscale 最新版本信息，尝试使用默认版本名"
    version="v1.0.0"
  fi

  url="https://pkgs.tailscale.com/stable/tailscale_${version#v}_${asset_arch}.tgz"
  info "下载 tailscale 包: $url"
  wget --connect-timeout=15 -q -O tailscale.tgz "$url" || { err "下载 tailscale 包失败"; exit 1; }
  tar -xzf tailscale.tgz

  DERPER_PATH=$(find . -type f -name "derper" | head -n 1 || true)
  if [[ -f "$DERPER_PATH" ]]; then
    info "✅ 官方包包含 derper，路径：$DERPER_PATH"
    cp "$DERPER_PATH" /usr/local/bin/derper
  else
    warn "⚙️ 官方包未包含 derper，开始从源码编译..."
    rm -rf /tmp/tailscale-src
    # 使用 ghproxy 优先加速 git clone
    git clone --depth=1 https://ghproxy.cn/https://github.com/tailscale/tailscale.git /tmp/tailscale-src || \
    git clone --depth=1 https://kgithub.com/tailscale/tailscale.git /tmp/tailscale-src || \
    git clone --depth=1 https://github.com/tailscale/tailscale.git /tmp/tailscale-src
    cd /tmp/tailscale-src/cmd/derper
    info "使用 go 版本：$(go version) 开始编译 derper..."
    # 确保 GOPROXY 已设置
    go env -w GOPROXY=https://goproxy.cn,direct || true
    go env -w GOSUMDB=off || true
    go build
    cp derper /usr/local/bin/
    info "✅ derper 编译完成。"
  fi

  chmod +x /usr/local/bin/derper
  derper -h >/dev/null 2>&1 && info "✅ derper 验证通过。" || { err "derper 启动验证失败"; exit 1; }
}

# ---------- 创建 systemd 服务 ----------
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

# ---------- 安装 td ----------
install_td(){
  info "安装命令行管理工具 td..."
  wget -q -O /usr/local/bin/td "https://ghproxy.cn/${REPO}/td"
  chmod +x /usr/local/bin/td
}

# ---------- 主流程 ----------
main(){
  check_root
  detect_os
  cleanup_old
  install_deps
  choose_domain_and_ip
  check_dns
  install_tailscale

  # 获取最快 Go 版本并下载安装
  ver_src=$(get_latest_go_version_and_source)
  ver="${ver_src%%|*}"
  src="${ver_src#*|}"
  install_go_by_source "$ver" "$src"

  setup_goproxy
  install_derper
  create_service
  install_td

  info "✅ 安装完成！输入 td 管理 DERP 服务。"
}

main "$@"
