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

export LANG=en_US.UTF-8
export LC_ALL=C

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

WORKDIR="/etc/s-box"
PROXY_GROUPS_DIR="${WORKDIR}/proxy_groups"
PSI_INSTANCES_DIR="${WORKDIR}/psiphon_instances"
SCRIPT_VERSION="2.0.0"

# 基础编码与辅助函数
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

# 架构探测
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        i386|i686|386) echo "386" ;;
        *) echo "amd64" ;;
    esac
}

# 平台与服务自适应
IS_OPENRC=false
IS_DIRECT=false
if [[ -x "/sbin/openrc-run" || -x "/sbin/runlevels" ]]; then
    IS_OPENRC=true
elif ! pidof systemd >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    IS_DIRECT=true
fi

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
        local pidfile="/etc/s-box/${name}.pid"
        if [[ -f "$pidfile" ]]; then
            local pid
            pid=$(cat "$pidfile" 2>/dev/null)
            [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
        else
            return 1
        fi
    else
        systemctl is-active --quiet "$name"
    fi
}

# ==================== 依赖与核心自动安装 ====================
install_system_dependencies() {
    if ! command -v curl >/dev/null 2>&1 || ! command -v wget >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl wget tar jq openssl git net-tools cron ca-certificates >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl wget tar jq openssl git net-tools cronie ca-certificates >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk update >/dev/null 2>&1
            apk add curl wget tar jq openssl git net-tools ca-certificates >/dev/null 2>&1
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm curl wget tar jq openssl net-tools cronie ca-certificates >/dev/null 2>&1
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        local arch=$(detect_arch)
        mkdir -p /usr/local/bin
        curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${arch}" -o /usr/local/bin/jq 2>/dev/null || \
        curl -fsSL "https://ghproxy.net/https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${arch}" -o /usr/local/bin/jq 2>/dev/null
        chmod +x /usr/local/bin/jq 2>/dev/null
    fi
}

download_singbox_core() {
    local arch=$(detect_arch)
    mkdir -p "$WORKDIR"
    if [[ ! -x "$WORKDIR/sing-box" ]]; then
        yellow "[*] 正在下载 Sing-box 核心 (Linux-${arch})..."
        local sb_ver="1.11.4"
        local sb_urls=(
            "https://github.com/SagerNet/sing-box/releases/download/v${sb_ver}/sing-box-${sb_ver}-linux-${arch}.tar.gz"
            "https://ghproxy.net/https://github.com/SagerNet/sing-box/releases/download/v${sb_ver}/sing-box-${sb_ver}-linux-${arch}.tar.gz"
            "https://raw.githubusercontent.com/hxzl666/singbox/main/sing-box-linux-${arch}"
        )
        local tmp_d="/tmp/sb_bin_tmp"
        mkdir -p "$tmp_d"
        for url in "${sb_urls[@]}"; do
            if curl -fsSL "$url" -o "$tmp_d/sb_pkg" 2>/dev/null; then
                if [[ "$url" == *.tar.gz ]]; then
                    tar -xzf "$tmp_d/sb_pkg" -C "$tmp_d" 2>/dev/null
                    local bpath=$(find "$tmp_d" -type f -name "sing-box" | head -n 1)
                    [[ -n "$bpath" ]] && cp -f "$bpath" "$WORKDIR/sing-box"
                else
                    cp -f "$tmp_d/sb_pkg" "$WORKDIR/sing-box"
                fi
                [[ -f "$WORKDIR/sing-box" ]] && break
            fi
        done
        rm -rf "$tmp_d"
        chmod +x "$WORKDIR/sing-box" 2>/dev/null
    fi

    if [[ ! -x "$WORKDIR/sing-box" ]]; then
        red "[!] Sing-box 核心程序下载失败，请检查 VPS 网络！"
        return 1
    fi
    return 0
}

download_cloudflared_core() {
    local arch=$(detect_arch)
    local cf_arch="$arch"
    [[ "$arch" == "armv7" ]] && cf_arch="arm"
    mkdir -p /usr/local/bin
    if [[ ! -x "/usr/local/bin/cloudflared" ]]; then
        yellow "[*] 正在下载 Cloudflared 核心 (Linux-${cf_arch})..."
        local cf_urls=(
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
            "https://ghproxy.net/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
        )
        for url in "${cf_urls[@]}"; do
            if curl -fsSL "$url" -o "/usr/local/bin/cloudflared" 2>/dev/null; then
                chmod +x "/usr/local/bin/cloudflared"
                break
            fi
        done
    fi
}

download_psiphon_core() {
    local arch=$(detect_arch)
    local psi_arch="$arch"
    [[ "$arch" == "armv7" ]] && psi_arch="arm"
    mkdir -p "$WORKDIR"
    if [[ -x "$WORKDIR/psiphon-tunnel-core" ]]; then
        return 0
    fi

    yellow "[*] 正在下载 Psiphon 赛风核心 (Linux-${psi_arch})..."
    local psi_urls=(
        "https://github.com/hxzlplp7/psiphon-tunnel-core/releases/download/v1.0.0/psiphon-tunnel-core-linux-${psi_arch}.tar.gz"
        "https://ghproxy.net/https://github.com/hxzlplp7/psiphon-tunnel-core/releases/download/v1.0.0/psiphon-tunnel-core-linux-${psi_arch}.tar.gz"
        "https://github.com/Psiphon-Labs/psiphon-tunnel-core/releases/download/v2.0.28/psiphon-tunnel-core-linux-${psi_arch}"
        "https://ghproxy.net/https://github.com/Psiphon-Labs/psiphon-tunnel-core/releases/download/v2.0.28/psiphon-tunnel-core-linux-${psi_arch}"
    )

    local tmp_psi="/tmp/psi_download_tmp"
    mkdir -p "$tmp_psi"
    for url in "${psi_urls[@]}"; do
        if curl -fsSL "$url" -o "$tmp_psi/psi_pkg" 2>/dev/null; then
            if [[ "$url" == *.tar.gz ]]; then
                tar -xzf "$tmp_psi/psi_pkg" -C "$tmp_psi" 2>/dev/null
                local ext_f=$(find "$tmp_psi" -type f -name 'psiphon-tunnel-core*' ! -name '*.tar.gz' | head -n1)
                [[ -n "$ext_f" ]] && cp -f "$ext_f" "$WORKDIR/psiphon-tunnel-core"
            else
                cp -f "$tmp_psi/psi_pkg" "$WORKDIR/psiphon-tunnel-core"
            fi
            [[ -f "$WORKDIR/psiphon-tunnel-core" ]] && break
        fi
    done
    rm -rf "$tmp_psi"
    chmod +x "$WORKDIR/psiphon-tunnel-core" 2>/dev/null

    if [[ ! -x "$WORKDIR/psiphon-tunnel-core" ]]; then
        yellow "未下载到 Psiphon 核心，请检查 VPS 对 GitHub 的网络连通性。"
        return 1
    fi

    # 预载 Psiphon 种子服务器列表
    if [[ ! -f "$WORKDIR/server_list_compressed" ]]; then
        local s_urls=(
            "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed"
            "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
            "https://ghproxy.net/https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
        )
        for surl in "${s_urls[@]}"; do
            curl -fsSL "$surl" -o "$WORKDIR/server_list_compressed" 2>/dev/null && break
        done
    fi

    green "[+] Psiphon 核心已安装: $WORKDIR/psiphon-tunnel-core"
    return 0
}

# ==================== IP 与端口获取 ====================
ALL_IPS=()
get_all_ips() {
    ALL_IPS=()
    mkdir -p "$WORKDIR"
    if [[ -f "$WORKDIR/all_ips.txt" ]]; then
        mapfile -t ALL_IPS < "$WORKDIR/all_ips.txt"
    fi
    if [[ ${#ALL_IPS[@]} -gt 0 && -n "${ALL_IPS[0]}" ]]; then
        return 0
    fi

    local ipv4_list
    ipv4_list=$(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | grep -vE '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)')
    if [[ -z "$ipv4_list" ]]; then
        local pub_ip
        pub_ip=$(curl -s4m3 https://api.ipify.org 2>/dev/null || curl -s4m3 https://ip.sb 2>/dev/null)
        [[ -n "$pub_ip" ]] && ALL_IPS+=("$pub_ip")
    else
        while read -r ip; do
            [[ -n "$ip" ]] && ALL_IPS+=("$ip")
        done <<< "$ipv4_list"
    fi

    local ipv6_list
    ipv6_list=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-fA-F:]+' | grep -vE '^(fe80|::1|fd)')
    if [[ -n "$ipv6_list" ]]; then
        while read -r ip6; do
            [[ -n "$ip6" ]] && ALL_IPS+=("$ip6")
        done <<< "$ipv6_list"
    fi

    [[ ${#ALL_IPS[@]} -eq 0 ]] && ALL_IPS=("$(hostname -I 2>/dev/null | awk '{print $1}')")
    [[ ${#ALL_IPS[@]} -eq 0 || -z "${ALL_IPS[0]}" ]] && ALL_IPS=("127.0.0.1")
    printf "%s\n" "${ALL_IPS[@]}" > "$WORKDIR/all_ips.txt"
}

is_port_used() {
    local port=$1
    ss -tulpn 2>/dev/null | grep -qE "(:${port}\s|:${port}$)" || \
    netstat -tulpn 2>/dev/null | grep -qE "(:${port}\s|:${port}$)"
}

get_free_port() {
    local port=$(( (RANDOM % 40000) + 10000 ))
    while is_port_used "$port"; do
        port=$(( (RANDOM % 40000) + 10000 ))
    done
    echo "$port"
}

get_free_loopback_port() {
    local port=$(( (RANDOM % 30000) + 20000 ))
    while is_port_used "$port"; do
        port=$(( (RANDOM % 30000) + 20000 ))
    done
    echo "$port"
}

read_valid_port() {
    local prompt="$1" default_port="$2" out_var="$3"
    local p=""
    while true; do
        reading "$prompt" p
        [[ -z "$p" ]] && p="$default_port"
        if [[ "$p" == "0" ]]; then
            eval "$out_var=0"
            return 0
        fi
        if ! [[ "$p" =~ ^[0-9]+$ ]] || [[ "$p" -lt 1 || "$p" -gt 65535 ]]; then
            red "[!] 端口必须为 1-65535 之间的数字，请重新输入！"
            continue
        fi
        if is_port_used "$p"; then
            red "[!] 端口 $p 已被系统其他进程占用，请更换其他端口！"
            continue
        fi
        eval "$out_var=$p"
        return 0
    done
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
    loop_port=$(jq -r '.inbounds[]? | select(.tag=="socks-loopback") | .listen_port // empty' "$WORKDIR/sb.json" 2>/dev/null | head -n1)
    if [[ -z "$loop_port" ]]; then
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
        KR) echo "韩国 (South Korea)" ;;
        TW) echo "中国台湾 (Taiwan)" ;;
        GB) echo "英国 (United Kingdom)" ;;
        DE) echo "德国 (Germany)" ;;
        CA) echo "加拿大 (Canada)" ;;
        NL) echo "荷兰 (Netherlands)" ;;
        FR) echo "法国 (France)" ;;
        IN) echo "印度 (India)" ;;
        AU) echo "澳大利亚 (Australia)" ;;
        CH) echo "瑞士 (Switzerland)" ;;
        SE) echo "瑞典 (Sweden)" ;;
        IT) echo "意大利 (Italy)" ;;
        ES) echo "西班牙 (Spain)" ;;
        PL) echo "波兰 (Poland)" ;;
        AT) echo "奥地利 (Austria)" ;;
        BE) echo "比利时 (Belgium)" ;;
        DK) echo "丹麦 (Denmark)" ;;
        NO) echo "挪威 (Norway)" ;;
        RO) echo "罗马尼亚 (Romania)" ;;
        CZ) echo "捷克 (Czech Republic)" ;;
        HU) echo "匈牙利 (Hungary)" ;;
        BG) echo "保加利亚 (Bulgaria)" ;;
        IE) echo "爱尔兰 (Ireland)" ;;
        FI) echo "芬兰 (Finland)" ;;
        AUTO|"") echo "智能自动优选" ;;
        *) echo "$code" ;;
    esac
}

show_supported_psiphon_codes() {
    yellow "Psiphon 赛风支持的出口国家代码列表:"
    echo "  [热门国家]:"
    echo "    US - 美国      JP - 日本      SG - 新加坡    HK - 中国香港"
    echo "    KR - 韩国      TW - 中国台湾  GB - 英国      DE - 德国"
    echo "    CA - 加拿大    NL - 荷兰      FR - 法国      IN - 印度      AU - 澳大利亚"
    echo "  [欧洲及其他国家]:"
    echo "    CH - 瑞士      SE - 瑞典      IT - 意大利    ES - 西班牙    PL - 波兰"
    echo "    AT - 奥地利    BE - 比利时    DK - 丹麦      NO - 挪威      RO - 罗马尼亚"
    echo "    CZ - 捷克      HU - 匈牙利    BG - 保加利亚  IE - 爱尔兰    FI - 芬兰"
    echo "  [自动策略]:"
    echo "    AUTO - 智能自动优选最佳出口"
}

write_psiphon_config() {
    local socks_port="$1"
    local region="$2"
    local cfg_file="$3"
    local data_dir="$4"

    mkdir -p "$data_dir" 2>/dev/null
    [[ "${region^^}" == "AUTO" ]] && region=""

    # 部署种子服务器列表至实例目录
    if [[ -f "$WORKDIR/server_list_compressed" ]]; then
        cp -f "$WORKDIR/server_list_compressed" "$data_dir/server_list_compressed" 2>/dev/null
        cp -f "$WORKDIR/server_list_compressed" "$data_dir/remote_server_list" 2>/dev/null
    else
        local s_urls=(
            "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed"
            "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
            "https://ghproxy.net/https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
        )
        for surl in "${s_urls[@]}"; do
            if curl -fsSL "$surl" -o "$data_dir/server_list_compressed" 2>/dev/null; then
                cp -f "$data_dir/server_list_compressed" "$data_dir/remote_server_list" 2>/dev/null
                cp -f "$data_dir/server_list_compressed" "$WORKDIR/server_list_compressed" 2>/dev/null
                break
            fi
        done
    fi

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
  "RemoteServerListDownloadFilename": "remote_server_list",
  "RemoteServerListSignaturePublicKey": "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
  "RemoteServerListUrl": "https://s3.amazonaws.com//psiphon/web/mjr4-p23r-puwl/server_list_compressed",
  "UseIndistinguishableTLS": true
}
EOF_PSI
}

start_main_psiphon() {
    download_psiphon_core || return 1
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

# ==================== 副节点目录与旧配置迁移 ====================
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

# 自动发现并迁移之前旧版本中的自定义出口节点与副节点
auto_migrate_legacy_nodes() {
    local cfg="$WORKDIR/sb.json"
    [[ -f "$cfg" ]] || return 0
    init_proxy_groups_dir
    init_psiphon_instances_dir

    local custom_outbound_tags
    mapfile -t custom_outbound_tags < <(jq -r '.outbounds[]? | select(.tag != "direct" and .tag != "block" and .tag != "warp-out" and .tag != "psiphon-main-out") | .tag' "$cfg" 2>/dev/null)

    local legacy_inbounds_to_remove=()

    for otag in "${custom_outbound_tags[@]}"; do
        [[ -z "$otag" || "$otag" == "null" ]] && continue
        
        # 赛风副节点
        if [[ "$otag" =~ ^psiphon-([a-zA-Z0-9]+)$ ]]; then
            local cc="${BASH_REMATCH[1]^^}"
            local inst_dir="${PSI_INSTANCES_DIR}/${cc}"
            mkdir -p "$inst_dir"
            local sport
            sport=$(jq -r --arg t "$otag" '.outbounds[]? | select(.tag==$t) | .server_port // empty' "$cfg" 2>/dev/null | head -n1)
            echo "${sport:-0}" > "$inst_dir/socks_port.txt"
            
            local hp tp vp
            hp=$(jq -r --arg t "hy2-psi-${cc,,}-in" '.inbounds[]? | select(.tag==$t or .tag==("hy2-custom-in-" + $t)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
            tp=$(jq -r --arg t "tuic-psi-${cc,,}-in" '.inbounds[]? | select(.tag==$t or .tag==("tuic-custom-in-" + $t)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
            vp=$(jq -r --arg t "vless-psi-${cc,,}-in" '.inbounds[]? | select(.tag==$t or .tag==("vless-custom-in-" + $t)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
            echo "${hp:-0}" > "$inst_dir/hy2_port.txt"
            echo "${tp:-0}" > "$inst_dir/tuic_port.txt"
            echo "${vp:-0}" > "$inst_dir/vless_port.txt"
            if ! grep -qx "$cc" "$PSI_INSTANCES_DIR/instances.txt" 2>/dev/null; then
                echo "$cc" >> "$PSI_INSTANCES_DIR/instances.txt"
            fi
            continue
        fi

        # 自定义外部代理副节点 (如 outbound-us, proxy-1, UA, JP 等)
        local gtag="$otag"
        [[ "$gtag" == *-out ]] && gtag="${gtag%-out}"
        local gdir="${PROXY_GROUPS_DIR}/${gtag}"
        mkdir -p "$gdir"

        jq --arg t "$otag" '.outbounds[]? | select(.tag==$t)' "$cfg" > "$gdir/outbound.json" 2>/dev/null
        [[ ! -f "$gdir/remark.txt" ]] && echo "$gtag" > "$gdir/remark.txt"

        local matched_inbounds
        mapfile -t matched_inbounds < <(jq -r --arg t "$otag" '.route.rules[]? | select(.outbound==$t) | .inbound[]?' "$cfg" 2>/dev/null)

        local hp="0" tp="0" vp="0"
        for ib_tag in "${matched_inbounds[@]}"; do
            [[ -z "$ib_tag" || "$ib_tag" == "null" ]] && continue
            local p_type p_port
            p_type=$(jq -r --arg t "$ib_tag" '.inbounds[]? | select(.tag==$t) | .type' "$cfg" 2>/dev/null)
            p_port=$(jq -r --arg t "$ib_tag" '.inbounds[]? | select(.tag==$t) | .listen_port' "$cfg" 2>/dev/null)
            if [[ "$p_type" == "hysteria2" ]]; then hp="$p_port"; fi
            if [[ "$p_type" == "tuic" ]]; then tp="$p_port"; fi
            if [[ "$p_type" == "vless" ]]; then vp="$p_port"; fi
            if [[ "$ib_tag" != "hy2-${gtag}-in" && "$ib_tag" != "tuic-${gtag}-in" && "$ib_tag" != "vless-${gtag}-in" ]]; then
                legacy_inbounds_to_remove+=("$ib_tag")
            fi
        done

        local saved_hp saved_tp saved_vp
        saved_hp=$(cat "$gdir/hy2_port.txt" 2>/dev/null || echo "0")
        saved_tp=$(cat "$gdir/tuic_port.txt" 2>/dev/null || echo "0")
        saved_vp=$(cat "$gdir/vless_port.txt" 2>/dev/null || echo "0")

        [[ "$hp" == "0" || -z "$hp" ]] && hp="$saved_hp"
        [[ "$tp" == "0" || -z "$tp" ]] && tp="$saved_tp"
        [[ "$vp" == "0" || -z "$vp" ]] && vp="$saved_vp"

        if [[ "$hp" == "0" || -z "$hp" ]]; then
            hp=$(jq -r --arg t "$gtag" '.inbounds[]? | select(.tag | (contains($t) and contains("hy2"))) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
        fi
        if [[ "$tp" == "0" || -z "$tp" ]]; then
            tp=$(jq -r --arg t "$gtag" '.inbounds[]? | select(.tag | (contains($t) and contains("tuic"))) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
        fi
        if [[ "$vp" == "0" || -z "$vp" ]]; then
            vp=$(jq -r --arg t "$gtag" '.inbounds[]? | select(.tag | (contains($t) and contains("vless"))) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
        fi

        if [[ "${hp:-0}" == "0" && "${tp:-0}" == "0" && "${vp:-0}" == "0" ]]; then
            hp=$(get_free_port)
        fi

        echo "${hp:-0}" > "$gdir/hy2_port.txt"
        echo "${tp:-0}" > "$gdir/tuic_port.txt"
        echo "${vp:-0}" > "$gdir/vless_port.txt"

        if ! grep -qx "$gtag" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null; then
            echo "$gtag" >> "$PROXY_GROUPS_DIR/groups.txt"
        fi
    done

    # 清除旧的重复入站标签，防止端口重复绑定
    if [[ ${#legacy_inbounds_to_remove[@]} -gt 0 ]]; then
        local tmp_cl=$(mktemp)
        jq --argjson tags "$(printf '%s\n' "${legacy_inbounds_to_remove[@]}" | jq -R . | jq -s .)" '
        .inbounds = [.inbounds[] | select(.tag as $t | ($tags | index($t) | not))]
        ' "$cfg" > "$tmp_cl" && mv -f "$tmp_cl" "$cfg"
    fi
}

# 纯 jq/bash 解析外部代理链接
parse_proxy_url_to_json() {
    local url="$1"
    local tag="$2"
    url=$(echo "$url" | tr -d '\r\n ')
    [[ -z "$url" ]] && return 1

    local proto="${url%%://*}"
    case "$proto" in
        vmess)
            local raw="${url#vmess://}"
            raw="${raw%%#*}"
            local decoded_json
            decoded_json=$(printf '%s' "$raw" | base64 -d 2>/dev/null || printf '%s' "$raw" | base64 -d -i 2>/dev/null)
            if ! echo "$decoded_json" | jq -e . >/dev/null 2>&1; then
                echo "ERROR: VMess base64 解析失败"
                return 1
            fi
            echo "$decoded_json" | jq --arg tag "$tag" '
            {
                "type": "vmess",
                "tag": $tag,
                "server": (.add // ""),
                "server_port": ((.port // 443) | tostring | tonumber),
                "uuid": (.id // ""),
                "alter_id": ((.aid // 0) | tostring | tonumber),
                "security": (.scy // "auto")
            } +
            (if .net == "ws" then {"transport": {"type": "ws", "path": (.path // "/"), "headers": (if .host and .host != "" then {"Host": .host} else {} end)}}
             elif .net == "grpc" then {"transport": {"type": "grpc", "service_name": (.serviceName // (.path // "") | ltrimstr("/"))}}
             elif .net == "httpupgrade" or .net == "h1" then {"transport": {"type": "httpupgrade", "path": (.path // "/"), "headers": (if .host and .host != "" then {"Host": .host} else {} end)}}
             else {} end) +
            (if .tls == "tls" then {"tls": {"enabled": true, "server_name": (if .sni and .sni != "" then .sni elif .host and .host != "" then .host else .add end)}} else {} end)
            '
            ;;
        vless|trojan|hy2|hysteria2|tuic|ss)
            local rest="${url#*://}"
            local fragment="${rest#*#}"
            [[ "$rest" == *"#"* ]] || fragment=""
            rest="${rest%%#*}"
            local query="${rest#*\?}"
            [[ "$rest" == *"\?"* ]] || query=""
            local hostpart="${rest%%\?*}"

            local userinfo="" host="" port=""
            if [[ "$hostpart" == *"@"* ]]; then
                userinfo="${hostpart%%@*}"
                hostpart="${hostpart#*@}"
            fi

            if [[ "$hostpart" =~ ^\[([a-fA-F0-9:]+)\]:([0-9]+)$ ]]; then
                host="${BASH_REMATCH[1]}"
                port="${BASH_REMATCH[2]}"
            elif [[ "$hostpart" =~ ^([a-zA-Z0-9.-]+):([0-9]+)$ ]]; then
                host="${BASH_REMATCH[1]}"
                port="${BASH_REMATCH[2]}"
            else
                host="$hostpart"
                port="443"
            fi

            local q_sni="" q_security="" q_flow="" q_pbk="" q_sid="" q_fp="" q_insecure="0" q_type="tcp" q_path="/" q_host="" q_serviceName="" q_alpn="" q_obfs="" q_obfs_pass=""
            if [[ -n "$query" ]]; then
                local old_ifs="$IFS"
                IFS='&'
                for param in $query; do
                    local k="${param%%=*}"
                    local v="${param#*=}"
                    case "$k" in
                        sni) q_sni="$v" ;;
                        security) q_security="$v" ;;
                        flow) q_flow="$v" ;;
                        pbk) q_pbk="$v" ;;
                        sid) q_sid="$v" ;;
                        fp) q_fp="$v" ;;
                        insecure|allowInsecure) q_insecure="$v" ;;
                        type) q_type="$v" ;;
                        path) q_path=$(printf '%b' "${v//%/\\x}") ;;
                        host) q_host="$v" ;;
                        serviceName) q_serviceName="$v" ;;
                        alpn) q_alpn="$v" ;;
                        obfs) q_obfs="$v" ;;
                        obfs-password) q_obfs_pass="$v" ;;
                    esac
                done
                IFS="$old_ifs"
            fi

            [[ -z "$q_sni" ]] && q_sni="$host"

            case "$proto" in
                vless)
                    jq -n \
                      --arg tag "$tag" \
                      --arg server "$host" \
                      --argjson port "$port" \
                      --arg uuid "$userinfo" \
                      --arg flow "$q_flow" \
                      --arg sec "$q_security" \
                      --arg sni "$q_sni" \
                      --arg pbk "$q_pbk" \
                      --arg sid "$q_sid" \
                      --arg fp "$q_fp" \
                      --arg net "$q_type" \
                      --arg path "$q_path" \
                      --arg hosthdr "$q_host" \
                      '
                      {
                        "type": "vless",
                        "tag": $tag,
                        "server": $server,
                        "server_port": $port,
                        "uuid": $uuid
                      } +
                      (if $flow != "" then {"flow": $flow} else {} end) +
                      (if $net == "ws" then {"transport": {"type": "ws", "path": $path, "headers": (if $hosthdr != "" then {"Host": $hosthdr} else {} end)}}
                       elif $net == "grpc" then {"transport": {"type": "grpc", "service_name": $path}}
                       elif $net == "httpupgrade" then {"transport": {"type": "httpupgrade", "path": $path, "headers": (if $hosthdr != "" then {"Host": $hosthdr} else {} end)}}
                       else {} end) +
                      (if $sec == "reality" then {
                        "tls": {"enabled": true, "server_name": $sni, "utls": {"enabled": true, "fingerprint": (if $fp != "" then $fp else "chrome" end)}, "reality": {"enabled": true, "public_key": $pbk, "short_id": $sid}}
                      } elif $sec == "tls" then {
                        "tls": {"enabled": true, "server_name": $sni, "utls": {"enabled": true, "fingerprint": (if $fp != "" then $fp else "chrome" end)}}
                      } else {} end)
                      '
                    ;;
                trojan)
                    jq -n \
                      --arg tag "$tag" \
                      --arg server "$host" \
                      --argjson port "$port" \
                      --arg pass "$userinfo" \
                      --arg sni "$q_sni" \
                      --arg net "$q_type" \
                      --arg path "$q_path" \
                      --arg hosthdr "$q_host" \
                      '
                      {
                        "type": "trojan",
                        "tag": $tag,
                        "server": $server,
                        "server_port": $port,
                        "password": $pass,
                        "tls": {"enabled": true, "server_name": $sni}
                      } +
                      (if $net == "ws" then {"transport": {"type": "ws", "path": $path, "headers": (if $hosthdr != "" then {"Host": $hosthdr} else {} end)}}
                       elif $net == "grpc" then {"transport": {"type": "grpc", "service_name": $path}}
                       elif $net == "httpupgrade" then {"transport": {"type": "httpupgrade", "path": $path, "headers": (if $hosthdr != "" then {"Host": $hosthdr} else {} end)}}
                       else {} end)
                      '
                    ;;
                hy2|hysteria2)
                    local insec_bool="false"
                    [[ "$q_insecure" == "1" || "$q_insecure" == "true" ]] && insec_bool="true"
                    jq -n \
                      --arg tag "$tag" \
                      --arg server "$host" \
                      --argjson port "$port" \
                      --arg pass "$userinfo" \
                      --arg sni "$q_sni" \
                      --argjson insec "$insec_bool" \
                      --arg obfs "$q_obfs" \
                      --arg obfs_p "$q_obfs_pass" \
                      '
                      {
                        "type": "hysteria2",
                        "tag": $tag,
                        "server": $server,
                        "server_port": $port,
                        "password": $pass,
                        "tls": {"enabled": true, "server_name": $sni, "insecure": $insec}
                      } +
                      (if $obfs != "" then {"obfs": {"type": $obfs, "password": $obfs_p}} else {} end)
                      '
                    ;;
                tuic)
                    local tuic_uuid="${userinfo%%:*}"
                    local tuic_pass="${userinfo#*:}"
                    [[ "$userinfo" != *":"* ]] && tuic_pass="$tuic_uuid"
                    local insec_bool="false"
                    [[ "$q_insecure" == "1" || "$q_insecure" == "true" ]] && insec_bool="true"
                    local alpn_arr='["h3"]'
                    [[ -n "$q_alpn" ]] && alpn_arr=$(printf '%s' "$q_alpn" | jq -R 'split(",")')

                    jq -n \
                      --arg tag "$tag" \
                      --arg server "$host" \
                      --argjson port "$port" \
                      --arg uuid "$tuic_uuid" \
                      --arg pass "$tuic_pass" \
                      --arg sni "$q_sni" \
                      --argjson insec "$insec_bool" \
                      --argjson alpn "$alpn_arr" \
                      '
                      {
                        "type": "tuic",
                        "tag": $tag,
                        "server": $server,
                        "server_port": $port,
                        "uuid": $uuid,
                        "password": $pass,
                        "congestion_control": "bbr",
                        "tls": {"enabled": true, "server_name": $sni, "alpn": $alpn, "insecure": $insec}
                      }
                      '
                    ;;
                ss)
                    local method="aes-256-gcm" password="$userinfo"
                    if [[ "$userinfo" == *":"* ]]; then
                        method="${userinfo%%:*}"
                        password="${userinfo#*:}"
                    else
                        local dec
                        dec=$(printf '%s' "$userinfo" | base64 -d 2>/dev/null)
                        if [[ "$dec" == *":"* ]]; then
                            method="${dec%%:*}"
                            password="${dec#*:}"
                        fi
                    fi
                    jq -n \
                      --arg tag "$tag" \
                      --arg server "$host" \
                      --argjson port "$port" \
                      --arg method "$method" \
                      --arg pass "$password" \
                      '
                      {
                        "type": "shadowsocks",
                        "tag": $tag,
                        "server": $server,
                        "server_port": $port,
                        "method": $method,
                        "password": $pass
                      }
                      '
                    ;;
            esac
            ;;
        *)
            echo "ERROR: 不支持的协议: $proto"
            return 1
            ;;
    esac
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

# ==================== 同步自定义代理副节点到 sing-box (纯 jq) ====================
sync_proxy_group_to_singbox() {
    local group_tag="$1"
    local group_dir="${PROXY_GROUPS_DIR}/${group_tag}"
    local cfg="$WORKDIR/sb.json"

    [[ -f "$cfg" ]] || return 1
    [[ -d "$group_dir" ]] || return 1
    [[ -f "$group_dir/outbound.json" ]] || return 1

    local hy2_port tuic_port vless_port uuid reality_pvk reym
    hy2_port=$(cat "$group_dir/hy2_port.txt" 2>/dev/null || echo "0")
    tuic_port=$(cat "$group_dir/tuic_port.txt" 2>/dev/null || echo "0")
    vless_port=$(cat "$group_dir/vless_port.txt" 2>/dev/null || echo "0")
    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.users[0].uuid != null) | .users[0].uuid' "$cfg" 2>/dev/null | head -n1)
    [[ -z "$uuid" ]] && uuid=$(jq -r '.inbounds[]? | select(.users[0].password != null) | .users[0].password' "$cfg" 2>/dev/null | head -n1)
    reality_pvk=$(cat "$WORKDIR/private_key.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.tls.reality.private_key != null) | .tls.reality.private_key' "$cfg" 2>/dev/null | head -n1)
    reym=$(cat "$WORKDIR/reym.txt" 2>/dev/null || echo "apple.com")
    local out_tag="${group_tag}-out"

    local tmp_json
    tmp_json=$(mktemp)

    jq \
      --slurpfile ob_file "$group_dir/outbound.json" \
      --arg group_tag "$group_tag" \
      --arg out_tag "$out_tag" \
      --argjson hy2_port "${hy2_port:-0}" \
      --argjson tuic_port "${tuic_port:-0}" \
      --argjson vless_port "${vless_port:-0}" \
      --arg uuid "$uuid" \
      --arg reality_pvk "$reality_pvk" \
      --arg reym "$reym" \
      '
      .outbounds = ([.outbounds[] | select(.tag != $out_tag)]) + [($ob_file[0] + {"tag": $out_tag})] |

      .inbounds = [.inbounds[] | select(
        .tag != ("hy2-" + $group_tag + "-in") and
        .tag != ("tuic-" + $group_tag + "-in") and
        .tag != ("vless-" + $group_tag + "-in")
      )] |

      (
        [] |
        if $hy2_port > 0 then . + [{
          "type": "hysteria2",
          "tag": ("hy2-" + $group_tag + "-in"),
          "listen": "::",
          "listen_port": $hy2_port,
          "users": [{"password": $uuid}],
          "masquerade": "https://www.bing.com",
          "ignore_client_bandwidth": false,
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $tuic_port > 0 then . + [{
          "type": "tuic",
          "tag": ("tuic-" + $group_tag + "-in"),
          "listen": "::",
          "listen_port": $tuic_port,
          "users": [{"uuid": $uuid, "password": $uuid}],
          "congestion_control": "bbr",
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $vless_port > 0 then . + [{
          "type": "vless",
          "tag": ("vless-" + $group_tag + "-in"),
          "listen": "::",
          "listen_port": $vless_port,
          "users": [{"uuid": $uuid, "flow": "xtls-rprx-vision"}],
          "tls": {
            "enabled": true,
            "server_name": $reym,
            "reality": {"enabled": true, "handshake": {"server": $reym, "server_port": 443}, "private_key": $reality_pvk, "short_id": [""]}
          }
        }] else . end
      ) as $new_inbounds |
      .inbounds += $new_inbounds |

      ($new_inbounds | map(.tag)) as $inbound_tags |

      .route.rules = ([.route.rules[] | select(.outbound != $out_tag)]) |
      if ($inbound_tags | length) > 0 then
        .route.rules = ([{"inbound": $inbound_tags, "outbound": $out_tag}] + .route.rules)
      else . end
      ' "$cfg" > "$tmp_json" && mv -f "$tmp_json" "$cfg"
    return $?
}

# ==================== 同步赛风副节点到 sing-box (纯 jq) ====================
sync_psiphon_instance_to_singbox() {
    local cc="${1^^}"
    local inst_dir="${PSI_INSTANCES_DIR}/${cc}"
    local cfg="$WORKDIR/sb.json"

    [[ -f "$cfg" ]] || return 1
    [[ -d "$inst_dir" ]] || return 1

    local hy2_port tuic_port vless_port socks_port uuid reality_pvk reym
    hy2_port=$(cat "$inst_dir/hy2_port.txt" 2>/dev/null || echo "0")
    tuic_port=$(cat "$inst_dir/tuic_port.txt" 2>/dev/null || echo "0")
    vless_port=$(cat "$inst_dir/vless_port.txt" 2>/dev/null || echo "0")
    socks_port=$(cat "$inst_dir/socks_port.txt" 2>/dev/null || echo "0")
    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.users[0].uuid != null) | .users[0].uuid' "$cfg" 2>/dev/null | head -n1)
    [[ -z "$uuid" ]] && uuid=$(jq -r '.inbounds[]? | select(.users[0].password != null) | .users[0].password' "$cfg" 2>/dev/null | head -n1)
    reality_pvk=$(cat "$WORKDIR/private_key.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.tls.reality.private_key != null) | .tls.reality.private_key' "$cfg" 2>/dev/null | head -n1)
    reym=$(cat "$WORKDIR/reym.txt" 2>/dev/null || echo "apple.com")
    local cc_lower=$(echo "$cc" | tr '[:upper:]' '[:lower:]')
    local out_tag="psiphon-${cc_lower}"

    local tmp_json
    tmp_json=$(mktemp)

    jq \
      --arg cc "$cc_lower" \
      --arg out_tag "$out_tag" \
      --argjson socks_port "${socks_port:-0}" \
      --argjson hy2_port "${hy2_port:-0}" \
      --argjson tuic_port "${tuic_port:-0}" \
      --argjson vless_port "${vless_port:-0}" \
      --arg uuid "$uuid" \
      --arg reality_pvk "$reality_pvk" \
      --arg reym "$reym" \
      '
      .outbounds = [.outbounds[] | select(.tag != $out_tag)] |
      if $socks_port > 0 then
        .outbounds += [{
          "type": "socks",
          "tag": $out_tag,
          "server": "127.0.0.1",
          "server_port": $socks_port,
          "version": "5",
          "network": "tcp"
        }]
      else . end |

      .inbounds = [.inbounds[] | select(
        .tag != ("hy2-psi-" + $cc + "-in") and
        .tag != ("tuic-psi-" + $cc + "-in") and
        .tag != ("vless-psi-" + $cc + "-in")
      )] |

      (
        [] |
        if $hy2_port > 0 then . + [{
          "type": "hysteria2",
          "tag": ("hy2-psi-" + $cc + "-in"),
          "listen": "::",
          "listen_port": $hy2_port,
          "users": [{"password": $uuid}],
          "masquerade": "https://www.bing.com",
          "ignore_client_bandwidth": false,
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $tuic_port > 0 then . + [{
          "type": "tuic",
          "tag": ("tuic-psi-" + $cc + "-in"),
          "listen": "::",
          "listen_port": $tuic_port,
          "users": [{"uuid": $uuid, "password": $uuid}],
          "congestion_control": "bbr",
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $vless_port > 0 then . + [{
          "type": "vless",
          "tag": ("vless-psi-" + $cc + "-in"),
          "listen": "::",
          "listen_port": $vless_port,
          "users": [{"uuid": $uuid, "flow": "xtls-rprx-vision"}],
          "tls": {
            "enabled": true,
            "server_name": $reym,
            "reality": {"enabled": true, "handshake": {"server": $reym, "server_port": 443}, "private_key": $reality_pvk, "short_id": [""]}
          }
        }] else . end
      ) as $new_inbounds |
      .inbounds += $new_inbounds |

      ($new_inbounds | map(.tag)) as $inbound_tags |

      .route.rules = ([.route.rules[] | select(.outbound != $out_tag)]) |
      if ($inbound_tags | length) > 0 and $socks_port > 0 then
        .route.rules = ([{"inbound": $inbound_tags, "outbound": $out_tag}] + .route.rules)
      else . end
      ' "$cfg" > "$tmp_json" && mv -f "$tmp_json" "$cfg"
    return $?
}

# ==================== 副节点全面自动同步函数 ====================
sync_all_secondary_nodes() {
    local cfg="$WORKDIR/sb.json"
    [[ -f "$cfg" ]] || return 0
    auto_migrate_legacy_nodes

    local psi_insts
    mapfile -t psi_insts < <(get_all_psiphon_instances 2>/dev/null)
    for cc in "${psi_insts[@]}"; do
        [[ -n "$cc" ]] && sync_psiphon_instance_to_singbox "$cc" >/dev/null 2>&1 || true
    done

    local proxy_tags
    mapfile -t proxy_tags < <(get_all_proxy_groups 2>/dev/null)
    for tag in "${proxy_tags[@]}"; do
        [[ -n "$tag" ]] && sync_proxy_group_to_singbox "$tag" >/dev/null 2>&1 || true
    done
}

# ==================== 主节点多协议配置与出站应用 ====================
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

    local tmp_json
    tmp_json=$(mktemp)

    jq \
      --arg warp_en "$warp_enabled" \
      --arg warp_mode "$warp_mode" \
      --arg warp_ep "$warp_endpoint" \
      --argjson warp_port "$warp_port" \
      --arg warp_pvk "$warp_pvk" \
      --arg warp_ipv6 "$warp_ipv6" \
      --argjson warp_res "$warp_res" \
      --arg psi_en "$psi_main_enabled" \
      --argjson psi_port "$psi_main_port" \
      '
      .outbounds = (.outbounds // []) |
      if any(.tag == "direct") then . else . + [{"type":"direct","tag":"direct"}] end |
      if any(.tag == "block") then . else . + [{"type":"block","tag":"block"}] end |
      
      .outbounds = [.outbounds[] | select(.tag != "warp-out" and .tag != "psiphon-main-out")] |
      
      .route.rules = [(.route.rules // [])[] | select(
        if .outbound == "warp-out" or .outbound == "psiphon-main-out" then
          if .inbound == ["socks-loopback"] or .geosite != null or .domain_suffix != null then false else true end
        else true end
      )] |
      
      if $warp_en == "true" and $warp_mode == "all" then
        .outbounds += [{
          "type": "wireguard",
          "tag": "warp-out",
          "server": $warp_ep,
          "server_port": $warp_port,
          "local_address": ["172.16.0.2/32", ($warp_ipv6 + "/128")],
          "private_key": $warp_pvk,
          "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "reserved": $warp_res
        }] |
        .route.rules += [{"inbound": ["socks-loopback"], "outbound": "warp-out"}] |
        .route.final = "warp-out"
      elif $warp_en == "true" and $warp_mode == "google" then
        .outbounds += [{
          "type": "wireguard",
          "tag": "warp-out",
          "server": $warp_ep,
          "server_port": $warp_port,
          "local_address": ["172.16.0.2/32", ($warp_ipv6 + "/128")],
          "private_key": $warp_pvk,
          "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "reserved": $warp_res
        }] |
        .route.rules += [
          {"inbound": ["socks-loopback"], "outbound": "warp-out"},
          {
            "geosite": ["google", "youtube", "netflix", "openai"],
            "domain_suffix": ["google.com", "googlevideo.com", "youtube.com", "netflix.com", "openai.com", "chatgpt.com"],
            "outbound": "warp-out"
          }
        ] |
        .route.final = "direct"
      elif $psi_en == "true" then
        .outbounds += [{
          "type": "socks",
          "tag": "psiphon-main-out",
          "server": "127.0.0.1",
          "server_port": $psi_port,
          "version": "5",
          "network": "tcp"
        }] |
        .route.rules += [{"inbound": ["socks-loopback"], "outbound": "psiphon-main-out"}] |
        .route.final = "psiphon-main-out"
      else
        .route.rules += [{"inbound": ["socks-loopback"], "outbound": "direct"}] |
        .route.final = "direct"
      end
      ' "$cfg" > "$tmp_json" && mv -f "$tmp_json" "$cfg"

    sync_all_secondary_nodes
    return 0
}

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

# ==================== 1. 主节点多协议配置管理 ====================
configure_main_node_protocols() {
    [[ -t 1 ]] && clear 2>/dev/null || true
    echo
    green "============================================================"
    green "  主节点多协议配置与端口管理"
    green "============================================================"
    yellow "  支持一键开启或单独定制各主流入站协议:"
    yellow "  - VLESS-Reality (TCP 抗封锁)"
    yellow "  - VMess-WS (支持 CDN / WebSocket / Argo)"
    yellow "  - Trojan-WS-TLS (伪装 HTTPS WebSocket)"
    yellow "  - Hysteria2 (UDP 高速加速)"
    yellow "  - TUIC v5 (QUIC 高性能)"
    yellow "  - AnyTLS (极简 TLS)"
    echo "============================================================"

    local cfg="$WORKDIR/sb.json"
    local cur_vless cur_vmess cur_trojan cur_hy2 cur_tuic cur_anytls
    cur_vless=$(jq -r '.inbounds[]? | select((.tag=="vless-in" or .tag=="vless-reality-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
    cur_vmess=$(jq -r '.inbounds[]? | select((.tag=="vmess-in" or .tag=="vmess-ws-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
    cur_trojan=$(jq -r '.inbounds[]? | select((.tag=="trojan-tls-in" or .tag=="trojan-ws-in" or .tag=="trojan-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
    cur_hy2=$(jq -r '.inbounds[]? | select((.tag=="hy2-in" or .tag=="hysteria2-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
    cur_tuic=$(jq -r '.inbounds[]? | select((.tag=="tuic-in" or .tag=="tuic-in-1") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
    cur_anytls=$(jq -r '.inbounds[]? | select((.tag=="anytls-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)

    purple "当前主节点已开启协议与端口:"
    [[ -n "$cur_vless" ]] && green "  [✓] VLESS-Reality : 端口 ${cur_vless}" || yellow "  [✗] VLESS-Reality : 未开启"
    [[ -n "$cur_vmess" ]] && green "  [✓] VMess-WS      : 端口 ${cur_vmess}" || yellow "  [✗] VMess-WS      : 未开启"
    [[ -n "$cur_trojan" ]] && green "  [✓] Trojan-WS-TLS : 端口 ${cur_trojan}" || yellow "  [✗] Trojan-WS-TLS : 未开启"
    [[ -n "$cur_hy2" ]] && green "  [✓] Hysteria2     : 端口 ${cur_hy2}" || yellow "  [✗] Hysteria2     : 未开启"
    [[ -n "$cur_tuic" ]] && green "  [✓] TUIC v5       : 端口 ${cur_tuic}" || yellow "  [✗] TUIC v5       : 未开启"
    [[ -n "$cur_anytls" ]] && green "  [✓] AnyTLS        : 端口 ${cur_anytls}" || yellow "  [✗] AnyTLS        : 未开启"
    echo "============================================================"

    echo
    echo "  1. 一键开启/更新全部 6 大主节点协议 (自动分配安全空闲端口)"
    echo "  2. 自定义选择开启/关闭各协议与指定端口"
    echo "  3. 重新生成 UUID 与 Reality 密钥对"
    echo "------------------------------------------------------------"
    echo "  0. 返回主菜单"
    echo "============================================================"
    reading "请选择 [0-3]: " p_choice

    case "$p_choice" in
        1)
            yellow "[*] 正在一键配置全部 6 大主节点协议..."
            local p_vless="${cur_vless:-$(get_free_port)}"
            local p_vmess="${cur_vmess:-$(get_free_port)}"
            local p_trojan="${cur_trojan:-$(get_free_port)}"
            local p_hy2="${cur_hy2:-$(get_free_port)}"
            local p_tuic="${cur_tuic:-$(get_free_port)}"
            local p_anytls="${cur_anytls:-$(get_free_port)}"
            local p_loop=$(get_free_loopback_port)

            build_and_apply_main_inbounds "$p_vless" "$p_vmess" "$p_trojan" "$p_hy2" "$p_tuic" "$p_anytls" "$p_loop"
            apply_main_node_outbound
            apply_changes
            green "[✓] 全部 6 大主节点协议已配置并成功运行！"
            echo
            get_all_ips >/dev/null 2>&1
            show_links
            ;;
        2)
            echo
            reading "开启 VLESS-Reality? (当前端口: ${cur_vless:-无}, 回车保留/留空禁用/输入端口): " inp_vless
            [[ -z "$inp_vless" && -n "$cur_vless" ]] && inp_vless="$cur_vless"
            [[ "$inp_vless" == "y" || "$inp_vless" == "Y" ]] && inp_vless=$(get_free_port)

            reading "开启 VMess-WS? (当前端口: ${cur_vmess:-无}, 回车保留/留空禁用/输入端口): " inp_vmess
            [[ -z "$inp_vmess" && -n "$cur_vmess" ]] && inp_vmess="$cur_vmess"
            [[ "$inp_vmess" == "y" || "$inp_vmess" == "Y" ]] && inp_vmess=$(get_free_port)

            reading "开启 Trojan-WS-TLS? (当前端口: ${cur_trojan:-无}, 回车保留/留空禁用/输入端口): " inp_trojan
            [[ -z "$inp_trojan" && -n "$cur_trojan" ]] && inp_trojan="$cur_trojan"
            [[ "$inp_trojan" == "y" || "$inp_trojan" == "Y" ]] && inp_trojan=$(get_free_port)

            reading "开启 Hysteria2? (当前端口: ${cur_hy2:-无}, 回车保留/留空禁用/输入端口): " inp_hy2
            [[ -z "$inp_hy2" && -n "$cur_hy2" ]] && inp_hy2="$cur_hy2"
            [[ "$inp_hy2" == "y" || "$inp_hy2" == "Y" ]] && inp_hy2=$(get_free_port)

            reading "开启 TUIC v5? (当前端口: ${cur_tuic:-无}, 回车保留/留空禁用/输入端口): " inp_tuic
            [[ -z "$inp_tuic" && -n "$cur_tuic" ]] && inp_tuic="$cur_tuic"
            [[ "$inp_tuic" == "y" || "$inp_tuic" == "Y" ]] && inp_tuic=$(get_free_port)

            reading "开启 AnyTLS? (当前端口: ${cur_anytls:-无}, 回车保留/留空禁用/输入端口): " inp_anytls
            [[ -z "$inp_anytls" && -n "$cur_anytls" ]] && inp_anytls="$cur_anytls"
            [[ "$inp_anytls" == "y" || "$inp_anytls" == "Y" ]] && inp_anytls=$(get_free_port)

            local p_loop=$(get_free_loopback_port)
            build_and_apply_main_inbounds "$inp_vless" "$inp_vmess" "$inp_trojan" "$inp_hy2" "$inp_tuic" "$inp_anytls" "$p_loop"
            apply_main_node_outbound
            apply_changes
            green "[✓] 主节点协议已更新！"
            echo
            get_all_ips >/dev/null 2>&1
            show_links
            ;;
        3)
            local new_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
            [[ -n "$new_uuid" ]] && echo "$new_uuid" > "$WORKDIR/UUID.txt"
            if [[ -x "$WORKDIR/sing-box" ]]; then
                local kp=$("$WORKDIR/sing-box" generate reality-keypair 2>/dev/null)
                local pvk=$(echo "$kp" | awk '/PrivateKey:/{print $2}' | tr -d '\r\n')
                local pbk=$(echo "$kp" | awk '/PublicKey:/{print $2}' | tr -d '\r\n')
                [[ -n "$pvk" ]] && echo "$pvk" > "$WORKDIR/private_key.txt"
                [[ -n "$pbk" ]] && echo "$pbk" > "$WORKDIR/public_key.txt"
            fi
            green "UUID 与 Reality 密钥对已刷新！请重新选择 1 或 2 应用配置。"
            ;;
        0) return 0 ;;
        *) red "无效选项" ;;
    esac
    echo
    reading "按回车继续..." _
}

build_and_apply_main_inbounds() {
    local p_vless="$1" p_vmess="$2" p_trojan="$3" p_hy2="$4" p_tuic="$5" p_anytls="$6" p_loop="$7"
    local cfg="$WORKDIR/sb.json"
    local uuid reality_pvk reym
    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.users[0].uuid != null) | .users[0].uuid' "$cfg" 2>/dev/null | head -n1)
    [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
    echo "$uuid" > "$WORKDIR/UUID.txt"

    reality_pvk=$(cat "$WORKDIR/private_key.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.tls.reality.private_key != null) | .tls.reality.private_key' "$cfg" 2>/dev/null | head -n1)
    if [[ -z "$reality_pvk" && -x "$WORKDIR/sing-box" ]]; then
        local kp=$("$WORKDIR/sing-box" generate reality-keypair 2>/dev/null)
        reality_pvk=$(echo "$kp" | awk '/PrivateKey:/{print $2}' | tr -d '\r\n')
        local pbk=$(echo "$kp" | awk '/PublicKey:/{print $2}' | tr -d '\r\n')
        echo "$reality_pvk" > "$WORKDIR/private_key.txt"
        echo "$pbk" > "$WORKDIR/public_key.txt"
    fi
    reym=$(cat "$WORKDIR/reym.txt" 2>/dev/null || echo "apple.com")

    if [[ ! -f "$WORKDIR/cert.pem" || ! -f "$WORKDIR/private.key" ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$WORKDIR/private.key" -out "$WORKDIR/cert.pem" -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1
    fi

    local tmp_json=$(mktemp)

    jq \
      --arg uuid "$uuid" \
      --arg reality_pvk "$reality_pvk" \
      --arg reym "$reym" \
      --argjson pv "${p_vless:-0}" \
      --argjson pvm "${p_vmess:-0}" \
      --argjson ptr "${p_trojan:-0}" \
      --argjson phy "${p_hy2:-0}" \
      --argjson ptu "${p_tuic:-0}" \
      --argjson pan "${p_anytls:-0}" \
      --argjson ploop "${p_loop:-20080}" \
      '
      # 保留所有副节点入站 (包含 custom / proxy / psi 的入站)
      .inbounds = [.inbounds[]? | select(.tag | contains("proxy") or contains("psi") or contains("custom"))] |

      (
        [] |
        if $pv > 0 then . + [{
          "tag": "vless-reality-in",
          "type": "vless",
          "listen": "::",
          "listen_port": $pv,
          "users": [{"uuid": $uuid, "flow": "xtls-rprx-vision"}],
          "tls": {
            "enabled": true,
            "server_name": $reym,
            "reality": {
              "enabled": true,
              "handshake": {"server": $reym, "server_port": 443},
              "private_key": $reality_pvk,
              "short_id": [""]
            }
          }
        }] else . end |
        if $pvm > 0 then . + [{
          "tag": "vmess-ws-in",
          "type": "vmess",
          "listen": "::",
          "listen_port": $pvm,
          "users": [{"uuid": $uuid}],
          "transport": {"type": "ws", "path": ("/" + $uuid + "-vm")}
        }] else . end |
        if $ptr > 0 then . + [{
          "tag": "trojan-ws-in",
          "type": "trojan",
          "listen": "::",
          "listen_port": $ptr,
          "users": [{"password": $uuid}],
          "transport": {"type": "ws", "path": ("/" + $uuid + "-tr")},
          "tls": {"enabled": true, "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $phy > 0 then . + [{
          "tag": "hy2-in",
          "type": "hysteria2",
          "listen": "::",
          "listen_port": $phy,
          "users": [{"password": $uuid}],
          "masquerade": "https://www.bing.com",
          "ignore_client_bandwidth": false,
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $ptu > 0 then . + [{
          "tag": "tuic-in",
          "type": "tuic",
          "listen": "::",
          "listen_port": $ptu,
          "users": [{"uuid": $uuid, "password": $uuid}],
          "congestion_control": "bbr",
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $pan > 0 then . + [{
          "tag": "anytls-in",
          "type": "anytls",
          "listen": "::",
          "listen_port": $pan,
          "users": [{"password": $uuid}],
          "tls": {"enabled": true, "server_name": "www.bing.com", "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        . + [{
          "tag": "socks-loopback",
          "type": "socks",
          "listen": "127.0.0.1",
          "listen_port": $ploop
        }]
      ) as $main_inbounds |
      .inbounds = $main_inbounds + .inbounds
      ' "$cfg" > "$tmp_json" && mv -f "$tmp_json" "$cfg"

    sync_all_secondary_nodes
}

# ==================== 2. 主节点出站管理子菜单 ====================
configure_warp_outbound() {
    [[ -t 1 ]] && clear 2>/dev/null || true
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

# ==================== 3. 副节点 - 自定义代理出站管理 ====================
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
        1)
            read_valid_port "请输入 Hysteria2 入站端口 [回车自动分配]: " "$(get_free_port)" hy2_p
            ;;
        2)
            read_valid_port "请输入 TUIC v5 入站端口 [回车自动分配]: " "$(get_free_port)" tuic_p
            ;;
        3)
            read_valid_port "请输入 VLESS-Reality 入站端口 [回车自动分配]: " "$(get_free_port)" vless_p
            ;;
        *)
            read_valid_port "请输入 Hysteria2 入站端口 [回车自动分配]: " "$(get_free_port)" hy2_p
            read_valid_port "请输入 TUIC v5 入站端口 [回车自动分配]: " "$(get_free_port)" tuic_p
            ;;
    esac

    local gdir="${PROXY_GROUPS_DIR}/${group_tag}"
    mkdir -p "$gdir"
    echo "$remark" > "$gdir/remark.txt"
    echo "$proxy_url" > "$gdir/raw_url.txt"
    echo "$out_json" > "$gdir/outbound.json"
    echo "$hy2_p" > "$gdir/hy2_port.txt"
    echo "$tuic_p" > "$gdir/tuic_port.txt"
    echo "$vless_p" > "$gdir/vless_port.txt"
    echo "$group_tag" >> "$PROXY_GROUPS_DIR/groups.txt"

    sync_proxy_group_to_singbox "$group_tag"
    apply_changes

    green "[✓] 代理节点组 [$remark] 添加成功！"
    generate_proxy_group_links "$group_tag"
}

generate_proxy_group_links() {
    local tag="$1"
    [[ -z "$tag" ]] && return 1
    local gdir="${PROXY_GROUPS_DIR}/${tag}"
    [[ -d "$gdir" ]] || return 1

    local remark hy2_p tuic_p vless_p uuid ip
    remark=$(cat "$gdir/remark.txt" 2>/dev/null || echo "$tag")
    hy2_p=$(cat "$gdir/hy2_port.txt" 2>/dev/null || echo "0")
    tuic_p=$(cat "$gdir/tuic_port.txt" 2>/dev/null || echo "0")
    vless_p=$(cat "$gdir/vless_port.txt" 2>/dev/null || echo "0")
    if [[ "$hy2_p" == "0" && "$tuic_p" == "0" && "$vless_p" == "0" ]]; then
        return 0
    fi
    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.users[0].uuid != null) | .users[0].uuid' "$WORKDIR/sb.json" 2>/dev/null | head -n1)
    [[ -z "$uuid" ]] && uuid=$(jq -r '.inbounds[]? | select(.users[0].password != null) | .users[0].password' "$WORKDIR/sb.json" 2>/dev/null | head -n1)
    ip="${ALL_IPS[0]:-202.73.4.182}"

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
        local pbk=$(cat "$WORKDIR/public_key.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.tls.reality.public_key != null) | .tls.reality.public_key' "$WORKDIR/sb.json" 2>/dev/null | head -n1)
        local reym=$(cat "$WORKDIR/reym.txt" 2>/dev/null || echo "apple.com")
        local vless_link="vless://${uuid}@${ip}:${vless_p}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reym}&fp=chrome&pbk=${pbk}&sid=#${remark}-Reality"
        green "3. VLESS-Reality 节点链接:"
        echo "   $vless_link"
    fi
    blue "============================================================"
}

proxy_egress_menu() {
    auto_migrate_legacy_nodes
    while true; do
        [[ -t 1 ]] && clear 2>/dev/null || true
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
                        local tmp_j=$(mktemp)
                        jq --arg dt "$del_tag" '
                        .outbounds = [.outbounds[] | select(.tag != ($dt + "-out"))] |
                        .inbounds = [.inbounds[] | select(.tag | contains($dt) | not)] |
                        .route.rules = [.route.rules[] | select(.outbound != ($dt + "-out"))]
                        ' "$WORKDIR/sb.json" > "$tmp_j" && mv -f "$tmp_j" "$WORKDIR/sb.json"
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

# ==================== 4. 副节点 - 赛风多出口管理 ====================
# ==================== 4. Psiphon 赛风综合管理模块 ====================

psiphon_check_current_ip() {
    echo
    purple "[*] 正在检测当前 Psiphon 赛风出口网络状态..."
    local socks_port
    socks_port=$(cat "$WORKDIR/psiphon_socks_port.txt" 2>/dev/null || echo "20800")
    local psi_pid
    psi_pid=$(cat "$WORKDIR/psiphon.pid" 2>/dev/null)

    if [[ -z "$psi_pid" ]] || ! kill -0 "$psi_pid" 2>/dev/null; then
        yellow "[!] Psiphon 主进程未运行，正在启动..."
        start_main_psiphon
        sleep 2
    fi

    local ip info
    ip=$(curl -sx "socks5h://127.0.0.1:${socks_port}" -s4m6 https://api.ipify.org 2>/dev/null || curl -sx "socks5h://127.0.0.1:${socks_port}" -s4m6 https://ip.sb 2>/dev/null)
    if [[ -n "$ip" ]]; then
        green "============================================================"
        green "  [✓] Psiphon 当前出口 IP : $ip"
        info=$(curl -sx "socks5h://127.0.0.1:${socks_port}" -s4m5 "https://api.ip.sb/geoip/${ip}" 2>/dev/null)
        if [[ -n "$info" ]]; then
            local country region city isp
            country=$(echo "$info" | jq -r '.country // empty' 2>/dev/null)
            region=$(echo "$info" | jq -r '.region // empty' 2>/dev/null)
            city=$(echo "$info" | jq -r '.city // empty' 2>/dev/null)
            isp=$(echo "$info" | jq -r '.isp // empty' 2>/dev/null)
            blue  "      出口国家 / 地区 : ${country} - ${region} ${city}"
            blue  "      网络运营商 (ISP): ${isp}"
        fi
        green "============================================================"
    else
        red "[!] 检测超时或 Psiphon 连接尚未建立就绪，请稍后重试或查看日志。"
    fi
}

psiphon_switch_auto() {
    echo
    yellow "[*] 正在切换 Psiphon 为智能自动选择 (AUTO 优选)..."
    echo "AUTO" > "$WORKDIR/psiphon_main_region.txt"
    stop_main_psiphon
    start_main_psiphon
    apply_main_node_outbound
    apply_changes
    green "[✓] 已切换为智能自动选择！正在获取新出口 IP..."
    sleep 3
    psiphon_check_current_ip
}

psiphon_switch_manual() {
    echo
    green "==== 手动切换 Psiphon 出口国家 ===="
    show_supported_psiphon_codes
    echo
    reading "请输入目标国家代码 (如 US, JP, SG, HK, GB, DE 等): " target_cc
    target_cc="${target_cc^^}"
    [[ -z "$target_cc" ]] && { red "[!] 国家代码不能为空"; return 1; }

    echo "$target_cc" > "$WORKDIR/psiphon_main_region.txt"
    stop_main_psiphon
    start_main_psiphon
    apply_main_node_outbound
    apply_changes
    green "[✓] 已切换出口国家为 [$target_cc - $(get_country_name "$target_cc")]！"
    sleep 3
    psiphon_check_current_ip
}

test_single_psiphon_country() {
    local cc="${1^^}"
    local cname=$(get_country_name "$cc")
    local test_port=$(get_free_loopback_port)
    local test_dir="/tmp/psi_test_${cc}_$$"
    mkdir -p "$test_dir/data"

    local cfg_file="$test_dir/psiphon.config"
    write_psiphon_config "$test_port" "$cc" "$cfg_file" "$test_dir/data"

    nohup "$WORKDIR/psiphon-tunnel-core" --config "$cfg_file" > "$test_dir/test.log" 2>&1 &
    local test_pid=$!
    disown "$test_pid" 2>/dev/null || true

    local egress_ip="" is_ok=false
    for i in {1..16}; do
        sleep 0.5
        if curl -sx "socks5h://127.0.0.1:${test_port}" -s4m2 https://api.ipify.org >/dev/null 2>&1 || \
           curl -sx "socks5h://127.0.0.1:${test_port}" -s4m2 https://ip.sb >/dev/null 2>&1; then
            egress_ip=$(curl -sx "socks5h://127.0.0.1:${test_port}" -s4m3 https://api.ipify.org 2>/dev/null || curl -sx "socks5h://127.0.0.1:${test_port}" -s4m3 https://ip.sb 2>/dev/null)
            is_ok=true
            break
        fi
    done

    kill -9 "$test_pid" 2>/dev/null || true
    rm -rf "$test_dir"

    if $is_ok; then
        green "  [✓] [$cc] $cname -> 出口 IP: ${egress_ip} (连接可用)"
        return 0
    else
        yellow "  [✗] [$cc] $cname -> 连接超时或未通"
        return 1
    fi
}

psiphon_quick_test() {
    echo
    green "==== 快速测试常用国家 (US / JP / SG / HK) ===="
    yellow "[*] 正在建立测试隧道，请稍候..."
    echo
    local quick_list=("US" "JP" "SG" "HK")
    for cc in "${quick_list[@]}"; do
        test_single_psiphon_country "$cc"
    done
    echo
    green "[✓] 快速测试完毕！"
}

psiphon_test_all() {
    echo
    green "==== 测试所有支持的 Psiphon 出口国家 ===="
    yellow "[*] 正在逐个检测国家可用性与出口 IP (共 28 个出口国家)..."
    echo
    local all_list=(
        "US" "JP" "SG" "HK" "KR" "TW"
        "GB" "DE" "CA" "NL" "FR" "IN" "AU"
        "CH" "SE" "IT" "ES" "PL" "AT" "BE" "DK" "NO" "RO" "CZ" "HU" "BG" "IE" "FI"
    )
    for cc in "${all_list[@]}"; do
        test_single_psiphon_country "$cc"
    done
    echo
    green "[✓] 全部国家测试完毕！"
}

psiphon_custom_test() {
    echo
    green "==== 自定义测试 Psiphon 出口国家 ===="
    show_supported_psiphon_codes
    echo
    reading "请输入要测试的国家代码 (如 KR, TW, NL, DE 等): " custom_cc
    custom_cc="${custom_cc^^}"
    [[ -z "$custom_cc" ]] && { red "[!] 国家代码不能为空"; return 1; }
    echo
    yellow "[*] 正在测试 [$custom_cc]..."
    test_single_psiphon_country "$custom_cc"
}

psiphon_view_log() {
    echo
    green "========== Psiphon 运行日志 (最近 30 行) =========="
    tail -n 30 "$WORKDIR/psiphon.log" 2>/dev/null || yellow "日志为空"
    echo "==================================================="
}

psiphon_restart() {
    echo
    yellow "[*] 正在重启 Psiphon 主进程..."
    stop_main_psiphon
    start_main_psiphon
    green "[✓] Psiphon 主进程已重启！"
    sleep 2
    psiphon_check_current_ip
}

add_psiphon_instance() {
    download_psiphon_core || return 1
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

    nohup "$WORKDIR/psiphon-tunnel-core" --config "$cfg_file" >> "$inst_dir/psiphon.log" 2>&1 &
    echo $! > "$inst_dir/psiphon.pid"
    echo "$socks_p" > "$inst_dir/socks_port.txt"

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
        1)
            read_valid_port "请输入 Hysteria2 入站端口 [回车自动分配]: " "$(get_free_port)" hy2_p
            ;;
        2)
            read_valid_port "请输入 TUIC v5 入站端口 [回车自动分配]: " "$(get_free_port)" tuic_p
            ;;
        3)
            read_valid_port "请输入 VLESS-Reality 入站端口 [回车自动分配]: " "$(get_free_port)" vless_p
            ;;
        *)
            read_valid_port "请输入 Hysteria2 入站端口 [回车自动分配]: " "$(get_free_port)" hy2_p
            read_valid_port "请输入 TUIC v5 入站端口 [回车自动分配]: " "$(get_free_port)" tuic_p
            ;;
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
    [[ -z "$cc" ]] && return 1
    local inst_dir="${PSI_INSTANCES_DIR}/${cc}"
    [[ -d "$inst_dir" ]] || return 1

    local hy2_p tuic_p vless_p uuid ip cname
    hy2_p=$(cat "$inst_dir/hy2_port.txt" 2>/dev/null || echo "0")
    tuic_p=$(cat "$inst_dir/tuic_port.txt" 2>/dev/null || echo "0")
    vless_p=$(cat "$inst_dir/vless_port.txt" 2>/dev/null || echo "0")
    if [[ "$hy2_p" == "0" && "$tuic_p" == "0" && "$vless_p" == "0" ]]; then
        return 0
    fi
    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.users[0].uuid != null) | .users[0].uuid' "$WORKDIR/sb.json" 2>/dev/null | head -n1)
    [[ -z "$uuid" ]] && uuid=$(jq -r '.inbounds[]? | select(.users[0].password != null) | .users[0].password' "$WORKDIR/sb.json" 2>/dev/null | head -n1)
    ip="${ALL_IPS[0]:-202.73.4.182}"
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
        local pbk=$(cat "$WORKDIR/public_key.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.tls.reality.public_key != null) | .tls.reality.public_key' "$WORKDIR/sb.json" 2>/dev/null | head -n1)
        local reym=$(cat "$WORKDIR/reym.txt" 2>/dev/null || echo "apple.com")
        local vless_link="vless://${uuid}@${ip}:${vless_p}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reym}&fp=chrome&pbk=${pbk}&sid=#Psi-${cc}-Reality"
        green "3. VLESS-Reality 节点链接:"
        echo "   $vless_link"
    fi
    purple "============================================================"
}

psiphon_multigroup_menu() {
    auto_migrate_legacy_nodes
    while true; do
        [[ -t 1 ]] && clear 2>/dev/null || true
        echo
        green "============================================================"
        green "  【副节点】Psiphon 赛风多出口节点组管理"
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
                [[ -z "$cc" ]] && continue
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
        green  "  1. 添加赛风国家出口组 (支持自定义入站端口)"
        green  "  2. 查看所有赛风出口组节点链接"
        red    "  3. 删除赛风国家出口组"
        blue   "  4. 重启所有赛风实例"
        echo "------------------------------------------------------------"
        red    "  0. 返回上一级菜单"
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
                        local tmp_j=$(mktemp)
                        jq --arg cc "${del_cc,,}" '
                        .outbounds = [.outbounds[] | select(.tag != ("psiphon-" + $cc))] |
                        .inbounds = [.inbounds[] | select(.tag | contains($cc) | not)] |
                        .route.rules = [.route.rules[] | select(.outbound != ("psiphon-" + $cc))]
                        ' "$WORKDIR/sb.json" > "$tmp_j" && mv -f "$tmp_j" "$WORKDIR/sb.json"
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

psiphon_management_menu() {
    while true; do
        [[ -t 1 ]] && clear 2>/dev/null || true
        echo
        green "============================================================"
        green "  【Psiphon 赛风综合管理】"
        green "============================================================"
        local psi_pid=$(cat "$WORKDIR/psiphon.pid" 2>/dev/null)
        local cur_reg=$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null || echo "AUTO")
        local cur_sport=$(cat "$WORKDIR/psiphon_socks_port.txt" 2>/dev/null || echo "20800")

        if [[ -n "$psi_pid" ]] && kill -0 "$psi_pid" 2>/dev/null; then
            green "  状态: [✓ 已启动] | 当前国家: [$cur_reg - $(get_country_name "$cur_reg")] | 本地Socks端口: [$cur_sport]"
        else
            yellow "  状态: [✗ 未运行] | 预设国家: [$cur_reg - $(get_country_name "$cur_reg")] | 本地Socks端口: [$cur_sport]"
        fi
        green "============================================================"
        echo
        echo "  1. 查看当前出口 IP"
        echo "  2. 智能切换出口国家 (自动优选)"
        echo "  3. 手动切换出口国家"
        echo "------------------------------------------------------------"
        echo "  4. 快速测试国家 (US/JP/SG/HK)"
        echo "  5. 测试所有支持国家"
        echo "  6. 自定义测试国家"
        echo "------------------------------------------------------------"
        echo "  7. 查看 Psiphon 日志"
        echo "  8. 重启 Psiphon"
        echo "  9. 多出口节点组管理 (独立入站副节点管理)"
        echo "------------------------------------------------------------"
        red  "  0. 返回主菜单"
        echo "============================================================"
        reading "请选择 [0-9]: " choice

        case "$choice" in
            1) psiphon_check_current_ip ;;
            2) psiphon_switch_auto ;;
            3) psiphon_switch_manual ;;
            4) psiphon_quick_test ;;
            5) psiphon_test_all ;;
            6) psiphon_custom_test ;;
            7) psiphon_view_log ;;
            8) psiphon_restart ;;
            9) psiphon_multigroup_menu ;;
            0) return 0 ;;
            *) red "无效选项" ;;
        esac
        echo
        reading "按回车继续..." _
    done
}

# ==================== 5. 查看主节点信息与全部汇总 ====================
show_links() {
    get_all_ips >/dev/null 2>&1
    local cfg="$WORKDIR/sb.json"
    local uuid ip pbk sid reym
    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.users[0].uuid != null) | .users[0].uuid' "$cfg" 2>/dev/null | head -n1)
    [[ -z "$uuid" ]] && uuid=$(jq -r '.inbounds[]? | select(.users[0].password != null) | .users[0].password' "$cfg" 2>/dev/null | head -n1)
    ip="${ALL_IPS[0]:-202.73.4.182}"
    pbk=$(cat "$WORKDIR/public_key.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.tls.reality.public_key != null) | .tls.reality.public_key' "$cfg" 2>/dev/null | head -n1)
    sid=$(cat "$WORKDIR/short_id.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.tls.reality.short_id != null) | .tls.reality.short_id[0] // empty' "$cfg" 2>/dev/null | head -n1)
    reym=$(cat "$WORKDIR/reym.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.tls.reality.handshake.server != null) | .tls.reality.handshake.server' "$cfg" 2>/dev/null | head -n1)
    [[ -z "$reym" ]] && reym="apple.com"

    green "=================================================="
    green "         Sing-box 主节点信息"
    green "=================================================="
    echo "UUID / Password: $uuid"
    echo

    # 兼容历史各种主入站 tag 命名
    local vless_p=$(jq -r '.inbounds[]? | select((.tag=="vless-in" or .tag=="vless-reality-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
    local vmess_p=$(jq -r '.inbounds[]? | select((.tag=="vmess-in" or .tag=="vmess-ws-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
    local vmess_path=$(jq -r '.inbounds[]? | select((.tag=="vmess-in" or .tag=="vmess-ws-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .transport.path // empty' "$cfg" 2>/dev/null | head -n1)
    [[ -z "$vmess_path" ]] && vmess_path="/${uuid}-vm"
    local trojan_p=$(jq -r '.inbounds[]? | select((.tag=="trojan-tls-in" or .tag=="trojan-ws-in" or .tag=="trojan-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
    local trojan_path=$(jq -r '.inbounds[]? | select((.tag=="trojan-tls-in" or .tag=="trojan-ws-in" or .tag=="trojan-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .transport.path // empty' "$cfg" 2>/dev/null | head -n1)
    [[ -z "$trojan_path" ]] && trojan_path="/${uuid}-tr"
    local hy2_p=$(jq -r '.inbounds[]? | select((.tag=="hy2-in" or .tag=="hysteria2-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
    local tuic_p=$(jq -r '.inbounds[]? | select((.tag=="tuic-in" or .tag=="tuic-in-1") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)
    local anytls_p=$(jq -r '.inbounds[]? | select((.tag=="anytls-in") and (.tag | contains("custom") or contains("proxy") or contains("psi") | not)) | .listen_port // empty' "$cfg" 2>/dev/null | head -n1)

    [[ -n "$vless_p" ]] && echo "1. VLESS-Reality: vless://${uuid}@${ip}:${vless_p}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reym}&fp=chrome&pbk=${pbk}&sid=${sid}#SB-VLESS-Reality"
    [[ -n "$vmess_p" ]] && echo "2. VMess-WS: $(make_vmess_link "{\"v\":\"2\",\"ps\":\"SB-VMess\",\"add\":\"${ip}\",\"port\":\"${vmess_p}\",\"id\":\"${uuid}\",\"net\":\"ws\",\"path\":\"${vmess_path}\"}")"
    [[ -n "$trojan_p" ]] && echo "3. Trojan-WS-TLS: trojan://${uuid}@${ip}:${trojan_p}?security=tls&sni=www.bing.com&allowInsecure=1&type=ws&path=$(url_encode "${trojan_path}")#SB-Trojan-TLS"
    [[ -n "$hy2_p" ]] && echo "4. Hysteria2: hysteria2://${uuid}@${ip}:${hy2_p}?insecure=1&sni=www.bing.com#SB-Hysteria2"
    [[ -n "$tuic_p" ]] && echo "5. TUIC v5: tuic://${uuid}:${uuid}@${ip}:${tuic_p}?alpn=h3&congestion_control=bbr&udp_relay=1&allow_insecure=1#SB-TUIC-v5"
    [[ -n "$anytls_p" ]] && echo "6. AnyTLS: anytls://${uuid}@${ip}:${anytls_p}?security=tls&sni=www.bing.com&allowInsecure=1#SB-AnyTLS"

    # 检查 Argo
    local argo_d=""
    if [[ -f /etc/s-box/argo.log ]]; then
        argo_d=$(head -n 1 /etc/s-box/argo.log 2>/dev/null)
    elif [[ -f /var/log/argo-tunnel.log ]]; then
        argo_d=$(grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' /var/log/argo-tunnel.log 2>/dev/null | tail -n 1)
    fi
    if [[ -n "$argo_d" ]]; then
        echo
        purple "--- Argo 隧道穿透节点 ---"
        echo "Argo 域名: $argo_d"
        echo "Argo VMess (80): $(make_vmess_link "{\"v\":\"2\",\"ps\":\"SB-VMess-Argo-80\",\"add\":\"${argo_d}\",\"port\":\"80\",\"id\":\"${uuid}\",\"net\":\"ws\",\"host\":\"${argo_d}\",\"path\":\"${vmess_path}\"}")"
        echo "Argo VMess (443/TLS): $(make_vmess_link "{\"v\":\"2\",\"ps\":\"SB-VMess-Argo-443\",\"add\":\"${argo_d}\",\"port\":\"443\",\"id\":\"${uuid}\",\"net\":\"ws\",\"tls\":\"tls\",\"sni\":\"${argo_d}\",\"host\":\"${argo_d}\",\"path\":\"${vmess_path}\"}")"
    fi
    green "=================================================="
}

show_all_nodes_summary() {
    [[ -t 1 ]] && clear 2>/dev/null || true
    get_all_ips >/dev/null 2>&1
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

custom_push_nodes() {
    [[ -t 1 ]] && clear 2>/dev/null || true
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
        [[ -t 1 ]] && clear 2>/dev/null || true
        echo
        green "============================================================"
        green "  主节点 Argo 隧道管理 (Cloudflare Tunnel)"
        green "============================================================"
        echo
        if service_is_active argo-tunnel; then
            green "【Argo 状态】: ✓ 运行中"
            local argo_d=""
            if [[ -f /etc/s-box/argo.log ]]; then
                argo_d=$(head -n 1 /etc/s-box/argo.log 2>/dev/null)
            elif [[ -f /var/log/argo-tunnel.log ]]; then
                argo_d=$(grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' /var/log/argo-tunnel.log 2>/dev/null | tail -n 1)
            fi
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
        [[ -t 1 ]] && clear 2>/dev/null || true
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
run_cron_check() {
    local log_file="/etc/s-box/monitor.log"
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

    if [[ -f "$WORKDIR/psiphon_main_enabled.txt" && "$(cat "$WORKDIR/psiphon_main_enabled.txt")" == "true" ]]; then
        local pid=$(cat "$WORKDIR/psiphon.pid" 2>/dev/null)
        if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
            start_main_psiphon
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [自愈守护] Psiphon 主进程未运行，已自动拉起！" >> "$log_file"
        fi
    fi
}

# ==================== 快捷命令同步更新 ====================
create_sb_tool() {
    mkdir -p /usr/local/bin "$WORKDIR"
    cp -f "${BASH_SOURCE[0]:-$0}" "$WORKDIR/install.sh" 2>/dev/null || true
    cp -f "${BASH_SOURCE[0]:-$0}" /usr/local/bin/sb 2>/dev/null || true
    chmod +x /usr/local/bin/sb "$WORKDIR/install.sh" 2>/dev/null || true
}

# ==================== 主菜单 ====================
menu() {
    auto_migrate_legacy_nodes
    create_sb_tool
    while true; do
        [[ -t 1 ]] && clear 2>/dev/null || true
        echo
        green "============================================================"
        green "  Sing-box Linux 多协议节点管理脚本 v${SCRIPT_VERSION}"
        green "============================================================"
        purple "  支持协议: Argo, VLESS-Reality, VMess, Trojan, Hy2, TUIC, AnyTLS"
        echo "============================================================"

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

        if [ -f "$WORKDIR/sb.json" ]; then
            if service_is_active sing-box; then
                green "【主节点状态】: ✓ 已安装并运行中"
            else
                yellow "【主节点状态】: ⚠ 已安装但未运行"
            fi

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

            local psi_insts
            mapfile -t psi_insts < <(get_all_psiphon_instances 2>/dev/null)
            if [[ ${#psi_insts[@]} -gt 0 ]]; then
                purple "【副节点-赛风】: ✓ 已配置 ${#psi_insts[@]} 个国家出口组 (${psi_insts[*]})"
            else
                purple "【副节点-赛风】: ✗ 未配置"
            fi

            local proxy_tags
            mapfile -t proxy_tags < <(get_all_proxy_groups 2>/dev/null)
            if [[ ${#proxy_tags[@]} -gt 0 ]]; then
                purple "【副节点-代理】: ✓ 已配置 ${#proxy_tags[@]} 个代理出口组 (${proxy_tags[*]})"
            else
                purple "【副节点-代理】: ✗ 未配置"
            fi

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
        purple "  5. Psiphon 赛风综合管理 (出口IP/国家切换/国家测速/多出口节点组)"
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
            1) configure_main_node_protocols ;;
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

# ==================== 初次安装 / 部署主流程 ====================
install_singbox_main() {
    log_info "开始安装/更新 Sing-box 环境与依赖..."

    install_system_dependencies
    mkdir -p "$WORKDIR" "$PROXY_GROUPS_DIR" "$PSI_INSTANCES_DIR"

    download_singbox_core || { red "Sing-box 核心下载失败"; exit 1; }
    download_cloudflared_core
    download_psiphon_core

    local UUID
    UUID=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.users[0].uuid != null) | .users[0].uuid' "$WORKDIR/sb.json" 2>/dev/null | head -n1)
    [[ -z "$UUID" || "$UUID" == "null" ]] && UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "a3b8c2d1-e5f6-4a7b-8c9d-0e1f2a3b4c5d")
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
    [[ ! -f "$WORKDIR/reym.txt" ]] && echo "apple.com" > "$WORKDIR/reym.txt"
    [[ ! -f "$WORKDIR/short_id.txt" ]] && echo "" > "$WORKDIR/short_id.txt"

    get_all_ips >/dev/null 2>&1

    # 如果没有现有 sb.json，才重新生成默认 6 大协议端口
    if [[ ! -f "$WORKDIR/sb.json" ]]; then
        local PORT_VLESS=$(get_free_port)
        local PORT_VMESS=$(get_free_port)
        local PORT_TROJAN_TLS=$(get_free_port)
        local PORT_HY2=$(get_free_port)
        local PORT_TUIC=$(get_free_port)
        local PORT_ANYTLS=$(get_free_port)
        local PORT_LOOPBACK=$(get_free_loopback_port)

        local REALITY_PVK=$(cat "$WORKDIR/private_key.txt" 2>/dev/null)

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
    fi

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

    create_sb_tool
    auto_migrate_legacy_nodes
    sync_all_secondary_nodes
    service_start sing-box

    if ! crontab -l 2>/dev/null | grep -q "sb cron"; then
        (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/sb cron >> /etc/s-box/monitor.log 2>&1") | crontab - 2>/dev/null || true
    fi

    log_info "Sing-box 安装与部署完成！"
    echo
    show_links
    echo
    log_info "快捷管理命令: 【 sb 】"
}

# ==================== 入口调度与 CLI 支持 ====================
case "$1" in
    cron)
        run_cron_check
        exit 0
        ;;
    show|links|info)
        show_links
        exit 0
        ;;
    all)
        show_all_nodes_summary
        exit 0
        ;;
    restart)
        service_restart sing-box
        sync_all_secondary_nodes
        apply_changes
        green "已重启 Sing-box 并同步配置！"
        exit 0
        ;;
    reconfig)
        configure_main_node_protocols
        exit 0
        ;;
    *)
        if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
            if [[ ! -f "$WORKDIR/sb.json" ]]; then
                install_singbox_main
            else
                menu
            fi
        fi
        ;;
esac
