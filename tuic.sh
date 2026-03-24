#!/usr/bin/env bash
# 仅使用 sing-box 内核安装 tuic 节点 (适配 Alpine / Debian / Ubuntu / CentOS)

set -eo pipefail

WORK_DIR="/etc/sing-box"
CONF_FILE="$WORK_DIR/config.json"
BIN_FILE="/usr/local/bin/sing-box"

SERVER_IP=""
TUIC_PORT=4443
TUIC_UUID=""
TUIC_PASSWORD=""
TLS_SERVER="addons.mozilla.org"
FINGERPRINT=""

log() { echo -e "\033[32m[INFO]\033[0m $1"; }
err() { echo -e "\033[31m[ERROR]\033[0m $1" >&2; exit 1; }

check_root() { 
  if [ "$(id -u)" != "0" ]; then 
    err "请使用 root 执行"
  fi 
}

install_deps() {
  log "安装依赖..."
  if [ -f /etc/alpine-release ]; then
    apk update && apk add --no-cache curl openssl jq tar bash gcompat libstdc++
  elif [ -f /etc/debian_version ]; then
    apt-get update && apt-get install -y curl openssl jq tar bash
  elif [ -f /etc/redhat-release ]; then
    yum install -y curl openssl jq tar bash
  else
    err "不支持的系统"
  fi
}

input_params() {
  local ip
  ip=$(curl -sL https://ipinfo.io/ip || echo "")
  read -p "请输入服务器IP [默认 $ip]: " SERVER_IP
  SERVER_IP=${SERVER_IP:-$ip}

  read -p "请输入端口 [默认 $TUIC_PORT]: " port
  TUIC_PORT=${port:-$TUIC_PORT}

  # 兼容所有系统的 UUID 生成
  TUIC_UUID=$(openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')
  TUIC_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
  
  log "生成的 UUID: $TUIC_UUID"
  log "生成的 PASS: $TUIC_PASSWORD"
}

gen_cert() {
  mkdir -p "$WORK_DIR"
  log "生成自签证书 (CN=$TLS_SERVER)..."
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK_DIR/tuic.key" \
    -out "$WORK_DIR/tuic.crt" \
    -days 3650 -subj "/CN=$TLS_SERVER" 2>/dev/null
  
  # 最兼容的 SHA256 base64 指纹提取方式
  FINGERPRINT=$(openssl x509 -in "$WORK_DIR/tuic.crt" -noout -pubkey | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -binary | openssl enc -base64)
}

download_singbox() {
  log "获取 sing-box 最新稳定版版本号..."
  
  # 使用 curl + jq 获取最新 release，这是最严谨的做法
  LATEST_VERSION=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/^v//')
  
  if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
    err "无法获取最新版本号，请检查网络或 Github API 限制。"
  fi
  log "当前最新版本: v${LATEST_VERSION}"

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) SB_ARCH="amd64" ;;
    aarch64) SB_ARCH="arm64" ;;
    *) err "不支持架构: $ARCH" ;;
  esac
  
  DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${SB_ARCH}.tar.gz"
  log "下载 sing-box: $DOWNLOAD_URL"
  
  # 必须使用 curl -L 支持重定向，避免下载到无效文件导致 tar 报错
  curl -sL -o /tmp/sb.tar.gz "$DOWNLOAD_URL"
  
  tar -xzf /tmp/sb.tar.gz -C /tmp
  cp /tmp/sing-box-${LATEST_VERSION}-linux-${SB_ARCH}/sing-box "$BIN_FILE"
  chmod +x "$BIN_FILE"
  rm -rf /tmp/sing-box-* /tmp/sb.tar.gz
}

gen_server_config() {
  log "生成 sing-box 服务端配置..."
  cat > "$CONF_FILE" <<EOF
{
  "log": {
    "level": "info"
  },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $TUIC_PORT,
      "users": [
        {
          "uuid": "$TUIC_UUID",
          "password": "$TUIC_PASSWORD"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$WORK_DIR/tuic.crt",
        "key_path": "$WORK_DIR/tuic.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF
}

install_service() {
  log "配置系统服务..."
  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=$BIN_FILE run -c $CONF_FILE
Restart=on-failure
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now sing-box
    log "服务已通过 systemctl 启动"
  elif [ -f /sbin/openrc-run ]; then
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
command="$BIN_FILE"
command_args="run -c $CONF_FILE"
command_background=yes
pidfile="/run/sing-box.pid"
depend() { need net; }
EOF
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box start
    log "服务已通过 openrc 启动"
  else
    log "未检测到 systemd 或 openrc，请手动后台运行: $BIN_FILE run -c $CONF_FILE"
  fi
}

show_client_info() {
  local V2RAYN_LINK="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${SERVER_IP}:${TUIC_PORT}?sni=${TLS_SERVER}&alpn=h3&allowInsecure=1&congestion_control=bbr#tuic-node"

  echo
  echo -e "\033[32m=============== 安装完成 =================\033[0m"
  echo "服务端地址 : $SERVER_IP"
  echo "端口       : $TUIC_PORT"
  echo "UUID       : $TUIC_UUID"
  echo "Password   : $TUIC_PASSWORD"
  echo "SNI        : $TLS_SERVER"
  echo "sing-box   : v${LATEST_VERSION}"
  echo -e "\033[32m==========================================\033[0m"
  echo
  echo ">>> [v2rayN / Nekobox 链接]"
  echo -e "\033[36m${V2RAYN_LINK}\033[0m"
  echo
  echo ">>> [客户端 sing-box Outbound 配置]"
  cat <<EOF
{
  "type": "tuic",
  "tag": "tuic-out",
  "server": "$SERVER_IP",
  "server_port": $TUIC_PORT,
  "uuid": "$TUIC_UUID",
  "password": "$TUIC_PASSWORD",
  "congestion_control": "bbr",
  "udp_relay_mode": "native",
  "zero_rtt_handshake": false,
  "heartbeat": "10s",
  "tls": {
    "enabled": true,
    "server_name": "$TLS_SERVER",
    "certificate_public_key_sha256": ["$FINGERPRINT"],
    "alpn": ["h3"]
  }
}
EOF
}

main() {
  check_root
  install_deps
  input_params
  gen_cert
  download_singbox
  gen_server_config
  install_service
  show_client_info
}

main
