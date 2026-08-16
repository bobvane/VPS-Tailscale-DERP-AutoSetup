# ============================================================
# Tailscale DERP 多阶段构建
# 阶段 1: 编译 derper 二进制
# 阶段 2: 最小运行镜像
#
# 构建时通过 --build-arg VERSION=<tailscale版本tag> 指定版本
# 例: docker build --build-arg VERSION=v1.72.0 -t derper .
# 不指定则默认使用最新
# ============================================================

# ---------- 阶段 1: 编译 ----------
ARG VERSION=latest
FROM golang:1.24-alpine AS builder

# 国内构建可用 GOPROXY 加速（默认走官方，Actions 环境无障碍）
ARG GOPROXY_ENV=https://proxy.golang.org,direct
ARG VERSION=latest

ENV GOPROXY=${GOPROXY_ENV} \
    CGO_ENABLED=0

WORKDIR /build

# 安装 git（go install 需要解析 tailscale 源码）
RUN apk add --no-cache git

# 编译 derper，VERSION 可以是 tag(v1.72.0) 或 latest
RUN if [ "${VERSION}" != "latest" ]; then \
      go install tailscale.com/cmd/derper@${VERSION}; \
    else \
      go install tailscale.com/cmd/derper@latest; \
    fi

# ---------- 阶段 2: 运行 ----------
FROM alpine:3.20

# 证书：derper 需要根证书来验证出站连接（ACME/LE）
# 同时自签名也需要 openssl（供脚本在容器内检查证书）
RUN apk add --no-cache ca-certificates openssl tzdata \
    && mkdir -p /app/certs

# 复制编译好的 derper
COPY --from=builder /go/bin/derper /usr/local/bin/derper

# 复制入口脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# DERP 服务端口（TLS）
# STUN 端口（UDP）也在容器内开放，通过 3478/udp 映射
EXPOSE 443 80 3478/udp

ENV DERP_CERT_MODE=manual \
    DERP_CERT_DIR=/app/certs \
    DERP_ADDR=:443 \
    DERP_HTTP_PORT=80 \
    DERP_STUN=true \
    DERP_STUN_PORT=3478 \
    DERP_VERIFY_CLIENTS=false

ENTRYPOINT ["/entrypoint.sh"]