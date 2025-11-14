#!/usr/bin/env bash
# install_cn.sh v4.2 — Modular Version (Debug / Option B)
# 用途：阿里云/国内 VPS 优化 + DERP 预备（调试版：详细日志与交互）
# 作者：bobvane
set -euo pipefail
export LANG=zh_CN.UTF-8

##############################################
# 第 1 段：全局行为与环境初始化区
##############################################

# 全局 PATH（确保子 shell 能访问 git、go、wget 等）
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"
PLAIN="\033[0m"

#  log 函数
log()     { echo -e "${GREEN}[INFO]${PLAIN} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
err()     { echo -e "${RED}[ERROR]${PLAIN} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${PLAIN} $1"; }

#  全局变量（必须 export）
export DERP_WORKDIR="${DERP_WORKDIR:-/opt/derper}"
export DERP_CERTDIR="${DERP_CERTDIR:-/etc/derp/certs}"
export SKIP_GO="${SKIP_GO:-0}"
export GHPROXY_GIT_PREFIX="${GHPROXY_GIT_PREFIX:-https://ghproxy.cn/https://github.com}"
export DOMAIN="${DOMAIN:-}"
export TLS_EMAIL="${TLS_EMAIL:-}"

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

# 检查 80 和 443 是否被占用（只提示，不退出）
for PORT in 80 443; do
    if ss -tulnp | grep -q ":$PORT "; then
        warn "端口 $PORT 被占用，可能影响证书申请。"
        ss -tulnp | grep ":$PORT " || true
    fi
done

log "运行环境检测完成。未对系统做任何修改。"

##############################################
# 第 3 段：系统组件可选优化区（可跳过）
##############################################

echo -e "${BLUE}即将进行系统优化操作，可提升网络质量与证书申请成功率。${PLAIN}"
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
        apt install -y curl wget jq unzip socat gnupg2 ca-certificates lsb-release git dnsutils tar unzip chrony
        success "基础工具安装完成。"
    else
        log "跳过系统更新与基础工具安装。"
    fi

    ##############################################
    # 3.2 修复 DNS 为国内源（阿里云特别处理）
    ##############################################
    fix_dns() {
        log "正在检测 DNS 配置..."

        # 推荐国内 DNS
        local CN_DNS_V4_1="223.5.5.5"
        local CN_DNS_V4_2="183.60.83.19"
        local CN_DNS_V6_1="2400:3200::1"
        local CN_DNS_V6_2="2400:da00::6666"

        # 如果 /etc/resolv.conf 是符号链接（常见 systemd-resolved）
        if [[ -L /etc/resolv.conf ]]; then
            warn "检测到 resolv.conf 为符号链接（systemd-resolved 管理）。"
            warn "在阿里云环境下这会导致 DNS 被强制覆盖为 100.100.x.x，影响证书申请与 DERP。"

            read -rp "是否切换到手动 DNS 管理（推荐）？[Y/n]: " ans
            ans=${ans:-Y}
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                log "正在禁用 systemd-resolved ..."
                systemctl disable --now systemd-resolved >/dev/null 2>&1 || true

                log "移除 resolv.conf 符号链接..."
                rm -f /etc/resolv.conf || true

                log "写入推荐国内 DNS..."
cat >/etc/resolv.conf <<EOF
nameserver $CN_DNS_V4_1
nameserver $CN_DNS_V4_2
nameserver $CN_DNS_V6_1
nameserver $CN_DNS_V6_2
options timeout:2 attempts:3 rotate single-request-reopen
EOF

                log "尝试锁定 resolv.conf（防止被覆盖，非致命）..."
                chattr +i /etc/resolv.conf >/dev/null 2>&1 || warn "无法设置 immutable（文件系统或权限不支持）。"

                success "DNS 已成功切换为手动模式并持久化。"
            else
                warn "用户选择保留 systemd-resolved，不修改 DNS。"
            fi

            return
        fi

        # 非软链情况 → 读取当前 DNS 内容
        local current_dns
        current_dns=$(cat /etc/resolv.conf 2>/dev/null || echo "")

        # 阿里云内部 DNS 检测（100.100.x.x）
        if echo "$current_dns" | grep -q "100.100."; then
            warn "检测到阿里云内部 DNS（100.100.x.x），将导致证书申请失败！"
            log "正在强制修复 DNS..."

            chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
cat >/etc/resolv.conf <<EOF
nameserver $CN_DNS_V4_1
nameserver $CN_DNS_V4_2
nameserver $CN_DNS_V6_1
nameserver $CN_DNS_V6_2
options timeout:2 attempts:3 rotate single-request-reopen
EOF
            chattr +i /etc/resolv.conf >/dev/null 2>&1 || warn "无法重新加 immutable（非致命）。"

            log "已修复为国内 DNS，阿里云内部 DNS 已屏蔽。"
            return
        fi

        # 检查是否已经是国内 DNS
        if echo "$current_dns" | grep -Eq "$CN_DNS_V4_1|$CN_DNS_V4_2"; then
            log "当前 DNS 已为推荐国内 DNS，无需修改。"
            return
        fi

        # 国外 DNS → 询问是否替换
        warn "检测到当前 DNS 不是国内 DNS（可能为 8.8.8.8 / 1.1.1.1 等）。"
        read -rp "是否替换为中国高可用 DNS？[Y/n]: " fix
        fix=${fix:-Y}
        if [[ "$fix" =~ ^[Yy]$ ]]; then
            chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
            log "正在写入国内 DNS..."
cat >/etc/resolv.conf <<EOF
nameserver $CN_DNS_V4_1
nameserver $CN_DNS_V4_2
nameserver $CN_DNS_V6_1
nameserver $CN_DNS_V6_2
options timeout:2 attempts:3 rotate single-request-reopen
EOF
            chattr +i /etc/resolv.conf >/dev/null 2>&1 || warn "无法加锁 resolv.conf（非致命）。"
            success "DNS 已成功修改为国内 DNS。"
        else
            warn "已跳过 DNS 修改。"
        fi
    }

    # 执行 DNS 修复（放在 3.2）
    fix_dns

    ###########################
    # 3.3 智能检测并自动启用 BBR（含 XanMod v3→v2→v1 自动fallback）
    ###########################

    log "== 开始 BBR 智能检测与自动启用流程 =="

    # 版本比较函数
    ver_ge() {
        [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
    }

    KERNEL_FULL=$(uname -r)
    KERNEL_MAJMIN=$(echo "$KERNEL_FULL" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')
    log "检测到内核：$KERNEL_FULL (简化版: $KERNEL_MAJMIN)"

    # 确保 iproute2 存在
    if ! command -v tc >/dev/null 2>&1; then
        warn "缺少 iproute2，正在自动安装..."
        apt update -y
        apt install -y iproute2
    fi

    # --- 新增：如果内核名称包含 xanmod，则优先认为 BBRv2 支持 ---
    if echo "$KERNEL_FULL" | grep -qi "xanmod"; then
        log "检测到当前为 XanMod 内核 → 默认支持 BBRv2。"
        HAS_BBR2=true
    fi

    # 获取 BBR 相关信息
    AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
    CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "none")
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "none")

    log "系统支持的 congestion control: ${AVAILABLE_CC:-(unknown)}"
    log "当前 default_qdisc: $CURRENT_QDISC, tcp_congestion_control: $CURRENT_CC"

    # 内核模块测试（防止脚本退出，使用 || true）
    try_mod() { modprobe "$1" 2>/dev/null || true; }

    # --- 新增：如果内核名称含 xanmod，则默认支持 BBRv2 ---
    if echo "$KERNEL_FULL" | grep -qi "xanmod"; then
        log "检测到当前为 XanMod 内核 → 默认支持 BBRv2。"
        HAS_BBR2=true
    else
        HAS_BBR2=false
    fi

    # 强制尝试加载 bbr2 模块（不退出）
    modprobe tcp_bbr2 2>/dev/null || true

    # 方法 1：检查 bbr2 模块文件是否存在
    if ls /lib/modules/"$(uname -r)"/kernel/net/ipv4/tcp_bbr2.ko 2>/dev/null | grep -q tcp_bbr2; then
        HAS_BBR2=true
    fi

    # 方法 2：检查 sysctl 是否能设置为 bbr2（某些系统 AVAILABLE_CC 不显示 bbr2）
    if sysctl -w net.ipv4.tcp_congestion_control=bbr2 2>/dev/null; then
        HAS_BBR2=true
    fi

    # 恢复原先算法
    sysctl -w net.ipv4.tcp_congestion_control="$CURRENT_CC" >/dev/null 2>&1 || true

    # 方法 3：再次读取 available CC（作为补充）
    AVAILABLE_CC=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
    if echo "$AVAILABLE_CC" | grep -qw "bbr2"; then
        HAS_BBR2=true
    fi

    log "BBR2 支持性检测：HAS_BBR2=$HAS_BBR2"

    try_mod tcp_bbr
    HAS_BBR1=false
    if echo "$AVAILABLE_CC" | grep -qw "bbr"; then
        HAS_BBR1=true
    fi

    try_mod sch_fq_codel
    HAS_FQ_CODEL=false
    # 兼容：检查 modprobe 可用性或 tc qdisc 检测
    if modprobe -n sch_fq_codel >/dev/null 2>&1 || tc qdisc show | grep -qi fq_codel; then
        HAS_FQ_CODEL=true
    fi

    HAS_FQ=true

    log "检测结果：BBRv2=$HAS_BBR2, BBR1=$HAS_BBR1, fq_codel=$HAS_FQ_CODEL"

    MIN_BBR2="5.9"
    KERNEL_SUPPORTS_BBR2=false
    if ver_ge "$KERNEL_MAJMIN" "$MIN_BBR2"; then
        KERNEL_SUPPORTS_BBR2=true
    fi

    log "内核是否满足 BBRv2 最低版本 ($MIN_BBR2)：$KERNEL_SUPPORTS_BBR2"

    ENABLED_MODE="none"

    # sysctl helper（写入 /etc/sysctl.conf）
    sysctl_write() {
        local key="$1"
        local value="$2"
        # 以 key=value 形式写入（尽量保持兼容）
        sed -i "/^${key//./\\.}=/d" /etc/sysctl.conf || true
        echo "${key}=${value}" >> /etc/sysctl.conf
    }

    ########################################
    # 优先级1：BBRv2 + fq_codel（当前内核支持并已编译）
    ########################################
    if $HAS_BBR2 && $HAS_FQ_CODEL && $KERNEL_SUPPORTS_BBR2; then
        log "优先级1 满足 → 尝试启用 BBRv2 + fq_codel"

        sysctl_write net.core.default_qdisc fq
        sysctl_write net.ipv4.tcp_congestion_control bbr2
        sysctl -p >/dev/null 2>&1 || true

        for IF in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
            tc qdisc replace dev "$IF" root fq_codel 2>/dev/null || true
        done

        CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
        [[ "$CUR" == "bbr2" ]] && ENABLED_MODE="BBRv2 + fq_codel"
    fi

    ########################################
    # 优先级2：BBRv2 + fq
    ########################################
    if [[ "$ENABLED_MODE" == "none" ]] && $HAS_BBR2 && $KERNEL_SUPPORTS_BBR2; then
        log "优先级2 满足 → 尝试启用 BBRv2 + fq"

        sysctl_write net.core.default_qdisc fq
        sysctl_write net.ipv4.tcp_congestion_control bbr2
        sysctl -p >/dev/null 2>&1 || true

        CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
        [[ "$CUR" == "bbr2" ]] && ENABLED_MODE="BBRv2 + fq"
    fi

    #######################################################################
    # 如果 BBRv2 不支持 → 尝试安装 XanMod 内核（支持 v3→v2→v1 三层 fallback）
    #######################################################################
    if [[ "$ENABLED_MODE" == "none" ]] && ! $HAS_BBR2; then

        log "检测到系统不支持 BBRv2，准备进行 XanMod 内核自动检测与安装..."

        # 检测 avx2 指令集
        CPU_SUPPORTS_AVX2=false
        if grep -qi avx2 /proc/cpuinfo; then
            CPU_SUPPORTS_AVX2=true
        fi

        # 选择优先版本
        if $CPU_SUPPORTS_AVX2; then
            DEFAULT_XANMOD="linux-xanmod-x64v3"
        else
            DEFAULT_XANMOD="linux-xanmod-x64v2"
        fi

        # 候选版本
        XANMOD_CANDIDATES=(
            "$DEFAULT_XANMOD"
            "linux-xanmod-x64v2"
            "linux-xanmod-x64v1"
        )

        # 检测仓库是否可访问（超时短）
        if curl -fsSL --connect-timeout 5 https://dl.xanmod.org >/dev/null 2>&1; then
            echo -e "\033[33m[建议] 安装 XanMod 内核可启用 BBRv2，显著提升 DERP 性能。\033[0m"
            read -rp "是否安装 XanMod 内核？ [Y/n]: " CONF_XANMOD
            CONF_XANMOD=${CONF_XANMOD:-Y}

            if [[ "$CONF_XANMOD" =~ ^[Yy]$ ]]; then
                log "开始尝试安装 XanMod 内核（含 v3→v2→v1 自动 fallback）..."

                # 安装 GPG key（若失败继续）
                curl -fsSL https://dl.xanmod.org/archive.key \
                    | gpg --dearmor -o /usr/share/keyrings/xanmod.gpg || warn "导入 XanMod key 失败（非致命）"

                # 添加仓库（注意：某些国内网络可能需要改成 http -> https 或镜像）
                echo "deb [signed-by=/usr/share/keyrings/xanmod.gpg] http://deb.xanmod.org releases main" \
                    | tee /etc/apt/sources.list.d/xanmod.list

                apt update -y || warn "apt update 失败（继续尝试安装）"

                # 依次尝试三种内核包
                XANMOD_INSTALLED=false
                for PKG in "${XANMOD_CANDIDATES[@]}"; do
                    log "尝试安装：$PKG ..."
                    if apt install -y "$PKG"; then
                        log "成功安装 XanMod 内核：$PKG"
                        XANMOD_INSTALLED=true
                        break
                    else
                        warn "$PKG 安装失败，尝试 fallback..."
                    fi
                done

                if ! $XANMOD_INSTALLED; then
                    warn "XanMod 所有版本均安装失败 → 启用优先级3（BBR1 + fq_codel）"
                fi
            fi
        else
            warn "无法访问 XanMod 仓库 → 自动跳过内核升级"
        fi
    fi

    ########################################
    # 优先级3：BBR1 + fq_codel（兜底永远可用）
    ########################################
    if [[ "$ENABLED_MODE" == "none" ]] && $HAS_BBR1 && $HAS_FQ_CODEL; then
        log "优先级3 满足 → 启用 BBR1 + fq_codel"

        sysctl_write net.core.default_qdisc fq
        sysctl_write net.ipv4.tcp_congestion_control bbr
        sysctl -p >/dev/null 2>&1 || true

        for IF in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
            tc qdisc replace dev "$IF" root fq_codel 2>/dev/null || true
        done

        CUR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
        [[ "$CUR" == "bbr" ]] && ENABLED_MODE="BBR1 + fq_codel"
    fi

    ########################################
    # 输出最终结果
    ########################################
    if [[ "$ENABLED_MODE" != "none" ]]; then
        log "BBR 优化完成：$ENABLED_MODE"
    else
        warn "无法启用 BBR1 或 BBR2。建议检查内核后重新运行脚本。"
    fi

    log "== BBR 智能模块执行结束 =="

    ###########################
    # 3.4 设置 Swap 1GB
    ###########################
    read -rp "是否创建 1GB Swap？ [Y/n]: " CONF_SWAP
    CONF_SWAP=${CONF_SWAP:-Y}
    if [[ "$CONF_SWAP" =~ ^[Yy]$ ]]; then
        if ! swapon --show | grep -q "swap"; then
            log "正在创建 1GB Swap..."
            fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
            success "1GB Swap 创建并启用。"
        else
            warn "系统已存在 Swap，跳过。"
        fi
    else
        log "用户选择跳过 Swap 创建。"
    fi

    ##############################################
    # 3.5 Sysctl 网络优化（DERP + XanMod 专用）
    ##############################################

    log "应用 DERP 优化专用 sysctl 配置..."

cat >/etc/sysctl.d/99-derp-opt.conf <<EOF
# 低延迟 UDP 优化（DERP 主流量）
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000

# 减少 UDP 丢包（适用于中高端 VPS）
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# 允许更多临时端口（DERP 需大量短连接）
net.ipv4.ip_local_port_range = 10000 65535

# Keepalive 频率（避免 NAT 提前清理）
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# 禁止 rp_filter 降低延迟
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# 关闭 ICMP 限速（DERP 中 Ping 用作调度）
net.ipv4.icmp_ratelimit = 0

# 高性能队列调度（XanMod 使用 fq 默认即可）
net.core.default_qdisc = fq
EOF

    # 重新加载 sysctl（非致命）
    sysctl --system >/dev/null 2>&1 || warn "sysctl 应用失败（非致命）。"
    success "Sysctl 网络优化已应用（DERP + XanMod 专用）。"

    log "前 3 段执行完毕，脚本即将进入证书申请与 DERP 主程序安装部分。"
fi

install_cert() {
###############################################
# 第 4 段：证书申请模块（支持 HTTP-01 / DNS-01）
# 使用 Certbot 默认目录，并同步到 /etc/derp/certs/
###############################################

echo ""
echo "=============================="
echo "[4/4] 开始证书申请模块"
echo "=============================="
echo ""

DERP_CERT_DIR="/etc/derp/certs"
mkdir -p "$DERP_CERT_DIR"
chmod 700 "$DERP_CERT_DIR"

#########################################
# 创建 Certbot deploy-hook：续期自动复制证书
#########################################
cat >/usr/local/bin/derp-cert-copy.sh <<'EOF'
#!/bin/bash

# Certbot 会提供 RENEWED_DOMAINS（可能包含多个域名）
DOMAIN="$(echo $RENEWED_DOMAINS | awk '{print $1}')"

SRC="/etc/letsencrypt/live/$DOMAIN"
DST="/etc/derp/certs"

# 如果 Certbot 输出的 DOMAIN 空了，直接退出
if [[ -z "$DOMAIN" ]]; then
    echo "[deploy-hook] ERROR: DOMAIN empty"
    exit 0
fi

# 必须确认证书目录存在
if [[ ! -d "$SRC" ]]; then
    echo "[deploy-hook] ERROR: cert path not found: $SRC"
    exit 0
fi

echo "[deploy-hook] Updating DERP certs for domain: $DOMAIN"

# fullchain.pem = 公钥
cp -f "$SRC/fullchain.pem" "$DST/$DOMAIN.crt"

# privkey.pem = 私钥
cp -f "$SRC/privkey.pem" "$DST/$DOMAIN.key"

# 权限
chmod 644 "$DST/$DOMAIN.crt"
chmod 600 "$DST/$DOMAIN.key"

echo "[deploy-hook] Certs copied. Reloading derper..."
systemctl restart derper 2>/dev/null || true

EOF

chmod +x /usr/local/bin/derp-cert-copy.sh

#########################################
# 1. 用户输入域名
#########################################
echo ""
read -rp "请输入你的域名（例如 example.com）: " DOMAIN

if [[ -z "$DOMAIN" ]]; then
    echo "[ERROR] 域名不能为空，退出安装。"
    exit 1
fi

CERTBOT_LIVE_DIR="/etc/letsencrypt/live/$DOMAIN"

#########################################
# 2. 检查 Certbot 证书是否已存在
#########################################
if [[ -d "$CERTBOT_LIVE_DIR" ]]; then
    echo ""
    echo "[INFO] 检测到已有证书：$CERTBOT_LIVE_DIR"
    echo "请选择："
    echo "1) 覆盖（删除旧证书并重新申请）"
    echo "2) 使用现有证书（跳过申请）"
    read -rp "请输入数字 (1/2): " EXIST_CHOICE

    if [[ "$EXIST_CHOICE" == "1" ]]; then
        echo "[INFO] 删除旧证书..."
        certbot delete --cert-name "$DOMAIN" -n
    else
        echo "[INFO] 使用现有证书：将复制到 $DERP_CERT_DIR"
        cp -f "$CERTBOT_LIVE_DIR/fullchain.pem" "$DERP_CERT_DIR/$DOMAIN.crt"
        cp -f "$CERTBOT_LIVE_DIR/privkey.pem"   "$DERP_CERT_DIR/$DOMAIN.key"
        chmod 644 "$DERP_CERT_DIR/$DOMAIN.crt"
        chmod 600 "$DERP_CERT_DIR/$DOMAIN.key"
        echo "[INFO] 已完成证书同步，继续进入第 5 段"
        return 0
    fi
fi

#########################################
# 3. 安装 Certbot & pip（DNS-01 统一提前准备）
#########################################
echo "[INFO] 安装 Certbot 与 pip..."
apt update -y
apt install -y certbot python3-pip
pip install --upgrade pip --break-system-packages

#########################################
# 4. 用户选择验证方式
#########################################
echo ""
echo "请选择证书验证方式："
echo "1) HTTP-01  (需要 80 端口可用)"
echo "2) DNS-01   (支持 *.domain.com)"
read -rp "请输入数字 (1/2): " MODE

#########################################
# 5. HTTP-01 方式
#########################################
if [[ "$MODE" == "1" ]]; then
    echo "[INFO] 使用 HTTP-01 申请证书..."

    certbot certonly --standalone \
        --deploy-hook "/usr/local/bin/derp-cert-copy.sh" \
        -d "$DOMAIN"

    if [[ $? -ne 0 ]]; then
        echo "[ERROR] HTTP-01 证书申请失败，请检查端口或域名解析。"
        exit 1
    fi

    # 手动复制一次，确保 derp 目录有证书
    cp -f "$CERTBOT_LIVE_DIR/fullchain.pem" "$DERP_CERT_DIR/$DOMAIN.crt"
    cp -f "$CERTBOT_LIVE_DIR/privkey.pem"   "$DERP_CERT_DIR/$DOMAIN.key"
    chmod 644 "$DERP_CERT_DIR/$DOMAIN.crt"
    chmod 600 "$DERP_CERT_DIR/$DOMAIN.key"

    echo "[INFO] 证书申请成功，已复制到 DERP 目录"
    return 0
fi

#########################################
# 6. DNS-01：用户选择 DNS 服务商
#########################################
echo ""
echo "[INFO] 你选择了 DNS-01，请选择 DNS 服务商："
echo "1) Cloudflare"
echo "2) Aliyun"
echo "3) DNSPod"
read -rp "请输入数字 (1/2/3): " DNS_MODE

CREDS_DIR="/etc/letsencrypt/dns"
mkdir -p "$CREDS_DIR"
chmod 700 "$CREDS_DIR"

#########################################
# 7. 安装对应 DNS 插件（使用 pip + --break-system-packages）
#########################################

if [[ "$DNS_MODE" == "1" ]]; then
    echo "[INFO] 安装 Cloudflare DNS 插件..."
    pip install certbot-dns-cloudflare --break-system-packages

    CRED_FILE="$CREDS_DIR/cloudflare.ini"
    read -rp "请输入 Cloudflare API Token: " CF_TOKEN
    echo "dns_cloudflare_api_token = $CF_TOKEN" > "$CRED_FILE"
    chmod 600 "$CRED_FILE"

    DNS_ARGS="--dns-cloudflare --dns-cloudflare-credentials $CRED_FILE"

elif [[ "$DNS_MODE" == "2" ]]; then
    echo "[INFO] 安装 Aliyun DNS 插件..."
    pip install certbot-dns-aliyun --break-system-packages

    CRED_FILE="$CREDS_DIR/aliyun.ini"
    read -rp "请输入 Aliyun AccessKey ID: " Ali_Key
    read -rp "请输入 Aliyun AccessKey Secret: " Ali_Secret

    {
        echo "access_key_id = $Ali_Key"
        echo "access_key_secret = $Ali_Secret"
    } > "$CRED_FILE"
    chmod 600 "$CRED_FILE"

    DNS_ARGS="--dns-aliyun --dns-aliyun-credentials $CRED_FILE"

elif [[ "$DNS_MODE" == "3" ]]; then
    echo "[INFO] 安装 DNSPod DNS 插件..."
    pip install certbot-dns-dnspod --break-system-packages

    CRED_FILE="$CREDS_DIR/dnspod.ini"
    read -rp "请输入 DNSPod Secret ID: " DP_Id
    read -rp "请输入 DNSPod Secret Key: " DP_Key

    {
        echo "dns_dp_id = $DP_Id"
        echo "dns_dp_key = $DP_Key"
    } > "$CRED_FILE"
    chmod 600 "$CRED_FILE"

    DNS_ARGS="--dns-dnspod --dns-dnspod-credentials $CRED_FILE"
fi

#########################################
# 8. DNS-01 申请证书（含通配符）
#########################################
echo "[INFO] 使用 DNS-01（Cloudflare API）开始申请证书..."

# ★★★ STAGING 临时启用，正式环境请删除 --staging ★★★

# DNS-01 参数（必须指定）
DNS_ARGS="--dns-cloudflare --dns-cloudflare-credentials /root/cloudflare.ini --dns-cloudflare-propagation-seconds 20"

certbot certonly \
    --staging \
    --non-interactive \
    --agree-tos \
    --email "admin@$DOMAIN" \
    --deploy-hook "/usr/local/bin/derp-cert-copy.sh" \
    $DNS_ARGS \
    -d "$DOMAIN" \
    -d "*.$DOMAIN"

# 检查是否成功
if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    echo "[ERROR] DNS-01 证书申请失败！请检查 Cloudflare API Token 或 DNS 设置"
    exit 1
fi

echo "[SUCCESS] DNS-01 证书申请成功"

# 手动复制一次（首次）
cp -f "$CERTBOT_LIVE_DIR/fullchain.pem" "$DERP_CERT_DIR/$DOMAIN.crt"
cp -f "$CERTBOT_LIVE_DIR/privkey.pem"   "$DERP_CERT_DIR/$DOMAIN.key"
chmod 644 "$DERP_CERT_DIR/$DOMAIN.crt"
chmod 600 "$DERP_CERT_DIR/$DOMAIN.key"

echo ""
echo "======================================="
echo "[SUCCESS] DNS-01 证书申请成功！"
echo "证书已复制到：$DERP_CERT_DIR"
echo "续期后将自动复制并重启 DERP"
echo "======================================="
echo ""

return 0
}
# 调用第 4 段
install_cert


# ========================================
# 5. 自动安装 Go + derper 源码编译
# ========================================
# 5.1 自动检测并安装最新 Go（从 golang.google.cn 稳定 JSON 获取）
log "自动检测并安装最新 Go（来源：https://golang.google.cn/dl/）..."

SKIP_GO="${SKIP_GO:-}"

if [[ "${SKIP_GO}" == "1" ]]; then
  log "SKIP_GO=1，跳过 Go 安装"
else
  # 获得最新 Go 版本号（从 JSON 中解析第一个版本）
  GO_JSON=$(curl -s https://golang.google.cn/dl/?mode=json&include=all)
  [[ -z "${GO_JSON}" ]] && err "无法访问 golang.google.cn/dl/"

  GO_LATEST=$(echo "${GO_JSON}" | \
    grep -E '"version": "go[0-9]+\.[0-9]+(\.[0-9]+)?"' -m1 | \
    sed -E 's/.*"version": "(go[0-9\.]+)".*/\1/')

  [[ -z "${GO_LATEST}" ]] && err "无法解析 Go 最新版本号"

  GO_TARBALL="${GO_LATEST}.linux-amd64.tar.gz"
  GO_URL="https://golang.google.cn/dl/${GO_TARBALL}"

  log "检测到最新 Go 版本：${GO_LATEST}"
  log "下载地址：${GO_URL}"

  wget -q -O /tmp/go.tar.gz "${GO_URL}" || err "Go 下载失败，请稍后再试"

  rm -rf /usr/local/go

  tar -C /usr/local -xzf /tmp/go.tar.gz || err "Go 解压失败"

  echo 'export PATH=/usr/local/go/bin:$PATH' > /etc/profile.d/99-go-path.sh
  export PATH=/usr/local/go/bin:$PATH

  log "Go 安装完成：$(go version)"
fi

# 5.2 derper 源码编译（官方不再提供二进制包）
log "开始从源码编译 derper..."

mkdir -p "${DERP_WORKDIR}" "${DERP_CERTDIR}"
cd "${DERP_WORKDIR}" || err "无法进入工作目录：${DERP_WORKDIR}"

rm -rf /tmp/tailscale-src
mkdir -p /tmp/tailscale-src

log "获取 derper 源码（来自 tailscale 仓库）..."
git clone --depth=1 "${GHPROXY_GIT_PREFIX}/tailscale/tailscale.git" \
  /tmp/tailscale-src || err "克隆 tailscale 源码失败"

cd /tmp/tailscale-src/cmd/derper || err "无法进入 cmd/derper"

log "配置 Go 模块代理，加速依赖下载..."
go env -w GOPROXY=https://goproxy.cn,direct
go env -w GOSUMDB=off

log "开始构建 derper..."
go build -o /usr/local/bin/derper . || err "derper 编译失败"

chmod +x /usr/local/bin/derper
log "derper 编译成功：$(/usr/local/bin/derper -h 2>/dev/null | head -n 1)"

# 5.3 统一证书路径（给 derper 用）
CERT_FULLCHAIN="${DERP_CERTDIR}/fullchain.pem"
CERT_PRIVKEY="${DERP_CERTDIR}/privkey.pem"

log "证书路径（derper 用）："
log "  - fullchain.pem: ${CERT_FULLCHAIN}"
log "  - privkey.pem  : ${CERT_PRIVKEY}"


# ========================================
# 6. 部署 derper systemd 服务（最终版）
# ========================================
log "开始第 6 段：部署 derper systemd 服务（systemd 单元 + 启动验证）..."

# 必要变量（假定在第1段已定义）
: "${DOMAIN:?DOMAIN 未设置，无法继续}"
: "${DERP_CERTDIR:?DERP_CERTDIR 未设置，无法继续}"

# 二进制检查
if [[ ! -x "/usr/local/bin/derper" ]]; then
  err "未检测到 /usr/local/bin/derper 可执行文件，请先完成第5段（Go + 编译 derper）"
  return 1 2>/dev/null || exit 1
fi

SERVICE_FILE="/etc/systemd/system/derper.service"
log "写入 systemd 服务文件：${SERVICE_FILE}"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Tailscale DERP Relay Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# 启动命令：显式监听 :443，使用 manual certmode + certdir（由第4段提供证书）
ExecStart=/usr/local/bin/derper \\
  -a :443 \\
  --hostname=${DOMAIN} \\
  --certmode=manual \\
  --certdir=${DERP_CERTDIR} \\
  --stun

# 守护/重启策略
Restart=always
RestartSec=2
LimitNOFILE=1048576

# 以 root 启动（不要在此处降权读取证书，证书权限由第4段控制）
User=root

[Install]
WantedBy=multi-user.target
EOF

log "systemd 单元写入完成。"

# 重新加载 systemd 配置并启用服务
log "重新加载 systemd..."
systemctl daemon-reload || warn "systemctl daemon-reload 返回非0"

log "启用并启动 derper 服务..."
# reset-failed 避免之前失败次数阻止启动
systemctl reset-failed --quiet || true
systemctl enable --now derper || warn "systemctl enable/start 返回非0，稍后检查日志"

# 等待短暂时间让服务完成启动
sleep 2

# 检查服务状态
if systemctl is-active --quiet derper; then
  success "derper 服务已处于运行状态 (systemd)"
else
  err "derper 服务未能保持运行，请查看日志：journalctl -u derper -n 200 --no-pager"
  # 仍然继续后面的端口检查，以便给出更详细提示
fi

# 检查端口监听（判断是否真正提供 DERP HTTPS 与 STUN）
# 检查 TCP 443
TCP443_LISTEN_COUNT=$(ss -lnpt 2>/dev/null | grep -E ':\*?:443\b|:443\b' | wc -l || true)
# 检查 UDP 3478
UDP3478_LISTEN_COUNT=$(ss -lnpu 2>/dev/null | grep -E ':\*?:3478\b|:3478\b' | wc -l || true)

if [[ "${TCP443_LISTEN_COUNT}" -gt 0 ]]; then
  success "检测到 derper 已监听 443/tcp（HTTPS）。"
else
  warn "未检测到 443/tcp 的监听（derper 可能未加载 TLS 证书或启动失败）。请检查：journalctl -u derper -n 200 --no-pager"
fi

if [[ "${UDP3478_LISTEN_COUNT}" -gt 0 ]]; then
  success "检测到 derper 已监听 3478/udp（STUN）。"
else
  warn "未检测到 3478/udp 的监听（STUN 未开启或被防火墙阻止）。"
fi

# 最终提示（不自动改证书，不创建证书目录）
log "第 6 段执行完毕。请注意："
log "  - derper 使用证书路径：${DERP_CERTDIR}/${DOMAIN}.crt 及 ${DERP_CERTDIR}/${DOMAIN}.key（由第4段生成）"
log "  - 查看服务日志：journalctl -u derper -f"
log "  - 若 443 未监听，请检查日志与证书文件名/权限："
log "      ls -l ${DERP_CERTDIR}"
log "      journalctl -u derper -n 200 --no-pager"
success "第 6 段：systemd 部署步骤完成（如无警告，则为正常）"

# =====================================================
# 7) 安装完成 — 部署 td、创建自动续签、提示重启
# =====================================================

log "正在从 GitHub 下载 td 管理工具..."

TD_URL="https://raw.githubusercontent.com/bobvane/VPS-Tailscale-DERP-AutoSetup/main/td"

# 直接从 GitHub 下载到 /usr/local/bin
curl -fsSL "$TD_URL" -o /usr/local/bin/td

if [[ $? -ne 0 ]]; then
    err "下载 td 失败，请检查网络或 GitHub 仓库 URL 是否正确。"
    exit 1
fi

chmod +x /usr/local/bin/td

# 刷新 shell 命令缓存
hash -r 2>/dev/null || true

# 验证 td 是否成功安装
if ! command -v td >/dev/null 2>&1; then
    err "td 未能成功安装到 PATH，请检查 /usr/local/bin/td"
    exit 1
fi

log "td 工具已安装，可直接通过命令： td  使用。"
echo

# -----------------------------------------------------
# 创建自动续签任务（每 12 小时）
# -----------------------------------------------------

CRON_FILE="/etc/cron.d/derper-auto-renew"
log "创建自动续签计划任务：${CRON_FILE}"

cat > "${CRON_FILE}" <<EOF
0 */12 * * * root certbot renew --quiet
EOF

chmod 644 "${CRON_FILE}"

log "自动续签任务已创建（每 12 小时自动执行 certbot renew）"
echo

# -----------------------------------------------------
# 显示 derper 运行状态
# -----------------------------------------------------

log "DERP 服务当前状态如下："
echo "-------------------------------------------"
systemctl status derper --no-pager || true
echo "-------------------------------------------"
echo

# -----------------------------------------------------
# 提示用户使用方法
# -----------------------------------------------------

echo -e "${RED}你可以随时输入命令： td    来管理 DERP 节点${RESET}"
echo
log "安装流程已全部完成！"
echo

# -----------------------------------------------------
# BBR + 新内核需要重启
# -----------------------------------------------------

echo -e "${YELLOW}为了让新内核和 BBR 生效，需要立即重启系统。${RESET}"
read -rp "按回车键立即重启系统..."

reboot
exit 0
