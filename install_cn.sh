#!/bin/bash
# ============================================================
# VPS-Tailscale-DERP-AutoSetup 中国优化版 v4.2-pro-fix
# 作者: bobvane / 文波协助
# 功能: 自动部署 DERP + BBR + 证书 + Tailscale + 管理菜单
# ============================================================

set -e

# ────────────────────────────── 配色定义 ──────────────────────────────
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
RESET="\033[0m"

info()  { echo -e "${GREEN}[INFO]${RESET} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error() { echo -e "${RED}[ERROR]${RESET} $1"; }

# ────────────────────────────── 系统检测 ──────────────────────────────
if ! grep -q "Debian GNU/Linux 12" /etc/os-release; then
  error "仅支持 Debian 12 系统。"
  exit 1
fi
info "检测到系统：Debian 12 (bookworm)"

# ────────────────────────────── 系统更新与基础优化 ──────────────────────────────
info "更新系统并安装依赖..."
apt update -y && apt upgrade -y
apt install -y curl wget git jq certbot chrony lsof unzip socat ufw vim

info "启用 BBR..."
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1
lsmod | grep bbr && info "BBR 启用成功"

info "设置时区与时间同步..."
timedatectl set-timezone Asia/Shanghai
systemctl enable chronyd --now
chronyc -a makestep >/dev/null 2>&1
info "时间同步完成。"

# ────────────────────────────── 清理旧环境 ──────────────────────────────
info "清理旧环境..."
systemctl stop derper 2>/dev/null || true
systemctl disable derper 2>/dev/null || true
rm -rf /opt/derper /usr/local/bin/derper /var/lib/derper /etc/systemd/system/derper.service

# ────────────────────────────── 交互信息 ──────────────────────────────
read -rp "请输入绑定的域名（例如 derp.bobvane.top）: " DOMAIN
read -rp "请输入服务器公网 IP（留空自动检测）: " SERVER_IP
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(curl -s https://ipinfo.io/ip || curl -s https://api.ip.sb/ip)
fi
info "域名：$DOMAIN"
info "IP：$SERVER_IP"

# ────────────────────────────── 申请证书 ──────────────────────────────
info "申请 Let’s Encrypt 证书..."
systemctl stop nginx 2>/dev/null || true
systemctl stop derper 2>/dev/null || true
fuser -k 80/tcp 2>/dev/null || true

if certbot certonly --standalone -d "$DOMAIN" --preferred-challenges http \
  --agree-tos -m admin@"$DOMAIN" --non-interactive; then
  info "✅ 证书申请成功"
else
  error "❌ 证书申请失败，请检查 80 端口和 DNS 解析"
  exit 1
fi

mkdir -p /var/lib/derper/certs
cp /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem /var/lib/derper/certs/"$DOMAIN".crt
cp /etc/letsencrypt/live/"$DOMAIN"/privkey.pem /var/lib/derper/certs/"$DOMAIN".key
info "证书文件已复制完成"

# ────────────────────────────── 安装 Tailscale ──────────────────────────────
info "安装 Tailscale..."
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
apt update -y
apt install -y tailscale

# ────────────────────────────── 安装 derper ──────────────────────────────
info "安装 derper..."
mkdir -p /opt/derper
cd /opt/derper
wget -q https://ghproxy.cn/https://github.com/tailscale/tailscale/releases/latest/download/derper_linux_amd64.tgz -O derper.tgz
tar -xzf derper.tgz
mv derper /usr/local/bin/derper
chmod +x /usr/local/bin/derper

# ────────────────────────────── 创建 systemd 服务 ──────────────────────────────
cat >/etc/systemd/system/derper.service <<EOF
[Unit]
Description=Tailscale DERP relay server
After=network.target

[Service]
ExecStart=/usr/local/bin/derper --hostname ${DOMAIN} --certmode manual --certdir /var/lib/derper/certs --stun --a :443
Restart=always
User=root
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable derper
systemctl start derper
info "systemd 单元已创建并启用"

# ────────────────────────────── 安装 td 管理工具 ──────────────────────────────
info "安装 td 管理工具..."

cat <<'EOF' >/usr/local/bin/td
#!/bin/bash
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; RESET="\033[0m"
show_menu() {
echo -e "${CYAN}============================"
echo -e "  Tailscale DERP 管理工具 v1.5"
echo -e "============================${RESET}"
echo -e "1) 查看 DERP 状态"
echo -e "2) 重启 DERP"
echo -e "3) 停止 DERP"
echo -e "4) 查看 Tailscale 状态"
echo -e "5) 注册 Tailscale 客户端"
echo -e "6) 更新证书并重启 DERP"
echo -e "7) 卸载本项目"
echo -e "0) 退出"
}
while true; do
  show_menu
  read -rp "请选择操作: " opt
  case "$opt" in
    1) systemctl status derper --no-pager ;;
    2) systemctl restart derper && echo -e "${GREEN}已重启 DERP${RESET}" ;;
    3) systemctl stop derper && echo -e "${YELLOW}已停止 DERP${RESET}" ;;
    4) tailscale status ;;
    5) systemctl start tailscaled && tailscale up ;;
    6) certbot renew --quiet && systemctl restart derper && echo -e "${GREEN}证书已更新并重启${RESET}" ;;
    7) systemctl stop derper && systemctl disable derper && rm -rf /opt/derper /usr/local/bin/derper /var/lib/derper /etc/systemd/system/derper.service /usr/local/bin/td && echo -e "${YELLOW}项目已卸载${RESET}" && exit 0 ;;
    0) echo "Bye~"; exit 0 ;;
    *) echo -e "${RED}无效选项${RESET}" ;;
  esac
done
EOF

chmod +x /usr/local/bin/td

# ────────────────────────────── 结尾提示 ──────────────────────────────
info "✅ 安装完成！请输入 ${CYAN}td${RESET} 管理 DERP 服务。"
echo ""
echo -e "${YELLOW}下一步建议:${RESET}"
echo -e "1️⃣ 运行 td"
echo -e "2️⃣ 选择 [5] 注册 Tailscale 客户端"
echo -e "3️⃣ 登录你的 Tailscale 账户完成绑定"
echo ""
info "🎯 脚本执行完毕。Enjoy your private DERP relay!"
exit 0
