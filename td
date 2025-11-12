#!/usr/bin/env bash
# td v1.4 - VPS-Tailscale-DERP 管理工具
# 作者: bobvane
# 彩色终端 + 实用管理 + 一键卸载

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
CYAN=$(tput setaf 6)
RESET=$(tput sgr0)

title(){
  echo -e "\n${CYAN}╭────────────────────────────╮${RESET}"
  echo -e "${CYAN}│ VPS-Tailscale-DERP 管理工具 │${RESET}"
  echo -e "${CYAN}├────────────────────────────┤${RESET}"
}

pause(){ read -rp $'\n按回车键返回菜单...'; }

check_status(){
  systemctl is-active --quiet derper && echo "${GREEN}✔ 正在运行${RESET}" || echo "${RED}✘ 未运行${RESET}"
}

status_menu(){
  echo -e "\n${YELLOW}🔍 DERP 服务状态:${RESET}"
  systemctl status derper --no-pager -l | grep -E 'Active|Main PID|Loaded'
  echo -e "\n${CYAN}监听端口:${RESET}"
  ss -tuln | grep 443 || echo "未检测到端口监听"
  pause
}

restart_menu(){
  echo -e "\n${YELLOW}♻ 正在重启 DERP 服务...${RESET}"
  systemctl restart derper && sleep 2
  echo -e "${GREEN}✅ 重启完成${RESET}"
  pause
}

log_menu(){
  echo -e "\n${YELLOW}📜 最近 30 条日志:${RESET}\n"
  journalctl -u derper --no-pager -n 30
  pause
}

ssl_renew_menu(){
  echo -e "\n${YELLOW}🔐 重新申请 SSL 证书...${RESET}"
  systemctl stop derper
  rm -rf /var/lib/derper/certs/*
  systemctl start derper
  sleep 5
  [[ -f /var/lib/derper/certs/*.crt ]] && echo "${GREEN}✅ 证书更新成功${RESET}" || echo "${RED}❌ 证书申请失败${RESET}"
  pause
}

uninstall_menu(){
  echo -e "\n${RED}⚠️ 彻底卸载 DERP + Go 环境 + td${RESET}"
  read -rp "确认继续？(y/N): " yn
  [[ "$yn" != [Yy] ]] && return
  systemctl stop derper 2>/dev/null || true
  systemctl disable derper 2>/dev/null || true
  rm -f /etc/systemd/system/derper.service
  systemctl daemon-reload
  killall derper 2>/dev/null || true
  rm -rf /opt/derper /var/lib/derper /usr/local/bin/derper /usr/local/go /etc/profile.d/99-go-path.sh
  rm -f /usr/local/bin/td
  echo -e "${GREEN}✅ 卸载完成${RESET}"
  pause
  exit 0
}

# ────────────── 主菜单 ──────────────
while true; do
  clear
  title
  echo -e "DERP 状态：$(check_status)\n"
  echo "1) 查看服务状态"
  echo "2) 重启 DERP 服务"
  echo "3) 查看运行日志"
  echo "4) 重新申请 SSL 证书"
  echo "5) 卸载 DERP + Go 环境"
  echo -e "${CYAN}0) 退出${RESET}"
  echo "──────────────────────────────"
  read -rp "请选择操作编号: " opt
  case "$opt" in
    1) status_menu ;;
    2) restart_menu ;;
    3) log_menu ;;
    4) ssl_renew_menu ;;
    5) uninstall_menu ;;
    0) echo "再见，少年！"; exit 0 ;;
    *) echo "${RED}无效选项${RESET}"; sleep 1 ;;
  esac
done
