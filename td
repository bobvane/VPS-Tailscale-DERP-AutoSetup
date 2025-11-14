#!/usr/bin/env bash
# td v2.0 - 精简版 DERP 管理工具（交互式）
set -euo pipefail
export LANG=zh_CN.UTF-8

# Colors
RED=$(tput setaf 1 2>/dev/null || echo "")
GREEN=$(tput setaf 2 2>/dev/null || echo "")
YELLOW=$(tput setaf 3 2>/dev/null || echo "")
CYAN=$(tput setaf 6 2>/dev/null || echo "")
RESET=$(tput sgr0 2>/dev/null || echo "")

info(){ echo -e "${GREEN}[INFO]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
err(){ echo -e "${RED}[ERROR]${RESET} $*"; }

DERP_SERVICE="derper"
TAILSCALE_SERVICE="tailscaled"
DERP_CERTDIR="/var/lib/derper/certs"
DERP_SYSTEMD_UNIT="/etc/systemd/system/derper.service"
DERPMAP_PATH="/etc/tailscale/derpmap.json"
CRON_FILE="/etc/cron.d/derper-renew"

_pause(){ read -rp $'\n按回车返回菜单'; }

# 解析 ExecStart 中的 hostname
get_derp_hostname(){
    if [[ -f "${DERP_SYSTEMD_UNIT}" ]]; then
        awk -F'--hostname ' '/ExecStart/ {print $2; exit}' "${DERP_SYSTEMD_UNIT}" | awk '{print $1}' || true
    else
        echo ""
    fi
}

DERP_DEFAULT_HOSTNAME="$(get_derp_hostname)"
DERP_IP="$(dig +short "${DERP_DEFAULT_HOSTNAME:-}" A 2>/dev/null | tail -n1 || true)"

show_header(){
    clear
    echo -e "${CYAN}=== td v2.0 — DERP 管理工具 ===${RESET}"
    echo
}

menu(){
    show_header
    echo "1) 查看 DERP 服务状态"
    echo "2) 重启 DERP（并显示状态与日志）"
    echo "3) 停止 DERP（并显示状态）"
    echo "4) 生成 DERP Map（在界面显示，便于复制）"
    echo "5) 查看证书与到期时间"
    echo "6) 卸载本项目（彻底、带备份）"
    echo "0) 退出"
    echo
    read -rp "请选择: " opt
    case "$opt" in
        1) status_derp ;;
        2) restart_derp ;;
        3) stop_derp ;;
        4) gen_derpmap ;;
        5) show_cert ;;
        6) uninstall_project ;;
        0) exit 0 ;;
        *) echo "无效选项"; _pause; menu ;;
    esac
}

status_derp(){
    show_header
    echo -e "${CYAN}-- DERP 服务状态 --${RESET}"
    if systemctl status "${DERP_SERVICE}" >/dev/null 2>&1; then
        systemctl status "${DERP_SERVICE}" --no-pager || true
        echo
        echo -e "${CYAN}最后 20 行日志:${RESET}"
        journalctl -u "${DERP_SERVICE}" -n 20 --no-pager || true
    else
        warn "未检测到 ${DERP_SERVICE}.service"
    fi
    _pause; menu
}

restart_derp(){
    show_header
    info "正在重启 ${DERP_SERVICE}..."
    if systemctl cat "${DERP_SERVICE}" >/dev/null 2>&1; then
        sudo systemctl restart "${DERP_SERVICE}" || warn "重启失败"
        sleep 1
        echo
        echo -e "${CYAN}最新状态:${RESET}"
        systemctl status "${DERP_SERVICE}" --no-pager || true
        echo
        echo -e "${CYAN}最近 20 行日志:${RESET}"
        journalctl -u "${DERP_SERVICE}" -n 20 --no-pager || true
    else
        err "未找到 ${DERP_SERVICE}.service"
    fi
    _pause; menu
}

stop_derp(){
    show_header
    info "正在停止 ${DERP_SERVICE}..."
    if systemctl cat "${DERP_SERVICE}" >/dev/null 2>&1; then
        sudo systemctl stop "${DERP_SERVICE}" || warn "停止失败"
        sleep 1
        echo
        echo -e "${CYAN}当前服务状态:${RESET}"
        systemctl status "${DERP_SERVICE}" --no-pager || true

        if systemctl is-active --quiet "${DERP_SERVICE}"; then
            warn "服务仍在运行，可能被自动重启"
        else
            info "已停止"
        fi
    else
        warn "未检测到 ${DERP_SERVICE}.service"
    fi
    _pause; menu
}

is_ipv4(){
    local ip=$1
    if [[ -z "$ip" ]]; then return 1; fi
    if echo "$ip" | grep -E -q '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        IFS='.' read -r a b c d <<< "$ip"
        for x in $a $b $c $d; do
            (( x>=0 && x<=255 )) || return 1
        done
        return 0
    fi
    return 1
}

gen_derpmap(){
    show_header
    echo -e "${CYAN}生成完整 DERP ACL JSON（可直接替换控制台全部内容）${RESET}"

    # ---------------------------
    # 自动检测默认 Region 值
    # ---------------------------
    read -rp "RegionID（默认: 900，回车采用，输入修改）: " regionid
    regionid=${regionid:-900}

    read -rp "RegionCode（默认: CN，回车采用，输入修改）: " regioncode
    regioncode=${regioncode:-CN}

    read -rp "RegionName（默认: DERP-CN，回车采用，输入修改）: " regionname
    regionname=${regionname:-"DERP-CN"}

    # ---------------------------
    # 自动检测 DERP 主机名
    # 优先顺序：
    #   1. systemd --hostname
    #   2. /etc/letsencrypt/live/*
    #   3. fallback: derp.example.com
    # ---------------------------
    detect_hostname=""

    # 1) 从 systemd 取
    detect_hostname=$(get_derp_hostname || true)

    # 2) 从证书目录 fallback
    if [[ -z "$detect_hostname" ]]; then
        le_dir=$(find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1)
        if [[ -n "$le_dir" ]]; then
            detect_hostname=$(basename "$le_dir")
        fi
    fi

    # 3) fallback
    detect_hostname=${detect_hostname:-"derp.example.com"}

    read -rp "DERP 主机名（默认: ${detect_hostname}，回车采用，输入修改）: " host
    host=${host:-$detect_hostname}

    # ---------------------------
    # 自动检测公网 IPv4
    #   优先从 DNS 解析 hostname
    #   再 fallback 公网 IP
    # ---------------------------
    ip_from_dns=$(dig +short "$host" A 2>/dev/null | tail -n1)
    if [[ -n "$ip_from_dns" ]]; then
        default_ip="$ip_from_dns"
    else
        # fallback：获取真实公网 IP
        default_ip=$(curl -4s https://ipinfo.io/ip 2>/dev/null)
        # 再 fallback：hostname -I
        default_ip=${default_ip:-$(hostname -I | awk '{print $1}')}
    fi
    default_ip=${default_ip:-"0.0.0.0"}

    read -rp "DERP IPv4（默认: ${default_ip}，回车采用，输入修改）: " ip
    ip=${ip:-$default_ip}

    # ---------------------------
    # 输出完整 ACL JSON
    # ---------------------------
cat <<EOF

================================================================================
⚠ 请复制下面所有内容，并粘贴到控制台中完全替换当前 JSON！
控制台链接：
👉 https://login.tailscale.com/admin/acls/file

这是一个完整可用的 ACL + DERP Map 配置文件，保存即可立即生效。
================================================================================


{
  "derpMap": {
    "OmitDefaultRegions": true,
    "Regions": {
      "${regionid}": {
        "RegionID": ${regionid},
        "RegionCode": "${regioncode}",
        "RegionName": "${regionname}",
        "Nodes": [
          {
            "Name": "${host}",
            "RegionID": ${regionid},
            "HostName": "${host}",
            "IPv4": "${ip}",
            "STUNPort": 3478,
            "DERPPort": 443
          }
        ]
      }
    }
  },

  "acls": [
    {
      "action": "accept",
      "src": ["*"],
      "dst": ["*:*"]
    }
  ],

  "ssh": []
}

================================================================================
⚠ 完整 JSON 到此结束。
粘贴 → 保存 → 立即生效
================================================================================

EOF

    _pause
    menu
}

show_cert(){
    show_header
    echo -e "${CYAN}证书检测${RESET}"

    local found=0

    # Let's Encrypt
    if [[ -n "${DERP_DEFAULT_HOSTNAME}" ]]; then
        local lepath="/etc/letsencrypt/live/${DERP_DEFAULT_HOSTNAME}/fullchain.pem"
        if [[ -f "$lepath" ]]; then
            info "检测到 Let’s Encrypt 证书"
            openssl x509 -in "$lepath" -noout -subject -dates -text || true
            found=1
        fi
    fi

    # local certdir
    if [[ -d "$DERP_CERTDIR" ]]; then
        certs=("$DERP_CERTDIR"/*.crt)
        if [[ -e "${certs[0]}" ]]; then
            info "检测到 derper 本地证书"
            for c in "${certs[@]}"; do
                openssl x509 -in "$c" -noout -subject -dates -text || true
            done
            found=1
        fi
    fi

    [[ $found -eq 0 ]] && warn "未找到可识别证书"

    _pause; menu
}

uninstall_project(){
    show_header
    echo -e "${YELLOW}将卸载本项目并备份${RESET}"
    read -rp "输入 yes 确认操作: " yn
    [[ "$yn" != "yes" ]] && { info "取消"; _pause; menu; }

    backup_dir="/root/td-derper-backup-$(date +%Y%m%d%H%M%S)"
    sudo mkdir -p "$backup_dir"
    info "备份目录: $backup_dir"

    # stop & disable derper
    if systemctl list-units --type=service --all | grep -q "^${DERP_SERVICE}.service"; then
        sudo systemctl stop "$DERP_SERVICE" || true
        sudo systemctl disable "$DERP_SERVICE" || true
        [[ -f "$DERP_SYSTEMD_UNIT" ]] && sudo cp "$DERP_SYSTEMD_UNIT" "$backup_dir" && sudo rm -f "$DERP_SYSTEMD_UNIT"
    fi

    # stop & disable tailscaled
    if systemctl list-units --type=service --all | grep -q "^${TAILSCALE_SERVICE}.service"; then
        sudo systemctl stop "$TAILSCALE_SERVICE" || true
        sudo systemctl disable "$TAILSCALE_SERVICE" || true
    fi

    sudo systemctl daemon-reload || true

    for p in /usr/local/bin/derper /usr/local/bin/td /opt/derper /var/lib/derper "$DERPMAP_PATH" "$CRON_FILE"; do
        [[ -e "$p" ]] && sudo cp -r "$p" "$backup_dir" && sudo rm -rf "$p"
    done

    info "卸载完成，备份在: $backup_dir"
    _pause; menu
}

# main
menu
