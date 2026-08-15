#!/bin/bash
# ============================================================================
# Sing-box Linux 多协议一键部署与多出口管理脚本
# ============================================================================
# 支持协议:
#   - Argo Tunnel (Cloudflare Tunnel)
#   - VLESS-Reality
#   - VMess-WS (支持TLS与CDN)
#   - Trojan-WS-TLS
#   - Hysteria2
#   - TUIC v5
#   - AnyTLS
#   - Shadowsocks-2022
# ============================================================================
# 架构层级:
#   【主节点】: 直连出站 / WARP全局出站 / WARP分流出站 / 赛风出站 / Argo穿透
#   【副节点】: 自定义代理出站多出口管理 / 赛风出站多出口管理 (平行独立，互不干扰)
# ============================================================================

# 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "错误：必须以 root 权限运行此脚本！"
   exit 1
fi

# 设置语言环境
export LANG=en_US.UTF-8
export LC_ALL=C

# ==================== 颜色与输出函数 ====================
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
blue="\e[1;36m"
white="\e[1;37m"

red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
blue() { echo -e "\e[1;36m$1\033[0m"; }
white() { echo -e "\e[1;37m$1\033[0m"; }
reading() { read -p "$(yellow "$1")" "$2"; }

log_info() { echo -e "${green}[信息] $1${re}"; }
log_warn() { echo -e "${yellow}[警告] $1${re}"; }
log_err() { echo -e "${red}[错误] $1${re}"; }

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
    encoded=$(printf '%s' "$1" | command jq -sRr @uri 2>/dev/null) || return $?
    printf '%s' "$encoded" | tr -d '\r\n'
}

make_vmess_link() {
    local json="$1"
    printf '%s' "$json" | command jq -e . >/dev/null 2>&1 || return 1
    printf 'vmess://%s' "$(b64_no_wrap "$json")"
}

# ==================== 工作路径与环境判断 ====================
WORKDIR="/etc/s-box"
PROXY_GROUPS_DIR="${WORKDIR}/proxy_groups"
PSI_INSTANCES_DIR="${WORKDIR}/psiphon_instances"
SCRIPT_VERSION="2.0.0"

# 自动检测是否为 OpenRC (Alpine 等) 或 Systemd
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

service_enable() {
    local name=$1
    if $IS_OPENRC; then
        rc-update add "$name" default >/dev/null 2>&1
    elif $IS_DIRECT; then
        :
    else
        systemctl enable "$name" >/dev/null 2>&1
    fi
}

service_disable() {
    local name=$1
    if $IS_OPENRC; then
        rc-update del "$name" default >/dev/null 2>&1
    elif $IS_DIRECT; then
        :
    else
        systemctl disable "$name" >/dev/null 2>&1
    fi
}

service_is_active() {
    local name=$1
    if $IS_OPENRC; then
        rc-service "$name" status 2>/dev/null | grep -q "started"
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

# ==================== 快捷管理脚本写入函数 ====================
create_sb_tool() {
mkdir -p /usr/local/bin
cat > /usr/local/bin/sb <<'EOF_SB_TOOL'
#!/bin/bash
# ============================================================================
# Sing-box 快捷管理工具 sb
# ============================================================================

# 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "错误：必须以 root 权限运行此脚本！"
   exit 1
fi

export LANG=en_US.UTF-8
export LC_ALL=C

# ==================== 颜色定义 ====================
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
blue="\e[1;36m"
white="\e[1;37m"

red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
blue() { echo -e "\e[1;36m$1\033[0m"; }
white() { echo -e "\e[1;37m$1\033[0m"; }
reading() { read -p "$(yellow "$1")" "$2"; }

WORKDIR="/etc/s-box"
PROXY_GROUPS_DIR="${WORKDIR}/proxy_groups"
PSI_INSTANCES_DIR="${WORKDIR}/psiphon_instances"
SCRIPT_VERSION="2.0.0"

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
    encoded=$(printf '%s' "$1" | command jq -sRr @uri 2>/dev/null) || return $?
    printf '%s' "$encoded" | tr -d '\r\n'
}

make_vmess_link() {
    local json="$1"
    printf '%s' "$json" | command jq -e . >/dev/null 2>&1 || return 1
    printf 'vmess://%s' "$(b64_no_wrap "$json")"
}

# 平台与服务自适应
IS_OPENRC=false
IS_DIRECT=false
if [[ -x "/sbin/openrc-run" || -x "/sbin/runlevels" ]]; then
    IS_OPENRC=true
elif ! pidof systemd >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    IS_DIRECT=true
fi

NGINX_CONF_DIR="/etc/nginx/conf.d"
[[ -d "/etc/nginx/http.d" ]] && NGINX_CONF_DIR="/etc/nginx/http.d"

# 服务控制
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
        rc-service "$name" status 2>/dev/null | grep -q "started"
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

# ==================== IP 与系统状态获取 ====================
ALL_IPS=()
get_all_ips() {
    ALL_IPS=()
    mkdir -p "$WORKDIR"
    local ipv4_list
    ipv4_list=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)')
    if [[ -z "$ipv4_list" ]]; then
        local pub_ip
        pub_ip=$(curl -s4m3 https://api.ipify.org || curl -s4m3 https://ip.sb)
        [[ -n "$pub_ip" ]] && ALL_IPS+=("$pub_ip")
    else
        while read -r ip; do
            [[ -n "$ip" ]] && ALL_IPS+=("$ip")
        done <<< "$ipv4_list"
    fi

    # 获取公共 IPv6 (若有)
    local ipv6_list
    ipv6_list=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-fA-F:]+' | grep -vE '^(fe80|::1|fd)')
    if [[ -n "$ipv6_list" ]]; then
        while read -r ip6; do
            [[ -n "$ip6" ]] && ALL_IPS+=("$ip6")
        done <<< "$ipv6_list"
    fi

    [[ ${#ALL_IPS[@]} -eq 0 ]] && ALL_IPS=("$(hostname -I 2>/dev/null | awk '{print $1}')")
    [[ ${#ALL_IPS[@]} -eq 0 || -z "${ALL_IPS[0]}" ]] && ALL_IPS=("127.0.0.1")

    # 缓存
    printf "%s\n" "${ALL_IPS[@]}" > "$WORKDIR/all_ips.txt"
}

display_ip_list() {
    mkdir -p "$WORKDIR"
    for ip in "${ALL_IPS[@]}"; do
        [[ -z "$ip" ]] && continue
        # 探测可用性并缓存
        local status_file="$WORKDIR/ip_status_${ip}.txt"
        if [ ! -f "$status_file" ]; then
            echo "Available" > "$status_file"
        fi
    done
}

# ==================== 端口管理与冲突修复 ====================
get_free_port() {
    local port=$(( (RANDOM % 40000) + 10000 ))
    while ss -tulpn 2>/dev/null | grep -q ":${port} " || netstat -tulpn 2>/dev/null | grep -q ":${port} "; do
        port=$(( (RANDOM % 40000) + 10000 ))
    done
    echo "$port"
}

get_free_loopback_port() {
    local port=$(( (RANDOM % 30000) + 20000 ))
    while ss -tulpn 2>/dev/null | grep -q "127.0.0.1:${port} " || netstat -tulpn 2>/dev/null | grep -q "127.0.0.1:${port} "; do
        port=$(( (RANDOM % 30000) + 20000 ))
    done
    echo "$port"
}

# ==================== WARP 模块 ====================
init_warp_config() {
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
            if [[ ! "$tmp_res" =~ ^\[ ]]; then
                WARP_RES="[${tmp_res}]"
            else
                WARP_RES="$tmp_res"
            fi
        fi
    fi

    echo "$WARP_PVK" > "$WORKDIR/warp_private_key.txt"
    echo "$WARP_IPV6" > "$WORKDIR/warp_ipv6.txt"
    echo "$WARP_RES" > "$WORKDIR/warp_reserved.txt"
    return 0
}

get_warp_endpoint() {
    if [ -f "$WORKDIR/warp_best_endpoint.txt" ]; then
        cat "$WORKDIR/warp_best_endpoint.txt" 2>/dev/null
        return
    fi
    echo "162.159.192.1"
}

warp_egress_test() {
    echo
    purple "正在检测主节点出口 IP (经由当前出站路由)..."
    local loop_port
    loop_port=$(jq -r '.inbounds[] | select(.tag=="socks-loopback") | .listen_port' "$WORKDIR/sb.json" 2>/dev/null)
    if [[ -z "$loop_port" || "$loop_port" == "null" ]]; then
        # 临时直接探测系统出口
        local res
        res=$(curl -s4m5 https://ip.sb 2>/dev/null || curl -s4m5 https://api.ipify.org 2>/dev/null)
        green "当前直连出口 IP: ${res:-未知}"
        return
    fi

    local ip info
    ip=$(curl -sx "socks5h://127.0.0.1:${loop_port}" -s4m5 https://ip.sb 2>/dev/null || curl -sx "socks5h://127.0.0.1:${loop_port}" -s4m5 https://api.ipify.org 2>/dev/null)
    if [[ -n "$ip" ]]; then
        green "主节点出口 IP: $ip"
        info=$(curl -sx "socks5h://127.0.0.1:${loop_port}" -s4m5 "https://api.ip.sb/geoip/${ip}" 2>/dev/null)
        if [[ -n "$info" ]]; then
            local isp country
            isp=$(echo "$info" | jq -r '.isp // empty' 2>/dev/null)
            country=$(echo "$info" | jq -r '.country // empty' 2>/dev/null)
            blue "归属地区: ${country} | 运营商: ${isp}"
        fi
    else
        yellow "测试超时，请检查 sing-box 服务与出站状态。"
    fi
}

# ==================== 赛风 Psiphon 模块 ====================
get_country_name() {
    local code="${1^^}"
    case "$code" in
        US) echo "美国 (United States)" ;;
        JP) echo "日本 (Japan)" ;;
        SG) echo "新加坡 (Singapore)" ;;
        HK) echo "中国香港 (Hong Kong)" ;;
        GB) echo "英国 (United Kingdom)" ;;
        DE) echo "德国 (Germany)" ;;
        CA) echo "加拿大 (Canada)" ;;
        NL) echo "荷兰 (Netherlands)" ;;
        FR) echo "法国 (France)" ;;
        IN) echo "印度 (India)" ;;
        AU) echo "澳大利亚 (Australia)" ;;
        KR) echo "韩国 (South Korea)" ;;
        TW) echo "中国台湾 (Taiwan)" ;;
        AUTO|"") echo "智能自动选择" ;;
        *) echo "$code" ;;
    esac
}

show_supported_psiphon_codes() {
    yellow "支持的常用 Psiphon 出口国家代码:"
    echo "  US - 美国      JP - 日本      SG - 新加坡    HK - 中国香港"
    echo "  GB - 英国      DE - 德国      CA - 加拿大    NL - 荷兰"
    echo "  FR - 法国      IN - 印度      AU - 澳大利亚  AUTO - 自动"
}

detect_arch_slim() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "arm" ;;
        i386|i686) echo "386" ;;
        *) echo "amd64" ;;
    esac
}

install_psiphon_core() {
    if [[ -x "$WORKDIR/psiphon-tunnel-core" ]]; then
        return 0
    fi
    mkdir -p "$WORKDIR"
    local arch
    arch=$(detect_arch_slim)
    yellow "[*] 正在下载 Psiphon 核心程序 (Linux-${arch})..."
    local url="https://github.com/Psiphon-Labs/psiphon-tunnel-core/releases/download/v2.0.28/psiphon-tunnel-core-linux-${arch}"
    if ! curl -fsSL "$url" -o "$WORKDIR/psiphon-tunnel-core" 2>/dev/null; then
        # 备用下载地址
        curl -fsSL "https://raw.githubusercontent.com/hxzl666/singbox/main/psiphon-tunnel-core-linux-${arch}" -o "$WORKDIR/psiphon-tunnel-core" 2>/dev/null || true
    fi
    chmod +x "$WORKDIR/psiphon-tunnel-core" 2>/dev/null
    if [[ ! -x "$WORKDIR/psiphon-tunnel-core" ]]; then
        log_warn "未下载到原生 psiphon-tunnel-core，请确保网络通畅。"
        return 1
    fi
    green "[+] Psiphon 核心已安装: $WORKDIR/psiphon-tunnel-core"
    return 0
}

write_psiphon_config() {
    local socks_port="$1"
    local region="$2"
    local cfg_file="$3"
    local data_dir="$4"

    mkdir -p "$data_dir" 2>/dev/null
    [[ "${region^^}" == "AUTO" ]] && region=""

    cat > "$cfg_file" <<EOF_PSI
{
  "DataRootDirectory": "${data_dir}",
  "EmitDiagnosticNotices": true,
  "EmitDiagnosticNetworkParameters": true,
  "EmitServerAlerts": true,
  "LocalSocksProxyPort": ${socks_port:-0},
  "DisableLocalHTTPProxy": true,
  "LocalHttpProxyPort": 0,
  "EgressRegion": "${region}",
  "PropagationChannelId": "FFFFFFFFFFFFFFFF",
  "SponsorId": "FFFFFFFFFFFFFFFF",
  "UseIndistinguishableTLS": true
}
EOF_PSI
}

start_main_psiphon() {
    install_psiphon_core || return 1
    local psi_pid_file="$WORKDIR/psiphon.pid"
    if [[ -f "$psi_pid_file" ]] && kill -0 "$(cat "$psi_pid_file" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi
    local region
    region=$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null || echo "AUTO")
    local socks_port
    socks_port=$(cat "$WORKDIR/psiphon_socks_port.txt" 2>/dev/null || echo "20800")
    write_psiphon_config "$socks_port" "$region" "$WORKDIR/psiphon.config" "$WORKDIR/psiphon-data"

    nohup "$WORKDIR/psiphon-tunnel-core" --config "$WORKDIR/psiphon.config" >> "$WORKDIR/psiphon.log" 2>&1 &
    echo $! > "$psi_pid_file"
    sleep 2
    return 0
}

stop_main_psiphon() {
    local psi_pid_file="$WORKDIR/psiphon.pid"
    if [[ -f "$psi_pid_file" ]]; then
        local pid
        pid=$(cat "$psi_pid_file" 2>/dev/null)
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
        rm -f "$psi_pid_file"
    fi
    pkill -9 -f "psiphon.config" 2>/dev/null || true
}

# ==================== 副节点目录初始化与同步 ====================
init_proxy_groups_dir() {
    mkdir -p "$PROXY_GROUPS_DIR"
    [[ -f "$PROXY_GROUPS_DIR/groups.txt" ]] || touch "$PROXY_GROUPS_DIR/groups.txt"
}

get_all_proxy_groups() {
    init_proxy_groups_dir
    if [[ -f "$PROXY_GROUPS_DIR/groups.txt" ]]; then
        grep -v '^$' "$PROXY_GROUPS_DIR/groups.txt" | sort -u
    fi
}

proxy_group_exists() {
    local tag="$1"
    init_proxy_groups_dir
    grep -qx "$tag" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null
}

init_psiphon_instances_dir() {
    mkdir -p "$PSI_INSTANCES_DIR"
    [[ -f "$PSI_INSTANCES_DIR/instances.txt" ]] || touch "$PSI_INSTANCES_DIR/instances.txt"
}

get_all_psiphon_instances() {
    init_psiphon_instances_dir
    if [[ -f "$PSI_INSTANCES_DIR/instances.txt" ]]; then
        grep -v '^$' "$PSI_INSTANCES_DIR/instances.txt" | sort -u
    fi
}

# 代理链接解析为 sing-box Outbound JSON (支持 6 种协议)
parse_proxy_url_to_json() {
    local url="$1"
    local tag="$2"
    PROXY_URL="$url" PROXY_TAG="$tag" python3 - <<'PY_PARSER'
import json, sys, base64, os
from urllib.parse import urlparse, parse_qs, unquote

url = os.environ.get('PROXY_URL', '').strip()
tag = os.environ.get('PROXY_TAG', 'proxy-out')

def b64d(s):
    s = s.replace('-', '+').replace('_', '/')
    s += '=' * (4 - len(s) % 4)
    return base64.b64decode(s).decode('utf-8', errors='replace')

def make_tls(params, host, default_sec='tls'):
    sec   = (params.get('security', [default_sec])[0] or default_sec).lower()
    sni   = params.get('sni', [host])[0] or host
    fp    = params.get('fp',  [''])[0]
    pbk   = params.get('pbk', [''])[0]
    sid   = params.get('sid', [''])[0]
    alpn  = [a for a in params.get('alpn', [''])[0].split(',') if a]
    insec = params.get('insecure', ['0'])[0] == '1' or params.get('allowInsecure', ['0'])[0] == '1'
    if sec in ('none', ''):
        return None
    tls = {'enabled': True, 'server_name': sni}
    if alpn:  tls['alpn'] = alpn
    if insec: tls['insecure'] = True
    if fp:    tls['utls'] = {'enabled': True, 'fingerprint': fp}
    if sec == 'reality':
        tls['reality'] = {'enabled': True, 'public_key': pbk, 'short_id': sid}
    return tls

def make_transport(params):
    net  = params.get('type', ['tcp'])[0].lower()
    path = params.get('path', ['/'])[0]
    hdr  = params.get('host', [''])[0]
    svc  = params.get('serviceName', [''])[0]
    if net == 'ws':
        t = {'type': 'ws', 'path': path}
        if hdr: t['headers'] = {'Host': hdr}
        return t
    if net == 'grpc':
        return {'type': 'grpc', 'service_name': svc or path.lstrip('/')}
    if net in ('httpupgrade', 'h1'):
        t = {'type': 'httpupgrade', 'path': path}
        if hdr: t['headers'] = {'Host': hdr}
        return t
    if net == 'h2':
        t = {'type': 'http', 'path': path}
        if hdr: t['host'] = [hdr]
        return t
    return None

def parse_vless(url, tag):
    p = urlparse(url); params = parse_qs(p.query); host = p.hostname
    out = {'type': 'vless', 'tag': tag, 'server': host, 'server_port': p.port or 443,
           'uuid': unquote(p.username or '')}
    flow = params.get('flow', [''])[0]
    if flow: out['flow'] = flow
    t = make_transport(params)
    if t: out['transport'] = t
    tls = make_tls(params, host)
    if tls: out['tls'] = tls
    return out

def parse_vmess(url, tag):
    raw = url[8:]
    try:    data = json.loads(b64d(raw))
    except Exception as e: raise ValueError(f'VMess base64 解码失败: {e}')
    host = data.get('add',''); port = int(data.get('port', 443))
    net  = data.get('net','tcp'); tls_s = data.get('tls','')
    sni  = data.get('sni','') or data.get('host','') or host
    path = data.get('path','/'); hdr = data.get('host',''); fp = data.get('fp','')
    out  = {'type': 'vmess', 'tag': tag, 'server': host, 'server_port': port,
            'uuid': data.get('id',''), 'alter_id': int(data.get('aid',0)),
            'security': data.get('scy','auto')}
    if net == 'ws':
        t = {'type': 'ws', 'path': path}
        if hdr: t['headers'] = {'Host': hdr}
        out['transport'] = t
    elif net == 'grpc':
        out['transport'] = {'type': 'grpc', 'service_name': data.get('serviceName', path.lstrip('/'))}
    elif net in ('httpupgrade', 'h1'):
        t = {'type': 'httpupgrade', 'path': path}
        if hdr: t['headers'] = {'Host': hdr}
        out['transport'] = t
    if tls_s == 'tls':
        tls = {'enabled': True, 'server_name': sni}
        if fp: tls['utls'] = {'enabled': True, 'fingerprint': fp}
        out['tls'] = tls
    return out

def parse_trojan(url, tag):
    p = urlparse(url); params = parse_qs(p.query); host = p.hostname
    out = {'type': 'trojan', 'tag': tag, 'server': host, 'server_port': p.port or 443,
           'password': unquote(p.username or '')}
    t = make_transport(params)
    if t: out['transport'] = t
    tls = make_tls(params, host) or {'enabled': True, 'server_name': host}
    out['tls'] = tls
    return out

def parse_hy2(url, tag):
    p = urlparse(url); params = parse_qs(p.query); host = p.hostname
    pw = unquote(p.username or '') or unquote(p.password or '')
    sni = params.get('sni', [host])[0] or host
    insec = params.get('insecure', ['0'])[0] == '1'
    obfs_t = params.get('obfs', [''])[0]; obfs_p = params.get('obfs-password', [''])[0]
    out = {'type': 'hysteria2', 'tag': tag, 'server': host, 'server_port': p.port or 443,
           'password': pw, 'tls': {'enabled': True, 'server_name': sni, 'insecure': insec}}
    if obfs_t: out['obfs'] = {'type': obfs_t, 'password': obfs_p}
    return out

def parse_tuic(url, tag):
    p = urlparse(url); params = parse_qs(p.query); host = p.hostname
    alpn = [a for a in params.get('alpn', ['h3'])[0].split(',') if a] or ['h3']
    sni  = params.get('sni', [host])[0] or host
    insec = params.get('allow_insecure', ['0'])[0] == '1'
    cc   = params.get('congestion_control', ['bbr'])[0]
    return {'type': 'tuic', 'tag': tag, 'server': host, 'server_port': p.port or 443,
            'uuid': unquote(p.username or ''), 'password': unquote(p.password or ''),
            'congestion_control': cc,
            'tls': {'enabled': True, 'server_name': sni, 'alpn': alpn, 'insecure': insec}}

def parse_ss(url, tag):
    p = urlparse(url); host = p.hostname; port = p.port or 8388
    if p.username and p.password:
        method = unquote(p.username); password = unquote(p.password)
    else:
        userinfo = unquote(p.username or '')
        try:    method, password = b64d(userinfo).split(':', 1)
        except: method = 'aes-256-gcm'; password = userinfo
    return {'type': 'shadowsocks', 'tag': tag, 'server': host, 'server_port': port,
            'method': method, 'password': password}

try:
    if   url.startswith('vless://'):                   r = parse_vless(url, tag)
    elif url.startswith('vmess://'):                   r = parse_vmess(url, tag)
    elif url.startswith('trojan://'):                  r = parse_trojan(url, tag)
    elif url.startswith(('hy2://', 'hysteria2://')):   r = parse_hy2(url, tag)
    elif url.startswith('tuic://'):                    r = parse_tuic(url, tag)
    elif url.startswith('ss://'):                      r = parse_ss(url, tag)
    else:
        print('ERROR: 不支持的协议，支持: vless/vmess/trojan/hy2/tuic/ss')
        sys.exit(1)
    print(json.dumps(r, ensure_ascii=False, indent=2))
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
PY_PARSER
}

validate_and_parse_proxy_url() {
    local url="$1" tag="${2:-proxy-out}" result rc
    result=$(parse_proxy_url_to_json "$url" "$tag" 2>&1); rc=$?
    if [[ $rc -ne 0 ]] || echo "$result" | grep -q '^ERROR:'; then
        red "[!] 链接解析失败: $(echo "$result" | grep '^ERROR:' | head -1 | sed 's/^ERROR: //')"
        return 1
    fi
    echo "$result"
    return 0
}

# ==================== 同步自定义代理副节点到 sing-box ====================
sync_proxy_group_to_singbox() {
    local group_tag="$1"
    local group_dir="${PROXY_GROUPS_DIR}/${group_tag}"
    local cfg="$WORKDIR/sb.json"

    [[ -f "$cfg" ]] || return 1
    [[ -d "$group_dir" ]] || return 1
    [[ -f "$group_dir/outbound.json" ]] || return 1

    local hy2_port tuic_port vless_port uuid
    hy2_port=$(cat "$group_dir/hy2_port.txt" 2>/dev/null || echo "0")
    tuic_port=$(cat "$group_dir/tuic_port.txt" 2>/dev/null || echo "0")
    vless_port=$(cat "$group_dir/vless_port.txt" 2>/dev/null || echo "0")
    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || cat "$WORKDIR/uuid.txt" 2>/dev/null)
    local out_tag="${group_tag}-out"

    python3 - \
        "$cfg" \
        "$group_tag" \
        "$out_tag" \
        "${hy2_port:-0}" \
        "${tuic_port:-0}" \
        "${vless_port:-0}" \
        "$uuid" \
        "$WORKDIR" \
        "$group_dir/outbound.json" <<'PY_SYNC_PROXY'
import json, sys

cfg_path    = sys.argv[1]
group_tag   = sys.argv[2]
out_tag     = sys.argv[3]
hy2_port    = int(sys.argv[4]) if sys.argv[4] else 0
tuic_port   = int(sys.argv[5]) if sys.argv[5] else 0
vless_port  = int(sys.argv[6]) if sys.argv[6] else 0
uuid        = sys.argv[7]
workdir     = sys.argv[8]
outbound_f  = sys.argv[9]

try:
    with open(outbound_f, 'r', encoding='utf-8') as f:
        outbound_obj = json.load(f)
    outbound_obj['tag'] = out_tag
except Exception as e:
    sys.exit(1)

try:
    with open(cfg_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception as e:
    sys.exit(1)

inbounds  = data.setdefault('inbounds',  [])
outbounds = data.setdefault('outbounds', [])
route     = data.setdefault('route',     {})
rules     = route.setdefault('rules',    [])

# 1. 更新 outbound
outbounds[:] = [o for o in outbounds if o.get('tag') != out_tag]
outbounds.append(outbound_obj)

# 2. 移除旧的专属 inbound
def is_mine(ib):
    t = ib.get('tag', '')
    return t == f'hy2-{group_tag}-in' or t == f'tuic-{group_tag}-in' or t == f'vless-{group_tag}-in'

inbounds[:] = [ib for ib in inbounds if not is_mine(ib)]

cert = f'{workdir}/cert.pem'
key  = f'{workdir}/private.key'
inbound_tags = []

if hy2_port > 0:
    t = f'hy2-{group_tag}-in'
    inbound_tags.append(t)
    inbounds.append({
        'type': 'hysteria2', 'tag': t,
        'listen': '::', 'listen_port': hy2_port,
        'users': [{'password': uuid}],
        'masquerade': 'https://www.bing.com',
        'ignore_client_bandwidth': False,
        'tls': {'enabled': True, 'alpn': ['h3'], 'certificate_path': cert, 'key_path': key}
    })

if tuic_port > 0:
    t = f'tuic-{group_tag}-in'
    inbound_tags.append(t)
    inbounds.append({
        'type': 'tuic', 'tag': t,
        'listen': '::', 'listen_port': tuic_port,
        'users': [{'uuid': uuid, 'password': uuid}],
        'congestion_control': 'bbr',
        'tls': {'enabled': True, 'alpn': ['h3'], 'certificate_path': cert, 'key_path': key}
    })

if vless_port > 0:
    t = f'vless-{group_tag}-in'
    inbound_tags.append(t)
    reality_pvk = ""
    reym = "apple.com"
    try:
        with open(f'{workdir}/private_key.txt', 'r') as f: reality_pvk = f.read().strip()
        with open(f'{workdir}/reym.txt', 'r') as f: reym = f.read().strip()
    except: pass
    inbounds.append({
        'type': 'vless', 'tag': t,
        'listen': '::', 'listen_port': vless_port,
        'users': [{'uuid': uuid, 'flow': 'xtls-rprx-vision'}],
        'tls': {
            'enabled': True, 'server_name': reym,
            'reality': {'enabled': True, 'handshake': {'server': reym, 'server_port': 443},
                        'private_key': reality_pvk, 'short_id': ['']}
        }
    })

# 3. 更新路由规则：在最前插入专属规则，确保副节点无论何时都走自己的外部代理出口
rules[:] = [r for r in rules if r.get('outbound') != out_tag]
if inbound_tags:
    rules.insert(0, {'inbound': inbound_tags, 'outbound': out_tag})

try:
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
except Exception as e:
    sys.exit(1)
PY_SYNC_PROXY
    return $?
}

# ==================== 同步赛风副节点到 sing-box ====================
sync_psiphon_instance_to_singbox() {
    local cc="${1^^}"
    local inst_dir="${PSI_INSTANCES_DIR}/${cc}"
    local cfg="$WORKDIR/sb.json"

    [[ -f "$cfg" ]] || return 1
    [[ -d "$inst_dir" ]] || return 1

    local hy2_port tuic_port vless_port socks_port uuid
    hy2_port=$(cat "$inst_dir/hy2_port.txt" 2>/dev/null || echo "0")
    tuic_port=$(cat "$inst_dir/tuic_port.txt" 2>/dev/null || echo "0")
    vless_port=$(cat "$inst_dir/vless_port.txt" 2>/dev/null || echo "0")
    socks_port=$(cat "$inst_dir/socks_port.txt" 2>/dev/null || echo "0")
    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || cat "$WORKDIR/uuid.txt" 2>/dev/null)
    local out_tag="psiphon-${cc,,}"

    python3 - \
        "$cfg" \
        "$cc" \
        "$out_tag" \
        "${socks_port:-0}" \
        "${hy2_port:-0}" \
        "${tuic_port:-0}" \
        "${vless_port:-0}" \
        "$uuid" \
        "$WORKDIR" <<'PY_SYNC_PSI'
import json, sys

cfg_path    = sys.argv[1]
cc          = sys.argv[2].lower()
out_tag     = sys.argv[3]
socks_port  = int(sys.argv[4]) if sys.argv[4] else 0
hy2_port    = int(sys.argv[5]) if sys.argv[5] else 0
tuic_port   = int(sys.argv[6]) if sys.argv[6] else 0
vless_port  = int(sys.argv[7]) if sys.argv[7] else 0
uuid        = sys.argv[8]
workdir     = sys.argv[9]

try:
    with open(cfg_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception as e:
    sys.exit(1)

inbounds  = data.setdefault('inbounds',  [])
outbounds = data.setdefault('outbounds', [])
route     = data.setdefault('route',     {})
rules     = route.setdefault('rules',    [])

# 1. 更新 outbound
outbounds[:] = [o for o in outbounds if o.get('tag') != out_tag]
if socks_port > 0:
    outbounds.append({
        'type': 'socks',
        'tag': out_tag,
        'server': '127.0.0.1',
        'server_port': socks_port,
        'version': '5',
        'network': 'tcp'
    })

# 2. 移除旧专属 inbound
def is_mine(ib):
    t = ib.get('tag', '')
    return t == f'hy2-psi-{cc}-in' or t == f'tuic-psi-{cc}-in' or t == f'vless-psi-{cc}-in'

inbounds[:] = [ib for ib in inbounds if not is_mine(ib)]

cert = f'{workdir}/cert.pem'
key  = f'{workdir}/private.key'
inbound_tags = []

if hy2_port > 0:
    t = f'hy2-psi-{cc}-in'
    inbound_tags.append(t)
    inbounds.append({
        'type': 'hysteria2', 'tag': t,
        'listen': '::', 'listen_port': hy2_port,
        'users': [{'password': uuid}],
        'masquerade': 'https://www.bing.com',
        'ignore_client_bandwidth': False,
        'tls': {'enabled': True, 'alpn': ['h3'], 'certificate_path': cert, 'key_path': key}
    })

if tuic_port > 0:
    t = f'tuic-psi-{cc}-in'
    inbound_tags.append(t)
    inbounds.append({
        'type': 'tuic', 'tag': t,
        'listen': '::', 'listen_port': tuic_port,
        'users': [{'uuid': uuid, 'password': uuid}],
        'congestion_control': 'bbr',
        'tls': {'enabled': True, 'alpn': ['h3'], 'certificate_path': cert, 'key_path': key}
    })

if vless_port > 0:
    t = f'vless-psi-{cc}-in'
    inbound_tags.append(t)
    reality_pvk = ""
    reym = "apple.com"
    try:
        with open(f'{workdir}/private_key.txt', 'r') as f: reality_pvk = f.read().strip()
        with open(f'{workdir}/reym.txt', 'r') as f: reym = f.read().strip()
    except: pass
    inbounds.append({
        'type': 'vless', 'tag': t,
        'listen': '::', 'listen_port': vless_port,
        'users': [{'uuid': uuid, 'flow': 'xtls-rprx-vision'}],
        'tls': {
            'enabled': True, 'server_name': reym,
            'reality': {'enabled': True, 'handshake': {'server': reym, 'server_port': 443},
                        'private_key': reality_pvk, 'short_id': ['']}
        }
    })

# 3. 插入专属路由规则到最前
rules[:] = [r for r in rules if r.get('outbound') != out_tag]
if inbound_tags and socks_port > 0:
    rules.insert(0, {'inbound': inbound_tags, 'outbound': out_tag})

try:
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
except Exception as e:
    sys.exit(1)
PY_SYNC_PSI
    return $?
}

# ==================== 副节点全面自动同步函数 ====================
sync_all_secondary_nodes() {
    local cfg="$WORKDIR/sb.json"
    [[ -f "$cfg" ]] || return 0

    # 1. 恢复同步所有赛风副节点实例
    local psi_insts
    mapfile -t psi_insts < <(get_all_psiphon_instances 2>/dev/null)
    for cc in "${psi_insts[@]}"; do
        [[ -n "$cc" ]] && sync_psiphon_instance_to_singbox "$cc" >/dev/null 2>&1 || true
    done

    # 2. 恢复同步所有自定义代理副节点组
    local proxy_tags
    mapfile -t proxy_tags < <(get_all_proxy_groups 2>/dev/null)
    for tag in "${proxy_tags[@]}"; do
        [[ -n "$tag" ]] && sync_proxy_group_to_singbox "$tag" >/dev/null 2>&1 || true
    done
}

# ==================== 主节点出站应用函数 ====================
apply_main_node_outbound() {
    local cfg="$WORKDIR/sb.json"
    [[ -f "$cfg" ]] || return 1

    local warp_enabled warp_mode warp_endpoint warp_port warp_pvk warp_ipv6 warp_res
    warp_enabled=$(cat "$WORKDIR/warp_enabled.txt" 2>/dev/null || echo "false")
    warp_mode=$(cat "$WORKDIR/warp_mode.txt" 2>/dev/null || echo "all")
    warp_endpoint=$(get_warp_endpoint)
    warp_port=$(cat "$WORKDIR/warp_best_port.txt" 2>/dev/null || echo "2408")
    warp_pvk=$(cat "$WORKDIR/warp_private_key.txt" 2>/dev/null || echo "52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A=")
    warp_ipv6=$(cat "$WORKDIR/warp_ipv6.txt" 2>/dev/null || echo "2606:4700:110:8d8d:1845:c39f:2dd5:a03a")
    warp_res=$(cat "$WORKDIR/warp_reserved.txt" 2>/dev/null || echo "[215, 69, 233]")

    local psi_main_enabled psi_main_port
    psi_main_enabled=$(cat "$WORKDIR/psiphon_main_enabled.txt" 2>/dev/null || echo "false")
    psi_main_port=$(cat "$WORKDIR/psiphon_socks_port.txt" 2>/dev/null || echo "20800")

    python3 - \
        "$cfg" \
        "$warp_enabled" \
        "$warp_mode" \
        "$warp_endpoint" \
        "$warp_port" \
        "$warp_pvk" \
        "$warp_ipv6" \
        "$warp_res" \
        "$psi_main_enabled" \
        "$psi_main_port" <<'PY_APPLY_MAIN'
import json, sys

cfg_path         = sys.argv[1]
warp_enabled     = sys.argv[2].lower() == 'true'
warp_mode        = sys.argv[3]
warp_endpoint    = sys.argv[4]
warp_port        = int(sys.argv[5]) if sys.argv[5] else 2408
warp_pvk         = sys.argv[6]
warp_ipv6        = sys.argv[7]
warp_res_raw     = sys.argv[8]
psi_main_enabled = sys.argv[9].lower() == 'true'
psi_main_port    = int(sys.argv[10]) if sys.argv[10] else 20800

try:
    warp_res = json.loads(warp_res_raw)
except:
    warp_res = [215, 69, 233]

try:
    with open(cfg_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception as e:
    sys.exit(1)

outbounds = data.setdefault('outbounds', [])
route     = data.setdefault('route', {})
rules     = route.setdefault('rules', [])

# 确保 direct 与 block 出站存在
if not any(o.get('tag') == 'direct' for o in outbounds):
    outbounds.append({'type': 'direct', 'tag': 'direct'})
if not any(o.get('tag') == 'block' for o in outbounds):
    outbounds.append({'type': 'block', 'tag': 'block'})

# 清理旧的主出站对象
outbounds[:] = [o for o in outbounds if o.get('tag') not in ('warp-out', 'psiphon-main-out')]

# 清理旧的主分流规则 (保留副节点的规则)
def is_main_rule(r):
    out = r.get('outbound', '')
    if out in ('warp-out', 'psiphon-main-out'):
        # 如果是 loopback 测试规则或 geosite 分流规则
        inb = r.get('inbound', [])
        if inb == ['socks-loopback'] or 'geosite' in r or 'domain_suffix' in r:
            return True
    return False

rules[:] = [r for r in rules if not is_main_rule(r)]

# 根据主节点出站模式配置
if warp_enabled and warp_mode == 'all':
    # 1. WARP 全局出站
    outbounds.append({
        'type': 'wireguard',
        'tag': 'warp-out',
        'server': warp_endpoint,
        'server_port': warp_port,
        'local_address': ['172.16.0.2/32', f'{warp_ipv6}/128'],
        'private_key': warp_pvk,
        'peer_public_key': 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=',
        'reserved': warp_res
    })
    rules.append({'inbound': ['socks-loopback'], 'outbound': 'warp-out'})
    route['final'] = 'warp-out'

elif warp_enabled and warp_mode == 'google':
    # 2. WARP 分流出站
    outbounds.append({
        'type': 'wireguard',
        'tag': 'warp-out',
        'server': warp_endpoint,
        'server_port': warp_port,
        'local_address': ['172.16.0.2/32', f'{warp_ipv6}/128'],
        'private_key': warp_pvk,
        'peer_public_key': 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=',
        'reserved': warp_res
    })
    rules.append({'inbound': ['socks-loopback'], 'outbound': 'warp-out'})
    rules.append({
        'geosite': ['google', 'youtube', 'netflix', 'openai'],
        'domain_suffix': ['google.com', 'googlevideo.com', 'youtube.com', 'netflix.com', 'openai.com', 'chatgpt.com'],
        'outbound': 'warp-out'
    })
    route['final'] = 'direct'

elif psi_main_enabled:
    # 3. 赛风出站
    outbounds.append({
        'type': 'socks',
        'tag': 'psiphon-main-out',
        'server': '127.0.0.1',
        'server_port': psi_main_port,
        'version': '5',
        'network': 'tcp'
    })
    rules.append({'inbound': ['socks-loopback'], 'outbound': 'psiphon-main-out'})
    route['final'] = 'psiphon-main-out'

else:
    # 4. 原生直连出站
    rules.append({'inbound': ['socks-loopback'], 'outbound': 'direct'})
    route['final'] = 'direct'

try:
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
except Exception as e:
    sys.exit(1)
PY_APPLY_MAIN

    # 关键：无论主节点出站怎么变，重新把副节点完整挂回最前，确保副节点绝不受干扰！
    sync_all_secondary_nodes
    return 0
}

# 校验并应用配置重启
apply_changes() {
    if [[ ! -f /etc/s-box/sb.json ]]; then
        log_err "配置文件不存在！"
        return 1
    fi
    if [[ -x /etc/s-box/sing-box ]]; then
        if ! /etc/s-box/sing-box check -c /etc/s-box/sb.json >/dev/null 2>&1; then
            log_err "Sing-box 配置文件格式或语法检查未通过！"
            return 1
        fi
    fi
    service_restart sing-box
    return 0
}

# ==================== 1. 主节点出站管理子菜单 ====================
configure_warp_outbound() {
    clear
    echo
    green "============================================================"
    green "  主节点出站管理 (直连出站 / WARP 出站 / 赛风出站)"
    green "============================================================"
    yellow "  说明: 本设置仅作用于【主节点】入站流量"
    yellow "        副节点(自定义代理出站、赛风出站)为独立平行系统，不受影响"
    echo "============================================================"
    
    if [ ! -f "$WORKDIR/sb.json" ]; then
        red "未检测到已安装的 Sing-box 配置，请先安装主节点"
        reading "按回车返回..." _
        return 1
    fi

    local current_status current_mode current_psi
    current_status=$(cat "$WORKDIR/warp_enabled.txt" 2>/dev/null || echo "false")
    current_mode=$(cat "$WORKDIR/warp_mode.txt" 2>/dev/null || echo "all")
    current_psi=$(cat "$WORKDIR/psiphon_main_enabled.txt" 2>/dev/null || echo "false")

    echo
    purple "当前主节点出站状态:"
    if [[ "$current_status" == "true" ]]; then
        if [[ "$current_mode" == "all" ]]; then
            blue "  主节点出站模式: ✓ WARP 全局出站 (全部主节点流量走 WARP)"
        else
            blue "  主节点出站模式: ✓ WARP 分流出站 (Google/YouTube/Netflix/OpenAI 走 WARP)"
        fi
        local ep=$(get_warp_endpoint)
        green "  WARP Endpoint: $ep"
    elif [[ "$current_psi" == "true" ]]; then
        blue "  主节点出站模式: ✓ 赛风出站 (全部主节点流量走本地 Psiphon)"
    else
        green "  主节点出站模式: ✓ 直连出站 (Direct 原生网络直连)"
    fi

    echo
    echo "------------------------------------------------------------"
    yellow "  0. 主节点 - 直连出站 (Direct, 恢复原生直连)"
    yellow "  1. 主节点 - WARP 全局出站 (全部主节点流量走 WARP)"
    yellow "  2. 主节点 - WARP 分流出站 (仅 Google/YouTube/Netflix/OpenAI)"
    yellow "  3. 主节点 - 赛风出站 (主节点流量走本地 Psiphon 核心)"
    echo "------------------------------------------------------------"
    green  "  4. 优选 WARP Endpoint IP (优化连接质量与延迟)"
    blue   "  5. 恢复 Cloudflare 默认 Endpoint"
    blue   "  6. 重新获取勇哥 WARP API 配置凭证"
    green  "  7. 检测主节点当前出口 IP"
    echo "------------------------------------------------------------"
    red    "  q. 返回主菜单"
    echo "============================================================"
    reading "请选择 [0-7, q]: " new_choice

    case "$new_choice" in
        0)
            echo "false" > "$WORKDIR/warp_enabled.txt"
            echo "false" > "$WORKDIR/psiphon_main_enabled.txt"
            stop_main_psiphon
            apply_main_node_outbound
            apply_changes
            green "已切换为主节点: 直连出站 (Direct)"
            ;;
        1)
            init_warp_config
            echo "true" > "$WORKDIR/warp_enabled.txt"
            echo "all" > "$WORKDIR/warp_mode.txt"
            echo "false" > "$WORKDIR/psiphon_main_enabled.txt"
            stop_main_psiphon
            apply_main_node_outbound
            apply_changes
            green "已切换为主节点: WARP 全局出站 (全部流量走 WARP)"
            ;;
        2)
            init_warp_config
            echo "true" > "$WORKDIR/warp_enabled.txt"
            echo "google" > "$WORKDIR/warp_mode.txt"
            echo "false" > "$WORKDIR/psiphon_main_enabled.txt"
            stop_main_psiphon
            apply_main_node_outbound
            apply_changes
            green "已切换为主节点: WARP 分流出站 (流媒体/AI 走 WARP)"
            ;;
        3)
            echo "false" > "$WORKDIR/warp_enabled.txt"
            echo "true" > "$WORKDIR/psiphon_main_enabled.txt"
            start_main_psiphon
            apply_main_node_outbound
            apply_changes
            green "已切换为主节点: 赛风出站 (Psiphon)"
            ;;
        4)
            yellow "正在测试最优 WARP Endpoint..."
            local best_ep="162.159.192.1"
            # 候选 IP 测试
            local candidates=("162.159.192.1" "162.159.193.10" "162.159.195.2" "188.114.96.1" "188.114.97.1")
            for ep in "${candidates[@]}"; do
                if ping -c 1 -W 1 "$ep" >/dev/null 2>&1; then
                    best_ep="$ep"
                    break
                fi
            done
            echo "$best_ep" > "$WORKDIR/warp_best_endpoint.txt"
            echo "2408" > "$WORKDIR/warp_best_port.txt"
            apply_main_node_outbound
            apply_changes
            green "已设置优选 Endpoint: ${best_ep}:2408"
            ;;
        5)
            echo "162.159.192.1" > "$WORKDIR/warp_best_endpoint.txt"
            echo "2408" > "$WORKDIR/warp_best_port.txt"
            apply_main_node_outbound
            apply_changes
            green "已恢复 Cloudflare 默认 Endpoint (162.159.192.1:2408)"
            ;;
        6)
            yellow "正在重新获取 WARP 凭据..."
            init_warp_config
            apply_main_node_outbound
            apply_changes
            green "WARP 凭据已刷新！"
            ;;
        7)
            warp_egress_test
            ;;
        q|Q|"")
            return 0
            ;;
        *)
            red "无效输入"
            ;;
    esac
    echo
    reading "按回车继续..." _
}

# ==================== 2. 副节点 - 自定义代理出站管理 ====================
add_proxy_egress_group() {
    init_proxy_groups_dir
    echo
    green "==== 添加自定义代理出站节点组 (副节点) ===="
    yellow "支持外部链接: vless://, vmess://, trojan://, hy2://, tuic://, ss://"
    echo
    reading "请输入分组备注名称 (如 香港BGP、美国VPS等): " remark
    [[ -z "$remark" ]] && remark="外部代理-$(date +%s)"

    reading "请粘贴代理节点链接: " proxy_url
    proxy_url=$(echo "$proxy_url" | tr -d ' \r\n')
    [[ -z "$proxy_url" ]] && { red "[!] 链接不能为空"; return 1; }

    local group_tag="proxy-$(( $(get_all_proxy_groups | wc -l) + 1 ))"
    while proxy_group_exists "$group_tag"; do
        group_tag="proxy-$((RANDOM % 1000 + 1))"
    done
    local out_tag="${group_tag}-out"

    yellow "[*] 正在解析代理链接..."
    local out_json
    out_json=$(validate_and_parse_proxy_url "$proxy_url" "$out_tag")
    if [[ $? -ne 0 || -z "$out_json" ]]; then
        red "[!] 解析失败，请检查链接格式！"
        return 1
    fi

    # 选择本地副节点入站协议
    echo
    purple "请选择为该代理出口搭建的本地入站协议 (支持多选或默认):"
    echo "  1. Hysteria2 入站 (UDP高加速)"
    echo "  2. TUIC v5 入站 (QUIC高性能)"
    echo "  3. VLESS-Reality 入站 (TCP抗封锁)"
    echo "  4. 同时开启 Hy2 + TUIC"
    reading "请选择 [1-4, 默认4]: " proto_sel
    [[ -z "$proto_sel" ]] && proto_sel="4"

    local hy2_p="0" tuic_p="0" vless_p="0"
    case "$proto_sel" in
        1) hy2_p=$(get_free_port) ;;
        2) tuic_p=$(get_free_port) ;;
        3) vless_p=$(get_free_port) ;;
        *) hy2_p=$(get_free_port); tuic_p=$(get_free_port) ;;
    esac

    # 保存副节点目录
    local gdir="${PROXY_GROUPS_DIR}/${group_tag}"
    mkdir -p "$gdir"
    echo "$remark" > "$gdir/remark.txt"
    echo "$proxy_url" > "$gdir/raw_url.txt"
    echo "$out_json" > "$gdir/outbound.json"
    echo "$hy2_p" > "$gdir/hy2_port.txt"
    echo "$tuic_p" > "$gdir/tuic_port.txt"
    echo "$vless_p" > "$gdir/vless_port.txt"
    echo "$group_tag" >> "$PROXY_GROUPS_DIR/groups.txt"

    # 同步并应用
    sync_proxy_group_to_singbox "$group_tag"
    apply_changes

    green "[✓] 代理节点组 [$remark] 添加成功！"
    generate_proxy_group_links "$group_tag"
}

generate_proxy_group_links() {
    local tag="$1"
    local gdir="${PROXY_GROUPS_DIR}/${tag}"
    [[ -d "$gdir" ]] || return 1

    local remark hy2_p tuic_p vless_p uuid ip
    remark=$(cat "$gdir/remark.txt" 2>/dev/null || echo "$tag")
    hy2_p=$(cat "$gdir/hy2_port.txt" 2>/dev/null || echo "0")
    tuic_p=$(cat "$gdir/tuic_port.txt" 2>/dev/null || echo "0")
    vless_p=$(cat "$gdir/vless_port.txt" 2>/dev/null || echo "0")
    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || cat "$WORKDIR/uuid.txt" 2>/dev/null)
    ip="${ALL_IPS[0]:-127.0.0.1}"

    echo
    blue "============================================================"
    blue "  【副节点-代理出站】: $remark (标识: $tag)"
    blue "============================================================"
    if [[ "$hy2_p" -gt 0 ]]; then
        local hy2_link="hysteria2://${uuid}@${ip}:${hy2_p}?insecure=1&sni=www.bing.com#${remark}-Hy2"
        green "1. Hysteria2 节点链接:"
        echo "   $hy2_link"
    fi
    if [[ "$tuic_p" -gt 0 ]]; then
        local tuic_link="tuic://${uuid}:${uuid}@${ip}:${tuic_p}?alpn=h3&congestion_control=bbr&udp_relay=1&allow_insecure=1#${remark}-TUIC"
        green "2. TUIC v5 节点链接:"
        echo "   $tuic_link"
    fi
    if [[ "$vless_p" -gt 0 ]]; then
        local pbk=$(cat "$WORKDIR/public_key.txt" 2>/dev/null)
        local reym=$(cat "$WORKDIR/reym.txt" 2>/dev/null || echo "apple.com")
        local vless_link="vless://${uuid}@${ip}:${vless_p}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reym}&fp=chrome&pbk=${pbk}&sid=#${remark}-Reality"
        green "3. VLESS-Reality 节点链接:"
        echo "   $vless_link"
    fi
    blue "============================================================"
}

proxy_egress_menu() {
    while true; do
        clear
        echo
        green "============================================================"
        green "  【副节点】自定义代理出站多出口路由管理"
        green "============================================================"
        yellow "  说明: 副节点拥有独立入站端口与专属路由，出站直接转发至外部代理"
        yellow "        与主节点(直连/WARP/赛风)完全平行独立，互不干扰"
        green "============================================================"
        echo

        local groups
        mapfile -t groups < <(get_all_proxy_groups)

        purple "当前代理节点组 (共 ${#groups[@]} 个):"
        if [[ ${#groups[@]} -gt 0 ]]; then
            local idx=1
            for t in "${groups[@]}"; do
                local r=$(cat "${PROXY_GROUPS_DIR}/$t/remark.txt" 2>/dev/null || echo "$t")
                local hp=$(cat "${PROXY_GROUPS_DIR}/$t/hy2_port.txt" 2>/dev/null || echo "0")
                local tp=$(cat "${PROXY_GROUPS_DIR}/$t/tuic_port.txt" 2>/dev/null || echo "0")
                local vp=$(cat "${PROXY_GROUPS_DIR}/$t/vless_port.txt" 2>/dev/null || echo "0")
                local p_info=""
                [[ "$hp" -gt 0 ]] && p_info="${p_info}Hy2:$hp "
                [[ "$tp" -gt 0 ]] && p_info="${p_info}TUIC:$tp "
                [[ "$vp" -gt 0 ]] && p_info="${p_info}VLESS:$vp "
                green "  [$idx] [$t] $r  ->  入站端口: [ ${p_info:-无} ]"
                ((idx++))
            done
        else
            yellow "  暂无代理节点组"
        fi

        echo
        echo "------------------------------------------------------------"
        green  "  1. 添加新代理节点组 (导入外部代理链接)"
        green  "  2. 查看所有代理组节点链接"
        yellow "  3. 修改代理组出站链接"
        red    "  4. 删除代理节点组"
        blue   "  5. 重新同步全部代理配置并重启"
        echo "------------------------------------------------------------"
        red    "  0. 返回主菜单"
        echo "============================================================"
        reading "请选择 [0-5]: " choice
        case "$choice" in
            1) add_proxy_egress_group ;;
            2)
                for t in "${groups[@]}"; do generate_proxy_group_links "$t"; done
                ;;
            3)
                if [[ ${#groups[@]} -eq 0 ]]; then
                    yellow "暂无代理节点组"
                else
                    reading "请输入要修改的 tag (如 proxy-1): " edit_tag
                    if proxy_group_exists "$edit_tag"; then
                        reading "请粘贴新的代理链接: " new_url
                        new_url=$(echo "$new_url" | tr -d ' \r\n')
                        if [[ -n "$new_url" ]]; then
                            local out_json
                            out_json=$(validate_and_parse_proxy_url "$new_url" "${edit_tag}-out")
                            if [[ $? -eq 0 && -n "$out_json" ]]; then
                                echo "$new_url" > "${PROXY_GROUPS_DIR}/$edit_tag/raw_url.txt"
                                echo "$out_json" > "${PROXY_GROUPS_DIR}/$edit_tag/outbound.json"
                                sync_proxy_group_to_singbox "$edit_tag"
                                apply_changes
                                green "代理链接已更新并生效！"
                            fi
                        fi
                    fi
                fi
                ;;
            4)
                if [[ ${#groups[@]} -eq 0 ]]; then
                    yellow "暂无代理节点组"
                else
                    reading "请输入要删除的 tag (如 proxy-1): " del_tag
                    if proxy_group_exists "$del_tag"; then
                        rm -rf "${PROXY_GROUPS_DIR:?}/$del_tag"
                        sed -i "/^${del_tag}$/d" "$PROXY_GROUPS_DIR/groups.txt"
                        # 从 sb.json 中移除
                        python3 -c "
import json
with open('$WORKDIR/sb.json') as f: d=json.load(f)
d['outbounds']=[o for o in d.get('outbounds',[]) if o.get('tag')!='${del_tag}-out']
d['inbounds']=[i for i in d.get('inbounds',[]) if '${del_tag}' not in i.get('tag','')]
d.setdefault('route',{}).setdefault('rules',[])
d['route']['rules']=[r for r in d['route']['rules'] if r.get('outbound')!='${del_tag}-out']
with open('$WORKDIR/sb.json','w') as f: json.dump(d,f,indent=2)
"
                        apply_changes
                        green "已删除代理节点组: $del_tag"
                    fi
                fi
                ;;
            5)
                sync_all_secondary_nodes
                apply_changes
                green "已重新同步所有副节点！"
                ;;
            0) return 0 ;;
            *) red "无效选项" ;;
        esac
        echo
        reading "按回车继续..." _
    done
}

# ==================== 3. 副节点 - 赛风多出口管理 ====================
add_psiphon_instance() {
    install_psiphon_core || return 1
    init_psiphon_instances_dir
    echo
    green "==== 添加赛风国家出口组 (副节点) ===="
    show_supported_psiphon_codes
    echo
    reading "请输入国家代码 (如 US, JP, SG, HK, GB, DE 等): " cc
    cc="${cc^^}"
    [[ -z "$cc" ]] && { red "[!] 国家代码不能为空"; return 1; }

    local inst_dir="${PSI_INSTANCES_DIR}/${cc}"
    mkdir -p "$inst_dir"

    local socks_p=$(get_free_loopback_port)
    local cfg_file="$inst_dir/psiphon.config"
    write_psiphon_config "$socks_p" "$cc" "$cfg_file" "$inst_dir/data"

    # 启动专属实例
    nohup "$WORKDIR/psiphon-tunnel-core" --config "$cfg_file" >> "$inst_dir/psiphon.log" 2>&1 &
    echo $! > "$inst_dir/psiphon.pid"
    echo "$socks_p" > "$inst_dir/socks_port.txt"

    # 选择本地入站
    echo
    purple "请选择为该赛风出口搭建的本地入站协议:"
    echo "  1. Hysteria2 入站 (UDP高加速)"
    echo "  2. TUIC v5 入站 (QUIC高性能)"
    echo "  3. VLESS-Reality 入站"
    echo "  4. 同时开启 Hy2 + TUIC"
    reading "请选择 [1-4, 默认4]: " proto_sel
    [[ -z "$proto_sel" ]] && proto_sel="4"

    local hy2_p="0" tuic_p="0" vless_p="0"
    case "$proto_sel" in
        1) hy2_p=$(get_free_port) ;;
        2) tuic_p=$(get_free_port) ;;
        3) vless_p=$(get_free_port) ;;
        *) hy2_p=$(get_free_port); tuic_p=$(get_free_port) ;;
    esac

    echo "$hy2_p" > "$inst_dir/hy2_port.txt"
    echo "$tuic_p" > "$inst_dir/tuic_port.txt"
    echo "$vless_p" > "$inst_dir/vless_port.txt"
    echo "$cc" >> "$PSI_INSTANCES_DIR/instances.txt"

    sync_psiphon_instance_to_singbox "$cc"
    apply_changes

    green "[✓] 赛风国家出口组 [$cc - $(get_country_name "$cc")] 添加并启动成功！"
    generate_psiphon_instance_links "$cc"
}

generate_psiphon_instance_links() {
    local cc="${1^^}"
    local inst_dir="${PSI_INSTANCES_DIR}/${cc}"
    [[ -d "$inst_dir" ]] || return 1

    local hy2_p tuic_p vless_p uuid ip cname
    hy2_p=$(cat "$inst_dir/hy2_port.txt" 2>/dev/null || echo "0")
    tuic_p=$(cat "$inst_dir/tuic_port.txt" 2>/dev/null || echo "0")
    vless_p=$(cat "$inst_dir/vless_port.txt" 2>/dev/null || echo "0")
    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || cat "$WORKDIR/uuid.txt" 2>/dev/null)
    ip="${ALL_IPS[0]:-127.0.0.1}"
    cname=$(get_country_name "$cc")

    echo
    purple "============================================================"
    purple "  【副节点-赛风出口】: $cc ($cname)"
    purple "============================================================"
    if [[ "$hy2_p" -gt 0 ]]; then
        local hy2_link="hysteria2://${uuid}@${ip}:${hy2_p}?insecure=1&sni=www.bing.com#Psi-${cc}-Hy2"
        green "1. Hysteria2 节点链接:"
        echo "   $hy2_link"
    fi
    if [[ "$tuic_p" -gt 0 ]]; then
        local tuic_link="tuic://${uuid}:${uuid}@${ip}:${tuic_p}?alpn=h3&congestion_control=bbr&udp_relay=1&allow_insecure=1#Psi-${cc}-TUIC"
        green "2. TUIC v5 节点链接:"
        echo "   $tuic_link"
    fi
    if [[ "$vless_p" -gt 0 ]]; then
        local pbk=$(cat "$WORKDIR/public_key.txt" 2>/dev/null)
        local reym=$(cat "$WORKDIR/reym.txt" 2>/dev/null || echo "apple.com")
        local vless_link="vless://${uuid}@${ip}:${vless_p}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reym}&fp=chrome&pbk=${pbk}&sid=#Psi-${cc}-Reality"
        green "3. VLESS-Reality 节点链接:"
        echo "   $vless_link"
    fi
    purple "============================================================"
}

psiphon_management_menu() {
    while true; do
        clear
        echo
        green "============================================================"
        green "  【副节点】Psiphon 赛风出站多出口管理"
        green "============================================================"
        yellow "  说明: 副节点拥有独立入站端口与专属路由，出站走赛风对应国家"
        yellow "        与主节点完全平行独立，互不干扰"
        green "============================================================"
        echo

        local insts
        mapfile -t insts < <(get_all_psiphon_instances)

        purple "当前赛风出口组 (共 ${#insts[@]} 个):"
        if [[ ${#insts[@]} -gt 0 ]]; then
            local idx=1
            for cc in "${insts[@]}"; do
                local cname=$(get_country_name "$cc")
                local hp=$(cat "${PSI_INSTANCES_DIR}/$cc/hy2_port.txt" 2>/dev/null || echo "0")
                local tp=$(cat "${PSI_INSTANCES_DIR}/$cc/tuic_port.txt" 2>/dev/null || echo "0")
                local vp=$(cat "${PSI_INSTANCES_DIR}/$cc/vless_port.txt" 2>/dev/null || echo "0")
                local p_info=""
                [[ "$hp" -gt 0 ]] && p_info="${p_info}Hy2:$hp "
                [[ "$tp" -gt 0 ]] && p_info="${p_info}TUIC:$tp "
                [[ "$vp" -gt 0 ]] && p_info="${p_info}VLESS:$vp "
                green "  [$idx] [$cc] $cname  ->  入站端口: [ ${p_info:-无} ]"
                ((idx++))
            done
        else
            yellow "  暂无赛风出口组"
        fi

        echo
        echo "------------------------------------------------------------"
        green  "  1. 添加赛风国家出口组"
        green  "  2. 查看所有赛风出口组节点链接"
        red    "  3. 删除赛风国家出口组"
        blue   "  4. 重启所有赛风实例"
        echo "------------------------------------------------------------"
        red    "  0. 返回主菜单"
        echo "============================================================"
        reading "请选择 [0-4]: " choice

        case "$choice" in
            1) add_psiphon_instance ;;
            2)
                for cc in "${insts[@]}"; do generate_psiphon_instance_links "$cc"; done
                ;;
            3)
                if [[ ${#insts[@]} -eq 0 ]]; then
                    yellow "暂无赛风出口组"
                else
                    reading "请输入要删除的国家码 (如 US): " del_cc
                    del_cc="${del_cc^^}"
                    if [[ -d "${PSI_INSTANCES_DIR}/$del_cc" ]]; then
                        local pid=$(cat "${PSI_INSTANCES_DIR}/$del_cc/psiphon.pid" 2>/dev/null)
                        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
                        rm -rf "${PSI_INSTANCES_DIR:?}/$del_cc"
                        sed -i "/^${del_cc}$/d" "$PSI_INSTANCES_DIR/instances.txt"
                        # 从 sb.json 中移除
                        python3 -c "
import json
with open('$WORKDIR/sb.json') as f: d=json.load(f)
d['outbounds']=[o for o in d.get('outbounds',[]) if o.get('tag')!='psiphon-${del_cc,,}']
d['inbounds']=[i for i in d.get('inbounds',[]) if '${del_cc,,}' not in i.get('tag','')]
d.setdefault('route',{}).setdefault('rules',[])
d['route']['rules']=[r for r in d['route']['rules'] if r.get('outbound')!='psiphon-${del_cc,,}']
with open('$WORKDIR/sb.json','w') as f: json.dump(d,f,indent=2)
"
                        apply_changes
                        green "已删除赛风出口组: $del_cc"
                    fi
                fi
                ;;
            4)
                yellow "正在重启所有赛风实例..."
                for cc in "${insts[@]}"; do
                    local idir="${PSI_INSTANCES_DIR}/$cc"
                    local pid=$(cat "$idir/psiphon.pid" 2>/dev/null)
                    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
                    nohup "$WORKDIR/psiphon-tunnel-core" --config "$idir/psiphon.config" >> "$idir/psiphon.log" 2>&1 &
                    echo $! > "$idir/psiphon.pid"
                done
                green "赛风实例已重启！"
                ;;
            0) return 0 ;;
            *) red "无效选项" ;;
        esac
        echo
        reading "按回车继续..." _
    done
}

# ==================== 4. 查看主节点信息与全部汇总 ====================
show_links() {
    if [[ -f /etc/s-box/info.log ]]; then
        cat /etc/s-box/info.log
    else
        yellow "未找到 /etc/s-box/info.log，正在尝试重新生成..."
        # 直接输出主节点信息
        local uuid ip pbk sid reym
        uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || cat "$WORKDIR/uuid.txt" 2>/dev/null)
        ip="${ALL_IPS[0]:-127.0.0.1}"
        pbk=$(cat "$WORKDIR/public_key.txt" 2>/dev/null)
        sid=$(cat "$WORKDIR/short_id.txt" 2>/dev/null)
        reym=$(cat "$WORKDIR/reym.txt" 2>/dev/null || echo "apple.com")

        green "=================================================="
        green "         Sing-box 主节点信息"
        green "=================================================="
        echo "UUID / Password: $uuid"
        echo
        local vless_p=$(jq -r '.inbounds[] | select(.tag=="vless-reality-in") | .listen_port' "$WORKDIR/sb.json" 2>/dev/null)
        local vmess_p=$(jq -r '.inbounds[] | select(.tag=="vmess-ws-in") | .listen_port' "$WORKDIR/sb.json" 2>/dev/null)
        local trojan_p=$(jq -r '.inbounds[] | select(.tag=="trojan-ws-in") | .listen_port' "$WORKDIR/sb.json" 2>/dev/null)
        local hy2_p=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .listen_port' "$WORKDIR/sb.json" 2>/dev/null)
        local tuic_p=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .listen_port' "$WORKDIR/sb.json" 2>/dev/null)

        [[ -n "$vless_p" && "$vless_p" != "null" ]] && echo "1. VLESS-Reality: vless://${uuid}@${ip}:${vless_p}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reym}&fp=chrome&pbk=${pbk}&sid=${sid}#SB-VLESS-Reality"
        [[ -n "$vmess_p" && "$vmess_p" != "null" ]] && echo "2. VMess-WS: $(make_vmess_link "{\"v\":\"2\",\"ps\":\"SB-VMess\",\"add\":\"${ip}\",\"port\":\"${vmess_p}\",\"id\":\"${uuid}\",\"net\":\"ws\",\"path\":\"/${uuid}-vm\"}")"
        [[ -n "$trojan_p" && "$trojan_p" != "null" ]] && echo "3. Trojan-WS-TLS: trojan://${uuid}@${ip}:${trojan_p}?security=tls&sni=www.bing.com&allowInsecure=1&type=ws&path=%2F${uuid}-tr#SB-Trojan-TLS"
        [[ -n "$hy2_p" && "$hy2_p" != "null" ]] && echo "4. Hysteria2: hysteria2://${uuid}@${ip}:${hy2_p}?insecure=1&sni=www.bing.com#SB-Hysteria2"
        [[ -n "$tuic_p" && "$tuic_p" != "null" ]] && echo "5. TUIC v5: tuic://${uuid}:${uuid}@${ip}:${tuic_p}?alpn=h3&congestion_control=bbr&udp_relay=1&allow_insecure=1#SB-TUIC-v5"
        green "=================================================="
    fi
}

show_all_nodes_summary() {
    clear
    echo
    green "============================================================"
    green "  全部节点信息总览 (主节点与副节点分类汇总)"
    green "============================================================"
    echo
    purple "【一、主节点列表 (多协议主节点群)】"
    show_links
    echo
    purple "【二、副节点 - 赛风出站多出口节点组】"
    local psi_insts
    mapfile -t psi_insts < <(get_all_psiphon_instances 2>/dev/null)
    if [[ ${#psi_insts[@]} -gt 0 ]]; then
        for cc in "${psi_insts[@]}"; do
            generate_psiphon_instance_links "$cc"
        done
    else
        yellow "  (当前未配置赛风副节点出口组)"
    fi
    echo
    purple "【三、副节点 - 自定义代理出站多出口节点组】"
    local proxy_tags
    mapfile -t proxy_tags < <(get_all_proxy_groups 2>/dev/null)
    if [[ ${#proxy_tags[@]} -gt 0 ]]; then
        for tag in "${proxy_tags[@]}"; do
            generate_proxy_group_links "$tag"
        done
    else
        yellow "  (当前未配置自定义代理副节点组)"
    fi
    echo
    green "============================================================"
}

# ==================== 5. 自定义节点组合推送 ====================
custom_push_nodes() {
    clear
    echo
    green "============================================================"
    green "  自定义节点组合推送 (聚合订阅生成)"
    green "============================================================"
    echo
    yellow "正在聚合所有可用主节点与副节点分享链接..."
    echo
    show_all_nodes_summary
}

# ==================== 6. Argo 隧道管理 ====================
argo_management_menu() {
    while true; do
        clear
        echo
        green "============================================================"
        green "  主节点 Argo 隧道管理 (Cloudflare Tunnel)"
        green "============================================================"
        echo
        if service_is_active argo-tunnel; then
            green "【Argo 状态】: ✓ 运行中"
            local argo_d
            argo_d=$(cat /etc/s-box/argo.log 2>/dev/null || cat /var/log/argo-tunnel.log 2>/dev/null | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -n 1)
            [[ -n "$argo_d" ]] && blue "当前域名: $argo_d"
        else
            yellow "【Argo 状态】: ✗ 未运行"
        fi
        echo
        echo "------------------------------------------------------------"
        green  "  1. 启动 / 重启 Argo 隧道"
        red    "  2. 停止 Argo 隧道"
        blue   "  3. 查看 Argo 实时日志与域名"
        yellow "  4. 重置/重新抓取临时域名"
        echo "------------------------------------------------------------"
        red    "  0. 返回主菜单"
        echo "============================================================"
        reading "请选择 [0-4]: " choice

        case "$choice" in
            1)
                service_restart argo-tunnel
                green "Argo 隧道已重启！"
                ;;
            2)
                service_stop argo-tunnel
                green "Argo 隧道已停止！"
                ;;
            3)
                echo
                green "========== Argo 日志 (最近 20 行) =========="
                tail -n 20 /var/log/argo-tunnel.log 2>/dev/null || journalctl -u argo-tunnel -n 20 --no-pager 2>/dev/null || yellow "暂无日志"
                echo "============================================"
                ;;
            4)
                service_restart argo-tunnel
                sleep 4
                local new_d
                new_d=$(cat /var/log/argo-tunnel.log 2>/dev/null | grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' | tail -n 1)
                [[ -n "$new_d" ]] && echo "$new_d" > /etc/s-box/argo.log
                green "已刷新域名: ${new_d:-获取中...}"
                ;;
            0) return 0 ;;
            *) red "无效选项" ;;
        esac
        echo
        reading "按回车继续..." _
    done
}

# ==================== 7. 系统运维与日志 ====================
view_logs_menu() {
    while true; do
        clear
        echo
        green "============================================================"
        green "  查看系统与服务运行日志"
        green "============================================================"
        echo
        echo "  1. 查看 Sing-box 核心日志 (最近 30 行)"
        echo "  2. 查看 Argo 隧道日志 (最近 30 行)"
        echo "  3. 查看 Psiphon 赛风日志 (最近 30 行)"
        echo "  4. 查看自愈守护 monitor.log"
        echo "------------------------------------------------------------"
        echo "  0. 返回主菜单"
        echo "============================================================"
        reading "请选择 [0-4]: " choice
        case "$choice" in
            1)
                echo
                green "========== Sing-box 运行日志 =========="
                tail -n 30 /var/log/sing-box.log 2>/dev/null || journalctl -u sing-box -n 30 --no-pager 2>/dev/null || yellow "日志为空"
                echo "======================================="
                ;;
            2)
                echo
                green "========== Argo 隧道日志 =========="
                tail -n 30 /var/log/argo-tunnel.log 2>/dev/null || journalctl -u argo-tunnel -n 30 --no-pager 2>/dev/null || yellow "日志为空"
                echo "==================================="
                ;;
            3)
                echo
                green "========== Psiphon 赛风日志 =========="
                tail -n 30 "$WORKDIR/psiphon.log" 2>/dev/null || yellow "日志为空"
                echo "======================================"
                ;;
            4)
                echo
                green "========== 自愈守护任务日志 =========="
                tail -n 30 /etc/s-box/monitor.log 2>/dev/null || yellow "日志为空"
                echo "======================================"
                ;;
            0) return 0 ;;
            *) red "无效选项" ;;
        esac
        echo
        reading "按回车继续..." _
    done
}

# ==================== Cron 自愈守护任务 ====================
if [[ "$1" == "cron" ]]; then
    log_file="/etc/s-box/monitor.log"
    if [[ -f "$log_file" && $(wc -c < "$log_file") -gt 51200 ]]; then
        : > "$log_file"
    fi

    if ! service_is_active sing-box; then
        service_restart sing-box
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [自愈守护] Sing-box 未运行，已自动拉起！" >> "$log_file"
    fi

    if [[ -f /etc/s-box/argo.conf ]]; then
        if ! service_is_active argo-tunnel; then
            service_restart argo-tunnel
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [自愈守护] Argo 隧道未运行，已自动拉起！" >> "$log_file"
        fi
    fi

    # 检查赛风主实例
    if [[ -f "$WORKDIR/psiphon_main_enabled.txt" && "$(cat "$WORKDIR/psiphon_main_enabled.txt")" == "true" ]]; then
        local pid=$(cat "$WORKDIR/psiphon.pid" 2>/dev/null)
        if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
            start_main_psiphon
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [自愈守护] Psiphon 主进程未运行，已自动拉起！" >> "$log_file"
        fi
    fi
    exit 0
fi

# ==================== 主菜单 ====================
menu() {
    while true; do
        clear
        echo
        green "============================================================"
        green "  Sing-box Linux 多协议节点管理脚本 v${SCRIPT_VERSION}"
        green "============================================================"
        purple "  支持协议: Argo, VLESS-Reality, VMess, Trojan, Hy2, TUIC, AnyTLS"
        echo "============================================================"

        # 加载 IP
        if [ ${#ALL_IPS[@]} -eq 0 ]; then
            if [ -f "$WORKDIR/all_ips.txt" ]; then
                mapfile -t ALL_IPS < "$WORKDIR/all_ips.txt"
            else
                get_all_ips >/dev/null 2>&1
            fi
        fi

        purple "  本机 IP 列表:"
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            [[ -n "$ip" ]] && green "    [$idx] $ip  ->  [可用]"
            ((idx++))
        done
        echo "============================================================"
        echo

        # 检查安装状态与各模块状态
        if [ -f "$WORKDIR/sb.json" ]; then
            if service_is_active sing-box; then
                green "【主节点状态】: ✓ 已安装并运行中"
            else
                yellow "【主节点状态】: ⚠ 已安装但未运行"
            fi

            # 主节点出站
            local warp_status=$(cat "$WORKDIR/warp_enabled.txt" 2>/dev/null)
            local warp_mode=$(cat "$WORKDIR/warp_mode.txt" 2>/dev/null)
            local psi_main=$(cat "$WORKDIR/psiphon_main_enabled.txt" 2>/dev/null)
            if [[ "$warp_status" == "true" ]]; then
                if [[ "$warp_mode" == "all" ]]; then
                    blue "【主节点出站】: ✓ WARP 全局出站 (全部主节点流量走 WARP)"
                else
                    blue "【主节点出站】: ✓ WARP 分流出站 (Google/YouTube/Netflix/OpenAI)"
                fi
            elif [[ "$psi_main" == "true" ]]; then
                blue "【主节点出站】: ✓ 赛风出站 (Psiphon 节点出站)"
            else
                green "【主节点出站】: ✓ 直连出站 (Direct 原生网络直连)"
            fi

            # 副节点 - 赛风
            local psi_insts
            mapfile -t psi_insts < <(get_all_psiphon_instances 2>/dev/null)
            if [[ ${#psi_insts[@]} -gt 0 ]]; then
                purple "【副节点-赛风】: ✓ 已配置 ${#psi_insts[@]} 个国家出口组 (${psi_insts[*]})"
            else
                purple "【副节点-赛风】: ✗ 未配置"
            fi

            # 副节点 - 代理
            local proxy_tags
            mapfile -t proxy_tags < <(get_all_proxy_groups 2>/dev/null)
            if [[ ${#proxy_tags[@]} -gt 0 ]]; then
                purple "【副节点-代理】: ✓ 已配置 ${#proxy_tags[@]} 个代理出口组 (${proxy_tags[*]})"
            else
                purple "【副节点-代理】: ✗ 未配置"
            fi

            # Argo
            if service_is_active argo-tunnel; then
                green "【Argo 隧道】 : ✓ 运行中"
            else
                yellow "【Argo 隧道】 : ✗ 未运行/未启用"
            fi
        else
            yellow "【主节点状态】: ✗ 未安装"
        fi

        echo
        echo "============================================================"
        blue   "  【主节点管理】"
        echo "------------------------------------------------------------"
        green  "  1. 一键重新配置/安装主节点 (多协议: Reality/VMess/Trojan/Hy2/TUIC/AnyTLS)"
        green  "  2. 主节点出站管理 (直连出站 / WARP 全局出站 / WARP 分流出站 / 赛风出站)"
        green  "  3. 主节点 Argo 隧道管理 (开关/重置/固定与临时隧道)"
        green  "  4. 查看主节点信息与订阅 (含各协议链接及主节点出站状态)"
        echo "------------------------------------------------------------"
        purple "  【副节点管理 (平行独立)】"
        echo "------------------------------------------------------------"
        purple "  5. 【副节点】赛风出站多出口管理 (添加/删除出口组、延迟测试、状态)"
        purple "  6. 【副节点】自定义代理出站多出口管理 (添加/修改/删除外部代理出站、测速)"
        echo "------------------------------------------------------------"
        white  "  【综合功能与系统运维】"
        echo "------------------------------------------------------------"
        blue   "  7. 自定义节点组合推送 (自由勾选主/副节点生成专属订阅)"
        blue   "  8. 查看全部节点信息总览 (主节点 + 副节点分类汇总)"
        green  "  9. 重启所有服务 (主节点 + 赛风多实例 + 自定义代理完整同步)"
        yellow " 10. 诊断 / 端口管理与冲突修复"
        blue   " 11. 查看运行日志 (sing-box / Argo / Psiphon / 自愈守护)"
        yellow " 12. 开启/关闭服务自愈守护定时任务"
        red    " 13. 卸载删除主节点与服务"
        echo "------------------------------------------------------------"
        red    "  0. 退出脚本"
        echo "============================================================"

        reading "请选择 [0-13]: " choice
        echo

        case "$choice" in
            1)
                if [[ -f /etc/s-box/install.sh ]]; then
                    bash /etc/s-box/install.sh reconfig
                elif [[ -f ./install.sh ]]; then
                    bash ./install.sh reconfig
                else
                    curl -sL https://raw.githubusercontent.com/hxzl666/singbox/main/install.sh -o /tmp/install.sh && bash /tmp/install.sh reconfig
                fi
                ;;
            2) configure_warp_outbound ;;
            3) argo_management_menu ;;
            4) show_links; echo; reading "按回车继续..." _ ;;
            5) psiphon_management_menu ;;
            6) proxy_egress_menu ;;
            7) custom_push_nodes; echo; reading "按回车继续..." _ ;;
            8) show_all_nodes_summary; echo; reading "按回车继续..." _ ;;
            9)
                yellow "正在重启所有服务..."
                service_restart sing-box
                [[ -f /etc/s-box/argo.conf ]] && service_restart argo-tunnel
                sync_all_secondary_nodes
                apply_changes
                green "所有服务已重启并完成配置同步！"
                reading "按回车继续..." _
                ;;
            10)
                yellow "正在诊断与修复配置..."
                apply_main_node_outbound
                sync_all_secondary_nodes
                apply_changes
                green "诊断与修复完成！"
                reading "按回车继续..." _
                ;;
            11) view_logs_menu ;;
            12)
                if crontab -l 2>/dev/null | grep -q "sb cron"; then
                    crontab -l | grep -v "sb cron" | crontab -
                    green "已关闭服务自愈守护任务。"
                else
                    (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/sb cron >> /etc/s-box/monitor.log 2>&1") | crontab -
                    : > /etc/s-box/monitor.log 2>/dev/null
                    green "已开启服务自愈守护任务 (每分钟检测一次)。"
                fi
                reading "按回车继续..." _
                ;;
            13)
                reading "确定彻底卸载 Sing-box 及所有组件? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    service_stop sing-box
                    service_stop argo-tunnel
                    service_disable sing-box 2>/dev/null
                    service_disable argo-tunnel 2>/dev/null
                    pkill -9 -f "psiphon-tunnel-core" 2>/dev/null || true
                    rm -rf /etc/s-box /usr/local/bin/cloudflared /usr/local/bin/sb
                    crontab -l 2>/dev/null | grep -v "sb cron" | crontab - 2>/dev/null || true
                    green "Sing-box 环境已彻底卸载清理！"
                    exit 0
                fi
                ;;
            0) exit 0 ;;
            *) red "无效选项" ;;
        esac
    done
}

menu
EOF_SB_TOOL
chmod +x /usr/local/bin/sb
}

# ==================== 初次安装 / 部署主流程 ====================
install_singbox_main() {
    log_info "开始安装/更新 Sing-box 环境依赖..."

    # 安装系统依赖
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget tar jq openssl git net-tools cron >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar jq openssl git net-tools cronie >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk update >/dev/null 2>&1
        apk add curl wget tar jq openssl git net-tools >/dev/null 2>&1
    fi

    mkdir -p "$WORKDIR" "$PROXY_GROUPS_DIR" "$PSI_INSTANCES_DIR"

    # 获取系统架构并下载 sing-box
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7) arch="armv7" ;;
        *) arch="amd64" ;;
    esac

    if [[ ! -x "$WORKDIR/sing-box" ]]; then
        log_info "正在下载最新 Sing-box 核心 (Linux-${arch})..."
        local sb_ver="1.11.4"
        local sb_url="https://github.com/SagerNet/sing-box/releases/download/v${sb_ver}/sing-box-${sb_ver}-linux-${arch}.tar.gz"
        local tmp_sb_dir="/tmp/sb_download"
        mkdir -p "$tmp_sb_dir"
        if curl -fsSL "$sb_url" -o "$tmp_sb_dir/sb.tar.gz" 2>/dev/null; then
            tar -xzf "$tmp_sb_dir/sb.tar.gz" -C "$tmp_sb_dir"
            local bin_path=$(find "$tmp_sb_dir" -type f -name "sing-box" | head -n 1)
            [[ -n "$bin_path" ]] && cp -f "$bin_path" "$WORKDIR/sing-box"
        fi
        rm -rf "$tmp_sb_dir"
        chmod +x "$WORKDIR/sing-box" 2>/dev/null
    fi

    # 生成基础 UUID、Reality 证书与密钥
    local UUID
    UUID=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
    [[ -z "$UUID" ]] && UUID="a3b8c2d1-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
    echo "$UUID" > "$WORKDIR/UUID.txt"

    if [[ ! -f "$WORKDIR/cert.pem" || ! -f "$WORKDIR/private.key" ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$WORKDIR/private.key" -out "$WORKDIR/cert.pem" -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1
    fi

    if [[ ! -f "$WORKDIR/private_key.txt" || ! -f "$WORKDIR/public_key.txt" ]]; then
        if [[ -x "$WORKDIR/sing-box" ]]; then
            local keypair=$("$WORKDIR/sing-box" generate reality-keypair 2>/dev/null)
            local pvk=$(echo "$keypair" | awk '/PrivateKey:/{print $2}' | tr -d '\r\n')
            local pbk=$(echo "$keypair" | awk '/PublicKey:/{print $2}' | tr -d '\r\n')
            echo "$pvk" > "$WORKDIR/private_key.txt"
            echo "$pbk" > "$WORKDIR/public_key.txt"
        fi
    fi
    echo "apple.com" > "$WORKDIR/reym.txt"
    echo "" > "$WORKDIR/short_id.txt"

    # 获取 IP
    get_all_ips >/dev/null 2>&1
    local IP="${ALL_IPS[0]:-127.0.0.1}"

    # 默认端口分配
    local PORT_VLESS=$(get_free_port)
    local PORT_VMESS=$(get_free_port)
    local PORT_TROJAN_TLS=$(get_free_port)
    local PORT_HY2=$(get_free_port)
    local PORT_TUIC=$(get_free_port)
    local PORT_ANYTLS=$(get_free_port)
    local PORT_LOOPBACK=$(get_free_loopback_port)

    # 生成主 sing-box 配置
    local REALITY_PVK=$(cat "$WORKDIR/private_key.txt" 2>/dev/null)
    local REALITY_PBK=$(cat "$WORKDIR/public_key.txt" 2>/dev/null)

    cat > "$WORKDIR/sb.json" <<EOF_SB_JSON
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "address": "8.8.8.8",
        "address_resolver": "local"
      },
      {
        "tag": "local",
        "address": "local"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "type": "vless",
      "listen": "::",
      "listen_port": ${PORT_VLESS},
      "users": [{"uuid": "${UUID}", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "apple.com",
        "reality": {
          "enabled": true,
          "handshake": {"server": "apple.com", "server_port": 443},
          "private_key": "${REALITY_PVK}",
          "short_id": [""]
        }
      }
    },
    {
      "tag": "vmess-ws-in",
      "type": "vmess",
      "listen": "::",
      "listen_port": ${PORT_VMESS},
      "users": [{"uuid": "${UUID}"}],
      "transport": {
        "type": "ws",
        "path": "/${UUID}-vm"
      }
    },
    {
      "tag": "trojan-ws-in",
      "type": "trojan",
      "listen": "::",
      "listen_port": ${PORT_TROJAN_TLS},
      "users": [{"password": "${UUID}"}],
      "transport": {
        "type": "ws",
        "path": "/${UUID}-tr"
      },
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    },
    {
      "tag": "hy2-in",
      "type": "hysteria2",
      "listen": "::",
      "listen_port": ${PORT_HY2},
      "users": [{"password": "${UUID}"}],
      "masquerade": "https://www.bing.com",
      "ignore_client_bandwidth": false,
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    },
    {
      "tag": "tuic-in",
      "type": "tuic",
      "listen": "::",
      "listen_port": ${PORT_TUIC},
      "users": [{"uuid": "${UUID}", "password": "${UUID}"}],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    },
    {
      "tag": "anytls-in",
      "type": "anytls",
      "listen": "::",
      "listen_port": ${PORT_ANYTLS},
      "users": [{"password": "${UUID}"}],
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/s-box/cert.pem",
        "key_path": "/etc/s-box/private.key"
      }
    },
    {
      "tag": "socks-loopback",
      "type": "socks",
      "listen": "127.0.0.1",
      "listen_port": ${PORT_LOOPBACK}
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["socks-loopback"],
        "outbound": "direct"
      }
    ],
    "final": "direct"
  }
}
EOF_SB_JSON

    # 注册 systemd 或 openrc 服务
    if $IS_OPENRC; then
        cat > /etc/init.d/sing-box <<'EOF_INIT'
#!/sbin/openrc-run
description="Sing-box Service"
command="/etc/s-box/sing-box"
command_args="run -c /etc/s-box/sb.json"
pidfile="/run/sing-box.pid"
command_background=true
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
EOF_INIT
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1
    elif ! $IS_DIRECT; then
        cat > /etc/systemd/system/sing-box.service <<'EOF_SYSTEMD'
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/s-box/sing-box run -c /etc/s-box/sb.json
Restart=always
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF_SYSTEMD
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable sing-box >/dev/null 2>&1
    fi

    # 生成 info.log
    cat > "$WORKDIR/info.log" <<EOF_INFO
==================================================
        Sing-box 多协议部署成功
==================================================
通用密码/UUID: ${UUID}

------------------【主节点列表】--------------------
1. VLESS-Reality:
vless://${UUID}@${IP}:${PORT_VLESS}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apple.com&fp=chrome&pbk=${REALITY_PBK}&sid=#SB-VLESS-Reality

2. VMess-WS:
$(make_vmess_link "{\"v\":\"2\",\"ps\":\"SB-VMess\",\"add\":\"${IP}\",\"port\":\"${PORT_VMESS}\",\"id\":\"${UUID}\",\"net\":\"ws\",\"path\":\"/${UUID}-vm\"}")

3. Trojan-WS-TLS:
trojan://${UUID}@${IP}:${PORT_TROJAN_TLS}?security=tls&sni=www.bing.com&allowInsecure=1&type=ws&path=%2F${UUID}-tr#SB-Trojan-TLS

4. Hysteria2:
hysteria2://${UUID}@${IP}:${PORT_HY2}?insecure=1&sni=www.bing.com#SB-Hysteria2

5. TUIC v5:
tuic://${UUID}:${UUID}@${IP}:${PORT_TUIC}?alpn=h3&congestion_control=bbr&udp_relay=1&allow_insecure=1#SB-TUIC-v5

6. AnyTLS:
anytls://${UUID}@${IP}:${PORT_ANYTLS}?security=tls&sni=www.bing.com&allowInsecure=1#SB-AnyTLS
==================================================
EOF_INFO

    # 自动挂载所有副节点（若已有）
    sync_all_secondary_nodes

    # 启动 sing-box 服务
    service_start sing-box

    # 生成快捷工具
    create_sb_tool

    # 备份当前脚本至 /etc/s-box/install.sh
    cp -f "$0" /etc/s-box/install.sh 2>/dev/null
    chmod +x /etc/s-box/install.sh 2>/dev/null

    # 写入 cron 守护任务
    if ! crontab -l 2>/dev/null | grep -q "sb cron"; then
        (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/sb cron >> /etc/s-box/monitor.log 2>&1") | crontab - 2>/dev/null || true
    fi

    log_info "Sing-box 安装与部署完成！"
    echo
    cat "$WORKDIR/info.log"
    echo
    log_info "快捷管理命令: 【 sb 】"
}

# ==================== 入口调度 ====================
if [[ "$1" == "reconfig" ]]; then
    install_singbox_main
    exit 0
fi

if [[ -f "$WORKDIR/sb.json" ]]; then
    create_sb_tool
    bash /usr/local/bin/sb
    exit 0
else
    install_singbox_main
fi
