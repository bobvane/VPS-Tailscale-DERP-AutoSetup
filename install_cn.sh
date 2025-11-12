#!/usr/bin/env bash
# install_cn.sh v4.0-pro
# 作者: bobvane (为 文波 定制)
# 说明: 生产级一键部署脚本 — Debian 12 专用
# 功能概览:
#  - 系统检测 & 更新
#  - 安装常用基础工具 (包含 certbot, chrony, etc.)
#  - 设置时区与时间同步
#  - 启用 BBR 并持久化
#  - 清理系统缓存
#  - 使用 80 端口申请 Let's Encrypt 证书（certbot standalone）
#  - 申请证书成功后再启动 DERP (443)，否则回退自签
#  - 安装 tailscale、Go、derper（官方包或源码编译）
#  - 安装 td 管理工具
#  - 创建自动续签 cron 任务
#  - 提供可选卸载/回滚（包含是否回退系统级优化）
#
# 运行: sudo bash install_cn.sh

set -euo pipefail
export LANG=zh_CN.UTF-8

# -------------------- 彩色输出 --------------------
RED=$(tput setaf 1) || true
GREEN=$(tput setaf 2) || true
YELLOW=$(tput setaf 3) || true
CYAN=$(tput setaf 6) || true
RESET=$(tput sgr0) || true

info(){ echo -e "${GREEN}[INFO]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERROR]${RESET} $*"; }

# -------------------- 基本变量 --------------------
REPO_RAW="https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main"
GO_VER="go1.25.4"
GO_URL="https://mirrors.aliyun.com/golang/${GO_VER}.linux-amd64.tar.gz"
GHPROXY_GIT_PREFIX="https://ghproxy.cn/https://github.com"

DERP_CERTDIR="/var/lib/derper/certs"
DERP_WORKDIR="/opt/derper"
TD_PATH="/usr/local/bin/td"

CRON_FILE="/etc/cron.d/derper-renew"

# -------------------- 权限检查 --------------------
if [[ $EUID -ne 0 ]]; then
  err "请使用 root 权限运行此脚本"
  exit 1
fi

# -------------------- 系统检测: 仅支持 Debian 12 --------------------
os_name="$(. /etc/os-release && echo "$ID")"
os_version="$(. /etc/os-release && echo "$VERSION_ID")"
if [[ "$os_name" != "debian" || "$os_version" != "12" ]]; then
  err "当前仅支持 Debian 12 (bookworm)。检测到: $os_name $os_version 。"
  exit 1
fi
info "系统检测通过：Debian 12"

# -------------------- 交互输入 --------------------
read -rp "请输入要绑定的域名（例如 derp.bobvane.top）: " DOMAIN
[[ -z "$DOMAIN" ]] && { err "域名不能为空"; exit 1; }
read -rp "请输入服务器公网 IP（留空自动检测）: " SERVER_IP
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP="$(curl -fsSL https://ifconfig.me || curl -fsSL https://ipinfo.io/ip || true)"
fi
info "域名: $DOMAIN"
info "服务器 IP: $SERVER_IP"

# -------------------- 1. 系统更新 与 基础工具安装 --------------------
system_prepare(){
  info "开始系统更新并安装基础工具 (apt update && upgrade)"
  apt update -y
  apt upgrade -y

  info "安装常用基础命令与生产工具 (curl wget git jq dnsutils socat tar ca-certificates bc)"
  apt install -y curl wget git jq dnsutils socat tar ca-certificates bc lsb-release

  info "安装 certbot 与 chrony (时间同步)"
  apt install -y certbot chrony
}

# -------------------- 2. 时区 与 时间同步 --------------------
setup_time(){
  info "设置时区为 Asia/Shanghai 并启用 chrony 同步"
  timedatectl set-timezone Asia/Shanghai || true
  systemctl enable chrony
  systemctl restart chrony
  info "当前时间：$(timedatectl status --no-pager | grep 'Local time' || date)"
}

# -------------------- 3. 启用 BBR (并持久化) --------------------
enable_bbr(){
  info "启用 BBR 加速并持久化 /etc/sysctl.d/99-bbr.conf"
  cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOF
  sysctl --system >/dev/null 2>&1 || true
  info "BBR 已启用 (若内核支持)"
  # 显示当前拥塞控制算法
  sysctl net.ipv4.tcp_congestion_control || true
}

# -------------------- 4. 清理无用缓存 --------------------
system_cleanup(){
  info "清理 apt 缓存与不再需要的包"
  apt autoremove -y || true
  apt clean || true
}

# -------------------- 清理/卸载: 停止服务并删除项目文件 --------------------
project_cleanup(){
  info "停止并清理本项目相关服务与文件（保留系统软件）..."
  systemctl stop derper tailscaled 2>/dev/null || true
  systemctl disable derper 2>/dev/null || true
  killall derper 2>/dev/null || true

  rm -f /etc/systemd/system/derper.service
  systemctl daemon-reload || true

  rm -rf /opt/derper /var/lib/derper /usr/local/bin/derper /tmp/tailscale-src
  rm -f /usr/local/bin/td
  rm -f "$CRON_FILE"
  info "项目文件已清理"
}

# -------------------- 询问是否回退系统优化 --------------------
rollback_system(){
  echo
  read -rp "是否需要回退系统级改动（BBR、chrony 设置等）？(y/N): " ans
  if [[ "${ans,,}" == "y" ]]; then
    info "回退 BBR (删除 /etc/sysctl.d/99-bbr.conf) 并重载 sysctl"
    rm -f /etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null 2>&1 || true

    info "禁用 chrony（但不卸载）"
    systemctl stop chrony || true
    systemctl disable chrony || true

    info "清理 certbot 证书 (仅本项目域名)"
    certbot delete --cert-name "$DOMAIN" || true

    info "系统回退完成（请根据需要手动检查）"
  else
    info "保留系统级改动（BBR/chrony）"
  fi
}

# -------------------- 5. 安装 tailscale --------------------
install_tailscale(){
  info "安装 Tailscale (官方源)"
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt update -y
  apt install -y tailscale || true
  info "tailscale 安装完成（或已存在）"
}

# -------------------- 6. 安装 Go (固定版本, 阿里云镜像) --------------------
install_go(){
  info "下载并安装 Go (${GO_VER})"
  wget -q -O /tmp/go.tar.gz "$GO_URL" || { err "Go 下载失败，请检查网络或手动放 /tmp/go.tar.gz"; exit 1; }
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/99-go-path.sh
  export PATH=/usr/local/go/bin:$PATH
  info "Go 已安装: $(go version || true)"
}

# -------------------- 7. 申请证书 (80端口, certbot standalone), 带等待和重试 --------------------
issue_cert_via_80(){
  info "开始使用 certbot (standalone, HTTP-01) 为 ${DOMAIN} 签发证书 (会占用 80 端口)"
  mkdir -p "$DERP_CERTDIR"
  # 确保 derper 不占 80/443
  systemctl stop derper 2>/dev/null || true
  killall derper 2>/dev/null || true
  fuser -k 80/tcp 2>/dev/null || true

  # 运行 certbot
  CERT_SUCCESS=0
  MAX_ATTEMPTS=3
  for attempt in $(seq 1 $MAX_ATTEMPTS); do
    info "certbot attempt ${attempt}/${MAX_ATTEMPTS} ..."
    # 保守模式：非交互，信任 tos，指定邮件
    if certbot certonly --standalone --preferred-challenges http \
        --agree-tos -m "admin@${DOMAIN}" -d "${DOMAIN}" --non-interactive; then
      CERT_SUCCESS=1
      break
    else
      warn "certbot 第 ${attempt} 次尝试失败，稍后重试..."
      sleep 3
    fi
  done

  if [[ "$CERT_SUCCESS" -ne 1 ]]; then
    warn "⚠️ certbot 多次尝试未成功，将回退为自签证书。"
    generate_self_signed_cert
    return 1
  fi

  # 等待证书文件真正写入 (最多等待 60s)
  info "等待 certbot 写入文件..."
  for i in {1..30}; do
    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" && -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
      info "certbot 已生成证书文件"
      break
    fi
    sleep 2
  done

  if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    warn "证书文件未生成或超时，将回退为自签证书"
    generate_self_signed_cert
    return 1
  fi

  # 拷贝到 derper certdir
  cp /etc/letsencrypt/live/"${DOMAIN}"/fullchain.pem "${DERP_CERTDIR}/${DOMAIN}.crt"
  cp /etc/letsencrypt/live/"${DOMAIN}"/privkey.pem "${DERP_CERTDIR}/${DOMAIN}.key"
  chmod 640 "${DERP_CERTDIR}/${DOMAIN}.key" || true
  info "✅ 已将 Certbot 证书复制到 ${DERP_CERTDIR}"
  return 0
}

# -------------------- 生成自签证书 (fallback) --------------------
generate_self_signed_cert(){
  info "生成自签证书 (fallback) ..."
  mkdir -p "$DERP_CERTDIR"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${DERP_CERTDIR}/${DOMAIN}.key" \
    -out "${DERP_CERTDIR}/${DOMAIN}.crt" \
    -subj "/CN=${DOMAIN}" -days 3650
  chmod 640 "${DERP_CERTDIR}/${DOMAIN}.key" || true
  info "✅ 自签证书已生成: ${DERP_CERTDIR}/${DOMAIN}.crt"
}

# -------------------- 8. 安装 derper（二进制或源码编译） --------------------
install_derper(){
  info "开始安装 derper (先尝试官方包, 若无则源码编译)"
  mkdir -p "$DERP_WORKDIR" "$DERP_CERTDIR"
  cd "$DERP_WORKDIR" || true

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
    info "✅ 已安装 derper (来自官方包): /usr/local/bin/derper"
  else
    warn "官方包未包含 derper，开始源码编译 (使用 ghproxy 加速)"
    rm -rf /tmp/tailscale-src && mkdir -p /tmp/tailscale-src
    if ! git clone --depth=1 "${GHPROXY_GIT_PREFIX}/tailscale/tailscale.git" /tmp/tailscale-src; then
      err "克隆 tailscale 源码失败"
      exit 1
    fi
    cd /tmp/tailscale-src/cmd/derper || { err "源码目录异常"; exit 1; }
    /usr/local/go/bin/go build -o /usr/local/bin/derper . || { err "derper 编译失败"; exit 1; }
    chmod +x /usr/local/bin/derper
    info "✅ derper 已从源码编译并安装：/usr/local/bin/derper"
  fi
}

# -------------------- 9. 创建 systemd 服务 (使用 manual 模式, 因为我们已在前面放好证书) --------------------
create_service(){
  info "创建 systemd 服务: /etc/systemd/system/derper.service"
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

# -------------------- 10. 安装 td 管理工具 --------------------
install_td(){
  info "安装 td 管理工具到 /usr/local/bin/td"
  # 如果需要改内容，请替换下面的 raw 链接
  wget -q -O /usr/local/bin/td "${REPO_RAW}/td" || { warn "下载 td 失败，稍后可以手动安装"; return 0; }
  chmod +x /usr/local/bin/td
  info "✅ td 已安装"
}

# -------------------- 11. 自动续签任务 --------------------
setup_auto_renew(){
  info "创建自动续签任务 (每周一凌晨 3 点尝试续签)"
  cat >"$CRON_FILE" <<EOF
0 3 * * 1 root certbot renew --quiet && systemctl restart derper
EOF
  chmod 644 "$CRON_FILE"
  info "自动续签任务已创建: $CRON_FILE"
}

# -------------------- 12. 主流程 --------------------
main(){
  # 1 系统准备
  system_prepare
  setup_time
  enable_bbr
  system_cleanup

  # 2 清理老旧残留
  project_cleanup

  # 3 安装 tailscale 与 go
  install_tailscale
  install_go

  # 4 申请证书（80端口）
  if issue_cert_via_80; then
    info "证书获取成功，使用 Certbot 证书"
  else
    warn "使用自签证书"
  fi

  # 5 安装 derper（此时证书已位于 ${DERP_CERTDIR}）
  install_derper

  # 6 创建 systemd 单元（手动模式，证书应已存在）
  create_service

  # 7 安装 td 管理器
  install_td

  # 8 自动续签设置
  setup_auto_renew

  # 9 启动 derper
  info "尝试启动 derper..."
  systemctl start derper
  sleep 3
  systemctl is-active --quiet derper && info "✅ derper 已启动并运行" || warn "derper 未能启动，请查看日志: journalctl -u derper -n 50 --no-pager"

  info "部署完成！使用命令: systemctl status derper 查看状态，使用 td 管理（若已安装）"
}

# -------------------- 13. 提示与卸载接口 --------------------
echo
info "即将开始部署：${DOMAIN} -> ${SERVER_IP}"
read -rp "确认继续部署吗？(y/N): " CONF
if [[ "${CONF,,}" != "y" ]]; then
  info "已取消"
  exit 0
fi

main

echo
info "如果需要卸载本项目，请运行此脚本并选择清理选项。"
read -rp "现在是否要执行卸载清理示例？(n=否, y=是): " need_uninstall
if [[ "${need_uninstall,,}" == "y" ]]; then
  project_cleanup
  read -rp "是否回退系统级改动（BBR/chrony/Certbot 删除）？(y/N): " rb
  if [[ "${rb,,}" == "y" ]]; then
    rollback_system
  fi
fi

info "脚本执行结束。"
