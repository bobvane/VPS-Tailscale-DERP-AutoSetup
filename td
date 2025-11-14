#!/usr/bin/env bash
# td v2.0 - 精简版 DERP 管理工具（交互式）
set -euo pipefail
export LANG=zh_CN.UTF-8

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

get_derp_hostname(){ if [[ -f "${DERP_SYSTEMD_UNIT}" ]]; then awk -F'--hostname ' '/ExecStart/ {print $2; exit}' "${DERP_SYSTEMD_UNIT}" 2>/dev/null | awk '{print $1}' || true; else echo ""; fi; }

DERP_DEFAULT_HOSTNAME="$(get_derp_hostname)"
DERP_IP="$(dig +short "${DERP_DEFAULT_HOSTNAME:-}" A 2>/dev/null | tail -n1 || true)"

show_header(){ clear; echo -e "${CYAN}=== td v2.0 — DERP 管理工具 ===${RESET}\n"; }

menu(){ show_header; echo "1) 查看 DERP 服务状态"; echo "2) 重启 DERP（并显示状态与日志）"; echo "3) 停止 DERP（并显示状态）"; echo "4) 生成 DERP Map（在界面显示，便于复制）"; echo "5) 查看证书与到期时间"; echo "6) 卸载本项目（彻底、带备份）"; echo "0) 退出\n"; read -rp "请选择: " opt; case "$opt" in 1) status_derp ;; 2) restart_derp ;; 3) stop_derp ;; 4) gen_derpmap ;; 5) show_cert ;; 6) uninstall_project ;; 0) exit 0 ;; *) echo "无效选项"; _pause; menu ;; esac; }

status_derp(){ show_header; echo -e "${CYAN}-- DERP 服务状态 --${RESET}"; if systemctl list-units --type=service --all | grep -q "^${DERP_SERVICE}.service"; then systemctl status "${DERP_SERVICE}" --no-pager || true; echo -e "\n${CYAN}最后 20 行日志:${RESET}"; journalctl -u "${DERP_SERVICE}" -n 20 --no-pager || true; else warn "未检测到 ${DERP_SERVICE}.service"; fi; _pause; menu; }

restart_derp(){ show_header; info "正在重启 ${DERP_SERVICE}..."; if systemctl list-units --type=service --all | grep -q "^${DERP_SERVICE}.service"; then sudo systemctl restart "${DERP_SERVICE}" 2>/dev/null || warn "重启失败"; sleep 1; echo -e "\n${CYAN}最新状态:${RESET}"; systemctl status "${DERP_SERVICE}" --no-pager || true; echo -e "\n${CYAN}最近 20 行日志:${RESET}"; journalctl -u "${DERP_SERVICE}" -n 20 --no-pager || true; else err "未找到 ${DERP_SERVICE}.service"; fi; _pause; menu; }

stop_derp(){ show_header; info "正在停止 ${DERP_SERVICE}..."; if systemctl list-units --type=service --all | grep -q "^${DERP_SERVICE}.service"; then sudo systemctl stop "${DERP_SERVICE}" 2>/dev/null || warn "停止失败"; sleep 1; echo -e "\n${CYAN}当前服务状态:${RESET}"; systemctl status "${DERP_SERVICE}" --no-pager || true; if systemctl is-active --quiet "${DERP_SERVICE}"; then warn "服务仍在运行，可能被自动重启"; else info "已停止"; fi; else warn "未检测到 ${DERP_SERVICE}.service"; fi; _pause; menu; }

is_ipv4(){ local ip=$1; if [[ -z "$ip" ]]; then return 1; fi; if echo "$ip" | grep -E -q '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then IFS='.' read -r a b c d <<< "$ip"; for x in $a $b $c $d; do (( x>=0 && x<=255 )) || return 1; done; return 0; fi; return 1; }

gen_derpmap(){ show_header; echo -e "${CYAN}生成 DERP Map（不会写文件）${RESET}"; read -rp "RegionID (默认900): " regionid; regionid=${regionid:-900}; read -rp "RegionCode (默认CN): " regioncode; regioncode=${regioncode:-CN}; read -rp "RegionName: " regionname; regionname=${regionname:-"China Private DERP"}; hostname_input=${DERP_DEFAULT_HOSTNAME:-derp.example.com}; read -rp "DERP 主机名 (默认 ${hostname_input}): " host; host=${host:-$hostname_input}; read -rp "DERP IPv4 (默认 ${DERP_IP:-127.0.0.1}): " ip; ip=${ip:-${DERP_IP:-127.0.0.1}};

cat <<EOF

----- 复制下面的 JSON 到 Headscale/Tailscale 控制台 -----

{
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
}
----- JSON 结束 -----
EOF

_pause; menu; }

show_cert(){ show_header; echo -e "${CYAN}证书检测${RESET}"; local found=0; if [[ -n "${DERP_DEFAULT_HOSTNAME}" ]]; then lepath="/etc/letsencrypt/live/${DERP_DEFAULT_HOSTNAME}/fullchain.pem"; if [[ -f "$lepath" ]]; then info "检测到 Let’s Encrypt 证书"; openssl x509 -in "$lepath" -noout -subject -dates -text || true; found=1; fi; fi; if [[ -d "$DERP_CERTDIR" ]]; then certs=("$DERP_CERTDIR"/*.crt); if [[ -e "${certs[0]}" ]]; then info "检测到 derper 本地证书"; for c in "${certs[@]}"; do openssl x509 -in "$c" -noout -subject -dates -text || true; done; found=1; fi; fi; if [[ $found -eq 0 ]]; then warn "未找到可识别证书"; fi; _pause; menu; }

uninstall_project(){ show_header; echo -e "${YELLOW}将卸载本项目并备份${RESET}"; read -rp "输入 yes 确认操作: " yn; [[ "$yn" != "yes" ]] && { info "取消"; _pause; menu; };

backup_dir="/root/td-derper-backup-$(date +%Y%m%d%H%M%S)"; sudo mkdir -p "$backup_dir"; info "备份目录: $backup_dir";

if systemctl list-units --type=service --all | grep -q "^${DERP_SERVICE}.service"; then sudo systemctl stop "$DERP_SERVICE" || true; sudo systemctl disable "$DERP_SERVICE" || true; [[ -f "$DERP_SYSTEMD_UNIT" ]] && sudo cp "$DERP_SYSTEMD_UNIT" "$backup_dir" && sudo rm -f "$DERP_SYSTEMD_UNIT"; fi

if systemctl list-units --type=service --all | grep -q "^${TAILSCALE_SERVICE}.service"; then sudo systemctl stop "$TAILSCALE_SERVICE" || true; sudo systemctl disable "$TAILSCALE_SERVICE" || true; fi

sudo systemctl daemon-reload || true

for p in /usr/local/bin/derper /usr/local/bin/td /opt/derper /var/lib/derper "$DERPMAP_PATH" "$CR
