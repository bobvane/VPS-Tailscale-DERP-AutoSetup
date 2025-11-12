#!/usr/bin/env bash
# install_cn.sh v4.2-fixed
# 目的：修复卡住、强制域名必须输入 + 恢复可控 Go 下载逻辑
# 作者: bobvane
# 说明：在你现有的 v4.x 基础上仅做必要修复与增强控制，不改变已稳定逻辑。

set -euo pipefail
export LANG=zh_CN.UTF-8

# ---------- 颜色 ----------
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

info(){ echo -e "${GREEN}[INFO]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERROR]${RESET} $*"; }

# ---------- 可配置项（环境变量可覆盖） ----------
# 如果想使用自定义 Go 下载链接，在运行脚本前 export GO_URL_OVERRIDE=...
GO_VER="${GO_VER:-go1.25.4}"
DEFAULT_GO_URL="https://go.dev/dl/${GO_VER}.linux-amd64.tar.gz"
ALIYUN_GO_URL="https://mirrors.aliyun.com/golang/${GO_VER}.linux-amd64.tar.gz"
TUNA_GO_URL="https://mirrors.tuna.tsinghua.edu.cn/golang/${GO_VER}.linux-amd64.tar.gz"
HUAWEI_GO_URL="https://mirrors.huaweicloud.com/golang/${GO_VER}.linux-amd64.tar.gz"
GO_URL_OVERRIDE="${GO_URL_OVERRIDE:-}"
SKIP_GO="${SKIP_GO:-0}"  # 设置为1可跳过Go安装（例如你已手动安装）

REPO_RAW="https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main"
GHPROXY_GIT_PREFIX="https://ghproxy.cn/https://github.com"

DERP_CERTDIR="/var/lib/derper/certs"
DERP_WORKDIR="/opt/derper"
TD_PATH="/usr/local/bin/td"
CRON_FILE="/etc/cron.d/derper-renew"

# ---------- 权限/系统检查 ----------
if [[ $EUID -ne 0 ]]; then
  err "请使用 root 用户执行此脚本。"
  exit 1
fi

if ! grep -q "VERSION_ID=\"12\"" /etc/os-release 2>/dev/null; then
  warn "检测到非 Debian 12 系统，脚本设计以 Debian 12 为主，继续可能有风险。"
  read -rp "仍要继续执行吗？(y/N): " _yn
  [[ "${_yn,,}" == "y" ]] || { info "取消执行"; exit 1; }
fi

# ---------- 基础函数 ----------
_safe_wait_for_file(){
  # usage: _safe_wait_for_file /path/to/file timeout_seconds
  local file="$1"; local timeout="${2:-60}"; local n=0
  while [[ ! -f "$file" && $n -lt $timeout ]]; do
    sleep 1; n=$((n+1))
  done
  [[ -f "$file" ]]
}

detect_public_ip(){
  local ip
  ip="$(curl -fsSL https://ifconfig.me 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -fsSL https://ipinfo.io/ip 2>/dev/null || true)"
  fi
  echo "$ip"
}

# ---------- 用户输入：域名必须输入（循环直到有效） ----------
while true; do
  read -rp "请输入绑定的域名（必须，例: derp.bobvane.top）: " DOMAIN
  DOMAIN="${DOMAIN// /}"  # trim spaces
  if [[ -z "$DOMAIN" ]]; then
    echo -e "${YELLOW}域名不能为空，请输入。${RESET}"
    continue
  fi
  # 简单校验：包含点，且长度>3
  if [[ "${#DOMAIN}" -lt 4 || "$DOMAIN" != *.* ]]; then
    echo -e "${YELLOW}域名格式看起来不对，请重新输入${RESET}"
    continue
  fi
  # 尝试解析 A 记录
  DIG_IP="$(dig +short A "$DOMAIN" | tail -n1 || true)"
  if [[ -z "$DIG_IP" ]]; then
    echo -e "${YELLOW}域名未解析到 A 记录 (dig 返回空)。${RESET}"
    read -rp "是否仍然继续（通常需要先把域名解析到服务器）？(y/N): " _c
    if [[ "${_c,,}" == "y" ]]; then
      break
    else
      continue
    fi
  fi
  # 自动检测本机公网IP
  PUB_IP="$(detect_public_ip)"
  if [[ -n "$PUB_IP" && "$DIG_IP" != "$PUB_IP" ]]; then
    echo -e "${YELLOW}注意: 域名 $DOMAIN 解析到 $DIG_IP，检测到本机公网 IP 为 $PUB_IP。${RESET}"
    read -rp "解析不匹配，是否继续？(y/N): " _c2
    if [[ "${_c2,,}" == "y" ]]; then
      break
    else
      continue
    fi
  fi
  # all good (or user confirmed)
  break
done

# 公网IP（可选输入）
read -rp "请输入服务器公网 IP（可留空自动检测）: " SERVER_IP
if [[ -z "$SERVER_IP" ]]; then
  SERVER_IP="$(detect_public_ip || true)"
fi
info "域名: $DOMAIN"
info "服务器公网 IP: ${SERVER_IP:-(未检测到)}"

# ---------- 安装/准备环境（保持之前稳定逻辑） ----------
info "系统更新 & 安装基础依赖..."
apt update -y
apt install -y curl wget git jq dnsutils socat tar ca-certificates bc lsb-release unzip certbot chrony

info "设置时区 Asia/Shanghai，启用 chrony 同步..."
timedatectl set-timezone Asia/Shanghai || true
systemctl enable chrony || true
systemctl restart chrony || true

info "启用 BBR (若支持)..."
if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf 2>/dev/null; then
  cat >>/etc/sysctl.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
fi

# ---------- tailscale 安装 ----------
info "安装 tailscale（官方源）..."
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
  | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
  | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
apt update -y
apt install -y tailscale || true

# ---------- Go 安装（可控） ----------
if [[ "${SKIP_GO}" == "1" ]]; then
  info "SKIP_GO=1，跳过 Go 安装（假设已安装或你将手动处理）"
else
  # 优先使用用户覆盖的 URL
  if [[ -n "${GO_URL_OVERRIDE}" ]]; then
    GO_URL="${GO_URL_OVERRIDE}"
  else
    # 优先用阿里云镜像（国内环境优先）
    GO_URL="${ALIYUN_GO_URL}"
  fi
  info "准备下载 Go：${GO_URL}"
  if wget -q -O /tmp/go.tar.gz "${GO_URL}"; then
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/99-go-path.sh
    export PATH=/usr/local/go/bin:$PATH
    info "Go 已安装：$(go version || true)"
  else
    warn "Go 下载失败（${GO_URL}）。你可以手动设置 GO_URL_OVERRIDE 再试或手动安装 Go。脚本将继续（可能需要 Go 仅在源码编译 derper 时使用）。"
  fi
fi

# ---------- 获取/安装 derper（保持旧逻辑：先尝试官方包，再源码编译） ----------
info "安装 derper（尝试官方包，失败时走源码编译）..."
mkdir -p "${DERP_WORKDIR}" "${DERP_CERTDIR}"
cd "${DERP_WORKDIR}" || true

# 尝试官方包 download（若官方没有提供 derper 二进制这里可能失败，回退源码编译）
# 我们使用 ghproxy 加速 GitHub releases 获取
DERPER_TGZ_URL="https://ghproxy.cn/https://github.com/tailscale/tailscale/releases/latest/download/derper_linux_amd64.tgz"
info "尝试使用：${DERPER_TGZ_URL}"
if wget -q -O derper.tgz "${DERPER_TGZ_URL}"; then
  tar -xzf derper.tgz 2>/dev/null || true
  if [[ -f ./derper ]]; then
    cp ./derper /usr/local/bin/derper
    chmod +x /usr/local/bin/derper
    info "已安装 derper（官方包）"
  fi
fi

if ! command -v /usr/local/bin/derper >/dev/null 2>&1; then
  warn "未检测到 derper 二进制，准备源码编译（需要 go）..."
  rm -rf /tmp/tailscale-src && mkdir -p /tmp/tailscale-src
  if ! git clone --depth=1 "${GHPROXY_GIT_PREFIX}/tailscale/tailscale.git" /tmp/tailscale-src; then
    err "克隆 tailscale 源码失败"
    # 继续，但提示用户手动处理
  else
    if command -v go >/dev/null 2>&1; then
      cd /tmp/tailscale-src/cmd/derper || true
      /usr/local/go/bin/go build -o /usr/local/bin/derper . || { err "derper 编译失败"; }
      chmod +x /usr/local/bin/derper || true
      info "derper 已从源码编译安装"
    else
      warn "系统未检测到 go，源码编译无法执行（需手动安装 go 或使用官方包）。"
    fi
  fi
fi

# ---------- 证书申请（使用 certbot HTTP-01, 80端口），并确保写入再启动 derper ----------
info "为 ${DOMAIN} 申请 LetsEncrypt 证书（使用 HTTP-01，80端口）..."
# 先确保没有占用 80/443 的进程
systemctl stop derper 2>/dev/null || true
fuser -k 80/tcp 2>/dev/null || true

CERT_SUCCESS=0
for attempt in 1 2 3; do
  info "certbot 尝试 ${attempt}/3 ..."
  if certbot certonly --standalone --preferred-challenges http --agree-tos \
       -m "admin@${DOMAIN}" -d "${DOMAIN}" --non-interactive; then
    CERT_SUCCESS=1
    break
  else
    warn "certbot 第 ${attempt} 次尝试失败，稍后重试..."
    sleep 2
  fi
done

if [[ "$CERT_SUCCESS" -eq 1 ]]; then
  info "等待证书文件写入..."
  if _safe_wait_for_file "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" 60; then
    mkdir -p "${DERP_CERTDIR}"
    cp /etc/letsencrypt/live/"${DOMAIN}"/fullchain.pem "${DERP_CERTDIR}/${DOMAIN}.crt"
    cp /etc/letsencrypt/live/"${DOMAIN}"/privkey.pem "${DERP_CERTDIR}/${DOMAIN}.key"
    chmod 640 "${DERP_CERTDIR}/${DOMAIN}.key" || true
    info "证书已拷贝到 ${DERP_CERTDIR}"
  else
    warn "证书写入超时，采用自签证书作为回退"
    mkdir -p "${DERP_CERTDIR}"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout "${DERP_CERTDIR}/${DOMAIN}.key" \
      -out "${DERP_CERTDIR}/${DOMAIN}.crt" -subj "/CN=${DOMAIN}" -days 3650
    chmod 640 "${DERP_CERTDIR}/${DOMAIN}.key" || true
  fi
else
  warn "certbot 多次失败，使用自签证书回退"
  mkdir -p "${DERP_CERTDIR}"
  openssl req -x509 -nodes -newkey rsa:2048 -keyout "${DERP_CERTDIR}/${DOMAIN}.key" \
    -out "${DERP_CERTDIR}/${DOMAIN}.crt" -subj "/CN=${DOMAIN}" -days 3650
  chmod 640 "${DERP_CERTDIR}/${DOMAIN}.key" || true
fi

# ---------- 创建 systemd unit（certdir 已存在或自签已生成） ----------
info "创建 systemd 单元 /etc/systemd/system/derper.service ..."
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

# ---------- 安装 td（保证 heredoc 正确关闭，避免卡死） ----------
info "安装 td 管理工具（/usr/local/bin/td）..."
cat >"${TD_PATH}" <<'EOF'
#!/usr/bin/env bash
# td v1.5 简化版（交互式）
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
RED=$(tput setaf 1 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

info(){ echo -e "${GREEN}[INFO]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERROR]${RESET} $*"; }

DERP_SERVICE="derper"
TAILSCALE_SERVICE="tailscaled"
DERP_CERTDIR="/var/lib/derper/certs"
DERP_SYSUNIT="/etc/systemd/system/derper.service"

_pause(){ read -rp $'\n按回车返回'; }

menu(){
  clear
  echo -e "${CYAN}=== td v1.5 — DERP & Tailscale 管理工具 ===${RESET}"
  echo "1) 查看 DERP 服务状态"
  echo "2) 重启 DERP 服务"
  echo "3) 停止 DERP 服务"
  echo "4) 查看 tailscaled 状态"
  echo "5) 生成 derpmap.json (并保存到 /etc/tailscale/derpmap.json)"
  echo "6) 查看证书 & 到期时间"
  echo "7) 注册 Tailscale 客户端 (tailscale up)"
  echo "8) 触发 certbot renew 并重启 derper"
  echo "9) 卸载本项目（清理文件）"
  echo "0) 退出"
  read -rp "请选择: " opt
  case "$opt" in
    1) systemctl status ${DERP_SERVICE} --no-pager || true; _pause; menu ;;
    2) systemctl restart ${DERP_SERVICE} && info "已重启"; _pause; menu ;;
    3) systemctl stop ${DERP_SERVICE} && info "已停止"; _pause; menu ;;
    4) systemctl status ${TAILSCALE_SERVICE} --no-pager || true; if command -v tailscale >/dev/null 2>&1; then tailscale status || true; fi; _pause; menu ;;
    5)
  read -rp "RegionID (默认 900): " r; r=${r:-900}
  read -rp "RegionCode (默认 CN): " rc; rc=${rc:-CN}
  read -rp "DERP 主机 (域名): " host
  read -rp "DERP IPv4: " ip

  mkdir -p /etc/tailscale

  cat > /etc/tailscale/derpmap.json <<EOF
{
  "Regions": {
    "${r}": {
      "RegionID": ${r},
      "RegionCode": "${rc}",
      "RegionName": "China Private DERP",
      "Nodes": [
        {
          "Name": "${host}",
          "RegionID": ${r},
          "HostName": "${host}",
          "IPv4": "${ip}",
          "STUNPort": 3478,
          "DERPPort": 443
        }
      ]
    }
  }
}
EOF

  if [[ -s /etc/tailscale/derpmap.json ]]; then
    info "✅ 已成功生成 /etc/tailscale/derpmap.json"
  else
    warn "⚠️ 生成失败，请检查写入权限或路径。"
  fi
  _pause; menu
  ;;

    6) ls -l ${DERP_CERTDIR} 2>/dev/null || true; if [[ -f ${DERP_CERTDIR}/*.crt ]]; then openssl x509 -in ${DERP_CERTDIR}/*.crt -noout -dates || true; fi; _pause; menu ;;
    7) systemctl start tailscaled 2>/dev/null || true; if ! command -v tailscale >/dev/null 2>&1; then err "未检测到 tailscale"; _pause; menu; fi; echo "将执行: tailscale up --ssh"; read -rp "确认执行并显示认证链接？(y/N): " c; if [[ ${c,,} == "y" ]]; then tailscale up --ssh || true; fi; _pause; menu ;;
    8) if command -v certbot >/dev/null 2>&1; then certbot renew --quiet || warn "renew 返回非0"; fi; systemctl restart ${DERP_SERVICE} || warn "重启失败"; _pause; menu ;;
    9) read -rp "确认删除 derper 与 td 文件? (y/N): " yn; if [[ ${yn,,} == "y" ]]; then systemctl stop derper 2>/dev/null || true; systemctl disable derper 2>/dev/null || true; rm -f /etc/systemd/system/derper.service; systemctl daemon-reload || true; rm -rf /opt/derper /var/lib/derper /usr/local/bin/derper /usr/local/bin/td /etc/tailscale/derpmap.json /etc/cron.d/derper-renew; info "已删除"; exit 0; fi; _pause; menu ;;
    0) exit 0 ;;
    *) echo "无效选项"; _pause; menu ;;
  esac
}

menu
EOF

# 确保 td 可执行
chmod +x "${TD_PATH}" || true
info "td 已安装到 ${TD_PATH}"

# ---------- 创建自动续签 cron ---------- 
info "创建自动续签任务（每周一 03:00）..."
cat >"${CRON_FILE}" <<'EOF'
0 3 * * 1 root certbot renew --quiet && systemctl restart derper
EOF
chmod 644 "${CRON_FILE}" || true
info "自动续签已创建: ${CRON_FILE}"

# ---------- 启动 derper ----------
info "尝试启动 derper 服务..."
systemctl start derper || true
sleep 2
if systemctl is-active --quiet derper; then
  info "✅ derper 已启动并运行"
else
  warn "derper 未完全启动，请查看日志：journalctl -u derper -n 50 --no-pager"
fi

info "脚本执行结束。请运行 ${CYAN}td${RESET} 并选择“注册 Tailscale 客户端”（菜单项 7）完成登录。"
exit 0
