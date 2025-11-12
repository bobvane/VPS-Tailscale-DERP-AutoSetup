#!/usr/bin/env bash
# td v1.5 - DERP & tailscale 管理工具 (彩色交互)
# 放到 /usr/local/bin/td 并 chmod +x /usr/local/bin/td
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
DERP_SYSUNIT="/etc/systemd/system/derper.service"
DERP_DEFAULT_HOSTNAME="$(awk -F'--hostname ' '/ExecStart/ {print $2; exit}' ${DERP_SYSUNIT} 2>/dev/null | awk '{print $1}' || true)"
DERP_IP="$(dig +short ${DERP_DEFAULT_HOSTNAME} A | tail -n1 || true)"

_pause(){ read -rp $'\n按回车返回菜单'; }

show_header(){
  clear
  echo -e "${CYAN}=== td v1.5 — DERP & Tailscale 管理工具 ===${RESET}"
  echo
}

menu(){
  show_header
  echo "1) 查看 DERP 服务状态"
  echo "2) 重启 DERP 服务"
  echo "3) 停止 DERP 服务"
  echo "4) 查看 tailscaled 状态"
  echo "5) 生成 derpmap.json 并保存到 /etc/tailscale/derpmap.json"
  echo "6) 查看证书信息"
  echo "7) 注册 Tailscale 客户端（执行 tailscale up）"
  echo "8) 触发证书更新（certbot renew）并重启 DERP"
  echo "9) 卸载本项目（清理文件）"
  echo "0) 退出"
  echo
  read -rp "请选择: " opt
  case "$opt" in
    1) status_derp ;;
    2) restart_derp ;;
    3) stop_derp ;;
    4) status_tailscaled ;;
    5) gen_derpmap ;;
    6) show_cert ;;
    7) register_tailscale ;;
    8) renew_cert ;;
    9) uninstall_project ;;
    0) exit 0 ;;
    *) echo "无效选项"; _pause; menu ;;
  esac
}

status_derp(){
  systemctl status ${DERP_SERVICE} --no-pager || true
  _pause; menu
}
restart_derp(){
  sudo systemctl restart ${DERP_SERVICE} && info "已重启 ${DERP_SERVICE}" || warn "重启失败"
  _pause; menu
}
stop_derp(){
  sudo systemctl stop ${DERP_SERVICE} && info "已停止 ${DERP_SERVICE}" || warn "停止失败"
  _pause; menu
}
status_tailscaled(){
  systemctl status ${TAILSCALE_SERVICE} --no-pager || true
  echo
  if command -v tailscale >/dev/null 2>&1; then
    tailscale status || true
  fi
  _pause; menu
}

gen_derpmap(){
  read -rp "请输入 RegionID (默认 900): " regionid
  regionid=${regionid:-900}
  read -rp "请输入 RegionCode (默认 CN): " regioncode
  regioncode=${regioncode:-CN}
  read -rp "请输入 RegionName (默认 China Private DERP): " regionname
  regionname=${regionname:-"China Private DERP"}

  hostname="${DERP_DEFAULT_HOSTNAME:-derp.example.com}"

  if [[ -z "${DERP_IP}" ]]; then
    read -rp "请输入 DERP IPv4 地址: " ip
  else
    ip="${DERP_IP}"
  fi

  # 确保目标目录存在
  mkdir -p /etc/tailscale

  # 写入 derpmap.json（并捕捉错误）
  {
    cat <<EOF >/etc/tailscale/derpmap.json
{
  "Regions": {
    "${regionid}": {
      "RegionID": ${regionid},
      "RegionCode": "${regioncode}",
      "RegionName": "${regionname}",
      "Nodes": [
        {
          "Name": "${hostname}",
          "RegionID": ${regionid},
          "HostName": "${hostname}",
          "IPv4": "${ip}",
          "STUNPort": 3478,
          "DERPPort": 443
        }
      ]
    }
  }
}
EOF
  } || {
    err "写入 derpmap.json 失败，请检查权限或路径。"
    _pause; menu
  }

  # 验证文件是否写入成功
  if [[ -s /etc/tailscale/derpmap.json ]]; then
    info "✅ 已成功生成 /etc/tailscale/derpmap.json"
    echo "-------- 文件预览 --------"
    head -n 15 /etc/tailscale/derpmap.json
    echo "--------------------------"
  else
    err "❌ 生成失败，文件为空或未创建。"
  fi

  _pause; menu
}

show_cert(){
  echo
  echo -e "${CYAN}证书目录: ${DERP_CERTDIR}${RESET}"
  ls -l "${DERP_CERTDIR}" 2>/dev/null || echo "目录不存在或为空"
  if [[ -f "${DERP_CERTDIR}/${DERP_DEFAULT_HOSTNAME}.crt" ]]; then
    echo
    echo "证书到期信息:"
    openssl x509 -in "${DERP_CERTDIR}/${DERP_DEFAULT_HOSTNAME}.crt" -noout -dates || true
  fi
  _pause; menu
}

register_tailscale(){
  echo
  info "开始注册本机 tailscale 客户端..."
  systemctl start ${TAILSCALE_SERVICE} || true
  if ! command -v tailscale >/dev/null 2>&1; then
    err "当前系统未安装 tailscale 客户端"
    _pause; menu
  fi
  echo "执行: tailscale up --ssh"
  echo "注意：该命令会输出一个需要在浏览器打开的认证链接（login.tailscale.com），请在浏览器中登录以完成注册。"
  read -rp "确认现在执行 tailscale up 并显示认证链接？(y/N): " confirm
  if [[ "${confirm,,}" != "y" ]]; then
    info "已取消注册"
    _pause; menu
  fi

  # 使用 tailscale up --ssh 来触发登录链接（交互可能需要浏览器）
  tailscale up --ssh || true

  echo
  info "如果出现认证链接，请复制并在浏览器中打开以登录并授权本设备。"
  echo "登录完成后可运行: tailscale status 验证本机已加入网络。"
  _pause; menu
}

renew_cert(){
  info "触发 certbot renew（尝试续签），成功会重启 derper"
  if ! command -v certbot >/dev/null 2>&1; then
    err "未检测到 certbot，请先安装"
    _pause; menu
  fi
  certbot renew --quiet || { warn "certbot renew 返回非零，查看日志"; }
  systemctl restart ${DERP_SERVICE} || warn "重启 derper 失败"
  _pause; menu
}

uninstall_project(){
  read -rp "确认卸载并删除 derper/td 文件? (y/N): " yn
  if [[ "${yn,,}" != "y" ]]; then
    info "取消卸载"
    _pause; menu
  fi

  echo
  warn "⚠ 正在停止并移除所有相关服务与文件..."

  # 停止并禁用服务
  systemctl stop derper 2>/dev/null && info "已停止 derper 服务" || warn "derper 未运行或停止失败"
  systemctl disable derper 2>/dev/null || true
  systemctl stop tailscaled 2>/dev/null && info "已停止 tailscaled 服务" || true
  systemctl disable tailscaled 2>/dev/null || true

  # 清理 systemd 配置
  rm -f /etc/systemd/system/derper.service
  systemctl daemon-reload || true
  systemctl reset-failed || true

  # 删除程序与数据目录
  rm -rf /opt/derper /var/lib/derper /usr/local/bin/derper /tmp/tailscale-src
  rm -f /usr/local/bin/td
  rm -f /etc/tailscale/derpmap.json
  rm -f /etc/cron.d/derper-renew

  # 清理日志
  find /var/log -type f -name "*derper*" -delete 2>/dev/null || true

  # 最终确认
  info "✅ 卸载完成，DERP 服务及相关文件已彻底清除。"
  echo "（如需重新安装，可直接执行 install_cn.sh）"
  exit 0
}

# 主循环
while true; do
  menu
done
