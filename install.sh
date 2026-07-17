#!/bin/bash

# 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "错误：必须以 root 权限运行此脚本！"
   exit 1
fi

# 设置语言环境
export LANG=en_US.UTF-8

# 覆写 jq 确保所有提取出来的 JSON 字段都不带 Windows 的 \r 回车符
jq() {
    command jq "$@" | tr -d '\r'
    return ${PIPESTATUS[0]}
}

b64_no_wrap() {
    printf '%s' "$1" | base64 -w 0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'
}

url_encode() {
    local encoded
    encoded=$(printf '%s' "$1" | command jq -sRr @uri) || return $?
    printf '%s' "$encoded" | tr -d '\r\n'
}

make_vmess_link() {
    local json="$1"
    printf '%s' "$json" | command jq -e . >/dev/null 2>&1 || return 1
    printf 'vmess://%s' "$(b64_no_wrap "$json")"
}

get_warp_credentials() {
    local warpurl
    warpurl=$(curl -sm5 -k https://warp.xijp.eu.org 2>/dev/null || wget -qO- --timeout=5 https://warp.xijp.eu.org 2>/dev/null)
    
    # 默认值
    WARP_PVK="52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A="
    WARP_IPV6="2606:4700:110:8d8d:1845:c39f:2dd5:a03a"
    WARP_RES="[215, 69, 233]"
    
    if [[ -n "$warpurl" ]] && ! printf '%s' "$warpurl" | grep -q -i "html"; then
        local tmp_pvk tmp_ipv6 tmp_res
        tmp_pvk=$(echo "$warpurl" | awk -F'：' '/Private_key/{print $2}' | xargs)
        tmp_ipv6=$(echo "$warpurl" | awk -F'：' '/IPV6/{print $2}' | xargs)
        tmp_res=$(echo "$warpurl" | awk -F'：' '/reserved/{print $2}' | xargs)
        
        [[ -n "$tmp_pvk" ]] && WARP_PVK="$tmp_pvk"
        [[ -n "$tmp_ipv6" ]] && WARP_IPV6="$tmp_ipv6"
        if [[ -n "$tmp_res" ]]; then
            if [[ ! "$tmp_res" =~ ^\[ ]]; then
                WARP_RES="[${tmp_res}]"
            else
                WARP_RES="$tmp_res"
            fi
        fi
    fi
}

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

log_info() { echo -e "${GREEN}[信息] $1${PLAIN}"; }
log_warn() { echo -e "${YELLOW}[警告] $1${PLAIN}"; }
log_err() { echo -e "${RED}[错误] $1${PLAIN}"; }

# 自动检测是否为 OpenRC (Alpine 等)
IS_OPENRC=false
IS_DIRECT=false
if [[ -x "/sbin/openrc-run" || -x "/sbin/runlevels" ]]; then
    IS_OPENRC=true
elif ! pidof systemd >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    # 非 OpenRC 也非 systemd 环境（如 WSL1、Docker、Ubuntu Desktop 无 systemd 等），使用直接进程管理
    IS_DIRECT=true
fi

# Nginx 配置目录自适应
NGINX_CONF_DIR="/etc/nginx/conf.d"
[[ -d "/etc/nginx/http.d" ]] && NGINX_CONF_DIR="/etc/nginx/http.d"

# 服务控制函数
service_start() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" start >/dev/null 2>&1
    elif $IS_DIRECT; then
        service_stop "$name" 2>/dev/null
        case "$name" in
            sing-box)
                nohup /etc/s-box/sing-box run -c /etc/s-box/sb.json >> /var/log/sing-box.log 2>&1 &
                echo $! > /etc/s-box/sing-box.pid
                ;;
            argo-tunnel)
                local _cf_args
                _cf_args=$(
                    local _am="" _at="" _ap="8401"
                    [[ -f /etc/s-box/argo.conf ]] && source /etc/s-box/argo.conf
                    _am="${ARGO_MODE:-temp}"; _at="${ARGO_TOKEN}"; _ap="${ARGO_PORT:-8401}"
                    if [[ "$_am" == "token" && -n "$_at" ]]; then
                        echo "tunnel --no-autoupdate run --token $_at"
                    else
                        echo "tunnel --url http://127.0.0.1:${_ap}"
                    fi
                )
                nohup /usr/local/bin/cloudflared $_cf_args >> /var/log/argo-tunnel.log 2>&1 &
                echo $! > /etc/s-box/argo-tunnel.pid
                ;;
            nginx)
                nginx >/dev/null 2>&1
                ;;
        esac
    else
        systemctl start "$name" >/dev/null 2>&1
    fi
}

service_stop() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" stop >/dev/null 2>&1
    elif $IS_DIRECT; then
        case "$name" in
            nginx)
                nginx -s stop >/dev/null 2>&1
                ;;
            *)
                local pidfile="/etc/s-box/${name}.pid"
                if [[ -f "$pidfile" ]]; then
                    local pid
                    pid=$(cat "$pidfile" 2>/dev/null)
                    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                        kill "$pid" 2>/dev/null
                        local i; for i in {1..10}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
                        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
                    fi
                    rm -f "$pidfile"
                fi
                ;;
        esac
    else
        systemctl stop "$name" >/dev/null 2>&1
    fi
}

service_restart() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" restart >/dev/null 2>&1
    elif $IS_DIRECT; then
        service_stop "$name"
        sleep 1
        service_start "$name"
    else
        systemctl restart "$name" >/dev/null 2>&1
    fi
}

service_enable() {
    local name=$1
    if $IS_OPENRC; then
        rc-update add "$name" default >/dev/null 2>&1
    elif $IS_DIRECT; then
        : # 直接进程模式无开机自启功能
    else
        systemctl enable "$name" >/dev/null 2>&1
    fi
}

service_disable() {
    local name=$1
    if $IS_OPENRC; then
        rc-update del "$name" default >/dev/null 2>&1
    elif $IS_DIRECT; then
        : # 直接进程模式无开机自启功能
    else
        systemctl disable "$name" >/dev/null 2>&1
    fi
}

service_is_active() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" status | grep -q "started"
    elif $IS_DIRECT; then
        case "$name" in
            nginx)
                pgrep -x nginx >/dev/null 2>&1
                ;;
            *)
                local pidfile="/etc/s-box/${name}.pid"
                if [[ -f "$pidfile" ]]; then
                    local pid
                    pid=$(cat "$pidfile" 2>/dev/null)
                    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
                else
                    return 1
                fi
                ;;
        esac
    else
        systemctl is-active --quiet "$name"
    fi
}

log_info "开始安装 Sing-box 多协议一键部署脚本..."

create_sb_tool() {
cat > /usr/local/bin/sb <<'EOF'
#!/bin/bash
# Sing-box 极简快捷管理工具

# 覆写 jq 确保所有提取出来的 JSON 字段都不带 Windows 的 \r 回车符
jq() {
    command jq "$@" | tr -d '\r'
    return ${PIPESTATUS[0]}
}

b64_no_wrap() {
    printf '%s' "$1" | base64 -w 0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'
}

url_encode() {
    local encoded
    encoded=$(printf '%s' "$1" | command jq -sRr @uri) || return $?
    printf '%s' "$encoded" | tr -d '\r\n'
}

make_vmess_link() {
    local json="$1"
    printf '%s' "$json" | command jq -e . >/dev/null 2>&1 || return 1
    printf 'vmess://%s' "$(b64_no_wrap "$json")"
}

if [[ $EUID -ne 0 ]]; then
   echo "错误：必须以 root 权限运行此脚本！"
   exit 1
fi

# 自动加载 Argo 配置
USE_NGINX="y"
ARGO_PORT=""
ARGO_TARGET_PROTOCOL=""
if [[ -f /etc/s-box/argo.conf ]]; then
    source /etc/s-box/argo.conf
fi

# 自动检测是否为 OpenRC (Alpine 等)
IS_OPENRC=false
IS_DIRECT=false
if [[ -x "/sbin/openrc-run" || -x "/sbin/runlevels" ]]; then
    IS_OPENRC=true
elif ! pidof systemd >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    IS_DIRECT=true
fi

# Nginx 配置目录自适应
NGINX_CONF_DIR="/etc/nginx/conf.d"
[[ -d "/etc/nginx/http.d" ]] && NGINX_CONF_DIR="/etc/nginx/http.d"

# 服务控制函数
service_start() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" start >/dev/null 2>&1
    elif $IS_DIRECT; then
        service_stop "$name" 2>/dev/null
        case "$name" in
            sing-box)
                nohup /etc/s-box/sing-box run -c /etc/s-box/sb.json >> /var/log/sing-box.log 2>&1 &
                echo $! > /etc/s-box/sing-box.pid
                ;;
            argo-tunnel)
                local _cf_args
                _cf_args=$(
                    local _am="" _at="" _ap="8401"
                    [[ -f /etc/s-box/argo.conf ]] && source /etc/s-box/argo.conf
                    _am="${ARGO_MODE:-temp}"; _at="${ARGO_TOKEN}"; _ap="${ARGO_PORT:-8401}"
                    if [[ "$_am" == "token" && -n "$_at" ]]; then
                        echo "tunnel --no-autoupdate run --token $_at"
                    else
                        echo "tunnel --url http://127.0.0.1:${_ap}"
                    fi
                )
                nohup /usr/local/bin/cloudflared $_cf_args >> /var/log/argo-tunnel.log 2>&1 &
                echo $! > /etc/s-box/argo-tunnel.pid
                ;;
            nginx)
                nginx >/dev/null 2>&1
                ;;
        esac
    else
        systemctl start "$name" >/dev/null 2>&1
    fi
}

service_stop() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" stop >/dev/null 2>&1
    elif $IS_DIRECT; then
        case "$name" in
            nginx)
                nginx -s stop >/dev/null 2>&1
                ;;
            *)
                local pidfile="/etc/s-box/${name}.pid"
                if [[ -f "$pidfile" ]]; then
                    local pid
                    pid=$(cat "$pidfile" 2>/dev/null)
                    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                        kill "$pid" 2>/dev/null
                        local i; for i in {1..10}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
                        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
                    fi
                    rm -f "$pidfile"
                fi
                ;;
        esac
    else
        systemctl stop "$name" >/dev/null 2>&1
    fi
}

service_restart() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" restart >/dev/null 2>&1
    elif $IS_DIRECT; then
        service_stop "$name"
        sleep 1
        service_start "$name"
    else
        systemctl restart "$name" >/dev/null 2>&1
    fi
}

service_is_active() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" status | grep -q "started"
    elif $IS_DIRECT; then
        case "$name" in
            nginx)
                pgrep -x nginx >/dev/null 2>&1
                ;;
            *)
                local pidfile="/etc/s-box/${name}.pid"
                if [[ -f "$pidfile" ]]; then
                    local pid
                    pid=$(cat "$pidfile" 2>/dev/null)
                    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
                else
                    return 1
                fi
                ;;
        esac
    else
        systemctl is-active --quiet "$name"
    fi
}

service_enable() {
    local name=$1
    if $IS_OPENRC; then
        rc-update add "$name" default >/dev/null 2>&1
    elif $IS_DIRECT; then
        : # 直接进程模式无开机自启功能
    else
        systemctl enable "$name" >/dev/null 2>&1
    fi
}

service_disable() {
    local name=$1
    if $IS_OPENRC; then
        rc-update del "$name" default >/dev/null 2>&1
    elif $IS_DIRECT; then
        : # 直接进程模式无开机自启功能
    else
        systemctl disable "$name" >/dev/null 2>&1
    fi
}

# 统一判断，空值或 y/yes 都视为启用
is_enabled() {
    [[ "$1" == "y" || "$1" == "yes" || -z "$1" ]] && return 0 || return 1
}

get_argo_recent_logs() {
    if $IS_OPENRC || $IS_DIRECT; then
        cat /var/log/argo-tunnel.log /var/log/argo-tunnel.err 2>/dev/null
    else
        journalctl -u argo-tunnel -n 200 --no-pager 2>/dev/null
    fi
}

extract_cloudflared_config_json() {
    local escaped_config
    escaped_config=$(get_argo_recent_logs | awk '
        match($0, /config="/) {
            line = substr($0, RSTART + 8)
            sub(/" version=.*/, "", line)
            print line
        }
    ' | tail -n 1)
    [[ -z "$escaped_config" ]] && return 1
    printf '%s' "${escaped_config//\\\"/\"}"
}

sync_argo_domains_from_cloudflared_config() {
    [[ -f /etc/s-box/argo.conf && -f /etc/s-box/sb.json ]] || return 0
    source /etc/s-box/argo.conf
    [[ "$ARGO_MODE" == "token" ]] || return 0
    is_enabled "$USE_NGINX" && return 0

    local vmess_port trojan_ws_port config_json
    local cf_vmess_domain="" cf_trojan_domain=""
    local synced_vmess_domain="$ARGO_VMESS_DOMAIN"
    local synced_trojan_domain="$ARGO_TROJAN_DOMAIN"
    local changed=false

    vmess_port=$(jq -r '.inbounds[]? | select(.tag=="vmess-in") | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null | head -n 1)
    trojan_ws_port=$(jq -r '.inbounds[]? | select(.tag=="trojan-ws-in") | .listen_port // empty' /etc/s-box/sb.json 2>/dev/null | head -n 1)

    config_json=""
    for i in {1..5}; do
        if config_json=$(extract_cloudflared_config_json); then
            break
        fi
        sleep 2
    done
    if [[ -z "$config_json" ]]; then
        echo "警告：未从 cloudflared 日志中找到远端 ingress 配置，跳过域名端口反向同步。"
        return 0
    fi
    if ! printf '%s' "$config_json" | command jq -e '.ingress' >/dev/null 2>&1; then
        echo "警告：cloudflared ingress 配置解析失败，跳过域名端口反向同步。"
        return 0
    fi

    if [[ -n "$vmess_port" && "$vmess_port" != "null" ]]; then
        cf_vmess_domain=$(printf '%s' "$config_json" | command jq -r --arg port "$vmess_port" '
            .ingress[]?
            | select((.hostname? // "") != "" and ((.service? // "") | test("://(127[.]0[.]0[.]1|localhost):" + $port + "($|/)")))
            | .hostname
        ' 2>/dev/null | head -n 1 | tr -d '\r')
    fi
    if [[ -n "$trojan_ws_port" && "$trojan_ws_port" != "null" ]]; then
        cf_trojan_domain=$(printf '%s' "$config_json" | command jq -r --arg port "$trojan_ws_port" '
            .ingress[]?
            | select((.hostname? // "") != "" and ((.service? // "") | test("://(127[.]0[.]0[.]1|localhost):" + $port + "($|/)")))
            | .hostname
        ' 2>/dev/null | head -n 1 | tr -d '\r')
    fi

    if [[ -n "$cf_vmess_domain" && "$cf_vmess_domain" != "$ARGO_VMESS_DOMAIN" ]]; then
        synced_vmess_domain="$cf_vmess_domain"
        changed=true
        echo "已按 cloudflared 配置同步 VMess 域名: ${synced_vmess_domain} -> 127.0.0.1:${vmess_port}"
    fi
    if [[ -n "$cf_trojan_domain" && "$cf_trojan_domain" != "$ARGO_TROJAN_DOMAIN" ]]; then
        synced_trojan_domain="$cf_trojan_domain"
        changed=true
        echo "已按 cloudflared 配置同步 Trojan 域名: ${synced_trojan_domain} -> 127.0.0.1:${trojan_ws_port}"
    fi

    if ! $changed; then
        [[ -n "$cf_vmess_domain" || -z "$vmess_port" ]] || echo "警告：未在 cloudflared 配置中找到 VMess 端口 ${vmess_port} 对应域名。"
        [[ -n "$cf_trojan_domain" || -z "$trojan_ws_port" ]] || echo "警告：未在 cloudflared 配置中找到 Trojan 端口 ${trojan_ws_port} 对应域名。"
        return 0
    fi

    ARGO_VMESS_DOMAIN="$synced_vmess_domain"
    ARGO_TROJAN_DOMAIN="$synced_trojan_domain"
    cat > /etc/s-box/argo.conf <<EOF_ARGO
ARGO_MODE="${ARGO_MODE}"
ARGO_TOKEN="${ARGO_TOKEN}"
ARGO_DOMAIN="${ARGO_DOMAIN}"
ARGO_VMESS_DOMAIN="${ARGO_VMESS_DOMAIN}"
ARGO_TROJAN_DOMAIN="${ARGO_TROJAN_DOMAIN}"
USE_NGINX="${USE_NGINX}"
ARGO_PORT="${ARGO_PORT}"
EOF_ARGO
    echo "${ARGO_VMESS_DOMAIN:-$ARGO_TROJAN_DOMAIN}" > /etc/s-box/argo.log
}

# 重新生成 Nginx 配置
regenerate_nginx_conf() {
    if ! is_enabled "$USE_NGINX"; then
        return
    fi
    if [[ ! -f ${NGINX_CONF_DIR}/singbox-argo.conf ]]; then
        return
    fi
    
    local port_nginx=$(grep -oE "listen 127.0.0.1:[0-9]+" ${NGINX_CONF_DIR}/singbox-argo.conf | head -n 1 | awk -F: '{print $2}')
    [[ -z "$port_nginx" ]] && port_nginx=8401
    
    local nginx_locations=""
    
    # 检查 VMess WS
    if jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local vmess_port=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .listen_port' /etc/s-box/sb.json)
        local vmess_path=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .transport.path' /etc/s-box/sb.json)
        nginx_locations="${nginx_locations}
    location ${vmess_path} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${vmess_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$http_host;
    }"
    fi
    
    # 检查 Trojan WS
    if jq -e '.inbounds[] | select(.tag=="trojan-ws-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local trojan_ws_port=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .listen_port' /etc/s-box/sb.json)
        local trojan_ws_path=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .transport.path' /etc/s-box/sb.json)
        nginx_locations="${nginx_locations}
    location ${trojan_ws_path} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${trojan_ws_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$http_host;
    }"
    fi
    
    local listen_ipv6=""
    if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -ne 1 ]]; then
        listen_ipv6="listen [::1]:${port_nginx};"
    fi

    cat > ${NGINX_CONF_DIR}/singbox-argo.conf <<EOF2
server {
    listen 127.0.0.1:${port_nginx};
    ${listen_ipv6}
    server_name localhost;
    ${nginx_locations}
}
EOF2
    service_restart nginx
}

# 重新生成 info.log 分享链接
regenerate_info_log() {
    local ipv4=$(curl -s4m5 icanhazip.com || curl -s4m5 api.ipify.org)
    local ipv6=$(curl -s6m5 icanhazip.com || curl -s6m5 api6.ipify.org)
    local ip=${ipv4:-$ipv6}
    
    local uuid=$(jq -r '.. | .uuid? // .password? | select(. != null)' /etc/s-box/sb.json | head -n 1)
    
    cat > /etc/s-box/info.log <<EOF2
==================================================
        Sing-box 多协议一键部署脚本 安装成功
==================================================
通用密码/UUID: ${uuid}
EOF2

    local has_direct=false
    if jq -e '.inbounds[] | select(.tag | test("^(vless|vmess|trojan-tls|hy2|tuic|anytls)-in$"))' /etc/s-box/sb.json >/dev/null 2>&1; then
        has_direct=true
    fi
    if $has_direct; then
        echo "" >> /etc/s-box/info.log
        echo "------------------【直连节点】--------------------" >> /etc/s-box/info.log
    fi

    local public_key=""
    if [[ -f /etc/s-box/public.key ]]; then
        public_key=$(cat /etc/s-box/public.key | tr -d '\r\n')
    fi
    local short_id=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.reality.short_id[0] // empty' /etc/s-box/sb.json)
    
    local argo_domain=""
    if [[ -f /etc/s-box/argo.log ]]; then
        argo_domain=$(cat /etc/s-box/argo.log | tr -d '\r\n')
    fi
    
    local argo_mode="temp"
    if [[ -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
        argo_mode=$ARGO_MODE
    fi



    # 1. VLESS-Reality
    if jq -e '.inbounds[] | select(.tag=="vless-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_vless=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .listen_port' /etc/s-box/sb.json)
        local uuid_vless=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .users[0].uuid' /etc/s-box/sb.json)
        local sni_vless=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.server_name' /etc/s-box/sb.json)
        local vless_link="vless://${uuid_vless}@${ip}:${port_vless}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni_vless}&fp=chrome&pbk=${public_key}&sid=${short_id}#SB-VLESS-Reality"
        echo "1. VLESS-Reality:" >> /etc/s-box/info.log
        echo "${vless_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # 2. VMess-WS
    if jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .listen_port' /etc/s-box/sb.json)
        local uuid_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .users[0].uuid' /etc/s-box/sb.json)
        local path_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .transport.path' /etc/s-box/sb.json)
        local vmess_json=$(cat <<EOF2
{
  "v": "2",
  "ps": "SB-VMess-WS",
  "add": "${ip}",
  "port": "${port_vmess}",
  "id": "${uuid_vmess}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "",
  "path": "${path_vmess}",
  "tls": "none",
  "sni": ""
}
EOF2
)
        local vmess_link
        vmess_link=$(make_vmess_link "$vmess_json")
        echo "2. VMess-WS (无TLS):" >> /etc/s-box/info.log
        echo "${vmess_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # 3. Trojan-WS-TLS
    if jq -e '.inbounds[] | select(.tag=="trojan-tls-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .listen_port' /etc/s-box/sb.json)
        local pass_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .users[0].password' /etc/s-box/sb.json)
        local sni_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .tls.server_name' /etc/s-box/sb.json)
        local path_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .transport.path' /etc/s-box/sb.json)
        local path_trojan_encoded=$(url_encode "$path_trojan")
        local trojan_link="trojan://${pass_trojan}@${ip}:${port_trojan}?security=tls&sni=${sni_trojan}&allowInsecure=1&type=ws&path=${path_trojan_encoded}#SB-Trojan-WS-TLS"
        echo "3. Trojan-WS-TLS (自签证书):" >> /etc/s-box/info.log
        echo "${trojan_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # 4. Hysteria2
    if jq -e '.inbounds[] | select(.tag=="hy2-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_hy2=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .listen_port' /etc/s-box/sb.json)
        local pass_hy2=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .users[0].password' /etc/s-box/sb.json)
        local hy2_link="hysteria2://${pass_hy2}@${ip}:${port_hy2}?insecure=1&sni=www.bing.com#SB-Hysteria2"
        echo "4. Hysteria2:" >> /etc/s-box/info.log
        echo "${hy2_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # 5. TUIC v5
    if jq -e '.inbounds[] | select(.tag=="tuic-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_tuic=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .listen_port' /etc/s-box/sb.json)
        local uuid_tuic=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].uuid' /etc/s-box/sb.json)
        local pass_tuic=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].password' /etc/s-box/sb.json)
        local tuic_link="tuic://${uuid_tuic}:${pass_tuic}@${ip}:${port_tuic}?alpn=h3&congestion_control=bbr&udp_relay=1&allow_insecure=1#SB-TUIC-v5"
        echo "5. TUIC v5:" >> /etc/s-box/info.log
        echo "${tuic_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # 6. AnyTLS
    if jq -e '.inbounds[] | select(.tag=="anytls-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
        local port_anytls=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .listen_port' /etc/s-box/sb.json)
        local pass_anytls=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .users[0].password' /etc/s-box/sb.json)
        local sni_anytls=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .tls.server_name' /etc/s-box/sb.json)
        local anytls_link="anytls://${pass_anytls}@${ip}:${port_anytls}?security=tls&sni=${sni_anytls}&allowInsecure=1#SB-AnyTLS"
        echo "6. AnyTLS:" >> /etc/s-box/info.log
        echo "${anytls_link}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi

    # 动态追加 WARP 链接
    local has_warp=false
    if jq -e '.inbounds[] | select(.tag | test("-warp-in$"))' /etc/s-box/sb.json >/dev/null 2>&1; then
        has_warp=true
    fi
    if $has_warp; then
        echo "------------------【WARP出站节点】--------------------" >> /etc/s-box/info.log
        
        if jq -e '.inbounds[] | select(.tag=="vless-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
            local port_vless_warp=$(jq -r '.inbounds[] | select(.tag=="vless-warp-in") | .listen_port' /etc/s-box/sb.json)
            local uuid_vless_warp=$(jq -r '.inbounds[] | select(.tag=="vless-warp-in") | .users[0].uuid' /etc/s-box/sb.json)
            local sni_vless_warp=$(jq -r '.inbounds[] | select(.tag=="vless-warp-in") | .tls.server_name' /etc/s-box/sb.json)
            local vless_warp_link="vless://${uuid_vless_warp}@${ip}:${port_vless_warp}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni_vless_warp}&fp=chrome&pbk=${public_key}&sid=${short_id}#SB-VLESS-Reality-WARP"
            echo "1. VLESS-Reality-WARP:" >> /etc/s-box/info.log
            echo "${vless_warp_link}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi
        
        if jq -e '.inbounds[] | select(.tag=="vmess-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
            local port_vmess_warp=$(jq -r '.inbounds[] | select(.tag=="vmess-warp-in") | .listen_port' /etc/s-box/sb.json)
            local uuid_vmess_warp=$(jq -r '.inbounds[] | select(.tag=="vmess-warp-in") | .users[0].uuid' /etc/s-box/sb.json)
            local path_vmess_warp=$(jq -r '.inbounds[] | select(.tag=="vmess-warp-in") | .transport.path' /etc/s-box/sb.json)
            local vmess_warp_json=$(cat <<EOF2
{
  "v": "2",
  "ps": "SB-VMess-WS-WARP",
  "add": "${ip}",
  "port": "${port_vmess_warp}",
  "id": "${uuid_vmess_warp}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "",
  "path": "${path_vmess_warp}",
  "tls": "none",
  "sni": ""
}
EOF2
)
            local vmess_warp_link
            vmess_warp_link=$(make_vmess_link "$vmess_warp_json")
            echo "2. VMess-WS-WARP (无TLS):" >> /etc/s-box/info.log
            echo "${vmess_warp_link}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi
        
        if jq -e '.inbounds[] | select(.tag=="trojan-tls-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
            local port_trojan_warp=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-warp-in") | .listen_port' /etc/s-box/sb.json)
            local pass_trojan_warp=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-warp-in") | .users[0].password' /etc/s-box/sb.json)
            local sni_trojan_warp=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-warp-in") | .tls.server_name' /etc/s-box/sb.json)
            local path_trojan_warp=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-warp-in") | .transport.path' /etc/s-box/sb.json)
            local path_trojan_warp_encoded=$(url_encode "$path_trojan_warp")
            local trojan_warp_link="trojan://${pass_trojan_warp}@${ip}:${port_trojan_warp}?security=tls&sni=${sni_trojan_warp}&allowInsecure=1&type=ws&path=${path_trojan_warp_encoded}#SB-Trojan-WS-TLS-WARP"
            echo "3. Trojan-WS-TLS-WARP (自签证书):" >> /etc/s-box/info.log
            echo "${trojan_warp_link}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi
        
        if jq -e '.inbounds[] | select(.tag=="hy2-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
            local port_hy2_warp=$(jq -r '.inbounds[] | select(.tag=="hy2-warp-in") | .listen_port' /etc/s-box/sb.json)
            local pass_hy2_warp=$(jq -r '.inbounds[] | select(.tag=="hy2-warp-in") | .users[0].password' /etc/s-box/sb.json)
            local hy2_warp_link="hysteria2://${pass_hy2_warp}@${ip}:${port_hy2_warp}?insecure=1&sni=www.bing.com#SB-Hysteria2-WARP"
            echo "4. Hysteria2-WARP:" >> /etc/s-box/info.log
            echo "${hy2_warp_link}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi
        
        if jq -e '.inbounds[] | select(.tag=="tuic-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
            local port_tuic_warp=$(jq -r '.inbounds[] | select(.tag=="tuic-warp-in") | .listen_port' /etc/s-box/sb.json)
            local uuid_tuic_warp=$(jq -r '.inbounds[] | select(.tag=="tuic-warp-in") | .users[0].uuid' /etc/s-box/sb.json)
            local pass_tuic_warp=$(jq -r '.inbounds[] | select(.tag=="tuic-warp-in") | .users[0].password' /etc/s-box/sb.json)
            local tuic_warp_link="tuic://${uuid_tuic_warp}:${pass_tuic_warp}@${ip}:${port_tuic_warp}?alpn=h3&congestion_control=bbr&udp_relay=1&allow_insecure=1#SB-TUIC-v5-WARP"
            echo "5. TUIC v5-WARP:" >> /etc/s-box/info.log
            echo "${tuic_warp_link}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi
        
        if jq -e '.inbounds[] | select(.tag=="anytls-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
            local port_anytls_warp=$(jq -r '.inbounds[] | select(.tag=="anytls-warp-in") | .listen_port' /etc/s-box/sb.json)
            local pass_anytls_warp=$(jq -r '.inbounds[] | select(.tag=="anytls-warp-in") | .users[0].password' /etc/s-box/sb.json)
            local sni_anytls_warp=$(jq -r '.inbounds[] | select(.tag=="anytls-warp-in") | .tls.server_name' /etc/s-box/sb.json)
            local anytls_warp_link="anytls://${pass_anytls_warp}@${ip}:${port_anytls_warp}?security=tls&sni=${sni_anytls_warp}&allowInsecure=1#SB-AnyTLS-WARP"
            echo "6. AnyTLS-WARP:" >> /etc/s-box/info.log
            echo "${anytls_warp_link}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi
    fi

    # Argo
    if [[ -n "$argo_domain" ]] || [[ -n "$ARGO_VMESS_DOMAIN" ]] || [[ -n "$ARGO_TROJAN_DOMAIN" ]]; then
        echo "------------------【Argo穿透】--------------------" >> /etc/s-box/info.log
        if [[ "$argo_mode" == "token" ]]; then
            if is_enabled "$USE_NGINX"; then
                echo "Argo 固定域名: ${argo_domain}" >> /etc/s-box/info.log
            else
                [[ -n "$ARGO_VMESS_DOMAIN" ]] && echo "VMess Argo 域名: ${ARGO_VMESS_DOMAIN}" >> /etc/s-box/info.log
                [[ -n "$ARGO_TROJAN_DOMAIN" ]] && echo "Trojan Argo 域名: ${ARGO_TROJAN_DOMAIN}" >> /etc/s-box/info.log
            fi
        else
            echo "Argo 临时域名: ${argo_domain}" >> /etc/s-box/info.log
        fi
        echo "" >> /etc/s-box/info.log

        if is_enabled "$USE_NGINX"; then
            if jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
                local uuid_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .users[0].uuid' /etc/s-box/sb.json)
                local path_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .transport.path' /etc/s-box/sb.json)
                local vmess_argo_json=$(cat <<EOF2
{
  "v": "2",
  "ps": "SB-VMess-Argo-80",
  "add": "${argo_domain}",
  "port": "80",
  "id": "${uuid_vmess}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${argo_domain}",
  "path": "${path_vmess}",
  "tls": "none",
  "sni": ""
}
EOF2
)
                local vmess_argo_80_link
                vmess_argo_80_link=$(make_vmess_link "$vmess_argo_json")

                local vmess_argo_tls_json=$(cat <<EOF2
{
  "v": "2",
  "ps": "SB-VMess-Argo-443",
  "add": "${argo_domain}",
  "port": "443",
  "id": "${uuid_vmess}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${argo_domain}",
  "path": "${path_vmess}",
  "tls": "tls",
  "sni": "${argo_domain}"
}
EOF2
)
                local vmess_argo_443_link
                vmess_argo_443_link=$(make_vmess_link "$vmess_argo_tls_json")

                echo "1. VMess Argo (80端口):" >> /etc/s-box/info.log
                echo "${vmess_argo_80_link}" >> /etc/s-box/info.log
                echo "" >> /etc/s-box/info.log
                echo "2. VMess Argo (443端口/TLS):" >> /etc/s-box/info.log
                echo "${vmess_argo_443_link}" >> /etc/s-box/info.log
                echo "" >> /etc/s-box/info.log
            fi

            if jq -e '.inbounds[] | select(.tag=="trojan-ws-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
                local pass_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .users[0].password' /etc/s-box/sb.json)
                local path_trojan_ws=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .transport.path' /etc/s-box/sb.json)
                local path_trojan_ws_encoded=$(url_encode "$path_trojan_ws")
                
                local trojan_argo_80_link="trojan://${pass_trojan}@${argo_domain}:80?security=none&type=ws&path=${path_trojan_ws_encoded}&host=${argo_domain}#SB-Trojan-Argo-80"
                local trojan_argo_443_link="trojan://${pass_trojan}@${argo_domain}:443?security=tls&sni=${argo_domain}&type=ws&path=${path_trojan_ws_encoded}&host=${argo_domain}#SB-Trojan-Argo-443"

                echo "3. Trojan Argo (80端口):" >> /etc/s-box/info.log
                echo "${trojan_argo_80_link}" >> /etc/s-box/info.log
                echo "" >> /etc/s-box/info.log
                echo "4. Trojan Argo (443端口/TLS):" >> /etc/s-box/info.log
                echo "${trojan_argo_443_link}" >> /etc/s-box/info.log
                echo "" >> /etc/s-box/info.log
            fi
        else
            # 免 Nginx 模式，双子域名分别独立生成
            local argo_idx=1
            if jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1 && [[ -n "$ARGO_VMESS_DOMAIN" ]]; then
                local uuid_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .users[0].uuid' /etc/s-box/sb.json)
                local path_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .transport.path' /etc/s-box/sb.json)
                local vmess_argo_json=$(cat <<EOF2
{
  "v": "2",
  "ps": "SB-VMess-Argo-80",
  "add": "${ARGO_VMESS_DOMAIN}",
  "port": "80",
  "id": "${uuid_vmess}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${ARGO_VMESS_DOMAIN}",
  "path": "${path_vmess}",
  "tls": "none",
  "sni": ""
}
EOF2
)
                local vmess_argo_80_link
                vmess_argo_80_link=$(make_vmess_link "$vmess_argo_json")

                local vmess_argo_tls_json=$(cat <<EOF2
{
  "v": "2",
  "ps": "SB-VMess-Argo-443",
  "add": "${ARGO_VMESS_DOMAIN}",
  "port": "443",
  "id": "${uuid_vmess}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${ARGO_VMESS_DOMAIN}",
  "path": "${path_vmess}",
  "tls": "tls",
  "sni": "${ARGO_VMESS_DOMAIN}"
}
EOF2
)
                local vmess_argo_443_link
                vmess_argo_443_link=$(make_vmess_link "$vmess_argo_tls_json")

                echo "${argo_idx}. VMess Argo (80端口):" >> /etc/s-box/info.log
                echo "${vmess_argo_80_link}" >> /etc/s-box/info.log
                echo "" >> /etc/s-box/info.log
                ((argo_idx++))
                echo "${argo_idx}. VMess Argo (443端口/TLS):" >> /etc/s-box/info.log
                echo "${vmess_argo_443_link}" >> /etc/s-box/info.log
                echo "" >> /etc/s-box/info.log
                ((argo_idx++))
            fi

            if jq -e '.inbounds[] | select(.tag=="trojan-ws-in")' /etc/s-box/sb.json >/dev/null 2>&1 && [[ -n "$ARGO_TROJAN_DOMAIN" ]]; then
                local pass_trojan=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .users[0].password' /etc/s-box/sb.json)
                local path_trojan_ws=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .transport.path' /etc/s-box/sb.json)
                local path_trojan_ws_encoded=$(url_encode "$path_trojan_ws")
                
                local trojan_argo_80_link="trojan://${pass_trojan}@${ARGO_TROJAN_DOMAIN}:80?security=none&type=ws&path=${path_trojan_ws_encoded}&host=${ARGO_TROJAN_DOMAIN}#SB-Trojan-Argo-80"
                local trojan_argo_443_link="trojan://${pass_trojan}@${ARGO_TROJAN_DOMAIN}:443?security=tls&sni=${ARGO_TROJAN_DOMAIN}&type=ws&path=${path_trojan_ws_encoded}&host=${ARGO_TROJAN_DOMAIN}#SB-Trojan-Argo-443"

                echo "${argo_idx}. Trojan Argo (80端口):" >> /etc/s-box/info.log
                echo "${trojan_argo_80_link}" >> /etc/s-box/info.log
                echo "" >> /etc/s-box/info.log
                ((argo_idx++))
                echo "${argo_idx}. Trojan Argo (443端口/TLS):" >> /etc/s-box/info.log
                echo "${trojan_argo_443_link}" >> /etc/s-box/info.log
                echo "" >> /etc/s-box/info.log
                ((argo_idx++))
            fi
        fi
    fi

    echo "==================================================" >> /etc/s-box/info.log
}

# 重新获取 Argo 临时域名并写入 argo.log
update_argo_domain() {
    if [[ ! -f ${NGINX_CONF_DIR}/singbox-argo.conf ]]; then
        return
    fi
    # 如果是 token 模式，不需要自动获取临时域名，直接返回
    if [[ -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
        if [[ "$ARGO_MODE" == "token" ]]; then
            return
        fi
    else
        # 兼容性检测，通过检测服务文件
        if $IS_OPENRC; then
            if grep -q "\--token" /etc/init.d/argo-tunnel 2>/dev/null; then
                return
            fi
        else
            if grep -q "\--token" /etc/systemd/system/argo-tunnel.service 2>/dev/null; then
                return
            fi
        fi
    fi
    # 清空旧日志，避免提取到旧域名
    : > /var/log/argo-tunnel.log 2>/dev/null
    : > /var/log/argo-tunnel.err 2>/dev/null
    service_restart argo-tunnel
    echo "正在等待 Argo 隧道上线并获取临时域名..."
    sleep 8
    local argo_domain=""
    for i in {1..10}; do
        if $IS_OPENRC || $IS_DIRECT; then
            argo_domain=$(cat /var/log/argo-tunnel.log /var/log/argo-tunnel.err 2>/dev/null | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -n 1)
        else
            argo_domain=$(journalctl -u argo-tunnel -n 50 --no-pager | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -n 1)
        fi
        [[ -n "$argo_domain" ]] && break
        sleep 3
    done
    if [[ -n "$argo_domain" ]]; then
        echo "$argo_domain" > /etc/s-box/argo.log
        echo "成功获取 Argo 新域名: $argo_domain"
    else
        echo "警告：未获取到 Argo 域名，可能隧道启动较慢，请稍后查看。"
    fi
}

apply_changes() {
    if ! /etc/s-box/sing-box check -c /etc/s-box/sb.json >/tmp/s-box-check.log 2>&1; then
        echo "错误：sing-box 配置校验失败，未重启服务。"
        cat /tmp/s-box-check.log
        return 1
    fi

    echo "正在应用更改，重启 Sing-box 服务..."
    service_restart sing-box
    sleep 1
    if ! service_is_active sing-box; then
        echo "错误：sing-box 服务启动失败。"
        if $IS_OPENRC || $IS_DIRECT; then
            tail -n 50 /var/log/sing-box.log 2>/dev/null
        else
            journalctl -u sing-box -n 50 --no-pager
        fi
        return 1
    fi
    
    if [[ -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
    fi
    
    if is_enabled "$USE_NGINX" && [[ -f ${NGINX_CONF_DIR}/singbox-argo.conf ]]; then
        echo "正在重启 Nginx 和 Argo 服务..."
        regenerate_nginx_conf
        service_restart argo-tunnel
        update_argo_domain
    elif [[ -f /etc/s-box/argo.conf ]]; then
        echo "正在重启 Argo 服务..."
        service_restart argo-tunnel
        sleep 2
        sync_argo_domains_from_cloudflared_config
        update_argo_domain
    fi
    
    regenerate_info_log
    echo "更改已成功应用并重启服务！"
}

repair_runtime_config() {
    if [[ ! -f /etc/s-box/sb.json ]]; then
        echo "未找到 /etc/s-box/sb.json，无法修复。"
        return 1
    fi

    echo "正在修复本地监听地址并同步 Argo/Nginx 配置..."
    local temp_json=$(mktemp)
    if ! jq '
        .inbounds |= map(
            if (.tag == "trojan-ws-in") then
                .listen = "127.0.0.1"
            elif (.tag == "vless-in" or .tag == "vmess-in" or .tag == "trojan-tls-in" or .tag == "hy2-in" or .tag == "tuic-in" or .tag == "anytls-in") then
                .listen = "0.0.0.0"
            else
                .
            end
        )
    ' /etc/s-box/sb.json > "$temp_json"; then
        rm -f "$temp_json"
        echo "修复失败：无法写入 JSON。"
        return 1
    fi
    mv "$temp_json" /etc/s-box/sb.json

    if ! /etc/s-box/sing-box check -c /etc/s-box/sb.json >/tmp/s-box-check.log 2>&1; then
        echo "错误：修复后的 sing-box 配置校验失败。"
        cat /tmp/s-box-check.log
        return 1
    fi

    if [[ -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
    fi
    if is_enabled "$USE_NGINX" && [[ -f ${NGINX_CONF_DIR}/singbox-argo.conf ]]; then
        regenerate_nginx_conf
        service_restart nginx
    fi

    service_restart sing-box
    sleep 1
    if ! service_is_active sing-box; then
        echo "错误：sing-box 服务启动失败。"
        if $IS_OPENRC || $IS_DIRECT; then
            tail -n 50 /var/log/sing-box.log 2>/dev/null
        else
            journalctl -u sing-box -n 50 --no-pager
        fi
        return 1
    fi
    if [[ -f /etc/s-box/argo.conf ]]; then
        service_restart argo-tunnel
        sleep 2
        sync_argo_domains_from_cloudflared_config
    fi
    regenerate_info_log

    echo "修复完成。当前监听："
    ss -tlnp 2>/dev/null | grep -E ':(8401|8402|38202|48203|58204)\b' || true
    echo ""
    echo "如果使用免 Nginx 固定隧道，请确认 Cloudflare Public Hostname："
    local vmess_port=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    local trojan_ws_port=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    [[ -n "$ARGO_VMESS_DOMAIN" && -n "$vmess_port" ]] && echo "  ${ARGO_VMESS_DOMAIN} -> http://127.0.0.1:${vmess_port}"
    [[ -n "$ARGO_TROJAN_DOMAIN" && -n "$trojan_ws_port" ]] && echo "  ${ARGO_TROJAN_DOMAIN} -> http://127.0.0.1:${trojan_ws_port}"
    [[ -n "$ARGO_TROJAN_DOMAIN" ]] && echo "Trojan Argo 链接必须使用 ${ARGO_TROJAN_DOMAIN}，不能使用 VMess 域名。"
}

check_port() {
    local port=$1
    if ss -tunlp | grep -q ":$port "; then
        return 1
    else
        return 0
    fi
}

modify_vless() {
    local suffix="$1"
    local tag="vless-in"
    local name="VLESS-Reality"
    if [[ "$suffix" == "-warp" ]]; then
        tag="vless-warp-in"
        name="VLESS-Reality-WARP"
    fi
    while true; do
        local cur_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .listen_port' /etc/s-box/sb.json)
        local cur_uuid=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .users[0].uuid' /etc/s-box/sb.json)
        local cur_sni=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .tls.server_name' /etc/s-box/sb.json)
        local cur_dest=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .tls.reality.handshake.server' /etc/s-box/sb.json)
        local cur_dest_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .tls.reality.handshake.server_port' /etc/s-box/sb.json)
        
        echo "--------------------------------------------------"
        echo "          ${name} 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 UUID (当前: $cur_uuid)"
        echo "3. 修改 SNI 域名 (当前: $cur_sni)"
        echo "4. 修改目标 IP/强绑定域名 (当前: $cur_dest:$cur_dest_port)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-4]: " vless_choice
        
        if [[ "$vless_choice" == "0" || -z "$vless_choice" ]]; then
            break
        fi
        
        case $vless_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --arg tag "$tag" --argjson port "$new_port" '(.inbounds[] | select(.tag==$tag) | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新 UUID (留空随机生成): " new_uuid
                if [[ -z "$new_uuid" ]]; then
                    new_uuid=$(/etc/s-box/sing-box generate uuid)
                fi
                local temp_json=$(mktemp)
                jq --arg tag "$tag" --arg uuid "$new_uuid" '(.inbounds[] | select(.tag==$tag) | .users[0].uuid) = $uuid' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                echo "UUID 修改成功，新 UUID: $new_uuid"
                apply_changes
                ;;
            3)
                read -p "请输入新 SNI 域名: " new_sni
                if [[ -n "$new_sni" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg tag "$tag" --arg sni "$new_sni" '(.inbounds[] | select(.tag==$tag) | .tls.server_name) = $sni' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "SNI 修改成功，新 SNI: $new_sni"
                    apply_changes
                else
                    echo "域名不能为空！"
                fi
                ;;
            4)
                read -p "请输入新目标域名/IP: " new_dest
                read -p "请输入新目标端口 [默认 443]: " new_dest_port
                [[ -z "$new_dest_port" ]] && new_dest_port=443
                if [[ -n "$new_dest" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg tag "$tag" --arg dest "$new_dest" --argjson dest_port "$new_dest_port" '
                        (.inbounds[] | select(.tag==$tag) | .tls.reality.handshake.server) = $dest |
                        (.inbounds[] | select(.tag==$tag) | .tls.reality.handshake.server_port) = $dest_port
                    ' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "目标修改成功，新目标: $new_dest:$new_dest_port"
                    apply_changes
                else
                    echo "目标不能为空！"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_vmess() {
    local suffix="$1"
    local tag="vmess-in"
    local name="VMess-WS"
    if [[ "$suffix" == "-warp" ]]; then
        tag="vmess-warp-in"
        name="VMess-WS-WARP"
    fi
    while true; do
        local cur_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .listen_port' /etc/s-box/sb.json)
        local cur_uuid=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .users[0].uuid' /etc/s-box/sb.json)
        local cur_path=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .transport.path' /etc/s-box/sb.json)
        
        echo "--------------------------------------------------"
        echo "          ${name} 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 UUID (当前: $cur_uuid)"
        echo "3. 修改 WS 路径 (当前: $cur_path)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-3]: " vmess_choice
        
        if [[ "$vmess_choice" == "0" || -z "$vmess_choice" ]]; then
            break
        fi
        
        case $vmess_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --arg tag "$tag" --argjson port "$new_port" '(.inbounds[] | select(.tag==$tag) | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新 UUID (留空随机生成): " new_uuid
                if [[ -z "$new_uuid" ]]; then
                    new_uuid=$(/etc/s-box/sing-box generate uuid)
                fi
                local temp_json=$(mktemp)
                jq --arg tag "$tag" --arg uuid "$new_uuid" '(.inbounds[] | select(.tag==$tag) | .users[0].uuid) = $uuid' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                echo "UUID 修改成功，新 UUID: $new_uuid"
                apply_changes
                ;;
            3)
                read -p "请输入新 WS 路径 (必须以 / 开头，例如 /my-path): " new_path
                if [[ -n "$new_path" ]]; then
                    if [[ ! "$new_path" =~ ^/ ]]; then
                        new_path="/${new_path}"
                    fi
                    local temp_json=$(mktemp)
                    jq --arg tag "$tag" --arg path "$new_path" '(.inbounds[] | select(.tag==$tag) | .transport.path) = $path' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "WS 路径修改成功，新路径: $new_path"
                    apply_changes
                else
                    echo "路径不能为空！"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_trojan() {
    local suffix="$1"
    local tag="trojan-tls-in"
    local name="Trojan-WS-TLS"
    if [[ "$suffix" == "-warp" ]]; then
        tag="trojan-tls-warp-in"
        name="Trojan-WS-TLS-WARP"
    fi
    while true; do
        local cur_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .listen_port' /etc/s-box/sb.json)
        local cur_pass=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .users[0].password' /etc/s-box/sb.json)
        local cur_sni=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .tls.server_name' /etc/s-box/sb.json)
        local cur_path=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .transport.path' /etc/s-box/sb.json)
        
        local has_trojan_ws=false
        local cur_ws_port=""
        local cur_ws_path=""
        if jq -e '.inbounds[] | select(.tag=="trojan-ws-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
            has_trojan_ws=true
            cur_ws_port=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .listen_port' /etc/s-box/sb.json)
            cur_ws_path=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .transport.path' /etc/s-box/sb.json)
        fi
        
        echo "--------------------------------------------------"
        echo "          ${name} 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 密码 (当前: $cur_pass)"
        echo "3. 修改 伪装域名 (当前: $cur_sni)"
        echo "4. 修改 WS 路径 (当前: $cur_path)"
        if $has_trojan_ws && [[ "$suffix" != "-warp" ]]; then
            echo "5. 修改 Argo 内部 Trojan-WS 端口 (当前: $cur_ws_port)"
            echo "6. 修改 Argo 内部 Trojan-WS 路径 (当前: $cur_ws_path)"
        fi
        echo "0. 返回"
        echo "--------------------------------------------------"
        local max_opt=4
        if $has_trojan_ws && [[ "$suffix" != "-warp" ]]; then
            max_opt=6
        fi
        read -p "请选择修改项 [0-$max_opt]: " trojan_choice
        
        if [[ "$trojan_choice" == "0" || -z "$trojan_choice" ]]; then
            break
        fi
        
        case $trojan_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --arg tag "$tag" --argjson port "$new_port" '(.inbounds[] | select(.tag==$tag) | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新密码: " new_pass
                if [[ -n "$new_pass" ]]; then
                    local temp_json=$(mktemp)
                    if $has_trojan_ws && [[ "$suffix" != "-warp" ]]; then
                        jq --arg tag "$tag" --arg password "$new_pass" '
                            ((.inbounds[] | select(.tag==$tag) | .users[0].password) = $password) |
                            ((.inbounds[] | select(.tag=="trojan-ws-in") | .users[0].password) = $password)
                        ' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    else
                        jq --arg tag "$tag" --arg password "$new_pass" '(.inbounds[] | select(.tag==$tag) | .users[0].password) = $password' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    fi
                    echo "密码修改成功，新密码: $new_pass"
                    apply_changes
                else
                    echo "密码不能为空！"
                fi
                ;;
            3)
                read -p "请输入新伪装域名: " new_sni
                if [[ -n "$new_sni" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg tag "$tag" --arg sni "$new_sni" '(.inbounds[] | select(.tag==$tag) | .tls.server_name) = $sni' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "伪装域名修改成功，新伪装域名: $new_sni"
                    apply_changes
                else
                    echo "域名不能为空！"
                fi
                ;;
            4)
                read -p "请输入新 WS 路径 (必须以 / 开头，例如 /my-path): " new_path
                if [[ -n "$new_path" ]]; then
                    if [[ ! "$new_path" =~ ^/ ]]; then
                        new_path="/${new_path}"
                    fi
                    local temp_json=$(mktemp)
                    jq --arg tag "$tag" --arg path "$new_path" '(.inbounds[] | select(.tag==$tag) | .transport.path) = $path' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "WS 路径修改成功，新路径: $new_path"
                    apply_changes
                else
                    echo "路径不能为空！"
                fi
                ;;
            5)
                if $has_trojan_ws && [[ "$suffix" != "-warp" ]]; then
                    read -p "请输入新 Argo 内部 Trojan-WS 端口: " new_port
                    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                        if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_ws_port" ]; then
                            echo "警告：端口 $new_port 已被占用！"
                        else
                            local temp_json=$(mktemp)
                            jq --argjson port "$new_port" '(.inbounds[] | select(.tag=="trojan-ws-in") | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                            echo "Argo 内部 Trojan-WS 端口修改成功，新端口: $new_port"
                            apply_changes
                        fi
                    else
                        echo "无效端口！"
                    fi
                else
                    echo "无效选项！"
                fi
                ;;
            6)
                if $has_trojan_ws && [[ "$suffix" != "-warp" ]]; then
                    read -p "请输入新 Argo 内部 Trojan-WS 路径 (必须以 / 开头): " new_path
                    if [[ -n "$new_path" ]]; then
                        if [[ ! "$new_path" =~ ^/ ]]; then
                            new_path="/${new_path}"
                        fi
                        local temp_json=$(mktemp)
                        jq --arg path "$new_path" '(.inbounds[] | select(.tag=="trojan-ws-in") | .transport.path) = $path' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "Argo 内部 Trojan-WS 路径修改成功，新路径: $new_path"
                        apply_changes
                    fi
                else
                    echo "无效选项！"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_hy2() {
    local suffix="$1"
    local tag="hy2-in"
    local name="Hysteria2"
    if [[ "$suffix" == "-warp" ]]; then
        tag="hy2-warp-in"
        name="Hysteria2-WARP"
    fi
    while true; do
        local cur_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .listen_port' /etc/s-box/sb.json)
        local cur_pass=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .users[0].password' /etc/s-box/sb.json)
        
        echo "--------------------------------------------------"
        echo "          ${name} 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 密码 (当前: $cur_pass)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-2]: " hy2_choice
        
        if [[ "$hy2_choice" == "0" || -z "$hy2_choice" ]]; then
            break
        fi
        
        case $hy2_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --arg tag "$tag" --argjson port "$new_port" '(.inbounds[] | select(.tag==$tag) | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新密码: " new_pass
                if [[ -n "$new_pass" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg tag "$tag" --arg password "$new_pass" '(.inbounds[] | select(.tag==$tag) | .users[0].password) = $password' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "密码修改成功，新密码: $new_pass"
                    apply_changes
                else
                    echo "密码不能为空！"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_tuic() {
    local suffix="$1"
    local tag="tuic-in"
    local name="TUIC v5"
    if [[ "$suffix" == "-warp" ]]; then
        tag="tuic-warp-in"
        name="TUIC-WARP"
    fi
    while true; do
        local cur_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .listen_port' /etc/s-box/sb.json)
        local cur_uuid=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .users[0].uuid' /etc/s-box/sb.json)
        
        echo "--------------------------------------------------"
        echo "          ${name} 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 UUID/密码 (当前: $cur_uuid)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-2]: " tuic_choice
        
        if [[ "$tuic_choice" == "0" || -z "$tuic_choice" ]]; then
            break
        fi
        
        case $tuic_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --arg tag "$tag" --argjson port "$new_port" '(.inbounds[] | select(.tag==$tag) | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新 UUID/密码 (留空随机生成): " new_uuid
                if [[ -z "$new_uuid" ]]; then
                    new_uuid=$(/etc/s-box/sing-box generate uuid)
                fi
                local temp_json=$(mktemp)
                jq --arg tag "$tag" --arg uuid "$new_uuid" '
                    (.inbounds[] | select(.tag==$tag) | .users[0].uuid) = $uuid |
                    (.inbounds[] | select(.tag==$tag) | .users[0].password) = $uuid
                ' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                echo "UUID/密码 修改成功，新 UUID/密码: $new_uuid"
                apply_changes
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_anytls() {
    local suffix="$1"
    local tag="anytls-in"
    local name="AnyTLS"
    if [[ "$suffix" == "-warp" ]]; then
        tag="anytls-warp-in"
        name="AnyTLS-WARP"
    fi
    while true; do
        local cur_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .listen_port' /etc/s-box/sb.json)
        local cur_pass=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .users[0].password' /etc/s-box/sb.json)
        local cur_sni=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .tls.server_name' /etc/s-box/sb.json)
        
        echo "--------------------------------------------------"
        echo "          ${name} 参数修改"
        echo "--------------------------------------------------"
        echo "1. 修改监听端口 (当前: $cur_port)"
        echo "2. 修改 密码 (当前: $cur_pass)"
        echo "3. 修改 伪装域名 (当前: $cur_sni)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-3]: " anytls_choice
        
        if [[ "$anytls_choice" == "0" || -z "$anytls_choice" ]]; then
            break
        fi
        
        case $anytls_choice in
            1)
                read -p "请输入新端口: " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ss -tunlp | grep -q ":$new_port " && [ "$new_port" -ne "$cur_port" ]; then
                        echo "警告：端口 $new_port 已被占用！"
                    else
                        local temp_json=$(mktemp)
                        jq --argjson port "$new_port" '(.inbounds[] | select(.tag=="anytls-in") | .listen_port) = $port' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                        echo "端口修改成功，新端口: $new_port"
                        apply_changes
                    fi
                else
                    echo "无效端口！"
                fi
                ;;
            2)
                read -p "请输入新密码: " new_pass
                if [[ -n "$new_pass" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg password "$new_pass" '(.inbounds[] | select(.tag=="anytls-in") | .users[0].password) = $password' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "密码修改成功，新密码: $new_pass"
                    apply_changes
                else
                    echo "密码不能为空！"
                fi
                ;;
            3)
                read -p "请输入新伪装域名: " new_sni
                if [[ -n "$new_sni" ]]; then
                    local temp_json=$(mktemp)
                    jq --arg sni "$new_sni" '(.inbounds[] | select(.tag=="anytls-in") | .tls.server_name) = $sni' /etc/s-box/sb.json > "$temp_json" && mv "$temp_json" /etc/s-box/sb.json
                    echo "伪装域名修改成功，新伪装域名: $new_sni"
                    apply_changes
                else
                    echo "域名不能为空！"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_argo() {
    if [[ ! -f /usr/local/bin/cloudflared ]]; then
        echo "错误：未安装 Cloudflared，无法配置 Argo 隧道！"
        read -p "按回车键继续..." temp
        return
    fi

    while true; do
        local argo_mode="temp"
        local argo_token=""
        local argo_domain=""
        local ARGO_VMESS_DOMAIN=""
        local ARGO_TROJAN_DOMAIN=""
        if [[ -f /etc/s-box/argo.conf ]]; then
            source /etc/s-box/argo.conf
            argo_mode=$ARGO_MODE
            argo_token=$ARGO_TOKEN
            argo_domain=$ARGO_DOMAIN
        else
            if $IS_OPENRC; then
                if grep -q "\--token" /etc/init.d/argo-tunnel 2>/dev/null; then
                    argo_mode="token"
                    argo_token=$(grep -oE "\--token[[:space:]]+[^[:space:]]+" /etc/init.d/argo-tunnel 2>/dev/null | awk '{print $2}')
                fi
            else
                if grep -q "\--token" /etc/systemd/system/argo-tunnel.service 2>/dev/null; then
                    argo_mode="token"
                    argo_token=$(grep -oE "\--token[[:space:]]+[^[:space:]]+" /etc/systemd/system/argo-tunnel.service 2>/dev/null | awk '{print $2}')
                fi
            fi
            if [[ -f /etc/s-box/argo.log ]]; then
                argo_domain=$(cat /etc/s-box/argo.log)
            fi
        fi

        echo "--------------------------------------------------"
        echo "          Argo 隧道参数修改"
        echo "--------------------------------------------------"
        if [[ "$argo_mode" == "token" ]]; then
            echo "当前模式: 固定域名隧道 (Token 模式)"
            if is_enabled "$USE_NGINX"; then
                echo "自备域名: $argo_domain"
            else
                [[ -n "$ARGO_VMESS_DOMAIN" ]] && echo "VMess 子域名: $ARGO_VMESS_DOMAIN"
                [[ -n "$ARGO_TROJAN_DOMAIN" ]] && echo "Trojan 子域名: $ARGO_TROJAN_DOMAIN"
            fi
            echo "Token值 : ${argo_token:0:15}... (已隐藏后续字符)"
        else
            echo "当前模式: 临时域名隧道 (TryCloudflare 模式)"
            echo "临时域名: $argo_domain"
        fi
        echo "--------------------------------------------------"
        echo "1. 切换为 临时域名隧道 (trycloudflare.com)"
        echo "2. 切换为 固定域名隧道 (使用 Cloudflare Tunnel Token)"
        echo "0. 返回"
        echo "--------------------------------------------------"
        read -p "请选择修改项 [0-2]: " argo_choice
        
        if [[ "$argo_choice" == "0" || -z "$argo_choice" ]]; then
            break
        fi
        
        case $argo_choice in
            1)
                if [[ "$argo_mode" == "temp" ]]; then
                    echo "当前已是临时隧道模式，无需切换。"
                    continue
                fi
                echo "正在切换为临时域名隧道模式..."
                
                local argo_target_port="${ARGO_PORT}"
                local argo_depend="net sing-box"
                if is_enabled "$USE_NGINX"; then
                    local port_nginx=$(grep -oE "listen 127.0.0.1:[0-9]+" ${NGINX_CONF_DIR}/singbox-argo.conf 2>/dev/null | head -n 1 | awk -F: '{print $2}')
                    [[ -z "$port_nginx" ]] && port_nginx=8401
                    argo_target_port="${port_nginx}"
                    argo_depend="net sing-box nginx"
                fi
                
                if $IS_OPENRC; then
                    cat > /etc/init.d/argo-tunnel <<EOF_INIT
#!/sbin/openrc-run
name="argo-tunnel"
description="Argo Tunnel Service"
command="/usr/local/bin/cloudflared"
command_args="tunnel --url http://127.0.0.1:${argo_target_port}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/argo-tunnel.log"
error_log="/var/log/argo-tunnel.log"
depend() {
    need ${argo_depend}
}
EOF_INIT
                    chmod +x /etc/init.d/argo-tunnel
                else
                    cat > /etc/systemd/system/argo-tunnel.service <<EOF_SYSTEMD
[Unit]
Description=Argo Tunnel Service
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:${argo_target_port}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
                    systemctl daemon-reload
                fi
                
                cat > /etc/s-box/argo.conf <<EOF_ARGO
ARGO_MODE="temp"
ARGO_TOKEN=""
ARGO_DOMAIN=""
ARGO_VMESS_DOMAIN=""
ARGO_TROJAN_DOMAIN=""
USE_NGINX="${USE_NGINX}"
ARGO_PORT="${ARGO_PORT}"
EOF_ARGO
                
                service_restart argo-tunnel
                update_argo_domain
                regenerate_info_log
                echo "成功切换为临时域名隧道模式！"
                ;;
            2)
                read -p "请输入您的 Cloudflare Tunnel Token: " new_token
                if [[ -z "$new_token" ]]; then
                    echo "错误：Token 不能为空！"
                    continue
                fi

                # 询问转发方式
                echo "=================================================="
                echo "          请选择 Argo 隧道的转发方式"
                echo "=================================================="
                echo "1. 启用 Nginx 作为反向代理分流 (推荐，支持多协议单域名分流，直接回车)"
                echo "2. 不启用 Nginx (多子域名多端口直连，VMess=8401, Trojan=8402)"
                echo "=================================================="
                read -p "请输入选项 [1-2, 默认1]: " nginx_choice
                local new_use_nginx="y"
                if [[ "$nginx_choice" == "2" ]]; then
                    new_use_nginx="n"
                fi

                local new_domain=""
                local new_vmess_domain=""
                local new_trojan_domain=""

                if is_enabled "$new_use_nginx"; then
                    read -p "请输入您在 Cloudflare 上为该隧道绑定的自定义域名 (如: argo.example.com): " new_domain
                    if [[ -z "$new_domain" ]]; then
                        echo "错误：自定义域名不能为空！"
                        continue
                    fi
                else
                    # 检查已安装什么协议以询问对应域名
                    if jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
                        read -p "请输入 VMess 节点对应的自定义子域名 (如: vmess.example.com): " new_vmess_domain
                        if [[ -z "$new_vmess_domain" ]]; then
                            echo "错误：VMess 子域名不能为空！"
                            continue
                        fi
                    fi
                    if jq -e '.inbounds[] | select(.tag=="trojan-ws-in")' /etc/s-box/sb.json >/dev/null 2>&1; then
                        read -p "请输入 Trojan 节点对应的自定义子域名 (如: trojan.example.com): " new_trojan_domain
                        if [[ -z "$new_trojan_domain" ]]; then
                            echo "错误：Trojan 子域名不能为空！"
                            continue
                        fi
                    fi
                fi
                
                echo "正在配置固定域名隧道..."
                
                local argo_depend="net sing-box"
                if is_enabled "$new_use_nginx"; then
                    argo_depend="net sing-box nginx"
                fi
                
                if $IS_OPENRC; then
                    cat > /etc/init.d/argo-tunnel <<EOF_INIT
#!/sbin/openrc-run
name="argo-tunnel"
description="Argo Tunnel Service"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate run --token ${new_token}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/argo-tunnel.log"
error_log="/var/log/argo-tunnel.log"
depend() {
    need ${argo_depend}
}
EOF_INIT
                    chmod +x /etc/init.d/argo-tunnel
                else
                    cat > /etc/systemd/system/argo-tunnel.service <<EOF_SYSTEMD
[Unit]
Description=Argo Tunnel Service
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${new_token}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
                    systemctl daemon-reload
                fi
                
                cat > /etc/s-box/argo.conf <<EOF_ARGO
ARGO_MODE="token"
ARGO_TOKEN="${new_token}"
ARGO_DOMAIN="${new_domain}"
ARGO_VMESS_DOMAIN="${new_vmess_domain}"
ARGO_TROJAN_DOMAIN="${new_trojan_domain}"
USE_NGINX="${new_use_nginx}"
ARGO_PORT="${ARGO_PORT}"
EOF_ARGO

                if ! is_enabled "$new_use_nginx"; then
                    echo "${new_vmess_domain:-$new_trojan_domain}" > /etc/s-box/argo.log
                else
                    echo "$new_domain" > /etc/s-box/argo.log
                fi
                
                service_restart argo-tunnel
                regenerate_info_log
                echo "成功配置并启用固定域名隧道！"
                local port_nginx=$(grep -oE "listen 127.0.0.1:[0-9]+" ${NGINX_CONF_DIR}/singbox-argo.conf 2>/dev/null | head -n 1 | awk -F: '{print $2}')
                [[ -z "$port_nginx" ]] && port_nginx=8401
                if is_enabled "$new_use_nginx"; then
                    echo -e "\033[1;33m【重要提示】请前往 Cloudflare Zero Trust 控制台，将该隧道对应的 Public Hostname 服务地址 (Service)"
                    echo -e "设置为: http://127.0.0.1:${port_nginx} (请务必使用 127.0.0.1，以避免 localhost 的 IPv6 解析冲突！)\033[0m"
                else
                    echo -e "\033[1;33m【重要提示】请前往 Cloudflare Zero Trust 控制台，分别配置子域名对应的 Public Hostname 服务地址 (Service)："
                    if [[ -n "$new_vmess_domain" ]]; then
                        local port_vmess=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
                        [[ -z "$port_vmess" ]] && port_vmess=8401
                        echo -e "  → 子域名: ${new_vmess_domain} → http://127.0.0.1:${port_vmess}"
                    fi
                    if [[ -n "$new_trojan_domain" ]]; then
                        local port_trojan_ws=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
                        [[ -z "$port_trojan_ws" ]] && port_trojan_ws=8402
                        echo -e "  → 子域名: ${new_trojan_domain} → http://127.0.0.1:${port_trojan_ws}"
                    fi
                    echo -e "  (请务必使用 127.0.0.1，以避免 localhost 的 IPv6 解析冲突！)\033[0m"
                fi
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

modify_node_params() {
    if [[ ! -f /etc/s-box/sb.json ]]; then
        echo "错误：未找到配置文件 /etc/s-box/sb.json"
        return
    fi

    while true; do
        echo "=================================================="
        echo "          修改已搭建节点参数"
        echo "=================================================="
        
        local has_vless=false; local has_vless_warp=false
        local has_vmess=false; local has_vmess_warp=false
        local has_trojan=false; local has_trojan_warp=false
        local has_hy2=false; local has_hy2_warp=false
        local has_tuic=false; local has_tuic_warp=false
        local has_anytls=false; local has_anytls_warp=false
        
        jq -e '.inbounds[] | select(.tag=="vless-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_vless=true
        jq -e '.inbounds[] | select(.tag=="vless-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_vless_warp=true
        jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_vmess=true
        jq -e '.inbounds[] | select(.tag=="vmess-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_vmess_warp=true
        jq -e '.inbounds[] | select(.tag=="trojan-tls-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_trojan=true
        jq -e '.inbounds[] | select(.tag=="trojan-tls-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_trojan_warp=true
        jq -e '.inbounds[] | select(.tag=="hy2-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_hy2=true
        jq -e '.inbounds[] | select(.tag=="hy2-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_hy2_warp=true
        jq -e '.inbounds[] | select(.tag=="tuic-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_tuic=true
        jq -e '.inbounds[] | select(.tag=="tuic-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_tuic_warp=true
        jq -e '.inbounds[] | select(.tag=="anytls-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_anytls=true
        jq -e '.inbounds[] | select(.tag=="anytls-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_anytls_warp=true
        
        local menu_index=1
        local opt_vless=0; local opt_vless_warp=0
        local opt_vmess=0; local opt_vmess_warp=0
        local opt_trojan=0; local opt_trojan_warp=0
        local opt_hy2=0; local opt_hy2_warp=0
        local opt_tuic=0; local opt_tuic_warp=0
        local opt_anytls=0; local opt_anytls_warp=0
        
        if $has_vless; then
            echo "${menu_index}. 修改 VLESS-Reality 节点参数"
            opt_vless=$menu_index
            ((menu_index++))
        fi
        if $has_vless_warp; then
            echo "${menu_index}. 修改 VLESS-Reality-WARP 节点参数"
            opt_vless_warp=$menu_index
            ((menu_index++))
        fi
        if $has_vmess; then
            echo "${menu_index}. 修改 VMess-WS 节点参数"
            opt_vmess=$menu_index
            ((menu_index++))
        fi
        if $has_vmess_warp; then
            echo "${menu_index}. 修改 VMess-WS-WARP 节点参数"
            opt_vmess_warp=$menu_index
            ((menu_index++))
        fi
        if $has_trojan; then
            echo "${menu_index}. 修改 Trojan-WS-TLS 节点参数"
            opt_trojan=$menu_index
            ((menu_index++))
        fi
        if $has_trojan_warp; then
            echo "${menu_index}. 修改 Trojan-WS-TLS-WARP 节点参数"
            opt_trojan_warp=$menu_index
            ((menu_index++))
        fi
        if $has_hy2; then
            echo "${menu_index}. 修改 Hysteria2 节点参数"
            opt_hy2=$menu_index
            ((menu_index++))
        fi
        if $has_hy2_warp; then
            echo "${menu_index}. 修改 Hysteria2-WARP 节点参数"
            opt_hy2_warp=$menu_index
            ((menu_index++))
        fi
        if $has_tuic; then
            echo "${menu_index}. 修改 TUIC v5 节点参数"
            opt_tuic=$menu_index
            ((menu_index++))
        fi
        if $has_tuic_warp; then
            echo "${menu_index}. 修改 TUIC-WARP 节点参数"
            opt_tuic_warp=$menu_index
            ((menu_index++))
        fi
        if $has_anytls; then
            echo "${menu_index}. 修改 AnyTLS 节点参数"
            opt_anytls=$menu_index
            ((menu_index++))
        fi
        if $has_anytls_warp; then
            echo "${menu_index}. 修改 AnyTLS-WARP 节点参数"
            opt_anytls_warp=$menu_index
            ((menu_index++))
        fi
        echo "0. 返回主菜单"
        echo "=================================================="
        read -p "请输入要修改的节点选项 [0-$((menu_index-1))]: " modify_choice
        
        if [[ "$modify_choice" == "0" || -z "$modify_choice" ]]; then
            break
        fi
        
        if [[ "$modify_choice" == "$opt_vless" && $opt_vless -ne 0 ]]; then
            modify_vless ""
        elif [[ "$modify_choice" == "$opt_vless_warp" && $opt_vless_warp -ne 0 ]]; then
            modify_vless "-warp"
        elif [[ "$modify_choice" == "$opt_vmess" && $opt_vmess -ne 0 ]]; then
            modify_vmess ""
        elif [[ "$modify_choice" == "$opt_vmess_warp" && $opt_vmess_warp -ne 0 ]]; then
            modify_vmess "-warp"
        elif [[ "$modify_choice" == "$opt_trojan" && $opt_trojan -ne 0 ]]; then
            modify_trojan ""
        elif [[ "$modify_choice" == "$opt_trojan_warp" && $opt_trojan_warp -ne 0 ]]; then
            modify_trojan "-warp"
        elif [[ "$modify_choice" == "$opt_hy2" && $opt_hy2 -ne 0 ]]; then
            modify_hy2 ""
        elif [[ "$modify_choice" == "$opt_hy2_warp" && $opt_hy2_warp -ne 0 ]]; then
            modify_hy2 "-warp"
        elif [[ "$modify_choice" == "$opt_tuic" && $opt_tuic -ne 0 ]]; then
            modify_tuic ""
        elif [[ "$modify_choice" == "$opt_tuic_warp" && $opt_tuic_warp -ne 0 ]]; then
            modify_tuic "-warp"
        elif [[ "$modify_choice" == "$opt_anytls" && $opt_anytls -ne 0 ]]; then
            modify_anytls ""
        elif [[ "$modify_choice" == "$opt_anytls_warp" && $opt_anytls_warp -ne 0 ]]; then
            modify_anytls "-warp"
        else
            echo "无效的选项，请重新输入。"
        fi
    done
}

add_warp_nodes() {
    if [[ ! -f /etc/s-box/sb.json ]]; then
        echo "错误：未找到配置文件 /etc/s-box/sb.json"
        read -p "按回车键继续..." temp
        return
    fi

    # 检测已有的直连协议
    local has_vless=false has_vmess=false has_trojan=false has_hy2=false has_tuic=false has_anytls=false
    jq -e '.inbounds[] | select(.tag=="vless-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_vless=true
    jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_vmess=true
    jq -e '.inbounds[] | select(.tag=="trojan-tls-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_trojan=true
    jq -e '.inbounds[] | select(.tag=="hy2-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_hy2=true
    jq -e '.inbounds[] | select(.tag=="tuic-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_tuic=true
    jq -e '.inbounds[] | select(.tag=="anytls-in")' /etc/s-box/sb.json >/dev/null 2>&1 && has_anytls=true

    # 检测已有的 WARP 节点
    local existing_warp=""
    jq -e '.inbounds[] | select(.tag=="vless-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && existing_warp="${existing_warp}VLESS "
    jq -e '.inbounds[] | select(.tag=="vmess-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && existing_warp="${existing_warp}VMess "
    jq -e '.inbounds[] | select(.tag=="trojan-tls-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && existing_warp="${existing_warp}Trojan "
    jq -e '.inbounds[] | select(.tag=="hy2-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && existing_warp="${existing_warp}Hy2 "
    jq -e '.inbounds[] | select(.tag=="tuic-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && existing_warp="${existing_warp}TUIC "
    jq -e '.inbounds[] | select(.tag=="anytls-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && existing_warp="${existing_warp}AnyTLS "

    echo "=================================================="
    echo "    追加 WARP 出站节点（不影响已有直连节点）"
    echo "=================================================="
    echo ""
    echo "当前已有的直连协议："
    $has_vless && echo "  ✓ VLESS-Reality" || echo "  ✗ VLESS-Reality (未安装)"
    $has_vmess && echo "  ✓ VMess-WS" || echo "  ✗ VMess-WS (未安装)"
    $has_trojan && echo "  ✓ Trojan-WS-TLS" || echo "  ✗ Trojan-WS-TLS (未安装)"
    $has_hy2 && echo "  ✓ Hysteria2" || echo "  ✗ Hysteria2 (未安装)"
    $has_tuic && echo "  ✓ TUIC v5" || echo "  ✗ TUIC v5 (未安装)"
    $has_anytls && echo "  ✓ AnyTLS" || echo "  ✗ AnyTLS (未安装)"
    echo ""
    if [[ -n "$existing_warp" ]]; then
        echo "已有的 WARP 节点: ${existing_warp}"
        echo "(重新添加将覆盖已有的同协议 WARP 节点)"
        echo ""
    fi
    echo "请选择要添加 WARP 出站的协议（多选请用空格分隔，如 1 3 5）："
    echo "  1. VLESS-Reality-WARP"
    echo "  2. VMess-WS-WARP"
    echo "  3. Trojan-WS-TLS-WARP"
    echo "  4. Hysteria2-WARP"
    echo "  5. TUIC-WARP"
    echo "  6. AnyTLS-WARP"
    echo "  0. 全部添加"
    echo "  q. 取消返回"
    echo "=================================================="
    read -p "请输入选项 (如 1 3 或 0): " warp_selections

    if [[ "$warp_selections" == "q" || -z "$warp_selections" ]]; then
        return
    fi

    local add_vless=false add_vmess=false add_trojan=false add_hy2=false add_tuic=false add_anytls=false
    if [[ "$warp_selections" == "0" ]]; then
        add_vless=true
        add_vmess=true
        add_trojan=true
        add_hy2=true
        add_tuic=true
        add_anytls=true
    else
        for sel in $warp_selections; do
            [[ "$sel" == "1" ]] && add_vless=true
            [[ "$sel" == "2" ]] && add_vmess=true
            [[ "$sel" == "3" ]] && add_trojan=true
            [[ "$sel" == "4" ]] && add_hy2=true
            [[ "$sel" == "5" ]] && add_tuic=true
            [[ "$sel" == "6" ]] && add_anytls=true
        done
    fi

    if ! $add_vless && ! $add_vmess && ! $add_trojan && ! $add_hy2 && ! $add_tuic && ! $add_anytls; then
        echo "未选择任何协议，已取消。"
        read -p "按回车键继续..." temp
        return
    fi

    echo ""
    echo "正在获取 WARP 出站凭证..."
    # 内联 get_warp_credentials 逻辑
    local warpurl
    warpurl=$(curl -sm5 -k https://warp.xijp.eu.org 2>/dev/null || wget -qO- --timeout=5 https://warp.xijp.eu.org 2>/dev/null)
    local WARP_PVK="52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A="
    local WARP_IPV6="2606:4700:110:8d8d:1845:c39f:2dd5:a03a"
    local WARP_RES="[215, 69, 233]"
    if [[ -n "$warpurl" ]] && ! printf '%s' "$warpurl" | grep -q -i "html"; then
        local tmp_pvk tmp_ipv6 tmp_res
        tmp_pvk=$(echo "$warpurl" | awk -F'：' '/Private_key/{print $2}' | xargs)
        tmp_ipv6=$(echo "$warpurl" | awk -F'：' '/IPV6/{print $2}' | xargs)
        tmp_res=$(echo "$warpurl" | awk -F'：' '/reserved/{print $2}' | xargs)
        [[ -n "$tmp_pvk" ]] && WARP_PVK="$tmp_pvk"
        [[ -n "$tmp_ipv6" ]] && WARP_IPV6="$tmp_ipv6"
        if [[ -n "$tmp_res" ]]; then
            if [[ ! "$tmp_res" =~ ^\[ ]]; then WARP_RES="[${tmp_res}]"; else WARP_RES="$tmp_res"; fi
        fi
    fi
    echo "WARP 凭证获取完成。"

    # 获取公网 IP
    local IP
    IP=$(curl -s4m5 icanhazip.com 2>/dev/null || curl -s4m5 api.ipify.org 2>/dev/null)
    [[ -z "$IP" ]] && IP=$(curl -s6m5 icanhazip.com 2>/dev/null || curl -s6m5 api6.ipify.org 2>/dev/null)
    local LISTEN="0.0.0.0"
    [[ -z "$(curl -s4m5 icanhazip.com 2>/dev/null)" ]] && LISTEN="::"

    # 从直连节点复制基础参数
    local UUID=$(jq -r '[.inbounds[]? | select(.users[0].uuid != null) | .users[0].uuid][0]' /etc/s-box/sb.json)
    local PVK=$(jq -r '[.inbounds[]? | select(.tls.reality.private_key != null) | .tls.reality.private_key][0]' /etc/s-box/sb.json)
    local PUBLIC_KEY=""
    [[ -f /etc/s-box/public.key ]] && PUBLIC_KEY=$(cat /etc/s-box/public.key | tr -d '\r\n')
    local SHORT_ID=$(jq -r '[.inbounds[]? | select(.tls.reality.short_id[0] != null) | .tls.reality.short_id[0]][0]' /etc/s-box/sb.json)

    # 凭证兜底生成机制
    if [[ -z "$UUID" || "$UUID" == "null" ]]; then
        UUID=$(/etc/s-box/sing-box generate uuid)
    fi
    if [[ -z "$PVK" || "$PVK" == "null" ]]; then
        local reality_keys
        reality_keys=$(/etc/s-box/sing-box generate reality-keypair 2>/dev/null)
        if [[ -n "$reality_keys" ]]; then
            PVK=$(echo "$reality_keys" | awk '/PrivateKey/{print $2}')
            PUBLIC_KEY=$(echo "$reality_keys" | awk '/PublicKey/{print $2}')
            echo "$PUBLIC_KEY" > /etc/s-box/public.key
        else
            PVK="52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A="
            PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
            echo "$PUBLIC_KEY" > /etc/s-box/public.key
        fi
    fi
    if [[ -z "$SHORT_ID" || "$SHORT_ID" == "null" ]]; then
        SHORT_ID=$(openssl rand -hex 8)
    fi

    # 端口分配与交互逻辑
    local used_ports=$(ss -tunlp | awk '{print $5}' | grep -oE '[0-9]+$' | sort -u)
    get_free_port() {
        local port
        while true; do
            port=$(shuf -i 20000-60000 -n 1)
            if ! echo "$used_ports" | grep -q "^${port}$"; then
                if ! echo -e "$_allocated_ports" | grep -q "^${port}$"; then
                    echo "$port"
                    return
                fi
            fi
        done
    }
    local _allocated_ports=""

    get_port_input() {
        local proto_name=$1
        local tag_name=$2
        local default_port
        default_port=$(get_free_port)
        local port
        while true; do
            read -p "请输入 ${proto_name} 的端口 (当前默认随机: ${default_port}): " port
            if [[ -z "$port" ]]; then
                port=$default_port
            fi
            if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
                echo "输入错误！端口必须是 1 到 65535 之间的数字，请重新输入。"
                continue
            fi
            # 排查在本次配置中已经占用
            if echo -e "$_allocated_ports" | grep -q "^${port}$"; then
                echo "该端口在本次配置中已分配，请重新输入。"
                continue
            fi
            # 排查系统已被非当前 tag 的服务占用
            if ss -tunlp | awk '{print $5}' | grep -oE '[0-9]+$' | grep -q "^${port}$"; then
                local current_tag_port=$(jq -r --arg tag "$tag_name" '.inbounds[]? | select(.tag==$tag) | .listen_port' /etc/s-box/sb.json 2>/dev/null)
                if [[ "$port" != "$current_tag_port" ]]; then
                    echo "该端口已被系统其他服务占用，请重新输入。"
                    continue
                fi
            fi
            _allocated_ports="${_allocated_ports}${port}\n"
            echo "$port"
            return
        done
    }

    local port_vless="" port_vmess="" port_trojan="" port_hy2="" port_tuic="" port_anytls=""
    echo ""
    echo "=================================================="
    echo "               配置节点监听端口"
    echo "=================================================="
    $add_vless && port_vless=$(get_port_input "VLESS-Reality-WARP" "vless-warp-in")
    $add_vmess && port_vmess=$(get_port_input "VMess-WS-WARP" "vmess-warp-in")
    $add_trojan && port_trojan=$(get_port_input "Trojan-WS-TLS-WARP" "trojan-tls-warp-in")
    $add_hy2 && port_hy2=$(get_port_input "Hysteria2-WARP" "hy2-warp-in")
    $add_tuic && port_tuic=$(get_port_input "TUIC-WARP" "tuic-warp-in")
    $add_anytls && port_anytls=$(get_port_input "AnyTLS-WARP" "anytls-warp-in")

    echo ""
    echo "正在注入配置到 /etc/s-box/sb.json ..."
    local temp_json=$(mktemp)
    cp /etc/s-box/sb.json "$temp_json"

    # 清理 outbounds 中可能残留的旧版错误 warp-out（兼容性修复）
    if jq -e '.outbounds[]? | select(.tag=="warp-out")' "$temp_json" >/dev/null 2>&1; then
        jq 'del(.outbounds[] | select(.tag=="warp-out"))' "$temp_json" > "${temp_json}.tmp" && mv "${temp_json}.tmp" "$temp_json"
    fi

    # 确保 endpoints 数组存在
    if ! jq -e '.endpoints' "$temp_json" >/dev/null 2>&1; then
        jq '. + {"endpoints": []}' "$temp_json" > "${temp_json}.tmp" && mv "${temp_json}.tmp" "$temp_json"
    fi

    # 在 endpoints 中创建或更新 warp-out（sing-box 1.11+ 使用 endpoints 定义 wireguard）
    if ! jq -e '.endpoints[]? | select(.tag=="warp-out")' "$temp_json" >/dev/null 2>&1; then
        jq --arg pvk "$WARP_PVK" --arg ipv6 "$WARP_IPV6" --argjson res "$WARP_RES" '
            .endpoints += [{
                "type": "wireguard",
                "tag": "warp-out",
                "address": ["172.16.0.2/32", ($ipv6 + "/128")],
                "private_key": $pvk,
                "peers": [{
                    "address": "162.159.192.1",
                    "port": 2408,
                    "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                    "allowed_ips": ["0.0.0.0/0", "::/0"],
                    "reserved": $res
                }],
                "mtu": 1280
            }]
        ' "$temp_json" > "${temp_json}.tmp" && mv "${temp_json}.tmp" "$temp_json"
    else
        jq --arg pvk "$WARP_PVK" --arg ipv6 "$WARP_IPV6" --argjson res "$WARP_RES" '
            (.endpoints[] | select(.tag=="warp-out")) |= {
                "type": "wireguard",
                "tag": "warp-out",
                "address": ["172.16.0.2/32", ($ipv6 + "/128")],
                "private_key": $pvk,
                "peers": [{
                    "address": "162.159.192.1",
                    "port": 2408,
                    "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                    "allowed_ips": ["0.0.0.0/0", "::/0"],
                    "reserved": $res
                }],
                "mtu": 1280
            }
        ' "$temp_json" > "${temp_json}.tmp" && mv "${temp_json}.tmp" "$temp_json"
    fi

    # 确保 route.rules 存在
    if ! jq -e '.route' "$temp_json" >/dev/null 2>&1; then
        jq '. + {"route": {"rules": []}}' "$temp_json" > "${temp_json}.tmp" && mv "${temp_json}.tmp" "$temp_json"
    elif ! jq -e '.route.rules' "$temp_json" >/dev/null 2>&1; then
        jq '.route.rules = []' "$temp_json" > "${temp_json}.tmp" && mv "${temp_json}.tmp" "$temp_json"
    fi

    add_warp_inbound() {
        local proto_tag=$1
        local warp_tag=$2
        local port=$3
        local inbound_json=$4

        # 先删除已有的同 tag 入站（用于覆盖）
        jq --arg tag "$warp_tag" 'del(.inbounds[] | select(.tag==$tag))' "$temp_json" > "${temp_json}.tmp" && mv "${temp_json}.tmp" "$temp_json"
        # 添加入站
        echo "$inbound_json" | jq -s '.[0]' > /tmp/warp_inbound.json
        jq --slurpfile nb /tmp/warp_inbound.json '.inbounds += $nb' "$temp_json" > "${temp_json}.tmp" && mv "${temp_json}.tmp" "$temp_json"
        rm -f /tmp/warp_inbound.json
        # 添加路由规则（如果不存在）
        if ! jq -e --arg tag "$warp_tag" '.route.rules[]? | select(.inbound[]? == $tag)' "$temp_json" >/dev/null 2>&1; then
            jq --arg tag "$warp_tag" '.route.rules += [{"inbound": [$tag], "outbound": "warp-out"}]' "$temp_json" > "${temp_json}.tmp" && mv "${temp_json}.tmp" "$temp_json"
        fi
        echo "  ✓ ${warp_tag} → 端口 ${port}"
    }

    # ---- VLESS-Reality-WARP ----
    if $add_vless; then
        local port=$port_vless
        local sni=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.server_name' /etc/s-box/sb.json)
        local dest=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.reality.handshake.server' /etc/s-box/sb.json)
        local dest_port=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.reality.handshake.server_port' /etc/s-box/sb.json)
        [[ -z "$sni" || "$sni" == "null" ]] && sni="apple.com"
        [[ -z "$dest" || "$dest" == "null" ]] && dest="apple.com"
        [[ -z "$dest_port" || "$dest_port" == "null" ]] && dest_port=443
        local inbound=$(cat <<EOFJ
{
    "type": "vless",
    "tag": "vless-warp-in",
    "listen": "${LISTEN}",
    "listen_port": ${port},
    "users": [{"uuid": "${UUID}", "flow": "xtls-rprx-vision"}],
    "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
            "enabled": true,
            "handshake": {"server": "${dest}", "server_port": ${dest_port}},
            "private_key": "${PVK}",
            "short_id": ["${SHORT_ID}"]
        }
    }
}
EOFJ
)
        add_warp_inbound "vless-in" "vless-warp-in" "$port" "$inbound"
    fi

    # ---- VMess-WS-WARP ----
    if $add_vmess; then
        local port=$port_vmess
        local ws_path=$(jq -r '.inbounds[] | select(.tag=="vmess-in") | .transport.path' /etc/s-box/sb.json)
        [[ -z "$ws_path" || "$ws_path" == "null" ]] && ws_path="/${UUID}-vm-warp"
        local warp_ws_path="${ws_path}-warp"
        local inbound=$(cat <<EOFJ
{
    "type": "vmess",
    "tag": "vmess-warp-in",
    "listen": "${LISTEN}",
    "listen_port": ${port},
    "users": [{"uuid": "${UUID}", "alterId": 0}],
    "transport": {"type": "ws", "path": "${warp_ws_path}"}
}
EOFJ
)
        add_warp_inbound "vmess-in" "vmess-warp-in" "$port" "$inbound"
    fi

    # ---- Trojan-WS-TLS-WARP ----
    if $add_trojan; then
        local port=$port_trojan
        local tr_path=$(jq -r '.inbounds[] | select(.tag=="trojan-tls-in") | .transport.path' /etc/s-box/sb.json)
        [[ -z "$tr_path" || "$tr_path" == "null" ]] && tr_path="/${UUID}-tr-warp"
        local warp_tr_path="${tr_path}-warp"
        local inbound=$(cat <<EOFJ
{
    "type": "trojan",
    "tag": "trojan-tls-warp-in",
    "listen": "${LISTEN}",
    "listen_port": ${port},
    "users": [{"password": "${UUID}"}],
    "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
    },
    "transport": {"type": "ws", "path": "${warp_tr_path}"}
}
EOFJ
)
        add_warp_inbound "trojan-tls-in" "trojan-tls-warp-in" "$port" "$inbound"
    fi

    # ---- Hysteria2-WARP ----
    if $add_hy2; then
        local port=$port_hy2
        local inbound=$(cat <<EOFJ
{
    "type": "hysteria2",
    "tag": "hy2-warp-in",
    "listen": "${LISTEN}",
    "listen_port": ${port},
    "users": [{"password": "${UUID}"}],
    "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
    }
}
EOFJ
)
        add_warp_inbound "hy2-in" "hy2-warp-in" "$port" "$inbound"
    fi

    # ---- TUIC-WARP ----
    if $add_tuic; then
        local port=$port_tuic
        local inbound=$(cat <<EOFJ
{
    "type": "tuic",
    "tag": "tuic-warp-in",
    "listen": "${LISTEN}",
    "listen_port": ${port},
    "users": [{"uuid": "${UUID}", "password": "${UUID}"}],
    "congestion_control": "bbr",
    "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "alpn": ["h3"],
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
    }
}
EOFJ
)
        add_warp_inbound "tuic-in" "tuic-warp-in" "$port" "$inbound"
    fi

    # ---- AnyTLS-WARP ----
    if $add_anytls; then
        local port=$port_anytls
        local inbound=$(cat <<EOFJ
{
    "type": "anytls",
    "tag": "anytls-warp-in",
    "listen": "${LISTEN}",
    "listen_port": ${port},
    "users": [{"password": "${UUID}"}],
    "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
    }
}
EOFJ
)
        add_warp_inbound "anytls-in" "anytls-warp-in" "$port" "$inbound"
    fi

    # 写回并应用
    cp "$temp_json" /etc/s-box/sb.json
    rm -f "$temp_json"

    echo ""
    echo "正在校验配置并重启服务..."
    if apply_changes; then
        echo ""
        echo "=================================================="
        echo "WARP 出站节点追加并启动成功！已有直连节点完全保留不变。"
        echo "=================================================="
    else
        echo ""
        echo "=================================================="
        echo "错误：配置校验失败或服务启动失败，请检查报错日志！"
        echo "=================================================="
    fi
    read -p "按回车键继续..." temp
}

view_logs() {
    while true; do
        echo -e "\033[0;36m"
        echo "    ______   ____     ____    ______     _    __   ____    ____ "
        echo "   / ____/  / __ \   / __ \  / ____/    | |  / /  / __ \  / ___/ "
        echo "  / /__    / /_/ /  / / / / / / __      | | / /  / /_/ /  \\__ \\  "
        echo " / /___   / _, _/  / /_/ / / /_/ /      | |/ /  / ____/  ___/ /  "
        echo "/_____/  /_/ |_|   \\____/  \\____/       |___/  /_/      /____/   "
        echo -e "\033[0m"
        echo "============================================================"
        echo "  服务运行日志查看"
        echo "============================================================"
        echo "  1. 查看 sing-box 节点主进程日志"
        echo "  2. 查看 cloudflared Argo 节点穿透日志"
        echo "  3. 查看服务自愈守护日志"
        echo "------------------------------------------------------------"
        echo "  0. 返回主菜单"
        echo "============================================================"
        read -p "请选择操作 [0-3]: " log_choice
        case $log_choice in
            1)
                echo "========== sing-box 日志 (最近 30 行) =========="
                if $IS_OPENRC || $IS_DIRECT; then
                    tail -n 30 /var/log/sing-box.log 2>/dev/null
                else
                    journalctl -u sing-box -n 30 --no-pager
                fi
                echo "================================================="
                read -p "按回车键继续..." temp
                ;;
            2)
                echo "========== Argo 穿透日志 (最近 30 行) =========="
                if $IS_OPENRC || $IS_DIRECT; then
                    tail -n 30 /var/log/argo-tunnel.log 2>/dev/null
                else
                    journalctl -u argo-tunnel -n 30 --no-pager
                fi
                echo "================================================="
                read -p "按回车键继续..." temp
                ;;
            3)
                echo "========== 自愈守护日志 (最近 30 行) =========="
                if [[ -f /etc/s-box/monitor.log ]]; then
                    tail -n 30 /etc/s-box/monitor.log 2>/dev/null
                else
                    echo "暂无自愈守护日志。"
                fi
                echo "================================================="
                read -p "按回车键继续..." temp
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项！"
                ;;
        esac
    done
}

if [[ "$1" == "repair" ]]; then
    repair_runtime_config
    exit $?
fi

if [[ "$1" == "cron" ]]; then
    log_file="/etc/s-box/monitor.log"
    # 如果日志文件超过 50KB 则进行清空截断，避免体积无限膨胀
    if [[ -f "$log_file" && $(wc -c < "$log_file") -gt 51200 ]]; then
        : > "$log_file"
    fi

    # 监测并重启 sing-box
    if ! service_is_active sing-box; then
        service_restart sing-box
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [自愈守护] 检测到 Sing-box 未运行，已自动拉起！" >> "$log_file"
    fi
    
    # 检查是否配置了 Argo
    if [[ -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
    fi
    if [[ -f ${NGINX_CONF_DIR}/singbox-argo.conf ]] || (! is_enabled "$USE_NGINX" && [[ -f /etc/s-box/argo.conf ]]); then
        if ! service_is_active argo-tunnel; then
            service_restart argo-tunnel
            
            # 判断 argo 模式
            argo_mode="temp"
            if [[ -f /etc/s-box/argo.conf ]]; then
                source /etc/s-box/argo.conf
                argo_mode=$ARGO_MODE
            else
                if $IS_OPENRC; then
                    if grep -q "\--token" /etc/init.d/argo-tunnel 2>/dev/null; then
                        argo_mode="token"
                    fi
                elif ! $IS_DIRECT; then
                    if grep -q "\--token" /etc/systemd/system/argo-tunnel.service 2>/dev/null; then
                        argo_mode="token"
                    fi
                fi
            fi
            
            # 只有在临时模式下才需要重新抓取临时域名
            if [[ "$argo_mode" == "temp" ]]; then
                update_argo_domain
            fi
            regenerate_info_log
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [自愈守护] 检测到 Argo 隧道未运行，已自动拉起并重置配置！" >> "$log_file"
        fi
    fi
    exit 0
fi

while true; do
    check_cron_status() {
        if crontab -l 2>/dev/null | grep -q "sb cron"; then
            echo -e "\033[0;32m已启用\033[0m"
        else
            echo -e "\033[0;31m已禁用\033[0m"
        fi
    }

    echo "=================================================="
    echo "          Sing-box 快捷管理工具 sb"
    echo "=================================================="
    echo "1. 查看已配置的节点分享链接"
    echo "2. 重启 Sing-box 和 Argo 隧道服务"
    echo "3. 停止 Sing-box 和 Argo 隧道服务"
    echo "4. 查看 Argo 隧道实时域名与连接状态"
    echo "5. 修改已搭建节点参数"
    echo "6. 配置 Argo 隧道参数"
    echo "7. 彻底卸载脚本环境"
    echo "8. 开启/关闭服务自愈守护任务 (当前: $(check_cron_status))"
    echo "9. 查看运行日志"
    echo "10. 诊断并修复监听/Argo 同步"
    echo "11. 追加 WARP 出站节点（不影响已有直连节点）"
    echo "12. 重新配置协议组合 (可添加/删除直连或 WARP 节点)"
    echo "0. 退出"
    echo "=================================================="
    read -p "请输入选项 [0-12]: " menu_choice
    case $menu_choice in
        1)
            if [[ -f /etc/s-box/info.log ]]; then
                cat /etc/s-box/info.log
            else
                echo "未找到节点信息日志，请确认是否安装成功。"
            fi
            ;;
        2)
            echo "正在重启服务..."
            service_restart sing-box
            if [[ -f /etc/s-box/argo.conf ]]; then
                source /etc/s-box/argo.conf
            fi
            if is_enabled "$USE_NGINX" && [[ -f ${NGINX_CONF_DIR}/singbox-argo.conf ]]; then
                service_restart argo-tunnel
                update_argo_domain
            elif [[ -f /etc/s-box/argo.conf ]]; then
                service_restart argo-tunnel
                update_argo_domain
            fi
            regenerate_info_log
            echo "重启完成并已重新生成分享链接！"
            ;;
        3)
            echo "正在停止服务..."
            service_stop sing-box
            service_stop argo-tunnel
            echo "服务已停止！"
            ;;
        4)
            echo "正在获取隧道状态..."
            if service_is_active argo-tunnel; then
                echo "Argo 隧道处于运行状态："
                if $IS_OPENRC || $IS_DIRECT; then
                    tail -n 15 /var/log/argo-tunnel.log 2>/dev/null
                else
                    journalctl -u argo-tunnel -n 15 --no-pager
                fi
            else
                echo "Argo 隧道服务未运行。"
            fi
            ;;
        5)
            modify_node_params
            ;;
        6)
            modify_argo
            ;;
        7)
            if [[ -f /etc/s-box/uninstall.sh ]]; then
                bash /etc/s-box/uninstall.sh
                exit 0
            elif [[ -f /root/singbox/uninstall.sh ]]; then
                bash /root/singbox/uninstall.sh
                exit 0
            elif [[ -f ./uninstall.sh ]]; then
                bash ./uninstall.sh
                exit 0
            else
                echo "未找到卸载脚本，正在执行直接清理..."
                service_stop sing-box
                service_stop argo-tunnel
                service_disable sing-box
                service_disable argo-tunnel
                if $IS_OPENRC; then
                    rm -f /etc/init.d/sing-box /etc/init.d/argo-tunnel
                elif $IS_DIRECT; then
                    rm -f /etc/s-box/sing-box.pid /etc/s-box/argo-tunnel.pid
                else
                    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo-tunnel.service
                    systemctl daemon-reload
                fi
                rm -rf /etc/s-box /usr/local/bin/cloudflared /usr/local/bin/sb
                if crontab -l 2>/dev/null | grep -q "sb cron"; then
                    crontab -l | grep -v "sb cron" | crontab -
                fi
                if is_enabled "$USE_NGINX"; then
                    service_restart nginx
                fi
                echo "清理完成！"
                exit 0
            fi
            ;;
        8)
            if crontab -l 2>/dev/null | grep -q "sb cron"; then
                crontab -l | grep -v "sb cron" | crontab -
                echo "已成功关闭自愈守护定时任务。"
            else
                echo "=================================================="
                echo "          配置服务自愈守护检测频率"
                echo "=================================================="
                echo "1. 每分钟检测一次 (默认，直接回车)"
                echo "2. 每 5 分钟检测一次"
                echo "3. 每 10 分钟检测一次"
                echo "4. 每 30 分钟检测一次"
                echo "5. 每小时检测一次"
                echo "=================================================="
                read -p "请输入选项 [1-5, 默认1]: " cron_choice
                cron_time="* * * * *"
                case $cron_choice in
                    2) cron_time="*/5 * * * *" ;;
                    3) cron_time="*/10 * * * *" ;;
                    4) cron_time="*/30 * * * *" ;;
                    5) cron_time="0 * * * *" ;;
                    *) cron_time="* * * * *" ;;
                esac
                (crontab -l 2>/dev/null; echo "${cron_time} /usr/local/bin/sb cron >> /etc/s-box/monitor.log 2>&1") | crontab -
                : > /etc/s-box/monitor.log 2>/dev/null
                echo "已成功开启自愈守护定时任务 (检测频率: ${cron_time})。"
            fi
            read -p "按回车键继续..." temp
            ;;
        9)
            view_logs
            ;;
        10)
            repair_runtime_config
            read -p "按回车键继续..." temp
            ;;
        11)
            add_warp_nodes
            ;;
        12)
            if [[ -f /etc/s-box/install.sh ]]; then
                bash /etc/s-box/install.sh reconfig
            elif [[ -f /root/singbox/install.sh ]]; then
                bash /root/singbox/install.sh reconfig
            elif [[ -f ./install.sh ]]; then
                bash ./install.sh reconfig
            else
                echo "未找到安装脚本 /etc/s-box/install.sh，尝试在线获取并执行重新配置..."
                curl -sL https://raw.githubusercontent.com/hxzl666/singbox/main/install.sh -o /tmp/install.sh && bash /tmp/install.sh reconfig
            fi
            exit 0
            ;;
        0)
            exit 0
            ;;
        *)
            echo "无效输入，请重新选择。"
            ;;
    esac
done
EOF
chmod +x /usr/local/bin/sb
}

if [[ "$1" == "reconfig" ]]; then
    SKIP_INSTALLED_CHECK=true
fi

if [[ "$1" == "repair" ]]; then
    create_sb_tool >/dev/null 2>&1
    bash /usr/local/bin/sb repair
    exit $?
fi

# 检测是否已安装
if [[ -f /etc/s-box/sb.json && "$SKIP_INSTALLED_CHECK" != "true" ]]; then
    echo "=================================================="
    echo "          检测到已安装 Sing-box 服务"
    echo "=================================================="
    echo "1. 进入 Sing-box 快捷管理菜单 (直接回车)"
    echo "2. 重新安装/更新 Sing-box 服务"
    echo "0. 退出"
    echo "=================================================="
    read -p "请选择操作 [0-2, 默认1]: " init_choice
    [[ -z "$init_choice" ]] && init_choice=1
    
    if [[ "$init_choice" == "1" ]]; then
        create_sb_tool >/dev/null 2>&1
        if [[ -f /usr/local/bin/sb ]]; then
            bash /usr/local/bin/sb
            exit 0
        else
            log_warn "未找到快捷管理工具 /usr/local/bin/sb，自动进入安装流程。"
        fi
    elif [[ "$init_choice" == "0" ]]; then
        exit 0
    fi
fi

# 节点配置默认值（自适应从已有 sb.json 中提取启用状态，用作交互选择的默认状态，实现无损的增量配置）
if [[ -f /etc/s-box/sb.json ]]; then
    jq -e '.inbounds[] | select(.tag=="vless-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_VLESS="y" || ENABLE_VLESS="n"
    jq -e '.inbounds[] | select(.tag=="vmess-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_VMESS="y" || ENABLE_VMESS="n"
    jq -e '.inbounds[] | select(.tag=="trojan-tls-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_TROJAN="y" || ENABLE_TROJAN="n"
    jq -e '.inbounds[] | select(.tag=="hy2-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_HY2="y" || ENABLE_HY2="n"
    jq -e '.inbounds[] | select(.tag=="tuic-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_TUIC="y" || ENABLE_TUIC="n"
    jq -e '.inbounds[] | select(.tag=="anytls-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_ANYTLS="y" || ENABLE_ANYTLS="n"
    
    jq -e '.inbounds[] | select(.tag=="vless-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_VLESS_WARP="y" || ENABLE_VLESS_WARP="n"
    jq -e '.inbounds[] | select(.tag=="vmess-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_VMESS_WARP="y" || ENABLE_VMESS_WARP="n"
    jq -e '.inbounds[] | select(.tag=="trojan-tls-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_TROJAN_WARP="y" || ENABLE_TROJAN_WARP="n"
    jq -e '.inbounds[] | select(.tag=="hy2-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_HY2_WARP="y" || ENABLE_HY2_WARP="n"
    jq -e '.inbounds[] | select(.tag=="tuic-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_TUIC_WARP="y" || ENABLE_TUIC_WARP="n"
    jq -e '.inbounds[] | select(.tag=="anytls-warp-in")' /etc/s-box/sb.json >/dev/null 2>&1 && ENABLE_ANYTLS_WARP="y" || ENABLE_ANYTLS_WARP="n"
    
    if [[ -f /etc/s-box/argo.conf ]] || systemctl is-active argo-tunnel >/dev/null 2>&1 || rc-service argo-tunnel status >/dev/null 2>&1; then
        ENABLE_ARGO="y"
    else
        ENABLE_ARGO="n"
    fi
else
    ENABLE_VLESS="y"
    ENABLE_VMESS="y"
    ENABLE_TROJAN="y"
    ENABLE_HY2="y"
    ENABLE_TUIC="y"
    ENABLE_ANYTLS="y"
    ENABLE_ARGO="y"
    ENABLE_VLESS_WARP="n"
    ENABLE_VMESS_WARP="n"
    ENABLE_TROJAN_WARP="n"
    ENABLE_HY2_WARP="n"
    ENABLE_TUIC_WARP="n"
    ENABLE_ANYTLS_WARP="n"
fi

get_prompt_default() {
    local current_val=$1
    if [[ "$current_val" == "y" || "$current_val" == "yes" ]]; then
        echo "Y/n"
    else
        echo "y/N"
    fi
}

# 提供自定义组合的交互式提示
echo "=================================================="
echo "          请选择要安装的节点组合"
echo "=================================================="
echo "1. 默认安装全部/保持原装节点协议 (直接回车)"
echo "2. 自定义选择需要安装的节点协议"
echo "3. 只安装走 WARP 出站的备份节点"
echo "=================================================="
read -p "请输入选项 [1-3, 默认1]: " menu_choice

if [[ "$menu_choice" == "2" ]]; then
    local opt
    read -p "1. 是否安装 VLESS-Reality? [$(get_prompt_default $ENABLE_VLESS), 默认 ${ENABLE_VLESS}]: " opt
    [[ -n "$opt" ]] && ENABLE_VLESS=$(echo "$opt" | tr 'A-Z' 'a-z')
    
    read -p "2. 是否安装 VMess-WS? [$(get_prompt_default $ENABLE_VMESS), 默认 ${ENABLE_VMESS}]: " opt
    [[ -n "$opt" ]] && ENABLE_VMESS=$(echo "$opt" | tr 'A-Z' 'a-z')
    
    read -p "3. 是否安装 Trojan-WS-TLS (自签证书)? [$(get_prompt_default $ENABLE_TROJAN), 默认 ${ENABLE_TROJAN}]: " opt
    [[ -n "$opt" ]] && ENABLE_TROJAN=$(echo "$opt" | tr 'A-Z' 'a-z')
    
    read -p "4. 是否安装 Hysteria2? [$(get_prompt_default $ENABLE_HY2), 默认 ${ENABLE_HY2}]: " opt
    [[ -n "$opt" ]] && ENABLE_HY2=$(echo "$opt" | tr 'A-Z' 'a-z')
    
    read -p "5. 是否安装 TUIC v5? [$(get_prompt_default $ENABLE_TUIC), 默认 ${ENABLE_TUIC}]: " opt
    [[ -n "$opt" ]] && ENABLE_TUIC=$(echo "$opt" | tr 'A-Z' 'a-z')
    
    read -p "6. 是否安装 AnyTLS? [$(get_prompt_default $ENABLE_ANYTLS), 默认 ${ENABLE_ANYTLS}]: " opt
    [[ -n "$opt" ]] && ENABLE_ANYTLS=$(echo "$opt" | tr 'A-Z' 'a-z')
    
    read -p "7. 是否安装 Argo 隧道穿透 (支持 VMess/Trojan)? [$(get_prompt_default $ENABLE_ARGO), 默认 ${ENABLE_ARGO}]: " opt
    [[ -n "$opt" ]] && ENABLE_ARGO=$(echo "$opt" | tr 'A-Z' 'a-z')
    
    local has_warp_installed="n"
    if [[ "$ENABLE_VLESS_WARP" == "y" || "$ENABLE_VMESS_WARP" == "y" || "$ENABLE_TROJAN_WARP" == "y" || "$ENABLE_HY2_WARP" == "y" || "$ENABLE_TUIC_WARP" == "y" || "$ENABLE_ANYTLS_WARP" == "y" ]]; then
        has_warp_installed="y"
    fi
    read -p "8. 是否同时配置/调整走 WARP 出站的备份节点？[$(get_prompt_default $has_warp_installed), 默认 ${has_warp_installed}]: " opt_warp_global
    [[ -z "$opt_warp_global" ]] && opt_warp_global=$has_warp_installed
    
    if [[ "$opt_warp_global" == "y" || "$opt_warp_global" == "yes" ]]; then
        is_enabled "$ENABLE_VLESS" && { read -p "   是否额外开启 VLESS-Reality-WARP? [$(get_prompt_default $ENABLE_VLESS_WARP), 默认 ${ENABLE_VLESS_WARP}]: " opt; [[ -n "$opt" ]] && ENABLE_VLESS_WARP=$(echo "$opt" | tr 'A-Z' 'a-z'); }
        is_enabled "$ENABLE_VMESS" && { read -p "   是否额外开启 VMess-WS-WARP? [$(get_prompt_default $ENABLE_VMESS_WARP), 默认 ${ENABLE_VMESS_WARP}]: " opt; [[ -n "$opt" ]] && ENABLE_VMESS_WARP=$(echo "$opt" | tr 'A-Z' 'a-z'); }
        is_enabled "$ENABLE_TROJAN" && { read -p "   是否额外开启 Trojan-WS-TLS-WARP? [$(get_prompt_default $ENABLE_TROJAN_WARP), 默认 ${ENABLE_TROJAN_WARP}]: " opt; [[ -n "$opt" ]] && ENABLE_TROJAN_WARP=$(echo "$opt" | tr 'A-Z' 'a-z'); }
        is_enabled "$ENABLE_HY2" && { read -p "   是否额外开启 Hysteria2-WARP? [$(get_prompt_default $ENABLE_HY2_WARP), 默认 ${ENABLE_HY2_WARP}]: " opt; [[ -n "$opt" ]] && ENABLE_HY2_WARP=$(echo "$opt" | tr 'A-Z' 'a-z'); }
        is_enabled "$ENABLE_TUIC" && { read -p "   是否额外开启 TUIC-WARP? [$(get_prompt_default $ENABLE_TUIC_WARP), 安排 ${ENABLE_TUIC_WARP}]: " opt; [[ -n "$opt" ]] && ENABLE_TUIC_WARP=$(echo "$opt" | tr 'A-Z' 'a-z'); }
        is_enabled "$ENABLE_ANYTLS" && { read -p "   是否额外开启 AnyTLS-WARP? [$(get_prompt_default $ENABLE_ANYTLS_WARP), 默认 ${ENABLE_ANYTLS_WARP}]: " opt; [[ -n "$opt" ]] && ENABLE_ANYTLS_WARP=$(echo "$opt" | tr 'A-Z' 'a-z'); }
    fi
elif [[ "$menu_choice" == "3" ]]; then
    ENABLE_VLESS="n"
    ENABLE_VMESS="n"
    ENABLE_TROJAN="n"
    ENABLE_HY2="n"
    ENABLE_TUIC="n"
    ENABLE_ANYTLS="n"
    ENABLE_ARGO="n"
    
    echo "=================================================="
    echo "          请选择要安装的 WARP 出站节点"
    echo "=================================================="
    echo "1. 默认安装全部 WARP 节点 (直接回车)"
    echo "2. 自定义选择需要安装的 WARP 节点"
    echo "=================================================="
    read -p "请输入选项 [1-2, 默认1]: " warp_choice
    
    if [[ "$warp_choice" == "2" ]]; then
        read -p "1. 是否安装 VLESS-Reality-WARP? [y/N, 默认N]: " opt
        [[ "$opt" == "y" || "$opt" == "yes" ]] && ENABLE_VLESS_WARP="y" || ENABLE_VLESS_WARP="n"
        
        read -p "2. 是否安装 VMess-WS-WARP? [y/N, 默认N]: " opt
        [[ "$opt" == "y" || "$opt" == "yes" ]] && ENABLE_VMESS_WARP="y" || ENABLE_VMESS_WARP="n"
        
        read -p "3. 是否安装 Trojan-WS-TLS-WARP (自签证书)? [y/N, 默认N]: " opt
        [[ "$opt" == "y" || "$opt" == "yes" ]] && ENABLE_TROJAN_WARP="y" || ENABLE_TROJAN_WARP="n"
        
        read -p "4. 是否安装 Hysteria2-WARP? [y/N, 默认N]: " opt
        [[ "$opt" == "y" || "$opt" == "yes" ]] && ENABLE_HY2_WARP="y" || ENABLE_HY2_WARP="n"
        
        read -p "5. 是否安装 TUIC-WARP? [y/N, 默认N]: " opt
        [[ "$opt" == "y" || "$opt" == "yes" ]] && ENABLE_TUIC_WARP="y" || ENABLE_TUIC_WARP="n"
        
        read -p "6. 是否安装 AnyTLS-WARP? [y/N, 默认N]: " opt
        [[ "$opt" == "y" || "$opt" == "yes" ]] && ENABLE_ANYTLS_WARP="y" || ENABLE_ANYTLS_WARP="n"
    else
        ENABLE_VLESS_WARP="y"
        ENABLE_VMESS_WARP="y"
        ENABLE_TROJAN_WARP="y"
        ENABLE_HY2_WARP="y"
        ENABLE_TUIC_WARP="y"
        ENABLE_ANYTLS_WARP="y"
    fi
    
    # 防呆校验
    if [[ "$ENABLE_VLESS_WARP" != "y" && "$ENABLE_VMESS_WARP" != "y" && "$ENABLE_TROJAN_WARP" != "y" && "$ENABLE_HY2_WARP" != "y" && "$ENABLE_TUIC_WARP" != "y" && "$ENABLE_ANYTLS_WARP" != "y" ]]; then
        log_warn "未选择任何 WARP 节点，将默认安装全部 WARP 节点。"
        ENABLE_VLESS_WARP="y"
        ENABLE_VMESS_WARP="y"
        ENABLE_TROJAN_WARP="y"
        ENABLE_HY2_WARP="y"
        ENABLE_TUIC_WARP="y"
        ENABLE_ANYTLS_WARP="y"
    fi
else
    # 默认选项下的 Warp 节点行为
    local has_warp_installed="n"
    if [[ "$ENABLE_VLESS_WARP" == "y" || "$ENABLE_VMESS_WARP" == "y" || "$ENABLE_TROJAN_WARP" == "y" || "$ENABLE_HY2_WARP" == "y" || "$ENABLE_TUIC_WARP" == "y" || "$ENABLE_ANYTLS_WARP" == "y" ]]; then
        has_warp_installed="y"
    fi
    # 只有原来没有配置过 warp 且没有进入自定义分支时，默认一键安装全部才对 warp 也进行全开；如果原来已经有配置，默认一键继续沿用旧配置状态
    if [[ "$has_warp_installed" == "n" ]]; then
        read -p "是否同时安装走 WARP 出站的备份节点？[y/N, 默认N]: " opt_warp_global
        if [[ "$opt_warp_global" == "y" || "$opt_warp_global" == "yes" ]]; then
            ENABLE_VLESS_WARP="y"
            ENABLE_VMESS_WARP="y"
            ENABLE_TROJAN_WARP="y"
            ENABLE_HY2_WARP="y"
            ENABLE_TUIC_WARP="y"
            ENABLE_ANYTLS_WARP="y"
        fi
    fi
fi

# 统一判断，空值或 y/yes 都视为启用
is_enabled() {
    [[ "$1" == "y" || "$1" == "yes" || -z "$1" ]] && return 0 || return 1
}

# 提供 Argo 配置的交互选择
USE_NGINX="y"
ARGO_MODE="temp"
ARGO_TOKEN=""
ARGO_DOMAIN=""
ARGO_VMESS_DOMAIN=""
ARGO_TROJAN_DOMAIN=""

if is_enabled "$ENABLE_ARGO"; then
    # 尝试从已有配置自适应继承
    if [[ -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
    fi
    
    # 询问 Argo 隧道的运行模式
    if [[ "$ARGO_MODE" != "token" ]]; then
        echo "=================================================="
        echo "          请选择 Argo 隧道的运行模式"
        echo "=================================================="
        echo "1. 申请临时域名隧道 (TryCloudflare，直接回车)"
        echo "2. 使用自备固定域名隧道 (使用 Cloudflare Tunnel Token)"
        echo "=================================================="
        read -p "请输入选项 [1-2, 默认1]: " argo_mode_choice
        if [[ "$argo_mode_choice" == "2" ]]; then
            ARGO_MODE="token"
        else
            ARGO_MODE="temp"
        fi
    fi

    if [[ "$ARGO_MODE" == "token" ]]; then
        # 输入 Token
        if [[ -z "$ARGO_TOKEN" ]]; then
            while true; do
                read -p "请输入您的 Cloudflare Tunnel Token: " ARGO_TOKEN
                if [[ -n "$ARGO_TOKEN" ]]; then
                    break
                fi
                log_err "Token 不能为空，请重新输入！"
            done
        fi

        # 选择转发方式
        echo "=================================================="
        echo "          请选择 Argo 隧道的转发方式"
        echo "=================================================="
        echo "1. 启用 Nginx 作为反向代理分流 (推荐，支持多协议单域名分流，直接回车)"
        echo "2. 不启用 Nginx (多子域名多端口直连，VMess=8401, Trojan=8402)"
        echo "=================================================="
        read -p "请输入选项 [1-2, 默认1]: " nginx_choice
        if [[ "$nginx_choice" == "2" ]]; then
            USE_NGINX="n"
        else
            USE_NGINX="y"
        fi

        if is_enabled "$USE_NGINX"; then
            # 单域名模式
            while true; do
                read -p "请输入您在 Cloudflare 上为该隧道绑定的自定义域名 (如: argo.example.com): " ARGO_DOMAIN
                if [[ -n "$ARGO_DOMAIN" ]]; then
                    break
                fi
                log_err "自定义域名不能为空，请重新输入！"
            done
        else
            # 免 Nginx 多子域名模式
            if is_enabled "$ENABLE_VMESS"; then
                while true; do
                    read -p "请输入 VMess 节点对应的自定义子域名 (如: vmess.example.com): " ARGO_VMESS_DOMAIN
                    if [[ -n "$ARGO_VMESS_DOMAIN" ]]; then
                        break
                    fi
                    log_err "VMess 子域名不能为空，请重新输入！"
                done
            fi
            if is_enabled "$ENABLE_TROJAN"; then
                while true; do
                    read -p "请输入 Trojan 节点对应的自定义子域名 (如: trojan.example.com): " ARGO_TROJAN_DOMAIN
                    if [[ -n "$ARGO_TROJAN_DOMAIN" ]]; then
                        break
                    fi
                    log_err "Trojan 子域名不能为空，请重新输入！"
                done
            fi
        fi
    else
        # 临时域名模式强制启用 Nginx
        USE_NGINX="y"
    fi
fi

# 1. 系统检测与包管理器识别
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
        release="Ubuntu"
    elif [[ "$ID" == "debian" ]]; then
        release="Debian"
    elif [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "rocky" || "$ID" == "almalinux" ]]; then
        release="CentOS"
    elif [[ "$ID" == "alpine" ]]; then
        release="Alpine"
    else
        log_err "暂不支持的系统类型: $NAME。请使用 Ubuntu, Debian, CentOS 或 Alpine。"
        exit 1
    fi
else
    if [[ -f /etc/redhat-release ]]; then
        release="CentOS"
    elif grep -q -i "debian" /etc/issue; then
        release="Debian"
    elif grep -q -i "ubuntu" /etc/issue; then
        release="Ubuntu"
    elif grep -q -i "alpine" /etc/issue; then
        release="Alpine"
    else
        log_err "暂不支持的系统类型。请使用 Ubuntu, Debian, CentOS 或 Alpine。"
        exit 1
    fi
fi

# 架构检测
arch=$(uname -m)
case $arch in
    x86_64) cpu="amd64" ;;
    aarch64) cpu="arm64" ;;
    armv7l) cpu="arm" ;;
    *)
        log_err "暂不支持的 CPU 架构: $arch"
        exit 1
        ;;
esac

# 2. 安装系统依赖 and Nginx
log_info "正在安装必要的系统依赖..."
if [[ "$release" == "Alpine" ]]; then
    apk update
    apk add --no-cache bash jq openssl curl tar wget procps coreutils iproute2
    is_enabled "$ENABLE_ARGO" && is_enabled "$USE_NGINX" && apk add --no-cache nginx
elif [[ "$release" == "CentOS" ]]; then
    yum install -y epel-release
    yum install -y jq openssl curl tar wget psmisc
    is_enabled "$ENABLE_ARGO" && is_enabled "$USE_NGINX" && yum install -y nginx
else
    apt-get update -y
    apt-get install -y jq openssl curl tar wget psmisc
    is_enabled "$ENABLE_ARGO" && is_enabled "$USE_NGINX" && apt-get install -y nginx
fi

# 安装完依赖后重新检测 Nginx 配置目录（Alpine 安装 nginx 后目录才出现）
if is_enabled "$ENABLE_ARGO" && is_enabled "$USE_NGINX"; then
    NGINX_CONF_DIR="/etc/nginx/conf.d"
    [[ -d "/etc/nginx/http.d" ]] && NGINX_CONF_DIR="/etc/nginx/http.d"
    mkdir -p "${NGINX_CONF_DIR}"
fi

# 3. 创建配置文件目录
mkdir -p /etc/s-box
cd /etc/s-box

# 4. 下载并安装 Sing-box 最新内核
log_info "正在获取 Sing-box 最新版本号..."
latest_version=$(curl -Ls https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/v//')
if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
    # 备用源：从 GitHub 发布页面 HTML 解析版本号
    latest_version=$(curl -Ls https://github.com/SagerNet/sing-box/releases/latest -o /dev/null -w '%{url_effective}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)
fi
if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
    latest_version="1.12.1" # 回退默认版本（需 >= 1.12.0 以支持 AnyTLS）
    log_warn "获取最新版本号失败，使用默认版本 v$latest_version"
fi

# AnyTLS 版本兼容性校验：需要 sing-box >= 1.12.0
if is_enabled "$ENABLE_ANYTLS"; then
    if [[ $(printf '%s\n' "1.12.0" "$latest_version" | sort -V | head -n 1) != "1.12.0" ]]; then
        log_warn "Sing-box v${latest_version} 不支持 AnyTLS 协议（需要 v1.12.0+），已自动跳过 AnyTLS。"
        ENABLE_ANYTLS="n"
    fi
fi

log_info "正在下载 Sing-box 内核 v$latest_version ($cpu)..."
package_name="sing-box-${latest_version}-linux-${cpu}"
download_url="https://github.com/SagerNet/sing-box/releases/download/v${latest_version}/${package_name}.tar.gz"

wget -qO sing-box.tar.gz "$download_url"
if [[ ! -f "sing-box.tar.gz" ]]; then
    log_err "下载 Sing-box 失败，请检查网络。"
    exit 1
fi

tar -xzf sing-box.tar.gz
mv "$package_name/sing-box" ./sing-box
rm -rf sing-box.tar.gz "$package_name"
chmod +x sing-box
log_info "Sing-box 内核安装成功：$(./sing-box version | head -n 1)"

# 5. 如果开启了 Argo，则下载并安装 Cloudflared
if is_enabled "$ENABLE_ARGO"; then
    log_info "正在下载 Cloudflared 客户端..."
    cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cpu}"
    wget -qO /usr/local/bin/cloudflared "$cf_url"
    chmod +x /usr/local/bin/cloudflared
    log_info "Cloudflared 安装成功：$(cloudflared --version)"
fi

# 6. 生成安全凭证与证书
log_info "正在处理配置凭证..."
UUID=""
private_key=""
public_key=""
short_id=""

if [[ -f /etc/s-box/sb.json ]]; then
    UUID=$(jq -r '.inbounds[]? | select(.users[0].uuid != null) | .users[0].uuid' /etc/s-box/sb.json | head -n 1)
    private_key=$(jq -r '.inbounds[]? | select(.tls.reality.private_key != null) | .tls.reality.private_key' /etc/s-box/sb.json | head -n 1)
    short_id=$(jq -r '.inbounds[]? | select(.tls.reality.short_id[0] != null) | .tls.reality.short_id[0]' /etc/s-box/sb.json | head -n 1)
fi

[[ -z "$UUID" || "$UUID" == "null" ]] && UUID=$(./sing-box generate uuid)

if [[ -z "$private_key" || "$private_key" == "null" ]]; then
    reality_keys=$(./sing-box generate reality-keypair)
    private_key=$(echo "$reality_keys" | awk '/PrivateKey/{print $2}')
    public_key=$(echo "$reality_keys" | awk '/PublicKey/{print $2}')
    echo "$public_key" > /etc/s-box/public.key
else
    if [[ -f /etc/s-box/public.key ]]; then
        public_key=$(cat /etc/s-box/public.key | tr -d '\r\n')
    fi
    # 兜底生成以防万一
    if [[ -z "$public_key" ]]; then
        reality_keys=$(./sing-box generate reality-keypair)
        private_key=$(echo "$reality_keys" | awk '/PrivateKey/{print $2}')
        public_key=$(echo "$reality_keys" | awk '/PublicKey/{print $2}')
        echo "$public_key" > /etc/s-box/public.key
    fi
fi

[[ -z "$short_id" || "$short_id" == "null" ]] && short_id=$(openssl rand -hex 8)

# 生成自签证书（若已存在证书则予以保留，不重复覆盖，保持证书指纹稳定）
if [[ ! -f /etc/s-box/private.key || ! -f /etc/s-box/cert.pem ]]; then
    openssl ecparam -genkey -name prime256v1 -out /etc/s-box/private.key
    openssl req -new -x509 -days 36500 -key /etc/s-box/private.key -out /etc/s-box/cert.pem -subj "/CN=www.bing.com"
fi

# 7. 端口自动分配与自定义（检查端口冲突）
check_port() {
    local port=$1
    if ss -tunlp | grep -q ":$port "; then
        return 1
    else
        return 0
    fi
}

get_random_port_in_range() {
    local min=$1
    local max=$2
    local port
    while true; do
        port=$(shuf -i ${min}-${max} -n 1)
        if check_port "$port"; then
            echo "$port"
            break
        fi
    done
}

get_custom_port() {
    local name=$1
    local default_val=$2
    local port
    while true; do
        read -p "请输入 ${name} 的监听端口 [默认 ${default_val}]: " port
        [[ -z "$port" ]] && port=$default_val
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if check_port "$port"; then
                echo "$port"
                break
            else
                log_warn "端口 $port 已被占用，请重新输入！"
            fi
        else
            log_err "输入不合法，请输入 1-65535 之间的数字！"
        fi
    done
}

get_port_range() {
    local range_str
    local start_port
    local end_port
    while true; do
        read -p "请输入端口范围 [格式例如 10000-20000, 默认 20000-60000]: " range_str
        if [[ -z "$range_str" ]]; then
            start_port=20000
            end_port=60000
            break
        fi
        if [[ "$range_str" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start_port=${BASH_REMATCH[1]}
            end_port=${BASH_REMATCH[2]}
            if [ "$start_port" -ge 1 ] && [ "$start_port" -le 65535 ] && \
               [ "$end_port" -ge 1 ] && [ "$end_port" -le 65535 ] && \
               [ "$start_port" -le "$end_port" ]; then
                break
            fi
        fi
        log_err "输入不合法！格式应为: 起始端口-结束端口 (如 10000-20000)，且在 1-65535 之间。"
    done
    echo "${start_port} ${end_port}"
}

# 如果已有 sb.json 配置，则尽可能继承已有端口，实现完美增量配置而不需要打乱已有的端口绑定
if [[ -f /etc/s-box/sb.json ]]; then
    cur_vless_port=$(jq -r '.inbounds[]? | select(.tag=="vless-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    cur_vmess_port=$(jq -r '.inbounds[]? | select(.tag=="vmess-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    cur_trojan_port=$(jq -r '.inbounds[]? | select(.tag=="trojan-tls-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    cur_hy2_port=$(jq -r '.inbounds[]? | select(.tag=="hy2-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    cur_tuic_port=$(jq -r '.inbounds[]? | select(.tag=="tuic-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    cur_anytls_port=$(jq -r '.inbounds[]? | select(.tag=="anytls-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    
    cur_vless_warp_port=$(jq -r '.inbounds[]? | select(.tag=="vless-warp-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    cur_vmess_warp_port=$(jq -r '.inbounds[]? | select(.tag=="vmess-warp-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    cur_trojan_warp_port=$(jq -r '.inbounds[]? | select(.tag=="trojan-tls-warp-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    cur_hy2_warp_port=$(jq -r '.inbounds[]? | select(.tag=="hy2-warp-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    cur_tuic_warp_port=$(jq -r '.inbounds[]? | select(.tag=="tuic-warp-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    cur_anytls_warp_port=$(jq -r '.inbounds[]? | select(.tag=="anytls-warp-in") | .listen_port' /etc/s-box/sb.json 2>/dev/null)
    
    [[ -n "$cur_vless_port" && "$cur_vless_port" != "null" ]] && PORT_VLESS="$cur_vless_port"
    [[ -n "$cur_vless_warp_port" && "$cur_vless_warp_port" != "null" ]] && PORT_VLESS_WARP="$cur_vless_warp_port"
    [[ -n "$cur_vmess_port" && "$cur_vmess_port" != "null" ]] && PORT_VMESS="$cur_vmess_port"
    [[ -n "$cur_vmess_warp_port" && "$cur_vmess_warp_port" != "null" ]] && PORT_VMESS_WARP="$cur_vmess_warp_port"
    [[ -n "$cur_trojan_port" && "$cur_trojan_port" != "null" ]] && PORT_TROJAN_TLS="$cur_trojan_port"
    [[ -n "$cur_trojan_warp_port" && "$cur_trojan_warp_port" != "null" ]] && PORT_TROJAN_TLS_WARP="$cur_trojan_warp_port"
    [[ -n "$cur_hy2_port" && "$cur_hy2_port" != "null" ]] && PORT_HY2="$cur_hy2_port"
    [[ -n "$cur_hy2_warp_port" && "$cur_hy2_warp_port" != "null" ]] && PORT_HY2_WARP="$cur_hy2_warp_port"
    [[ -n "$cur_tuic_port" && "$cur_tuic_port" != "null" ]] && PORT_TUIC="$cur_tuic_port"
    [[ -n "$cur_tuic_warp_port" && "$cur_tuic_warp_port" != "null" ]] && PORT_TUIC_WARP="$cur_tuic_warp_port"
    [[ -n "$cur_anytls_port" && "$cur_anytls_port" != "null" ]] && PORT_ANYTLS="$cur_anytls_port"
    [[ -n "$cur_anytls_warp_port" && "$cur_anytls_warp_port" != "null" ]] && PORT_ANYTLS_WARP="$cur_anytls_warp_port"
fi

echo "=================================================="
echo "          请选择端口配置方式"
echo "=================================================="
echo "1. 自动随机端口分配 (20000-60000 范围，直接回车)"
echo "2. 手动为每个选定协议指定固定端口"
echo "3. 指定自定义端口范围并在此范围内随机分配"
echo "=================================================="
read -p "请输入选项 [1-3, 默认1]: " port_choice

if [[ "$port_choice" == "2" ]]; then
    is_enabled "$ENABLE_VLESS" && PORT_VLESS=$(get_custom_port "VLESS-Reality" "${PORT_VLESS:-28201}")
    is_enabled "$ENABLE_VLESS_WARP" && PORT_VLESS_WARP=$(get_custom_port "VLESS-Reality-WARP" "${PORT_VLESS_WARP:-28211}")
    if is_enabled "$ENABLE_VMESS"; then
        if is_enabled "$ENABLE_ARGO" && ! is_enabled "$USE_NGINX"; then
            PORT_VMESS=8401
            log_info "Argo 免 Nginx 穿透 VMess-WS，本地端口已自动固定为 8401。"
        else
            PORT_VMESS=$(get_custom_port "VMess-WS" "${PORT_VMESS:-38202}")
        fi
    fi
    is_enabled "$ENABLE_VMESS_WARP" && PORT_VMESS_WARP=$(get_custom_port "VMess-WS-WARP" "${PORT_VMESS_WARP:-38212}")
    is_enabled "$ENABLE_TROJAN" && PORT_TROJAN_TLS=$(get_custom_port "Trojan-WS-TLS" "${PORT_TROJAN_TLS:-48203}")
    is_enabled "$ENABLE_TROJAN_WARP" && PORT_TROJAN_TLS_WARP=$(get_custom_port "Trojan-WS-TLS-WARP" "${PORT_TROJAN_TLS_WARP:-48213}")
    if is_enabled "$ENABLE_ARGO"; then
        if is_enabled "$ENABLE_TROJAN"; then
            if ! is_enabled "$USE_NGINX"; then
                if is_enabled "$ENABLE_VMESS"; then
                    PORT_TROJAN_WS=8402
                    log_info "Argo 免 Nginx 穿透 Trojan-WS，本地端口已自动固定为 8402。"
                else
                    PORT_TROJAN_WS=8401
                    log_info "Argo 免 Nginx 穿透 Trojan-WS，本地端口已自动固定为 8401。"
                fi
            else
                PORT_TROJAN_WS=$(get_custom_port "Trojan-WS (Argo内部)" "${PORT_TROJAN_WS:-58204}")
            fi
        fi
        is_enabled "$USE_NGINX" && PORT_NGINX=8401
    fi
    is_enabled "$ENABLE_HY2" && PORT_HY2=$(get_custom_port "Hysteria2" "${PORT_HY2:-21092}")
    is_enabled "$ENABLE_HY2_WARP" && PORT_HY2_WARP=$(get_custom_port "Hysteria2-WARP" "${PORT_HY2_WARP:-21102}")
    is_enabled "$ENABLE_TUIC" && PORT_TUIC=$(get_custom_port "TUIC v5" "${PORT_TUIC:-33104}")
    is_enabled "$ENABLE_TUIC_WARP" && PORT_TUIC_WARP=$(get_custom_port "TUIC-WARP" "${PORT_TUIC_WARP:-33114}")
    is_enabled "$ENABLE_ANYTLS" && PORT_ANYTLS=$(get_custom_port "AnyTLS" "${PORT_ANYTLS:-48205}")
    is_enabled "$ENABLE_ANYTLS_WARP" && PORT_ANYTLS_WARP=$(get_custom_port "AnyTLS-WARP" "${PORT_ANYTLS_WARP:-48215}")
elif [[ "$port_choice" == "3" ]]; then
    read start_p end_p <<< $(get_port_range)
    is_enabled "$ENABLE_VLESS" && [[ -z "$PORT_VLESS" ]] && PORT_VLESS=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_VLESS_WARP" && [[ -z "$PORT_VLESS_WARP" ]] && PORT_VLESS_WARP=$(get_random_port_in_range $start_p $end_p)
    if is_enabled "$ENABLE_VMESS"; then
        if is_enabled "$ENABLE_ARGO" && ! is_enabled "$USE_NGINX"; then
            PORT_VMESS=8401
        else
            [[ -z "$PORT_VMESS" ]] && PORT_VMESS=$(get_random_port_in_range $start_p $end_p)
        fi
    fi
    is_enabled "$ENABLE_VMESS_WARP" && [[ -z "$PORT_VMESS_WARP" ]] && PORT_VMESS_WARP=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_TROJAN" && [[ -z "$PORT_TROJAN_TLS" ]] && PORT_TROJAN_TLS=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_TROJAN_WARP" && [[ -z "$PORT_TROJAN_TLS_WARP" ]] && PORT_TROJAN_TLS_WARP=$(get_random_port_in_range $start_p $end_p)
    if is_enabled "$ENABLE_ARGO"; then
        if is_enabled "$ENABLE_TROJAN"; then
            if ! is_enabled "$USE_NGINX"; then
                if is_enabled "$ENABLE_VMESS"; then
                    PORT_TROJAN_WS=8402
                else
                    PORT_TROJAN_WS=8401
                fi
            else
                [[ -z "$PORT_TROJAN_WS" ]] && PORT_TROJAN_WS=$(get_random_port_in_range $start_p $end_p)
            fi
        fi
        is_enabled "$USE_NGINX" && PORT_NGINX=8401
    fi
    is_enabled "$ENABLE_HY2" && [[ -z "$PORT_HY2" ]] && PORT_HY2=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_HY2_WARP" && [[ -z "$PORT_HY2_WARP" ]] && PORT_HY2_WARP=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_TUIC" && [[ -z "$PORT_TUIC" ]] && PORT_TUIC=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_TUIC_WARP" && [[ -z "$PORT_TUIC_WARP" ]] && PORT_TUIC_WARP=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_ANYTLS" && [[ -z "$PORT_ANYTLS" ]] && PORT_ANYTLS=$(get_random_port_in_range $start_p $end_p)
    is_enabled "$ENABLE_ANYTLS_WARP" && [[ -z "$PORT_ANYTLS_WARP" ]] && PORT_ANYTLS_WARP=$(get_random_port_in_range $start_p $end_p)
else
    is_enabled "$ENABLE_VLESS" && [[ -z "$PORT_VLESS" ]] && PORT_VLESS=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_VLESS_WARP" && [[ -z "$PORT_VLESS_WARP" ]] && PORT_VLESS_WARP=$(get_random_port_in_range 20000 60000)
    if is_enabled "$ENABLE_VMESS"; then
        if is_enabled "$ENABLE_ARGO" && ! is_enabled "$USE_NGINX"; then
            PORT_VMESS=8401
        else
            [[ -z "$PORT_VMESS" ]] && PORT_VMESS=$(get_random_port_in_range 20000 60000)
        fi
    fi
    is_enabled "$ENABLE_VMESS_WARP" && [[ -z "$PORT_VMESS_WARP" ]] && PORT_VMESS_WARP=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_TROJAN" && [[ -z "$PORT_TROJAN_TLS" ]] && PORT_TROJAN_TLS=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_TROJAN_WARP" && [[ -z "$PORT_TROJAN_TLS_WARP" ]] && PORT_TROJAN_TLS_WARP=$(get_random_port_in_range 20000 60000)
    if is_enabled "$ENABLE_ARGO"; then
        if is_enabled "$ENABLE_TROJAN"; then
            if ! is_enabled "$USE_NGINX"; then
                if is_enabled "$ENABLE_VMESS"; then
                    PORT_TROJAN_WS=8402
                else
                    PORT_TROJAN_WS=8401
                fi
            else
                [[ -z "$PORT_TROJAN_WS" ]] && PORT_TROJAN_WS=$(get_random_port_in_range 20000 60000)
            fi
        fi
        is_enabled "$USE_NGINX" && PORT_NGINX=8401
    fi
    is_enabled "$ENABLE_HY2" && [[ -z "$PORT_HY2" ]] && PORT_HY2=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_HY2_WARP" && [[ -z "$PORT_HY2_WARP" ]] && PORT_HY2_WARP=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_TUIC" && [[ -z "$PORT_TUIC" ]] && PORT_TUIC=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_TUIC_WARP" && [[ -z "$PORT_TUIC_WARP" ]] && PORT_TUIC_WARP=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_ANYTLS" && [[ -z "$PORT_ANYTLS" ]] && PORT_ANYTLS=$(get_random_port_in_range 20000 60000)
    is_enabled "$ENABLE_ANYTLS_WARP" && [[ -z "$PORT_ANYTLS_WARP" ]] && PORT_ANYTLS_WARP=$(get_random_port_in_range 20000 60000)
fi

ARGO_PORT=""
if is_enabled "$ENABLE_ARGO"; then
    if is_enabled "$USE_NGINX"; then
        ARGO_PORT=$PORT_NGINX
    else
        ARGO_PORT=8401
    fi
fi

# 获取服务器公网 IP
IPV4=$(curl -s4m5 icanhazip.com || curl -s4m5 api.ipify.org)
IPV6=$(curl -s6m5 icanhazip.com || curl -s6m5 api6.ipify.org)
IP=${IPV4:-$IPV6}
SINGBOX_PUBLIC_LISTEN="0.0.0.0"
if [[ -z "$IPV4" && -n "$IPV6" ]]; then
    SINGBOX_PUBLIC_LISTEN="::"
fi
SINGBOX_LOCAL_LISTEN="127.0.0.1"

# 8. 动态生成 sing-box 配置文件 sb.json
log_info "正在生成 sing-box 配置文件..."
inbounds=()

if is_enabled "$ENABLE_VLESS"; then
    inbounds+=('{
      "type": "vless",
      "tag": "vless-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_VLESS}"',
      "users": [
        {
          "uuid": "'"${UUID}"'",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "apple.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "apple.com",
            "server_port": 443
          },
          "private_key": "'"${private_key}"'",
          "short_id": [
            "'"${short_id}"'"
          ]
        }
      }
    }')
fi

if is_enabled "$ENABLE_VMESS"; then
    inbounds+=('{
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_VMESS}"',
      "users": [
        {
          "uuid": "'"${UUID}"'",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/'"${UUID}"'-vm",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }')
fi

if is_enabled "$ENABLE_TROJAN"; then
    inbounds+=('{
      "type": "trojan",
      "tag": "trojan-tls-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_TROJAN_TLS}"',
      "users": [
        {
          "password": "'"${UUID}"'"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      },
      "transport": {
        "type": "ws",
        "path": "/'"${UUID}"'-tr"
      }
    }')
fi

# 如果启用了 Argo，且启用了 Trojan，则为 Argo 创建无 TLS 的 Trojan 端口
if is_enabled "$ENABLE_ARGO" && is_enabled "$ENABLE_TROJAN"; then
    inbounds+=('{
      "type": "trojan",
      "tag": "trojan-ws-in",
      "listen": "'"${SINGBOX_LOCAL_LISTEN}"'",
      "listen_port": '"${PORT_TROJAN_WS}"',
      "users": [
        {
          "password": "'"${UUID}"'"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/'"${UUID}"'-tr-argo"
      }
    }')
fi

if is_enabled "$ENABLE_HY2"; then
    inbounds+=('{
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_HY2}"',
      "users": [
        {
          "password": "'"${UUID}"'"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    }')
fi

if is_enabled "$ENABLE_TUIC"; then
    inbounds+=('{
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_TUIC}"',
      "users": [
        {
          "uuid": "'"${UUID}"'",
          "password": "'"${UUID}"'"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    }')
fi

if is_enabled "$ENABLE_ANYTLS"; then
    inbounds+=('{
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_ANYTLS}"',
      "users": [
        {
          "password": "'"${UUID}"'"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    }')
fi

# 开始生成走 WARP 的节点 inbounds
if is_enabled "$ENABLE_VLESS_WARP"; then
    inbounds+=('{
      "type": "vless",
      "tag": "vless-warp-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_VLESS_WARP}"',
      "users": [
        {
          "uuid": "'"${UUID}"'",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "apple.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "apple.com",
            "server_port": 443
          },
          "private_key": "'"${private_key}"'",
          "short_id": [
            "'"${short_id}"'"
          ]
        }
      }
    }')
fi

if is_enabled "$ENABLE_VMESS_WARP"; then
    inbounds+=('{
      "type": "vmess",
      "tag": "vmess-warp-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_VMESS_WARP}"',
      "users": [
        {
          "uuid": "'"${UUID}"'",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/'"${UUID}"'-vm-warp",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }')
fi

if is_enabled "$ENABLE_TROJAN_WARP"; then
    inbounds+=('{
      "type": "trojan",
      "tag": "trojan-tls-warp-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_TROJAN_TLS_WARP}"',
      "users": [
        {
          "password": "'"${UUID}"'"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      },
      "transport": {
        "type": "ws",
        "path": "/'"${UUID}"'-tr-warp"
      }
    }')
fi

if is_enabled "$ENABLE_HY2_WARP"; then
    inbounds+=('{
      "type": "hysteria2",
      "tag": "hy2-warp-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_HY2_WARP}"',
      "users": [
        {
          "password": "'"${UUID}"'"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    }')
fi

if is_enabled "$ENABLE_TUIC_WARP"; then
    inbounds+=('{
      "type": "tuic",
      "tag": "tuic-warp-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_TUIC_WARP}"',
      "users": [
        {
          "uuid": "'"${UUID}"'",
          "password": "'"${UUID}"'"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    }')
fi

if is_enabled "$ENABLE_ANYTLS_WARP"; then
    inbounds+=('{
      "type": "anytls",
      "tag": "anytls-warp-in",
      "listen": "'"${SINGBOX_PUBLIC_LISTEN}"'",
      "listen_port": '"${PORT_ANYTLS_WARP}"',
      "users": [
        {
          "password": "'"${UUID}"'"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    }')
fi

# 将 inbounds 数组转为 JSON 片段
inbounds_json=""
for i in "${!inbounds[@]}"; do
    if [[ $i -eq 0 ]]; then
        inbounds_json="${inbounds[$i]}"
    else
        inbounds_json="${inbounds_json},${inbounds[$i]}"
    fi
done

any_warp_enabled=false
if is_enabled "$ENABLE_VLESS_WARP" || is_enabled "$ENABLE_VMESS_WARP" || is_enabled "$ENABLE_TROJAN_WARP" || is_enabled "$ENABLE_HY2_WARP" || is_enabled "$ENABLE_TUIC_WARP" || is_enabled "$ENABLE_ANYTLS_WARP"; then
    any_warp_enabled=true
fi

outbounds_json='{
      "type": "direct",
      "tag": "direct"
    }'

route_json=""
endpoints_json=""

if $any_warp_enabled; then
    log_info "正在获取 WARP 出站配置凭证..."
    get_warp_credentials
    
    endpoints_json=",
  \"endpoints\": [
    {
      \"type\": \"wireguard\",
      \"tag\": \"warp-out\",
      \"address\": [
        \"172.16.0.2/32\",
        \"${WARP_IPV6}/128\"
      ],
      \"private_key\": \"${WARP_PVK}\",
      \"peers\": [
        {
          \"address\": \"162.159.192.1\",
          \"port\": 2408,
          \"public_key\": \"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=\",
          \"allowed_ips\": [\"0.0.0.0/0\", \"::/0\"],
          \"reserved\": ${WARP_RES}
        }
      ],
      \"mtu\": 1280
    }
  ]"
    
    warp_tags=()
    is_enabled "$ENABLE_VLESS_WARP" && warp_tags+=('"vless-warp-in"')
    is_enabled "$ENABLE_VMESS_WARP" && warp_tags+=('"vmess-warp-in"')
    is_enabled "$ENABLE_TROJAN_WARP" && warp_tags+=('"trojan-tls-warp-in"')
    is_enabled "$ENABLE_HY2_WARP" && warp_tags+=('"hy2-warp-in"')
    is_enabled "$ENABLE_TUIC_WARP" && warp_tags+=('"tuic-warp-in"')
    is_enabled "$ENABLE_ANYTLS_WARP" && warp_tags+=('"anytls-warp-in"')
    
    warp_tags_json=""
    for i in "${!warp_tags[@]}"; do
        if [[ $i -eq 0 ]]; then
            warp_tags_json="${warp_tags[$i]}"
        else
            warp_tags_json="${warp_tags_json},${warp_tags[$i]}"
        fi
    done
    
    route_json=",
  \"route\": {
    \"rules\": [
      {
        \"inbound\": [
          ${warp_tags_json}
        ],
        \"outbound\": \"warp-out\"
      }
    ]
  }"
fi

cat > /etc/s-box/sb.json <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    ${inbounds_json}
  ],
  "outbounds": [
    ${outbounds_json}
  ]${endpoints_json}${route_json}
}
EOF

if ! /etc/s-box/sing-box check -c /etc/s-box/sb.json >/tmp/s-box-check.log 2>&1; then
    log_err "sing-box 配置校验失败，服务不会启动。错误如下："
    cat /tmp/s-box-check.log
    exit 1
fi

# 9. 配置 Nginx（仅如果启用了 Argo 且启用了 Nginx）
if is_enabled "$ENABLE_ARGO" && is_enabled "$USE_NGINX"; then
    log_info "正在配置 Nginx..."
    
    # 动态写入 nginx location 块
    nginx_locations=""
    if is_enabled "$ENABLE_VMESS"; then
        nginx_locations="${nginx_locations}
    location /${UUID}-vm {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_VMESS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$http_host;
    }"
    fi

    if is_enabled "$ENABLE_TROJAN"; then
        nginx_locations="${nginx_locations}
    location /${UUID}-tr-argo {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_TROJAN_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$http_host;
    }"
    fi

    # 删除 Alpine/Debian 默认的 Nginx 站点配置，避免冲突
    rm -f ${NGINX_CONF_DIR}/default.conf 2>/dev/null
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null

    listen_ipv6=""
    if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 && $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -ne 1 ]]; then
        listen_ipv6="listen [::1]:${PORT_NGINX};"
    fi

    cat > ${NGINX_CONF_DIR}/singbox-argo.conf <<EOF
server {
    listen 127.0.0.1:${PORT_NGINX};
    ${listen_ipv6}
    server_name localhost;
    ${nginx_locations}
}
EOF
    # 测试 Nginx 配置是否合法
    if ! nginx -t >/dev/null 2>&1; then
        log_warn "Nginx 配置测试失败，尝试修复..."
        nginx -t 2>&1 | tail -n 5
    fi
    service_enable nginx
    service_restart nginx
    # 验证 Nginx 是否真正监听了指定端口
    sleep 1
    if ss -tlnp 2>/dev/null | grep -q ":${PORT_NGINX} " || netstat -tlnp 2>/dev/null | grep -q ":${PORT_NGINX} "; then
        log_info "Nginx 已成功启动并监听端口 ${PORT_NGINX}"
    else
        log_warn "Nginx 未在端口 ${PORT_NGINX} 上监听，请检查 Nginx 配置！"
        nginx -t 2>&1
    fi
else
    # 如果没启用 Nginx，为防止原有的 nginx 进程残留运行并占用端口，主动关闭并禁用它
    if which nginx >/dev/null 2>&1 || command -v nginx >/dev/null 2>&1; then
        log_info "正在停止可能残留运行的 Nginx 服务..."
        service_stop nginx
        service_disable nginx
    fi
fi

# 10. 创建守护服务
if $IS_OPENRC; then
    log_info "正在创建 OpenRC 服务..."
    
    # Sing-box OpenRC 服务
    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Service"
command="/etc/s-box/sing-box"
command_args="run -c /etc/s-box/sb.json"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/sing-box
    service_enable sing-box
    service_restart sing-box
elif $IS_DIRECT; then
    log_info "正在以直接进程模式启动 sing-box..."
    : > /var/log/sing-box.log 2>/dev/null
    nohup /etc/s-box/sing-box run -c /etc/s-box/sb.json >> /var/log/sing-box.log 2>&1 &
    echo $! > /etc/s-box/sing-box.pid
else
    log_info "正在创建 systemd 服务..."
    
    # Sing-box 服务
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/s-box
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

sleep 1
if ! service_is_active sing-box; then
    log_err "sing-box 服务启动失败，请查看下面的日志。"
    if $IS_OPENRC || $IS_DIRECT; then
        tail -n 50 /var/log/sing-box.log 2>/dev/null
    else
        journalctl -u sing-box -n 50 --no-pager
    fi
    exit 1
fi

# Argo 隧道服务（仅在启用 Argo 时）
if is_enabled "$ENABLE_ARGO"; then
    # 优先使用交互确定的变量，否则读取已有配置
    argo_mode="${ARGO_MODE:-temp}"
    argo_token="${ARGO_TOKEN}"
    argo_domain="${ARGO_DOMAIN}"
    if [[ -z "$ARGO_TOKEN" && -f /etc/s-box/argo.conf ]]; then
        source /etc/s-box/argo.conf
        argo_mode=$ARGO_MODE
        argo_token=$ARGO_TOKEN
        argo_domain=$ARGO_DOMAIN
    fi

    argo_depend="net sing-box"
    if is_enabled "$USE_NGINX"; then
        argo_depend="net sing-box nginx"
    fi

    if $IS_OPENRC; then
        cf_args="tunnel --url http://127.0.0.1:${ARGO_PORT}"
        if [[ "$argo_mode" == "token" ]]; then
            cf_args="tunnel --no-autoupdate run --token ${argo_token}"
        fi
        cat > /etc/init.d/argo-tunnel <<EOF
#!/sbin/openrc-run
name="argo-tunnel"
description="Argo Tunnel Service"
command="/usr/local/bin/cloudflared"
command_args="${cf_args}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/argo-tunnel.log"
error_log="/var/log/argo-tunnel.log"
depend() {
    need ${argo_depend}
}
EOF
        chmod +x /etc/init.d/argo-tunnel
        service_enable argo-tunnel
        # 清空旧日志，避免提取到旧域名
        : > /var/log/argo-tunnel.log 2>/dev/null
        : > /var/log/argo-tunnel.err 2>/dev/null
        service_restart argo-tunnel
    elif $IS_DIRECT; then
        # 直接进程模式：先保存 argo.conf 再用 nohup 启动
        : > /var/log/argo-tunnel.log 2>/dev/null
        if [[ "$argo_mode" == "token" ]]; then
            nohup /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "$argo_token" >> /var/log/argo-tunnel.log 2>&1 &
        else
            nohup /usr/local/bin/cloudflared tunnel --url "http://127.0.0.1:${ARGO_PORT}" >> /var/log/argo-tunnel.log 2>&1 &
        fi
        echo $! > /etc/s-box/argo-tunnel.pid
    else
        cf_exec="/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:${ARGO_PORT}"
        if [[ "$argo_mode" == "token" ]]; then
            cf_exec="/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${argo_token}"
        fi
        cat > /etc/systemd/system/argo-tunnel.service <<EOF
[Unit]
Description=Argo Tunnel Service
After=network.target

[Service]
User=root
ExecStart=${cf_exec}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable argo-tunnel
        systemctl restart argo-tunnel
    fi

    if [[ "$argo_mode" == "token" ]]; then
        ARGO_DOMAIN="${argo_domain:-$ARGO_DOMAIN}"
        if ! is_enabled "$USE_NGINX"; then
            echo "${ARGO_VMESS_DOMAIN:-$ARGO_TROJAN_DOMAIN}" > /etc/s-box/argo.log
        else
            echo "$ARGO_DOMAIN" > /etc/s-box/argo.log
        fi
        cat > /etc/s-box/argo.conf <<EOF_ARGO
ARGO_MODE="token"
ARGO_TOKEN="${argo_token}"
ARGO_DOMAIN="${ARGO_DOMAIN}"
ARGO_VMESS_DOMAIN="${ARGO_VMESS_DOMAIN}"
ARGO_TROJAN_DOMAIN="${ARGO_TROJAN_DOMAIN}"
USE_NGINX="${USE_NGINX}"
ARGO_PORT="${ARGO_PORT}"
EOF_ARGO
    else
        log_info "正在等待 Argo 隧道上线，获取节点临时域名..."
        sleep 6

        # 提取 trycloudflare 域名
        ARGO_DOMAIN=""
        for i in {1..5}; do
            if $IS_OPENRC || $IS_DIRECT; then
                ARGO_DOMAIN=$(cat /var/log/argo-tunnel.log /var/log/argo-tunnel.err 2>/dev/null | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -n 1)
            else
                ARGO_DOMAIN=$(journalctl -u argo-tunnel -n 50 --no-pager | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -n 1)
            fi
            if [[ -n "$ARGO_DOMAIN" ]]; then
                break
            fi
            sleep 3
        done

        if [[ -z "$ARGO_DOMAIN" ]]; then
            if $IS_OPENRC || $IS_DIRECT; then
                log_warn "获取 Argo 域名超时，请稍后查看 /var/log/argo-tunnel.log。"
            else
                log_warn "获取 Argo 域名超时，请稍后使用 'journalctl -u argo-tunnel' 命令手动查看。"
            fi
            ARGO_DOMAIN="[未获取到Argo域名]"
        fi
        echo "$ARGO_DOMAIN" > /etc/s-box/argo.log
        cat > /etc/s-box/argo.conf <<EOF_ARGO
ARGO_MODE="temp"
ARGO_TOKEN=""
ARGO_DOMAIN="${ARGO_DOMAIN}"
ARGO_VMESS_DOMAIN=""
ARGO_TROJAN_DOMAIN=""
USE_NGINX="${USE_NGINX}"
ARGO_PORT="${ARGO_PORT}"
EOF_ARGO
    fi
fi

# 11. 节点输出与分享链接生成
log_info "所有已选服务部署并启动完毕！"

# 初始化 info.log
cat > /etc/s-box/info.log <<EOF
==================================================
        Sing-box 多协议一键部署脚本 安装成功
==================================================
通用密码/UUID: ${UUID}
EOF

any_direct_enabled=false
if is_enabled "$ENABLE_VLESS" || is_enabled "$ENABLE_VMESS" || is_enabled "$ENABLE_TROJAN" || is_enabled "$ENABLE_HY2" || is_enabled "$ENABLE_TUIC" || is_enabled "$ENABLE_ANYTLS"; then
    any_direct_enabled=true
fi
if $any_direct_enabled; then
    echo "" >> /etc/s-box/info.log
    echo "------------------【直连节点】--------------------" >> /etc/s-box/info.log
fi

# 动态追加直连链接
if is_enabled "$ENABLE_VLESS"; then
    VLESS_LINK="vless://${UUID}@${IP}:${PORT_VLESS}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apple.com&fp=chrome&pbk=${public_key}&sid=${short_id}#SB-VLESS-Reality"
    echo "1. VLESS-Reality:" >> /etc/s-box/info.log
    echo "${VLESS_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

if is_enabled "$ENABLE_VMESS"; then
    VMESS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-WS",
  "add": "${IP}",
  "port": "${PORT_VMESS}",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "",
  "path": "/${UUID}-vm",
  "tls": "none",
  "sni": ""
}
EOF
)
    VMESS_LINK=$(make_vmess_link "$VMESS_JSON")
    echo "2. VMess-WS (无TLS):" >> /etc/s-box/info.log
    echo "${VMESS_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

if is_enabled "$ENABLE_TROJAN"; then
    TROJAN_PATH="/${UUID}-tr"
    TROJAN_PATH_ENCODED=$(url_encode "$TROJAN_PATH")
    TROJAN_LINK="trojan://${UUID}@${IP}:${PORT_TROJAN_TLS}?security=tls&sni=www.bing.com&allowInsecure=1&type=ws&path=${TROJAN_PATH_ENCODED}#SB-Trojan-WS-TLS"
    echo "3. Trojan-WS-TLS (自签证书):" >> /etc/s-box/info.log
    echo "${TROJAN_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

if is_enabled "$ENABLE_HY2"; then
    HY2_LINK="hysteria2://${UUID}@${IP}:${PORT_HY2}?insecure=1&sni=www.bing.com#SB-Hysteria2"
    echo "4. Hysteria2:" >> /etc/s-box/info.log
    echo "${HY2_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

if is_enabled "$ENABLE_TUIC"; then
    TUIC_LINK="tuic://${UUID}:${UUID}@${IP}:${PORT_TUIC}?alpn=h3&congestion_control=bbr&udp_relay=1&allow_insecure=1#SB-TUIC-v5"
    echo "5. TUIC v5:" >> /etc/s-box/info.log
    echo "${TUIC_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

if is_enabled "$ENABLE_ANYTLS"; then
    ANYTLS_LINK="anytls://${UUID}@${IP}:${PORT_ANYTLS}?security=tls&sni=www.bing.com&allowInsecure=1#SB-AnyTLS"
    echo "6. AnyTLS:" >> /etc/s-box/info.log
    echo "${ANYTLS_LINK}" >> /etc/s-box/info.log
    echo "" >> /etc/s-box/info.log
fi

# 动态追加 WARP 链接
any_warp_enabled=false
if is_enabled "$ENABLE_VLESS_WARP" || is_enabled "$ENABLE_VMESS_WARP" || is_enabled "$ENABLE_TROJAN_WARP" || is_enabled "$ENABLE_HY2_WARP" || is_enabled "$ENABLE_TUIC_WARP" || is_enabled "$ENABLE_ANYTLS_WARP"; then
    any_warp_enabled=true
fi
if $any_warp_enabled; then
    echo "------------------【WARP出站节点】--------------------" >> /etc/s-box/info.log
    
    if is_enabled "$ENABLE_VLESS_WARP"; then
        VLESS_WARP_LINK="vless://${UUID}@${IP}:${PORT_VLESS_WARP}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apple.com&fp=chrome&pbk=${public_key}&sid=${short_id}#SB-VLESS-Reality-WARP"
        echo "1. VLESS-Reality-WARP:" >> /etc/s-box/info.log
        echo "${VLESS_WARP_LINK}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi
    
    if is_enabled "$ENABLE_VMESS_WARP"; then
        VMESS_WARP_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-WS-WARP",
  "add": "${IP}",
  "port": "${PORT_VMESS_WARP}",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "",
  "path": "/${UUID}-vm-warp",
  "tls": "none",
  "sni": ""
}
EOF
)
        VMESS_WARP_LINK=$(make_vmess_link "$VMESS_WARP_JSON")
        echo "2. VMess-WS-WARP (无TLS):" >> /etc/s-box/info.log
        echo "${VMESS_WARP_LINK}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi
    
    if is_enabled "$ENABLE_TROJAN_WARP"; then
        TROJAN_WARP_PATH="/${UUID}-tr-warp"
        TROJAN_WARP_PATH_ENCODED=$(url_encode "$TROJAN_WARP_PATH")
        TROJAN_WARP_LINK="trojan://${UUID}@${IP}:${PORT_TROJAN_TLS_WARP}?security=tls&sni=www.bing.com&allowInsecure=1&type=ws&path=${TROJAN_WARP_PATH_ENCODED}#SB-Trojan-WS-TLS-WARP"
        echo "3. Trojan-WS-TLS-WARP (自签证书):" >> /etc/s-box/info.log
        echo "${TROJAN_WARP_LINK}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi
    
    if is_enabled "$ENABLE_HY2_WARP"; then
        HY2_WARP_LINK="hysteria2://${UUID}@${IP}:${PORT_HY2_WARP}?insecure=1&sni=www.bing.com#SB-Hysteria2-WARP"
        echo "4. Hysteria2-WARP:" >> /etc/s-box/info.log
        echo "${HY2_WARP_LINK}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi
    
    if is_enabled "$ENABLE_TUIC_WARP"; then
        TUIC_WARP_LINK="tuic://${UUID}:${UUID}@${IP}:${PORT_TUIC_WARP}?alpn=h3&congestion_control=bbr&udp_relay=1&allow_insecure=1#SB-TUIC-v5-WARP"
        echo "5. TUIC v5-WARP:" >> /etc/s-box/info.log
        echo "${TUIC_WARP_LINK}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi
    
    if is_enabled "$ENABLE_ANYTLS_WARP"; then
        ANYTLS_WARP_LINK="anytls://${UUID}@${IP}:${PORT_ANYTLS_WARP}?security=tls&sni=www.bing.com&allowInsecure=1#SB-AnyTLS-WARP"
        echo "6. AnyTLS-WARP:" >> /etc/s-box/info.log
        echo "${ANYTLS_WARP_LINK}" >> /etc/s-box/info.log
        echo "" >> /etc/s-box/info.log
    fi
fi

# 动态追加 Argo 链接
if is_enabled "$ENABLE_ARGO"; then
    echo "------------------【Argo穿透】--------------------" >> /etc/s-box/info.log
    if [[ "$argo_mode" == "token" ]]; then
        if is_enabled "$USE_NGINX"; then
            echo "Argo 固定域名: ${ARGO_DOMAIN}" >> /etc/s-box/info.log
        else
            [[ -n "$ARGO_VMESS_DOMAIN" ]] && echo "VMess Argo 域名: ${ARGO_VMESS_DOMAIN}" >> /etc/s-box/info.log
            [[ -n "$ARGO_TROJAN_DOMAIN" ]] && echo "Trojan Argo 域名: ${ARGO_TROJAN_DOMAIN}" >> /etc/s-box/info.log
        fi
    else
        echo "Argo 临时域名: ${ARGO_DOMAIN}" >> /etc/s-box/info.log
    fi
    echo "" >> /etc/s-box/info.log

    if is_enabled "$USE_NGINX"; then
        if is_enabled "$ENABLE_VMESS"; then
            VMESS_ARGO_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-Argo-80",
  "add": "${ARGO_DOMAIN}",
  "port": "80",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${ARGO_DOMAIN}",
  "path": "/${UUID}-vm",
  "tls": "none",
  "sni": ""
}
EOF
)
            VMESS_ARGO_80_LINK=$(make_vmess_link "$VMESS_ARGO_JSON")

            VMESS_ARGO_TLS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-Argo-443",
  "add": "${ARGO_DOMAIN}",
  "port": "443",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${ARGO_DOMAIN}",
  "path": "/${UUID}-vm",
  "tls": "tls",
  "sni": "${ARGO_DOMAIN}"
}
EOF
)
            VMESS_ARGO_443_LINK=$(make_vmess_link "$VMESS_ARGO_TLS_JSON")

            echo "1. VMess Argo (80端口):" >> /etc/s-box/info.log
            echo "${VMESS_ARGO_80_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            echo "2. VMess Argo (443端口/TLS):" >> /etc/s-box/info.log
            echo "${VMESS_ARGO_443_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi

        if is_enabled "$ENABLE_TROJAN"; then
            TROJAN_ARGO_PATH="/${UUID}-tr-argo"
            TROJAN_ARGO_PATH_ENCODED=$(url_encode "$TROJAN_ARGO_PATH")
            TROJAN_ARGO_80_LINK="trojan://${UUID}@${ARGO_DOMAIN}:80?security=none&type=ws&path=${TROJAN_ARGO_PATH_ENCODED}&host=${ARGO_DOMAIN}#SB-Trojan-Argo-80"
            TROJAN_ARGO_443_LINK="trojan://${UUID}@${ARGO_DOMAIN}:443?security=tls&sni=${ARGO_DOMAIN}&type=ws&path=${TROJAN_ARGO_PATH_ENCODED}&host=${ARGO_DOMAIN}#SB-Trojan-Argo-443"

            echo "3. Trojan Argo (80端口):" >> /etc/s-box/info.log
            echo "${TROJAN_ARGO_80_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            echo "4. Trojan Argo (443端口/TLS):" >> /etc/s-box/info.log
            echo "${TROJAN_ARGO_443_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
        fi
    else
        # 免 Nginx 模式，双子域名分别独立生成
        argo_idx=1
        if is_enabled "$ENABLE_VMESS" && [[ -n "$ARGO_VMESS_DOMAIN" ]]; then
            VMESS_ARGO_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-Argo-80",
  "add": "${ARGO_VMESS_DOMAIN}",
  "port": "80",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${ARGO_VMESS_DOMAIN}",
  "path": "/${UUID}-vm",
  "tls": "none",
  "sni": ""
}
EOF
)
            VMESS_ARGO_80_LINK=$(make_vmess_link "$VMESS_ARGO_JSON")

            VMESS_ARGO_TLS_JSON=$(cat <<EOF
{
  "v": "2",
  "ps": "SB-VMess-Argo-443",
  "add": "${ARGO_VMESS_DOMAIN}",
  "port": "443",
  "id": "${UUID}",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "${ARGO_VMESS_DOMAIN}",
  "path": "/${UUID}-vm",
  "tls": "tls",
  "sni": "${ARGO_VMESS_DOMAIN}"
}
EOF
)
            VMESS_ARGO_443_LINK=$(make_vmess_link "$VMESS_ARGO_TLS_JSON")

            echo "${argo_idx}. VMess Argo (80端口):" >> /etc/s-box/info.log
            echo "${VMESS_ARGO_80_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            ((argo_idx++))
            echo "${argo_idx}. VMess Argo (443端口/TLS):" >> /etc/s-box/info.log
            echo "${VMESS_ARGO_443_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            ((argo_idx++))
        fi

        if is_enabled "$ENABLE_TROJAN" && [[ -n "$ARGO_TROJAN_DOMAIN" ]]; then
            TROJAN_ARGO_PATH="/${UUID}-tr-argo"
            TROJAN_ARGO_PATH_ENCODED=$(url_encode "$TROJAN_ARGO_PATH")
            TROJAN_ARGO_80_LINK="trojan://${UUID}@${ARGO_TROJAN_DOMAIN}:80?security=none&type=ws&path=${TROJAN_ARGO_PATH_ENCODED}&host=${ARGO_TROJAN_DOMAIN}#SB-Trojan-Argo-80"
            TROJAN_ARGO_443_LINK="trojan://${UUID}@${ARGO_TROJAN_DOMAIN}:443?security=tls&sni=${ARGO_TROJAN_DOMAIN}&type=ws&path=${TROJAN_ARGO_PATH_ENCODED}&host=${ARGO_TROJAN_DOMAIN}#SB-Trojan-Argo-443"

            echo "${argo_idx}. Trojan Argo (80端口):" >> /etc/s-box/info.log
            echo "${TROJAN_ARGO_80_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            ((argo_idx++))
            echo "${argo_idx}. Trojan Argo (443端口/TLS):" >> /etc/s-box/info.log
            echo "${TROJAN_ARGO_443_LINK}" >> /etc/s-box/info.log
            echo "" >> /etc/s-box/info.log
            ((argo_idx++))
        fi
    fi
fi

echo "==================================================" >> /etc/s-box/info.log

# 创建 sb 快捷管理工具
log_info "正在生成快捷管理工具 sb..."
create_sb_tool

# 备份一份 uninstall.sh 在 /etc/s-box 中以便 sb 工具直接调用
if [[ -f ./uninstall.sh ]]; then
    cp ./uninstall.sh /etc/s-box/uninstall.sh
else
    curl -sL https://raw.githubusercontent.com/hxzl666/singbox/main/uninstall.sh -o /etc/s-box/uninstall.sh 2>/dev/null \
        || wget -qO /etc/s-box/uninstall.sh https://raw.githubusercontent.com/hxzl666/singbox/main/uninstall.sh 2>/dev/null
fi
chmod +x /etc/s-box/uninstall.sh 2>/dev/null

# 备份 install.sh 本身以便 sb 管理菜单可调起重新配置
if [[ -f ./install.sh ]]; then
    cp ./install.sh /etc/s-box/install.sh
elif [[ -f "$0" ]]; then
    cp "$0" /etc/s-box/install.sh
fi
chmod +x /etc/s-box/install.sh 2>/dev/null

# 添加守护自愈定时任务（每分钟检查一次）
if ! crontab -l 2>/dev/null | grep -q "sb cron"; then
    (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/sb cron >> /etc/s-box/monitor.log 2>&1") | crontab -
    : > /etc/s-box/monitor.log 2>/dev/null
    log_info "已成功添加 Sing-box / Argo 服务监控守护定时任务。"
fi

# 打印信息到终端
cat /etc/s-box/info.log

# 提示固定隧道用户前往控制台做映射配置
if is_enabled "$ENABLE_ARGO" && [[ "$argo_mode" == "token" ]] && ! is_enabled "$USE_NGINX"; then
    echo ""
    echo -e "\033[1;33m======================================================================="
    echo "【重要提示】您已启用免 Nginx 固定隧道模式，请登录 Cloudflare Zero Trust 控制台："
    echo "  1. 找到对应的 Argo Tunnel，进入 Public Hostname 页面"
    if is_enabled "$ENABLE_VMESS" && [[ -n "$ARGO_VMESS_DOMAIN" ]]; then
        echo "  2. 添加域名: ${ARGO_VMESS_DOMAIN} → Service: http://127.0.0.1:${PORT_VMESS:-8401}"
    fi
    if is_enabled "$ENABLE_TROJAN" && [[ -n "$ARGO_TROJAN_DOMAIN" ]]; then
        echo "  3. 添加域名: ${ARGO_TROJAN_DOMAIN} → Service: http://127.0.0.1:${PORT_TROJAN_WS:-8402}"
    fi
    echo "  (注意：Service 地址请使用 127.0.0.1 而非 localhost，避免 IPv6 双栈环回解析问题)"
    echo -e "=======================================================================\033[0m"
    echo ""
elif is_enabled "$ENABLE_ARGO" && [[ "$argo_mode" == "token" ]] && is_enabled "$USE_NGINX"; then
    port_nginx_actual=$(grep -oE "listen 127.0.0.1:[0-9]+" ${NGINX_CONF_DIR}/singbox-argo.conf 2>/dev/null | head -n 1 | awk -F: '{print $2}')
    [[ -z "$port_nginx_actual" ]] && port_nginx_actual=8401
    echo ""
    echo -e "\033[1;33m======================================================================="
    echo "【重要提示】您已启用 Nginx 固定隧道模式，请登录 Cloudflare Zero Trust 控制台："
    echo "  1. 找到对应的 Argo Tunnel，进入 Public Hostname 页面"
    echo "  2. 添加域名: ${ARGO_DOMAIN} → Service: http://127.0.0.1:${port_nginx_actual}"
    echo "  (注意：Service 地址请使用 127.0.0.1 而非 localhost，避免 IPv6 双栈环回解析问题)"
    echo -e "=======================================================================\033[0m"
    echo ""
fi

log_info "所有已选节点的链接已保存至 /etc/s-box/info.log"
log_info "快捷管理工具已安装。今后你可以直接在终端输入【 sb 】来管理你的服务与节点配置。"
