#!/usr/bin/env bash
# install_cn.sh v4.2 — Modular Version (Debug / Option B)
# 用途：阿里云/国内 VPS 优化 + DERP 预备（调试版：详细日志与交互）
# 作者：bobvane
set -euo pipefail
export LANG=zh_CN.UTF-8

##############################################
# 第 1 段：全局行为与环境初始化区
##############################################

# 颜色定义（全局唯一标准）
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

# 日志输出函数（安全写法以防 set -u）
log()     { echo -e "${GREEN}[INFO]${PLAIN} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
err()     { echo -e "${RED}[ERROR]${PLAIN} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${PLAIN} $1"; }

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
        apt install -y curl wget jq unzip socat gnupg2 ca-certificates lsb-release
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

##############################################
# 第 4 段：证书申请模块（Let's Encrypt）
##############################################

echo -e "${BLUE}开始进行 DERP HTTPS 证书申请（Let's Encrypt）...${PLAIN}"

# 4.0 安装 certbot 必备软件
log "正在安装 certbot 及相关依赖..."

apt update -y
apt install -y certbot python3 python3-venv python3-certbot

# 再次检查 certbot 是否安装成功
if ! command -v certbot >/dev/null 2>&1; then
    err "certbot 安装失败，请检查网络或软件源。"
    exit 1
fi

log "certbot 已成功安装，继续进行证书申请流程。"

# 4.1 用户输入域名
read -rp "请输入用于 DERP 的域名（必须已正确解析到本服务器）: " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr -d ' ')

if [[ -z "$DOMAIN" || ! "$DOMAIN" =~ \. ]]; then
    err "域名格式不正确，请输入一个有效的域名，例如：derp.example.com"
    exit 1
fi

log "你输入的域名为：$DOMAIN"

##############################################
# 4.2 检测系统是否已有该域名证书 → 跳过证书申请
##############################################

DERP_CERT_DIR="/var/lib/derper/certs"
EXIST_CERT="$DERP_CERT_DIR/${DOMAIN}.crt"
EXIST_KEY="$DERP_CERT_DIR/${DOMAIN}.key"

if [[ -f "$EXIST_CERT" && -f "$EXIST_KEY" ]]; then
    log "检测到已有 DERP 证书文件："
    echo " - $EXIST_CERT"
    echo " - $EXIST_KEY"

    # 检查证书是否有效（不是损坏文件）
    if openssl x509 -in "$EXIST_CERT" -noout >/dev/null 2>&1; then
        log "证书结构有效，将跳过证书申请步骤。"
        SKIP_CERT=true
    else
        warn "检测到证书存在，但文件损坏，将重新申请证书。"
        SKIP_CERT=false
    fi
else
    log "未找到 $DOMAIN 的有效 DERP 证书，将开始申请。"
    SKIP_CERT=false
fi

##############################################
# 如果已有证书有效 → 跳过整个申请阶段
##############################################
if [[ "$SKIP_CERT" == true ]]; then
    log "跳过 Let's Encrypt 证书申请，直接进入 DERP 主程序安装。"
    CERT_PATH="$EXIST_CERT"
    KEY_PATH="$EXIST_KEY"
else

    ##############################################
    # 4.3 输入邮箱
    ##############################################
    read -rp "请输入用于 Let's Encrypt 的邮箱（留空=admin@$DOMAIN）: " EMAIL
    EMAIL=${EMAIL:-"admin@$DOMAIN"}

    if [[ ! "$EMAIL" =~ @ || ! "$EMAIL" =~ \. ]]; then
        err "邮箱格式不正确，请输入一个有效邮箱，例如：admin@example.com"
        exit 1
    fi

    log "使用邮箱：$EMAIL"

    ##############################################
    # 4.4 DNS 解析校验
    ##############################################

    log "正在检测域名解析记录..."

    SERVER_IP=$(curl -4 -s https://ip.gs || curl -4 -s https://api.ipify.org)
    if [[ -z "$SERVER_IP" ]]; then
        err "无法获取本机 IPv4 地址，请检查网络。"
        exit 1
    fi

    DOMAIN_IP=$(dig +short A "$DOMAIN" | head -n1)

    if [[ -z "$DOMAIN_IP" ]]; then
        err "域名未解析到任何 IPv4 地址，请在 DNS 控制台添加记录后再运行脚本。"
        exit 1
    fi

    if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
        err "域名 ($DOMAIN) 未解析到本机 IP！"
        echo "域名解析：$DOMAIN_IP"
        echo "本机IP：$SERVER_IP"
        echo "请等待 DNS 生效后重新运行脚本。"
        exit 1
    fi

    log "DNS 校验成功（$DOMAIN → $DOMAIN_IP）"

    ##############################################
    # 4.5 端口占用检查
    ##############################################

    log "正在检查 80 端口是否被占用..."

    if ss -tulnp | grep -q ':80 '; then
        err "80端口被占用，Let's Encrypt 无法验证域名。"
        ss -tulnp | grep ':80 '
        exit 1
    fi

    log "80 端口可用。"

    ##############################################
    # 4.6 开始签发证书（最大重试次数）
    ##############################################

    MAX_TRY=5
    TRY=1

    log "即将开始为 $DOMAIN 申请 Let's Encrypt 证书..."

    while [[ $TRY -le $MAX_TRY ]]; do
        log "正在尝试签发证书（${TRY}/${MAX_TRY}）..."

        if certbot certonly --standalone \
            --preferred-challenges http \
            --agree-tos \
            --non-interactive \
            -m "$EMAIL" \
            -d "$DOMAIN"; then

            log "证书申请成功！"
            break
        else
            warn "第 ${TRY} 次申请失败，3 秒后重试..."
            ((TRY++))
            sleep 3
        fi
    done

    # 最终检查证书是否成功生成
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

    if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
        err "证书申请失败，已尝试 ${MAX_TRY} 次仍未成功。请检查："
        echo " - 域名解析是否正确？"
        echo " - 端口80是否被防火墙放行？"
        exit 1
    fi

    log "证书申请阶段完成。"

    ##############################################
    # 4.7 复制证书到 derper 工作目录
    ##############################################
    log "复制证书到 DERP 工作目录..."

    mkdir -p "$DERP_CERT_DIR"
    cp "$CERT_PATH" "$DERP_CERT_DIR/$DOMAIN.crt"
    cp "$KEY_PATH" "$DERP_CERT_DIR/$DOMAIN.key"

    chmod 600 "$DERP_CERT_DIR"/*
    chown root:root "$DERP_CERT_DIR"/*

    log "证书已复制到：$DERP_CERT_DIR/"
fi

##############################################
# 4.8 输出完成提示
##############################################
log "证书模块执行完毕，即将进入 DERP 主程序安装部分。"

