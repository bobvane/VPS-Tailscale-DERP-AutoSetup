#!/usr/bin/env bash
# install_cn.sh v4.2 — Modular Version (段落1~3)

##############################################
# 第 1 段：全局行为与环境初始化区
##############################################

set -euo pipefail
export LANG=zh_CN.UTF-8

# 颜色输出函数（后续各段都需要用）
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[36m"; NC="\033[0m"

log()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

log "脚本已启动（install_cn.sh），加载全局环境完成。"

##############################################
# 第 2 段：运行环境检查区（非破坏性）
##############################################

# 必须 root
if [[ $EUID -ne 0 ]]; then
    err "请使用 root 权限运行此脚本。"
    exit 1
fi

# 检查系统类型
if ! grep -qiE "debian|ubuntu" /etc/os-release; then
    err "当前系统不是 Debian/Ubuntu，不支持中国优化版 install_cn.sh。"
    exit 1
fi

OS=$(grep "^ID=" /etc/os-release | cut -d= -f2)
VERSION=$(grep "VERSION_ID" /etc/os-release | cut -d= -f2 | tr -d '"')

log "系统检测：$OS $VERSION"

# 检查 80 和 443 是否被占用
for PORT in 80 443; do
    if ss -tulnp | grep -q ":$PORT "; then
        warn "端口 $PORT 被占用，可能影响证书申请。"
        ss -tulnp | grep ":$PORT "
    fi
done

# 检查 DNS 是否为阿里云的"内部 DNS"，可能屏蔽证书解析
ALI_DNS_1="100.100.2.136"
ALI_DNS_2="100.100.2.138"

CURRENT_DNS=$(grep "^nameserver" /etc/resolv.conf | awk '{print $2}' | paste -sd "," -)

if echo "$CURRENT_DNS" | grep -qE "$ALI_DNS_1|$ALI_DNS_2"; then
    warn "检测到阿里云内部 DNS（$CURRENT_DNS），可能导致 Let’s Encrypt 证书申请失败。"
fi

log "运行环境检测完成。未对系统做任何修改。"

##############################################
# 第 3 段：系统组件可选优化区（可跳过）
##############################################

echo -e "${BLUE}即将进行系统优化操作，可提升网络质量与证书申请成功率。${NC}"
echo "内容包括："
echo "1) 更新系统与安装必要组件"
echo "2) 设置国内高可用 DNS (223.5.5.5 / 183.60.83.19 等)"
echo "3) 开启 BBR 加速"
echo "4) 创建 1GB Swap（若无）"
echo "5) 应用网络与内核优化 sysctl 参数"

read -rp "是否继续执行以上优化？ [Y/n]: " CONF_OPT_ALL
CONF_OPT_ALL=${CONF_OPT_ALL:-Y}

if [[ ! "$CONF_OPT_ALL" =~ ^[Yy]$ ]]; then
    warn "用户选择跳过所有系统优化步骤。"
else
    log "开始执行系统优化..."

    ###########################
    # 3.1 更新系统 + 基础组件
    ###########################
    read -rp "是否更新系统并安装基础组件？ [Y/n]: " CONF_UPGRADE
    CONF_UPGRADE=${CONF_UPGRADE:-Y}
    if [[ "$CONF_UPGRADE" =~ ^[Yy]$ ]]; then
        log "正在更新系统并安装基础工具..."
        apt update -y
        apt install -y curl wget jq unzip socat
    fi

    ###########################
    # 3.2 修复 DNS 为国内源
    ###########################
    read -rp "是否将 DNS 修改为中国高可用 DNS？ [Y/n]: " CONF_DNS
    CONF_DNS=${CONF_DNS:-Y}
    if [[ "$CONF_DNS" =~ ^[Yy]$ ]]; then
        log "正在设置国内 DNS..."
        cat >/etc/resolv.conf <<EOF
nameserver 223.5.5.5
nameserver 183.60.83.19
nameserver 2400:3200::1
nameserver 2400:da00::6666
EOF
        chattr +i /etc/resolv.conf || true
        log "DNS 已设置为国内高可用源。"
    fi

    ###########################
    # 3.3 开启 BBR
    ###########################
    read -rp "是否开启 BBR 加速？ [Y/n]: " CONF_BBR
    CONF_BBR=${CONF_BBR:-Y}
    if [[ "$CONF_BBR" =~ ^[Yy]$ ]]; then
        log "正在开启 BBR..."
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi

    ###########################
    # 3.4 设置 Swap 1GB
    ###########################
    read -rp "是否创建 1GB Swap？ [Y/n]: " CONF_SWAP
    CONF_SWAP=${CONF_SWAP:-Y}
    if [[ "$CONF_SWAP" =~ ^[Yy]$ ]]; then
        if ! swapon --show | grep -q "swap"; then
            log "正在创建 1GB Swap..."
            fallocate -l 1G /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
        else
            warn "系统已存在 Swap，跳过。"
        fi
    fi

    ###########################
    # 3.5 sysctl 内核优化
    ###########################
    read -rp "是否应用网络内核优化？ [Y/n]: " CONF_SYSCTL
    CONF_SYSCTL=${CONF_SYSCTL:-Y}
    if [[ "$CONF_SYSCTL" =~ ^[Yy]$ ]]; then
        log "正在应用网络优化参数..."
        cat >>/etc/sysctl.conf <<EOF
net.core.rmem_max=2500000
net.ipv4.tcp_fastopen=3
EOF
        sysctl -p
    fi

    log "所有系统优化操作已完成。"
fi

log "前 3 段执行完毕，脚本即将进入证书申请与 DERP 主程序安装部分。"

