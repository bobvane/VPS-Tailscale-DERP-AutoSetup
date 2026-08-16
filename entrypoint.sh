#!/bin/sh
# ============================================================
# Tailscale DERP 容器入口脚本
#
# 根据环境变量生成 derper 启动命令
# 支持三种证书模式（继承设计文档需求 11）:
#   1. letsencrypt(域名)   — derper 自动申请 LE 证书
#   2. letsencrypt(纯IP)   — derper 自动申请 LE IP 证书
#   3. manual(自签名)      — 无证书时用 openssl 生成自签名
#
# 关键环境变量:
#   DERP_DOMAIN      域名或 IP（必需）
#   DERP_CERT_MODE   证书模式: manual|letsencrypt
#   DERP_CERT_DIR    证书目录 (默认 /app/certs)
#   DERP_ADDR        监听地址 (默认 :443)
#   DERP_HTTP_PORT   HTTP 端口，-1 禁用 (默认 80)
#   DERP_STUN        启用 STUN (true/false)
#   DERP_STUN_PORT   STUN 端口 (默认 3478)
#   DERP_VERIFY_CLIENTS  防白嫖 (true/false)
# ============================================================

set -e

# ---------- 默认值 ----------
DERP_DOMAIN="${DERP_DOMAIN:-}"
DERP_CERT_MODE="${DERP_CERT_MODE:-manual}"
DERP_CERT_DIR="${DERP_CERT_DIR:-/app/certs}"
DERP_ADDR="${DERP_ADDR:-:443}"
DERP_HTTP_PORT="${DERP_HTTP_PORT:-80}"
DERP_STUN="${DERP_STUN:-true}"
DERP_STUN_PORT="${DERP_STUN_PORT:-3478}"
DERP_VERIFY_CLIENTS="${DERP_VERIFY_CLIENTS:-false}"

# ---------- 参数组装 ----------
ARGS="-hostname ${DERP_DOMAIN}"
ARGS="${ARGS} -certmode ${DERP_CERT_MODE}"
ARGS="${ARGS} -certdir ${DERP_CERT_DIR}"
ARGS="${ARGS} -a ${DERP_ADDR}"
ARGS="${ARGS} -http-port ${DERP_HTTP_PORT}"

if [ "${DERP_STUN}" = "true" ]; then
  ARGS="${ARGS} -stun"
  ARGS="${ARGS} -stun-port ${DERP_STUN_PORT}"
fi

if [ "${DERP_VERIFY_CLIENTS}" = "true" ]; then
  ARGS="${ARGS} -verify-clients"
fi

# ---------- 自签名证书处理 ----------
# 仅在 manual 模式下，如果证书目录没有证书文件，则生成自签名证书
if [ "${DERP_CERT_MODE}" = "manual" ]; then
  mkdir -p "${DERP_CERT_DIR}"
  # derper 的 manual 模式需要明确的 cert 文件（<hostname>.crt/.key）
  CERT_FILE="${DERP_CERT_DIR}/${DERP_DOMAIN}.crt"
  KEY_FILE="${DERP_CERT_DIR}/${DERP_DOMAIN}.key"
  if [ ! -f "${CERT_FILE}" ] || [ ! -f "${KEY_FILE}" ]; then
    echo "[entrypoint] 证书不存在，生成自签名证书 (${DERP_DOMAIN}, 3650天)..."
    # 判断是域名还是 IP，IP 用 IP SAN，域名用 DNS SAN
    if echo "${DERP_DOMAIN}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      SAN="IP:${DERP_DOMAIN}"
    else
      SAN="DNS:${DERP_DOMAIN}"
    fi
    openssl req -x509 -newkey rsa:2048 \
      -sha256 -days 3650 -nodes \
      -keyout "${KEY_FILE}" \
      -out "${CERT_FILE}" \
      -subj "/CN=${DERP_DOMAIN}" \
      -addext "subjectAltName=${SAN}" 2>/dev/null
    echo "[entrypoint] 自签名证书已生成：${CERT_FILE}"
  else
    echo "[entrypoint] 已存在证书：${CERT_FILE}"
  fi
  # manual 模式 derper 会读取 <hostname>.crt/.key
fi

# ---------- 启动 ----------
echo "[entrypoint] 启动 derper: derper ${ARGS}"
exec /usr/local/bin/derper $ARGS