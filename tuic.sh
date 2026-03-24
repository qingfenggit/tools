#!/usr/bin/env bash

set -euo pipefail

#================ 基本配置 ================
TUIC_VERSION="v1.0.0"                # tuic 服务端版本，可按需修改
TUIC_BIN_DIR="/usr/local/bin"
TUIC_BIN="${TUIC_BIN_DIR}/tuic-server"
TUIC_CONF_DIR="/etc/tuic"
TUIC_CONF_FILE="${TUIC_CONF_DIR}/config.json"
TUIC_SERVICE_FILE="/etc/systemd/system/tuic.service"

# 默认参数（可通过交互覆盖）
SERVER_IP=""
TUIC_PORT=4443
TUIC_UUID=""                         # 自动生成
TUIC_PASSWORD=""                     # 自动生成
TUIC_CONGESTION_CONTROL="bbr"        # bbr / cubic / new_reno …
TLS_SERVER="addons.mozilla.org"      # SNI

SELF_SIGNED_CERT=""
SELF_SIGNED_KEY=""

#================ 工具函数 ================
log()  { echo -e "\033[32m[INFO]\033[0m $*"; }
err()  { echo -e "\033[31m[ERROR]\033[0m $*" >&2; exit 1; }
ask()  { read -rp "$1" "$2"; }

check_root() {
  [[ $EUID -ne 0 ]] && err "请用 root 运行：sudo -i 后再执行该脚本"
}

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    err "无法检测系统类型"
  fi
}

install_deps() {
  log "安装依赖..."
  case "$OS" in
    debian|ubuntu)
      apt-get update -y
      apt-get install -y wget curl jq openssl
      ;;
    centos|rocky|almalinux)
      yum install -y epel-release
      yum install -y wget curl jq openssl
      ;;
    fedora)
      dnf install -y wget curl jq openssl
      ;;
    alpine)
      apk add --no-cache wget curl jq openssl
      ;;
    arch)
      pacman -Sy --noconfirm wget curl jq openssl
      ;;
    *)
      err "暂不支持的系统：$OS"
      ;;
  esac
}

download_tuic() {
  mkdir -p "$TUIC_BIN_DIR"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64)  ARCH_TAG="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) ARCH_TAG="aarch64-unknown-linux-gnu" ;;
    *)
      err "暂不支持的架构：$ARCH"
      ;;
  esac

  local URL="https://github.com/EAimTY/tuic/releases/download/${TUIC_VERSION}/tuic-server-${ARCH_TAG}"
  log "下载 tuic 服务端：$URL"
  wget -O "$TUIC_BIN" "$URL"
  chmod +x "$TUIC_BIN"
}

gen_cert() {
  mkdir -p "$TUIC_CONF_DIR"
  SELF_SIGNED_CERT="${TUIC_CONF_DIR}/tuic.crt"
  SELF_SIGNED_KEY="${TUIC_CONF_DIR}/tuic.key"

  log "生成自签证书..."
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$SELF_SIGNED_KEY" \
    -out "$SELF_SIGNED_CERT" \
    -days 3650 \
    -subj "/CN=${TLS_SERVER}"
}

gen_uuid_and_password() {
  if [ -z "$TUIC_UUID" ]; then
    TUIC_UUID=$(cat /proc/sys/kernel/random/uuid)
  fi

  if [ -z "$TUIC_PASSWORD" ]; then
    TUIC_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
  fi
}

input_params() {
  local WAN4 WAN6 TMP_PORT TMP_CC TMP_SNI
  WAN4=$(curl -4s https://ip.gs || true)
  WAN6=$(curl -6s https://ip.gs || true)

  log "检测到 IPv4: ${WAN4:-无}, IPv6: ${WAN6:-无}"
  ask "请输入服务器 IP [默认: ${WAN4:-$WAN6}]: " SERVER_IP
  SERVER_IP=${SERVER_IP:-${WAN4:-$WAN6}}
  [ -z "$SERVER_IP" ] && err "服务器 IP 不能为空"

  ask "请输入 tuic 监听端口 [默认: $TUIC_PORT]: " TMP_PORT
  TUIC_PORT=${TMP_PORT:-$TUIC_PORT}

  ask "拥塞控制算法 [默认: $TUIC_CONGESTION_CONTROL]: " TMP_CC
  TUIC_CONGESTION_CONTROL=${TMP_CC:-$TUIC_CONGESTION_CONTROL}

  ask "TLS server_name / SNI [默认: $TLS_SERVER]: " TMP_SNI
  TLS_SERVER=${TMP_SNI:-$TLS_SERVER}

  gen_uuid_and_password
  log "自动生成 UUID : $TUIC_UUID"
  log "自动生成 PASS : $TUIC_PASSWORD"
}

write_config() {
  log "生成 tuic 配置: $TUIC_CONF_FILE"
  cat > "$TUIC_CONF_FILE" <<EOF
{
  "server": "${SERVER_IP}",
  "server_port": ${TUIC_PORT},
  "users": [
    {
      "uuid": "${TUIC_UUID}",
      "password": "${TUIC_PASSWORD}"
    }
  ],
  "congestion_control": "${TUIC_CONGESTION_CONTROL}",
  "alpn": ["h3"],
  "max_idle_time": "30s",
  "log_level": "info",
  "certificate": "${SELF_SIGNED_CERT}",
  "private_key": "${SELF_SIGNED_KEY}",
  "enable_0rtt": false
}
EOF
}

write_service() {
  log "写入 systemd 服务: $TUIC_SERVICE_FILE"
  cat > "$TUIC_SERVICE_FILE" <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
Type=simple
ExecStart=${TUIC_BIN} -c ${TUIC_CONF_FILE}
Restart=on-failure
RestartSec=5
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now tuic.service
}

gen_v2rayn_link() {
  local NAME="tuic-${SERVER_IP}-${TUIC_PORT}"
  local RAW="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${SERVER_IP}:${TUIC_PORT}?sni=${TLS_SERVER}&alpn=h3&allowInsecure=1&congestion_control=${TUIC_CONGESTION_CONTROL}#${NAME}"
  echo "$RAW"
}

gen_clash_snippet() {
  local NAME="tuic-${SERVER_IP}-${TUIC_PORT}"
  cat <<EOF
- name: "${NAME}"
  type: tuic
  server: ${SERVER_IP}
  port: ${TUIC_PORT}
  uuid: ${TUIC_UUID}
  password: ${TUIC_PASSWORD}
  alpn:
    - h3
  reduce-rtt: true
  request-timeout: 8000
  udp-relay-mode: native
  congestion-controller: ${TUIC_CONGESTION_CONTROL}
  sni: ${TLS_SERVER}
  skip-cert-verify: false
EOF
}

show_info() {
  log "tuic 安装完成！"
  echo
  echo "=========== tuic 节点信息 ==========="
  echo "服务器 IP      : ${SERVER_IP}"
  echo "端口           : ${TUIC_PORT}"
  echo "UUID           : ${TUIC_UUID}"
  echo "Password       : ${TUIC_PASSWORD}"
  echo "SNI            : ${TLS_SERVER}"
  echo "Congestion Ctl : ${TUIC_CONGESTION_CONTROL}"
  echo "证书路径       : ${SELF_SIGNED_CERT}"
  echo "私钥路径       : ${SELF_SIGNED_KEY}"
  echo "===================================="
  echo
  echo "=========== V2Ray / V2RayN 链接 ==========="
  gen_v2rayn_link
  echo "==========================================="
  echo
  echo "=========== Clash 节点片段 ================"
  gen_clash_snippet
  echo "（复制以上到 Clash 的 proxies 列表中）"
  echo "==========================================="
}

main() {
  check_root
  detect_os
  install_deps
  download_tuic
  input_params
  gen_cert
  write_config
  write_service
  show_info
}

main "\$@"
