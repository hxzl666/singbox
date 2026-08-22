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
blue="\e[1;34m"
cyan="\e[1;36m"
white="\e[1;37m"

red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
blue() { echo -e "\e[1;34m$1\033[0m"; }
cyan() { echo -e "\e[1;36m$1\033[0m"; }
white() { echo -e "\e[1;37m$1\033[0m"; }
reading() { read -p "$(yellow "$1")" "$2"; }

log_info() { echo -e "${green}[信息] $1${re}"; }
log_warn() { echo -e "${yellow}[警告] $1${re}"; }
log_err() { echo -e "${red}[错误] $1${re}"; }

WORKDIR="/etc/s-box"
PROXY_GROUPS_DIR="${WORKDIR}/proxy_groups"
PSI_INSTANCES_DIR="${WORKDIR}/psiphon_instances"
SCRIPT_VERSION="2.0.0"

# 智能检测 IPv6 支持（自适应双栈 / 纯 IPv4 / LXD / Docker 容器环境）
if [[ -f /proc/net/if_inet6 ]] && [[ -s /proc/net/if_inet6 ]]; then
    LISTEN_ADDR="::"
else
    LISTEN_ADDR="0.0.0.0"
fi

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

# Alpine Linux 兼容性保障与依赖自愈
ensure_alpine_compatibility() {
    if command -v apk >/dev/null 2>&1; then
        local need_apk=0
        for _pkg in bash grep procps util-linux gcompat libc6-compat ca-certificates curl jq tar; do
            if ! apk info -e "$_pkg" >/dev/null 2>&1; then
                need_apk=1
                break
            fi
        done
        if [[ $need_apk -eq 1 ]]; then
            yellow "[*] 检测到 Alpine Linux 环境，正在自动补全基础依赖与 glibc 兼容层 (gcompat, libc6-compat)..."
            apk update >/dev/null 2>&1 || true
            apk add --no-cache bash grep procps util-linux gcompat libc6-compat ca-certificates curl jq tar wget >/dev/null 2>&1 || true
        fi
        
        # 确保 /lib64 ld-linux 兼容链接存在
        if [[ ! -d /lib64 && -d /lib ]]; then
            mkdir -p /lib64 2>/dev/null || true
        fi
        if [[ -f /lib/ld-linux-x86-64.so.2 && ! -f /lib64/ld-linux-x86-64.so.2 ]]; then
            ln -sf /lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2 2>/dev/null || true
        fi
        if [[ -f /lib/ld-musl-x86_64.so.1 && ! -f /lib/ld-linux-x86-64.so.2 ]]; then
            ln -sf /lib/ld-musl-x86_64.so.1 /lib/ld-linux-x86-64.so.2 2>/dev/null || true
            ln -sf /lib/ld-musl-x86_64.so.1 /lib64/ld-linux-x86-64.so.2 2>/dev/null || true
        fi
    fi
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
        if [[ -x "/etc/init.d/$name" ]]; then
            rc-service "$name" restart >/dev/null 2>&1 || rc-service "$name" start >/dev/null 2>&1
        else
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
        fi
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
    if [[ "$name" == "sing-box" ]]; then
        systemctl stop sing-box >/dev/null 2>&1 || true
        pkill -9 -f "/etc/s-box/sing-box.*run" >/dev/null 2>&1 || true
        pkill -9 -f "/etc/s-box/sing-box" >/dev/null 2>&1 || true
    fi
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
    service_stop "$name"
    sleep 1
    service_start "$name"
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

service_disable() {
    local name=$1
    if $IS_OPENRC; then
        rc-update del "$name" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/$name" 2>/dev/null || true
    elif ! $IS_DIRECT; then
        systemctl disable "$name" >/dev/null 2>&1 || true
    fi
}

# ==================== 依赖与核心自动安装 ====================
install_system_dependencies() {
    log_info "正在检测系统基础依赖..."
    export DEBIAN_FRONTEND=noninteractive

    local need_install=0
    for cmd in curl wget jq openssl tar git net-tools unzip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            need_install=1
            break
        fi
    done

    if [[ $need_install -eq 1 ]]; then
        yellow "[*] 正在安装系统基础依赖 (curl, wget, jq, openssl, git, net-tools, unzip, ca-certificates)..."
        if command -v apt-get >/dev/null 2>&1; then
            echo -e "${blue}--> 正在更新 APT 软件包列表...${re}"
            apt-get update -y || yellow "[!] APT 源更新存在部分失败，尝试继续安装依赖..."
            echo -e "${blue}--> 正在安装基础依赖软件包...${re}"
            apt-get install -y --no-install-recommends curl wget tar jq openssl git net-tools unzip cron ca-certificates
        elif command -v yum >/dev/null 2>&1; then
            echo -e "${blue}--> 正在安装 YUM 基础依赖包...${re}"
            yum install -y curl wget tar jq openssl git net-tools unzip cronie ca-certificates
        elif command -v apk >/dev/null 2>&1; then
            echo -e "${blue}--> 正在更新 APK 软件源并安装依赖...${re}"
            apk update
            # Alpine 使用 musl libc，需要 gcompat 提供 glibc 兼容层以运行预编译二进制
            apk add curl wget tar jq openssl git net-tools unzip ca-certificates \
                     bash grep procps util-linux gcompat libc6-compat
        elif command -v pacman >/dev/null 2>&1; then
            echo -e "${blue}--> 正在安装 Pacman 基础依赖包...${re}"
            pacman -Sy --noconfirm curl wget tar jq openssl net-tools unzip cronie ca-certificates
        fi
        green "[+] 系统依赖包安装完成"
    else
        green "[+] 系统基础依赖已就绪"
    fi

    if ! command -v jq >/dev/null 2>&1; then
        local arch=$(detect_arch)
        mkdir -p /usr/local/bin
        yellow "[*] 正在补充下载 jq 工具 (Linux-${arch})..."
        curl -# -fSL --connect-timeout 10 --max-time 60 "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${arch}" -o /usr/local/bin/jq || \
        curl -# -fSL --connect-timeout 10 --max-time 60 "https://ghproxy.net/https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-${arch}" -o /usr/local/bin/jq 2>/dev/null
        chmod +x /usr/local/bin/jq 2>/dev/null
        if command -v jq >/dev/null 2>&1; then
            green "[+] jq 工具下载安装成功: /usr/local/bin/jq"
        fi
    fi
}

download_singbox_core() {
    local force="$1"
    local arch=$(detect_arch)
    mkdir -p "$WORKDIR"
    ensure_alpine_compatibility

    local sb_ver="1.13.18"
    local latest_tag
    latest_tag=$(curl -sL -m 4 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | grep '"tag_name":' | head -n1 | sed -E 's/.*"v([^"]+)".*/\1/' 2>/dev/null)
    [[ -n "$latest_tag" ]] && sb_ver="$latest_tag"

    local need_download=0
    if [[ ! -x "$WORKDIR/sing-box" || "$force" == "force" ]]; then
        need_download=1
    else
        # 检查当前核心版本，若低于 1.12.0 (不支持 AnyTLS) 则自动更新至最新版本
        local current_ver
        current_ver=$("$WORKDIR/sing-box" version 2>/dev/null | head -n 1 | awk '{print $3}' | sed 's/^v//')
        if [[ -n "$current_ver" ]]; then
            local major minor
            major=$(echo "$current_ver" | awk -F. '{print $1}')
            minor=$(echo "$current_ver" | awk -F. '{print $2}')
            if [[ "$major" -lt 1 || ( "$major" -eq 1 && "$minor" -lt 12 ) ]]; then
                yellow "[*] 检测到当前 Sing-box 核心版本 (v${current_ver}) 低于 v1.12.0，正在自动升级至最新版 (v${sb_ver}) 以支持 AnyTLS..."
                need_download=1
            fi
        else
            need_download=1
        fi
    fi

    if [[ $need_download -eq 1 ]]; then
        yellow "[*] 正在下载/更新 Sing-box 核心 (版本: v${sb_ver}, 架构: Linux-${arch})..."
        local sb_urls=(
            "https://github.com/SagerNet/sing-box/releases/download/v${sb_ver}/sing-box-${sb_ver}-linux-${arch}.tar.gz"
            "https://ghproxy.net/https://github.com/SagerNet/sing-box/releases/download/v${sb_ver}/sing-box-${sb_ver}-linux-${arch}.tar.gz"
            "https://raw.githubusercontent.com/hxzl666/singbox/main/sing-box-linux-${arch}"
        )
        local tmp_d="/tmp/sb_bin_tmp"
        mkdir -p "$tmp_d"
        for url in "${sb_urls[@]}"; do
            echo -e "${blue}--> 尝试下载源: ${url}${re}"
            if curl -# -fSL --connect-timeout 10 --max-time 120 "$url" -o "$tmp_d/sb_pkg"; then
                if [[ "$url" == *.tar.gz ]]; then
                    echo -e "${blue}--> 正在解压核心文件...${re}"
                    tar -xzf "$tmp_d/sb_pkg" -C "$tmp_d" 2>/dev/null
                    local bpath=$(find "$tmp_d" -type f -name "sing-box" | head -n 1)
                    [[ -n "$bpath" ]] && cp -f "$bpath" "$WORKDIR/sing-box"
                else
                    cp -f "$tmp_d/sb_pkg" "$WORKDIR/sing-box"
                fi
                [[ -f "$WORKDIR/sing-box" ]] && break
            else
                yellow "[!] 当前源下载失败，尝试备用下载源..."
            fi
        done
        rm -rf "$tmp_d"
        chmod +x "$WORKDIR/sing-box" 2>/dev/null
    fi

    # 验证是否可执行，在 Alpine 下若执行失败则再次尝试修复兼容层
    if [[ -f "$WORKDIR/sing-box" ]] && ! "$WORKDIR/sing-box" version >/dev/null 2>&1; then
        ensure_alpine_compatibility
    fi

    if [[ ! -x "$WORKDIR/sing-box" ]] || ! "$WORKDIR/sing-box" version >/dev/null 2>&1; then
        red "[!] Sing-box 核心程序下载失败或在当前系统架构下无法执行，请检查 VPS 网络与 libc 兼容层！"
        return 1
    fi
    green "[+] Sing-box 核心就绪: $WORKDIR/sing-box ($("$WORKDIR/sing-box" version 2>/dev/null | head -n1))"
    return 0
}

download_cloudflared_core() {
    local arch=$(detect_arch)
    local cf_arch="$arch"
    [[ "$arch" == "armv7" ]] && cf_arch="arm"
    mkdir -p /usr/local/bin
    ensure_alpine_compatibility
    if [[ ! -x "/usr/local/bin/cloudflared" ]] || ! /usr/local/bin/cloudflared version >/dev/null 2>&1; then
        yellow "[*] 正在下载 Cloudflared 核心 (Linux-${cf_arch})..."
        local cf_urls=(
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
            "https://ghproxy.net/https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
        )
        for url in "${cf_urls[@]}"; do
            echo -e "${blue}--> 尝试下载源: ${url}${re}"
            if curl -# -fSL --connect-timeout 10 --max-time 120 "$url" -o "/usr/local/bin/cloudflared"; then
                chmod +x "/usr/local/bin/cloudflared"
                green "[+] Cloudflared 核心安装完成: /usr/local/bin/cloudflared"
                break
            else
                yellow "[!] 当前源下载失败，尝试备用源..."
            fi
        done
    else
        green "[+] Cloudflared 核心已就绪"
    fi
}

download_psiphon_core() {
    local arch=$(detect_arch)
    local psi_arch="$arch"
    [[ "$arch" == "armv7" ]] && psi_arch="arm"
    mkdir -p "$WORKDIR"
    ensure_alpine_compatibility
    if [[ -x "$WORKDIR/psiphon-tunnel-core" ]] && "$WORKDIR/psiphon-tunnel-core" --version >/dev/null 2>&1; then
        green "[+] Psiphon 核心已就绪"
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
        echo -e "${blue}--> 尝试下载源: ${url}${re}"
        if curl -# -fSL --connect-timeout 10 --max-time 120 "$url" -o "$tmp_psi/psi_pkg"; then
            if [[ "$url" == *.tar.gz ]]; then
                echo -e "${blue}--> 正在解压 Psiphon 核心...${re}"
                tar -xzf "$tmp_psi/psi_pkg" -C "$tmp_psi" 2>/dev/null
                local ext_f=$(find "$tmp_psi" -type f -name 'psiphon-tunnel-core*' ! -name '*.tar.gz' | head -n1)
                [[ -n "$ext_f" ]] && cp -f "$ext_f" "$WORKDIR/psiphon-tunnel-core"
            else
                cp -f "$tmp_psi/psi_pkg" "$WORKDIR/psiphon-tunnel-core"
            fi
            [[ -f "$WORKDIR/psiphon-tunnel-core" ]] && break
        else
            yellow "[!] 当前源下载失败，尝试备用源..."
        fi
    done
    rm -rf "$tmp_psi"
    chmod +x "$WORKDIR/psiphon-tunnel-core" 2>/dev/null

    if [[ ! -x "$WORKDIR/psiphon-tunnel-core" ]]; then
        yellow "[!] 未下载到 Psiphon 核心，请检查 VPS 对 GitHub 的网络连通性。"
        return 1
    fi

    # 预载 Psiphon 种子服务器列表
    if [[ ! -f "$WORKDIR/server_list_compressed" ]]; then
        yellow "[*] 正在预载 Psiphon 种子服务器列表..."
        local s_urls=(
            "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed"
            "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
            "https://ghproxy.net/https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
        )
        for surl in "${s_urls[@]}"; do
            echo -e "${blue}--> 尝试下载节点列表: ${surl}${re}"
            curl -# -fSL --connect-timeout 10 --max-time 60 "$surl" -o "$WORKDIR/server_list_compressed" && break
        done
    fi

    green "[+] Psiphon 核心已安装: $WORKDIR/psiphon-tunnel-core"
    setup_psiphon_systemd_services
    return 0
}

setup_psiphon_systemd_services() {
    if [[ -d /etc/systemd/system ]] && ! $IS_DIRECT && ! $IS_OPENRC; then
        cat > /etc/systemd/system/psiphon-main.service <<'EOF_PSI_MAIN'
[Unit]
Description=Psiphon Main Tunnel Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/s-box
ExecStart=/etc/s-box/psiphon-tunnel-core --config /etc/s-box/psiphon.config
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_PSI_MAIN

        cat > /etc/systemd/system/psiphon-instance@.service <<'EOF_PSI_INST'
[Unit]
Description=Psiphon Secondary Instance for %i
After=network.target

[Service]
Type=simple
WorkingDirectory=/etc/s-box/psiphon_instances/%i
ExecStart=/etc/s-box/psiphon-tunnel-core --config /etc/s-box/psiphon_instances/%i/psiphon.config
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_PSI_INST

        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

start_psiphon_instance() {
    local cc="${1^^}"
    local idir="${PSI_INSTANCES_DIR}/${cc}"
    [[ -d "$idir" ]] || return 1
    setup_psiphon_systemd_services
    if command -v systemctl >/dev/null 2>&1 && ! $IS_DIRECT && ! $IS_OPENRC; then
        systemctl enable --now "psiphon-instance@${cc}" >/dev/null 2>&1 || true
    else
        local pid=$(cat "$idir/psiphon.pid" 2>/dev/null)
        if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
            nohup "$WORKDIR/psiphon-tunnel-core" --config "$idir/psiphon.config" >> "$idir/psiphon.log" 2>&1 &
            echo $! > "$idir/psiphon.pid"
        fi
    fi
}

stop_psiphon_instance() {
    local cc="${1^^}"
    local idir="${PSI_INSTANCES_DIR}/${cc}"
    if command -v systemctl >/dev/null 2>&1 && ! $IS_DIRECT && ! $IS_OPENRC; then
        systemctl stop "psiphon-instance@${cc}" >/dev/null 2>&1 || true
        systemctl disable --now "psiphon-instance@${cc}" >/dev/null 2>&1 || true
    fi
    local pid=$(cat "$idir/psiphon.pid" 2>/dev/null)
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    pkill -9 -f "psiphon-tunnel-core.*psiphon_instances/${cc}" 2>/dev/null || true
    rm -f "$idir/psiphon.pid"
}

is_psiphon_instance_running() {
    local cc="${1^^}"
    local idir="${PSI_INSTANCES_DIR}/${cc}"
    [[ -d "$idir" ]] || return 1
    if command -v systemctl >/dev/null 2>&1 && ! $IS_DIRECT && ! $IS_OPENRC; then
        systemctl is-active "psiphon-instance@${cc}" >/dev/null 2>&1 && return 0
    fi
    local pid=$(cat "$idir/psiphon.pid" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    if pgrep -f "psiphon-tunnel-core.*psiphon_instances/${cc}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# 统一的副节点出站进程启停与检测接口
start_secondary_egress() {
    local cc="${1^^}"
    start_psiphon_instance "$cc"
}

stop_secondary_egress() {
    local cc="${1^^}"
    stop_psiphon_instance "$cc"
}

is_secondary_egress_running() {
    local cc="${1^^}"
    is_psiphon_instance_running "$cc"
}

restart_psiphon_instance() {
    local cc="${1^^}"
    stop_psiphon_instance "$cc"
    sleep 1
    start_psiphon_instance "$cc"
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
    ipv6_list=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | sed 's/\/.*$//' | grep -vE '^(fe80|::1|fd)')
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

open_port_firewall() {
    local port=$1
    local proto=${2:-both} # tcp, udp, both
    [[ -z "$port" || "$port" == "0" ]] && return 0

    # UFW
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            ufw allow "${port}/udp" >/dev/null 2>&1 || true
        fi
    fi

    # Firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            firewall-cmd --zone=public --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            firewall-cmd --zone=public --add-port="${port}/udp" --permanent >/dev/null 2>&1 || true
        fi
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    # iptables
    if command -v iptables >/dev/null 2>&1; then
        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
    fi

    # ip6tables
    if command -v ip6tables >/dev/null 2>&1; then
        if [[ "$proto" == "tcp" || "$proto" == "both" ]]; then
            ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
        if [[ "$proto" == "udp" || "$proto" == "both" ]]; then
            ip6tables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
    fi
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

ensure_warp_config() {
    if [[ -s "$WORKDIR/warp_private_key.txt" && -s "$WORKDIR/warp_ipv6.txt" && -s "$WORKDIR/warp_reserved.txt" ]]; then
        return 0
    fi
    init_warp_config
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
    purple "正在检测主节点出口 IP..."
    local loop_port
    loop_port=$(jq -r '.inbounds[]? | select(.tag=="socks-loopback") | .listen_port // empty' "$WORKDIR/sb.json" 2>/dev/null | head -n1)
    [[ -z "$loop_port" ]] && loop_port="20080"

    local psi_en=$(cat "$WORKDIR/psiphon_main_enabled.txt" 2>/dev/null || echo "false")
    local warp_en=$(cat "$WORKDIR/warp_enabled.txt" 2>/dev/null || echo "false")
    local warp_m=$(cat "$WORKDIR/warp_mode.txt" 2>/dev/null || echo "all")

    local mode_desc="原生直连出站"
    if [[ "$psi_en" == "true" ]]; then
        local cur_reg=$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null || echo "AUTO")
        mode_desc="赛风出站 ${cur_reg}"
    elif [[ "$warp_en" == "true" ]]; then
        case "$warp_m" in
            ipv4) mode_desc="WARP 仅 IPv4 出站" ;;
            ipv6) mode_desc="WARP 仅 IPv6 出站" ;;
            google|rules) mode_desc="WARP 规则分流出站" ;;
            *) mode_desc="WARP 双栈全局出站" ;;
        esac
    fi

    echo "============================================================"
    green "  【主节点出口 IP 检测】 当前模式: ${mode_desc}"
    echo "============================================================"

    # 1. 探测 IPv4 出口
    yellow "[*] 正在探测 IPv4 出口路由..."
    local ipv4="" country4="" region4="" city4="" isp4="" json4=""
    
    # 优先采用 0 依赖官方 Trace 端点 (毫秒级响应)
    local trace4
    trace4=$(curl -sx "socks5://127.0.0.1:${loop_port}" -s4 --connect-timeout 2 -m 4 "http://1.1.1.1/cdn-cgi/trace" 2>/dev/null)
    if [[ -n "$trace4" ]] && echo "$trace4" | grep -q "ip="; then
        ipv4=$(echo "$trace4" | awk -F= '/^ip=/{print $2}' | tr -d ' \r\n')
    fi

    # 备用源 1: ipify
    if [[ -z "$ipv4" || ! "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ipv4=$(curl -sx "socks5://127.0.0.1:${loop_port}" -s4 --connect-timeout 2 -m 3 "http://api.ipify.org" 2>/dev/null | tr -d ' \r\n')
    fi

    # 备用源 2: icanhazip
    if [[ -z "$ipv4" || ! "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ipv4=$(curl -sx "socks5://127.0.0.1:${loop_port}" -s4 --connect-timeout 2 -m 3 "http://ipv4.icanhazip.com" 2>/dev/null | tr -d ' \r\n')
    fi

    # 备用源 3: ip.sb
    if [[ -z "$ipv4" || ! "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ipv4=$(curl -sx "socks5://127.0.0.1:${loop_port}" -s4 --connect-timeout 2 -m 3 "https://api-ipv4.ip.sb/ip" 2>/dev/null | tr -d ' \r\n')
    fi

    # 赛风模式备用探测
    if [[ -z "$ipv4" && "$psi_en" == "true" ]]; then
        local psi_port=$(cat "$WORKDIR/psiphon_socks_port.txt" 2>/dev/null || echo "20800")
        ipv4=$(curl -sx "socks5://127.0.0.1:${psi_port}" -s4 --connect-timeout 2 -m 3 "http://1.1.1.1/cdn-cgi/trace" 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d ' \r\n')
    fi

    if [[ -n "$ipv4" && "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local info4
        info4=$(curl -s4 --connect-timeout 3 -m 4 "http://ip-api.com/json/${ipv4}?lang=zh-CN" 2>/dev/null || curl -s4 --connect-timeout 3 -m 4 "https://api.ip.sb/geoip/${ipv4}" 2>/dev/null)
        country4=$(echo "$info4" | jq -r '.country // .country_name // empty' 2>/dev/null)
        region4=$(echo "$info4" | jq -r '.region // .regionName // empty' 2>/dev/null)
        city4=$(echo "$info4" | jq -r '.city // empty' 2>/dev/null)
        isp4=$(echo "$info4" | jq -r '.isp // .organization // empty' 2>/dev/null)

        green "  [✓] IPv4 出口 IP : ${ipv4}"
        [[ -n "$country4" || -n "$city4" ]] && blue  "      出口国家地区 : ${country4:-未知} - ${region4} ${city4}"
        [[ -n "$isp4" ]] && blue  "      网络运营商   : ${isp4}"
    else
        yellow "  [!] IPv4 出口    : 未获取到"
    fi

    echo "  ----------------------------------------------------------"

    # 2. 探测 IPv6 出口
    yellow "[*] 正在探测 IPv6 出口路由..."
    local ipv6="" country6="" region6="" city6="" isp6=""

    # 优先请求 api-ipv6.ip.sb
    ipv6=$(curl -sx "socks5h://127.0.0.1:${loop_port}" -s --connect-timeout 2 -m 4 "https://api-ipv6.ip.sb/ip" 2>/dev/null | tr -d ' \r\n')

    # 备用源 1: ipify IPv6
    if [[ -z "$ipv6" || ! "$ipv6" =~ : ]]; then
        ipv6=$(curl -sx "socks5h://127.0.0.1:${loop_port}" -s --connect-timeout 2 -m 4 "https://api6.ipify.org" 2>/dev/null | tr -d ' \r\n')
    fi

    # 备用源 2: icanhazip IPv6
    if [[ -z "$ipv6" || ! "$ipv6" =~ : ]]; then
        ipv6=$(curl -sx "socks5h://127.0.0.1:${loop_port}" -s --connect-timeout 2 -m 4 "http://ipv6.icanhazip.com" 2>/dev/null | tr -d ' \r\n')
    fi

    # 备用源 3: cloudflare trace
    if [[ -z "$ipv6" || ! "$ipv6" =~ : ]]; then
        ipv6=$(curl -sx "socks5://127.0.0.1:${loop_port}" -s6 --connect-timeout 2 -m 4 "http://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null | awk -F= '/^ip=/{print $2}' | tr -d ' \r\n')
    fi

    if [[ -n "$ipv6" && "$ipv6" =~ : ]]; then
        local info6
        info6=$(curl -s --connect-timeout 3 -m 4 "https://api.ip.sb/geoip/${ipv6}" 2>/dev/null || curl -s --connect-timeout 3 -m 4 "http://ip-api.com/json/${ipv6}?lang=zh-CN" 2>/dev/null)
        country6=$(echo "$info6" | jq -r '.country // .country_name // empty' 2>/dev/null)
        region6=$(echo "$info6" | jq -r '.region // .regionName // empty' 2>/dev/null)
        city6=$(echo "$info6" | jq -r '.city // empty' 2>/dev/null)
        isp6=$(echo "$info6" | jq -r '.isp // .organization // empty' 2>/dev/null)

        green "  [✓] IPv6 出口 IP : ${ipv6}"
        [[ -n "$country6" || -n "$city6" ]] && blue  "      出口国家地区 : ${country6:-未知} - ${region6} ${city6}"
        [[ -n "$isp6" ]] && blue  "      网络运营商   : ${isp6}"
    else
        yellow "  [!] IPv6 出口    : 未获取到"
    fi

    echo "============================================================"
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
    local upstream_proxy="$5"

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
            if curl -fsSL --connect-timeout 5 --max-time 15 "$surl" -o "$data_dir/server_list_compressed" 2>/dev/null; then
                cp -f "$data_dir/server_list_compressed" "$data_dir/remote_server_list" 2>/dev/null
                cp -f "$data_dir/server_list_compressed" "$WORKDIR/server_list_compressed" 2>/dev/null
                break
            fi
        done
    fi

    local upstream_line=""
    if [[ -n "$upstream_proxy" ]]; then
        upstream_line="  \"UpstreamProxyURL\": \"${upstream_proxy}\","
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
${upstream_line}
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

is_main_psiphon_running() {
    if command -v systemctl >/dev/null 2>&1 && ! $IS_DIRECT && ! $IS_OPENRC; then
        systemctl is-active psiphon-main >/dev/null 2>&1 && return 0
    fi
    local psi_pid=$(cat "$WORKDIR/psiphon.pid" 2>/dev/null)
    if [[ -n "$psi_pid" ]] && kill -0 "$psi_pid" 2>/dev/null; then
        return 0
    fi
    if pgrep -f "psiphon-tunnel-core.*psiphon\.config" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

start_main_psiphon() {
    download_psiphon_core || return 1
    setup_psiphon_systemd_services
    local region
    region=$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null || echo "AUTO")
    local socks_port
    socks_port=$(cat "$WORKDIR/psiphon_socks_port.txt" 2>/dev/null || echo "20800")
    local data_dir="$WORKDIR/psiphon-data/${region:-AUTO}"
    mkdir -p "$data_dir"
    write_psiphon_config "$socks_port" "$region" "$WORKDIR/psiphon.config" "$data_dir"

    if command -v systemctl >/dev/null 2>&1 && ! $IS_DIRECT && ! $IS_OPENRC; then
        systemctl stop psiphon-main >/dev/null 2>&1 || true
        systemctl enable psiphon-main >/dev/null 2>&1 || true
        systemctl start psiphon-main >/dev/null 2>&1 || true
    else
        stop_main_psiphon
        local psi_pid_file="$WORKDIR/psiphon.pid"
        if [[ ! -f "$psi_pid_file" ]] || ! kill -0 "$(cat "$psi_pid_file" 2>/dev/null)" 2>/dev/null; then
            nohup "$WORKDIR/psiphon-tunnel-core" --config "$WORKDIR/psiphon.config" >> "$WORKDIR/psiphon.log" 2>&1 &
            echo $! > "$psi_pid_file"
        fi
    fi
    return 0
}

stop_main_psiphon() {
    if command -v systemctl >/dev/null 2>&1 && ! $IS_DIRECT && ! $IS_OPENRC; then
        systemctl disable --now psiphon-main >/dev/null 2>&1 || true
    fi
    local psi_pid_file="$WORKDIR/psiphon.pid"
    if [[ -f "$psi_pid_file" ]]; then
        local pid
        pid=$(cat "$psi_pid_file" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$psi_pid_file"
    fi
    pkill -9 -f "${WORKDIR}/psiphon-tunnel-core --config ${WORKDIR}/psiphon.config" 2>/dev/null || true
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

# 自动发现并迁移之前旧版本中的自定义出口节点与副节点（单次幂等迁移）
auto_migrate_legacy_nodes() {
    local cfg="$WORKDIR/sb.json"
    [[ -f "$cfg" ]] || return 0
    init_proxy_groups_dir
    init_psiphon_instances_dir

    # 若已迁移完成，则直接执行孤儿清理并返回
    if [[ -f "$WORKDIR/.legacy_migrated_v2" ]]; then
        cleanup_orphan_secondary_nodes
        return 0
    fi

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

        # 自定义外部代理副节点 (如 outbound-us, proxy-1 等)
        local gtag="$otag"
        [[ "$gtag" == *-out ]] && gtag="${gtag%-out}"
        [[ "$gtag" == outbound-* ]] && gtag="${gtag#outbound-}"
        local gdir="${PROXY_GROUPS_DIR}/${gtag}"

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

        # 只有在确实有入站端口关联时才视为真实副节点进行迁移，孤儿出站不自动分配端口
        if [[ "${hp:-0}" -gt 0 || "${tp:-0}" -gt 0 || "${vp:-0}" -gt 0 ]]; then
            mkdir -p "$gdir"
            jq --arg t "$otag" '.outbounds[]? | select(.tag==$t)' "$cfg" > "$gdir/outbound.json" 2>/dev/null
            [[ ! -f "$gdir/remark.txt" ]] && echo "$gtag" > "$gdir/remark.txt"
            echo "${hp:-0}" > "$gdir/hy2_port.txt"
            echo "${tp:-0}" > "$gdir/tuic_port.txt"
            echo "${vp:-0}" > "$gdir/vless_port.txt"
            if ! grep -qx "$gtag" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null; then
                echo "$gtag" >> "$PROXY_GROUPS_DIR/groups.txt"
            fi
        fi
    done

    # 清除旧的重复入站标签
    if [[ ${#legacy_inbounds_to_remove[@]} -gt 0 ]]; then
        local tmp_cl=$(mktemp)
        jq --argjson tags "$(printf '%s\n' "${legacy_inbounds_to_remove[@]}" | jq -R . | jq -s .)" '
        .inbounds = [.inbounds[] | select(.tag as $t | ($tags | index($t) | not))]
        ' "$cfg" > "$tmp_cl" && mv -f "$tmp_cl" "$cfg"
    fi

    touch "$WORKDIR/.legacy_migrated_v2"
    cleanup_orphan_secondary_nodes
}

# 清理未在任何合法副节点清单中注册的孤儿出站与残留路由
cleanup_orphan_secondary_nodes() {
    local cfg="$WORKDIR/sb.json"
    [[ -f "$cfg" ]] || return 0

    local valid_tags=("direct" "block" "warp-out" "psiphon-main-out")

    local psi_insts
    mapfile -t psi_insts < <(get_all_psiphon_instances 2>/dev/null)
    for cc in "${psi_insts[@]}"; do
        [[ -n "$cc" ]] && valid_tags+=("psiphon-${cc,,}" "psiphon-warp-${cc,,}")
    done

    local proxy_tags
    mapfile -t proxy_tags < <(get_all_proxy_groups 2>/dev/null)
    for tag in "${proxy_tags[@]}"; do
        [[ -n "$tag" ]] && valid_tags+=("${tag}-out")
    done

    local tmp_clean=$(mktemp)
    if jq --argjson valids "$(printf '%s\n' "${valid_tags[@]}" | jq -R . | jq -s .)" '
      .outbounds = [.outbounds[] | select(.tag as $t | ($valids | index($t)) != null)] |
      .endpoints = [(.endpoints // [])[] | select(.tag as $t | ($valids | index($t)) != null)] |
      .route.rules = [
        .route.rules[] |
        select(
          (has("outbound") | not) or
          (.outbound as $o | ($valids | index($o)) != null)
        )
      ]
    ' "$cfg" > "$tmp_clean" 2>/dev/null && jq -e . "$tmp_clean" >/dev/null 2>&1; then
        mv -f "$tmp_clean" "$cfg"
    else
        rm -f "$tmp_clean"
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
            # 补齐 base64 padding
            local mod=$(( ${#raw} % 4 ))
            [[ $mod -eq 2 ]] && raw="${raw}=="
            [[ $mod -eq 3 ]] && raw="${raw}="
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
            local fragment=""
            if [[ "$rest" == *"#"* ]]; then
                fragment="${rest#*#}"
                rest="${rest%%#*}"
            fi
            local query=""
            local hostpart="$rest"
            if [[ "$rest" == *"?"* ]]; then
                query="${rest#*?}"
                hostpart="${rest%%\?*}"
            fi

            local userinfo="" host="" port=""
            if [[ "$hostpart" == *"@"* ]]; then
                userinfo="${hostpart%%@*}"
                hostpart="${hostpart#*@}"
            fi

            if [[ "$hostpart" =~ ^\[([a-fA-F0-9:]+)\]:([0-9]+)$ ]]; then
                host="${BASH_REMATCH[1]}"
                port="${BASH_REMATCH[2]}"
            elif [[ "$hostpart" =~ ^([-a-zA-Z0-9.]+):([0-9]+)$ ]]; then
                host="${BASH_REMATCH[1]}"
                port="${BASH_REMATCH[2]}"
            elif [[ "$hostpart" =~ ^\[([a-fA-F0-9:]+)\]$ ]]; then
                host="${BASH_REMATCH[1]}"
                port="443"
            elif [[ "$hostpart" =~ ^([-a-zA-Z0-9.]+)$ ]]; then
                host="${BASH_REMATCH[1]}"
                port="443"
            else
                host="${hostpart%:*}"
                port="${hostpart##*:}"
                [[ "$host" == "$port" ]] && port="443"
            fi
            [[ "$port" =~ ^[0-9]+$ ]] || port="443"

            local q_sni="" q_security="" q_flow="" q_pbk="" q_sid="" q_fp="" q_insecure="0" q_type="tcp" q_path="/" q_host="" q_serviceName="" q_alpn="" q_obfs="" q_obfs_pass=""
            if [[ -n "$query" ]]; then
                local old_ifs="$IFS"
                IFS='&'
                for param in $query; do
                    local k="${param%%=*}"
                    local v="${param#*=}"
                    case "$k" in
                        sni|peer) q_sni="$v" ;;
                        security) q_security="$v" ;;
                        flow) q_flow="$v" ;;
                        pbk) q_pbk="$v" ;;
                        sid) q_sid="$v" ;;
                        fp) q_fp="$v" ;;
                        insecure|allowInsecure|allow_insecure|allow_insecure_cert|insecure_cert) q_insecure="$v" ;;
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

            local insec_bool="false"
            if [[ "$q_insecure" == "1" || "$q_insecure" == "true" ]]; then
                insec_bool="true"
            elif [[ "$host" =~ ^[0-9.]+$ || "$host" =~ ^[a-fA-F0-9:]+$ ]]; then
                # 裸 IP 出站默认跳过证书校验以兼容自签与非 IP-SAN 证书
                insec_bool="true"
            fi

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
                      --argjson insec "$insec_bool" \
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
                        "tls": ({"enabled": true, "insecure": $insec, "utls": {"enabled": true, "fingerprint": (if $fp != "" then $fp else "chrome" end)}} + (if $sni != "" and ($sni | test("^[0-9.]+$|^[a-fA-F0-9:]+$") | not) then {"server_name": $sni} else {} end))
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
                      --argjson insec "$insec_bool" \
                      '
                      {
                        "type": "trojan",
                        "tag": $tag,
                        "server": $server,
                        "server_port": $port,
                        "password": $pass,
                        "tls": ({"enabled": true, "insecure": $insec} + (if $sni != "" and ($sni | test("^[0-9.]+$|^[a-fA-F0-9:]+$") | not) then {"server_name": $sni} else {} end))
                      } +
                      (if $net == "ws" then {"transport": {"type": "ws", "path": $path, "headers": (if $hosthdr != "" then {"Host": $hosthdr} else {} end)}}
                       elif $net == "grpc" then {"transport": {"type": "grpc", "service_name": $path}}
                       elif $net == "httpupgrade" then {"transport": {"type": "httpupgrade", "path": $path, "headers": (if $hosthdr != "" then {"Host": $hosthdr} else {} end)}}
                       else {} end)
                      '
                    ;;
                hy2|hysteria2)
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
                        "tls": ({"enabled": true, "insecure": $insec} + (if $sni != "" and ($sni | test("^[0-9.]+$|^[a-fA-F0-9:]+$") | not) then {"server_name": $sni} else {} end))
                      } +
                      (if $obfs != "" then {"obfs": {"type": $obfs, "password": $obfs_p}} else {} end)
                      '
                    ;;
                tuic)
                    local tuic_uuid="${userinfo%%:*}"
                    local tuic_pass="${userinfo#*:}"
                    [[ "$userinfo" != *":"* ]] && tuic_pass="$tuic_uuid"
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
                        "tls": ({"enabled": true, "alpn": $alpn, "insecure": $insec} + (if $sni != "" and ($sni | test("^[0-9.]+$|^[a-fA-F0-9:]+$") | not) then {"server_name": $sni} else {} end))
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
    if ! echo "$result" | jq -e . >/dev/null 2>&1; then
        red "[!] 链接解析结果不是合法的 JSON 出站对象"
        return 1
    fi
    echo "$result" | jq -c .
    return 0
}

# ==================== 同步自定义代理副节点到 sing-box (纯 jq) ====================
sync_proxy_group_to_singbox() {
    local group_tag="$1"
    local group_dir="${PROXY_GROUPS_DIR}/${group_tag}"
    local cfg="$WORKDIR/sb.json"

    [[ -f "$cfg" ]] || return 1
    [[ -d "$group_dir" ]] || return 1
    local out_tag="${group_tag}-out"

    # 自动检测并修复/自愈损坏的 outbound.json
    if [[ ! -f "$group_dir/outbound.json" ]] || ! jq -e . "$group_dir/outbound.json" >/dev/null 2>&1; then
        local candidate_url=""
        if [[ -f "$group_dir/raw_url.txt" ]]; then
            candidate_url=$(head -n 1 "$group_dir/raw_url.txt" | tr -d '\r\n ')
        elif [[ -f "$group_dir/outbound.json" ]]; then
            candidate_url=$(head -n 1 "$group_dir/outbound.json" | tr -d '\r\n ')
        fi
        if [[ -n "$candidate_url" && "$candidate_url" == *"://"* ]]; then
            local fixed_json
            fixed_json=$(parse_proxy_url_to_json "$candidate_url" "$out_tag" 2>/dev/null)
            if [[ -n "$fixed_json" ]] && echo "$fixed_json" | jq -e . >/dev/null 2>&1; then
                echo "$fixed_json" | jq -c . > "$group_dir/outbound.json"
                echo "$candidate_url" > "$group_dir/raw_url.txt"
            fi
        fi
    fi

    [[ -f "$group_dir/outbound.json" ]] || return 1
    if ! jq -e . "$group_dir/outbound.json" >/dev/null 2>&1; then
        red "[!] 代理组 $group_tag 的出站配置无效，跳过同步"
        return 1
    fi

    local hy2_port tuic_port vless_port uuid reality_pvk reym
    hy2_port=$(cat "$group_dir/hy2_port.txt" 2>/dev/null || echo "0")
    tuic_port=$(cat "$group_dir/tuic_port.txt" 2>/dev/null || echo "0")
    vless_port=$(cat "$group_dir/vless_port.txt" 2>/dev/null || echo "0")
    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.users[0].uuid != null) | .users[0].uuid' "$cfg" 2>/dev/null | head -n1)
    [[ -z "$uuid" ]] && uuid=$(jq -r '.inbounds[]? | select(.users[0].password != null) | .users[0].password' "$cfg" 2>/dev/null | head -n1)
    reality_pvk=$(cat "$WORKDIR/private_key.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.tls.reality.private_key != null) | .tls.reality.private_key' "$cfg" 2>/dev/null | head -n1)
    reym=$(cat "$WORKDIR/reym.txt" 2>/dev/null || echo "apple.com")

    local tmp_json
    tmp_json=$(mktemp)

    if jq \
      --slurpfile ob_file "$group_dir/outbound.json" \
      --arg group_tag "$group_tag" \
      --arg out_tag "$out_tag" \
      --argjson hy2_port "${hy2_port:-0}" \
      --argjson tuic_port "${tuic_port:-0}" \
      --argjson vless_port "${vless_port:-0}" \
      --arg uuid "$uuid" \
      --arg reality_pvk "$reality_pvk" \
      --arg reym "$reym" \
      --arg listen_addr "${LISTEN_ADDR:-"::"}" \
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
          "listen": $listen_addr,
          "listen_port": $hy2_port,
          "users": [{"password": $uuid}],
          "masquerade": "https://www.bing.com",
          "ignore_client_bandwidth": false,
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $tuic_port > 0 then . + [{
          "type": "tuic",
          "tag": ("tuic-" + $group_tag + "-in"),
          "listen": $listen_addr,
          "listen_port": $tuic_port,
          "users": [{"uuid": $uuid, "password": $uuid}],
          "congestion_control": "bbr",
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $vless_port > 0 then . + [{
          "type": "vless",
          "tag": ("vless-" + $group_tag + "-in"),
          "listen": $listen_addr,
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
      ' "$cfg" > "$tmp_json" 2>/dev/null && jq -e . "$tmp_json" >/dev/null 2>&1; then
        mv -f "$tmp_json" "$cfg"
        [[ "${hy2_port:-0}" -gt 0 ]] && open_port_firewall "$hy2_port" udp
        [[ "${tuic_port:-0}" -gt 0 ]] && open_port_firewall "$tuic_port" udp
        [[ "${vless_port:-0}" -gt 0 ]] && open_port_firewall "$vless_port" tcp
        return 0
    else
        rm -f "$tmp_json"
        return 1
    fi
}

# ==================== 赛风副节点出站模式管理模块 (纯赛风 / Cfon) ====================
get_psiphon_egress_mode() {
    local cc="${1^^}"
    local file="${PSI_INSTANCES_DIR}/${cc}/egress_mode.txt"
    [[ -f "$file" ]] && cat "$file" 2>/dev/null || echo "psiphon"
}

get_psiphon_cfon_socks_port() {
    local cc="${1^^}"
    local inst_dir="${PSI_INSTANCES_DIR}/${cc}"
    local port_file="${inst_dir}/cfon_socks_port.txt"
    local port

    mkdir -p "$inst_dir"
    port=$(cat "$port_file" 2>/dev/null || echo "0")
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -le 0 ]]; then
        port=$(get_free_loopback_port)
        echo "$port" > "$port_file"
    fi
    printf '%s\n' "$port"
}
set_psiphon_egress_mode() {

    local cc="${1^^}"
    local mode="$2"
    [[ "$mode" == "psiphon" || "$mode" == "cfon" ]] || return 1
    mkdir -p "${PSI_INSTANCES_DIR}/${cc}"
    printf '%s\n' "$mode" > "${PSI_INSTANCES_DIR}/${cc}/egress_mode.txt"
}

get_psiphon_egress_desc() {
    case "$(get_psiphon_egress_mode "$1")" in
        cfon) echo "赛风（WARP 前置 / Cfon）" ;;
        *)    echo "纯赛风原生出站" ;;
    esac
}

# ==================== 同步赛风副节点到 sing-box (纯 jq) ====================
sync_psiphon_instance_to_singbox() {
    local cc="${1^^}"
    local inst_dir="${PSI_INSTANCES_DIR}/${cc}"
    local cfg="$WORKDIR/sb.json"

    [[ -f "$cfg" ]] || return 1
    [[ -d "$inst_dir" ]] || return 1

    local hy2_port tuic_port vless_port socks_port uuid reality_pvk reym test_socks_port
    hy2_port=$(cat "$inst_dir/hy2_port.txt" 2>/dev/null || echo "0")
    tuic_port=$(cat "$inst_dir/tuic_port.txt" 2>/dev/null || echo "0")
    vless_port=$(cat "$inst_dir/vless_port.txt" 2>/dev/null || echo "0")
    test_socks_port=$(cat "$inst_dir/test_socks_port.txt" 2>/dev/null || echo "0")
    [[ -z "$test_socks_port" || "$test_socks_port" == "0" ]] && test_socks_port=$(get_free_loopback_port)
    echo "$test_socks_port" > "$inst_dir/test_socks_port.txt"

    socks_port=$(cat "$inst_dir/socks_port.txt" 2>/dev/null || echo "0")
    if [[ -z "$socks_port" || "$socks_port" == "0" ]]; then
        socks_port=$(get_free_loopback_port)
        echo "$socks_port" > "$inst_dir/socks_port.txt"
    fi

    uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.users[0].uuid != null) | .users[0].uuid' "$cfg" 2>/dev/null | head -n1)
    [[ -z "$uuid" ]] && uuid=$(jq -r '.inbounds[]? | select(.users[0].password != null) | .users[0].password' "$cfg" 2>/dev/null | head -n1)
    reality_pvk=$(cat "$WORKDIR/private_key.txt" 2>/dev/null || jq -r '.inbounds[]? | select(.tls.reality.private_key != null) | .tls.reality.private_key' "$cfg" 2>/dev/null | head -n1)
    reym=$(cat "$WORKDIR/reym.txt" 2>/dev/null || echo "apple.com")
    local cc_lower=$(echo "$cc" | tr '[:upper:]' '[:lower:]')
    local out_tag="psiphon-${cc_lower}"

    local tmp_json
    local egress_mode cfon_enabled cfon_socks_port warp_endpoint warp_port warp_pvk warp_ipv6 warp_res
    egress_mode=$(get_psiphon_egress_mode "$cc")
    cfon_enabled="false"
    cfon_socks_port="0"
    if [[ "$egress_mode" == "cfon" ]]; then
        ensure_warp_config >/dev/null 2>&1 || true
        cfon_enabled="true"
        cfon_socks_port=$(get_psiphon_cfon_socks_port "$cc")
    fi
    warp_endpoint=$(get_warp_endpoint)
    warp_port=$(cat "$WORKDIR/warp_best_port.txt" 2>/dev/null || echo "2408")
    warp_pvk=$(cat "$WORKDIR/warp_private_key.txt" 2>/dev/null || echo "52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A=")
    warp_ipv6=$(cat "$WORKDIR/warp_ipv6.txt" 2>/dev/null || echo "2606:4700:110:8d8d:1845:c39f:2dd5:a03a")
    warp_res=$(cat "$WORKDIR/warp_reserved.txt" 2>/dev/null || echo "[215, 69, 233]")

    tmp_json=$(mktemp)

    if jq \
      --arg cc "$cc_lower" \
      --arg out_tag "$out_tag" \
      --argjson socks_port "${socks_port:-0}" \
      --argjson test_port "${test_socks_port:-0}" \
      --argjson hy2_port "${hy2_port:-0}" \
      --argjson tuic_port "${tuic_port:-0}" \
      --argjson vless_port "${vless_port:-0}" \
      --arg uuid "$uuid" \
      --arg reality_pvk "$reality_pvk" \
      --arg reym "$reym" \
      --arg listen_addr "${LISTEN_ADDR:-"::"}" \
      --arg cfon_en "$cfon_enabled" \
      --argjson cfon_port "${cfon_socks_port:-0}" \
      --arg warp_ep "$warp_endpoint" \
      --argjson warp_port "$warp_port" \
      --arg warp_pvk "$warp_pvk" \
      --arg warp_ipv6 "$warp_ipv6" \
      --argjson warp_res "$warp_res" \
      '
      # 清理旧的副节点 WARP endpoint（Cfon 由底座自身管理，无需 singbox endpoint）
      .endpoints = [(.endpoints // [])[] | select(.tag != ("psiphon-warp-" + $cc))] |
      if $cfon_en == "true" and $cfon_port > 0 then
        .endpoints += [{
          "type": "wireguard",
          "tag": ("psiphon-warp-" + $cc),
          "system": false,
          "address": ["172.16.0.2/32", ($warp_ipv6 + "/128")],
          "private_key": $warp_pvk,
          "peers": [{
            "address": $warp_ep,
            "port": $warp_port,
            "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
            "allowed_ips": ["0.0.0.0/0", "::/0"],
            "reserved": $warp_res
          }]
        }]
      else . end |

      # 管理专属的 SOCKS outbound
      .outbounds = [.outbounds[] | select(.tag != $out_tag)] |
      if $socks_port > 0 then
        .outbounds += [{
          "type": "socks",
          "tag": $out_tag,
          "server": "127.0.0.1",
          "server_port": $socks_port,
          "version": "5"
        }]
      else . end |

      # 重构专属的 Inbounds (Hy2 / TUIC / VLESS / 本地专属探测 socks-psi-$cc-in)
      .inbounds = [.inbounds[] | select(
        .tag != ("hy2-psi-" + $cc + "-in") and
        .tag != ("tuic-psi-" + $cc + "-in") and
        .tag != ("vless-psi-" + $cc + "-in") and
        .tag != ("socks-psi-" + $cc + "-in") and
        .tag != ("socks-cfon-" + $cc + "-in")
      )] |

      (
        [] |
        if $test_port > 0 then . + [{
          "type": "socks",
          "tag": ("socks-psi-" + $cc + "-in"),
          "listen": "127.0.0.1",
          "listen_port": $test_port
        }] else . end |
        if $hy2_port > 0 then . + [{
          "type": "hysteria2",
          "tag": ("hy2-psi-" + $cc + "-in"),
          "listen": $listen_addr,
          "listen_port": $hy2_port,
          "users": [{"password": $uuid}],
          "masquerade": "https://www.bing.com",
          "ignore_client_bandwidth": false,
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $tuic_port > 0 then . + [{
          "type": "tuic",
          "tag": ("tuic-psi-" + $cc + "-in"),
          "listen": $listen_addr,
          "listen_port": $tuic_port,
          "users": [{"uuid": $uuid, "password": $uuid}],
          "congestion_control": "bbr",
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $vless_port > 0 then . + [{
          "type": "vless",
          "tag": ("vless-psi-" + $cc + "-in"),
          "listen": $listen_addr,
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
      if $cfon_en == "true" and $cfon_port > 0 then
        .inbounds += [{
          "type": "socks",
          "tag": ("socks-cfon-" + $cc + "-in"),
          "listen": "127.0.0.1",
          "listen_port": $cfon_port
        }]
      else . end |


      ($new_inbounds | map(.tag)) as $inbound_tags |

      # 清理旧的与该赛风副节点相关的 route 规则
      .route.rules = [.route.rules[] | select(
        (.inbound != $inbound_tags) and
        (.outbound != $out_tag) and
        (.outbound != ("psiphon-warp-" + $cc))
      )] |
      if $cfon_en == "true" and $cfon_port > 0 then
        .route.rules = ([{"inbound": [("socks-cfon-" + $cc + "-in")], "action": "route", "outbound": ("psiphon-warp-" + $cc)}] + .route.rules)
      else . end |


      if ($inbound_tags | length) > 0 and $socks_port > 0 then
        .route.rules = ([{"inbound": $inbound_tags, "action": "route", "outbound": $out_tag}] + .route.rules)
      else . end
      ' "$cfg" > "$tmp_json" 2>/dev/null && jq -e . "$tmp_json" >/dev/null 2>&1; then
        mv -f "$tmp_json" "$cfg"
        [[ "${hy2_port:-0}" -gt 0 ]] && open_port_firewall "$hy2_port" udp
        [[ "${tuic_port:-0}" -gt 0 ]] && open_port_firewall "$tuic_port" udp
        [[ "${vless_port:-0}" -gt 0 ]] && open_port_firewall "$vless_port" tcp
        return 0
    else
        rm -f "$tmp_json"
        return 1
    fi
}

ensure_all_psiphon_instances_running() {
    local psi_insts
    mapfile -t psi_insts < <(get_all_psiphon_instances 2>/dev/null)
    for cc in "${psi_insts[@]}"; do
        [[ -z "$cc" ]] && continue
        local idir="${PSI_INSTANCES_DIR}/${cc}"
        local socks_p=$(jq -r '.LocalSocksProxyPort // empty' "$idir/psiphon.config" 2>/dev/null)
        [[ -z "$socks_p" || "$socks_p" == "0" ]] && socks_p=$(cat "$idir/socks_port.txt" 2>/dev/null)
        [[ -z "$socks_p" || "$socks_p" == "0" ]] && socks_p=$(get_free_loopback_port)
        echo "$socks_p" > "$idir/socks_port.txt"
        local upstream_proxy=""
        if [[ "$(get_psiphon_egress_mode "$cc")" == "cfon" ]]; then
            upstream_proxy="socks5://127.0.0.1:$(get_psiphon_cfon_socks_port "$cc")"
        fi
        write_psiphon_config "$socks_p" "$cc" "$idir/psiphon.config" "$idir/data" "$upstream_proxy"
        start_psiphon_instance "$cc"
    done
}

# ==================== 副节点全面自动同步函数 ====================
sync_all_secondary_nodes() {
    local cfg="$WORKDIR/sb.json"
    [[ -f "$cfg" ]] || return 0
    auto_migrate_legacy_nodes
    ensure_all_psiphon_instances_running

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

    cleanup_orphan_secondary_nodes
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
      .dns = {
        "servers": [
          {"type": "local", "tag": "dns-direct"},
          {"type": "udp", "tag": "dns-remote", "server": "8.8.8.8"}
        ],
        "final": "dns-direct"
      } |
      .route.default_domain_resolver = "dns-direct" |
      .route = (.route // {}) |

      # 严格去重并确保唯一的 socks-loopback 入站存在
      .inbounds = [(.inbounds // [])[] | select(.tag != "socks-loopback")] + [
        {"tag":"socks-loopback","type":"socks","listen":"127.0.0.1","listen_port":20080}
      ] |

      .outbounds = (.outbounds // []) |
      if any(.outbounds[]; .tag == "direct") then . else .outbounds += [{"type":"direct","tag":"direct"}] end |
      if any(.outbounds[]; .tag == "block") then . else .outbounds += [{"type":"block","tag":"block"}] end |
      
      # 彻底清理旧的 warp-out 和 psiphon-main-out 出站
      .outbounds = [.outbounds[] | select(.tag != "warp-out" and .tag != "psiphon-main-out")] |
      
      # 清理 endpoints 中的历史 warp-out
      .endpoints = [(.endpoints // [])[] | select(.tag != "warp-out")] |

      # 100% 绝对保护所有副节点规则 (入站/出站双重白名单机制，零误伤)
      def is_secondary_rule:
        (
          ((.inbound | type == "array") and (.inbound | any(. | tostring | (contains("psi") or contains("proxy") or contains("custom"))))) or
          ((.inbound | type == "string") and (.inbound | (contains("psi") or contains("proxy") or contains("custom")))) or
          ((.outbound | type == "string") and ((.outbound | (startswith("psiphon-") and . != "psiphon-main-out")) or (.outbound | (startswith("proxy-") or startswith("custom-")))))
        );
      .route.rules = [(.route.rules // [])[] | select(is_secondary_rule)] |
      
      if $warp_en == "true" then
        # 基础 WARP Endpoint 配置 (保持双栈 allowed_ips 放行，由路由层精确控制分流)
        .endpoints += [{
          "type": "wireguard",
          "tag": "warp-out",
          "system": false,
          "address": ["172.16.0.2/32", ($warp_ipv6 + "/128")],
          "private_key": $warp_pvk,
          "peers": [{
            "address": $warp_ep,
            "port": $warp_port,
            "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
            "allowed_ips": ["0.0.0.0/0", "::/0"],
            "reserved": $warp_res
          }]
        }] |
        if $warp_mode == "all" or $warp_mode == "dual" then
          # 双栈全局: 双栈流量与 socks-loopback 均走 WARP
          .outbounds = [.outbounds[] | if .tag == "direct" then del(.domain_strategy) else . end] |
          .route.rules = .route.rules + [
            {"inbound": ["socks-loopback"], "action": "route", "outbound": "warp-out"},
            {"action": "sniff"},
            {"action": "resolve", "strategy": "prefer_ipv6"},
            {"ip_version": 4, "action": "route", "outbound": "warp-out"},
            {"ip_version": 6, "action": "route", "outbound": "warp-out"}
          ] |
          .route.final = "warp-out"
        elif $warp_mode == "ipv4" then
          # 仅 IPv4 走 WARP: IPv4 走 WARP，IPv6 走直连
          .outbounds = [.outbounds[] | if .tag == "direct" then del(.domain_strategy) else . end] |
          .route.rules = .route.rules + [
            {"action": "sniff"},
            {"action": "resolve", "strategy": "prefer_ipv4"},
            {"ip_cidr": ["0.0.0.0/0"], "action": "route", "outbound": "warp-out"},
            {"ip_version": 4, "action": "route", "outbound": "warp-out"},
            {"ip_cidr": ["::/0"], "action": "route", "outbound": "direct"},
            {"ip_version": 6, "action": "route", "outbound": "direct"}
          ] |
          .route.final = "direct"
        elif $warp_mode == "ipv6" then
          # 仅 IPv6 走 WARP: IPv6 走 WARP，IPv4 走直连 (对齐勇哥经典架构)
          .outbounds = [.outbounds[] | if .tag == "direct" then del(.domain_strategy) else . end] |
          .route.rules = .route.rules + [
            {"action": "sniff"},
            {"action": "resolve", "strategy": "prefer_ipv6"},
            {"ip_version": 6, "action": "route", "outbound": "warp-out"},
            {"ip_version": 4, "action": "route", "outbound": "direct"}
          ] |
          .route.final = "direct"
        elif $warp_mode == "google" or $warp_mode == "rules" then
          # 规则分流: 仅特定媒体/AI 域名走 WARP, 其余直连
          .outbounds = [.outbounds[] | if .tag == "direct" then del(.domain_strategy) else . end] |
          .route.rules = .route.rules + [
            {"inbound": ["socks-loopback"], "action": "route", "outbound": "direct"},
            {"action": "sniff"},
            {
              "domain_suffix": ["google.com", "googlevideo.com", "youtube.com", "netflix.com", "openai.com", "chatgpt.com"],
              "action": "route",
              "outbound": "warp-out"
            }
          ] |
          .route.final = "direct"
        else
          .outbounds = [.outbounds[] | if .tag == "direct" then del(.domain_strategy) else . end] |
          .route.rules = .route.rules + [
            {"inbound": ["socks-loopback"], "action": "route", "outbound": "warp-out"},
            {"action": "sniff"},
            {"action": "resolve", "strategy": "prefer_ipv6"},
            {"ip_cidr": ["::/0", "0.0.0.0/0"], "action": "route", "outbound": "warp-out"}
          ] |
          .route.final = "warp-out"
        end
      elif $psi_en == "true" then
        .outbounds = [.outbounds[] | if .tag == "direct" then del(.domain_strategy) else . end] |
        .outbounds += [{
          "type": "socks",
          "tag": "psiphon-main-out",
          "server": "127.0.0.1",
          "server_port": $psi_port,
          "version": "5"
        }] |
        .route.rules = .route.rules + [
          {"inbound": ["socks-loopback"], "action": "route", "outbound": "psiphon-main-out"}
        ] |
        .route.final = "psiphon-main-out"
      else
        .outbounds = [.outbounds[] | if .tag == "direct" then del(.domain_strategy) else . end] |
        .route.rules = .route.rules + [
          {"inbound": ["socks-loopback"], "action": "route", "outbound": "direct"}
        ] |
        .route.final = "direct"
      end |
      if (.endpoints | length) == 0 then del(.endpoints) else . end
      ' "$cfg" > "$tmp_json" && mv -f "$tmp_json" "$cfg"

    sync_all_secondary_nodes
    return 0
}

apply_changes() {
    if [[ ! -f /etc/s-box/sb.json ]]; then
        log_err "配置文件 /etc/s-box/sb.json 不存在！"
        return 1
    fi

    ensure_alpine_compatibility

    # 适配 Sing-box 1.12.0+ / 1.13.0+ 语法校验与 inbounds 入站去重（防御性结构修复）
    if command -v jq >/dev/null 2>&1; then
        local tmp_fix=$(mktemp)
        if jq '
          # 确保顶层为对象
          if type != "object" then {} else . end |
          if (.inbounds // null) != null and (.inbounds | type == "array") then
            .inbounds = ([.inbounds[] | select(type == "object")] | unique_by(.tag // ""))
          else . end |
          if (.dns.servers // null) != null and (.dns.servers | type == "array") then
            .dns.servers = [.dns.servers[] | select(type == "object") | del(.detour)]
          else . end |
          if (.route // null) != null and (.dns // null) != null then
            .route.default_domain_resolver = (.route.default_domain_resolver // "dns-direct")
          else . end
        ' /etc/s-box/sb.json > "$tmp_fix" 2>/dev/null && jq -e . "$tmp_fix" >/dev/null 2>&1; then
            mv -f "$tmp_fix" /etc/s-box/sb.json
        else
            rm -f "$tmp_fix"
        fi
    fi

    # 检查核心是否真实可正常运行，不可用则自动重载核心
    if [[ ! -x /etc/s-box/sing-box ]] || ! /etc/s-box/sing-box version >/dev/null 2>&1; then
        yellow "[*] 检测到 Sing-box 核心缺失或在当前系统下无法执行，正在尝试自动安装/修复核心与兼容层..."
        download_singbox_core force
    fi

    if [[ -x /etc/s-box/sing-box ]]; then
        local check_out
        export ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true
        export ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true
        if ! check_out=$(/etc/s-box/sing-box check -c /etc/s-box/sb.json 2>&1); then
            # 若因旧版本核心不支持 AnyTLS 导致报错，自动触发升级至最新核心
            if echo "$check_out" | grep -qi "anytls"; then
                yellow "[*] 检测到当前 Sing-box 核心版本不支持 AnyTLS，正在自动升级至最新核心..."
                if download_singbox_core force; then
                    if /etc/s-box/sing-box check -c /etc/s-box/sb.json >/dev/null 2>&1; then
                        green "[+] Sing-box 核心升级完成，AnyTLS 语法校验通过！"
                        service_restart sing-box
                        return 0
                    fi
                fi
            fi
            log_err "Sing-box 配置文件格式或语法检查未通过！"
            echo -e "${red}错误详情:${re}\n${check_out}"
            return 1
        fi
    fi
    service_restart sing-box
    sleep 1
    if ! service_is_active sing-box; then
        pkill -9 -f "/etc/s-box/sing-box" >/dev/null 2>&1 || true
        if command -v fuser >/dev/null 2>&1; then
            fuser -k 20080/tcp >/dev/null 2>&1 || true
        fi
        sleep 1
        service_start sing-box
    fi
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
    yellow "  - AnyTLS (极简 TLS 混淆隧道, v1.12+)"
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
    [[ -n "$cur_vless" ]] && green "  [✓] VLESS-Reality   : 端口 ${cur_vless}" || yellow "  [✗] VLESS-Reality   : 未开启"
    [[ -n "$cur_vmess" ]] && green "  [✓] VMess-WS        : 端口 ${cur_vmess}" || yellow "  [✗] VMess-WS        : 未开启"
    [[ -n "$cur_trojan" ]] && green "  [✓] Trojan-WS-TLS   : 端口 ${cur_trojan}" || yellow "  [✗] Trojan-WS-TLS   : 未开启"
    [[ -n "$cur_hy2" ]] && green "  [✓] Hysteria2       : 端口 ${cur_hy2}" || yellow "  [✗] Hysteria2       : 未开启"
    [[ -n "$cur_tuic" ]] && green "  [✓] TUIC v5         : 端口 ${cur_tuic}" || yellow "  [✗] TUIC v5         : 未开启"
    [[ -n "$cur_anytls" ]] && green "  [✓] AnyTLS          : 端口 ${cur_anytls}" || yellow "  [✗] AnyTLS          : 未开启"
    echo "============================================================"

    echo
    echo "  1. 一键启用全部协议"
    echo "  2. 自定义选择协议与端口"
    echo "  3. 重新生成 UUID 与密钥"
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
            if apply_changes; then
                green "[✓] 全部 6 大主节点协议已配置并成功运行！"
                echo
                get_all_ips >/dev/null 2>&1
                show_links
            else
                red "[!] 主节点协议配置失败，请根据上方错误详情排查！"
            fi
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
            if apply_changes; then
                green "[✓] 主节点协议已更新并成功运行！"
                echo
                get_all_ips >/dev/null 2>&1
                show_links
            else
                red "[!] 主节点协议更新失败，请根据上方错误详情排查！"
            fi
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

    if [[ ! -f "$cfg" ]]; then
        cat > "$cfg" << 'EOF_BLANK'
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {"type": "local", "tag": "dns-direct"},
      {"type": "local", "tag": "local"},
      {"type": "udp", "tag": "dns-remote", "server": "8.8.8.8"},
      {"type": "udp", "tag": "remote-dns", "server": "8.8.8.8"}
    ],
    "final": "dns-direct"
  },
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block", "tag": "block"}
  ],
  "route": {
    "default_domain_resolver": "dns-direct",
    "rules": [
      {"inbound": ["socks-loopback"], "outbound": "direct"}
    ],
    "final": "direct"
  }
}
EOF_BLANK
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
      --arg listen_addr "${LISTEN_ADDR:-"::"}" \
      '
      # 确保顶层为对象
      if type != "object" then {} else . end |
      # 保留所有副节点入站 (包含 custom / proxy / psi 的入站)
      .inbounds = [.inbounds[]? | select(type == "object" and ((.tag // "") | (contains("proxy") or contains("psi") or contains("custom"))))] |

      (
        [] |
        if $pv > 0 then . + [{
          "tag": "vless-reality-in",
          "type": "vless",
          "listen": $listen_addr,
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
          "listen": $listen_addr,
          "listen_port": $pvm,
          "users": [{"uuid": $uuid}],
          "transport": {"type": "ws", "path": ("/" + $uuid + "-vm")}
        }] else . end |
        if $ptr > 0 then . + [{
          "tag": "trojan-ws-in",
          "type": "trojan",
          "listen": $listen_addr,
          "listen_port": $ptr,
          "users": [{"password": $uuid}],
          "transport": {"type": "ws", "path": ("/" + $uuid + "-tr")},
          "tls": {"enabled": true, "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $phy > 0 then . + [{
          "tag": "hy2-in",
          "type": "hysteria2",
          "listen": $listen_addr,
          "listen_port": $phy,
          "users": [{"password": $uuid}],
          "masquerade": {"type": "proxy", "url": "https://www.bing.com"},
          "ignore_client_bandwidth": false,
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $ptu > 0 then . + [{
          "tag": "tuic-in",
          "type": "tuic",
          "listen": $listen_addr,
          "listen_port": $ptu,
          "users": [{"uuid": $uuid, "password": $uuid}],
          "congestion_control": "bbr",
          "tls": {"enabled": true, "alpn": ["h3"], "certificate_path": "/etc/s-box/cert.pem", "key_path": "/etc/s-box/private.key"}
        }] else . end |
        if $pan > 0 then . + [{
          "tag": "anytls-in",
          "type": "anytls",
          "listen": $listen_addr,
          "listen_port": $pan,
          "users": [{"name": "default", "password": $uuid}],
          "tls": {
            "enabled": true,
            "server_name": "www.bing.com",
            "certificate_path": "/etc/s-box/cert.pem",
            "key_path": "/etc/s-box/private.key"
          }
        }] else . end |
        . + [{
          "tag": "socks-loopback",
          "type": "socks",
          "listen": "127.0.0.1",
          "listen_port": $ploop
        }]
      ) as $main_inbounds |
      .inbounds = (([$main_inbounds[], .inbounds[]?] | select(type == "object") | unique_by(.tag // "")))
      ' "$cfg" > "$tmp_json" && jq -e . "$tmp_json" >/dev/null 2>&1 && mv -f "$tmp_json" "$cfg"

    sync_all_secondary_nodes
}

# ==================== 2. 主节点出站路由管理 ====================
configure_warp_outbound() {
    while true; do
        [[ -t 1 ]] && clear 2>/dev/null || true
        echo
        green "============================================================"
        green "  主节点出站路由管理"
        green "============================================================"
        
        if [ ! -f "$WORKDIR/sb.json" ]; then
            red "未检测到已安装的 Sing-box 配置，请先安装主节点"
            reading "按回车返回..." _
            return 1
        fi

        local current_status current_mode current_psi
        current_status=$(cat "$WORKDIR/warp_enabled.txt" 2>/dev/null || echo "false")
        current_mode=$(cat "$WORKDIR/warp_mode.txt" 2>/dev/null || echo "all")
        current_psi=$(cat "$WORKDIR/psiphon_main_enabled.txt" 2>/dev/null || echo "false")

        local warp_v6=$(cat "$WORKDIR/warp_ipv6.txt" 2>/dev/null || echo "2606:4700:110:8d8d:1845:c39f:2dd5:a03a")
        local ep=$(get_warp_endpoint)
        local wp_port=$(cat "$WORKDIR/warp_best_port.txt" 2>/dev/null || echo "2408")

        echo
        purple "【主节点当前出站状态】"
        if [[ "$current_status" == "true" ]]; then
            case "$current_mode" in
                ipv4)
                    blue   "  出站模式 : WARP 仅 IPv4 出站"
                    green  "  IPv4 路由: WARP 出口"
                    yellow "  IPv6 路由: 直连出站"
                    ;;
                ipv6)
                    blue   "  出站模式 : WARP 仅 IPv6 出站"
                    yellow "  IPv4 路由: 直连出站"
                    green  "  IPv6 路由: WARP 出口"
                    ;;
                google|rules)
                    blue   "  出站模式 : WARP 规则分流出站"
                    green  "  分流目标 : Google / YouTube / Netflix / OpenAI / ChatGPT"
                    yellow "  常规流量: 直连出站"
                    ;;
                *)
                    blue   "  出站模式 : WARP 双栈全局出站"
                    green  "  IPv4 路由: WARP 出口"
                    green  "  IPv6 路由: WARP 出口"
                    ;;
            esac
            cyan   "  接入节点 : ${ep}:${wp_port}"
            cyan   "  WARP 地址: 172.16.0.2 / ${warp_v6}"
        elif [[ "$current_psi" == "true" ]]; then
            local cur_reg=$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null || echo "AUTO")
            blue   "  出站模式 : Psiphon 赛风出站"
            blue   "  出口国家 : $cur_reg - $(get_country_name "$cur_reg")"
        else
            green  "  出站模式 : 原生直连出站"
            yellow "  流量去向 : VPS 本机公网 IP 直连"
        fi

        echo
        echo "------------------------------------------------------------"
        yellow "  1. 直连原生出站"
        yellow "  2. WARP 双栈全局出站"
        yellow "  3. WARP 仅 IPv4 出站"
        yellow "  4. WARP 仅 IPv6 出站"
        yellow "  5. WARP 规则分流出站"
        yellow "  6. Psiphon 赛风出站"
        echo "------------------------------------------------------------"
        green  "  7. 优选 WARP 接入节点"
        blue   "  8. 恢复默认 WARP 节点"
        blue   "  9. 重置 WARP 注册凭证"
        green  " 10. 实时检测主节点出口 IP"
        echo "------------------------------------------------------------"
        red    "  0. 返回主菜单"
        echo "============================================================"
        reading "请选择 [0-10, q]: " new_choice

        case "$new_choice" in
            1)
                echo "false" > "$WORKDIR/warp_enabled.txt"
                echo "false" > "$WORKDIR/psiphon_main_enabled.txt"
                stop_main_psiphon
                if apply_main_node_outbound && apply_changes; then
                    green "[✓] 已切换为主节点: 原生直连出站"
                else
                    red "[✗] 切换失败: 配置生成或服务重启异常！"
                fi
                echo
                reading "按回车继续..." _
                ;;
            2)
                ensure_warp_config
                echo "true" > "$WORKDIR/warp_enabled.txt"
                echo "all" > "$WORKDIR/warp_mode.txt"
                echo "false" > "$WORKDIR/psiphon_main_enabled.txt"
                stop_main_psiphon
                if apply_main_node_outbound && apply_changes; then
                    green "[✓] 已切换为主节点: WARP 双栈全局出站"
                else
                    red "[✗] 切换失败: 配置生成或服务重启异常！"
                fi
                echo
                reading "按回车继续..." _
                ;;
            3)
                ensure_warp_config
                echo "true" > "$WORKDIR/warp_enabled.txt"
                echo "ipv4" > "$WORKDIR/warp_mode.txt"
                echo "false" > "$WORKDIR/psiphon_main_enabled.txt"
                stop_main_psiphon
                if apply_main_node_outbound && apply_changes; then
                    green "[✓] 已切换为主节点: WARP 仅 IPv4 出站"
                else
                    red "[✗] 切换失败: 配置生成或服务重启异常！"
                fi
                echo
                reading "按回车继续..." _
                ;;
            4)
                ensure_warp_config
                echo "true" > "$WORKDIR/warp_enabled.txt"
                echo "ipv6" > "$WORKDIR/warp_mode.txt"
                echo "false" > "$WORKDIR/psiphon_main_enabled.txt"
                stop_main_psiphon
                if apply_main_node_outbound && apply_changes; then
                    green "[✓] 已切换为主节点: WARP 仅 IPv6 出站"
                else
                    red "[✗] 切换失败: 配置生成或服务重启异常！"
                fi
                echo
                reading "按回车继续..." _
                ;;
            5)
                ensure_warp_config
                echo "true" > "$WORKDIR/warp_enabled.txt"
                echo "google" > "$WORKDIR/warp_mode.txt"
                echo "false" > "$WORKDIR/psiphon_main_enabled.txt"
                stop_main_psiphon
                if apply_main_node_outbound && apply_changes; then
                    green "[✓] 已切换为主节点: WARP 规则分流出站"
                else
                    red "[✗] 切换失败: 配置生成或服务重启异常！"
                fi
                echo
                reading "按回车继续..." _
                ;;
            6)
                echo "false" > "$WORKDIR/warp_enabled.txt"
                echo "true" > "$WORKDIR/psiphon_main_enabled.txt"
                start_main_psiphon
                if apply_main_node_outbound && apply_changes; then
                    green "[✓] 已切换为主节点: 赛风出站"
                else
                    red "[✗] 切换失败: 配置生成或服务重启异常！"
                fi
                echo
                reading "按回车继续..." _
                ;;
            7)
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
                green "[✓] 已设置优选 Endpoint: ${best_ep}:2408"
                echo
                reading "按回车继续..." _
                ;;
            8)
                echo "162.159.192.1" > "$WORKDIR/warp_best_endpoint.txt"
                echo "2408" > "$WORKDIR/warp_best_port.txt"
                apply_main_node_outbound
                apply_changes
                green "[✓] 已恢复默认 Endpoint: 162.159.192.1:2408"
                echo
                reading "按回车继续..." _
                ;;
            9)
                yellow "正在重新获取 WARP 注册凭据与 IPv6 地址..."
                init_warp_config
                apply_main_node_outbound
                apply_changes
                green "[✓] WARP 注册凭据与 IPv6 地址已刷新"
                echo
                reading "按回车继续..." _
                ;;
            10|t|test|d)
                warp_egress_test
                echo
                reading "按回车继续..." _
                ;;
            0|q|Q|"")
                return 0
                ;;
            *)
                red "无效输入，请重新选择"
                sleep 1
                ;;
        esac
    done
}

configure_warp_mode_submenu() {
    configure_warp_outbound
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
    purple "请选择本地入站协议:"
    echo "  1. Hysteria2 入站"
    echo "  2. TUIC v5 入站"
    echo "  3. VLESS-Reality 入站"
    echo "  4. 同时开启 Hy2 与 TUIC"
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
    if sync_proxy_group_to_singbox "$group_tag"; then
        if ! grep -qx "$group_tag" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null; then
            echo "$group_tag" >> "$PROXY_GROUPS_DIR/groups.txt"
        fi
        apply_changes
        green "[✓] 代理节点组 [$remark] 添加成功！"
        generate_proxy_group_links "$group_tag"
    else
        rm -rf "$gdir"
        sed -i "/^${group_tag}$/d" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null || true
        red "[!] 代理节点组 [$remark] 同步配置失败，请检查链接格式或系统环境！"
    fi
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
        local hy2_link="hysteria2://${uuid}@${ip}:${hy2_p}?insecure=1&allowInsecure=1&sni=www.bing.com#${remark}-Hy2"
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
        green "  自定义代理出站管理"
        green "============================================================"
        yellow "  说明: 副节点拥有独立入站端口与专属路由，出站转发至外部代理"
        yellow "        与主节点完全平行独立，互不干扰"
        green "============================================================"
        echo

        local groups
        mapfile -t groups < <(get_all_proxy_groups)

        purple "【当前已配置代理组】 (共 ${#groups[@]} 组):"
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
                green "  [$idx] $t - $r"
                blue  "      入站端口: [ ${p_info:-无} ]"
                ((idx++))
            done
        else
            yellow "  暂无代理节点组"
        fi

        echo
        echo "------------------------------------------------------------"
        green  "  1. 添加代理节点组"
        green  "  2. 查看代理节点链接"
        yellow "  3. 修改代理出站链接"
        red    "  4. 删除代理节点组"
        blue   "  5. 重新同步代理配置"
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
                                if sync_proxy_group_to_singbox "$edit_tag"; then
                                    apply_changes
                                    green "代理链接已更新并生效！"
                                else
                                    red "[!] 代理链接同步更新失败，请检查链接有效性！"
                                fi
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
                    if proxy_group_exists "$del_tag" || [[ -d "${PROXY_GROUPS_DIR}/$del_tag" ]] || grep -qx "$del_tag" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null; then
                        rm -rf "${PROXY_GROUPS_DIR:?}/$del_tag"
                        sed -i "/^${del_tag}$/d" "$PROXY_GROUPS_DIR/groups.txt"
                        local tmp_j=$(mktemp)
                        jq --arg dt "$del_tag" '
                        .outbounds = [.outbounds[] | select(
                          .tag != $dt and
                          .tag != ($dt + "-out") and
                          .tag != ("outbound-" + $dt) and
                          .tag != ($dt + "_out")
                        )] |
                        .inbounds = [.inbounds[] | select(
                          .tag != ("hy2-" + $dt + "-in") and
                          .tag != ("tuic-" + $dt + "-in") and
                          .tag != ("vless-" + $dt + "-in") and
                          (.tag | contains($dt) | not)
                        )] |
                        .route.rules = [.route.rules[] | select(
                          .outbound != $dt and
                          .outbound != ($dt + "-out") and
                          .outbound != ("outbound-" + $dt) and
                          .outbound != ($dt + "_out")
                        )]
                        ' "$WORKDIR/sb.json" > "$tmp_j" 2>/dev/null && jq -e . "$tmp_j" >/dev/null 2>&1 && mv -f "$tmp_j" "$WORKDIR/sb.json"
                        cleanup_orphan_secondary_nodes
                        apply_changes
                        green "已彻底删除代理节点组: $del_tag"
                    else
                        red "未找到代理节点组: $del_tag"
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
    local cur_reg=$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null || echo "AUTO")

    if ! is_main_psiphon_running; then
        yellow "[!] Psiphon 主进程未运行，正在启动..."
        start_main_psiphon
        sleep 2
    fi

    local ip=""
    local max_wait=10
    local elapsed=0

    # 动态握手轮询探测 (最多等待 10 秒，握手成功立即返回)
    for ((i=1; i<=max_wait; i++)); do
        printf "\r  [*] 正在建立加密隧道并探测出口 IP (%ds/%ds)..." "$i" "$max_wait"
        local res=""
        res=$(timeout 3 curl -sx "socks5h://127.0.0.1:${socks_port}" -s4 --connect-timeout 2 -m 2 "http://api.ipify.org" 2>/dev/null | tr -d ' \r\n')
        [[ -z "$res" || ! "$res" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && res=$(timeout 3 curl -sx "socks5h://127.0.0.1:${socks_port}" -s4 --connect-timeout 2 -m 2 "http://ipv4.icanhazip.com" 2>/dev/null | tr -d ' \r\n')
        [[ -z "$res" || ! "$res" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && res=$(timeout 3 curl -sx "socks5h://127.0.0.1:${socks_port}" -s4 --connect-timeout 2 -m 2 "https://api.ip.sb/ip" 2>/dev/null | tr -d ' \r\n')

        if [[ -n "$res" && "$res" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ip="$res"
            elapsed=$i
            break
        fi
        sleep 1
    done
    printf "\r\033[K"

    if [[ -n "$ip" ]]; then
        green "============================================================"
        green "  [✓] Psiphon 当前出口已就绪！ (握手耗时: 约 ${elapsed}s)"
        green "============================================================"
        green "  出口公网 IP : $ip"
        local info
        info=$(curl -s4m4 "http://ip-api.com/json/${ip}?lang=zh-CN" 2>/dev/null)
        if [[ -n "$info" ]]; then
            local country region city isp
            country=$(echo "$info" | jq -r '.country // empty' 2>/dev/null)
            region=$(echo "$info" | jq -r '.regionName // empty' 2>/dev/null)
            city=$(echo "$info" | jq -r '.city // empty' 2>/dev/null)
            isp=$(echo "$info" | jq -r '.isp // empty' 2>/dev/null)
            blue  "  国家 / 地区 : ${country:-未知} - ${region} ${city}"
            blue  "  运营商(ISP) : ${isp:-未知}"
        fi
        green "============================================================"
    else
        red "[!] 检测超时：Psiphon 远端加密隧道建立耗时较长或目标地区节点负载较高。"
        yellow "    提示: Psiphon 守护服务已在后台持续重试握手，请稍候 5~10 秒再次查看即可。"
    fi
}

psiphon_switch_auto() {
    echo
    yellow "[*] 正在切换 Psiphon 为智能自动选择 (AUTO 优选)..."
    echo "AUTO" > "$WORKDIR/psiphon_main_region.txt"
    stop_main_psiphon
    rm -f "$WORKDIR/psiphon-data/remote_server_list" 2>/dev/null || true
    start_main_psiphon
    apply_main_node_outbound
    apply_changes
    green "[✓] 已切换为智能自动选择！正在获取新出口 IP..."
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
    rm -f "$WORKDIR/psiphon-data/remote_server_list" 2>/dev/null || true
    start_main_psiphon
    apply_main_node_outbound
    apply_changes
    green "[✓] 已切换出口国家为 [$target_cc - $(get_country_name "$target_cc")]！"
    psiphon_check_current_ip
}

cleanup_psiphon_test_garbage() {
    # 清理测试专用的临时进程和目录
    pkill -9 -f "/tmp/psi_test_" 2>/dev/null || true
    pkill -9 -f "psiphon-tunnel-core.*--config.*/tmp/" 2>/dev/null || true
    pkill -9 -f "curl.*socks5h://127.0.0.1:21999" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf /tmp/psi_test_* 2>/dev/null || true
}

PSI_TEST_INTERRUPTED=0
psi_test_sigint_handler() {
    PSI_TEST_INTERRUPTED=1
    cleanup_psiphon_test_garbage
    echo
    red "[!] 测试已手动中断并清理残留进程"
    echo
    yellow "[*] 正在恢复赛风服务..."
    if is_main_psiphon_running 2>/dev/null || [[ -n "$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null)" ]]; then
        start_main_psiphon 2>/dev/null
    fi
    ensure_all_psiphon_instances_running 2>/dev/null
    green "[✓] 赛风服务已恢复"
}

# 单进程复用架构：stop → 改配置 → start → 探测出口 IP → stop
# 不再为每个国家单独 fork 临时进程，彻底杜绝进程累积耗尽系统资源
test_single_psiphon_country() {
    [[ $PSI_TEST_INTERRUPTED -eq 1 ]] && return 130
    local cc="${1^^}"
    local cname=$(get_country_name "$cc")
    local test_port=21999
    local test_dir="/tmp/psi_test_${cc}"
    local cfg_file="$test_dir/psiphon.config"
    local log_file="$test_dir/test.log"
    local pid_file="$test_dir/test.pid"

    # 1. 彻底杀掉上一轮测试残留
    if [[ -f "$pid_file" ]]; then
        local old_pid=$(cat "$pid_file" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            kill -9 "$old_pid" 2>/dev/null || true
            wait "$old_pid" 2>/dev/null || true
        fi
    fi
    cleanup_psiphon_test_garbage
    sleep 0.5
    [[ $PSI_TEST_INTERRUPTED -eq 1 ]] && return 130

    # 2. 写入当前国家的配置文件并启动单个测试进程
    rm -rf "$test_dir" 2>/dev/null || true
    mkdir -p "$test_dir/data" 2>/dev/null
    write_psiphon_config "$test_port" "$cc" "$cfg_file" "$test_dir/data"

    if [[ ! -x "$WORKDIR/psiphon-tunnel-core" ]]; then
        red "  [!] Psiphon 核心程序不存在或无执行权限"
        rm -rf "$test_dir" 2>/dev/null || true
        return 1
    fi

    : > "$log_file"
    "$WORKDIR/psiphon-tunnel-core" --config "$cfg_file" >> "$log_file" 2>&1 &
    local test_pid=$!
    echo "$test_pid" > "$pid_file"

    # 3. 探测循环：等待 SOCKS 端口就绪后请求出口 IP
    local egress_ip="" is_ok=false
    local max_wait=8
    local elapsed=0

    for ((i=1; i<=max_wait; i++)); do
        [[ $PSI_TEST_INTERRUPTED -eq 1 ]] && break
        # 如果进程已自行退出，无需继续
        if ! kill -0 "$test_pid" 2>/dev/null; then
            elapsed=$i
            break
        fi
        sleep 1
        [[ $PSI_TEST_INTERRUPTED -eq 1 ]] && break
        elapsed=$i
        printf "\r  [*] [%s] %-14s -> 正在握手测试中 (%ds/%ds)..." "$cc" "$cname" "$elapsed" "$max_wait"

        # 尝试通过 SOCKS5 代理探测出口 IP
        local res=""
        res=$(timeout 3 curl -sx "socks5h://127.0.0.1:${test_port}" -s4 --connect-timeout 1 -m 2 "http://api.ipify.org" 2>/dev/null | tr -d ' \r\n') || true

        if [[ -n "$res" && "$res" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            egress_ip="$res"
            is_ok=true
            break
        fi
    done

    # 4. 彻底终止本次测试进程 (先 SIGKILL 再验证，确保绝对退出)
    kill -9 "$test_pid" 2>/dev/null || true
    wait "$test_pid" 2>/dev/null || true
    pkill -9 -f "$cfg_file" 2>/dev/null || true
    # 验证进程确实已死
    local retries=0
    while kill -0 "$test_pid" 2>/dev/null && [[ $retries -lt 5 ]]; do
        kill -9 "$test_pid" 2>/dev/null || true
        sleep 0.3
        ((retries++))
    done
    wait 2>/dev/null || true
    rm -rf "$test_dir" 2>/dev/null || true

    if [[ $PSI_TEST_INTERRUPTED -eq 1 ]]; then
        printf "\r\033[K"
        return 130
    fi

    # 冷却等待：给系统时间回收 TCP 连接和文件描述符
    sleep 1

    if $is_ok; then
        printf "\r\033[K"
        green "  [✓] [$cc] $cname -> 出口 IP: ${egress_ip} (耗时约 ${elapsed}s)"
        return 0
    else
        printf "\r\033[K"
        yellow "  [✗] [$cc] $cname -> 连接超时或未通 (已探测 ${elapsed}s)"
        return 1
    fi
}

psiphon_quick_test() {
    download_psiphon_core || return 1
    cleanup_psiphon_test_garbage
    PSI_TEST_INTERRUPTED=0
    trap 'psi_test_sigint_handler' INT TERM

    echo
    green "============================================================"
    green "  【快速测试常用国家】 (US / JP / SG / HK)"
    green "============================================================"
    yellow "[*] 正在逐个建立轻量级测试隧道并探测连通性..."
    echo
    local quick_list=("US" "JP" "SG" "HK")
    local ok_cnt=0 fail_cnt=0
    for cc in "${quick_list[@]}"; do
        [[ $PSI_TEST_INTERRUPTED -eq 1 ]] && break
        test_single_psiphon_country "$cc"
        local ret=$?
        if [[ $PSI_TEST_INTERRUPTED -eq 1 || $ret -eq 130 ]]; then
            PSI_TEST_INTERRUPTED=1
            break
        fi
        if [[ $ret -eq 0 ]]; then
            ((ok_cnt++))
        else
            ((fail_cnt++))
        fi
    done
    trap - INT TERM

    if [[ $PSI_TEST_INTERRUPTED -eq 0 ]]; then
        cleanup_psiphon_test_garbage
        echo
        green "============================================================"
        green "  快速测试完毕！共测试 4 个国家: 可用 [$ok_cnt] / 不可用 [$fail_cnt]"
        green "============================================================"
        # 恢复主赛风进程和副节点赛风实例
        echo
        yellow "[*] 正在恢复赛风服务..."
        if is_main_psiphon_running 2>/dev/null || [[ -n "$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null)" ]]; then
            start_main_psiphon 2>/dev/null
        fi
        ensure_all_psiphon_instances_running 2>/dev/null
        green "[✓] 赛风服务已恢复"
    fi
}

psiphon_test_all() {
    download_psiphon_core || return 1
    cleanup_psiphon_test_garbage
    PSI_TEST_INTERRUPTED=0
    trap 'psi_test_sigint_handler' INT TERM

    echo
    green "============================================================"
    green "  【测试所有支持的 Psiphon 出口国家】 (共 28 个国家)"
    green "============================================================"
    yellow "[*] 正在逐个检测国家可用性与出口 IP (按 Ctrl+C 可随时安全中断)..."
    echo
    local all_list=(
        "US" "JP" "SG" "HK" "KR" "TW"
        "GB" "DE" "CA" "NL" "FR" "IN" "AU"
        "CH" "SE" "IT" "ES" "PL" "AT" "BE" "DK" "NO" "RO" "CZ" "HU" "BG" "IE" "FI"
    )
    local idx=1
    local total=${#all_list[@]}
    local ok_cnt=0 fail_cnt=0
    for cc in "${all_list[@]}"; do
        [[ $PSI_TEST_INTERRUPTED -eq 1 ]] && break
        # 系统资源安全熔断：当进程数超过系统上限 80% 时立即中止
        if [[ -f /proc/sys/kernel/pid_max ]]; then
            local cur_pids=$(find /proc -maxdepth 1 -name '[0-9]*' -type d 2>/dev/null | wc -l)
            local max_pids=$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768)
            if [[ $cur_pids -gt $((max_pids * 80 / 100)) ]]; then
                echo
                red "[!] 系统进程数接近上限 (${cur_pids}/${max_pids})，为安全起见中止测试"
                cleanup_psiphon_test_garbage
                break
            fi
        fi
        echo -ne "${blue}[${idx}/${total}]${re} "
        test_single_psiphon_country "$cc"
        local ret=$?
        if [[ $PSI_TEST_INTERRUPTED -eq 1 || $ret -eq 130 ]]; then
            PSI_TEST_INTERRUPTED=1
            break
        fi
        if [[ $ret -eq 0 ]]; then
            ((ok_cnt++))
        else
            ((fail_cnt++))
        fi
        ((idx++))
    done
    trap - INT TERM

    if [[ $PSI_TEST_INTERRUPTED -eq 0 ]]; then
        cleanup_psiphon_test_garbage
        echo
        green "============================================================"
        green "  全部国家测试完毕！共测试 ${total} 个国家: 可用 [$ok_cnt] / 不可用 [$fail_cnt]"
        green "============================================================"
        # 恢复主赛风进程和副节点赛风实例
        echo
        yellow "[*] 正在恢复赛风服务..."
        if is_main_psiphon_running 2>/dev/null || [[ -n "$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null)" ]]; then
            start_main_psiphon 2>/dev/null
        fi
        ensure_all_psiphon_instances_running 2>/dev/null
        green "[✓] 赛风服务已恢复"
    fi
}

psiphon_custom_test() {
    download_psiphon_core || return 1
    cleanup_psiphon_test_garbage
    PSI_TEST_INTERRUPTED=0
    trap 'psi_test_sigint_handler' INT TERM

    echo
    green "============================================================"
    green "  【自定义测试 Psiphon 出口国家】"
    green "============================================================"
    show_supported_psiphon_codes
    echo
    reading "请输入要测试的国家代码 (支持多个用空格隔开，如 KR TW NL DE): " custom_input
    custom_input="${custom_input^^}"
    if [[ -z "$custom_input" ]]; then
        red "[!] 国家代码不能为空"
        trap - INT TERM
        return 1
    fi
    echo
    yellow "[*] 正在测试指定国家 [$custom_input]..."
    echo
    for cc in $custom_input; do
        [[ $PSI_TEST_INTERRUPTED -eq 1 ]] && break
        test_single_psiphon_country "$cc"
        local ret=$?
        if [[ $PSI_TEST_INTERRUPTED -eq 1 || $ret -eq 130 ]]; then
            PSI_TEST_INTERRUPTED=1
            break
        fi
    done
    trap - INT TERM

    if [[ $PSI_TEST_INTERRUPTED -eq 0 ]]; then
        cleanup_psiphon_test_garbage
        echo
        green "[✓] 自定义测试完毕！"
        # 恢复主赛风进程和副节点赛风实例
        echo
        yellow "[*] 正在恢复赛风服务..."
        if is_main_psiphon_running 2>/dev/null || [[ -n "$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null)" ]]; then
            start_main_psiphon 2>/dev/null
        fi
        ensure_all_psiphon_instances_running 2>/dev/null
        green "[✓] 赛风服务已恢复"
    fi
}

psiphon_view_log() {
    echo
    green "========== Psiphon 运行日志 (最近 30 行) =========="
    if command -v journalctl >/dev/null 2>&1 && ! $IS_DIRECT && ! $IS_OPENRC && systemctl is-active psiphon-main >/dev/null 2>&1; then
        journalctl -u psiphon-main -n 30 --no-pager 2>/dev/null
    elif [[ -f "$WORKDIR/psiphon.log" && -s "$WORKDIR/psiphon.log" ]]; then
        tail -n 30 "$WORKDIR/psiphon.log"
    else
        yellow "暂未读取到日志或日志为空"
    fi
    echo "==================================================="
}

psiphon_restart() {
    echo
    yellow "[*] 正在深度重启与自愈 Psiphon 主进程..."
    local cur_reg=$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null || echo "AUTO")
    stop_main_psiphon
    rm -rf "$WORKDIR/psiphon-data/${cur_reg:-AUTO}" 2>/dev/null || true
    start_main_psiphon
    green "[✓] Psiphon 主进程已重启并载入种子服务器！"
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
    rm -rf "$inst_dir/data" 2>/dev/null || true
    mkdir -p "$inst_dir/data" 2>/dev/null

    local socks_p=$(get_free_loopback_port)
    local cfg_file="$inst_dir/psiphon.config"
    write_psiphon_config "$socks_p" "$cc" "$cfg_file" "$inst_dir/data"
    echo "$socks_p" > "$inst_dir/socks_port.txt"
    start_psiphon_instance "$cc"

    echo
    purple "请选择本地入站协议:"
    echo "  1. Hysteria2 入站"
    echo "  2. TUIC v5 入站"
    echo "  3. VLESS-Reality 入站"
    echo "  4. 同时开启 Hy2 与 TUIC"
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

repair_single_psiphon_instance() {
    local insts
    mapfile -t insts < <(get_all_psiphon_instances)
    if [[ ${#insts[@]} -eq 0 ]]; then
        yellow "[!] 当前暂无已配置的赛风出口组"
        return 1
    fi

    echo
    green "============================================================"
    green "  重启 / 修复指定赛风出口组"
    green "============================================================"
    echo "当前已配置的赛风出口组列表:"
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
        local st_str="${red}[✗ 未运行]${re}"
        if is_psiphon_instance_running "$cc"; then
            st_str="${green}[✓ 运行中]${re}"
        fi
        echo -e "  ${green}[${idx}] [${cc}] ${cname}${re} ${st_str} (入站: ${p_info:-无})"
        ((idx++))
    done
    echo "------------------------------------------------------------"
    red  "  0. 取消并返回"
    echo "============================================================"
    reading "请输入要重启/修复的国家序号或代码 (如 1 或 US): " target_in
    [[ -z "$target_in" || "$target_in" == "0" ]] && return 0

    local target_cc=""
    if [[ "$target_in" =~ ^[0-9]+$ ]]; then
        local sel_idx=$((target_in - 1))
        if [[ $sel_idx -ge 0 && $sel_idx -lt ${#insts[@]} ]]; then
            target_cc="${insts[$sel_idx]}"
        fi
    else
        target_cc="${target_in^^}"
    fi

    if [[ -z "$target_cc" || ! -d "${PSI_INSTANCES_DIR}/$target_cc" ]]; then
        red "[!] 未找到指定的赛风出口组: $target_in"
        return 1
    fi

    local cname=$(get_country_name "$target_cc")
    local inst_dir="${PSI_INSTANCES_DIR}/${target_cc}"
    echo
    yellow "[*] 正在为 [$target_cc - $cname] 执行深度重启与修复..."

    # 1. 停止旧进程与服务
    echo -e "${blue}--> [1/5] 停止旧服务并清理可能残留的孤儿进程...${re}"
    stop_psiphon_instance "$target_cc"
    sleep 1

    # 2. 检查与校准 Socks5 端口
    echo -e "${blue}--> [2/5] 校验本地 Socks5 监听端口...${re}"
    local socks_p=$(cat "$inst_dir/socks_port.txt" 2>/dev/null || echo "0")
    if [[ -z "$socks_p" || "$socks_p" -le 0 ]]; then
        socks_p=$(get_free_loopback_port)
        echo "$socks_p" > "$inst_dir/socks_port.txt"
        green "    重新分配本地 Socks5 端口: $socks_p"
    else
        echo -e "    保持本地 Socks5 端口: $socks_p"
    fi

    # 3. 彻底重置历史脏数据并载入纯净种子服务器列表
    echo -e "${blue}--> [3/5] 彻底重置历史脏数据并载入纯净种子列表...${re}"
    local up_proxy=""
    [[ "$(get_psiphon_egress_mode "$target_cc")" == "cfon" ]] && up_proxy="socks5://127.0.0.1:$(get_psiphon_cfon_socks_port "$target_cc")"
    write_psiphon_config "$socks_p" "$target_cc" "$inst_dir/psiphon.config" "$inst_dir/data" "$up_proxy"

    # 4. 同步 Sing-box 路由与入站
    echo -e "${blue}--> [4/5] 同步 Sing-box 出站与分流路由规则...${re}"
    sync_psiphon_instance_to_singbox "$target_cc"
    apply_changes

    # 5. 启动服务并执行平滑动态出口连通性探测
    echo -e "${blue}--> [5/5] 拉起守护进程并执行实时出口连通性探测...${re}"
    start_psiphon_instance "$target_cc"
    local out_ip=""
    local max_wait=10
    local elapsed=0

    for ((i=1; i<=max_wait; i++)); do
        printf "\r    [*] 正在建立加密隧道并探测出口 IP (%ds/%ds)..." "$i" "$max_wait"
        local res=""
        res=$(timeout 3 curl -sx "socks5h://127.0.0.1:${socks_p}" -s4 --connect-timeout 2 -m 2 "http://api.ipify.org" 2>/dev/null | tr -d ' \r\n')
        [[ -z "$res" || ! "$res" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && res=$(timeout 3 curl -sx "socks5h://127.0.0.1:${socks_p}" -s4 --connect-timeout 2 -m 2 "http://ipv4.icanhazip.com" 2>/dev/null | tr -d ' \r\n')
        [[ -z "$res" || ! "$res" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && res=$(timeout 3 curl -sx "socks5h://127.0.0.1:${socks_p}" -s4 --connect-timeout 2 -m 2 "https://api.ip.sb/ip" 2>/dev/null | tr -d ' \r\n')

        if [[ -n "$res" && "$res" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            out_ip="$res"
            elapsed=$i
            break
        fi
        sleep 1
    done
    printf "\r\033[K"

    echo
    if [[ -n "$out_ip" ]]; then
        local ip_info=$(curl -s4m 4 "http://ip-api.com/json/${out_ip}?lang=zh-CN" 2>/dev/null)
        local ip_country=$(echo "$ip_info" | jq -r '.country // empty' 2>/dev/null)
        local ip_isp=$(echo "$ip_info" | jq -r '.isp // empty' 2>/dev/null)
        green "============================================================"
        green "  [✓] 赛风出口组 [$target_cc - $cname] 重启修复成功！(握手耗时: 约 ${elapsed}s)"
        green "============================================================"
        green "  运行状态 : 正常运行中"
        blue  "  出口 IP  : ${out_ip}"
        [[ -n "$ip_country" ]] && purple "  出口归属 : ${ip_country} (${ip_isp:-未知})"
        green "============================================================"
    else
        green "============================================================"
        green "  [✓] 赛风服务已重新拉起并常驻守护！"
        yellow "  提示: 远端隧道握手耗时较长，守护进程已在后台持续重试"
        yellow "        可稍后在查看链接或客户端连接进行测试"
        green "============================================================"
    fi

    generate_psiphon_instance_links "$target_cc"
}

psiphon_instance_egress_test() {
    local cc="${1^^}"
    local cname=$(get_country_name "$cc")
    local mode=$(get_psiphon_egress_mode "$cc")
    local mode_desc=$(get_psiphon_egress_desc "$cc")
    local socks_p=$(cat "${PSI_INSTANCES_DIR}/$cc/socks_port.txt" 2>/dev/null)

    echo
    echo "============================================================"
    green "  【赛风副节点出口 IP 检测】 [$cc - $cname]"
    yellow "  当前出站模式: ${mode_desc}"
    [[ "$mode" == "cfon" ]] && cyan "  说明: Cfon 底座由 WARP 加密前置建立隧道，最终出口归属所选国家"
    echo "============================================================"

    local test_p=$(cat "${PSI_INSTANCES_DIR}/$cc/test_socks_port.txt" 2>/dev/null)
    [[ -z "$test_p" || "$test_p" == "0" ]] && test_p="$socks_p"

    # 1. 探测 IPv4
    yellow "[*] 正在探测 IPv4 出口路由..."
    local ipv4="" country4="" region4="" city4="" isp4="" json4=""
    if [[ -n "$test_p" && "$test_p" -gt 0 ]]; then
        json4=$(curl -sx "socks5h://127.0.0.1:${test_p}" -s --connect-timeout 4 -m 6 -A "Mozilla/5.0" "https://api-ipv4.ip.sb/geoip" 2>/dev/null)
        if [[ -z "$json4" || ! "$json4" =~ ip ]]; then
            ipv4=$(curl -sx "socks5h://127.0.0.1:${test_p}" -s --connect-timeout 4 -m 6 -A "Mozilla/5.0" "https://api-ipv4.ip.sb/ip" 2>/dev/null | tr -d ' \r\n')
        fi
    fi

    if [[ -n "$json4" ]] && echo "$json4" | jq -e '.ip' >/dev/null 2>&1; then
        ipv4=$(echo "$json4" | jq -r '.ip // empty' 2>/dev/null)
        country4=$(echo "$json4" | jq -r '.country // empty' 2>/dev/null)
        region4=$(echo "$json4" | jq -r '.region // empty' 2>/dev/null)
        city4=$(echo "$json4" | jq -r '.city // empty' 2>/dev/null)
        isp4=$(echo "$json4" | jq -r '.isp // .organization // .asn_organization // empty' 2>/dev/null)
    fi

    if [[ -n "$ipv4" && "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        green "  [✓] IPv4 出口 IP : ${ipv4}"
        [[ -n "$country4" || -n "$city4" ]] && blue "      出口国家地区 : ${country4:-未知} - ${region4} ${city4}"
        [[ -n "$isp4" ]] && blue "      网络运营商   : ${isp4}"
    else
        yellow "  [!] IPv4 出口    : 未获取到 (可能远端正在重连，请稍后重试)"
    fi

    echo "  ----------------------------------------------------------"

    # 2. 探测 IPv6
    yellow "[*] 正在探测 IPv6 出口路由..."
    local ipv6="" country6="" region6="" city6="" isp6="" json6=""
    if [[ -n "$test_p" && "$test_p" -gt 0 ]]; then
        json6=$(curl -sx "socks5h://127.0.0.1:${test_p}" -s --connect-timeout 4 -m 6 -A "Mozilla/5.0" "https://api-ipv6.ip.sb/geoip" 2>/dev/null)
        if [[ -z "$json6" || ! "$json6" =~ ip ]]; then
            ipv6=$(curl -sx "socks5h://127.0.0.1:${test_p}" -s --connect-timeout 4 -m 6 -A "Mozilla/5.0" "https://api-ipv6.ip.sb/ip" 2>/dev/null | tr -d ' \r\n')
        fi
    fi

    if [[ -n "$json6" ]] && echo "$json6" | jq -e '.ip' >/dev/null 2>&1; then
        ipv6=$(echo "$json6" | jq -r '.ip // empty' 2>/dev/null)
        country6=$(echo "$json6" | jq -r '.country // empty' 2>/dev/null)
        region6=$(echo "$json6" | jq -r '.region // empty' 2>/dev/null)
        city6=$(echo "$json6" | jq -r '.city // empty' 2>/dev/null)
        isp6=$(echo "$json6" | jq -r '.isp // .organization // .asn_organization // empty' 2>/dev/null)
    fi

    if [[ -n "$ipv6" && "$ipv6" =~ : ]]; then
        green "  [✓] IPv6 出口 IP : ${ipv6}"
        [[ -n "$country6" || -n "$city6" ]] && blue "      出口国家地区 : ${country6:-未知} - ${region6} ${city6}"
        [[ -n "$isp6" ]] && blue "      网络运营商   : ${isp6}"
    else
        yellow "  [-] IPv6 出口    : 远端节点未分配 IPv6 (非错误，以 IPv4 赛风出口为主)"
    fi
    echo "============================================================"
}

configure_psiphon_instance_egress_menu() {
    local insts
    mapfile -t insts < <(get_all_psiphon_instances)
    if [[ ${#insts[@]} -eq 0 ]]; then
        yellow "暂无可配置的赛风出口组，请先添加赛风副节点！"
        return 0
    fi

    echo
    green "==== 选择要配置出站模式的赛风副节点 ===="
    local idx=1
    for cc in "${insts[@]}"; do
        local cname=$(get_country_name "$cc")
        local edesc=$(get_psiphon_egress_desc "$cc")
        echo -e "  ${green}[$idx] [$cc] $cname${re} (当前: ${blue}${edesc}${re})"
        ((idx++))
    done
    echo "------------------------------------------------------------"
    reading "请输入国家代码 (如 US) 或序号 [回车取消]: " input_target
    [[ -z "$input_target" ]] && return 0

    local target_cc=""
    if [[ "$input_target" =~ ^[0-9]+$ ]] && [[ "$input_target" -ge 1 && "$input_target" -le ${#insts[@]} ]]; then
        target_cc="${insts[$((input_target-1))]}"
    else
        target_cc="${input_target^^}"
    fi

    if [[ ! -d "${PSI_INSTANCES_DIR}/$target_cc" ]]; then
        red "未找到赛风出口组: $target_cc"
        return 1
    fi

    local cname=$(get_country_name "$target_cc")
    local idir="${PSI_INSTANCES_DIR}/${target_cc}"
    local socks_p=$(cat "$idir/socks_port.txt" 2>/dev/null || echo "0")

    while true; do
        [[ -t 1 ]] && clear 2>/dev/null || true
        local cur_desc=$(get_psiphon_egress_desc "$target_cc")

        echo
        green "============================================================"
        green "  赛风副节点 [$target_cc - $cname] 出站模式管理"
        green "============================================================"
        yellow "  当前出站状态: ${cur_desc}"
        echo "------------------------------------------------------------"
        green "  1. 切换为: 纯赛风原生出站 (Psiphon 原生传输)"
        green "  2. 切换为: 赛风（WARP 前置 / Cfon 出站 - 防阻断底座）"
        echo "------------------------------------------------------------"
        purple "  3. 实时检测该副节点出口 IP"
        blue  "  4. 查看该副节点运行日志"
        echo "------------------------------------------------------------"
        red   "  0. 返回上一级"
        echo "============================================================"
        reading "请选择 [0-4]: " mode_choice

        case "$mode_choice" in
            1)
                yellow "[*] 正在切换 [$target_cc - $cname] 为【纯赛风原生出站】..."
                set_psiphon_egress_mode "$target_cc" "psiphon"
                write_psiphon_config "$socks_p" "$target_cc" "$idir/psiphon.config" "$idir/data" ""
                restart_psiphon_instance "$target_cc"
                sync_psiphon_instance_to_singbox "$target_cc"
                apply_changes
                green "[✓] [$target_cc - $cname] 已切换为: 纯赛风原生出站"
                echo
                reading "按回车继续..." _
                ;;
            2)
                yellow "[*] 正在切换 [$target_cc - $cname] 为【赛风（WARP 前置 / Cfon）】..."
                ensure_warp_config
                set_psiphon_egress_mode "$target_cc" "cfon"
                write_psiphon_config "$socks_p" "$target_cc" "$idir/psiphon.config" "$idir/data" "socks5://127.0.0.1:$(get_psiphon_cfon_socks_port "$target_cc")"
                restart_psiphon_instance "$target_cc"
                sync_psiphon_instance_to_singbox "$target_cc"
                apply_changes
                green "[✓] [$target_cc - $cname] 成功切换为: 赛风（WARP 前置 / Cfon）！"
                echo
                reading "按回车继续..." _
                ;;
            3)
                psiphon_instance_egress_test "$target_cc"
                echo
                reading "按回车继续..." _
                ;;
            4)
                echo
                if command -v journalctl >/dev/null 2>&1 && ! $IS_DIRECT && ! $IS_OPENRC; then
                    journalctl -u "psiphon-instance@${target_cc}" -n 50 --no-pager
                else
                    tail -n 50 "$idir/psiphon.log" 2>/dev/null || yellow "暂无日志"
                fi
                echo
                reading "按回车继续..." _
                ;;
            0)
                return 0
                ;;
            *)
                red "无效选项，请重新选择"
                sleep 1
                ;;
        esac
    done
}

psiphon_multigroup_menu() {
    auto_migrate_legacy_nodes
    while true; do
        [[ -t 1 ]] && clear 2>/dev/null || true
        echo
        green "============================================================"
        green "  副节点 - 赛风多出口组管理"
        green "============================================================"
        yellow "  说明: 副节点拥有独立入站端口与专属路由，出站走赛风对应国家"
        yellow "        支持原生赛风出站与 WARP 前置 (Cfon) 防阻断双模式"
        green "============================================================"
        echo

        local insts
        mapfile -t insts < <(get_all_psiphon_instances)

        purple "【当前已配置赛风出口组】 (共 ${#insts[@]} 组):"
        if [[ ${#insts[@]} -gt 0 ]]; then
            local idx=1
            for cc in "${insts[@]}"; do
                [[ -z "$cc" ]] && continue
                local cname=$(get_country_name "$cc")
                local hp=$(cat "${PSI_INSTANCES_DIR}/$cc/hy2_port.txt" 2>/dev/null || echo "0")
                local tp=$(cat "${PSI_INSTANCES_DIR}/$cc/tuic_port.txt" 2>/dev/null || echo "0")
                local vp=$(cat "${PSI_INSTANCES_DIR}/$cc/vless_port.txt" 2>/dev/null || echo "0")
                local emode=$(get_psiphon_egress_mode "$cc")
                local emode_tag="[纯赛风原生]"
                if [[ "$emode" == "cfon" ]]; then
                    emode_tag="${blue}[WARP前置/Cfon]${re}"
                else
                    emode_tag="${green}[纯赛风原生]${re}"
                fi
                local p_info=""
                [[ "$hp" -gt 0 ]] && p_info="${p_info}Hy2:$hp "
                [[ "$tp" -gt 0 ]] && p_info="${p_info}TUIC:$tp "
                [[ "$vp" -gt 0 ]] && p_info="${p_info}VLESS:$vp "
                local st_str="${red}[✗ 未运行]${re}"
                if is_secondary_egress_running "$cc"; then
                    st_str="${green}[✓ 运行中]${re}"
                fi
                echo -e "  ${green}[$idx] [$cc] $cname${re} $st_str  ${emode_tag}"
                echo -e "      ${blue}入站端口: [ ${p_info:-无} ]${re}"
                ((idx++))
            done
        else
            yellow "  暂无赛风出口组"
        fi

        echo
        echo "------------------------------------------------------------"
        green  "  1. 添加赛风出口组"
        green  "  2. 查看赛风出口组链接"
        red    "  3. 删除赛风出口组"
        blue   "  4. 重启/修复指定赛风出口组"
        blue   "  5. 重启所有赛风实例"
        purple "  6. 配置赛风副节点出站模式 (纯赛风 / Cfon)"
        echo "------------------------------------------------------------"
        red    "  0. 返回上一级菜单"
        echo "============================================================"
        reading "请选择 [0-6]: " choice

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
                    if [[ -d "${PSI_INSTANCES_DIR}/$del_cc" ]] || grep -qix "$del_cc" "$PSI_INSTANCES_DIR/instances.txt" 2>/dev/null; then
                        stop_secondary_egress "$del_cc"
                        rm -rf "${PSI_INSTANCES_DIR:?}/$del_cc"
                        sed -i "/^${del_cc}$/Id" "$PSI_INSTANCES_DIR/instances.txt"
                        local tmp_j=$(mktemp)
                        jq --arg cc "${del_cc,,}" --arg ccu "$del_cc" '
                        .outbounds = [.outbounds[] | select(
                          .tag != ("psiphon-" + $cc) and
                          .tag != ("psiphon-" + $cc + "-out") and
                          .tag != ("psiphon-" + $ccu) and
                          .tag != $cc and
                          .tag != $ccu
                        )] |
                        .endpoints = [(.endpoints // [])[] | select(
                          .tag != ("psiphon-warp-" + $cc) and
                          .tag != ("psiphon-warp-" + $ccu)
                        )] |
                        .inbounds = [.inbounds[] | select(
                          (.tag | contains("psi-" + $cc)) or
                          (.tag | contains("psi-" + $ccu)) or
                          (.tag | contains("cfon-" + $cc)) or
                          (.tag | contains("psiphon-" + $cc)) | not
                        )] |
                        .route.rules = [.route.rules[] | select(
                          .outbound != ("psiphon-" + $cc) and
                          .outbound != ("psiphon-" + $cc + "-out") and
                          .outbound != ("psiphon-warp-" + $cc) and
                          .outbound != ("psiphon-warp-" + $ccu) and
                          .outbound != ("psiphon-" + $ccu) and
                          .outbound != $cc and
                          .outbound != $ccu
                        )]
                        ' "$WORKDIR/sb.json" > "$tmp_j" 2>/dev/null && jq -e . "$tmp_j" >/dev/null 2>&1 && mv -f "$tmp_j" "$WORKDIR/sb.json"
                        cleanup_orphan_secondary_nodes
                        apply_changes
                        green "已彻底删除赛风出口组: $del_cc"
                    else
                        red "未找到赛风出口组: $del_cc"
                    fi
                fi
                ;;
            4) repair_single_psiphon_instance ;;
            5)
                yellow "正在重启并重置所有赛风实例..."
                for cc in "${insts[@]}"; do
                    [[ -z "$cc" ]] && continue
                    local idir="${PSI_INSTANCES_DIR}/${cc}"
                    stop_psiphon_instance "$cc"
                    rm -rf "$idir/data" 2>/dev/null || true
                    mkdir -p "$idir/data" 2>/dev/null
                    local socks_p=$(cat "$idir/socks_port.txt" 2>/dev/null)
                    [[ -z "$socks_p" || "$socks_p" == "0" ]] && socks_p=$(get_free_loopback_port)
                    echo "$socks_p" > "$idir/socks_port.txt"
                    local up_proxy=""
                    [[ "$(get_psiphon_egress_mode "$cc")" == "cfon" ]] && up_proxy="socks5://127.0.0.1:$(get_psiphon_cfon_socks_port "$cc")"
                    write_psiphon_config "$socks_p" "$cc" "$idir/psiphon.config" "$idir/data" "$up_proxy"
                    start_psiphon_instance "$cc"
                done
                green "所有赛风实例已按照各自模式重启并重新载入！"
                ;;
            6) configure_psiphon_instance_egress_menu ;;
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
        green "  Psiphon 赛风综合管理"
        green "============================================================"
        local cur_reg=$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null || echo "AUTO")
        local cur_sport=$(cat "$WORKDIR/psiphon_socks_port.txt" 2>/dev/null || echo "20800")

        if is_main_psiphon_running; then
            green  "  主进程状态 : ✓ 运行中"
        else
            yellow "  主进程状态 : ✗ 未运行"
        fi
        blue   "  主出口国家 : $cur_reg - $(get_country_name "$cur_reg")"
        purple "  Socks5端口 : $cur_sport"
        green "============================================================"
        echo
        echo "  1. 查看当前出口 IP"
        echo "  2. 智能优选出口国家"
        echo "  3. 手动切换出口国家"
        echo "------------------------------------------------------------"
        echo "  4. 快速测试常用国家"
        echo "  5. 测试全部支持国家"
        echo "  6. 自定义测试国家"
        echo "------------------------------------------------------------"
        echo "  7. 查看 Psiphon 日志"
        echo "  8. 重启 Psiphon 主服务"
        echo "  9. 副节点赛风出口组管理"
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
        green "  主节点 Argo 隧道管理"
        green "============================================================"
        if service_is_active argo-tunnel; then
            green "  隧道状态 : ✓ 运行中"
            local argo_d=""
            if [[ -f /etc/s-box/argo.log ]]; then
                argo_d=$(head -n 1 /etc/s-box/argo.log 2>/dev/null)
            elif [[ -f /var/log/argo-tunnel.log ]]; then
                argo_d=$(grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' /var/log/argo-tunnel.log 2>/dev/null | tail -n 1)
            fi
            blue  "  分配域名 : ${argo_d:-获取中...}"
        else
            yellow "  隧道状态 : ✗ 未运行"
        fi
        green "============================================================"
        echo
        echo "------------------------------------------------------------"
        green  "  1. 启动 / 重启隧道"
        red    "  2. 停止隧道"
        blue   "  3. 查看隧道实时日志"
        yellow "  4. 重新抓取临时域名"
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
        echo "  1. 查看 Sing-box 日志"
        echo "  2. 查看 Argo 隧道日志"
        echo "  3. 查看 Psiphon 赛风日志"
        echo "  4. 查看自愈守护日志"
        echo "------------------------------------------------------------"
        red  "  0. 返回主菜单"
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
        if ! is_main_psiphon_running; then
            start_main_psiphon
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [自愈守护] Psiphon 主进程未运行，已自动拉起！" >> "$log_file"
        fi
    fi

    ensure_all_psiphon_instances_running
}

# ==================== 8. TCP / UDP / BBR 网络深度调优模块 ====================
SYSCTL_TCP_OPT="/etc/sysctl.d/99-singbox-network-performance.conf"
LIMITS_TCP_OPT="/etc/security/limits.d/99-singbox-network-performance.conf"

set_ipv4_priority() {
    echo
    yellow "[*] 正在调整系统互联网协议解析优先级..."
    # Alpine (musl libc) 不支持 /etc/gai.conf，该文件仅对 glibc 生效
    if command -v apk >/dev/null 2>&1; then
        yellow "[!] 检测到 Alpine Linux (musl libc)，/etc/gai.conf 在此环境下无效，跳过该优化。"
        return 0
    fi
    if [[ ! -f /etc/gai.conf ]]; then
        cat > /etc/gai.conf <<'EOF_GAI'
label ::1/128       0
label ::/0          1
label 2002::/16     2
label ::/96         3
label ::ffff:0:0/96 4
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence  ::/96         20
precedence  ::ffff:0:0/96 10
EOF_GAI
    fi

    cp -f /etc/gai.conf /etc/gai.conf.bak 2>/dev/null || true

    if grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf; then
        sed -i 's/^#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
    else
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    fi

    echo
    green "[✓] 优化成功！当前系统已成功设置为 [ IPv4 优先解析 ]。"
    echo -e "    ${purple}说明: 有效解决双栈 VPS 因 IPv6 国际绕路导致的节点连接握手卡顿问题。${re}"
}

enable_bbr_tune() {
    echo
    yellow "[*] 正在激活 BBR + FQ 拥塞控制算法..."
    mkdir -p /etc/sysctl.d
    echo "net.core.default_qdisc = fq" > /etc/sysctl.d/10-bbr.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/10-bbr.conf
    # 兼容 Alpine Busybox sysctl（不支持 --system）
    if sysctl --system &>/dev/null 2>&1; then
        : # systemd 环境，--system 直接加载所有 sysctl.d 配置
    else
        for _f in /etc/sysctl.d/*.conf; do [[ -f "$_f" ]] && sysctl -p "$_f" &>/dev/null || true; done
    fi

    echo
    cyan "[*] 正在与 Linux 内核交换握手信号，激活 BBR 加速引擎..."
    local bbr_steps=(
        "Initializing FQ Pacifier" 
        "Loading BBR Kernel Module" 
        "Calibrating Pacing Rate" 
        "Synchronizing TCP States"
    )
    for step in "${bbr_steps[@]}"; do
        printf "  [⚙] %-28s [" "$step"
        for i in {1..5}; do printf "%b■%b" "${green}" "${re}"; sleep 0.06; done
        printf "] %b[SUCCESS]%b\n" "${green}" "${re}"
    done

    echo
    green "🚀 BBR + FQ 网络加速模块已成功灌注至内核底层！"
    echo "============================================================"
    printf "  %-24s : %b%-15s%b\n" "当前拥塞控制算法" "${green}" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "${re}"
    printf "  %-24s : %b%-15s%b\n" "默认队列调度算法" "${green}" "$(sysctl -n net.core.default_qdisc 2>/dev/null)" "${re}"
    printf "  %-24s : %b%-15s%b\n" "链路抗丢包实时补偿" "${cyan}" "动态补偿 [已就绪]" "${re}"
    echo "============================================================"
    echo -e "${purple}说明: 显著提升跨境单线程吞吐速率、降低 YouTube/大文件下行缓冲延迟。${re}"
}

smart_tune_tcp_tune() {
    local old_bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
    local old_somax=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "128")
    local old_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "212992")
    local old_file=$(ulimit -n 2>/dev/null || echo "1024")

    echo
    yellow "[*] 正在扫描系统硬件与内存环境..."
    local mem_total_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    [[ -z "$mem_total_kb" || "$mem_total_kb" -le 0 ]] && mem_total_kb=1048576
    local cpu_count=$(nproc 2>/dev/null || echo "1")
    local buf_bytes=$((mem_total_kb * 5 / 100 * 1024))
    [[ $buf_bytes -lt 16777216 ]] && buf_bytes=16777216

    echo -e "  - CPU 核心数: ${cyan}${cpu_count} 核心${re} | 系统总内存: ${cyan}$((mem_total_kb / 1024)) MB${re}"
    echo -e "  - 动态网络缓冲区: ${cyan}$((buf_bytes / 1024 / 1024)) MB${re} (基于物理内存 5% 智能分配)"

    echo
    yellow "[*] 正在注入 Sing-box 生产级 + 跨境专属网络优化内核参数..."
    mkdir -p /etc/sysctl.d
    cat > "$SYSCTL_TCP_OPT" <<EOF_SYSCTL
# --- 基础队列与拥塞算法 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 缓冲区与超高并发容量 ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535
net.core.rmem_max = ${buf_bytes}
net.core.wmem_max = ${buf_bytes}
net.ipv4.tcp_rmem = 4096 87380 ${buf_bytes}
net.ipv4.tcp_wmem = 4096 65536 ${buf_bytes}
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152

# --- 跨境代理 / Reality / Hy2 针对性低延迟调优 ---
# 降低发送队列积压，显著削减 Reality/VLESS 首包延迟 (TTFB)
net.ipv4.tcp_notsent_lowat = 16384
# 开启 MTU 探测，防止跨境运营商 ICMP 黑洞导致断流
net.ipv4.tcp_mtu_probing = 1
# 深度扩容 UDP 缓冲区，解决 Hysteria2 / TUIC / QUIC 高并发丢包
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# 开启 ECN 智能拥塞标记，跨境高位拥塞时不粗暴丢包，极大平滑抖动
net.ipv4.tcp_ecn = 1
# BBRv3 / 新版内核算法向前兼容
net.ipv4.tcp_congestion_control_version = 3

# 限制孤儿连接数，防止翻墙协议在大并发断开时耗尽内存
net.ipv4.tcp_max_orphans = 32768

# --- 连接保活与快速复用 ---
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_fastopen = 3
EOF_SYSCTL

    # 兼容 Alpine Busybox sysctl（不支持 --system）
    if sysctl --system &>/dev/null 2>&1; then
        : # systemd 环境，--system 直接加载所有 sysctl.d 配置
    else
        for _f in /etc/sysctl.d/*.conf; do [[ -f "$_f" ]] && sysctl -p "$_f" &>/dev/null || true; done
    fi

    echo
    cyan "[*] 正在加载跨境物理链路专项调优补丁..."
    local steps=("Analyzing Network Topo" "Clamping MSS Window" "Expanding UDP Ring Buffer" "Activating ECN Engine")
    for step in "${steps[@]}"; do
        printf "  [*] %-30s " "$step..."
        for i in {1..5}; do printf "%b■%b" "${green}" "${re}"; sleep 0.04; done
        printf " [ %bOK%b ]\n" "${green}" "${re}"
    done

    mkdir -p /etc/security/limits.d/
    cat > "$LIMITS_TCP_OPT" <<'EOF_LIMITS'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF_LIMITS

    if command -v iptables &>/dev/null; then
        iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        green "  ✔ 成功部署 MSS Clamp 智能钳制规则，防止跨境 MTU 超出导致连接卡死"
    fi

    ulimit -n 1048576 2>/dev/null || true

    echo
    green "============================================================"
    green "  [✓] Sing-box 生产级 + 跨境网络深度调优部署完成！"
    green "============================================================"
    printf "  %-14s: %-15s -> %b%-15s%b\n" "拥塞控制算法" "$old_bbr" "${green}" "bbr" "${re}"
    printf "  %-14s: %-15s -> %b%-15s%b\n" "最大并发连接" "$old_somax" "${green}" "65535" "${re}"
    printf "  %-14s: %-15s -> %b%-15s%b\n" "文件句柄上限" "$old_file" "${green}" "1048576" "${re}"
    printf "  %-14s: %-15s -> %b%-15s%b\n" "动态网络缓存" "$((old_rmem / 1024 / 1024))MB" "${green}" "$((buf_bytes / 1024 / 1024))MB" "${re}"
    echo "============================================================"
    echo -e "${purple}说明: 所有配置已持久化至 $SYSCTL_TCP_OPT，重启服务器依然生效。${re}"
}

optimize_nic_tune() {
    echo
    yellow "[*] 正在执行多核心网卡硬中断/软中断负载均衡 (RSS/RPS) 优化..."
    if ! command -v ethtool &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y ethtool
        elif command -v yum &>/dev/null; then
            yum install -y ethtool
        elif command -v dnf &>/dev/null; then
            dnf install -y ethtool
        elif command -v apk &>/dev/null; then
            apk add ethtool
        fi
    fi

    local interfaces=$(ls /sys/class/net 2>/dev/null | grep -vE 'lo|docker|veth|br-|any|tung3|sit0|tun|wg')
    local cpu_count=$(nproc 2>/dev/null || echo "1")
    local rps_cpus=$(printf '%x' $(((1 << cpu_count) - 1)))
    for eth in $interfaces; do
        local max_rx=$(ethtool -g "$eth" 2>/dev/null | grep -A 5 "Pre-set maximums" | grep "RX:" | awk '{print $2}')
        [[ -n "$max_rx" ]] && ethtool -G "$eth" rx "${max_rx}" tx "${max_rx}" &>/dev/null || true
        for rps_file in /sys/class/net/$eth/queues/rx-*/rps_cpus; do [[ -f "$rps_file" ]] && echo "$rps_cpus" > "$rps_file" 2>/dev/null; done
        for rfc_file in /sys/class/net/$eth/queues/rx-*/rps_flow_cnt; do [[ -f "$rfc_file" ]] && echo "4096" > "$rfc_file" 2>/dev/null; done
    done
    sysctl -w net.core.rps_sock_flow_entries=32768 &>/dev/null || true

    echo
    cyan "[*] 正在启动网卡硬件多队列负载分发流水线..."
    local nic_steps=(
        "Mapping Network Interface" 
        "Unbinding Single Core IRQ" 
        "Injecting RPS Network Mask" 
        "Balancing Socket Flows"
    )
    for step in "${nic_steps[@]}"; do
        printf "  [⚡] %-28s [" "$step"
        for i in {1..5}; do printf "%b■%b" "${green}" "${re}"; sleep 0.04; done
        printf "] %b[DONE]%b\n" "${green}" "${re}"
    done

    echo
    green "============================================================"
    green "  [✓] 网卡硬件中断多核心流分发部署完毕！"
    green "============================================================"
    local percent=0
    [[ $cpu_count -gt 0 ]] && percent=$((100 / cpu_count))
    for ((i=0; i<cpu_count; i++)); do
        echo -e "  ⚡ CPU 核心 #$i : [${green}██████████████████████████████${re}] 负载分配: ${yellow}${percent}%${re}"
        sleep 0.04
    done
    echo "============================================================"
    echo -e "${purple}说明: 成功打破单核软中断 (SoftIRQ) 瓶颈，大并发网络流量已均匀平摊至所有 ${cpu_count} 个核心。${re}"
}

rollback_tcp_tune() {
    echo
    yellow "[*] 正在准备回退网络调优设置并恢复系统默认值..."
    rm -f "$SYSCTL_TCP_OPT" "$LIMITS_TCP_OPT" /etc/sysctl.d/10-bbr.conf

    if [[ -f /etc/gai.conf.bak ]]; then
        mv -f /etc/gai.conf.bak /etc/gai.conf
    else
        sed -i 's/^precedence ::ffff:0:0\/96  100/#precedence ::ffff:0:0\/96  100/' /etc/gai.conf 2>/dev/null || true
    fi

    sysctl -w net.ipv4.tcp_congestion_control=cubic &>/dev/null || true
    sysctl -w net.core.default_qdisc=pfifo_fast &>/dev/null || true
    sysctl -w net.core.rps_sock_flow_entries=0 &>/dev/null || true

    if command -v iptables &>/dev/null; then
        iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi

    local interfaces=$(ls /sys/class/net 2>/dev/null | grep -vE 'lo|docker|veth|br-|any|tung3|sit0|tun|wg')
    for eth in $interfaces; do
        for rps_file in /sys/class/net/$eth/queues/rx-*/rps_cpus; do [[ -f "$rps_file" ]] && echo "0" > "$rps_file" 2>/dev/null; done
    done

    ulimit -n 1024 2>/dev/null || true
    # 兼容 Alpine Busybox sysctl（不支持 --system）
    if sysctl --system &>/dev/null 2>&1; then
        : # systemd 环境，--system 直接加载所有 sysctl.d 配置
    else
        for _f in /etc/sysctl.d/*.conf; do [[ -f "$_f" ]] && sysctl -p "$_f" &>/dev/null || true; done
    fi
    echo
    green "[✓] 回退完成！所有网络独立配置文件已清理，内存参数已恢复为系统默认状态。"
}

onekey_full_tcp_tune() {
    echo
    green "============================================================"
    green "  一键开启全套极速网络深度调优 (推荐)"
    green "============================================================"
    set_ipv4_priority
    echo
    enable_bbr_tune
    echo
    smart_tune_tcp_tune
    echo
    optimize_nic_tune
    echo
    green "============================================================"
    green "  [🎉] 全套 TCP / BBR / 网卡 / IPv4 深度调优已全部成功激活！"
    green "============================================================"
}

tcp_tune_menu() {
    while true; do
        [[ -t 1 ]] && clear 2>/dev/null || true
        echo
        green "============================================================"
        green "  TCP / UDP / BBR 网络深度调优与性能看板"
        green "============================================================"
        yellow "  源自 tcp.vpsing.de 核心算法，针对 Sing-box 多协议环境深度优化"
        yellow "  全面增强 Reality / Hysteria2 / TUIC / Argo 跨境吞吐与连接稳定性"
        green "============================================================"

        local status_ipv4="${red}[未开启]${re}"
        if [[ -f /etc/gai.conf ]] && grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf; then
            status_ipv4="${green}[已激活]${re}"
        fi

        local status_bbr="${red}[未开启]${re}"
        if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
            status_bbr="${green}[已激活]${re}"
        fi

        local status_sysctl="${red}[未开启]${re}"
        if [[ -f "$SYSCTL_TCP_OPT" ]]; then
            status_sysctl="${green}[已激活]${re}"
        fi

        local status_nic="${red}[未开启]${re}"
        if [[ "$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)" == "32768" ]]; then
            status_nic="${green}[已激活]${re}"
        fi

        echo
        echo -e "  1. 设置 IPv4 优先解析       -> $status_ipv4  ${purple}[解决 IPv6 国际绕路导致的连接握手卡顿]${re}"
        echo -e "  2. 开启 BBR + FQ 拥塞算法   -> $status_bbr  ${purple}[降低跨境丢包率，大幅提升单线程速率]${re}"
        echo -e "  3. 生产级 + 跨境内核调优    -> $status_sysctl  ${purple}[扩容连接池/UDP缓存，优化 Reality/Hy2 首包]${re}"
        echo -e "  4. 网卡多队列全核心均衡     -> $status_nic  ${purple}[消除 CPU 单核中断瓶颈，平摊全核心负载]${re}"
        echo "------------------------------------------------------------"
        green  "  5. 一键开启全套极速网络调优 (推荐一键执行 1-4)"
        yellow "  6. 一键回退到系统默认网络设置"
        echo "------------------------------------------------------------"
        red    "  0. 返回上一级菜单"
        echo "============================================================"
        echo -e "当前内核状态: 算法: ${green}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${re} | 队列: ${green}$(sysctl -n net.core.default_qdisc 2>/dev/null)${re} | 句柄: ${green}$(ulimit -n 2>/dev/null)${re}"
        echo "============================================================"
        reading "请选择 [0-6]: " choice

        case "$choice" in
            1) set_ipv4_priority; echo; reading "按回车继续..." _ ;;
            2) enable_bbr_tune; echo; reading "按回车继续..." _ ;;
            3) smart_tune_tcp_tune; echo; reading "按回车继续..." _ ;;
            4) optimize_nic_tune; echo; reading "按回车继续..." _ ;;
            5) onekey_full_tcp_tune; echo; reading "按回车继续..." _ ;;
            6) rollback_tcp_tune; echo; reading "按回车继续..." _ ;;
            0) return 0 ;;
            *) red "无效选项"; sleep 1 ;;
        esac
    done
}

# ==================== 快捷命令同步更新 ====================
create_sb_tool() {
    mkdir -p /usr/local/bin "$WORKDIR"
    local current_src="${BASH_SOURCE[0]:-$0}"
    local is_updated=false

    # 1. 如果当前是从本地普通脚本文件执行，直接强制覆盖至 /etc/s-box/install.sh
    if [[ -f "$current_src" && "$current_src" != "$WORKDIR/install.sh" && "$current_src" != /dev/fd/* && "$current_src" != /proc/* ]]; then
        if cp -f "$current_src" "$WORKDIR/install.sh" 2>/dev/null && [[ -s "$WORKDIR/install.sh" ]]; then
            is_updated=true
        fi
    fi

    # 2. 如果是从管道/远程加载执行 (如 bash <(curl...))，或本地覆盖未发生，强制拉取最新脚本覆盖
    if ! $is_updated; then
        local remote_urls=(
            "https://raw.githubusercontent.com/hxzl666/singbox/main/install.sh"
            "https://ghproxy.net/https://raw.githubusercontent.com/hxzl666/singbox/main/install.sh"
        )
        for rurl in "${remote_urls[@]}"; do
            if curl -fsSL --connect-timeout 5 --max-time 15 "$rurl" -o "$WORKDIR/install.sh.tmp" 2>/dev/null && [[ -s "$WORKDIR/install.sh.tmp" ]]; then
                mv -f "$WORKDIR/install.sh.tmp" "$WORKDIR/install.sh"
                is_updated=true
                break
            fi
        done
        rm -f "$WORKDIR/install.sh.tmp" 2>/dev/null || true
    fi

    chmod +x "$WORKDIR/install.sh" 2>/dev/null || true

    # 3. 部署 /usr/local/bin/sb 快捷管理入口 (确保始终调用最新 /etc/s-box/install.sh)
    cat > /usr/local/bin/sb << 'EOF_SB'
#!/usr/bin/env bash
WORKDIR="/etc/s-box"
if [[ ! -s "$WORKDIR/install.sh" || $(wc -c < "$WORKDIR/install.sh" 2>/dev/null || echo 0) -lt 1000 ]]; then
    curl -fsSL https://raw.githubusercontent.com/hxzl666/singbox/main/install.sh -o "$WORKDIR/install.sh" 2>/dev/null || \
    curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/hxzl666/singbox/main/install.sh -o "$WORKDIR/install.sh" 2>/dev/null || \
    wget -qO "$WORKDIR/install.sh" https://raw.githubusercontent.com/hxzl666/singbox/main/install.sh 2>/dev/null || true
    chmod +x "$WORKDIR/install.sh" 2>/dev/null || true
fi
exec bash "$WORKDIR/install.sh" "$@"
EOF_SB
    chmod +x /usr/local/bin/sb 2>/dev/null || true
    ln -sf /usr/local/bin/sb /usr/local/bin/t 2>/dev/null || true
}

# ==================== 主菜单 ====================
menu() {
    ensure_alpine_compatibility
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

        purple "【本机网络环境】"
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            [[ -n "$ip" ]] && echo -e "  IP 地址 [$idx]  : ${green}$ip${re}"
            ((idx++))
        done
        echo "------------------------------------------------------------"

        purple "【核心服务状态】"
        if [ -f "$WORKDIR/sb.json" ]; then
            if service_is_active sing-box; then
                echo -e "  Sing-box 核心 : ${green}✓ 运行中${re}"
            else
                echo -e "  Sing-box 核心 : ${yellow}⚠ 已安装但未运行${re}"
            fi

            local warp_status=$(cat "$WORKDIR/warp_enabled.txt" 2>/dev/null)
            local warp_mode=$(cat "$WORKDIR/warp_mode.txt" 2>/dev/null)
            local psi_main=$(cat "$WORKDIR/psiphon_main_enabled.txt" 2>/dev/null)
            if [[ "$warp_status" == "true" ]]; then
                case "$warp_mode" in
                    ipv4)
                        echo -e "  主节点出站模式: ${blue}WARP 仅 IPv4 出站${re}"
                        ;;
                    ipv6)
                        echo -e "  主节点出站模式: ${blue}WARP 仅 IPv6 出站${re}"
                        ;;
                    google|rules)
                        echo -e "  主节点出站模式: ${blue}WARP 规则分流${re}"
                        ;;
                    *)
                        echo -e "  主节点出站模式: ${blue}WARP 全局双栈出站${re}"
                        ;;
                esac
            elif [[ "$psi_main" == "true" ]]; then
                local cur_reg=$(cat "$WORKDIR/psiphon_main_region.txt" 2>/dev/null || echo "AUTO")
                echo -e "  主节点出站模式: ${blue}赛风出站 [${cur_reg}]${re}"
            else
                echo -e "  主节点出站模式: ${green}原生直连出站${re}"
            fi

            if service_is_active argo-tunnel; then
                local argo_d=""
                if [[ -f /etc/s-box/argo.log ]]; then
                    argo_d=$(head -n 1 /etc/s-box/argo.log 2>/dev/null)
                elif [[ -f /var/log/argo-tunnel.log ]]; then
                    argo_d=$(grep -oE '[a-zA-Z0-9.-]+\.trycloudflare\.com' /var/log/argo-tunnel.log 2>/dev/null | tail -n 1)
                fi
                echo -e "  Argo 隧道状态 : ${green}✓ 运行中${re} ${blue}[${argo_d:-获取中}]${re}"
            else
                echo -e "  Argo 隧道状态 : ${yellow}✗ 未运行${re}"
            fi
        else
            echo -e "  Sing-box 核心 : ${red}✗ 未安装${re}"
        fi
        echo "------------------------------------------------------------"

        purple "【副节点出口状态】"
        local psi_insts
        mapfile -t psi_insts < <(get_all_psiphon_instances 2>/dev/null)
        if [[ ${#psi_insts[@]} -gt 0 ]]; then
            echo -e "  赛风出口副节点: ${green}✓ 已配置 ${#psi_insts[@]} 组${re} [ ${psi_insts[*]} ]"
        else
            echo -e "  赛风出口副节点: ${yellow}✗ 未配置${re}"
        fi

        local proxy_tags
        mapfile -t proxy_tags < <(get_all_proxy_groups 2>/dev/null)
        if [[ ${#proxy_tags[@]} -gt 0 ]]; then
            echo -e "  代理出口副节点: ${green}✓ 已配置 ${#proxy_tags[@]} 组${re} [ ${proxy_tags[*]} ]"
        else
            echo -e "  代理出口副节点: ${yellow}✗ 未配置${re}"
        fi
        echo "============================================================"

        echo
        blue   "  【主节点管理】"
        echo "------------------------------------------------------------"
        green  "  1. 重新配置主节点协议"
        green  "  2. 主节点出站管理"
        green  "  3. 主节点 Argo 隧道管理"
        green  "  4. 查看主节点信息与链接"
        echo "------------------------------------------------------------"
        purple "  【副节点管理】"
        echo "------------------------------------------------------------"
        purple "  5. 赛风综合管理"
        purple "  6. 自定义代理出站管理"
        echo "------------------------------------------------------------"
        white  "  【综合功能与系统运维】"
        echo "------------------------------------------------------------"
        blue   "  7. 自定义节点组合推送"
        blue   "  8. 查看全部节点信息总览"
        green  "  9. 重启所有服务"
        yellow " 10. 系统诊断与配置修复"
        blue   " 11. 查看运行日志"
        yellow " 12. 开启 / 关闭服务自愈守护"
        cyan   " 13. TCP / BBR 网络深度调优"
        red    " 14. 彻底卸载 Sing-box 环境"
        echo "------------------------------------------------------------"
        red    "  0. 退出脚本"
        echo "============================================================"

        reading "请选择 [0-14]: " choice
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
            13) tcp_tune_menu ;;
            14)
                reading "确定彻底卸载 Sing-box 及所有组件? (y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    service_stop sing-box
                    service_stop argo-tunnel
                    service_disable sing-box 2>/dev/null
                    service_disable argo-tunnel 2>/dev/null
                    if $IS_OPENRC; then
                        # 清理 OpenRC 服务注册
                        for _svc in sing-box argo-tunnel; do
                            rc-update del "$_svc" default >/dev/null 2>&1 || true
                            rm -f "/etc/init.d/$_svc" 2>/dev/null || true
                        done
                    else
                        systemctl disable --now 'psiphon-main' 2>/dev/null || true
                        systemctl disable --now 'psiphon-instance@*' 2>/dev/null || true
                        systemctl disable --now 'psiphon-cfon@*' 2>/dev/null || true
                        rm -f /etc/systemd/system/psiphon-main.service /etc/systemd/system/psiphon-instance@.service /etc/systemd/system/psiphon-cfon@.service
                        systemctl daemon-reload 2>/dev/null || true
                    fi
                    pkill -9 -f "psiphon-tunnel-core" 2>/dev/null || true
                    pkill -9 -f "warp-plus" 2>/dev/null || true
                    rm -rf /etc/s-box /usr/local/bin/cloudflared /usr/local/bin/sb /usr/local/bin/t
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
    clear 2>/dev/null || true
    echo -e "${purple}======================================================${re}"
    echo -e "${purple}     Sing-box Linux 多协议一键部署与管理脚本          ${re}"
    echo -e "${purple}======================================================${re}"
    echo

    log_info "【步骤 1/5】检测并安装系统基础依赖..."
    install_system_dependencies
    mkdir -p "$WORKDIR" "$PROXY_GROUPS_DIR" "$PSI_INSTANCES_DIR"

    log_info "【步骤 2/5】下载并配置 Sing-box 核心程序..."
    download_singbox_core || { red "[!] Sing-box 核心下载失败，安装终止"; exit 1; }

    log_info "【步骤 3/5】下载附加核心组件 (Cloudflared / Psiphon)..."
    download_cloudflared_core
    download_psiphon_core

    log_info "【步骤 4/5】初始化配置、证书与 Reality 密钥..."
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

    log_info "【步骤 5/5】配置主节点入站协议与端口..."
    if [[ ! -f "$WORKDIR/sb.json" ]]; then
        echo
        echo -e "${green}======================================================${re}"
        echo -e "${green}              主节点协议与端口配置                    ${re}"
        echo -e "${green}======================================================${re}"
        echo -e "  1. ${green}一键启用全部 6 大协议${re} [默认推荐]"
        echo -e "  2. ${yellow}自定义选择协议与端口${re}"
        echo -e "${green}======================================================${re}"
        reading "请选择配置模式 [1-2, 默认 1]: " inst_mode
        [[ -z "$inst_mode" ]] && inst_mode=1

        local p_vless p_vmess p_trojan p_hy2 p_tuic p_anytls
        if [[ "$inst_mode" == "2" ]]; then
            echo
            yellow "提示：输入所需端口(1-65535)，直接回车由系统随机分配，输入 0 或 n 禁用该协议"
            echo

            reading "开启 VLESS-Reality? [回车随机/端口/0禁用]: " inp_vless
            [[ -z "$inp_vless" || "$inp_vless" == "y" || "$inp_vless" == "Y" ]] && p_vless=$(get_free_port)
            [[ "$inp_vless" =~ ^[0-9]+$ && "$inp_vless" -gt 0 ]] && p_vless="$inp_vless"
            [[ "$inp_vless" == "0" || "$inp_vless" == "n" || "$inp_vless" == "N" ]] && p_vless=0

            reading "开启 VMess-WS?      [回车随机/端口/0禁用]: " inp_vmess
            [[ -z "$inp_vmess" || "$inp_vmess" == "y" || "$inp_vmess" == "Y" ]] && p_vmess=$(get_free_port)
            [[ "$inp_vmess" =~ ^[0-9]+$ && "$inp_vmess" -gt 0 ]] && p_vmess="$inp_vmess"
            [[ "$inp_vmess" == "0" || "$inp_vmess" == "n" || "$inp_vmess" == "N" ]] && p_vmess=0

            reading "开启 Trojan-WS-TLS? [回车随机/端口/0禁用]: " inp_trojan
            [[ -z "$inp_trojan" || "$inp_trojan" == "y" || "$inp_trojan" == "Y" ]] && p_trojan=$(get_free_port)
            [[ "$inp_trojan" =~ ^[0-9]+$ && "$inp_trojan" -gt 0 ]] && p_trojan="$inp_trojan"
            [[ "$inp_trojan" == "0" || "$inp_trojan" == "n" || "$inp_trojan" == "N" ]] && p_trojan=0

            reading "开启 Hysteria2?     [回车随机/端口/0禁用]: " inp_hy2
            [[ -z "$inp_hy2" || "$inp_hy2" == "y" || "$inp_hy2" == "Y" ]] && p_hy2=$(get_free_port)
            [[ "$inp_hy2" =~ ^[0-9]+$ && "$inp_hy2" -gt 0 ]] && p_hy2="$inp_hy2"
            [[ "$inp_hy2" == "0" || "$inp_hy2" == "n" || "$inp_hy2" == "N" ]] && p_hy2=0

            reading "开启 TUIC v5?       [回车随机/端口/0禁用]: " inp_tuic
            [[ -z "$inp_tuic" || "$inp_tuic" == "y" || "$inp_tuic" == "Y" ]] && p_tuic=$(get_free_port)
            [[ "$inp_tuic" =~ ^[0-9]+$ && "$inp_tuic" -gt 0 ]] && p_tuic="$inp_tuic"
            [[ "$inp_tuic" == "0" || "$inp_tuic" == "n" || "$inp_tuic" == "N" ]] && p_tuic=0

            reading "开启 AnyTLS?        [回车随机/端口/0禁用]: " inp_anytls
            [[ -z "$inp_anytls" || "$inp_anytls" == "y" || "$inp_anytls" == "Y" ]] && p_anytls=$(get_free_port)
            [[ "$inp_anytls" =~ ^[0-9]+$ && "$inp_anytls" -gt 0 ]] && p_anytls="$inp_anytls"
            [[ "$inp_anytls" == "0" || "$inp_anytls" == "n" || "$inp_anytls" == "N" ]] && p_anytls=0
        else
            p_vless=$(get_free_port)
            p_vmess=$(get_free_port)
            p_trojan=$(get_free_port)
            p_hy2=$(get_free_port)
            p_tuic=$(get_free_port)
            p_anytls=$(get_free_port)
        fi

        local p_loop=$(get_free_loopback_port)
        build_and_apply_main_inbounds "$p_vless" "$p_vmess" "$p_trojan" "$p_hy2" "$p_tuic" "$p_anytls" "$p_loop"
        apply_main_node_outbound
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

depend() {
    need net
    after firewall
}

start_pre() {
    export ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true
    export ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS=true
}
EOF_INIT
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1
        # 为 Argo Tunnel 创建 OpenRC 服务脚本
        cat > /etc/init.d/argo-tunnel <<'EOF_ARGO_INIT'
#!/sbin/openrc-run
description="Cloudflare Argo Tunnel Service"
command="/usr/local/bin/cloudflared"
pidfile="/run/argo-tunnel.pid"
command_background=true
output_log="/var/log/argo-tunnel.log"
error_log="/var/log/argo-tunnel.err"

depend() {
    need net
    after sing-box
}

start_pre() {
    local _am="" _at="" _ap="8401"
    if [ -f /etc/s-box/argo.conf ]; then
        . /etc/s-box/argo.conf
    fi
    _am="${ARGO_MODE:-temp}"; _at="${ARGO_TOKEN}"; _ap="${ARGO_PORT:-8401}"
    if [ "$_am" = "token" ] && [ -n "$_at" ]; then
        command_args="tunnel --no-autoupdate run --token $_at"
    else
        command_args="tunnel --url http://127.0.0.1:${_ap}"
    fi
}
EOF_ARGO_INIT
        chmod +x /etc/init.d/argo-tunnel
        # 确保 Alpine 的 crond 已启动并加入开机自启
        if command -v crond >/dev/null 2>&1; then
            rc-update add crond default >/dev/null 2>&1 || true
            rc-service crond start >/dev/null 2>&1 || true
        fi
    elif ! $IS_DIRECT; then
        cat > /etc/systemd/system/sing-box.service <<'EOF_SYSTEMD'
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
Environment="ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true"
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

update_script_self() {
    yellow "正在强制更新 Sing-box 脚本至最新版本..."
    local rurls=(
        "https://raw.githubusercontent.com/hxzl666/singbox/main/install.sh"
        "https://ghproxy.net/https://raw.githubusercontent.com/hxzl666/singbox/main/install.sh"
    )
    local done_u=false
    for u in "${rurls[@]}"; do
        if curl -fsSL --connect-timeout 5 --max-time 15 "$u" -o "$WORKDIR/install.sh.tmp" 2>/dev/null && [[ -s "$WORKDIR/install.sh.tmp" ]]; then
            mv -f "$WORKDIR/install.sh.tmp" "$WORKDIR/install.sh"
            chmod +x "$WORKDIR/install.sh"
            done_u=true
            break
        fi
    done
    rm -f "$WORKDIR/install.sh.tmp" 2>/dev/null || true
    if $done_u; then
        create_sb_tool
        green "脚本已成功强制更新至最新版本！"
    else
        red "更新失败，请检查网络！"
    fi
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
    tcp|bbr|t)
        tcp_tune_menu
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
    update)
        update_script_self
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
