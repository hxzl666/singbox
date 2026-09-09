#!/bin/bash
# ============================================================================
# Serv00/Hostuno 多协议节点安装脚本
# ============================================================================
# 支持的协议:
#   - Argo Tunnel (Cloudflare Tunnel)
#   - VLESS-Reality
#   - VMess-WS (支持TLS)
#   - Trojan-WS
#   - Hysteria2
#   - TUIC v5
#   - Shadowsocks-2022
# ============================================================================
# 基于 yonggekkk 和 eooce 脚本
# 版本: 1.0.0
# ============================================================================

# ==================== 颜色定义 ====================
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

# ==================== 环境变量 ====================
export LC_ALL=C
USERNAME=$(whoami | tr '[:upper:]' '[:lower:]')
HOSTNAME=$(hostname)
snb=$(hostname | cut -d. -f1)
nb=$(hostname | cut -d '.' -f 1 | tr -d 's')
hona=$(hostname | cut -d. -f2)

# 判断平台
if [ "$hona" = "serv00" ]; then
    PLATFORM="serv00"
    DOMAIN="serv00.net"
elif [ "$hona" = "hostuno" ]; then
    PLATFORM="hostuno"
    DOMAIN="useruno.com"
else
    PLATFORM="ct8"
    DOMAIN="ct8.pl"
fi

# 工作目录
WORKDIR="${HOME}/domains/${USERNAME}.${DOMAIN}/logs"
FILE_PATH="${HOME}/domains/${USERNAME}.${DOMAIN}/public_html"
KEEP_PATH="${HOME}/domains/${snb}.${USERNAME}.${DOMAIN}/public_nodejs"

# 默认变量
export UUID=${UUID:-$(uuidgen -r 2>/dev/null || cat /proc/sys/kernel/random/uuid)}
export ARGO_DOMAIN=${ARGO_DOMAIN:-''}
export ARGO_AUTH=${ARGO_AUTH:-''}
export NEZHA_SERVER=${NEZHA_SERVER:-''}
export NEZHA_PORT=${NEZHA_PORT:-''}
export NEZHA_KEY=${NEZHA_KEY:-''}
export CFIP=${CFIP:-'cdn.2020111.xyz'}
export CFPORT=${CFPORT:-'443'}
export SUB_TOKEN=${SUB_TOKEN:-${UUID:0:8}}

# 启用的协议
export ENABLE_ARGO=${ENABLE_ARGO:-true}
export ENABLE_VLESS_REALITY=${ENABLE_VLESS_REALITY:-true}
export ENABLE_VMESS_WS=${ENABLE_VMESS_WS:-true}
export ENABLE_TROJAN_WS=${ENABLE_TROJAN_WS:-false}
export ENABLE_HYSTERIA2=${ENABLE_HYSTERIA2:-true}
export ENABLE_TUIC=${ENABLE_TUIC:-true}
export ENABLE_SHADOWSOCKS=${ENABLE_SHADOWSOCKS:-false}
export ENABLE_ANYTLS=${ENABLE_ANYTLS:-false}

# ==================== WARP 出站配置 ====================
# 是否启用 WARP 出站 (默认关闭)
WARP_ENABLED=${WARP_ENABLED:-false}
# WARP 配置 (运行时从远程获取或使用备用)
WARP_PRIVATE_KEY=""
WARP_IPV6=""
WARP_RESERVED=""
# WARP 模式: all=全部流量走WARP, google=仅Google/YouTube走WARP
WARP_MODE=${WARP_MODE:-"all"}

# ==================== 脚本版本 ====================
SCRIPT_VERSION="1.0.0"

# ==================== 工具函数 ====================

# 后台脱离终端启动函数 (支持 setsid/daemon/nohup 降级)
# 用法: run_detached <pidfile> <logfile> <cmd...>
run_detached() {
    local pidfile="$1"; shift
    local logfile="$1"; shift

    # 优先使用 setsid (Linux)
    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" </dev/null >>"$logfile" 2>&1 &
        echo $! >"$pidfile"
        return 0
    fi

    # FreeBSD 使用 daemon 命令
    if command -v daemon >/dev/null 2>&1; then
        # daemon 会脱离控制终端，并把子进程 pid 写到 pidfile
        local cmd=""
        for arg in "$@"; do
            cmd+=" $(printf "%q" "$arg")"
        done
        /usr/sbin/daemon -p "$pidfile" /bin/sh -c "exec $cmd </dev/null >>\"$logfile\" 2>&1"
        return $?
    fi

    # 最后的兜底 (不如 setsid/daemon 可靠)
    nohup "$@" </dev/null >>"$logfile" 2>&1 &
    echo $! >"$pidfile"
    return 0
}


# ==================== 自动清理与系统自愈维护 ====================

# 深度清理僵尸与孤儿进程 (释放 FreeBSD maxproc 与端口死锁)
cleanup_zombie_processes() {
    local me
    me="$(whoami 2>/dev/null || echo "$USERNAME")"
    [ -z "$me" ] && return 0

    # 1. 基础已知进程特征清理 (按当前用户过滤)
    pkill -9 -u "$me" -f "psiphon-tunnel-core" >/dev/null 2>&1 || true
    pkill -9 -u "$me" -x "psiphon-tunnel-core" >/dev/null 2>&1 || true
    pkill -9 -u "$me" -f "psiphon-tunnel" >/dev/null 2>&1 || true
    pkill -9 -u "$me" -f "sing-box" >/dev/null 2>&1 || true
    pkill -9 -u "$me" -x "sing-box" >/dev/null 2>&1 || true
    pkill -9 -u "$me" -f "cloudflared" >/dev/null 2>&1 || true
    pkill -9 -u "$me" -x "cloudflared" >/dev/null 2>&1 || true
    pkill -9 -u "$me" -f "nezha-agent" >/dev/null 2>&1 || true
    pkill -9 -u "$me" -x "nezha-agent" >/dev/null 2>&1 || true

    # 2. 读取记录的随机伪装名精准清理
    if [ -d "$WORKDIR" ]; then
        local sb_bin cf_bin nz_bin
        sb_bin=$(cat "$WORKDIR/sb.txt" 2>/dev/null)
        cf_bin=$(cat "$WORKDIR/cf.txt" 2>/dev/null)
        nz_bin=$(cat "$WORKDIR/nz.txt" 2>/dev/null)
        [ -n "$sb_bin" ] && pkill -9 -u "$me" -x "$sb_bin" >/dev/null 2>&1 || true
        [ -n "$sb_bin" ] && pkill -9 -u "$me" -f "$WORKDIR/$sb_bin" >/dev/null 2>&1 || true
        [ -n "$cf_bin" ] && pkill -9 -u "$me" -x "$cf_bin" >/dev/null 2>&1 || true
        [ -n "$cf_bin" ] && pkill -9 -u "$me" -f "$WORKDIR/$cf_bin" >/dev/null 2>&1 || true
        [ -n "$nz_bin" ] && pkill -9 -u "$me" -x "$nz_bin" >/dev/null 2>&1 || true
        [ -n "$nz_bin" ] && pkill -9 -u "$me" -f "$WORKDIR/$nz_bin" >/dev/null 2>&1 || true
    fi

    # 3. 清理 PID 文件中记录但可能已卡死/僵死的旧 PID
    if [ -d "$WORKDIR" ]; then
        for pid_file in "$WORKDIR"/*.pid "$WORKDIR"/instances/*/*.pid; do
            if [ -f "$pid_file" ]; then
                local old_pid
                old_pid=$(cat "$pid_file" 2>/dev/null | tr -d ' \r\n')
                if [[ "$old_pid" =~ ^[0-9]+$ ]]; then
                    kill -9 "$old_pid" >/dev/null 2>&1 || true
                fi
                rm -f "$pid_file" 2>/dev/null
            fi
        done
    fi

    # 4. 端口占用释放 (针对主副节点端口，防止 address already in use)
    if [ -f "$WORKDIR/ports.txt" ]; then
        local ports_to_check=()
        while IFS='=' read -r _ val; do
            local p=$(echo "$val" | grep -oE '[0-9]+' | head -n1)
            [ -n "$p" ] && ports_to_check+=("$p")
        done < "$WORKDIR/ports.txt"
        
        for port in "${ports_to_check[@]}"; do
            [ -z "$port" ] && continue
            # FreeBSD sockstat
            if command -v sockstat >/dev/null 2>&1; then
                sockstat -4 -l -p "$port" 2>/dev/null | awk -v u="$me" '$1==u {print $3}' | while read -r p_id; do
                    if [[ "$p_id" =~ ^[0-9]+$ ]]; then
                        kill -9 "$p_id" >/dev/null 2>&1 || true
                    fi
                done
            fi
            # Linux fuser / lsof
            if command -v fuser >/dev/null 2>&1; then
                fuser -k -n tcp "$port" >/dev/null 2>&1 || true
                fuser -k -n udp "$port" >/dev/null 2>&1 || true
            elif command -v lsof >/dev/null 2>&1; then
                lsof -ti :"$port" 2>/dev/null | xargs -r kill -9 >/dev/null 2>&1 || true
            fi
        done
    fi
}

# 自动清理历史垃圾、过期临时文件与日志安全截断 (防止 512MB 磁盘配额占满)
cleanup_garbage_and_logs() {
    [ -d "$WORKDIR" ] || return 0

    # 1. 日志轮转与截断 (单日志超过 512KB 时保留最新 300 行)
    find "$WORKDIR" -type f -name "*.log" 2>/dev/null | while read -r log_file; do
        if [ -f "$log_file" ]; then
            local file_size=0
            if stat -f%z "$log_file" >/dev/null 2>&1; then
                file_size=$(stat -f%z "$log_file" 2>/dev/null || echo 0)
            elif stat -c%s "$log_file" >/dev/null 2>&1; then
                file_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
            else
                file_size=$(wc -c < "$log_file" 2>/dev/null || echo 0)
            fi

            # 超过 512KB (524288 字节) 自动截断
            if [ "$file_size" -gt 524288 ] 2>/dev/null; then
                tail -n 300 "$log_file" > "${log_file}.tmp" 2>/dev/null && mv -f "${log_file}.tmp" "$log_file" 2>/dev/null
            fi
        fi
    done

    # 2. 清理临时测速文件、临时 json/curl/wget 垃圾
    rm -f "$WORKDIR"/*.tmp "$WORKDIR"/check_* "$WORKDIR"/tmp_* "$WORKDIR"/*.out "$WORKDIR"/test_* 2>/dev/null
    find "$WORKDIR" -type f -name "ip_status_*.txt" -mtime +1 -delete 2>/dev/null || true

    # 3. 清理废弃的旧版本随机二进制核心 (只保留当前活跃核心与标准系统组件)
    local cur_sb cur_cf cur_nz
    cur_sb=$(cat "$WORKDIR/sb.txt" 2>/dev/null)
    cur_cf=$(cat "$WORKDIR/cf.txt" 2>/dev/null)
    cur_nz=$(cat "$WORKDIR/nz.txt" 2>/dev/null)

    for bin_file in "$WORKDIR"/*; do
        [ -f "$bin_file" ] || continue
        local b_name
        b_name=$(basename "$bin_file")
        case "$b_name" in
            *.txt|*.json|*.log|*.pid|*.yaml|*.yml|*.sh|*.bak|instances|proxy_groups|tunnel.json|config.json|"$cur_sb"|"$cur_cf"|"$cur_nz"|"psiphon-tunnel-core"|"sing-box"|"cloudflared"|"nezha-agent"|"jq")
                continue
                ;;
            *)
                # 若为可执行文件且长度在 5-10 位随机名，判定为旧核心废弃文件并清理
                if [ -x "$bin_file" ] && [[ ${#b_name} -ge 5 && ${#b_name} -le 10 ]]; then
                    rm -f "$bin_file" 2>/dev/null
                fi
                ;;
        esac
    done
}

# 清理老版本脚本遗留物 (自动覆盖指向旧仓库的 ~/bin/sb、清理残留 alias 等)
cleanup_old_script_remnants() {
    local sb_cmd="$HOME/bin/sb"
    local need_overwrite=false

    # 1. 检测 ~/bin/sb 是否存在且指向旧版本仓库地址，若是则强制覆盖为新版
    if [ -f "$sb_cmd" ]; then
        # 匹配老仓库 URL (hxzlplp7 等非当前仓库地址)
        if grep -q 'hxzlplp7' "$sb_cmd" 2>/dev/null; then
            need_overwrite=true
        fi
        # 匹配极老版本的简陋快捷脚本 (没有本地优先判断的单行 curl)
        if ! grep -q 'HOME/serv00_nodes.sh' "$sb_cmd" 2>/dev/null; then
            need_overwrite=true
        fi
    fi

    if [ "$need_overwrite" = true ]; then
        mkdir -p "$HOME/bin"
        cat > "$sb_cmd" <<'SBEOF'
#!/bin/bash
if [ -f "$HOME/serv00_nodes.sh" ]; then
    bash "$HOME/serv00_nodes.sh" "$@"
else
    bash <(curl -Lks "https://raw.githubusercontent.com/hxzl666/serv00-singbox/main/serv00_nodes.sh?t=$(date +%s)") "$@"
fi
SBEOF
        chmod +x "$sb_cmd"
    fi

    # 2. 清理 .bashrc / .profile 中可能残留的老版本 alias 行 (如 alias sb='bash <(curl ... hxzlplp7 ...')
    for rc_file in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile"; do
        if [ -f "$rc_file" ]; then
            # 移除指向旧仓库的 alias sb 行
            sed -i.bak '/alias sb=.*hxzlplp7/d' "$rc_file" 2>/dev/null || true
            rm -f "${rc_file}.bak" 2>/dev/null
        fi
    done
}

# 综合自动系统自愈维护总函数
auto_system_maintenance() {
    cleanup_old_script_remnants
    cleanup_garbage_and_logs
}

# 初始化目录
init_directories() {
    devil www add ${USERNAME}.${DOMAIN} php > /dev/null 2>&1
    [ -d "$FILE_PATH" ] || mkdir -p "$FILE_PATH"
    [ -d "$WORKDIR" ] || (mkdir -p "$WORKDIR" && chmod 777 "$WORKDIR")
    [ -d "$KEEP_PATH" ] || mkdir -p "$KEEP_PATH"
    devil binexec on >/dev/null 2>&1
    # 默认自动清理垃圾与截断大日志
    auto_system_maintenance
    # 初始化 Psiphon 状态文件 (升级覆盖时自动补齐)
    init_psiphon_state_files
}

# 获取所有可用IP
get_all_ips() {
    # 获取三个可用的IP
    IP1=$(dig @8.8.8.8 +time=5 +short "$HOSTNAME" 2>/dev/null | head -n1)
    IP2=$(dig @8.8.8.8 +time=5 +short "cache$nb.${hona}.com" 2>/dev/null | head -n1)
    IP3=$(dig @8.8.8.8 +time=5 +short "web$nb.${hona}.com" 2>/dev/null | head -n1)
    
    # 去重并存储
    ALL_IPS=()
    [ -n "$IP1" ] && ALL_IPS+=("$IP1")
    [ -n "$IP2" ] && [[ ! " ${ALL_IPS[*]} " =~ " $IP2 " ]] && ALL_IPS+=("$IP2")
    [ -n "$IP3" ] && [[ ! " ${ALL_IPS[*]} " =~ " $IP3 " ]] && ALL_IPS+=("$IP3")
    
    # 如果dig失败，使用devil vhost list
    if [ ${#ALL_IPS[@]} -eq 0 ]; then
        ALL_IPS=($(devil vhost list | awk '/^[0-9]+/ {print $1}'))
    fi
    
    export ALL_IPS
    export IP_COUNT=${#ALL_IPS[@]}
    
    # 保存到文件
    printf '%s\n' "${ALL_IPS[@]}" > "$WORKDIR/all_ips.txt"
}
# 检测IP可达性 (优先亚太近邻与大陆监测节点)
check_ip_availability() {
    local ip=$1
    [ -z "$ip" ] && { echo "Unknown"; return; }

    # 选用多地域高可用节点 (香港/日本/新加坡)，兼容 check-host 平台节点池变动
    local check_url="https://check-host.net/check-ping?host=${ip}&node=hk1.node.check-host.net&node=jp1.node.check-host.net&node=sg1.node.check-host.net"
    local response=""
    response=$(curl -s -H "Accept: application/json" --max-time 5 "$check_url" 2>/dev/null)
    
    local req_id=""
    if [ -n "$response" ]; then
        req_id=$(echo "$response" | grep -o '"request_id":"[^"]*"' | head -n1 | cut -d'"' -f4)
    fi

    if [ -z "$req_id" ]; then
        echo "Unknown" > "$WORKDIR/ip_status_${ip}.txt" 2>/dev/null
        echo "Unknown"
        return
    fi

    # 轮询获取异步检测结果 (最多 3 次，防止未完成时被误判)
    local result=""
    local status="Unknown"
    for ((try=0; try<3; try++)); do
        sleep 2
        result=$(curl -s --max-time 4 "https://check-host.net/check-result/${req_id}" 2>/dev/null)
        if [ -n "$result" ] && [ "$result" != "{}" ]; then
            if echo "$result" | grep -q '"OK"'; then
                status="Available"
                break
            elif echo "$result" | grep -q '"TIMEOUT"'; then
                # 只有全节点均超时且未出现 OK 才判定阻断
                if ! echo "$result" | grep -q '"OK"'; then
                    status="Blocked"
                fi
                break
            fi
        fi
    done

    echo "$status" > "$WORKDIR/ip_status_${ip}.txt" 2>/dev/null
    echo "$status"
}

# 显示IP列表并批量检测可达性 (消除空节点误报)
display_ip_list() {
    yellow "正在检测本机IP的大陆及亚太可达性 (API: check-host.net)..."
    
    local req_ids=()
    for ip in "${ALL_IPS[@]}"; do
        local check_url="https://check-host.net/check-ping?host=${ip}&node=hk1.node.check-host.net&node=jp1.node.check-host.net&node=sg1.node.check-host.net"
        local response=""
        response=$(curl -s -H "Accept: application/json" --max-time 4 "$check_url" 2>/dev/null)
        local req_id=""
        if [ -n "$response" ]; then
            req_id=$(echo "$response" | grep -o '"request_id":"[^"]*"' | head -n1 | cut -d'"' -f4)
        fi
        req_ids+=("$req_id")
    done
    
    # 统一等待 3 秒以让节点返回检测结果
    sleep 3
    
    green "可用IP列表 (共 ${IP_COUNT} 个):"
    local idx=1
    for i in "${!ALL_IPS[@]}"; do
        local ip="${ALL_IPS[$i]}"
        local req_id="${req_ids[$i]}"
        local status="Unknown"
        
        if [ -n "$req_id" ]; then
            local result=""
            result=$(curl -s --max-time 4 "https://check-host.net/check-result/${req_id}" 2>/dev/null)
            # 如果尚未返回，轻量重试一次
            if [[ -z "$result" || "$result" == "{}" || "$result" == *":null"* ]]; then
                sleep 2
                result=$(curl -s --max-time 4 "https://check-host.net/check-result/${req_id}" 2>/dev/null)
            fi

            if [ -n "$result" ] && [ "$result" != "{}" ]; then
                if echo "$result" | grep -q '"OK"'; then
                    status="Available"
                elif echo "$result" | grep -q '"TIMEOUT"'; then
                    status="Blocked"
                fi
            fi
        fi
        
        # 写入缓存文件，供 generate_links 读取
        echo "$status" > "$WORKDIR/ip_status_${ip}.txt" 2>/dev/null
        
        if [[ "$status" == "Available" ]]; then
            green "  [$idx] $ip  ->  [可用] (未发现阻断)"
        elif [[ "$status" == "Blocked" ]]; then
            red "  [$idx] $ip  ->  [被墙] (Argo与CDN回源节点、proxyip依旧有效)"
        else
            yellow "  [$idx] $ip  ->  [未知] (API检测超时或节点无响应)"
        fi
        ((idx++))
    done
}



# ── 端口冲突检测(配置文件内部) ──────────────────────────
# 检查 config.json 里是否已有相同 (listen, listen_port) 的 inbound
# 返回: 0=冲突, 1=不冲突
port_conflict_in_config() {
    local ip="$1"
    local port="$2"
    local cfg="${3:-$WORKDIR/config.json}"
    
    [[ ! -f "$cfg" || -z "$ip" || -z "$port" ]] && return 1
    
    python3 - "$cfg" "$ip" "$port" <<'PYEOF' 2>/dev/null
import json, sys
cfg_path, ip, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    with open(cfg_path) as f:
        data = json.load(f)
    for ib in data.get("inbounds", []):
        if ib.get("listen") == ip and int(ib.get("listen_port", 0)) == port:
            sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
PYEOF
}

# 在端口分配前检查: 系统空闲 + 配置内不冲突
# 返回: 0=可用, 1=不可用
check_port_safe_for_config() {
    local port="$1"
    local proto="${2:-udp}"
    local cfg="${3:-$WORKDIR/config.json}"
    
    # 1. 系统端口检查(原逻辑)
    if check_port_in_use "$port" "$proto" >/dev/null 2>&1; then
        return 1
    fi
    
    # 2. 配置内冲突检查(新增)
    if [[ ${#ALL_IPS[@]} -eq 0 ]]; then
        get_all_ips 2>/dev/null || true
    fi
    for ip in "${ALL_IPS[@]}"; do
        if port_conflict_in_config "$ip" "$port" "$cfg"; then
            return 1
        fi
    done
    return 0
}


# 检测端口是否被占用 (sockstat 基础检测)
check_port_in_use() {
    local port=$1
    local protocol=${2:-tcp}
    
    # 使用 sockstat 检测端口占用 (FreeBSD/Serv00)
    local result=$(sockstat -l 2>/dev/null | grep ":$port " | head -1)
    
    if [ -n "$result" ]; then
        echo "$result"
        return 0  # 被占用
    fi
    return 1  # 未被占用
}

# 校验端口是否能在所有可用 IP ($ALL_IPS) 上成功 bind (TCP / UDP)
check_port_available_all_ips() {
    local port=$1
    local protocol=${2:-tcp}
    
    [ -z "$port" ] && return 1

    # 1. 基础 sockstat 检测
    if check_port_in_use "$port" "$protocol" >/dev/null 2>&1; then
        return 1
    fi

    # 2. 如果 ALL_IPS 为空，先获取 IP 列表
    if [ ${#ALL_IPS[@]} -eq 0 ]; then
        get_all_ips 2>/dev/null || true
    fi

    # 如果依旧没有 IP 列表，则仅依赖 sockstat
    if [ ${#ALL_IPS[@]} -eq 0 ]; then
        return 0
    fi

    # 3. 使用 Python 尝试在每个 IP 上 bind 该端口
    local py_cmd=""
    if command -v python3 >/dev/null 2>&1; then
        py_cmd="python3"
    elif command -v python >/dev/null 2>&1; then
        py_cmd="python"
    fi

    if [ -n "$py_cmd" ]; then
        $py_cmd - "$port" "$protocol" "${ALL_IPS[@]}" <<'PYEOF' >/dev/null 2>&1
import sys, socket

try:
    port = int(sys.argv[1])
    proto = sys.argv[2].lower()
    ips = sys.argv[3:]
except Exception:
    sys.exit(1)

sock_type = socket.SOCK_STREAM if proto == 'tcp' else socket.SOCK_DGRAM
is_udp = (proto != 'tcp')

for ip in ips:
    ip = ip.strip()
    if not ip:
        continue
    try:
        s = socket.socket(socket.AF_INET, sock_type)
        # TCP: SO_REUSEADDR 防止 TIME_WAIT 导致的误判
        # UDP: 不用 SO_REUSEADDR，否则 FreeBSD 下会与已绑定的 UDP 端口共存（假阳性）
        if not is_udp:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((ip, port))
        s.close()
    except Exception:
        sys.exit(1)

sys.exit(0)
PYEOF
        return $?
    fi

    return 0
}

# 检查某个端口 (TCP/UDP) 是否能在指定的单一 IP 上成功 bind
check_port_available_on_ip() {
    local port=$1
    local protocol=${2:-tcp}
    local ip=$3

    [ -z "$port" ] || [ -z "$ip" ] && return 1

    # 1. sockstat 检测
    if check_port_in_use "$port" "$protocol" >/dev/null 2>&1; then
        return 1
    fi

    # 2. Python socket bind 测试
    local py_cmd=""
    if command -v python3 >/dev/null 2>&1; then
        py_cmd="python3"
    elif command -v python >/dev/null 2>&1; then
        py_cmd="python"
    fi

    if [ -n "$py_cmd" ]; then
        $py_cmd - "$port" "$protocol" "$ip" <<'PYEOF' >/dev/null 2>&1
import sys, socket

try:
    port = int(sys.argv[1])
    proto = sys.argv[2].lower()
    ip = sys.argv[3].strip()
except Exception:
    sys.exit(1)

sock_type = socket.SOCK_STREAM if proto == 'tcp' else socket.SOCK_DGRAM
is_udp = (proto != 'tcp')

try:
    s = socket.socket(socket.AF_INET, sock_type)
    # TCP: SO_REUSEADDR 防止 TIME_WAIT 导致的误判
    # UDP: 不用 SO_REUSEADDR，否则 FreeBSD 下会与已绑定的 UDP 端口共存（假阳性）
    if not is_udp:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((ip, port))
    s.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
PYEOF
        return $?
    fi

    return 0
}

# 申请一个满足 3 个 IP (全 IP) 均可用的全新端口 (兼容 Serv00 波兰语/英语面板)
alloc_new_port_all_ips() {
    local proto=$1
    local desc=${2:-"singbox-port"}
    
    local new_port=""
    local retry=0
    while [[ $retry -lt 50 && -z "$new_port" ]]; do
        local cand=$(shuf -i 10000-65535 -n 1)
        if check_port_available_all_ips "$cand" "$proto"; then
            local res=""
            local ec=0
            
            # 先尝试带描述添加
            res=$(devil port add $proto $cand "$desc" 2>&1)
            ec=$?
            
            # 如果带描述失败，尝试不带描述添加
            if [[ $ec -ne 0 ]] || echo "$res" | grep -qiE "błąd|error|limit|usage"; then
                res=$(devil port add $proto $cand 2>&1)
                ec=$?
            fi

            # 判断面板返回是否成功 (Serv00 波兰语: został dodany / 英语: succesfully, Ok, success)
            if [[ $ec -eq 0 ]] && ! echo "$res" | grep -qiE "błąd|error|limit|istnieje|fail"; then
                new_port=$cand
                break
            fi
        fi
        ((retry++))
    done
    
    echo "$new_port"
}

# 标准端口更换逻辑 (先申请 3 个 IP 可用的新端口 → 删掉原端口 → 返回纯数字新端口供节点更新)
replace_occupied_port() {
    local proto=$1
    local desc=$2
    local old_port=$3
    
    # 1. 先去申请一个新的三个 IP 均可用的端口
    local new_p=""
    new_p=$(alloc_new_port_all_ips "$proto" "$desc")
    
    # 2. 如果直接申请成功，删掉原端口
    if [ -n "$new_p" ]; then
        if [ -n "$old_port" ] && [ "$old_port" != "0" ] && [ "$old_port" != "$new_p" ]; then
            devil port del "$proto" "$old_port" >/dev/null 2>&1
        fi
        echo "$new_p"
        return 0
    fi

    # 3. 如果因为端口额度超限导致未直接申请成功，先删除原冲突端口释放额度，再重试申请
    if [ -n "$old_port" ] && [ "$old_port" != "0" ]; then
        devil port del "$proto" "$old_port" >/dev/null 2>&1
        sleep 1
        new_p=$(alloc_new_port_all_ips "$proto" "$desc")
    fi

    if [ -n "$new_p" ]; then
        echo "$new_p"
        return 0
    fi

    echo -e "\e[1;91m[!] 无法申请到全 IP 可用的新端口\033[0m" >&2
    return 1
}

# 显示端口占用详情
show_port_usage() {
    local port=$1
    local usage=$(check_port_in_use $port)
    
    if [ -n "$usage" ]; then
        local proc_name=$(echo "$usage" | awk '{print $1}')
        local proc_user=$(echo "$usage" | awk '{print $2}')
        local proc_pid=$(echo "$usage" | awk '{print $3}')
        
        red "端口 $port 被占用:"
        yellow "  进程: $proc_name"
        yellow "  用户: $proc_user"
        yellow "  PID:  $proc_pid"
        echo
        yellow "解决方案:"
        yellow "  1. 终止进程: kill $proc_pid"
        yellow "  2. 或重置端口: 菜单选项 6"
        return 0
    fi
    return 1
}

# 添加端口的通用函数 (带描述，并严格校验全 IP 绑定可用性)
add_port_with_desc() {
    local port_type=$1
    local desc=${2:-"singbox-port"}
    local added_port=""
    local retry=0
    
    while [[ $retry -lt 40 && -z "$added_port" ]]; do
        local candidate=$(shuf -i 10000-65535 -n 1)
        
        # 检查端口在所有 IP 上是否均空闲且可绑定
        if ! check_port_available_all_ips "$candidate" "$port_type"; then
            ((retry++))
            continue
        fi
        
        # 尝试使用 devil port add 端口
        local result
        result=$(devil port add $port_type $candidate "$desc" 2>&1)
        if [[ $result == *"succesfully"* ]] || [[ $result == *"Ok"* ]] || [[ $result == *"success"* ]]; then
            added_port=$candidate
        else
            result=$(devil port add $port_type $candidate 2>&1)
            if [[ $result == *"succesfully"* ]] || [[ $result == *"Ok"* ]] || [[ $result == *"success"* ]]; then
                added_port=$candidate
            fi
        fi
        ((retry++))
    done
    
    echo "$added_port"
}

# 检查和配置端口
check_port() {
    # Hostuno: 直接添加4个新端口（带描述）
    if [[ "$PLATFORM" == "hostuno" ]]; then
        yellow "Hostuno平台: 直接添加新端口..."
        
        # VMess端口 (TCP)
        local vmess_port=$(add_port_with_desc "tcp" "singbox-vmess")
        if [ -n "$vmess_port" ]; then
            green "已添加端口: $vmess_port (TCP) - singbox-vmess"
        else
            red "VMess端口添加失败"
        fi
        
        # VLESS端口 (TCP)
        local vless_port=$(add_port_with_desc "tcp" "singbox-vless")
        if [ -n "$vless_port" ]; then
            green "已添加端口: $vless_port (TCP) - singbox-vless"
        else
            red "VLESS端口添加失败"
        fi
        
        # Hysteria2端口 (UDP)
        local hy2_port=$(add_port_with_desc "udp" "singbox-hy2")
        if [ -n "$hy2_port" ]; then
            green "已添加端口: $hy2_port (UDP) - singbox-hy2"
        else
            red "Hysteria2端口添加失败 (可能UDP端口数量已达上限)"
        fi
        
        # TUIC端口 (UDP)
        local tuic_port=$(add_port_with_desc "udp" "singbox-tuic")
        if [ -n "$tuic_port" ]; then
            green "已添加端口: $tuic_port (UDP) - singbox-tuic"
        else
            red "TUIC端口添加失败 (可能UDP端口数量已达上限)"
        fi
        
        # AnyTLS端口 (TCP, 可选)
        local anytls_port=""
        if [[ "$ENABLE_ANYTLS" == "true" ]]; then
            anytls_port=$(add_port_with_desc "tcp" "singbox-anytls")
            if [ -n "$anytls_port" ]; then
                green "已添加端口: $anytls_port (TCP) - singbox-anytls"
            else
                red "AnyTLS端口添加失败"
            fi
        fi
        
        # 分配端口
        export VMESS_PORT=$vmess_port
        export VLESS_PORT=$vless_port
        export HY2_PORT=$hy2_port
        export TUIC_PORT=$tuic_port
        export ANYTLS_PORT=$anytls_port
        
        echo
        purple "端口分配:"
        purple "  VMess-WS/Trojan: ${VMESS_PORT:-未分配} (TCP)"
        purple "  VLESS-Reality:   ${VLESS_PORT:-未分配} (TCP)"
        purple "  Hysteria2:       ${HY2_PORT:-未分配} (UDP)"
        purple "  TUIC v5:         ${TUIC_PORT:-未分配} (UDP)"
        purple "  AnyTLS:          ${ANYTLS_PORT:-未分配} (TCP)"
        
        # 检查是否有端口添加失败
        if [ -z "$vmess_port" ] || [ -z "$vless_port" ]; then
            red "⚠ TCP端口添加失败，无法继续安装"
            return 1
        fi
        
        if [ -z "$hy2_port" ] && [ -z "$tuic_port" ]; then
            yellow "⚠ UDP端口全部添加失败，Hysteria2和TUIC将不可用"
            yellow "提示: Hostuno可能限制了UDP端口数量，请检查面板"
        elif [ -z "$hy2_port" ] || [ -z "$tuic_port" ]; then
            yellow "⚠ 部分UDP端口添加失败，部分协议将不可用"
        else
            green "✓ 所有端口已添加"
        fi
        
        return 0
    fi
    
    # Serv00/CT8: 根据用户选择的协议动态分配端口
    port_list=$(devil port list)
    tcp_ports_now=$(echo "$port_list" | grep -c "tcp")
    udp_ports_now=$(echo "$port_list" | grep -c "udp")
    
    # 计算需要的端口数量
    required_tcp=0
    required_udp=0
    
    # VMess-WS 直连需要 1 TCP (Trojan 共用)
    [[ "$ENABLE_VMESS_WS" == "true" ]] && ((required_tcp++))
    
    # VLESS-Reality 需要 1 TCP
    [[ "$ENABLE_VLESS_REALITY" == "true" ]] && ((required_tcp++))
    
    # Hysteria2 需要 1 UDP
    [[ "$ENABLE_HYSTERIA2" == "true" ]] && ((required_udp++))
    
    # TUIC 需要 1 UDP (独立端口，不共用)
    [[ "$ENABLE_TUIC" == "true" ]] && ((required_udp++))
    
    # AnyTLS 需要 1 TCP
    [[ "$ENABLE_ANYTLS" == "true" ]] && ((required_tcp++))
    
    yellow "根据协议选择，需要: ${required_tcp} TCP + ${required_udp} UDP = $((required_tcp + required_udp)) 端口"
    
    if [[ $tcp_ports_now -ne $required_tcp || $udp_ports_now -ne $required_udp ]]; then
        yellow "当前端口数量不符，正在调整..."
        
        # 删除多余的TCP端口
        if [[ $tcp_ports_now -gt $required_tcp ]]; then
            tcp_to_delete=$((tcp_ports_now - required_tcp))
            echo "$port_list" | awk '/tcp/ {print $1, $2}' | head -n $tcp_to_delete | while read port type; do
                devil port del $type $port >/dev/null 2>&1
                green "已删除TCP端口: $port"
            done
        fi
        
        # 删除多余的UDP端口
        if [[ $udp_ports_now -gt $required_udp ]]; then
            udp_to_delete=$((udp_ports_now - required_udp))
            echo "$port_list" | awk '/udp/ {print $1, $2}' | head -n $udp_to_delete | while read port type; do
                devil port del $type $port >/dev/null 2>&1
                green "已删除UDP端口: $port"
            done
        fi
        
        # 添加缺失的TCP端口
        if [[ $tcp_ports_now -lt $required_tcp ]]; then
            tcp_ports_to_add=$((required_tcp - tcp_ports_now))
            tcp_ports_added=0
            local retry_count=0
            while [[ $tcp_ports_added -lt $tcp_ports_to_add && $retry_count -lt 30 ]]; do
                tcp_port=$(shuf -i 10000-65535 -n 1)
                
                if ! check_port_available_all_ips $tcp_port "tcp"; then
                    ((retry_count++))
                    continue
                fi
                
                result=$(devil port add tcp $tcp_port 2>&1)
                if [[ $result == *"succesfully"* ]] || [[ $result == *"Ok"* ]]; then
                    green "已添加TCP端口: $tcp_port"
                    tcp_ports_added=$((tcp_ports_added + 1))
                fi
                ((retry_count++))
            done
        fi
        
        # 添加缺失的UDP端口
        if [[ $udp_ports_now -lt $required_udp ]]; then
            udp_ports_to_add=$((required_udp - udp_ports_now))
            udp_ports_added=0
            local retry_count=0
            while [[ $udp_ports_added -lt $udp_ports_to_add && $retry_count -lt 30 ]]; do
                udp_port=$(shuf -i 10000-65535 -n 1)
                
                if ! check_port_available_all_ips $udp_port "udp"; then
                    ((retry_count++))
                    continue
                fi
                
                result=$(devil port add udp $udp_port 2>&1)
                if [[ $result == *"succesfully"* ]] || [[ $result == *"Ok"* ]]; then
                    green "已添加UDP端口: $udp_port"
                    udp_ports_added=$((udp_ports_added + 1))
                fi
                ((retry_count++))
            done
        fi
        
        sleep 2
        port_list=$(devil port list)
    fi
    
    # 获取端口列表
    tcp_ports_list=$(echo "$port_list" | awk '/tcp/ {print $1}')
    udp_ports_list=$(echo "$port_list" | awk '/udp/ {print $1}')
    
    TCP_PORT1=$(echo "$tcp_ports_list" | sed -n '1p')
    TCP_PORT2=$(echo "$tcp_ports_list" | sed -n '2p')
    UDP_PORT1=$(echo "$udp_ports_list" | sed -n '1p')
    UDP_PORT2=$(echo "$udp_ports_list" | sed -n '2p')
    
    # 根据协议分配端口
    local tcp_idx=1
    local udp_idx=1
    
    # VMess-WS / Trojan 分配第一个TCP
    if [[ "$ENABLE_VMESS_WS" == "true" ]]; then
        export VMESS_PORT=$TCP_PORT1
        ((tcp_idx++))
    fi
    
    # VLESS-Reality 分配下一个TCP
    if [[ "$ENABLE_VLESS_REALITY" == "true" ]]; then
        if [[ $tcp_idx -eq 1 ]]; then
            export VLESS_PORT=$TCP_PORT1
        else
            export VLESS_PORT=$TCP_PORT2
        fi
        ((tcp_idx++))
    fi
    
    # AnyTLS 分配下一个TCP (若第三个TCP存在)
    if [[ "$ENABLE_ANYTLS" == "true" ]]; then
        if [[ $tcp_idx -eq 1 ]]; then
            export ANYTLS_PORT=$TCP_PORT1
        elif [[ $tcp_idx -eq 2 ]]; then
            export ANYTLS_PORT=$TCP_PORT2
        else
            export ANYTLS_PORT=$(echo "$tcp_ports_list" | sed -n '3p')
        fi
        ((tcp_idx++))
    fi
    
    # Hysteria2 分配第一个UDP
    if [[ "$ENABLE_HYSTERIA2" == "true" ]]; then
        export HY2_PORT=$UDP_PORT1
        ((udp_idx++))
    fi
    
    # TUIC 分配下一个UDP (独立端口)
    if [[ "$ENABLE_TUIC" == "true" ]]; then
        if [[ $udp_idx -eq 1 ]]; then
            export TUIC_PORT=$UDP_PORT1
        else
            export TUIC_PORT=$UDP_PORT2
        fi
        ((udp_idx++))
    fi
    
    echo
    purple "端口分配:"
    [[ -n "$VMESS_PORT" ]] && purple "  VMess-WS/Trojan: $VMESS_PORT (TCP)"
    [[ -n "$VLESS_PORT" ]] && purple "  VLESS-Reality:   $VLESS_PORT (TCP)"
    [[ -n "$HY2_PORT" ]] && purple "  Hysteria2:       $HY2_PORT (UDP)"
    [[ -n "$TUIC_PORT" ]] && purple "  TUIC v5:         $TUIC_PORT (UDP)"
    
    # 检测端口在全 IP 上的占用及绑定冲突
    echo
    local has_conflict=false
    
    if [ -n "$VMESS_PORT" ] && ! check_port_available_all_ips "$VMESS_PORT" "tcp"; then
        has_conflict=true
        show_port_usage "$VMESS_PORT"
    fi
    if [ -n "$VLESS_PORT" ] && ! check_port_available_all_ips "$VLESS_PORT" "tcp"; then
        has_conflict=true
        show_port_usage "$VLESS_PORT"
    fi
    if [ -n "$HY2_PORT" ] && ! check_port_available_all_ips "$HY2_PORT" "udp"; then
        has_conflict=true
        show_port_usage "$HY2_PORT"
    fi
    if [ -n "$TUIC_PORT" ] && ! check_port_available_all_ips "$TUIC_PORT" "udp"; then
        has_conflict=true
        show_port_usage "$TUIC_PORT"
    fi
    
    if $has_conflict; then
        echo
        red "⚠ 检测到端口冲突 (部分 IP 无法绑定相应端口)！"
        yellow "正在自动重置被占用的冲突端口并申请全 IP 可用的新端口..."
        auto_repair_conflicting_ports
        local rc=$?
        if [[ $rc -eq 2 ]]; then
            red "[!] 端口冲突修复失败 (全量重置未成功)，请检查端口额度后重试"
            return 1
        elif [[ $rc -eq 0 ]]; then
            green "端口冲突已修复"
        fi
    else
        green "✓ 所有端口在全 IP 上测试可用"
    fi
}

# 重置所有端口
reset_all_ports() {
    yellow "正在重置所有端口..."
    
    # Hostuno不删除端口
    if [[ "$PLATFORM" == "hostuno" ]]; then
        yellow "Hostuno平台：不删除现有端口，仅检查并添加缺失端口"
        check_port
        green "端口检查完成！"
        return
    fi
    
    portlist=$(devil port list | grep -E '^[0-9]+[[:space:]]+[a-zA-Z]+' | sed 's/^[[:space:]]*//')
    if [[ -n "$portlist" ]]; then
        while read -r line; do
            port=$(echo "$line" | awk '{print $1}')
            port_type=$(echo "$line" | awk '{print $2}')
            devil port del "$port_type" "$port" >/dev/null 2>&1
            yellow "删除端口: $port ($port_type)"
        done <<< "$portlist"
    fi
    
    check_port
    green "端口重置完成！"
}

# ==================== 证书函数 ====================

# 生成自签名证书
generate_certificate() {
    cd "$WORKDIR"
    openssl ecparam -genkey -name prime256v1 -out "private.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "private.key" -out "cert.pem" \
        -subj "/CN=${USERNAME}.${DOMAIN}" 2>/dev/null
    green "自签名证书已生成"
}

# 生成Reality密钥对
generate_reality_keys() {
    cd "$WORKDIR"
    if [ ! -f "private_key.txt" ]; then
        output=$(./${SB_BINARY} generate reality-keypair 2>/dev/null)
        private_key=$(echo "${output}" | awk '/PrivateKey:/ {print $2}')
        public_key=$(echo "${output}" | awk '/PublicKey:/ {print $2}')
        echo "${private_key}" > private_key.txt
        echo "${public_key}" > public_key.txt
    fi
    export REALITY_PRIVATE_KEY=$(cat private_key.txt 2>/dev/null)
    export REALITY_PUBLIC_KEY=$(cat public_key.txt 2>/dev/null)
}

# ==================== WARP 出站函数 ====================

# 初始化/获取 WARP 配置 (参照 argosbx)
init_warp_config() {
    yellow "获取 WARP 配置..."
    
    # 尝试从勇哥的 API 获取预注册配置
    local warpurl=""
    warpurl=$(curl -sm5 -k https://warp.xijp.eu.org 2>/dev/null) || \
    warpurl=$(wget -qO- --timeout=5 https://warp.xijp.eu.org 2>/dev/null)
    
    if [ -n "$warpurl" ] && ! echo "$warpurl" | grep -q html; then
        WARP_PRIVATE_KEY=$(echo "$warpurl" | awk -F'：' '/Private_key/{print $2}' | xargs)
        WARP_IPV6=$(echo "$warpurl" | awk -F'：' '/IPV6/{print $2}' | xargs)
        WARP_RESERVED=$(echo "$warpurl" | awk -F'：' '/reserved/{print $2}' | xargs)
        green "WARP 配置获取成功 (远程API: warp.xijp.eu.org)"
    else
        # 备用硬编码配置
        WARP_IPV6='2606:4700:110:8d8d:1845:c39f:2dd5:a03a'
        WARP_PRIVATE_KEY='52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A='
        WARP_RESERVED='[215, 69, 233]'
        green "WARP 配置获取成功 (备用配置)"
    fi
    
    # 保存配置供后续使用
    echo "$WARP_PRIVATE_KEY" > "$WORKDIR/warp_private_key.txt"
    echo "$WARP_RESERVED" > "$WORKDIR/warp_reserved.txt"
    echo "$WARP_IPV6" > "$WORKDIR/warp_ipv6.txt"
    
    return 0
}

# 获取 WARP Endpoint 配置 (检测网络环境选择最佳 Endpoint)
get_warp_endpoint() {
    # 优先使用已保存的优选 Endpoint
    if [ -f "$WORKDIR/warp_best_endpoint.txt" ]; then
        local saved_endpoint=$(cat "$WORKDIR/warp_best_endpoint.txt" 2>/dev/null)
        if [ -n "$saved_endpoint" ]; then
            echo "$saved_endpoint"
            return
        fi
    fi
    
    local has_ipv4=false
    local has_ipv6=false
    
    # 检测网络环境 (FreeBSD 兼容)
    curl -s4m2 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep -q "warp\|h=" && has_ipv4=true
    curl -s6m2 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep -q "warp\|h=" && has_ipv6=true
    
    # 备用检测 (FreeBSD 使用 ifconfig)
    if [ "$has_ipv4" = false ] && [ "$has_ipv6" = false ]; then
        if command -v ip >/dev/null 2>&1; then
            ip -4 route show default 2>/dev/null | grep -q default && has_ipv4=true
            ip -6 route show default 2>/dev/null | grep -q default && has_ipv6=true
        else
            # FreeBSD
            netstat -rn 2>/dev/null | grep -q "^default.*[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+" && has_ipv4=true
            netstat -rn 2>/dev/null | grep -q "^default.*:" && has_ipv6=true
        fi
    fi
    
    if [ "$has_ipv6" = true ] && [ "$has_ipv4" = false ]; then
        # 纯 IPv6 环境
        echo "2606:4700:d0::a29f:c001"
    else
        # IPv4 或双栈，使用默认 IP
        echo "162.159.192.1"
    fi
}

# WARP Endpoint IP 优选 (纯Shell实现，兼容FreeBSD)
# 原理: 向WARP服务器发送UDP包，测量响应时间和丢包率
optimize_warp_endpoint() {
    local ipv6_mode="$1"  # 传入 6 则使用 IPv6 优选
    
    cd "$WORKDIR"
    
    echo
    green "==== WARP Endpoint IP 优选 ===="
    echo
    
    # 检查是否有上次的优选结果
    local last_result_file="$WORKDIR/warp_result_history.txt"
    local current_endpoint=$(cat "$WORKDIR/warp_best_endpoint.txt" 2>/dev/null)
    local current_port=$(cat "$WORKDIR/warp_best_port.txt" 2>/dev/null)
    
    if [ -n "$current_endpoint" ]; then
        blue "当前使用的 Endpoint: ${current_endpoint}:${current_port:-2408}"
    else
        yellow "当前状态: 未选择优选 Endpoint (使用默认)"
    fi
    
    # 如果有历史记录，显示选项
    if [ -f "$last_result_file" ] && [ -s "$last_result_file" ]; then
        echo
        blue "检测到上次优选结果:"
        echo "----------------------------------------"
        local idx=1
        tail -n +2 "$last_result_file" | \
            awk -F, '$2 < 100' | \
            sort -t, -k2,2n -k3,3n | \
            head -10 | \
            while IFS=, read -r endpoint loss delay; do
                printf "  %2d. %-22s 丢包:%s%% 延迟:%sms\n" "$idx" "$endpoint" "$loss" "$delay"
                idx=$((idx + 1))
            done
        echo "----------------------------------------"
        echo
        yellow "选项:"
        yellow "  1-10. 选择上次结果中的 Endpoint"
        yellow "  n. 进行新的优选测试"
        yellow "  0. 返回不修改"
        reading "请选择: " history_choice
        
        case "$history_choice" in
            [1-9]|10)
                # 从历史中选择
                local selected_line=$(tail -n +2 "$last_result_file" | \
                    awk -F, '$2 < 100' | \
                    sort -t, -k2,2n -k3,3n | \
                    sed -n "${history_choice}p")
                
                if [ -n "$selected_line" ]; then
                    local sel_endpoint=$(echo "$selected_line" | cut -d, -f1)
                    local sel_ip=$(echo "$sel_endpoint" | cut -d: -f1)
                    local sel_port=$(echo "$sel_endpoint" | cut -d: -f2)
                    
                    echo "$sel_ip" > "$WORKDIR/warp_best_endpoint.txt"
                    echo "$sel_port" > "$WORKDIR/warp_best_port.txt"
                    green "已选择 Endpoint: $sel_ip:$sel_port"
                    
                    # 更新配置文件
                    update_warp_config "$sel_ip" "$sel_port"
                    return 0
                else
                    red "无效选择"
                    return 1
                fi
                ;;
            n|N)
                # 继续进行新的优选
                ;;
            0|"")
                yellow "已取消"
                return 0
                ;;
            *)
                red "无效选择"
                return 1
                ;;
        esac
    fi
    
    # 检查依赖
    if ! command -v nc >/dev/null 2>&1; then
        red "错误: 需要 nc (netcat) 命令"
        return 1
    fi
    
    # 检查是否需要关闭 WARP/sing-box 服务
    local sb_binary=$(cat "$WORKDIR/sb.txt" 2>/dev/null)
    local warp_running=false
    
    if [ -n "$sb_binary" ] && pgrep -x "$sb_binary" >/dev/null 2>&1; then
        local warp_status=$(cat "$WORKDIR/warp_enabled.txt" 2>/dev/null)
        if [[ "$warp_status" == "true" ]]; then
            warp_running=true
            yellow "检测到 WARP 正在运行，需要暂时关闭以进行优选..."
            pkill -x "$sb_binary" >/dev/null 2>&1
            sleep 2
            green "已暂停 sing-box 服务"
        fi
    fi
    
    local result_file="$WORKDIR/warp_result.txt"
    
    # 清理之前的结果
    rm -f "$result_file"
    
    # WARP 端口列表 (官方端口)
    local ports=(500 1701 2408 4500)
    
    # 生成测试IP列表
    echo
    yellow "正在生成测试IP列表..."
    
    local test_ips=()
    
    if [[ "$ipv6_mode" == "6" ]]; then
        yellow "模式: IPv6 优选"
        test_ips=(
            "2606:4700:d0::a29f:c001"
            "2606:4700:d0::a29f:c002"
            "2606:4700:d0::a29f:c003"
            "2606:4700:d1::a29f:c001"
            "2606:4700:d1::a29f:c002"
        )
    else
        yellow "模式: IPv4 优选"
        local cidrs=("162.159.192" "162.159.193" "162.159.195" "188.114.96" "188.114.97")
        
        for cidr in "${cidrs[@]}"; do
            for i in $(seq 1 10); do
                local last_octet=$((RANDOM % 254 + 1))
                test_ips+=("${cidr}.${last_octet}")
            done
        done
    fi
    
    local total_ips=${#test_ips[@]}
    green "共生成 $total_ips 个测试IP"
    echo
    
    yellow "开始测试 Endpoint 延迟..."
    yellow "这可能需要1-2分钟，请耐心等待..."
    echo
    
    # 进度显示
    local tested=0
    local success=0
    
    # 创建结果文件
    echo "endpoint,loss,delay" > "$result_file"
    
    for ip in "${test_ips[@]}"; do
        # 随机选择端口
        local port=${ports[$((RANDOM % ${#ports[@]}))]}
        
        local total_time=0
        local recv_count=0
        local send_count=3
        
        for i in $(seq 1 $send_count); do
            local start_time=$(date +%s)
            
            # 使用 nc 测试连接 (不捕获响应内容，避免null byte警告)
            # -z 只扫描，不发送数据 (用于快速测试端口可达性)
            # 或使用 -w 1 设置超时
            if echo "" | timeout 1 nc -u -w 1 "$ip" "$port" >/dev/null 2>&1; then
                recv_count=$((recv_count + 1))
            fi
            
            local end_time=$(date +%s)
            local elapsed=$((end_time - start_time))
            total_time=$((total_time + elapsed * 1000))
        done
        
        # 计算丢包率和平均延迟
        local loss=100
        local delay=9999
        
        if [ $recv_count -gt 0 ]; then
            loss=$(( (send_count - recv_count) * 100 / send_count ))
            delay=$((total_time / recv_count))
            success=$((success + 1))
        fi
        
        # 保存结果
        echo "${ip}:${port},${loss},${delay}" >> "$result_file"
        
        tested=$((tested + 1))
        if [ $((tested % 10)) -eq 0 ]; then
            printf "\r进度: %d/%d (成功: %d)   " "$tested" "$total_ips" "$success"
        fi
    done
    
    printf "\r进度: %d/%d (成功: %d)   \n" "$tested" "$total_ips" "$success"
    echo
    
    # 保存为历史记录
    cp "$result_file" "$last_result_file"
    
    # 检查是否有结果
    local valid_count=$(tail -n +2 "$result_file" | awk -F, '$2 < 100' | wc -l)
    if [ "$valid_count" -eq 0 ]; then
        red "优选失败，无可用 Endpoint"
        yellow "可能原因: 网络不通或防火墙阻止UDP"
        # 恢复服务
        if $warp_running && [ -n "$sb_binary" ] && [ -f "$sb_binary" ]; then
            run_detached "$WORKDIR/singbox.pid" "$WORKDIR/singbox.log" \
                ./"$sb_binary" run -c config.json
            green "已恢复 sing-box 服务"
        fi
        return 1
    fi
    
    # 显示排序后的结果
    echo
    green "优选结果 (按延迟排序):"
    echo "=============================================="
    printf "  %-4s %-22s %-8s %-8s\n" "序号" "Endpoint" "丢包%" "延迟ms"
    echo "----------------------------------------------"
    
    # 提取并排序，带序号显示
    local idx=1
    tail -n +2 "$result_file" | \
        awk -F, '$2 < 100' | \
        sort -t, -k2,2n -k3,3n | \
        head -10 | \
        while IFS=, read -r endpoint loss delay; do
            printf "  %-4s %-22s %-8s %-8s\n" "[$idx]" "$endpoint" "$loss" "$delay"
            idx=$((idx + 1))
        done
    
    echo "=============================================="
    echo
    
    # 让用户选择
    yellow "请选择要使用的 Endpoint (输入序号 1-10，回车使用第1个):"
    reading "选择: " user_choice
    
    if [ -z "$user_choice" ]; then
        user_choice=1
    fi
    
    # 验证输入
    if ! [[ "$user_choice" =~ ^[0-9]+$ ]] || [ "$user_choice" -lt 1 ] || [ "$user_choice" -gt 10 ]; then
        user_choice=1
    fi
    
    # 获取用户选择的 Endpoint
    local selected_line=$(tail -n +2 "$result_file" | \
        awk -F, '$2 < 100' | \
        sort -t, -k2,2n -k3,3n | \
        sed -n "${user_choice}p")
    
    if [ -z "$selected_line" ]; then
        selected_line=$(tail -n +2 "$result_file" | awk -F, '$2 < 100' | sort -t, -k2,2n -k3,3n | head -1)
    fi
    
    local best_endpoint=$(echo "$selected_line" | cut -d, -f1)
    local best_ip=$(echo "$best_endpoint" | cut -d: -f1)
    local best_port=$(echo "$best_endpoint" | cut -d: -f2)
    local best_loss=$(echo "$selected_line" | cut -d, -f2)
    local best_delay=$(echo "$selected_line" | cut -d, -f3)
    
    echo
    green "★ 已选择 Endpoint: $best_ip:$best_port"
    green "  丢包率: ${best_loss}%, 延迟: ${best_delay}ms"
    
    # 保存优选结果
    echo "$best_ip" > "$WORKDIR/warp_best_endpoint.txt"
    echo "$best_port" > "$WORKDIR/warp_best_port.txt"
    green "已保存优选结果"
    
    # 更新配置文件并重启服务
    update_warp_config "$best_ip" "$best_port"
    
    green "Endpoint 优选完成！"
    return 0
}

# 更新 WARP 配置文件中的 Endpoint 及全套节点属性
# 参数: $1=IP, $2=端口, $3=restart(可选，传入restart则自动重启)
update_warp_config() {
    local new_ip="$1"
    local new_port="$2"
    local auto_restart="$3"
    
    if [ ! -f "$WORKDIR/config.json" ]; then
        return 0
    fi
    
    # 如果不是自动重启模式，询问用户
    if [[ "$auto_restart" != "restart" ]]; then
        echo
        reading "是否立即更新配置文件中的 Endpoint? [Y/n]: " update_now
        
        if [[ "$update_now" =~ ^[Nn]$ ]]; then
            yellow "配置未更新，稍后可在菜单中手动更新"
            return 0
        fi
    fi
    
    cd "$WORKDIR" 2>/dev/null || return 1
    
    # 备份配置
    cp config.json config.json.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null
    
    local warp_ipv6="${WARP_IPV6:-$(cat "$WORKDIR/warp_ipv6.txt" 2>/dev/null || echo "2606:4700:110:8d8d:1845:c39f:2dd5:a03a")}"
    local warp_private_key="${WARP_PRIVATE_KEY:-$(cat "$WORKDIR/warp_private_key.txt" 2>/dev/null || echo "52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A=")}"
    local warp_reserved="${WARP_RESERVED:-$(cat "$WORKDIR/warp_reserved.txt" 2>/dev/null || echo "[215, 69, 233]")}"
    
    yellow "[*] 正在更新 sing-box 配置文件中的 WARP 出站..."

    python3 - <<PY
import json
import sys

cfg_path = "config.json"
new_ip = r"$new_ip"
new_port = int(r"${new_port:-2408}")
warp_ipv6 = r"$warp_ipv6"
warp_private_key = r"$warp_private_key"
warp_reserved_str = r"$warp_reserved"

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"[!] 读取 config.json 失败: {e}")
    sys.exit(1)

outbounds = data.setdefault("outbounds", [])
route = data.setdefault("route", {})
rules = route.setdefault("rules", [])

try:
    warp_reserved = json.loads(warp_reserved_str)
except Exception:
    warp_reserved = [215, 69, 233]

warp_tag = "warp-out"
warp_found = False

for o in outbounds:
    if o.get("tag") == warp_tag or o.get("type") == "wireguard":
        o.clear()
        o.update({
            "type": "wireguard",
            "tag": warp_tag,
            "server": new_ip,
            "server_port": new_port,
            "local_address": [
                "172.16.0.2/32",
                warp_ipv6 if "/" in warp_ipv6 else f"{warp_ipv6}/128"
            ],
            "private_key": warp_private_key,
            "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
            "reserved": warp_reserved,
            "mtu": 1280
        })
        warp_found = True
        break

if not warp_found:
    outbounds.append({
        "type": "wireguard",
        "tag": warp_tag,
        "server": new_ip,
        "server_port": new_port,
        "local_address": [
            "172.16.0.2/32",
            warp_ipv6 if "/" in warp_ipv6 else f"{warp_ipv6}/128"
        ],
        "private_key": warp_private_key,
        "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
        "reserved": warp_reserved,
        "mtu": 1280
    })

# 清理未定义的悬挂 outbound 路由规则并保持副节点规则置顶
existing_tags = {o.get("tag") for o in outbounds if o.get("tag")}
rules[:] = [r for r in rules if not r.get("outbound") or r.get("outbound") in existing_tags]
proxy_rules = [r for r in rules if r.get("outbound", "").endswith("-out") and r.get("outbound") != warp_tag]
psi_rules = [r for r in rules if r.get("outbound", "").startswith("psiphon-")]
other_rules = [r for r in rules if r not in proxy_rules and r not in psi_rules]
rules[:] = proxy_rules + psi_rules + other_rules

try:
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("[+] 配置文件更新完成 (WARP 出站已完整写入)")
except Exception as e:
    print(f"[!] 写入配置文件失败: {e}")
    sys.exit(1)
PY

    if [ $? -ne 0 ]; then
        red "[!] 配置文件更新失败"
        return 1
    fi
    
    # 统一使用 safe 重启函数
    start_singbox_safe
}

# 询问是否启用 WARP 出站
ask_warp_outbound() {
    echo
    green "==== WARP 出站配置 ===="
    yellow "WARP 可以解锁流媒体、隐藏服务器真实IP"
    echo
    yellow "选项:"
    yellow "  0. 不使用 WARP (默认)"
    yellow "  1. 全部流量走 WARP"
    yellow "  2. 仅 Google/YouTube 走 WARP (分流)"
    reading "请选择 0-2: " warp_choice
    
    case "$warp_choice" in
        1)
            if init_warp_config; then
                WARP_ENABLED=true
                WARP_MODE="all"
                green "已启用 WARP 出站 (全部流量)"
                
                # 首次安装时自动运行 Endpoint 优选
                echo
                yellow "首次启用 WARP，建议进行 Endpoint 优选以获取最佳连接质量"
                reading "是否现在运行 Endpoint 优选? [Y/n]: " run_optimize
                
                if [[ ! "$run_optimize" =~ ^[Nn]$ ]]; then
                    echo
                    yellow "选择优选模式:"
                    yellow "  1. IPv4 优选 (默认)"
                    yellow "  2. IPv6 优选"
                    reading "请选择 [1-2]: " opt_mode
                    
                    if [[ "$opt_mode" == "2" ]]; then
                        optimize_warp_endpoint 6
                    else
                        optimize_warp_endpoint
                    fi
                fi
            else
                WARP_ENABLED=false
                red "WARP 配置失败，将使用直连出站"
            fi
            ;;
        2)
            if init_warp_config; then
                WARP_ENABLED=true
                WARP_MODE="google"
                green "已启用 WARP 出站 (仅 Google/YouTube)"
                
                # 首次安装时自动运行 Endpoint 优选
                echo
                yellow "首次启用 WARP，建议进行 Endpoint 优选以获取最佳连接质量"
                reading "是否现在运行 Endpoint 优选? [Y/n]: " run_optimize
                
                if [[ ! "$run_optimize" =~ ^[Nn]$ ]]; then
                    echo
                    yellow "选择优选模式:"
                    yellow "  1. IPv4 优选 (默认)"
                    yellow "  2. IPv6 优选"
                    reading "请选择 [1-2]: " opt_mode
                    
                    if [[ "$opt_mode" == "2" ]]; then
                        optimize_warp_endpoint 6
                    else
                        optimize_warp_endpoint
                    fi
                fi
            else
                WARP_ENABLED=false
                red "WARP 配置失败，将使用直连出站"
            fi
            ;;
        *)
            WARP_ENABLED=false
            WARP_MODE=""
            green "使用直连出站 (不使用 WARP)"
            ;;
    esac
    
    # 保存设置
    echo "$WARP_ENABLED" > "$WORKDIR/warp_enabled.txt"
    echo "$WARP_MODE" > "$WORKDIR/warp_mode.txt"
}

# ==================== Psiphon 出站配置 ====================
# Psiphon ConsoleClient 下载配置
PSI_REPO_OWNER="hxzlplp7"
PSI_REPO_NAME="psiphon-tunnel-core"
PSI_TAG_DEFAULT="v1.0.0"

# 初始化 Psiphon 状态文件 (升级覆盖时自动补齐)
init_psiphon_state_files() {
    : "${WORKDIR:?WORKDIR not set}"
    [[ -f "$WORKDIR/psiphon_enabled.txt" ]]    || echo "false" > "$WORKDIR/psiphon_enabled.txt"
    [[ -f "$WORKDIR/psiphon_mode.txt" ]]       || echo "all"   > "$WORKDIR/psiphon_mode.txt"
    [[ -f "$WORKDIR/psiphon_region.txt" ]]     || echo "US"    > "$WORKDIR/psiphon_region.txt"
    # 使用 0 表示自动端口 (FreeBSD mac_portacl 限制固定端口绑定)
    [[ -f "$WORKDIR/psiphon_socks_port.txt" ]] || echo "0"     > "$WORKDIR/psiphon_socks_port.txt"
    [[ -f "$WORKDIR/psiphon_http_port.txt" ]]  || echo "0"     > "$WORKDIR/psiphon_http_port.txt"
    [[ -f "$WORKDIR/psi.txt" ]]                || : > "$WORKDIR/psi.txt"
    [[ -f "$WORKDIR/psiphon.log" ]]            || : > "$WORKDIR/psiphon.log"
    # 运行时实际监听端口文件 (自动端口模式必需)
    [[ -f "$WORKDIR/psiphon_socks_listen.txt" ]] || : > "$WORKDIR/psiphon_socks_listen.txt"
    [[ -f "$WORKDIR/psiphon_http_listen.txt" ]]  || : > "$WORKDIR/psiphon_http_listen.txt"
}

# 从系统监听套接字中探测 Psiphon 实际绑定的 TCP 端口
detect_psiphon_port_from_system() {
    local pid_file="${1:-$WORKDIR/psiphon.pid}"
    local pid=""
    if [[ -f "$pid_file" ]]; then
        pid="$(cat "$pid_file" 2>/dev/null)"
    fi
    
    local port=""
    # 1. FreeBSD sockstat
    if command -v sockstat >/dev/null 2>&1; then
        if [[ -n "$pid" ]]; then
            port=$(sockstat -4 -l -p "$pid" 2>/dev/null | awk '/tcp/ {print $6}' | awk -F: '{print $NF}' | grep -E '^[0-9]+$' | head -n1)
        fi
        if [[ -z "$port" ]]; then
            port=$(sockstat -4 -l 2>/dev/null | grep -E 'psiphon' | awk '/tcp/ {print $6}' | awk -F: '{print $NF}' | grep -E '^[0-9]+$' | head -n1)
        fi
    fi
    
    # 2. Linux lsof
    if [[ -z "$port" ]] && command -v lsof >/dev/null 2>&1; then
        if [[ -n "$pid" ]]; then
            port=$(lsof -a -p "$pid" -i TCP -s TCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | awk -F: '{print $NF}' | grep -E '^[0-9]+$' | head -n1)
        fi
    fi
    
    # 3. netstat
    if [[ -z "$port" ]] && command -v netstat >/dev/null 2>&1; then
        port=$(netstat -an 2>/dev/null | grep LISTEN | grep -E '127\.0\.0\.1' | grep -E 'psiphon' | awk '{print $4}' | awk -F: '{print $NF}' | grep -E '^[0-9]+$' | head -n1)
    fi

    if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 )); then
        echo "$port"
        return 0
    fi
    return 1
}

# 获取 Psiphon 实际 SOCKS 端口 (优先读运行时端口，其次调用底层 Socket 探针)
get_psiphon_socks_port() {
    local p=""
    # 优先读运行时实际监听端口
    p="$(cat "$WORKDIR/psiphon_socks_listen.txt" 2>/dev/null || true)"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then
        echo "$p"
        return 0
    fi
    # 尝试底层系统 Socket 探针
    p="$(detect_psiphon_port_from_system "$WORKDIR/psiphon.pid")"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then
        echo "$p" > "$WORKDIR/psiphon_socks_listen.txt" 2>/dev/null
        echo "$p"
        return 0
    fi
    # fallback: 读配置端口 (如果是固定非 0 端口)
    p="$(cat "$WORKDIR/psiphon_socks_port.txt" 2>/dev/null || true)"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then
        echo "$p"
        return 0
    fi
    # fallback: 读 psiphon.config 内部端口
    if [ -f "$WORKDIR/psiphon.config" ]; then
        p=$(grep -oE '"LocalSocksProxyPort":[[:space:]]*[0-9]+' "$WORKDIR/psiphon.config" | awk -F: '{print $2}' | tr -d ' ,')
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 )); then
            echo "$p"
            return 0
        fi
    fi
    echo "0"
}

# 从 psiphon.log 或底层系统 socket 解析实际监听端口
psiphon_update_listen_ports_from_log() {
    local log="$WORKDIR/psiphon.log"
    local socks http

    # 1. 提取 SOCKS 端口
    socks="$(grep -a '"ListeningSocksProxyPort"' "$log" 2>/dev/null | tail -n 1 | grep -oE '"port":[[:space:]]*[0-9]+' | grep -oE '[0-9]+')"
    if [[ -z "$socks" || "$socks" == "0" ]]; then
        socks="$(detect_psiphon_port_from_system "$WORKDIR/psiphon.pid")"
    fi

    if [[ "$socks" =~ ^[0-9]+$ ]] && (( socks > 0 )); then
        echo "$socks" > "$WORKDIR/psiphon_socks_listen.txt"
        green "[+] Psiphon SOCKS 实际端口: $socks"
    fi

    # 提取 HTTP 端口
    http="$(grep -a '"ListeningHttpProxyPort"' "$log" 2>/dev/null | tail -n 1 | grep -oE '"port":[[:space:]]*[0-9]+' | grep -oE '[0-9]+')"
    if [[ "$http" =~ ^[0-9]+$ ]] && (( http > 0 )); then
        echo "$http" > "$WORKDIR/psiphon_http_listen.txt"
    fi
}

# 检测操作系统
detect_os_slim() {
    case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
        linux) echo "linux" ;;
        freebsd) echo "freebsd" ;;
        *) echo "unsupported" ;;
    esac
}

# 检测架构
detect_arch_slim() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "unknown" ;;
    esac
}

# 安装 Psiphon ConsoleClient (无 root 版本)
install_psiphon_userland() {
    local os arch tag base url tmpd
    os="$(detect_os_slim)"
    arch="$(detect_arch_slim)"

    [[ "$os" != "unsupported" ]] || { red "[!] 不支持的系统: $(uname -s)"; return 1; }
    [[ "$arch" != "unknown" ]]   || { red "[!] 不支持的架构: $(uname -m)"; return 1; }

    tmpd="$(mktemp -d)"
    tag="${PSI_TAG_DEFAULT}"
    base="https://github.com/${PSI_REPO_OWNER}/${PSI_REPO_NAME}/releases/download/${tag}"

    # 候选文件名列表 (按优先级)
    local candidates=(
        "psiphon-tunnel-core-${os}-${arch}.tar.gz"
        "psiphon-tunnel-core-${os}-${arch}.tgz"
        "psiphon-tunnel-core-${os}-${arch}.zip"
        "psiphon-tunnel-core-${os}-${arch}"
        "psiphon-tunnel-core-${os}_${arch}.tar.gz"
        "psiphon-tunnel-core_${os}_${arch}.tar.gz"
    )

    local picked=""
    yellow "[*] 正在探测 Psiphon 资产文件..."
    for f in "${candidates[@]}"; do
        url="${base}/${f}"
        if curl -fsIL "$url" >/dev/null 2>&1; then
            picked="$f"
            break
        fi
    done

    [[ -n "$picked" ]] || {
        red "[!] 未在 release ${tag} 找到匹配的 ${os}/${arch} 资产"
        yellow "    已尝试的文件名: ${candidates[*]}"
        rm -rf "$tmpd"
        return 1
    }

    url="${base}/${picked}"
    green "[*] 下载 Psiphon: $picked"
    curl -fsSL "$url" -o "${tmpd}/${picked}" || {
        red "[!] 下载失败: $url"
        rm -rf "$tmpd"
        return 1
    }

    # SHA256 校验 (如果有)
    local sha_url="${url}.sha256"
    if curl -fsIL "$sha_url" >/dev/null 2>&1; then
        curl -fsSL "$sha_url" -o "${tmpd}/${picked}.sha256"
        local expected actual
        expected="$(grep -Eo '[0-9a-fA-F]{64}' "${tmpd}/${picked}.sha256" | head -n1 | tr '[:upper:]' '[:lower:]')"
        if command -v sha256sum >/dev/null 2>&1; then
            actual="$(sha256sum "${tmpd}/${picked}" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
        else
            actual="$(sha256 -q "${tmpd}/${picked}" | tr '[:upper:]' '[:lower:]')"
        fi
        if [[ "$expected" != "$actual" ]]; then
            red "[!] Psiphon SHA256 校验失败"
            yellow "    期望: $expected"
            yellow "    实际: $actual"
            rm -rf "$tmpd"
            return 1
        fi
        green "[+] SHA256 校验通过"
    fi

    # 解包/落地 (兼容 tar.gz、zip、裸二进制)
    if [[ "$picked" == *.tar.gz || "$picked" == *.tgz ]]; then
        tar -xzf "${tmpd}/${picked}" -C "$tmpd"
        local extracted
        extracted="$(find "$tmpd" -maxdepth 2 -type f -name 'psiphon-tunnel-core*' ! -name '*.tar.gz' ! -name '*.sha256' | head -n1)"
        [[ -n "$extracted" ]] || { red "[!] 解压未找到可执行文件"; rm -rf "$tmpd"; return 1; }
        cp -f "$extracted" "$WORKDIR/psiphon-tunnel-core"
    elif [[ "$picked" == *.zip ]]; then
        unzip -o "${tmpd}/${picked}" -d "$tmpd" >/dev/null
        local extracted
        extracted="$(find "$tmpd" -maxdepth 2 -type f -name 'psiphon-tunnel-core*' ! -name '*.zip' ! -name '*.sha256' | head -n1)"
        [[ -n "$extracted" ]] || { red "[!] 解压未找到可执行文件"; rm -rf "$tmpd"; return 1; }
        cp -f "$extracted" "$WORKDIR/psiphon-tunnel-core"
    else
        cp -f "${tmpd}/${picked}" "$WORKDIR/psiphon-tunnel-core"
    fi

    chmod +x "$WORKDIR/psiphon-tunnel-core"
    echo "psiphon-tunnel-core" > "$WORKDIR/psi.txt"
    rm -rf "$tmpd"
    
    # 预载 Psiphon 种子服务器列表 (多镜像源自动 fallback)
    if [[ ! -f "$WORKDIR/server_list_compressed" ]]; then
        yellow "[*] 正在预载 Psiphon 全球种子服务器列表..."
        local s_urls=(
            "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed"
            "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
            "https://ghproxy.net/https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
        )
        for surl in "${s_urls[@]}"; do
            echo -e "${blue}--> 尝试下载种子服务器列表: ${surl}${re}"
            curl -# -fSL --connect-timeout 10 --max-time 60 "$surl" -o "$WORKDIR/server_list_compressed" 2>/dev/null && break
        done
    fi

    green "[+] Psiphon 已安装到 $WORKDIR/psiphon-tunnel-core"
}

# 生成 Psiphon 配置文件
write_psiphon_config() {
    local socks region datadir reg_key
    socks="$(cat "$WORKDIR/psiphon_socks_port.txt" 2>/dev/null)"
    region="$(cat "$WORKDIR/psiphon_region.txt" 2>/dev/null)"
    
    # FreeBSD mac_portacl 限制固定端口 bind，必须用 0 (自动端口)
    if [[ -f "$WORKDIR/ports.txt" ]] || [[ "$(detect_os_slim)" == "freebsd" ]]; then socks="0"; else socks="${socks:-0}"; fi
    region="${region:-US}"
    reg_key="${region^^}"
    
    # AUTO 时写空字符串
    [[ "${region^^}" == "AUTO" ]] && region=""
    
    # 创建分国家独立数据目录 (避免跨国家历史失效节点污染导致死循环)
    datadir="$WORKDIR/psiphon-data/${reg_key:-AUTO}"
    mkdir -p "$datadir" 2>/dev/null

    # 部署种子服务器列表至主数据目录
    if [[ -f "$WORKDIR/server_list_compressed" ]]; then
        cp -f "$WORKDIR/server_list_compressed" "$datadir/server_list_compressed" 2>/dev/null
        cp -f "$WORKDIR/server_list_compressed" "$datadir/remote_server_list" 2>/dev/null
    else
        local s_urls=(
            "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed"
            "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
            "https://ghproxy.net/https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
        )
        for surl in "${s_urls[@]}"; do
            if curl -fsSL --connect-timeout 5 --max-time 15 "$surl" -o "$datadir/server_list_compressed" 2>/dev/null; then
                cp -f "$datadir/server_list_compressed" "$datadir/remote_server_list" 2>/dev/null
                cp -f "$datadir/server_list_compressed" "$WORKDIR/server_list_compressed" 2>/dev/null
                break
            fi
        done
    fi

    cat > "$WORKDIR/psiphon.config" <<EOF
{
  "DataRootDirectory": "${datadir}",
  "EmitDiagnosticNotices": true,
  "EmitDiagnosticNetworkParameters": true,
  "EmitServerAlerts": true,
  
  "LocalSocksProxyPort": ${socks},
  "DisableLocalHTTPProxy": true,
  "LocalHttpProxyPort": 0,
  "EgressRegion": "${region}",
  
  "PropagationChannelId": "FFFFFFFFFFFFFFFF",
  "SponsorId": "FFFFFFFFFFFFFFFF",
  "RemoteServerListDownloadFilename": "remote_server_list",
  "RemoteServerListSignaturePublicKey": "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
  "RemoteServerListUrl": "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed",
  "UseIndistinguishableTLS": true
}
EOF
    green "[+] Psiphon 配置已生成 (SOCKS: 自动端口, 数据目录: $datadir)"
}

# 等待 Psiphon 就绪 (基于 notice 事件及底层系统套接字检测)
psiphon_wait_ready() {
    local log="$WORKDIR/psiphon.log"
    local timeout=${1:-30}
    local is_fast_test=${2:-false}
    local elapsed=0
    
    [[ "$is_fast_test" != "true" ]] && yellow "[*] 等待 Psiphon 就绪 (最多 ${timeout} 秒)..."

    while (( elapsed < timeout )); do
        # 1) 检查底层系统 Socket 监听 (最快最可靠)
        local sys_port
        sys_port="$(detect_psiphon_port_from_system "$WORKDIR/psiphon.pid")"
        if [[ "$sys_port" =~ ^[0-9]+$ ]] && (( sys_port > 0 )); then
            echo "$sys_port" > "$WORKDIR/psiphon_socks_listen.txt"
            [[ "$is_fast_test" != "true" ]] && green "\n[+] Psiphon SOCKS 端口已就绪 (端口: $sys_port)"
            return 0
        fi

        # 2) 检查端口占用 notice
        if tail -n 200 "$log" 2>/dev/null | grep -q '"noticeType":"SocksProxyPortInUse"'; then
            [[ "$is_fast_test" != "true" ]] && red "[!] Psiphon SOCKS 端口被占用"
            return 2
        fi

        # 3) 检查已开始监听 notice (最可靠的就绪信号)
        if tail -n 400 "$log" 2>/dev/null | grep -q '"noticeType":"ListeningSocksProxyPort"'; then
            psiphon_update_listen_ports_from_log
            local actual_port
            actual_port="$(get_psiphon_socks_port)"
            [[ "$is_fast_test" != "true" ]] && green "\n[+] Psiphon SOCKS 已监听 (端口: $actual_port)"
            return 0
        fi

        # 4) 检查 Tunnels notice (已建立隧道)
        if tail -n 400 "$log" 2>/dev/null | grep -q '"noticeType":"Tunnels"'; then
            if tail -n 400 "$log" 2>/dev/null | grep '"noticeType":"Tunnels"' | grep -q '"count":[1-9]'; then
                psiphon_update_listen_ports_from_log
                local actual_port
                actual_port="$(get_psiphon_socks_port)"
                [[ "$is_fast_test" != "true" ]] && green "\n[+] Psiphon 隧道已建立 (SOCKS: $actual_port)"
                return 0
            fi
        fi

        # 5) 检查进程是否还活着
        if ! pgrep -x "psiphon-tunnel-core" >/dev/null 2>&1 && ! pgrep -f "psiphon-tunnel-core" >/dev/null 2>&1; then
            [[ "$is_fast_test" != "true" ]] && red "[!] Psiphon 进程已退出"
            return 1
        fi

        sleep 1
        elapsed=$((elapsed + 1))
        [[ "$is_fast_test" != "true" ]] && printf "\r[*] 等待 Psiphon 就绪... %ds/%ds" "$elapsed" "$timeout"
    done

    # 尝试解析端口
    psiphon_update_listen_ports_from_log
    if [[ "$is_fast_test" == "true" ]]; then
        return 1
    fi
    return 0
}

# 启动 Psiphon (nohup 版本，带 notice 就绪检测)
start_psiphon_userland() {
    local custom_timeout=${1:-30}
    local is_fast_test=${2:-false}
    local bin="$WORKDIR/psiphon-tunnel-core"
    
    # 检查二进制是否存在，不存在则安装
    if [[ ! -x "$bin" ]]; then
        [[ "$is_fast_test" != "true" ]] && yellow "[*] Psiphon 二进制不存在，正在安装..."
        install_psiphon_userland || return 1
    fi
    
    # 清理上一次的运行时端口文件
    : > "$WORKDIR/psiphon_socks_listen.txt" 2>/dev/null || true
    : > "$WORKDIR/psiphon_http_listen.txt" 2>/dev/null || true
    
    write_psiphon_config

    # 先停止旧进程
    stop_psiphon_userland

    # 清空旧日志 (便于检测新 notice)
    > "$WORKDIR/psiphon.log" 2>/dev/null

    [[ "$is_fast_test" != "true" ]] && yellow "[*] 启动 Psiphon (SOCKS: 自动端口 127.0.0.1:0)..."
    cd "$WORKDIR"
    run_detached "$WORKDIR/psiphon.pid" "$WORKDIR/psiphon.log" \
        "$bin" -config "$WORKDIR/psiphon.config"
    
    local pid
    pid="$(cat "$WORKDIR/psiphon.pid" 2>/dev/null || echo 0)"
    
    # 给进程一点启动时间
    sleep 1

    # 检查进程是否启动 (如果秒退，用前台模式抓错误)
    if ! kill -0 "$pid" 2>/dev/null && ! pgrep -f "psiphon-tunnel-core" >/dev/null 2>&1; then
        if [[ "$is_fast_test" != "true" ]]; then
            red "[!] Psiphon 秒退，正在抓取前台错误信息..."
            echo
            yellow "========== 前台错误输出 (最重要) =========="
            timeout 10 "$bin" -config "$WORKDIR/psiphon.config" 2>&1 | head -n 60 || true
            echo
            yellow "========== 日志文件最后 30 行 =========="
            tail -30 "$WORKDIR/psiphon.log" 2>/dev/null || true
            echo "==========================================="
        fi
        return 1
    fi

    # 等待就绪 (基于 notice 检测，并自动解析实际端口)
    psiphon_wait_ready "$custom_timeout" "$is_fast_test"
    local ready_status=$?
    
    if [[ $ready_status -ne 0 ]]; then
        return 1
    fi

    # 显示实际端口
    local actual_port
    actual_port="$(get_psiphon_socks_port)"
    if [[ "$actual_port" != "0" && -n "$actual_port" ]]; then
        [[ "$is_fast_test" != "true" ]] && green "[+] Psiphon 已启动 (SOCKS: 127.0.0.1:${actual_port})"
    else
        [[ "$is_fast_test" != "true" ]] && yellow "[!] Psiphon 已启动，但未能获取实际端口"
    fi
    return 0
}

# 可靠启动 sing-box（使用绝对路径，不依赖当前目录）
start_singbox_safe() {
    local retry_count=${1:-0}
    local max_retries=3
    local SB_BINARY
    SB_BINARY="$(cat "$WORKDIR/sb.txt" 2>/dev/null)"
    
    if [[ -z "$SB_BINARY" || ! -f "$WORKDIR/$SB_BINARY" ]]; then
        red "[!] sing-box 二进制不存在"
        return 1
    fi

    # 自动修补悬挂路由规则与缺失的 outbound
    local warp_ipv6="${WARP_IPV6:-$(cat "$WORKDIR/warp_ipv6.txt" 2>/dev/null || echo "2606:4700:110:8d8d:1845:c39f:2dd5:a03a")}"
    local warp_pk="${WARP_PRIVATE_KEY:-$(cat "$WORKDIR/warp_private_key.txt" 2>/dev/null || echo "52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A=")}"
    local warp_res="${WARP_RESERVED:-$(cat "$WORKDIR/warp_reserved.txt" 2>/dev/null || echo "[215, 69, 233]")}"
    local warp_ep="$(get_warp_endpoint 2>/dev/null || echo "162.159.192.1")"
    local warp_pt="$(cat "$WORKDIR/warp_best_port.txt" 2>/dev/null || echo "2408")"

    python3 - <<PY 2>/dev/null
import json
cfg = r"$WORKDIR/config.json"
try:
    with open(cfg, 'r', encoding='utf-8') as f:
        data = json.load(f)
    obs = data.setdefault('outbounds', [])
    route = data.setdefault('route', {})
    rules = route.setdefault('rules', [])
    tags = {o.get('tag') for o in obs if o.get('tag')}
    
    # 检查是否有规则引用了 warp-out 但 outbounds 缺失该节点
    need_warp = any(r.get('outbound') == 'warp-out' for r in rules) or route.get('final') == 'warp-out'
    if need_warp and 'warp-out' not in tags:
        try: res_arr = json.loads(r'$warp_res')
        except Exception: res_arr = [215, 69, 233]
        obs.append({
            'type': 'wireguard',
            'tag': 'warp-out',
            'server': r'$warp_ep',
            'server_port': int(r'$warp_pt'),
            'local_address': [
                '172.16.0.2/32',
                r'$warp_ipv6' if '/' in r'$warp_ipv6' else f"{r'$warp_ipv6'}/128"
            ],
            'private_key': r'$warp_pk',
            'peer_public_key': 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=',
            'reserved': res_arr,
            'mtu': 1280
        })
        tags.add('warp-out')

    # 清理指向不存在 outbound 的悬挂 rules
    new_rules = [r for r in rules if not r.get('outbound') or r.get('outbound') in tags]
    if len(new_rules) != len(rules) or need_warp:
        route['rules'] = new_rules
        with open(cfg, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
except Exception:
    pass
PY

    # 校验配置
    local out
    out="$(cd "$WORKDIR" && "./$SB_BINARY" check -c "$WORKDIR/config.json" 2>&1)" || {
        red "[!] sing-box 配置校验失败："
        echo "$out" | head -30
        return 1
    }

    # 停止旧进程（用绝对路径匹配）
    pkill -f "$WORKDIR/$SB_BINARY" >/dev/null 2>&1 || true
    pkill -x "$SB_BINARY" >/dev/null 2>&1 || true
    sleep 1

    # 清空旧日志，确保端口冲突检测的日志只反映本次启动
    > "$WORKDIR/singbox.log" 2>/dev/null || true

    # 启动（使用绝对路径）
    cd "$WORKDIR"
    run_detached "$WORKDIR/singbox.pid" "$WORKDIR/singbox.log" \
        "$WORKDIR/$SB_BINARY" run -c "$WORKDIR/config.json"
    sleep 2

    if pgrep -f "$WORKDIR/$SB_BINARY" >/dev/null 2>&1 || pgrep -x "$SB_BINARY" >/dev/null 2>&1; then
        green "[+] sing-box 重启成功"
        return 0
    else
        red "[!] sing-box 启动失败，查看日志：$WORKDIR/singbox.log"
        tail -20 "$WORKDIR/singbox.log" 2>/dev/null

        # 自愈1: 检测到 mac_portacl 端口未注册 (operation not permitted) 时，
        # 自动把 socks-loopback 端口改为 devil 已注册端口并重试
        if grep -qE "operation not permitted" "$WORKDIR/singbox.log" 2>/dev/null; then
            if [ "$retry_count" -lt "$max_retries" ]; then
                yellow "[!] 检测到端口未授权绑定 (mac_portacl / operation not permitted)，正在改用已注册端口重试 (尝试 $((retry_count + 1))/$max_retries)..."
                local lp
                lp=$(get_free_loopback_port)
                if python3 -c "
import json,sys
try:
    cfg=r'$WORKDIR/config.json'
    d=json.load(open(cfg))
    for ib in d.get('inbounds',[]):
        if ib.get('tag')=='socks-loopback':
            ib['listen_port']=$lp
    with open(cfg,'w') as f: json.dump(d,f,ensure_ascii=False,indent=2)
    print('[+] socks-loopback 端口已改为 $lp')
except Exception as e:
    print(f'[!] 修正失败: {e}'); sys.exit(1)
"; then
                    start_singbox_safe $((retry_count + 1))
                    return $?
                fi
                yellow "[!] loopback 端口修正未完成，启动失败 (已尝试 $((retry_count + 1)) 次)"
            fi
        # 自愈2: 检测到端口冲突 (address already in use) 时，
        # 自动调用 auto_repair_conflicting_ports 修复端口并重试 (最多 max_retries 次)
        elif grep -qE "address already in use" "$WORKDIR/singbox.log" 2>/dev/null; then
            if [ "$retry_count" -lt "$max_retries" ]; then
                yellow "[!] 检测到端口冲突 (address already in use)，正在自动修复端口并重试 (尝试 $((retry_count + 1))/$max_retries)..."
                if auto_repair_conflicting_ports; then
                    start_singbox_safe $((retry_count + 1))
                    return $?
                fi
                yellow "[!] 端口修复未完成，启动失败 (已尝试 $((retry_count + 1)) 次)"
            fi
        fi
        return 1
    fi
}

# 同步 Psiphon 端口到 sing-box 配置 (切换国家后必须调用)
sync_psiphon_port_to_singbox() {
    # 只在 Psiphon 已启用时才同步
    local psi_enabled
    psi_enabled="$(cat "$WORKDIR/psiphon_enabled.txt" 2>/dev/null || echo "false")"
    [[ "$psi_enabled" == "true" ]] || {
        # Psiphon 未启用，无需同步
        return 0
    }
    
    local port cfg psiphon_tag="psiphon-out"
    port="$(get_psiphon_socks_port)"
    cfg="$WORKDIR/config.json"
    
    if [[ "$port" == "0" || -z "$port" ]]; then
        red "[!] 无法获取 Psiphon 实际端口，跳过同步"
        return 1
    fi
    
    if [[ ! -f "$cfg" ]]; then
        # 配置文件不存在，可能尚未安装
        return 0
    fi
    
    yellow "[*] 同步 Psiphon 端口到 sing-box (端口: $port)..."

    python3 - <<PY
import json
import sys

cfg_path = r"$cfg"
port = int(r"$port")
psiphon_tag = r"$psiphon_tag"

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"[!] 读取配置失败: {e}")
    sys.exit(1)

outbounds = data.get("outbounds", [])
found = False

for o in outbounds:
    if o.get("tag") == psiphon_tag:
        old_port = o.get("server_port", 0)
        if old_port == port:
            print(f"[*] 端口未变化 ({port})，跳过")
            sys.exit(0)
        o["server"] = "127.0.0.1"
        o["server_port"] = port
        found = True
        break

if not found:
    print("[*] sing-box 配置中无 Psiphon 出站，跳过同步")
    sys.exit(0)

try:
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"[+] sing-box 已更新 Psiphon 端口: {port}")
except Exception as e:
    print(f"[!] 写入配置失败: {e}")
    sys.exit(1)
PY

    if [ $? -ne 0 ]; then
        red "[!] 同步端口失败"
        return 1
    fi
    
    # 重启 sing-box 使配置生效
    start_singbox_safe || return 1
    return 0
}

# 同步所有 Psiphon 端口到 sing-box 配置 (全局 + 各出口实例)
sync_all_psiphon_ports() {
    local cfg="$WORKDIR/config.json"
    [[ -f "$cfg" ]] || return 0

    # 收集所有 Psiphon outbound tag → 实际端口 的映射
    local tag_port_pairs=""

    # 1. 全局 psiphon-out
    local global_port
    global_port="$(get_psiphon_socks_port)"
    if [[ "$global_port" =~ ^[0-9]+$ ]] && (( global_port > 0 )); then
        tag_port_pairs="psiphon-out:$global_port"
    fi

    # 2. 各出口实例 psiphon-<cc>
    if [[ -f "$WORKDIR/egress_node_groups.txt" ]]; then
        local groups
        groups="$(cat "$WORKDIR/egress_node_groups.txt" 2>/dev/null)"
        IFS=',' read -ra cc_arr <<< "$groups"
        for cc in "${cc_arr[@]}"; do
            cc="$(echo "$cc" | tr '[:upper:]' '[:lower:]' | xargs)"
            [[ -z "$cc" ]] && continue
            local inst_port
            inst_port="$(get_instance_socks_port "${cc^^}")"
            if [[ "$inst_port" =~ ^[0-9]+$ ]] && (( inst_port > 0 )); then
                local tag="psiphon-${cc}"
                if [[ -n "$tag_port_pairs" ]]; then
                    tag_port_pairs="$tag_port_pairs,$tag:$inst_port"
                else
                    tag_port_pairs="$tag:$inst_port"
                fi
            fi
        done
    fi

    [[ -z "$tag_port_pairs" ]] && return 0

    yellow "[*] 同步 Psiphon 端口到 sing-box 配置..."

    python3 - <<PY
import json, sys

cfg_path = r"$cfg"
pairs_str = r"$tag_port_pairs"  # tag1:port1,tag2:port2

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"[!] 读取配置失败: {e}")
    sys.exit(1)

pairs = {}
for p in pairs_str.split(","):
    if ":" in p:
        tag, port = p.rsplit(":", 1)
        pairs[tag.strip()] = int(port.strip())

outbounds = data.get("outbounds", [])
updated = 0
for o in outbounds:
    tag = o.get("tag", "")
    if tag in pairs:
        old_port = o.get("server_port", 0)
        new_port = pairs[tag]
        if old_port != new_port:
            o["server"] = "127.0.0.1"
            o["server_port"] = new_port
            print(f"  {tag}: {old_port} -> {new_port}")
            updated += 1
        else:
            print(f"  {tag}: {old_port} (未变化)")

if updated > 0:
    try:
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print(f"[+] 已更新 {updated} 个 Psiphon 出站端口")
    except Exception as e:
        print(f"[!] 写入配置失败: {e}")
        sys.exit(1)
else:
    print("[*] 所有端口无变化")
PY

    # 重启 sing-box 使最新端口生效
    yellow "[*] 正在重启 sing-box..."
    if start_singbox_safe; then
        green "[+] sing-box 已重启，新端口已生效"
    else
        # start_singbox_safe 可能因为配置校验失败而退出，直接强制重启
        local sb_binary
        sb_binary="$(cat "$WORKDIR/sb.txt" 2>/dev/null)"
        if [[ -n "$sb_binary" && -f "$WORKDIR/$sb_binary" ]]; then
            pkill -f "$WORKDIR/$sb_binary" >/dev/null 2>&1 || true
            pkill -x "$sb_binary" >/dev/null 2>&1 || true
            sleep 1
            cd "$WORKDIR"
            run_detached "$WORKDIR/singbox.pid" "$WORKDIR/singbox.log" \
                "$WORKDIR/$sb_binary" run -c "$WORKDIR/config.json"
            sleep 2
            if pgrep -x "$sb_binary" >/dev/null 2>&1; then
                green "[+] sing-box 重启成功"
            else
                red "[!] sing-box 重启失败，请检查日志: $WORKDIR/singbox.log"
            fi
        fi
    fi
}

# 强力清空当前用户所有 psiphon-tunnel 僵尸孤儿进程 (释放 FreeBSD maxproc 限制)
kill_all_user_psiphon_processes() {
    local me
    me="$(whoami 2>/dev/null || echo "$USERNAME")"
    
    # 彻底 kill 属于当前用户的所有 psiphon 僵尸进程
    pkill -9 -u "$me" -f "psiphon-tunnel-core" >/dev/null 2>&1 || true
    pkill -9 -u "$me" -x "psiphon-tunnel-core" >/dev/null 2>&1 || true
    pkill -9 -u "$me" -f "psiphon-tunnel" >/dev/null 2>&1 || true
}

# 停止 Psiphon 主进程
stop_psiphon_userland() {
    local pid_file="$WORKDIR/psiphon.pid"
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            sleep 1
        fi
        rm -f "$pid_file" 2>/dev/null
    fi
    
    # 强力清理属于主目录 psiphon.config 的孤儿进程
    kill_all_user_psiphon_processes
    sleep 1
}

# 应用 Psiphon 出站模式 (使用 Python 稳定修改 JSON)
apply_egress_mode_psiphon() {
    local mode="$1"   # all / google / google_warp
    local cfg="$WORKDIR/config.json"

    # 先启动 psiphon，再获取实际端口
    start_psiphon_userland || return 1
    
    local socks_port
    socks_port="$(get_psiphon_socks_port)"
    if [[ "$socks_port" == "0" || -z "$socks_port" ]]; then
        red "[!] 无法获取 Psiphon 实际端口"
        return 1
    fi

    # 获取 WARP 变量以供 google_warp 模式使用
    local warp_endpoint
    warp_endpoint=$(get_warp_endpoint)
    local warp_port
    warp_port=$(cat "$WORKDIR/warp_best_port.txt" 2>/dev/null || echo "2408")
    local warp_ipv6
    warp_ipv6=$(cat "$WORKDIR/warp_ipv6.txt" 2>/dev/null || echo "2606:4700:110:8d8d:1845:c39f:2dd5:a03a")
    local warp_private_key
    warp_private_key=$(cat "$WORKDIR/warp_private_key.txt" 2>/dev/null || echo "52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A=")
    local warp_reserved
    warp_reserved=$(cat "$WORKDIR/warp_reserved.txt" 2>/dev/null || echo "[215, 69, 233]")

    # 备份配置
    cp "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null

    local loopback_port
    loopback_port=$(get_free_loopback_port)

    yellow "[*] 更新 sing-box 配置 (添加 Psiphon SOCKS 出站)..."

    python3 - <<PY
import json
import sys

cfg_path = r"$cfg"
mode = r"$mode"
socks_port = int(r"$socks_port")
warp_endpoint = r"$warp_endpoint"
warp_port = int(r"$warp_port")
warp_ipv6 = r"$warp_ipv6"
warp_private_key = r"$warp_private_key"
warp_reserved_str = r"$warp_reserved"
loopback_port = int(r"$loopback_port")

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"[!] 读取配置失败: {e}")
    sys.exit(1)

outbounds = data.setdefault("outbounds", [])
route = data.setdefault("route", {})
rules = route.setdefault("rules", [])

def first_tag_by_type(t, fallback):
    for o in outbounds:
        if o.get("type") == t and o.get("tag"):
            return o["tag"]
    return fallback

direct_tag = first_tag_by_type("direct", "direct")
psiphon_tag = "psiphon-out"
warp_tag = "warp-out"

# upsert psiphon outbound (SOCKS5)
found = False
for o in outbounds:
    if o.get("tag") == psiphon_tag:
        o.clear()
        o.update({
            "type": "socks",
            "tag": psiphon_tag,
            "server": "127.0.0.1",
            "server_port": socks_port,
            "version": "5",
            "network": "tcp"
        })
        found = True
        break

if not found:
    outbounds.append({
        "type": "socks",
        "tag": psiphon_tag,
        "server": "127.0.0.1",
        "server_port": socks_port,
        "version": "5",
        "network": "tcp"
    })

# 移除旧的 psiphon 规则 (幂等)
def is_our_rule(r):
    return r.get("outbound") == psiphon_tag and ("domain_suffix" in r or "rule_set" in r)

rules[:] = [r for r in rules if not is_our_rule(r)]

if mode == "all":
    route["final"] = psiphon_tag
    outbounds[:] = [o for o in outbounds if o.get("tag") != warp_tag]
elif mode == "google":
    # 仅 Google/YouTube/OpenAI/Netflix 走 Psiphon 分流，普通流量走直连
    rules.insert(0, {
        "domain_suffix": [
            "google.com", "google.co.jp", "google.com.hk",
            "googleapis.com", "gstatic.com", "ggpht.com",
            "youtube.com", "ytimg.com", "youtu.be",
            "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com",
            "netflix.com", "nflxvideo.net", "nflxso.net"
        ],
        "outbound": psiphon_tag
    })
    route["final"] = direct_tag
    outbounds[:] = [o for o in outbounds if o.get("tag") != warp_tag]
elif mode == "google_warp":
    # 混合模式：赛风出口节点走赛风出站（由 sync_egress_group inbound 路由控制），普通主节点全部走 WARP，各自独立出站，无域名共同分流
    if "endpoints" in data:
        del data["endpoints"]

    try:
        warp_reserved = json.loads(warp_reserved_str)
    except Exception:
        warp_reserved = [215, 69, 233]
        
    warp_found = False
    for o in outbounds:
        if o.get("tag") == warp_tag:
            o.clear()
            o.update({
                "type": "wireguard",
                "tag": warp_tag,
                "server": warp_endpoint,
                "server_port": warp_port,
                "local_address": [
                    "172.16.0.2/32",
                    warp_ipv6 if "/" in warp_ipv6 else f"{warp_ipv6}/128"
                ],
                "private_key": warp_private_key,
                "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                "reserved": warp_reserved,
                "mtu": 1280
            })
            warp_found = True
            break
            
    if not warp_found:
        outbounds.append({
            "type": "wireguard",
            "tag": warp_tag,
            "server": warp_endpoint,
            "server_port": warp_port,
            "local_address": [
                "172.16.0.2/32",
                warp_ipv6 if "/" in warp_ipv6 else f"{warp_ipv6}/128"
            ],
            "private_key": warp_private_key,
            "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
            "reserved": warp_reserved,
            "mtu": 1280
        })
    route["final"] = warp_tag
else:
    print(f"[!] 未知模式: {mode}")
    sys.exit(1)

# 动态处理 socks-loopback
warp_tags = ["warp-out", "wireguard-out"]
active_warp_tag = None
for o in outbounds:
    if o.get("tag") in warp_tags:
        active_warp_tag = o["tag"]
        break

inbound_tag = "socks-loopback"

# 移除旧的 loopback 路由规则
rules[:] = [r for r in rules if not (r.get("inbound") and inbound_tag in r["inbound"])]

if active_warp_tag:
    # 确保 inbounds 列表存在
    inbounds = data.setdefault("inbounds", [])
    inbound_found = False
    for ib in inbounds:
        if ib.get("tag") == inbound_tag:
            ib.clear()
            ib.update({
                "tag": inbound_tag,
                "type": "socks",
                "listen": "127.0.0.1",
                "listen_port": loopback_port
            })
            inbound_found = True
            break
    if not inbound_found:
        inbounds.append({
            "tag": inbound_tag,
            "type": "socks",
            "listen": "127.0.0.1",
            "listen_port": loopback_port
        })
    # 在 rules 开头插入强制分流规则
    rules.insert(0, {
        "inbound": [inbound_tag],
        "outbound": active_warp_tag
    })
else:
    # 移除 inbound
    if "inbounds" in data:
        data["inbounds"] = [ib for ib in data["inbounds"] if ib.get("tag") != inbound_tag]

try:
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("[+] sing-box 配置已更新 (Psiphon 出站)")
except Exception as e:
    print(f"[!] 写入配置失败: {e}")
    sys.exit(1)
PY

    if [ $? -ne 0 ]; then
        red "[!] 配置更新失败"
        return 1
    fi

    echo "true" > "$WORKDIR/psiphon_enabled.txt"
    green "[+] Psiphon 出站配置完成"
    
    # 使用可靠的重启函数
    start_singbox_safe || return 1
    return 0
}

# 关闭 Psiphon 出站 (恢复直连或 WARP)
disable_psiphon_egress() {
    local cfg="$WORKDIR/config.json"
    
    stop_psiphon_userland
    
    # 备份配置
    cp "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null

    yellow "[*] 移除 Psiphon 出站配置..."

    local loopback_port
    loopback_port=$(get_free_loopback_port)
    python3 - <<PY
import json
import sys

cfg_path = r"$cfg"

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"[!] 读取配置失败: {e}")
    sys.exit(1)

outbounds = data.get("outbounds", [])
route = data.get("route", {})
rules = route.get("rules", [])

psiphon_tag = "psiphon-out"
warp_tag = "warp-out"

# 移除 psiphon outbound
outbounds[:] = [o for o in outbounds if o.get("tag") != psiphon_tag]

# 移除 psiphon 相关规则
rules[:] = [r for r in rules if r.get("outbound") != psiphon_tag]

# 检查 WARP 是否启用，如果不启用才移除 warp-out 痕迹
warp_enabled = "false"
try:
    with open(r"$WORKDIR/warp_enabled.txt", "r") as wf:
        warp_enabled = wf.read().strip()
except Exception:
    pass

if warp_enabled != "true":
    outbounds[:] = [o for o in outbounds if o.get("tag") != warp_tag]
    if "endpoints" in data:
        del data["endpoints"]

def first_tag_by_type(t, fallback):
    for o in outbounds:
        if o.get("type") == t and o.get("tag"):
            return o["tag"]
    return fallback

direct_tag = first_tag_by_type("direct", "direct")
if warp_enabled == "true":
    route["final"] = warp_tag
else:
    route["final"] = direct_tag

# 动态处理 socks-loopback
warp_tags = ["warp-out", "wireguard-out"]
active_warp_tag = None
for o in outbounds:
    if o.get("tag") in warp_tags:
        active_warp_tag = o["tag"]
        break

inbound_tag = "socks-loopback"
loopback_port = int(r"$loopback_port")

# 移除旧的 loopback 路由规则
rules[:] = [r for r in rules if not (r.get("inbound") and inbound_tag in r["inbound"])]

if active_warp_tag:
    # 确保 inbounds 列表存在
    inbounds = data.setdefault("inbounds", [])
    inbound_found = False
    for ib in inbounds:
        if ib.get("tag") == inbound_tag:
            ib.clear()
            ib.update({
                "tag": inbound_tag,
                "type": "socks",
                "listen": "127.0.0.1",
                "listen_port": loopback_port
            })
            inbound_found = True
            break
    if not inbound_found:
        inbounds.append({
            "tag": inbound_tag,
            "type": "socks",
            "listen": "127.0.0.1",
            "listen_port": loopback_port
        })
    # 在 rules 开头插入强制分流规则
    rules.insert(0, {
        "inbound": [inbound_tag],
        "outbound": active_warp_tag
    })
else:
    # 移除 inbound
    if "inbounds" in data:
        data["inbounds"] = [ib for ib in data["inbounds"] if ib.get("tag") != inbound_tag]

try:
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("[+] Psiphon 出站已移除，恢复直连")
except Exception as e:
    print(f"[!] 写入配置失败: {e}")
    sys.exit(1)
PY

    if [ $? -ne 0 ]; then
        red "[!] 配置更新失败"
        return 1
    fi

    echo "false" > "$WORKDIR/psiphon_enabled.txt"
    green "[+] Psiphon 已关闭"
    
    # 使用可靠的重启函数
    start_singbox_safe || return 1
    return 0
}

# ==================== Psiphon 国家管理 (psictl 等价功能) ====================

# Psiphon 官方真实支持的出口国家码列表 (共 28 国 + AUTO)
PSI_ALL_CC=(
    US JP SG HK KR TW GB DE CA NL FR IN AU
    CH SE IT ES PL AT BE DK NO RO CZ HU BG IE FI
    AUTO
)

# 国家码到中文名映射
get_country_name() {
    local cc="${1^^}"
    case "$cc" in
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
        AUTO) echo "自动优选 (Auto)" ;;
        *) echo "$cc" ;;
    esac
}

is_supported_psiphon_cc() {
    local cc="${1^^}"
    [[ "$cc" == "AUTO" ]] && return 0
    local item
    for item in "${PSI_ALL_CC[@]}"; do
        [[ "$item" == "$cc" ]] && return 0
    done
    return 1
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

# 获取可绑定的本地回环端口 (FreeBSD mac_portacl: 非 root 只能绑定 devil 已注册端口)
# 策略: 优先复用 config 中已有 socks-loopback 端口; 否则从 devil 已注册 tcp 端口中挑空闲的
get_free_loopback_port() {
    local registered
    registered=$(devil port list 2>/dev/null | awk 'NR>2 && $2=="tcp" {print $1}')
    local existing=""
    # 1. 若 config.json 已有 socks-loopback, 复用其端口 (前提: 该端口已在 devil 注册)
    if [ -f "$WORKDIR/config.json" ]; then
        existing=$(python3 -c "import json;d=json.load(open('$WORKDIR/config.json'));print([ib.get('listen_port') for ib in d.get('inbounds',[]) if ib.get('tag')=='socks-loopback'][0])" 2>/dev/null || echo "")
    fi
    if [ -n "$existing" ]; then
        if echo "$registered" | grep -qx "$existing"; then
            echo "$existing"
            return 0
        fi
    fi
    # 2. 从 devil 已注册 tcp 端口挑一个当前空闲的
    local p
    for p in $registered; do
        if check_port_available_on_ip "$p" "tcp" "127.0.0.1" >/dev/null 2>&1; then
            echo "$p"
            return 0
        fi
    done
    # 3. 全部被占用: 回退 31092 (大概率绑定失败, 调用方应跳过 loopback 注入)
    echo "31092"
    return 1
}

# WARP 出口 IP 检测 - 智能坚固版
warp_egress_test() {
    cd "$WORKDIR" 2>/dev/null || return 1
    
    # 检查 sing-box 是否在运行 (改进 PID 与 pgrep 兼容判定)
    local sb_binary
    sb_binary=$(cat "$WORKDIR/sb.txt" 2>/dev/null)
    local is_sb_running=false
    if [[ -f "$WORKDIR/singbox.pid" ]]; then
        local sb_pid=$(cat "$WORKDIR/singbox.pid" 2>/dev/null)
        if [[ -n "$sb_pid" ]] && kill -0 "$sb_pid" 2>/dev/null; then
            is_sb_running=true
        fi
    fi
    if [[ "$is_sb_running" == "false" ]]; then
        if pgrep -f "$sb_binary" >/dev/null 2>&1 || pgrep -x "sing-box" >/dev/null 2>&1; then
            is_sb_running=true
        fi
    fi
    if [[ "$is_sb_running" == "false" ]]; then
        yellow "[*] sing-box 进程未运行，正在尝试自动拉起..."
        start_singbox_safe || { red "[!] sing-box 启动失败，无法检测 WARP"; return 1; }
    fi

    # 动态从 config.json 获取 socks-loopback 端口
    local socks=""
    if [ -f "$WORKDIR/config.json" ]; then
        socks=$(python3 -c "import json; data=json.load(open('$WORKDIR/config.json')); print([ib.get('listen_port') for ib in data.get('inbounds',[]) if ib.get('tag')=='socks-loopback'][0])" 2>/dev/null || echo "")
    fi

    # 如果配置中不存在 socks-loopback，自动补充
    if [[ -z "$socks" || "$socks" == "None" || "$socks" == "0" ]]; then
        socks=$(get_free_loopback_port)
        yellow "[*] 配置中未检测到 socks-loopback 节点，正在自动补充 (端口: $socks)..."
        python3 -c "
import json
cfg = r'$WORKDIR/config.json'
try:
    with open(cfg, 'r') as f: data = json.load(f)
    ibs = data.setdefault('inbounds', [])
    rules = data.setdefault('route', {}).setdefault('rules', [])
    if not any(ib.get('tag') == 'socks-loopback' for ib in ibs):
        ibs.append({'tag': 'socks-loopback', 'type': 'socks', 'listen': '127.0.0.1', 'listen_port': $socks})
    if not any(r.get('inbound') == ['socks-loopback'] for r in rules):
        rules.insert(0, {'inbound': ['socks-loopback'], 'outbound': 'warp-out'})
    with open(cfg, 'w') as f: json.dump(data, f, ensure_ascii=False, indent=2)
except Exception: pass
"
        start_singbox_safe
    fi

    yellow "[*] 正在检测 WARP 出口 IP (SOCKS5 端口: $socks)..."

    local json=""
    # 尝试 ipinfo.io (可能限流/403)
    json="$(curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:${socks}" https://ipinfo.io/json 2>/dev/null)" || true
    
    # fallback 到 ip-api.com (免费无 key，但只有 HTTP)
    if [[ -z "$json" ]]; then
        yellow "[*] ipinfo.io 无响应，尝试 ip-api.com..."
        json="$(curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:${socks}" http://ip-api.com/json 2>/dev/null)" || true
    fi
    
    # fallback 到 ifconfig.me (只返回 IP)
    if [[ -z "$json" ]]; then
        yellow "[*] ip-api.com 无响应，尝试 ifconfig.me..."
        local raw_ip
        raw_ip="$(curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:${socks}" https://ifconfig.me 2>/dev/null)" || true
        if [[ -n "$raw_ip" ]]; then
            green "  IP: $raw_ip"
            yellow "  (其他信息无法获取，但 WARP 环回通道正常)"
            return 0
        fi
    fi

    if [[ -z "$json" ]]; then
        yellow "[!] WARP 出口 IP 检测未成功"
        yellow "    这不一定表示 WARP 未工作，可能是检测接口被墙/限流"
        yellow "    建议稍后重试，或手动测试: curl --socks5-hostname 127.0.0.1:${socks} https://ipinfo.io/ip"
        return 1
    fi

    # 解析 JSON - 使用 python3 -c 代替 heredoc
    python3 -c '
import json, sys
try:
    j = json.load(sys.stdin)
    ip = j.get("ip") or j.get("query") or ""
    country = j.get("country") or j.get("countryCode") or ""
    city = j.get("city") or ""
    region = j.get("region") or j.get("regionName") or ""
    org = j.get("org") or j.get("isp") or ""
    print(f"  IP:      {ip}")
    print(f"  国家:    {country}")
    print(f"  城市:    {city}")
    print(f"  地区:    {region}")
    print(f"  运营商:  {org}")
except Exception as e:
    print(f"[!] 解析失败: {e}")
    sys.exit(1)
' <<<"$json"
    
    return 0
}

# 出口 IP 检测 (带 1~10s 动态轮询平滑握手探测)
psiphon_egress_test() {
    local socks
    socks="$(get_psiphon_socks_port)"
    
    if [[ "$socks" == "0" || -z "$socks" ]]; then
        red "[!] 未获取到 Psiphon 实际 Socks5 端口"
        return 1
    fi

    # 检查 Psiphon 是否在运行
    local is_running=false
    if [[ -f "$WORKDIR/psiphon.pid" ]]; then
        local psi_pid=$(cat "$WORKDIR/psiphon.pid" 2>/dev/null)
        if [[ -n "$psi_pid" ]] && kill -0 "$psi_pid" 2>/dev/null; then
            is_running=true
        fi
    fi
    if [[ "$is_running" == "false" ]]; then
        if pgrep -f "psiphon-tunnel-core" >/dev/null 2>&1 || pgrep -x "psiphon-tunnel-core" >/dev/null 2>&1; then
            is_running=true
        elif [[ -n "$(detect_psiphon_port_from_system "$WORKDIR/psiphon.pid")" ]]; then
            is_running=true
        fi
    fi
    if [[ "$is_running" == "false" ]]; then
        red "[!] Psiphon 主服务进程未运行"
        return 1
    fi

    local out_ip=""
    local max_wait=10
    local elapsed=0

    for ((i=1; i<=max_wait; i++)); do
        printf "\r[*] 正在建立加密隧道并探测出口 IP (%ds/%ds)..." "$i" "$max_wait"
        local res=""
        res=$(timeout 3 curl -sx "socks5h://127.0.0.1:${socks}" -s4 --connect-timeout 2 -m 2 "http://api.ipify.org" 2>/dev/null | tr -d ' \r\n')
        [[ -z "$res" || ! "$res" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && res=$(timeout 3 curl -sx "socks5h://127.0.0.1:${socks}" -s4 --connect-timeout 2 -m 2 "http://ipv4.icanhazip.com" 2>/dev/null | tr -d ' \r\n')
        [[ -z "$res" || ! "$res" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && res=$(timeout 3 curl -sx "socks5h://127.0.0.1:${socks}" -s4 --connect-timeout 2 -m 2 "https://api.ip.sb/ip" 2>/dev/null | tr -d ' \r\n')

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
        local ip_region=$(echo "$ip_info" | jq -r '.regionName // empty' 2>/dev/null)
        local ip_city=$(echo "$ip_info" | jq -r '.city // empty' 2>/dev/null)
        local ip_isp=$(echo "$ip_info" | jq -r '.isp // empty' 2>/dev/null)
        
        green "============================================================"
        green "  [✓] Psiphon 赛风出口网络状态正常！(耗时约 ${elapsed}s)"
        green "============================================================"
        blue   "  出口公网 IP : ${out_ip}"
        purple "  地理位置归属: ${ip_country} ${ip_region} ${ip_city}"
        purple "  网络运营商  : ${ip_isp:-未知}"
        green "============================================================"
        return 0
    else
        yellow "============================================================"
        yellow "  [!] 检测超时：Psiphon 远端加密隧道握手耗时较长或目标地区无可用节点。"
        yellow "      提示: 部分地区 (如 HK 香港 / TW 台湾 / KR 韩国) 官方服务器池常年无节点。"
        yellow "      建议切换到 JP (日本)、US (美国)、SG (新加坡)、DE (德国) 等热门出口。"
        yellow "============================================================"
        return 1
    fi
}

# 设置出口国家
psiphon_set_region() {
    local cc="${1:-AUTO}"
    [[ -z "$cc" ]] && cc="AUTO"
    cc="${cc^^}"
    if ! is_supported_psiphon_cc "$cc"; then
        red "[!] Psiphon 不支持国家码: $cc"
        show_supported_psiphon_codes
        return 1
    fi
    
    local name=$(get_country_name "$cc")
    yellow "[*] 切换 Psiphon 出口国家: $cc ($name)..."
    
    echo "$cc" > "$WORKDIR/psiphon_region.txt"
    
    # 重启 Psiphon
    start_psiphon_userland
    
    if [ $? -eq 0 ]; then
        green "[+] 已切换到 $cc ($name)"
        
        # 关键修复：同步新端口到 sing-box 配置并重启
        # Psiphon 使用随机端口，切换国家后端口会变化
        sync_psiphon_port_to_singbox || {
            yellow "[!] 端口同步失败，节点可能无法正常使用"
        }
        
        # 等待连接建立
        sleep 2
        psiphon_egress_test || true
    else
        red "[!] 切换失败"
        return 1
    fi
}

# 国家可用性快速检测 (带极速超时与原出口自动恢复)
psiphon_country_test() {
    local list=("$@")
    [[ ${#list[@]} -ge 1 ]] || { red "用法: psiphon_country_test US JP SG ..."; return 1; }

    # 记录当前原本的出口国家，测试结束后自动恢复
    local orig_cc
    orig_cc="$(cat "$WORKDIR/psiphon_region.txt" 2>/dev/null || echo "GB")"
    [[ -z "$orig_cc" ]] && orig_cc="GB"

    local ok=() fail=() mismatch=()
    local total=${#list[@]}
    local current=1

    for cc in "${list[@]}"; do
        cc="${cc^^}"
        if ! is_supported_psiphon_cc "$cc" || [[ "$cc" == "AUTO" ]]; then
            red "[$current/$total] ==> 跳过 $cc (Psiphon 不支持或不能用于指定国家检测)"
            fail+=("$cc")
            ((current++))
            continue
        fi
        local name=$(get_country_name "$cc")
        yellow "[$current/$total] ==> 正在测试 $cc ($name)..."
        
        # 切换到测试国家配置并以极速模式启动 (最多等待 6 秒握手)
        echo "$cc" > "$WORKDIR/psiphon_region.txt"
        if ! start_psiphon_userland 6 true >/dev/null 2>&1; then
            red "  [-] FAIL (握手超时或无可用节点)"
            fail+=("$cc")
            ((current++))
            continue
        fi
        
        # 获取实际端口
        local socks
        socks="$(get_psiphon_socks_port)"
        if [[ "$socks" == "0" || -z "$socks" ]]; then
            red "  [-] FAIL (无法获取 SOCKS 端口)"
            fail+=("$cc")
            ((current++))
            continue
        fi

        # 查出口 country (单次 4 秒超短超时)
        local json got
        json="$(curl -fsS --max-time 4 --socks5-hostname "127.0.0.1:${socks}" https://ipinfo.io/json 2>/dev/null || true)"
        if [[ -z "$json" ]]; then
            json="$(curl -fsS --max-time 4 --socks5-hostname "127.0.0.1:${socks}" http://ip-api.com/json 2>/dev/null || true)"
        fi

        if [[ -z "$json" ]]; then
            red "  [-] FAIL (出口连接超时)"
            fail+=("$cc")
            ((current++))
            continue
        fi

        got="$(python3 - "$json" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    j = json.loads(raw)
    c = j.get("country") or j.get("countryCode") or ""
    print(c.upper())
except:
    print("")
PY
)"

        if [[ -z "$got" ]]; then
            yellow "  [~] MISMATCH (无 country 字段)"
            mismatch+=("$cc")
        elif [[ "$got" == "$cc" ]]; then
            green "  [+] OK (出口确认: $got)"
            ok+=("$cc")
        else
            yellow "  [~] MISMATCH (期望=$cc 实际出口=$got)"
            mismatch+=("$cc")
        fi
        ((current++))
    done

    echo
    blue "========== 测试结果统计 =========="
    green "可用国家 (OK):       ${ok[*]:-无} (共 ${#ok[@]} 个)"
    red   "不可用国家 (FAIL):   ${fail[*]:-无} (共 ${#fail[@]} 个)"
    yellow "出口不符 (MISMATCH): ${mismatch[*]:-无}"
    echo "=================================="
    
    # 保存 OK 列表供智能切换使用
    printf '%s\n' "${ok[@]}" > "$WORKDIR/psiphon_ok_countries.txt" 2>/dev/null

    # 自动恢复测试前的出口国家，并重启服务
    echo
    yellow "[*] 测试完毕，正在自动恢复原出口国家 ($orig_cc)..."
    echo "$orig_cc" > "$WORKDIR/psiphon_region.txt"
    start_psiphon_userland >/dev/null 2>&1
    sync_psiphon_port_to_singbox >/dev/null 2>&1 || true
    green "[+] 原出口国家 ($orig_cc) 已恢复正常运行！"
}

# 测试所有支持国家
psiphon_country_test_all() {
    yellow "[*] 开始测试所有支持国家 (共 ${#PSI_ALL_CC[@]} 个)..."
    yellow "[*] 这可能需要几分钟，请耐心等待..."
    echo
    psiphon_country_test "${PSI_ALL_CC[@]}"
}

# 智能切换出口国家
psiphon_smart_country() {
    echo
    green "==== Psiphon 智能切换出口国家 ===="
    echo
    
    # 检查是否有缓存的 OK 列表
    local ok_file="$WORKDIR/psiphon_ok_countries.txt"
    local ok_arr=()
    
    if [[ -f "$ok_file" ]] && [[ -s "$ok_file" ]]; then
        mapfile -t ok_arr < "$ok_file"
        if [[ ${#ok_arr[@]} -gt 0 ]]; then
            echo
            yellow "检测到上次测试结果 (${#ok_arr[@]} 个可用国家)"
            yellow "选项:"
            yellow "  1. 使用上次结果"
            yellow "  2. 重新测试所有支持国家"
            yellow "  3. 快速测试 (仅 US/JP/SG/HK)"
            yellow "  0. 返回"
            reading "请选择: " test_choice
            
            case "$test_choice" in
                1) ;;  # 使用缓存
                2) 
                    psiphon_country_test_all
                    mapfile -t ok_arr < "$ok_file"
                    ;;
                3)
                    psiphon_country_test US JP SG HK
                    mapfile -t ok_arr < "$ok_file"
                    ;;
                0|*) return 0 ;;
            esac
        fi
    else
        yellow "未检测到可用国家列表，需要先测试"
        yellow "选项:"
        yellow "  1. 测试所有支持国家"
        yellow "  2. 快速测试 (仅 US/JP/SG/HK)"
        yellow "  0. 返回"
        reading "请选择: " test_choice
        
        case "$test_choice" in
            1) 
                psiphon_country_test_all
                mapfile -t ok_arr < "$ok_file"
                ;;
            2)
                psiphon_country_test US JP SG HK
                mapfile -t ok_arr < "$ok_file"
                ;;
            0|*) return 0 ;;
        esac
    fi

    if [[ ${#ok_arr[@]} -eq 0 ]]; then
        red "[!] 没有检测到可用国家"
        return 1
    fi

    echo
    green "========== 可用国家 =========="
    local i=1
    for cc in "${ok_arr[@]}"; do
        local name=$(get_country_name "$cc")
        printf "  %2d) %-4s %s\n" "$i" "$cc" "$name"
        ((i++))
    done
    echo "   0) 取消"
    echo "   A) AUTO (自动选择)"
    echo "=============================="
    reading "请选择编号或国家码: " sel

    if [[ "${sel^^}" == "A" || "${sel^^}" == "AUTO" ]]; then
        psiphon_set_region AUTO
        return 0
    fi

    if [[ "$sel" =~ ^[0-9]+$ ]]; then
        [[ "$sel" -eq 0 ]] && return 0
        local idx=$((sel-1))
        if [[ $idx -ge 0 && $idx -lt ${#ok_arr[@]} ]]; then
            psiphon_set_region "${ok_arr[$idx]}"
        else
            red "[!] 编号超出范围"
        fi
    else
        psiphon_set_region "${sel^^}"
    fi
}

# 搭建/更新 英国出口 (Psiphon GB) 端口复用 Hy2 节点
setup_psiphon_gb_hy2_node() {
    clear
    echo
    green "============================================================"
    green "  搭建/更新 英国出口 (Psiphon GB) 端口复用 Hy2 节点"
    green "============================================================"
    echo
    
    if [ ! -f "$WORKDIR/config.json" ]; then
        red "未检测到节点安装，请先在主菜单选项 1 安装节点"
        return 1
    fi
    
    cd "$WORKDIR" || return 1
    
    yellow "[*] 配置 Psiphon 英国出口 (GB)..."
    echo "GB" > "$WORKDIR/psiphon_region.txt"
    echo "true" > "$WORKDIR/psiphon_enabled.txt"
    echo "gb_hy2" > "$WORKDIR/psiphon_mode.txt"
    
    if ! install_psiphon_userland; then
        red "[!] Psiphon 安装失败"
        return 1
    fi
    
    write_psiphon_config
    
    if ! start_psiphon_userland; then
        red "[!] Psiphon 启动失败"
        return 1
    fi
    
    local socks_port
    socks_port="$(get_psiphon_socks_port)"
    if [[ "$socks_port" == "0" || -z "$socks_port" ]]; then
        red "[!] 无法获取 Psiphon 实际监听端口"
        return 1
    fi
    
    green "[+] Psiphon 英国 (GB) SOCKS5 出站端口: 127.0.0.1:$socks_port"
    yellow "[*] 正在向 sing-box 配置加入端口复用的 Hy2 英国节点..."
    
    local cfg="$WORKDIR/config.json"
    cp "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    
    python3 - <<PY
import json
import sys

cfg_path = r"$cfg"
socks_port = int(r"$socks_port")

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"[!] 读取配置失败: {e}")
    sys.exit(1)

outbounds = data.setdefault("outbounds", [])
inbounds = data.setdefault("inbounds", [])
route = data.setdefault("route", {})
rules = route.setdefault("rules", [])

gb_out_tag = "psiphon-gb-out"
gb_in_tag = "hy2-psiphon-gb-in"

# 1. 配置赛风 GB SOCKS5 出站
outbound_found = False
for o in outbounds:
    if o.get("tag") == gb_out_tag:
        o.clear()
        o.update({
            "type": "socks",
            "tag": gb_out_tag,
            "server": "127.0.0.1",
            "server_port": socks_port,
            "version": "5",
            "network": "tcp"
        })
        outbound_found = True
        break
if not outbound_found:
    outbounds.append({
        "type": "socks",
        "tag": gb_out_tag,
        "server": "127.0.0.1",
        "server_port": socks_port,
        "version": "5",
        "network": "tcp"
    })

hy2_port = 0
main_uuid = "secret"

# 找到主 Hysteria2 入站的端口与 UUID
for ib in inbounds:
    if ib.get("type") == "hysteria2":
        if not hy2_port and ib.get("listen_port"):
            hy2_port = ib["listen_port"]
        users = ib.get("users", [])
        if users:
            main_uuid = users[0].get("password", "secret")

if hy2_port == 0:
    print("[!] 未找到主 Hysteria2 入站配置")
    sys.exit(1)

gb_uuid = f"{main_uuid}-gb"

# 2. 为 GB 英国节点建立专属独立 Inbound (确保端口与路由 100% 绑定匹配)
inbounds[:] = [ib for ib in inbounds if ib.get("tag") != gb_in_tag]
inbounds.append({
    "type": "hysteria2",
    "tag": gb_in_tag,
    "listen": "::",
    "listen_port": hy2_port,
    "users": [{"password": gb_uuid}],
    "tls": {
        "enabled": True,
        "alpn": ["h3"],
        "certificate_path": "cert.pem",
        "key_path": "private.key"
    }
})

# 3. 在 rules 顶部添加极其可靠的 inbound 专属路由规则 (hy2-psiphon-gb-in -> psiphon-gb-out)
rules[:] = [r for r in rules if r.get("outbound") != gb_out_tag]
rules.insert(0, {
    "inbound": [gb_in_tag],
    "outbound": gb_out_tag
})

try:
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("[+] 英国 Psiphon 复用 Hy2 节点 JSON 路由修改成功 (inbound->outbound 已精准挂载)")
except Exception as e:
    print(f"[!] 写入配置失败: {e}")
    sys.exit(1)
PY

    if [ $? -ne 0 ]; then
        red "[!] 配置写入失败"
        return 1
    fi

    start_singbox_safe || return 1
    echo "true" > "$WORKDIR/psiphon_gb_node_enabled.txt"
    
    echo
    green "============================================================"
    green "  ✓ 英国出口 (Psiphon GB) 端口复用 Hy2 节点搭建完成！"
    green "============================================================"
    
    local main_ip=""
    if [ -f "$WORKDIR/all_ips.txt" ]; then
        main_ip=$(head -n 1 "$WORKDIR/all_ips.txt")
    fi
    main_ip=${main_ip:-"$(curl -s4m2 https://api.ipify.org 2>/dev/null)"}
    
    local main_uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null || echo "secret")
    local gb_uuid="${main_uuid}-gb"
    local hy2_port=$(jq -r '.inbounds[] | select(.tag=="hy2-psiphon-gb-in") | .listen_port' config.json 2>/dev/null)
    hy2_port=${hy2_port:-$(grep -oE '"listen_port": [0-9]+' config.json | head -n 1 | awk '{print $2}')}

    echo
    yellow "复用端口: $hy2_port (与主节点共享端口)"
    yellow "专属密码: $gb_uuid"
    echo
    purple "Hysteria2 英国 (GB) 出口节点链接 (端口复用):"
    green "hy2://${gb_uuid}@${main_ip}:${hy2_port}/?insecure=1&sni=www.bing.com#GB-Psiphon-Hy2-Reuse"
    echo "============================================================"
    return 0
}

# Psiphon 管理菜单
psiphon_management_menu() {
    while true; do
        clear 2>/dev/null || true
        echo
        green "============================================================"
        green "  Psiphon 赛风综合管理"
        green "============================================================"
        
        # 检查运行状态
        local psi_pid_file="$WORKDIR/psiphon.pid"
        local is_running=false
        if [[ -f "$psi_pid_file" ]]; then
            local pid=$(cat "$psi_pid_file" 2>/dev/null)
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                is_running=true
            fi
        fi
        if [[ "$is_running" == "false" ]]; then
            if pgrep -f "psiphon-tunnel-core" >/dev/null 2>&1 || pgrep -x "psiphon-tunnel-core" >/dev/null 2>&1; then
                is_running=true
            elif [[ -n "$(detect_psiphon_port_from_system "$WORKDIR/psiphon.pid")" ]]; then
                is_running=true
            fi
        fi
        
        local cur_reg=$(cat "$WORKDIR/psiphon_region.txt" 2>/dev/null || echo "AUTO")
        cur_reg="${cur_reg:-AUTO}"
        local cur_sport=$(get_psiphon_socks_port)

        if [[ "$is_running" == "true" ]]; then
            green  "  主进程状态 : ✓ 运行中"
        else
            yellow "  主进程状态 : ✗ 未运行"
        fi
        blue   "  主出口国家 : $cur_reg - $(get_country_name "$cur_reg")"
        purple "  Socks5端口 : ${cur_sport:-自动分配}"
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
        echo
        
        case "$choice" in
            1) psiphon_egress_test ;;
            2) psiphon_smart_country ;;
            3)
                echo
                show_supported_psiphon_codes
                echo
                reading "请输入国家码 (如 US): " new_cc
                [[ -n "$new_cc" ]] && psiphon_set_region "$new_cc"
                ;;
            4) psiphon_country_test US JP SG HK ;;
            5) psiphon_country_test_all ;;
            6)
                echo
                yellow "请输入要测试的国家码 (空格分隔):"
                yellow "例如: US JP SG HK DE FR"
                reading "> " custom_list
                if [[ -n "$custom_list" ]]; then
                    read -r -a cc_arr <<< "$custom_list"
                    psiphon_country_test "${cc_arr[@]}"
                fi
                ;;
            7)
                echo
                green "========== Psiphon 日志 (最近 30 行) =========="
                tail -30 "$WORKDIR/psiphon.log" 2>/dev/null || yellow "日志为空"
                echo "================================================"
                ;;
            8)
                yellow "正在深度重启与重置 Psiphon 主服务..."
                rm -rf "$WORKDIR/psiphon-data" 2>/dev/null || true
                mkdir -p "$WORKDIR/psiphon-data" 2>/dev/null
                if start_psiphon_userland; then
                    green "Psiphon 主服务重启成功！"
                    sync_psiphon_port_to_singbox || yellow "[!] 端口同步失败"
                else
                    red "Psiphon 主服务重启失败"
                fi
                ;;
            9)
                multi_egress_menu
                ;;
            0)
                return 0
                ;;
            *)
                red "无效选项"
                ;;
        esac
        
        echo
        reading "按回车继续..." _
    done
}

# ==================== Psiphon 多出口实例管理 ====================

# 多实例目录
PSI_INSTANCES_DIR="$WORKDIR/psiphon_instances"

# 初始化多实例目录结构
init_psiphon_instances_dir() {
    mkdir -p "$PSI_INSTANCES_DIR" 2>/dev/null
    touch "$PSI_INSTANCES_DIR/instances.txt" 2>/dev/null
}

# 获取所有实例列表
get_all_instances() {
    if [[ -f "$PSI_INSTANCES_DIR/instances.txt" ]]; then
        cat "$PSI_INSTANCES_DIR/instances.txt" | tr ',' '\n' | grep -v '^$' | sort -u
    fi
}

# 检查实例是否存在
instance_exists() {
    local cc="${1^^}"
    get_all_instances | grep -qxF "$cc"
}

# 获取指定实例的 SOCKS 端口
get_instance_socks_port() {
    local cc="${1^^}"
    local port_file="$PSI_INSTANCES_DIR/$cc/socks_port.txt"
    if [[ -f "$port_file" ]]; then
        cat "$port_file" 2>/dev/null
    else
        echo "0"
    fi
}

# 写入指定实例的 Psiphon 配置
write_instance_config() {
    local cc="${1^^}"
    local instance_dir="$PSI_INSTANCES_DIR/$cc"
    local datadir="$instance_dir/psiphon-data"
    
    mkdir -p "$datadir" 2>/dev/null
    
    # AUTO 时写空字符串
    local region="$cc"
    [[ "$region" == "AUTO" ]] && region=""
    
    # 部署种子服务器列表至副节点实例数据目录
    if [[ -f "$WORKDIR/server_list_compressed" ]]; then
        cp -f "$WORKDIR/server_list_compressed" "$datadir/server_list_compressed" 2>/dev/null
        cp -f "$WORKDIR/server_list_compressed" "$datadir/remote_server_list" 2>/dev/null
    else
        local s_urls=(
            "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed"
            "https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
            "https://ghproxy.net/https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core/master/psiphon/server_list_compressed"
        )
        for surl in "${s_urls[@]}"; do
            if curl -fsSL --connect-timeout 5 --max-time 15 "$surl" -o "$datadir/server_list_compressed" 2>/dev/null; then
                cp -f "$datadir/server_list_compressed" "$datadir/remote_server_list" 2>/dev/null
                cp -f "$datadir/server_list_compressed" "$WORKDIR/server_list_compressed" 2>/dev/null
                break
            fi
        done
    fi

    cat > "$instance_dir/psiphon.config" <<EOF
{
  "DataRootDirectory": "${datadir}",
  "EmitDiagnosticNotices": true,
  "EmitDiagnosticNetworkParameters": true,
  "EmitServerAlerts": true,
  
  "LocalSocksProxyPort": 0,
  "DisableLocalHTTPProxy": true,
  "LocalHttpProxyPort": 0,
  "EgressRegion": "${region}",
  
  "PropagationChannelId": "FFFFFFFFFFFFFFFF",
  "SponsorId": "FFFFFFFFFFFFFFFF",
  "RemoteServerListDownloadFilename": "remote_server_list",
  "RemoteServerListSignaturePublicKey": "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
  "RemoteServerListUrl": "https://s3.amazonaws.com/psiphon/web/mjr4-p23r-puwl/server_list_compressed",
  "UseIndistinguishableTLS": true
}
EOF
}

# 解析实例日志获取实际端口
parse_instance_port() {
    local cc="${1^^}"
    local log="$PSI_INSTANCES_DIR/$cc/psiphon.log"
    local port_file="$PSI_INSTANCES_DIR/$cc/socks_port.txt"
    local pid_file="$PSI_INSTANCES_DIR/$cc/psiphon.pid"
    
    local socks
    socks="$(grep -a '"noticeType":"ListeningSocksProxyPort"' "$log" 2>/dev/null \
        | tail -n 1 \
        | sed -E 's/.*"port":[[:space:]]*([0-9]+).*/\1/' )"
    
    if [[ -z "$socks" || "$socks" == "0" ]]; then
        socks="$(detect_psiphon_port_from_system "$pid_file")"
    fi

    if [[ "$socks" =~ ^[0-9]+$ ]] && (( socks > 0 )); then
        echo "$socks" > "$port_file"
        echo "$socks"
    else
        echo "0"
    fi
}

# 等待实例就绪
wait_instance_ready() {
    local cc="${1^^}"
    local log="$PSI_INSTANCES_DIR/$cc/psiphon.log"
    local timeout=60
    local elapsed=0
    
    while (( elapsed < timeout )); do
        # 检查端口占用
        if tail -n 200 "$log" 2>/dev/null | grep -q '"noticeType":"SocksProxyPortInUse"'; then
            red "[!] Psiphon $cc 端口被占用"
            return 2
        fi
        
        # 检查已开始监听
        if tail -n 400 "$log" 2>/dev/null | grep -q '"noticeType":"ListeningSocksProxyPort"'; then
            parse_instance_port "$cc" > /dev/null
            return 0
        fi
        
        # 检查隧道建立
        if tail -n 400 "$log" 2>/dev/null | grep '"noticeType":"Tunnels"' | grep -q '"count":[1-9]'; then
            parse_instance_port "$cc" > /dev/null
            return 0
        fi
        
        # 检查进程
        local pid_file="$PSI_INSTANCES_DIR/$cc/psiphon.pid"
        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            if ! kill -0 "$pid" 2>/dev/null; then
                return 1
            fi
        fi
        
        sleep 3
        elapsed=$((elapsed + 3))
        printf "\r[*] 等待 Psiphon $cc 就绪... %ds/%ds" "$elapsed" "$timeout"
    done
    
    echo
    return 1
}

# 启动指定实例
start_psiphon_instance() {
    local cc="${1^^}"
    local instance_dir="$PSI_INSTANCES_DIR/$cc"
    local bin="$WORKDIR/psiphon-tunnel-core"
    
    # 检查二进制
    if [[ ! -x "$bin" ]]; then
        yellow "[*] Psiphon 二进制不存在，正在安装..."
        install_psiphon_userland || return 1
    fi
    
    mkdir -p "$instance_dir" 2>/dev/null
    
    # 写配置
    write_instance_config "$cc"
    
    # 停止旧进程
    stop_psiphon_instance "$cc"
    
    # 清理历史数据锁目录 (防止 datastore open timeout 死锁)
    rm -rf "$instance_dir/psiphon-data" 2>/dev/null
    mkdir -p "$instance_dir/psiphon-data" 2>/dev/null
    
    # 清空旧日志
    > "$instance_dir/psiphon.log" 2>/dev/null
    > "$instance_dir/socks_port.txt" 2>/dev/null
    
    yellow "[*] 启动 Psiphon $cc 实例..."
    
    cd "$instance_dir"
    run_detached "$instance_dir/psiphon.pid" "$instance_dir/psiphon.log" \
        "$bin" -config "$instance_dir/psiphon.config"
    
    local pid
    pid="$(cat "$instance_dir/psiphon.pid" 2>/dev/null || echo 0)"
    
    sleep 2
    
    # 检查是否启动
    if ! kill -0 "$pid" 2>/dev/null; then
        red "[!] Psiphon $cc 启动失败"
        tail -20 "$instance_dir/psiphon.log" 2>/dev/null
        return 1
    fi
    
    # 等待就绪
    wait_instance_ready "$cc"
    local status=$?
    
    if [[ $status -eq 0 ]]; then
        local port=$(parse_instance_port "$cc")
        green "[+] Psiphon $cc 已启动 (SOCKS: 127.0.0.1:$port)"
        return 0
    else
        red "[!] Psiphon $cc 启动超时或失败"
        return 1
    fi
}

# 停止指定实例
stop_psiphon_instance() {
    local cc="${1^^}"
    local pid_file="$PSI_INSTANCES_DIR/$cc/psiphon.pid"
    
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 1
        fi
    fi
    
    # 额外清理适配 FreeBSD：使用 pgrep 结合 ps 强校验
    if command -v pgrep >/dev/null 2>&1; then
        for pid in $(pgrep -x "psiphon-tunnel-core" 2>/dev/null || pgrep "psiphon-tunnel"); do
            local cmd
            cmd=$(ps -o args= -p "$pid" 2>/dev/null)
            if echo "$cmd" | grep -q "$PSI_INSTANCES_DIR/$cc"; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        done
    fi
}

# 添加 Psiphon 实例
add_psiphon_instance() {
    local cc="${1^^}"
    
    if [[ -z "$cc" ]]; then
        red "[!] 请指定国家码"
        return 1
    fi
    if ! is_supported_psiphon_cc "$cc" || [[ "$cc" == "AUTO" ]]; then
        red "[!] Psiphon 多出口不支持国家码: $cc"
        show_supported_psiphon_codes
        return 1
    fi
    
    init_psiphon_instances_dir
    
    local name=$(get_country_name "$cc")
    yellow "[*] 添加 Psiphon 出口实例: $cc ($name)"
    
    # 检查是否已存在
    if instance_exists "$cc"; then
        yellow "[*] 实例 $cc 已存在，重新启动..."
    else
        # 添加到实例列表
        local instances=$(get_all_instances | tr '\n' ',' | sed 's/,$//')
        if [[ -n "$instances" ]]; then
            echo "$instances,$cc" > "$PSI_INSTANCES_DIR/instances.txt"
        else
            echo "$cc" > "$PSI_INSTANCES_DIR/instances.txt"
        fi
    fi
    
    # 启动实例
    start_psiphon_instance "$cc"
}

# 删除 Psiphon 实例
remove_psiphon_instance() {
    local cc="${1^^}"
    
    if [[ -z "$cc" ]]; then
        red "[!] 请指定国家码"
        return 1
    fi
    
    if ! instance_exists "$cc"; then
        yellow "[*] 实例 $cc 不存在"
        return 0
    fi
    
    local name=$(get_country_name "$cc")
    yellow "[*] 删除 Psiphon 出口实例: $cc ($name)"
    
    # 停止实例
    stop_psiphon_instance "$cc"
    
    # 删除目录
    rm -rf "$PSI_INSTANCES_DIR/$cc" 2>/dev/null
    
    # 从列表移除
    local instances=$(get_all_instances | grep -vxF "$cc" | tr '\n' ',' | sed 's/,$//')
    echo "$instances" > "$PSI_INSTANCES_DIR/instances.txt"
    
    green "[+] 已删除实例 $cc"
}

# 列出所有实例
list_psiphon_instances() {
    init_psiphon_instances_dir
    
    local instances=($(get_all_instances))
    
    if [[ ${#instances[@]} -eq 0 ]]; then
        yellow "[*] 暂无多出口实例"
        return 0
    fi
    
    echo
    green "========== Psiphon 多出口实例 =========="
    printf "  %-4s %-10s %-8s %-15s\n" "国家" "名称" "状态" "SOCKS端口"
    echo "  ----------------------------------------"
    
    for cc in "${instances[@]}"; do
        local name=$(get_country_name "$cc")
        local port=$(get_instance_socks_port "$cc")
        local pid_file="$PSI_INSTANCES_DIR/$cc/psiphon.pid"
        local status="✗ 未运行"
        
        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                status="✓ 运行中"
            fi
        fi
        
        if [[ "$port" == "0" || -z "$port" ]]; then
            port="未知"
        else
            port="127.0.0.1:$port"
        fi
        
        printf "  %-4s %-10s %-8s %-15s\n" "$cc" "$name" "$status" "$port"
    done
    echo "========================================="
}

# 启动所有实例
start_all_psiphon_instances() {
    local instances=($(get_all_instances))
    
    if [[ ${#instances[@]} -eq 0 ]]; then
        yellow "[*] 暂无多出口实例"
        return 0
    fi
    
    for cc in "${instances[@]}"; do
        start_psiphon_instance "$cc"
    done
    
    # 同步最新动态端口到 sing-box 配置 (重启后端口可能变化)
    yellow "[*] 同步最新端口到 sing-box..."
    sync_all_psiphon_ports || yellow "[!] 端口同步失败，请手动重启 sing-box"
}

# 停止所有实例
stop_all_psiphon_instances() {
    local instances=($(get_all_instances))
    
    for cc in "${instances[@]}"; do
        stop_psiphon_instance "$cc"
    done
    
    green "[+] 已停止所有多出口实例"
}

# 测试实例出口 IP
test_instance_egress() {
    local cc="${1^^}"
    local port=$(get_instance_socks_port "$cc")

    
    if [[ "$port" == "0" || -z "$port" ]]; then
        red "[!] 无法获取实例 $cc 端口"
        return 1
    fi
    
    yellow "[*] 测试 $cc 实例出口..."
    
    local json
    json="$(curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:${port}" https://ipinfo.io/json 2>/dev/null)" || \
    json="$(curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:${port}" http://ip-api.com/json 2>/dev/null)" || true
    
    if [[ -z "$json" ]]; then
        red "[!] $cc 出口测试失败"
        return 1
    fi
    
    local ip country
    ip=$(echo "$json" | python3 -c "import json,sys; j=json.load(sys.stdin); print(j.get('ip') or j.get('query',''))" 2>/dev/null)
    country=$(echo "$json" | python3 -c "import json,sys; j=json.load(sys.stdin); print(j.get('country') or j.get('countryCode',''))" 2>/dev/null)
    green "  $cc 出口: $ip ($country)"
}

# ==================== 多出口节点组管理 ====================

# 获取节点组列表
get_egress_node_groups() {
    if [[ -f "$WORKDIR/egress_node_groups.txt" ]]; then
        cat "$WORKDIR/egress_node_groups.txt" | tr ',' '\n' | grep -v '^$' | sort -u
    fi
}

# 检查节点组是否存在
node_group_exists() {
    local cc="${1^^}"
    get_egress_node_groups | grep -qxF "$cc"
}

# 添加多出口节点组 (核心函数)
# ==================== 全局 UDP 端口占用收集 (2026-09-08 用户核心需求) ====================
# 覆盖: 主节点 4 大端口 + 自定义代理组 + 赛风出口组, 输出每行: port|proto|ip|owner
# 任何组添加时都基于此视图选择复用端口/绑定IP, 实现端口+IP 全局共享利用最大化
collect_global_udp_binds() {
    local -a out=()
    local ip
    # 1. 主节点端口 (绑全部 IP)
    if [ -n "${HY2_PORT:-}" ] && [ "$HY2_PORT" != "0" ]; then
        for ip in "${ALL_IPS[@]:-}"; do
            [ -n "$ip" ] && out+=("$HY2_PORT|hy2|$ip|main")
        done
    fi
    if [ -n "${TUIC_PORT:-}" ] && [ "$TUIC_PORT" != "0" ]; then
        for ip in "${ALL_IPS[@]:-}"; do
            [ -n "$ip" ] && out+=("$TUIC_PORT|tuic|$ip|main")
        done
    fi

    # 2. 自定义代理组
    local gtag gdir
    for gtag in $(get_all_proxy_groups 2>/dev/null || true); do
        gdir="${PROXY_GROUPS_DIR}/${gtag}"
        [ -d "$gdir" ] || continue
        local h2=$(cat "$gdir/hy2_port.txt" 2>/dev/null)
        local t2=$(cat "$gdir/tuic_port.txt" 2>/dev/null)
        [ -z "$h2" ] && [ -z "$t2" ] && continue
        if [ -f "$gdir/ip_protos.txt" ]; then
            local bip bproto
            while IFS='|' read -r bip bproto; do
                [ -z "$bip" ] && continue
                if [ "$bproto" == "hy2" ] || [ "$bproto" == "both" ]; then [ -n "$h2" ] && out+=("$h2|hy2|$bip|$gtag"); fi
                if [ "$bproto" == "tuic" ] || [ "$bproto" == "both" ]; then [ -n "$t2" ] && out+=("$t2|tuic|$bip|$gtag"); fi
            done < "$gdir/ip_protos.txt"
        else
            for ip in "${ALL_IPS[@]:-}"; do
                [ -z "$ip" ] && continue
                [ -n "$h2" ] && out+=("$h2|hy2|$ip|$gtag")
                [ -n "$t2" ] && out+=("$t2|tuic|$ip|$gtag")
            done
        fi
    done

    # 3. 赛风出口组
    local cc
    if [ -d "${PSI_INSTANCES_DIR:-}" ]; then
        for cc in $(ls "$PSI_INSTANCES_DIR" 2>/dev/null || true); do
            [ -d "$PSI_INSTANCES_DIR/$cc" ] || continue
            local h3=$(cat "$PSI_INSTANCES_DIR/$cc/hy2_port.txt" 2>/dev/null)
            local t3=$(cat "$PSI_INSTANCES_DIR/$cc/tuic_port.txt" 2>/dev/null)
            [ -z "$h3" ] && [ -z "$t3" ] && continue
            if [ -f "$PSI_INSTANCES_DIR/$cc/ip_protos.txt" ]; then
                local cip cproto
                while IFS='|' read -r cip cproto; do
                    [ -z "$cip" ] && continue
                    if [ "$cproto" == "hy2" ] || [ "$cproto" == "both" ]; then [ -n "$h3" ] && out+=("$h3|hy2|$cip|$cc"); fi
                    if [ "$cproto" == "tuic" ] || [ "$cproto" == "both" ]; then [ -n "$t3" ] && out+=("$t3|tuic|$cip|$cc"); fi
                done < "$PSI_INSTANCES_DIR/$cc/ip_protos.txt"
            else
                for ip in "${ALL_IPS[@]:-}"; do
                    [ -z "$ip" ] && continue
                    [ -n "$h3" ] && out+=("$h3|hy2|$ip|$cc")
                    [ -n "$t3" ] && out+=("$t3|tuic|$ip|$cc")
                done
            fi
        done
    fi

    printf '%s\n' "${out[@]}"
}

add_egress_node_group() {
    local cc="${1^^}"
    local enable_vless="${2:-true}"
    local enable_hy2="${3:-true}"
    local enable_tuic="${4:-true}"
    
    if [[ -z "$cc" ]]; then
        red "[!] 请指定出口国家"
        return 1
    fi
    if ! is_supported_psiphon_cc "$cc" || [[ "$cc" == "AUTO" ]]; then
        red "[!] Psiphon 多出口不支持国家码: $cc"
        show_supported_psiphon_codes
        return 1
    fi
    
    local name=$(get_country_name "$cc")
    green "==== 添加 $cc ($name) 出口节点组 ===="
    
    # 1. 添加并启动 Psiphon 实例
    yellow "[1/5] 启动 Psiphon $cc 实例..."
    add_psiphon_instance "$cc" || {
        red "[!] Psiphon $cc 实例启动失败"
        return 1
    }
    
    local psi_port=$(get_instance_socks_port "$cc")
    if [[ "$psi_port" == "0" || -z "$psi_port" ]]; then
        red "[!] 无法获取 Psiphon $cc 端口"
        return 1
    fi
    green "    Psiphon $cc SOCKS 端口: $psi_port"
    
    # 2. 选择端口 (对齐自定义代理组: 复用已有 or 申请新端口)
    yellow "[2/5] 选择端口..."
    local tcp_port="" udp_port1="" udp_port2=""
    
    # 收集全局 UDP 端口占用 (主节点+代理组+赛风)
    local global_binds=()
    mapfile -t global_binds < <(collect_global_udp_binds)

    # --- VLESS: 监听 :: 独占端口, 只能新开 ---
    if [[ "$enable_vless" == "true" ]]; then
        yellow "[VLESS] VLESS 入站监听 :: 独占端口，不能按 IP 复用，申请新 TCP 端口..."
        local retry=0
        while [[ $retry -lt 30 && -z "$tcp_port" ]]; do
            local candidate=$(shuf -i 10000-65535 -n 1)
            if check_port_safe_for_config "$candidate" >/dev/null 2>&1; then
                local vres
                vres=$(devil port add tcp "$candidate" 2>&1)
                if [[ "$vres" == *"succesfully"* || "$vres" == *"Ok"* ]]; then
                    tcp_port="$candidate"
                fi
            fi
            ((retry++))
        done
        [[ -n "$tcp_port" ]] && green "    VLESS-$cc TCP 端口: $tcp_port"
    fi
    
    # --- Hy2: 复用 or 新开 ---
    local hy2_choice=""
    if [[ "$enable_hy2" == "true" ]]; then
        local hy2_ports=() bl
        for bl in "${global_binds[@]}"; do
            local bp bpr bip
            IFS='|' read -r bp bpr bip x <<< "$bl"
            [[ "$bpr" == "hy2" ]] || continue
            local found=false p2
            for p2 in "${hy2_ports[@]}"; do [[ "$p2" == "$bp" ]] && found=true; done
            [[ "$found" == "false" ]] && hy2_ports+=("$bp")
        done
        if [[ ${#hy2_ports[@]} -gt 0 ]]; then
            echo
            yellow "检测到目前已有 Hysteria2 端口: ${hy2_ports[*]}"
            yellow "为了节省端口资源（共享同端口绑定不同 IP），可选择复用已有端口或申请新端口。"
            echo "  1. 复用已有 Hysteria2 端口"
            echo "  2. 申请新的 Hysteria2 端口"
            reading "  请选择 [1-2]: " hy2_choice
            if [[ "$hy2_choice" == "1" ]]; then
                echo "已有端口列表 (括号内为占用情况):"
                local i
                for i in "${!hy2_ports[@]}"; do
                    local hp="${hy2_ports[$i]}"
                    local occ=() b3
                    for b3 in "${global_binds[@]}"; do
                        local p3 pr3 ip3 o3
                        IFS='|' read -r p3 pr3 ip3 o3 <<< "$b3"
                        [[ "$p3" == "$hp" && "$pr3" == "hy2" ]] && occ+=("$ip3($o3)")
                    done
                    if [[ ${#occ[@]} -eq 0 ]]; then
                        green "  $((i+1)). $hp  [全部 ${#ALL_IPS[@]} 个IP可用]"
                    elif [[ ${#occ[@]} -ge ${#ALL_IPS[@]} ]]; then
                        red "  $((i+1)). $hp  [!! 所有IP已被占用: ${occ[*]}]"
                    else
                        yellow "  $((i+1)). $hp  [可用 $(( ${#ALL_IPS[@]} - ${#occ[@]} ))/${#ALL_IPS[@]} 个IP, 已占用: ${occ[*]}]"
                    fi
                done
                reading "  请选择复用的端口序号: " p_idx
                p_idx=$((p_idx-1))
                if [[ $p_idx -ge 0 && $p_idx -lt ${#hy2_ports[@]} ]]; then
                    udp_port1="${hy2_ports[$p_idx]}"
                    green "  → 选择复用 Hysteria2 端口: $udp_port1"
                else
                    red "  [!] 无效选择，将申请新端口"
                fi
            fi
        fi
        if [[ -z "$udp_port1" ]]; then
            yellow "[*] 申请新的 Hysteria2 UDP 端口..."
            local retry=0
            while [[ $retry -lt 30 && -z "$udp_port1" ]]; do
                local cand=$(shuf -i 10000-65535 -n 1)
                if check_port_safe_for_config "$cand" >/dev/null 2>&1; then
                    local res
                    res=$(devil port add udp "$cand" 2>&1)
                    if [[ "$res" == *"succesfully"* || "$res" == *"Ok"* ]]; then
                        udp_port1="$cand"
                        green "    已成功申请 Hy2 UDP 端口: $udp_port1"
                    fi
                fi
                ((retry++))
            done
            [[ -z "$udp_port1" ]] && { red "[!] Hy2 UDP 端口申请失败"; return 1; }
        fi
    fi
    
    # --- TUIC: 复用 or 新开 ---
    local tuic_choice=""
    if [[ "$enable_tuic" == "true" ]]; then
        local tuic_ports=() bl2
        for bl2 in "${global_binds[@]}"; do
            local bp2 bpr2 bip2
            IFS='|' read -r bp2 bpr2 bip2 x <<< "$bl2"
            [[ "$bpr2" == "tuic" ]] || continue
            local found2=false p4
            for p4 in "${tuic_ports[@]}"; do [[ "$p4" == "$bp2" ]] && found2=true; done
            [[ "$found2" == "false" ]] && tuic_ports+=("$bp2")
        done
        if [[ ${#tuic_ports[@]} -gt 0 ]]; then
            echo
            yellow "检测到目前已有 TUIC 端口: ${tuic_ports[*]}"
            yellow "为了节省端口资源（共享同端口绑定不同 IP），可选择复用已有端口或申请新端口。"
            echo "  1. 复用已有 TUIC 端口"
            echo "  2. 申请新的 TUIC 端口"
            reading "  请选择 [1-2]: " tuic_choice
            if [[ "$tuic_choice" == "1" ]]; then
                echo "已有端口列表 (括号内为占用情况):"
                local i2
                for i2 in "${!tuic_ports[@]}"; do
                    local tp="${tuic_ports[$i2]}"
                    local tocc=() b4
                    for b4 in "${global_binds[@]}"; do
                        local p5 pr5 ip5 o5
                        IFS='|' read -r p5 pr5 ip5 o5 <<< "$b4"
                        [[ "$p5" == "$tp" && "$pr5" == "tuic" ]] && tocc+=("$ip5($o5)")
                    done
                    if [[ ${#tocc[@]} -eq 0 ]]; then
                        green "  $((i2+1)). $tp  [全部 ${#ALL_IPS[@]} 个IP可用]"
                    elif [[ ${#tocc[@]} -ge ${#ALL_IPS[@]} ]]; then
                        red "  $((i2+1)). $tp  [!! 所有IP已被占用: ${tocc[*]}]"
                    else
                        yellow "  $((i2+1)). $tp  [可用 $(( ${#ALL_IPS[@]} - ${#tocc[@]} ))/${#ALL_IPS[@]} 个IP, 已占用: ${tocc[*]}]"
                    fi
                done
                reading "  请选择复用的端口序号: " p_idx2
                p_idx2=$((p_idx2-1))
                if [[ $p_idx2 -ge 0 && $p_idx2 -lt ${#tuic_ports[@]} ]]; then
                    udp_port2="${tuic_ports[$p_idx2]}"
                    green "  → 选择复用 TUIC 端口: $udp_port2"
                else
                    red "  [!] 无效选择，将申请新端口"
                fi
            fi
        fi
        if [[ -z "$udp_port2" ]]; then
            yellow "[*] 申请新的 TUIC UDP 端口..."
            local retry=0
            while [[ $retry -lt 30 && -z "$udp_port2" ]]; do
                local cand2=$(shuf -i 10000-65535 -n 1)
                if check_port_safe_for_config "$cand2" >/dev/null 2>&1; then
                    local res2
                    res2=$(devil port add udp "$cand2" 2>&1)
                    if [[ "$res2" == *"succesfully"* || "$res2" == *"Ok"* ]]; then
                        udp_port2="$cand2"
                        green "    已成功申请 TUIC UDP 端口: $udp_port2"
                    fi
                fi
                ((retry++))
            done
            [[ -z "$udp_port2" ]] && { red "[!] TUIC UDP 端口申请失败"; return 1; }
        fi
    fi
    
    # 2.5 配置入站 IP (对齐自定义代理组: 逐 IP 选择绑定, 已被占用的自动跳过)
    local egress_ip_protos=()
    if [[ -n "$udp_port1" || -n "$udp_port2" ]]; then
        echo
        green "==== 配置入站 IP (赛风 $cc 出口组) ===="
        blue  "选择哪些 IP 映射到此赛风出口组 (已在其他组占用的 IP 自动跳过)"
        echo
        local i3
        for i3 in "${!ALL_IPS[@]}"; do
            local ipx="${ALL_IPS[$i3]}"
            local st=$(cat "$WORKDIR/ip_status_${ipx}.txt" 2>/dev/null)
            local st_str=""
            [[ "$st" == "Available" ]] && st_str=" [大陆可用]"
            [[ "$st" == "Blocked"   ]] && st_str=" [被墙]"
            
            local hy2_occ=false tuic_occ=false b6
            if [[ -n "$udp_port1" ]]; then
                for b6 in "${global_binds[@]}"; do
                    local p6 pr6 ip6 o6
                    IFS='|' read -r p6 pr6 ip6 o6 <<< "$b6"
                    [[ "$p6" == "$udp_port1" && "$pr6" == "hy2" && "$ip6" == "$ipx" ]] && hy2_occ=true
                done
            fi
            if [[ -n "$udp_port2" ]]; then
                for b6 in "${global_binds[@]}"; do
                    local p7 pr7 ip7 o7
                    IFS='|' read -r p7 pr7 ip7 o7 <<< "$b6"
                    [[ "$p7" == "$udp_port2" && "$pr7" == "tuic" && "$ip7" == "$ipx" ]] && tuic_occ=true
                done
            fi
            
            local can_h=false can_t=false
            [[ "$enable_hy2" == "true" && "$hy2_occ" == "false" ]] && can_h=true
            [[ "$enable_tuic" == "true" && "$tuic_occ" == "false" ]] && can_t=true
            
            echo
            blue "  IP[$((i3+1))]: $ipx${st_str}"
            
            if [[ "$can_h" == "false" && "$can_t" == "false" ]]; then
                yellow "    [自动跳过] 该 IP 在选定的端口上均已被其他组占用"
                continue
            fi
            if [[ "$can_h" == "true" && "$can_t" == "true" ]]; then
                yellow "    1. 启用 Hysteria2 + TUIC 双入站"
                yellow "    2. 仅启用 Hysteria2 入站"
                yellow "    3. 仅启用 TUIC 入站"
                yellow "    0. 跳过此 IP"
                reading "    选择 [0-3]: " eipc
                case "$eipc" in
                    1) egress_ip_protos+=("${ipx}|both"); green "    → 绑定 Hysteria2 + TUIC" ;;
                    2) egress_ip_protos+=("${ipx}|hy2");  green "    → 仅绑定 Hysteria2" ;;
                    3) egress_ip_protos+=("${ipx}|tuic"); green "    → 仅绑定 TUIC" ;;
                    *) yellow "    → 跳过 $ipx" ;;
                esac
            elif [[ "$can_h" == "true" ]]; then
                yellow "    1. 启用 Hysteria2 入站"
                yellow "    0. 跳过此 IP"
                reading "    选择 [0-1]: " eipc
                case "$eipc" in
                    1) egress_ip_protos+=("${ipx}|hy2"); green "    → 仅绑定 Hysteria2" ;;
                    *) yellow "    → 跳过 $ipx" ;;
                esac
            elif [[ "$can_t" == "true" ]]; then
                yellow "    1. 启用 TUIC 入站"
                yellow "    0. 跳过此 IP"
                reading "    选择 [0-1]: " eipc
                case "$eipc" in
                    1) egress_ip_protos+=("${ipx}|tuic"); green "    → 仅绑定 TUIC" ;;
                    *) yellow "    → 跳过 $ipx" ;;
                esac
            fi
        done
        if [[ ${#egress_ip_protos[@]} -eq 0 ]]; then
            red "[!] 未绑定任何 IP，操作取消。"
            # 回滚新申请的端口 (仅当该端口是本次新开的且无其他引用)
            local gb7
            for gb7 in "${global_binds[@]}"; do
                local p8 pr8 ip8 o8
                IFS='|' read -r p8 pr8 ip8 o8 <<< "$gb7"
                [[ "$p8" == "$udp_port1" && "$pr8" == "hy2" ]] && { udp_port1=""; break; }
            done
            for gb7 in "${global_binds[@]}"; do
                local p9 pr9 ip9 o9
                IFS='|' read -r p9 pr9 ip9 o9 <<< "$gb7"
                [[ "$p9" == "$udp_port2" && "$pr9" == "tuic" ]] && { udp_port2=""; break; }
            done
            [[ -n "$udp_port1" ]] && devil port del udp "$udp_port1" >/dev/null 2>&1
            [[ -n "$udp_port2" ]] && devil port del udp "$udp_port2" >/dev/null 2>&1
            [[ -n "$tcp_port" ]] && devil port del tcp "$tcp_port" >/dev/null 2>&1
            return 1
        fi
    fi
    
    # 保存端口信息
    mkdir -p "$PSI_INSTANCES_DIR/$cc" 2>/dev/null
    echo "$tcp_port" > "$PSI_INSTANCES_DIR/$cc/vless_port.txt"
    echo "$udp_port1" > "$PSI_INSTANCES_DIR/$cc/hy2_port.txt"
    echo "$udp_port2" > "$PSI_INSTANCES_DIR/$cc/tuic_port.txt"
    printf '%s\n' "${egress_ip_protos[@]}" > "$PSI_INSTANCES_DIR/$cc/ip_protos.txt"
    
    # 3. 更新 sing-box 配置
    yellow "[3/5] 更新 sing-box 配置..."
    sync_egress_group_to_singbox "$cc" "$tcp_port" "$udp_port1" "$udp_port2" "$psi_port" || {
        red "[!] 配置更新失败"
        return 1
    }
    
    # 4. 添加到节点组列表
    yellow "[4/5] 保存节点组信息..."
    local groups=$(get_egress_node_groups | tr '\n' ',' | sed 's/,$//')
    if [[ -n "$groups" ]]; then
        echo "$groups,$cc" > "$WORKDIR/egress_node_groups.txt"
    else
        echo "$cc" > "$WORKDIR/egress_node_groups.txt"
    fi
    
    # 5. 重启 sing-box
    yellow "[5/5] 重启 sing-box..."
    start_singbox_safe || {
        red "[!] sing-box 重启失败"
        return 1
    }
    
    green "==== $cc ($name) 节点组添加完成 ===="
    
    # 显示新节点链接
    echo
    generate_egress_node_links "$cc"
}

# 同步出口组到 sing-box 配置
sync_egress_group_to_singbox() {
    local cc="${1^^}"
    local vless_port="$2"
    local hy2_port="$3"
    local tuic_port="$4"
    local psi_port="$5"
    
    local cfg="$WORKDIR/config.json"
    local cc_lower=$(echo "$cc" | tr '[:upper:]' '[:lower:]')
    
    if [[ ! -f "$cfg" ]]; then
        red "[!] sing-box 配置不存在"
        return 1
    fi
    
    # 确保 ALL_IPS 已加载
    if [[ -f "$WORKDIR/all_ips.txt" ]]; then
        mapfile -t ALL_IPS < "$WORKDIR/all_ips.txt"
    fi
    [[ ${#ALL_IPS[@]} -eq 0 ]] && ALL_IPS=("$HOSTNAME")
    
    # 备份
    cp "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    
    # 读取现有配置
    local uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null)
    local reality_private=$(cat "$WORKDIR/private_key.txt" 2>/dev/null)
    local reality_domain=$(cat "$WORKDIR/reym.txt" 2>/dev/null)
    local server_ip="${ALL_IPS[0]:-$HOSTNAME}"
    
    # 读取该组的 IP 绑定关系 (ip_protos.txt: 每行 ip|proto), 按协议分别生成 IP 列表
    # 无 ip_protos.txt 的旧组 fallback 到 ALL_IPS 全部绑定
    local hy2_ip_csv="" tuic_ip_csv="" all_ip_csv=""
    if [[ -f "$PSI_INSTANCES_DIR/$cc/ip_protos.txt" ]]; then
        local eip eproto
        while IFS='|' read -r eip eproto; do
            [[ -z "$eip" ]] && continue
            if [[ "$eproto" == "hy2" || "$eproto" == "both" ]]; then
                hy2_ip_csv="${hy2_ip_csv},${eip}"
            fi
            if [[ "$eproto" == "tuic" || "$eproto" == "both" ]]; then
                tuic_ip_csv="${tuic_ip_csv},${eip}"
            fi
            all_ip_csv="${all_ip_csv},${eip}"
        done < "$PSI_INSTANCES_DIR/$cc/ip_protos.txt"
        hy2_ip_csv="${hy2_ip_csv#,}"
        tuic_ip_csv="${tuic_ip_csv#,}"
        all_ip_csv="${all_ip_csv#,}"
    else
        all_ip_csv="$(printf "%s," "${ALL_IPS[@]}")"; all_ip_csv="${all_ip_csv%,}"
        hy2_ip_csv="$all_ip_csv"
        tuic_ip_csv="$all_ip_csv"
    fi
    
    python3 - <<PY
import json
import sys

cfg_path = r"$cfg"
cc = r"$cc"
cc_lower = r"$cc_lower"
vless_port = int(r"$vless_port") if r"$vless_port" else 0
hy2_port = int(r"$hy2_port") if r"$hy2_port" else 0
tuic_port = int(r"$tuic_port") if r"$tuic_port" else 0
psi_port = int(r"$psi_port")
uuid = r"$uuid"
reality_private = r"$reality_private"
reality_domain = r"$reality_domain"
server_ip = r"$server_ip"

# 解析 IP 列表 (hy2/tuic 各自绑定的 IP)
hy2_ip_csv = r"$hy2_ip_csv"
tuic_ip_csv = r"$tuic_ip_csv"
hy2_ips = [x.strip() for x in hy2_ip_csv.split(",") if x.strip()]
tuic_ips = [x.strip() for x in tuic_ip_csv.split(",") if x.strip()]
ips = list(dict.fromkeys(hy2_ips + tuic_ips))
if not ips:
    ips = [server_ip]

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"[!] 读取配置失败: {e}")
    sys.exit(1)

inbounds = data.setdefault("inbounds", [])
outbounds = data.setdefault("outbounds", [])
route = data.setdefault("route", {})
rules = route.setdefault("rules", [])

# Psiphon 出站 tag
psi_tag = f"psiphon-{cc_lower}"

# 1. 添加 Psiphon 出站
psi_out = None
for o in outbounds:
    if o.get("tag") == psi_tag:
        psi_out = o
        break

if psi_out:
    psi_out["server_port"] = psi_port
else:
    outbounds.append({
        "type": "socks",
        "tag": psi_tag,
        "server": "127.0.0.1",
        "server_port": psi_port,
        "version": "5",
        "network": "tcp"
    })

inbound_tags = []

# 2. 添加 VLESS inbound (TCP 协议用 :: 监听即可)
if vless_port > 0:
    vless_tag = f"vless-reality-{cc_lower}"
    inbound_tags.append(vless_tag)
    
    # 移除旧的同名 inbound
    inbounds[:] = [i for i in inbounds if i.get("tag") != vless_tag]
    
    inbounds.append({
        "type": "vless",
        "tag": vless_tag,
        "listen": "::",
        "listen_port": vless_port,
        "users": [{"uuid": uuid, "flow": "xtls-rprx-vision"}],
        "tls": {
            "enabled": True,
            "server_name": reality_domain,
            "reality": {
                "enabled": True,
                "handshake": {"server": reality_domain, "server_port": 443},
                "private_key": reality_private,
                "short_id": [""]
            }
        }
    })

# 3. 添加 Hysteria2 inbound（每个绑定的 IP 一个 inbound，像 serv00.sh 那样）
if hy2_port > 0 and hy2_ips:
    # 先移除旧的 hysteria2-*-{cc_lower} 格式的 inbound
    inbounds[:] = [i for i in inbounds 
                   if not (i.get("tag", "").startswith("hysteria2-") and i.get("tag", "").endswith(f"-{cc_lower}"))]

    for idx, ip in enumerate(hy2_ips, start=1):
        hy2_tag = f"hysteria2-{idx}-{cc_lower}"
        inbound_tags.append(hy2_tag)

        inbounds.append({
            "type": "hysteria2",
            "tag": hy2_tag,
            "listen": ip,              # 关键：绑定到具体 IP
            "listen_port": hy2_port,
            "users": [{"password": uuid}],
            "tls": {
                "enabled": True,
                "alpn": ["h3"],
                "certificate_path": "cert.pem",
                "key_path": "private.key"
            }
        })

# 4. 添加 TUIC inbound（每个绑定的 IP 一个 inbound）
if tuic_port > 0 and tuic_ips:
    # 先移除旧的 tuic-*-{cc_lower} 格式的 inbound
    inbounds[:] = [i for i in inbounds 
                   if not (i.get("tag", "").startswith("tuic-") and i.get("tag", "").endswith(f"-{cc_lower}"))]

    for idx, ip in enumerate(tuic_ips, start=1):
        tuic_tag = f"tuic-{idx}-{cc_lower}"
        inbound_tags.append(tuic_tag)

        inbounds.append({
            "type": "tuic",
            "tag": tuic_tag,
            "listen": ip,              # 关键：绑定到具体 IP
            "listen_port": tuic_port,
            "users": [{"uuid": uuid, "password": uuid}],
            "congestion_control": "bbr",
            "tls": {
                "enabled": True,
                "alpn": ["h3"],
                "certificate_path": "cert.pem",
                "key_path": "private.key"
            }
        })

# 5. 添加路由规则
rule_exists = False
for r in rules:
    if r.get("outbound") == psi_tag and "inbound" in r:
        r["inbound"] = inbound_tags
        rule_exists = True
        break

if not rule_exists and inbound_tags:
    rules.insert(0, {
        "inbound": inbound_tags,
        "outbound": psi_tag
    })

try:
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"[+] sing-box 配置已更新 ({cc} 节点组, {len(ips)} 个IP)")
except Exception as e:
    print(f"[!] 写入配置失败: {e}")
    sys.exit(1)
PY
}

# 生成出口节点组链接（展开全部 IP + 自定义命名）
generate_egress_node_links() {
    local cc="${1^^}"
    local cc_lower=$(echo "$cc" | tr '[:upper:]' '[:lower:]')
    local name=$(get_country_name "$cc")

    local vless_port=$(cat "$PSI_INSTANCES_DIR/$cc/vless_port.txt" 2>/dev/null)
    local hy2_port=$(cat "$PSI_INSTANCES_DIR/$cc/hy2_port.txt" 2>/dev/null)
    local tuic_port=$(cat "$PSI_INSTANCES_DIR/$cc/tuic_port.txt" 2>/dev/null)

    local uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null)
    local reality_public=$(cat "$WORKDIR/public_key.txt" 2>/dev/null)
    local reality_domain=$(cat "$WORKDIR/reym.txt" 2>/dev/null)

    # 确保 ALL_IPS 已加载（多出口菜单路径下不一定提前加载）
    if [[ -f "$WORKDIR/all_ips.txt" ]]; then
        mapfile -t ALL_IPS < "$WORKDIR/all_ips.txt"
    fi
    [[ ${#ALL_IPS[@]} -eq 0 ]] && ALL_IPS=("$HOSTNAME")

    # 读取该组 IP 绑定关系 (ip_protos.txt), 无则回退 ALL_IPS
    local hy2_ips=() tuic_ips=() all_ips=()
    if [[ -f "$PSI_INSTANCES_DIR/$cc/ip_protos.txt" ]]; then
        local eip2 eproto2
        while IFS='|' read -r eip2 eproto2; do
            [[ -z "$eip2" ]] && continue
            if [[ "$eproto2" == "hy2" || "$eproto2" == "both" ]]; then hy2_ips+=("$eip2"); fi
            if [[ "$eproto2" == "tuic" || "$eproto2" == "both" ]]; then tuic_ips+=("$eip2"); fi
            local dup=false ipx2
            for ipx2 in "${all_ips[@]}"; do [[ "$ipx2" == "$eip2" ]] && dup=true; done
            [[ "$dup" == "false" ]] && all_ips+=("$eip2")
        done < "$PSI_INSTANCES_DIR/$cc/ip_protos.txt"
    else
        hy2_ips=("${ALL_IPS[@]}")
        tuic_ips=("${ALL_IPS[@]}")
        all_ips=("${ALL_IPS[@]}")
    fi

    # 中转标签（可改为自动识别落地国家）
    local transit_label="PL中转"

    echo
    green "========== $cc ($name) 出口节点链接 =========="

    # VLESS-Reality：为每个绑定的 IP 输出一条 (VLESS 是 :: 独占, 用全部绑定IP)
    if [[ -n "$vless_port" && "$vless_port" != "0" ]]; then
        echo
        purple "VLESS-Reality-$cc (共 ${#all_ips[@]} 个IP):"
        local idx=1
        for ip in "${all_ips[@]}"; do
            local node_name="${cc}-VLESS-${transit_label}-${idx}"
            local vless_link="vless://${uuid}@${ip}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_domain}&fp=chrome&pbk=${reality_public}&type=tcp#${node_name}"
            echo "$vless_link"
            ((idx++))
        done
    fi

    # Hysteria2：为每个绑定的 IP 输出一条
    if [[ -n "$hy2_port" && "$hy2_port" != "0" ]]; then
        echo
        purple "Hysteria2-$cc (共 ${#hy2_ips[@]} 个IP):"
        local idx=1
        for ip in "${hy2_ips[@]}"; do
            local node_name="${cc}-Hysteria2-${transit_label}-${idx}"
            local hy2_link="hysteria2://${uuid}@${ip}:${hy2_port}?insecure=1&sni=${HOSTNAME}#${node_name}"
            echo "$hy2_link"
            ((idx++))
        done
    fi

    # TUIC：为每个绑定的 IP 输出一条
    if [[ -n "$tuic_port" && "$tuic_port" != "0" ]]; then
        echo
        purple "TUIC-$cc (共 ${#tuic_ips[@]} 个IP):"
        local idx=1
        for ip in "${tuic_ips[@]}"; do
            local node_name="${cc}-TUIC-${transit_label}-${idx}"
            local tuic_link="tuic://${uuid}:${uuid}@${ip}:${tuic_port}?congestion_control=bbr&alpn=h3&allow_insecure=1#${node_name}"
            echo "$tuic_link"
            ((idx++))
        done
    fi

    echo "============================================="
}

# 删除出口节点组
remove_egress_node_group() {
    local cc="${1^^}"
    
    if [[ -z "$cc" ]]; then
        red "[!] 请指定国家码"
        return 1
    fi
    
    local name=$(get_country_name "$cc")
    yellow "[*] 删除 $cc ($name) 出口节点组..."
    
    # 读取端口信息
    local vless_port=$(cat "$PSI_INSTANCES_DIR/$cc/vless_port.txt" 2>/dev/null)
    local hy2_port=$(cat "$PSI_INSTANCES_DIR/$cc/hy2_port.txt" 2>/dev/null)
    local tuic_port=$(cat "$PSI_INSTANCES_DIR/$cc/tuic_port.txt" 2>/dev/null)
    
    # 端口可能被其他组(代理组/主节点/其他赛风组)复用, 删除前检查全局引用:
    # 仅当没有任何其他位置引用该端口时才 devil port del, 否则保留端口只移除本组绑定
    local port_ref_check
    port_ref_check=$(collect_global_udp_binds 2>/dev/null | grep -c "|hy2|" ) || true
    # VLESS 是 TCP 且 :: 独占, 无复用可能, 直接删除
    [[ -n "$vless_port" ]] && devil port del tcp "$vless_port" >/dev/null 2>&1
    
    if [[ -n "$hy2_port" ]]; then
        local hy2_refs
        hy2_refs=$(collect_global_udp_binds 2>/dev/null | grep -E "^${hy2_port}\|hy2\|" | grep -v "|${cc}$" || true)
        if [[ -n "$hy2_refs" ]]; then
            yellow "  [*] Hy2 端口 $hy2_port 仍被其他组引用，保留端口:"
            echo "$hy2_refs" | head -5
        else
            devil port del udp "$hy2_port" >/dev/null 2>&1
        fi
    fi
    
    if [[ -n "$tuic_port" ]]; then
        local tuic_refs
        tuic_refs=$(collect_global_udp_binds 2>/dev/null | grep -E "^${tuic_port}\|tuic\|" | grep -v "|${cc}$" || true)
        if [[ -n "$tuic_refs" ]]; then
            yellow "  [*] TUIC 端口 $tuic_port 仍被其他组引用，保留端口:"
            echo "$tuic_refs" | head -5
        else
            devil port del udp "$tuic_port" >/dev/null 2>&1
        fi
    fi
    
    # 删除 Psiphon 实例
    remove_psiphon_instance "$cc"
    
    # 从节点组列表移除
    local groups=$(get_egress_node_groups | grep -vxF "$cc" | tr '\n' ',' | sed 's/,$//')
    echo "$groups" > "$WORKDIR/egress_node_groups.txt"
    
    # 更新 sing-box 配置 (移除相关 inbound 和 outbound)
    remove_egress_from_singbox "$cc"
    
    # 重启 sing-box
    start_singbox_safe
    
    green "[+] 已删除 $cc 出口节点组"
}

# 从 sing-box 配置移除出口组
remove_egress_from_singbox() {
    local cc="${1^^}"
    local cc_lower=$(echo "$cc" | tr '[:upper:]' '[:lower:]')
    local cfg="$WORKDIR/config.json"
    
    [[ -f "$cfg" ]] || return 0
    
    python3 - <<PY
import json

cfg_path = r"$cfg"
cc_lower = r"$cc_lower"

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except:
    exit(0)

inbounds = data.get("inbounds", [])
outbounds = data.get("outbounds", [])
route = data.get("route", {})
rules = route.get("rules", [])

# 移除相关 inbound
inbounds[:] = [i for i in inbounds if not i.get("tag", "").endswith(f"-{cc_lower}")]

# 移除相关 outbound
psi_tag = f"psiphon-{cc_lower}"
outbounds[:] = [o for o in outbounds if o.get("tag") != psi_tag]

# 移除相关路由规则
rules[:] = [r for r in rules if r.get("outbound") != psi_tag]

try:
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
except:
    pass
PY
}

# 重新/修复指定赛风出口组 (彻底清理历史脏数据库并执行 1~10s 动态轮询连通性探测)
repair_single_psiphon_instance() {
    local groups=($(get_egress_node_groups))
    if [[ ${#groups[@]} -eq 0 ]]; then
        yellow "[!] 当前暂无已配置的赛风出口组"
        return 1
    fi

    echo
    green "============================================================"
    green "  重启 / 修复指定赛风出口组"
    green "============================================================"
    echo "当前已配置的赛风出口组列表:"
    local idx=1
    for cc in "${groups[@]}"; do
        [[ -z "$cc" ]] && continue
        local cname=$(get_country_name "$cc")
        local hp=$(cat "${PSI_INSTANCES_DIR}/$cc/hy2_port.txt" 2>/dev/null || echo "0")
        local tp=$(cat "${PSI_INSTANCES_DIR}/$cc/tuic_port.txt" 2>/dev/null || echo "0")
        local vp=$(cat "${PSI_INSTANCES_DIR}/$cc/vless_port.txt" 2>/dev/null || echo "0")
        local p_info=""
        [[ "$hp" -gt 0 ]] && p_info="${p_info}Hy2:$hp "
        [[ "$tp" -gt 0 ]] && p_info="${p_info}TUIC:$tp "
        [[ "$vp" -gt 0 ]] && p_info="${p_info}VLESS:$vp "
        local pid_file="$PSI_INSTANCES_DIR/$cc/psiphon.pid"
        local st_str="${red}[✗ 未运行]${re}"
        if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
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
        if [[ $sel_idx -ge 0 && $sel_idx -lt ${#groups[@]} ]]; then
            target_cc="${groups[$sel_idx]}"
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

    # 1. 停止旧服务并清理可能残留的孤儿进程
    echo -e "${blue}--> [1/5] 停止旧服务并清理可能残留的孤儿进程...${re}"
    stop_psiphon_instance "$target_cc"
    sleep 1

    # 2. 校验与校准 Socks5 端口
    echo -e "${blue}--> [2/5] 校验本地 Socks5 监听与绑定...${re}"
    > "$inst_dir/psiphon.log" 2>/dev/null
    > "$inst_dir/socks_port.txt" 2>/dev/null

    # 3. 彻底重置历史脏数据并载入纯净种子
    echo -e "${blue}--> [3/5] 彻底重置历史脏数据并载入纯净种子列表...${re}"
    rm -rf "$inst_dir/psiphon-data" 2>/dev/null || true
    mkdir -p "$inst_dir/psiphon-data" 2>/dev/null
    write_instance_config "$target_cc"

    # 4. 同步 Sing-box 出站与分流路由规则
    echo -e "${blue}--> [4/5] 同步 Sing-box 出站与分流路由规则...${re}"
    add_egress_to_singbox "$target_cc"
    start_singbox_safe

    # 5. 启动服务并执行平滑动态出口连通性探测
    echo -e "${blue}--> [5/5] 拉起守护进程并执行实时出口连通性探测...${re}"
    start_psiphon_instance "$target_cc"
    
    local socks_p=$(get_instance_socks_port "$target_cc")
    local out_ip=""
    local max_wait=10
    local elapsed=0

    if [[ "$socks_p" =~ ^[0-9]+$ ]] && (( socks_p > 0 )); then
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
    fi
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

    generate_egress_node_links "$target_cc"
}

# 多出口节点管理菜单
multi_egress_menu() {
    while true; do
        clear 2>/dev/null || true
        echo
        green "============================================================"
        green "  副节点 - 赛风多出口组管理"
        green "============================================================"
        yellow "  说明: 副节点拥有独立入站端口与专属路由，出站走赛风对应国家"
        yellow "        与主节点完全平行独立，互不干扰"
        green "============================================================"
        echo
        
        # 显示现有节点组
        local groups=($(get_egress_node_groups))
        purple "【当前已配置赛风出口组】 (共 ${#groups[@]} 组):"
        if [[ ${#groups[@]} -gt 0 ]]; then
            local idx=1
            for cc in "${groups[@]}"; do
                [[ -z "$cc" ]] && continue
                local name=$(get_country_name "$cc")
                local hp=$(cat "${PSI_INSTANCES_DIR}/$cc/hy2_port.txt" 2>/dev/null || echo "0")
                local tp=$(cat "${PSI_INSTANCES_DIR}/$cc/tuic_port.txt" 2>/dev/null || echo "0")
                local vp=$(cat "${PSI_INSTANCES_DIR}/$cc/vless_port.txt" 2>/dev/null || echo "0")
                local p_info=""
                [[ "$hp" -gt 0 ]] && p_info="${p_info}Hy2:$hp "
                [[ "$tp" -gt 0 ]] && p_info="${p_info}TUIC:$tp "
                [[ "$vp" -gt 0 ]] && p_info="${p_info}VLESS:$vp "
                local pid_file="$PSI_INSTANCES_DIR/$cc/psiphon.pid"
                local st_str="${red}[✗ 未运行]${re}"
                if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
                    st_str="${green}[✓ 运行中]${re}"
                fi
                echo -e "  ${green}[$idx] [$cc] $name${re} $st_str"
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
        echo "------------------------------------------------------------"
        red    "  0. 返回上一级菜单"
        echo "============================================================"
        reading "请选择 [0-5]: " choice
        echo
        
        case "$choice" in
            1)
                echo
                show_supported_psiphon_codes
                echo
                reading "请输入要添加的国家码 (如 JP): " new_cc
                
                if [[ -n "$new_cc" ]]; then
                    echo
                    yellow "选择要启用的协议:"
                    yellow "  1. 全部 (VLESS + Hy2 + TUIC) - 需要 3 端口"
                    yellow "  2. 仅 VLESS-Reality - 需要 1 TCP 端口"
                    yellow "  3. 仅 UDP (Hy2 + TUIC) - 需要 2 UDP 端口"
                    yellow "  4. 仅 Hysteria2 - 需要 1 UDP 端口"
                    reading "请选择 [1-4, 默认1]: " proto_choice
                    [[ -z "$proto_choice" ]] && proto_choice="1"
                    
                    case "$proto_choice" in
                        1) add_egress_node_group "$new_cc" true true true ;;
                        2) add_egress_node_group "$new_cc" true false false ;;
                        3) add_egress_node_group "$new_cc" false true true ;;
                        4) add_egress_node_group "$new_cc" false true false ;;
                        *) add_egress_node_group "$new_cc" true true true ;;
                    esac
                fi
                ;;
            2)
                if [[ ${#groups[@]} -eq 0 ]]; then
                    yellow "暂无赛风出口组"
                else
                    echo
                    for cc in "${groups[@]}"; do
                        generate_egress_node_links "$cc"
                    done
                fi
                ;;
            3)
                if [[ ${#groups[@]} -eq 0 ]]; then
                    yellow "暂无赛风出口组可删除"
                else
                    echo
                    reading "请输入要删除的国家码 (如 US): " del_cc
                    [[ -n "$del_cc" ]] && remove_egress_node_group "$del_cc"
                fi
                ;;
            4)
                repair_single_psiphon_instance
                ;;
            5)
                yellow "正在重启并重置所有赛风实例..."
                for cc in "${groups[@]}"; do
                    [[ -z "$cc" ]] && continue
                    local idir="${PSI_INSTANCES_DIR}/${cc}"
                    stop_psiphon_instance "$cc"
                    rm -rf "$idir/psiphon-data" 2>/dev/null || true
                    mkdir -p "$idir/psiphon-data" 2>/dev/null
                    write_instance_config "$cc"
                    start_psiphon_instance "$cc"
                done
                sync_all_psiphon_ports || true
                start_singbox_safe
                green "所有赛风实例已重启、清空旧缓存并重新载入种子守护！"
                ;;
            0)
                return 0
                ;;
            *)
                red "无效选项"
                ;;
        esac
        
        echo
        reading "按回车继续..." _
    done
}

# ==================== 下载函数 ====================

# 生成随机文件名
generate_random_name() {
    local chars=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890
    local name=""
    for i in {1..6}; do
        name="$name${chars:RANDOM%${#chars}:1}"
    done
    echo "$name"
}

# 带降级的下载
download_with_fallback() {
    local URL=$1
    local NEW_FILENAME=$2
    
    curl -L -sS --max-time 30 -o "$NEW_FILENAME" "$URL" 2>/dev/null
    
    if [ ! -s "$NEW_FILENAME" ]; then
        wget -q -O "$NEW_FILENAME" "$URL" 2>/dev/null
    fi
    
    if [ -s "$NEW_FILENAME" ]; then
        chmod +x "$NEW_FILENAME"
        return 0
    else
        return 1
    fi
}

# 下载sing-box二进制文件
download_singbox() {
    cd "$WORKDIR"
    
    ARCH=$(uname -m)
    if [ "$ARCH" == "arm" ] || [ "$ARCH" == "arm64" ] || [ "$ARCH" == "aarch64" ]; then
        BASE_URL="https://github.com/eooce/test/releases/download/freebsd-arm64"
    else
        BASE_URL="https://github.com/eooce/test/releases/download/freebsd"
    fi
    
    # 下载 sing-box
    SB_BINARY=$(generate_random_name)
    yellow "正在下载 sing-box..."
    download_with_fallback "$BASE_URL/sb" "$SB_BINARY"
    if [ $? -eq 0 ]; then
        green "sing-box 下载成功"
        echo "$SB_BINARY" > sb.txt
    else
        red "sing-box 下载失败"
        return 1
    fi
    
    # 下载 cloudflared
    CF_BINARY=$(generate_random_name)
    yellow "正在下载 cloudflared..."
    download_with_fallback "$BASE_URL/server" "$CF_BINARY"
    if [ $? -eq 0 ]; then
        green "cloudflared 下载成功"
        echo "$CF_BINARY" > cf.txt
    else
        red "cloudflared 下载失败"
        return 1
    fi
    
    # 下载哪吒探针（如果需要）
    if [ -n "$NEZHA_SERVER" ] && [ -n "$NEZHA_KEY" ]; then
        NZ_BINARY=$(generate_random_name)
        if [ -n "$NEZHA_PORT" ]; then
            # Nezha v0
            download_with_fallback "$BASE_URL/npm" "$NZ_BINARY"
        else
            # Nezha v1
            download_with_fallback "$BASE_URL/v1" "$NZ_BINARY"
        fi
        if [ $? -eq 0 ]; then
            echo "$NZ_BINARY" > nz.txt
            green "哪吒探针下载成功"
        fi
    fi
    
    export SB_BINARY
    export CF_BINARY
}

# ==================== 配置函数 ====================

# 读取用户配置
read_user_config() {
    echo
    green "==== 配置节点参数 ===="
    echo
    
    # 获取并显示所有IP
    get_all_ips
    display_ip_list
    echo
    
    # 让用户选择IP模式
    yellow "IP模式选择:"
    yellow "  1. 使用所有可用IP (推荐，生成更多节点)"
    yellow "  2. 只使用最佳IP (单IP模式)"
    reading "请选择 1-2 (回车默认1): " ip_mode
    
    if [[ "$ip_mode" == "2" ]]; then
        # 单IP模式 - 让用户选择或自动选择最佳IP
        USE_ALL_IPS=false
        reading "请输入要使用的IP (回车自动选择最佳可用IP): " selected_ip
        if [ -z "$selected_ip" ]; then
            # 自动选择最佳可用IP（优先选择 Available 的）
            yellow "正在自动筛选最佳可用IP..."
            local req_ids=()
            for ip in "${ALL_IPS[@]}"; do
                local response=""
                response=$(curl -s -H "Accept: application/json" --max-time 4 "https://check-host.net/check-ping?host=${ip}&node=cn" 2>/dev/null)
                local req_id=""
                if [ -n "$response" ]; then
                    req_id=$(echo "$response" | grep -o '"request_id":"[^"]*"' | head -n1 | cut -d'"' -f4)
                fi
                req_ids+=("$req_id")
            done
            
            sleep 3
            
            for i in "${!ALL_IPS[@]}"; do
                local ip="${ALL_IPS[$i]}"
                local req_id="${req_ids[$i]}"
                local status="Unknown"
                if [ -n "$req_id" ]; then
                    local result=""
                    result=$(curl -s --max-time 4 "https://check-host.net/check-result/${req_id}" 2>/dev/null)
                    if [ -n "$result" ] && echo "$result" | grep -q '"OK"'; then
                        status="Available"
                    fi
                fi
                if [[ "$status" == "Available" ]]; then
                    selected_ip="$ip"
                    break
                fi
            done
            
            # 如果没有找到 Available 的，退回第一个
            if [ -z "$selected_ip" ]; then
                selected_ip=${ALL_IPS[0]}
                yellow "未检测到大陆可达的IP，默认选择第一个 IP: $selected_ip"
            else
                green "自动选择最佳可用 IP: $selected_ip (大陆未阻断)"
            fi
        fi
        # 只保留选中的IP
        ALL_IPS=("$selected_ip")
        IP_COUNT=1
        printf '%s\n' "${ALL_IPS[@]}" > "$WORKDIR/all_ips.txt"
        green "选择的IP: $selected_ip (单IP模式)"

    else
        # 所有IP模式
        USE_ALL_IPS=true
        green "将为所有 ${IP_COUNT} 个IP生成节点"
    fi
    
    # UUID
    echo
    reading "请输入UUID密码 (回车随机生成): " input_uuid
    if [ -n "$input_uuid" ]; then
        UUID=$input_uuid
    fi
    echo "$UUID" > "$WORKDIR/UUID.txt"
    green "UUID: $UUID"
    
    # Reality域名
    echo
    yellow "Reality域名选项:"
    yellow "  1. 使用Serv00/Hostuno自带域名 (默认/回车)"
    yellow "  2. 使用CF域名 (blog.cloudflare.com) - 支持ProxyIP"
    yellow "  3. 自定义域名"
    reading "请选择 1-3: " reym_choice
    case "$reym_choice" in
        2|s|S)
            REALITY_DOMAIN="blog.cloudflare.com"
            ;;
        3)
            reading "请输入Reality域名: " custom_domain
            REALITY_DOMAIN=${custom_domain:-"apple.com"}
            ;;
        *)
            REALITY_DOMAIN="${USERNAME}.${DOMAIN}"
            ;;
    esac
    echo "$REALITY_DOMAIN" > "$WORKDIR/reym.txt"
    green "Reality域名: $REALITY_DOMAIN"
}



# 配置Argo隧道
configure_argo() {
    echo
    green "==== Argo隧道配置 ===="
    yellow "  1. 临时隧道 (回车默认) - 无需域名"
    yellow "  2. 固定隧道 - 需要CF Token"
    reading "请选择 1-2: " argo_choice
    
    if [[ "$argo_choice" == "2" || "$argo_choice" == "g" || "$argo_choice" == "G" ]]; then
        reading "请输入Argo固定隧道域名: " ARGO_DOMAIN
        echo "$ARGO_DOMAIN" > "$WORKDIR/ARGO_DOMAIN.log"
        green "Argo域名: $ARGO_DOMAIN"
        
        reading "请输入Argo固定隧道密钥 (Token/JSON): " ARGO_AUTH
        echo "$ARGO_AUTH" > "$WORKDIR/ARGO_AUTH.log"
        green "Argo密钥已保存"
        rm -f "$WORKDIR/boot.log"
    else
        green "使用Argo临时隧道"
        ARGO_DOMAIN=""
        ARGO_AUTH=""
        rm -f "$WORKDIR/ARGO_AUTH.log" "$WORKDIR/ARGO_DOMAIN.log"
    fi
}

# 选择协议
# 计算当前选择的端口占用
calculate_port_usage() {
    local tcp_count=0
    local udp_count=0
    
    # VMess-WS 直连需要 1 TCP (Trojan共用)
    [[ "$ENABLE_VMESS_WS" == "true" ]] && ((tcp_count++))
    
    # VLESS-Reality 需要 1 TCP
    [[ "$ENABLE_VLESS_REALITY" == "true" ]] && ((tcp_count++))
    
    # Hysteria2 需要 1 UDP
    [[ "$ENABLE_HYSTERIA2" == "true" ]] && ((udp_count++))
    
    # TUIC 需要 1 UDP
    [[ "$ENABLE_TUIC" == "true" ]] && ((udp_count++))
    
    # Shadowsocks 需要额外 1 TCP (如果没有VMess则独占，有VMess则+1)
    if [[ "$ENABLE_SHADOWSOCKS" == "true" ]]; then
        if [[ "$ENABLE_VMESS_WS" != "true" ]]; then
            ((tcp_count++))
        fi
        # SS 共用 VMess 端口 +1，不额外计算
    fi
    
    # AnyTLS 需要 1 TCP (v1.12+)
    [[ "$ENABLE_ANYTLS" == "true" ]] && ((tcp_count++))
    
    # Argo 不占端口
    # Trojan-WS 共用 VMess 端口，不额外计算
    
    echo "$((tcp_count + udp_count))"
}

# 选择协议 (支持端口限制)
select_protocols() {
    echo
    green "==== 选择要安装的协议 ===="
    echo
    
    # 判断端口限制
    local max_ports=99
    if [[ "$PLATFORM" == "serv00" ]] || [[ "$PLATFORM" == "ct8" ]]; then
        max_ports=3
        yellow "⚠ Serv00/CT8 端口限制: 最多 3 个端口"
        echo
        blue "端口占用说明:"
        blue "  • Argo隧道: 0 端口 (走CF隧道，推荐!)"
        blue "  • VLESS-Reality: 1 TCP"
        blue "  • VMess-WS直连: 1 TCP (Trojan共用此端口)"
        blue "  • Hysteria2: 1 UDP"
        blue "  • TUIC v5: 1 UDP"
        blue "  • Shadowsocks: 使用VMess端口"
        blue "  • AnyTLS: 1 TCP (v1.12+)"
        echo
        green "推荐组合 (3端口): Argo + VLESS + Hy2 + TUIC"
        echo
    fi
    
    # 初始化默认值
    ENABLE_ARGO=false
    ENABLE_VLESS_REALITY=false
    ENABLE_VMESS_WS=false
    ENABLE_TROJAN_WS=false
    ENABLE_HYSTERIA2=false
    ENABLE_TUIC=false
    ENABLE_SHADOWSOCKS=false
    ENABLE_ANYTLS=false
    
    yellow "选择安装方式:"
    yellow "  1. 使用推荐组合 (Argo + VLESS + Hy2 + TUIC)"
    yellow "  2. 自定义选择协议"
    reading "请选择 [1-2]: " install_mode
    
    if [[ "$install_mode" != "2" ]]; then
        # 推荐组合
        ENABLE_ARGO=true
        ENABLE_VLESS_REALITY=true
        ENABLE_HYSTERIA2=true
        ENABLE_TUIC=true
    else
        # 自定义选择 - 交互式菜单
        while true; do
            clear
            echo
            green "============================================================"
            green "  自定义协议选择 (Serv00 限制: $max_ports 端口)"
            green "============================================================"
            
            local current_ports=$(calculate_port_usage)
            
            if [[ $current_ports -gt $max_ports ]]; then
                red "当前端口占用: $current_ports / $max_ports ⚠ 超出限制!"
            elif [[ $current_ports -eq $max_ports ]]; then
                yellow "当前端口占用: $current_ports / $max_ports (已满)"
            else
                green "当前端口占用: $current_ports / $max_ports"
            fi
            echo
            
            purple "协议列表 (✓=已选, ✗=未选):"
            echo
            
            # 1. Argo (0端口)
            if [[ "$ENABLE_ARGO" == "true" ]]; then
                green "  [1] [✓] Argo隧道 (VMess-WS over CF) - 0端口 ★推荐"
            else
                yellow "  [1] [✗] Argo隧道 (VMess-WS over CF) - 0端口 ★推荐"
            fi
            
            # 2. VLESS-Reality (1 TCP)
            if [[ "$ENABLE_VLESS_REALITY" == "true" ]]; then
                green "  [2] [✓] VLESS-Reality - 1 TCP"
            else
                yellow "  [2] [✗] VLESS-Reality - 1 TCP"
            fi
            
            # 3. VMess-WS直连 (1 TCP)
            if [[ "$ENABLE_VMESS_WS" == "true" ]]; then
                green "  [3] [✓] VMess-WS (直连) - 1 TCP"
            else
                yellow "  [3] [✗] VMess-WS (直连) - 1 TCP"
            fi
            
            # 4. Trojan-WS (共用VMess端口)
            if [[ "$ENABLE_TROJAN_WS" == "true" ]]; then
                green "  [4] [✓] Trojan-WS - 共用VMess端口"
            else
                yellow "  [4] [✗] Trojan-WS - 共用VMess端口"
            fi
            
            # 5. Hysteria2 (1 UDP)
            if [[ "$ENABLE_HYSTERIA2" == "true" ]]; then
                green "  [5] [✓] Hysteria2 - 1 UDP ★推荐"
            else
                yellow "  [5] [✗] Hysteria2 - 1 UDP ★推荐"
            fi
            
            # 6. TUIC (1 UDP)
            if [[ "$ENABLE_TUIC" == "true" ]]; then
                green "  [6] [✓] TUIC v5 - 1 UDP ★推荐"
            else
                yellow "  [6] [✗] TUIC v5 - 1 UDP ★推荐"
            fi
            
            # 7. Shadowsocks (使用VMess端口)
            if [[ "$ENABLE_SHADOWSOCKS" == "true" ]]; then
                green "  [7] [✓] Shadowsocks-2022 - 使用VMess端口"
            else
                yellow "  [7] [✗] Shadowsocks-2022 - 使用VMess端口"
            fi
            
            # 8. AnyTLS (1 TCP)
            if [[ "$ENABLE_ANYTLS" == "true" ]]; then
                green "  [8] [✓] AnyTLS - 1 TCP (v1.12+)"
            else
                yellow "  [8] [✗] AnyTLS - 1 TCP (v1.12+)"
            fi
            
            echo
            echo "------------------------------------------------------------"
            blue "  a. 全选推荐组合 (Argo+VLESS+Hy2+TUIC)"
            blue "  n. 清空所有选择"
            green "  d. 完成选择，继续安装"
            echo "============================================================"
            echo
            reading "输入数字切换选择 [1-8/a/n/d]: " choice
            
            case "$choice" in
                1)
                    [[ "$ENABLE_ARGO" == "true" ]] && ENABLE_ARGO=false || ENABLE_ARGO=true
                    ;;
                2)
                    if [[ "$ENABLE_VLESS_REALITY" == "true" ]]; then
                        ENABLE_VLESS_REALITY=false
                    else
                        # 检查是否超出端口限制
                        ENABLE_VLESS_REALITY=true
                        if [[ $(calculate_port_usage) -gt $max_ports ]]; then
                            red "超出端口限制! 请先取消其他协议"
                            ENABLE_VLESS_REALITY=false
                            sleep 1
                        fi
                    fi
                    ;;
                3)
                    if [[ "$ENABLE_VMESS_WS" == "true" ]]; then
                        ENABLE_VMESS_WS=false
                        # 如果关闭VMess，Trojan也要关闭
                        ENABLE_TROJAN_WS=false
                    else
                        ENABLE_VMESS_WS=true
                        if [[ $(calculate_port_usage) -gt $max_ports ]]; then
                            red "超出端口限制! 请先取消其他协议"
                            ENABLE_VMESS_WS=false
                            sleep 1
                        fi
                    fi
                    ;;
                4)
                    if [[ "$ENABLE_VMESS_WS" != "true" ]]; then
                        yellow "Trojan需要先启用VMess-WS (共用端口)"
                        sleep 1
                    else
                        [[ "$ENABLE_TROJAN_WS" == "true" ]] && ENABLE_TROJAN_WS=false || ENABLE_TROJAN_WS=true
                    fi
                    ;;
                5)
                    if [[ "$ENABLE_HYSTERIA2" == "true" ]]; then
                        ENABLE_HYSTERIA2=false
                    else
                        ENABLE_HYSTERIA2=true
                        if [[ $(calculate_port_usage) -gt $max_ports ]]; then
                            red "超出端口限制! 请先取消其他协议"
                            ENABLE_HYSTERIA2=false
                            sleep 1
                        fi
                    fi
                    ;;
                6)
                    if [[ "$ENABLE_TUIC" == "true" ]]; then
                        ENABLE_TUIC=false
                    else
                        ENABLE_TUIC=true
                        if [[ $(calculate_port_usage) -gt $max_ports ]]; then
                            red "超出端口限制! 请先取消其他协议"
                            ENABLE_TUIC=false
                            sleep 1
                        fi
                    fi
                    ;;
                7)
                    if [[ "$ENABLE_VMESS_WS" != "true" ]]; then
                        yellow "Shadowsocks需要先启用VMess-WS (使用其端口)"
                        sleep 1
                    else
                        [[ "$ENABLE_SHADOWSOCKS" == "true" ]] && ENABLE_SHADOWSOCKS=false || ENABLE_SHADOWSOCKS=true
                    fi
                    ;;
                8)
                    if [[ "$ENABLE_ANYTLS" == "true" ]]; then
                        ENABLE_ANYTLS=false
                    else
                        ENABLE_ANYTLS=true
                        if [[ $(calculate_port_usage) -gt $max_ports ]]; then
                            red "超出端口限制! 请先取消其他协议"
                            ENABLE_ANYTLS=false
                            sleep 1
                        fi
                    fi
                    ;;
                a|A)
                    # 推荐组合
                    ENABLE_ARGO=true
                    ENABLE_VLESS_REALITY=true
                    ENABLE_VMESS_WS=false
                    ENABLE_TROJAN_WS=false
                    ENABLE_HYSTERIA2=true
                    ENABLE_TUIC=true
                    ENABLE_SHADOWSOCKS=false
                    ENABLE_ANYTLS=false
                    ;;
                n|N)
                    ENABLE_ARGO=false
                    ENABLE_VLESS_REALITY=false
                    ENABLE_VMESS_WS=false
                    ENABLE_TROJAN_WS=false
                    ENABLE_HYSTERIA2=false
                    ENABLE_TUIC=false
                    ENABLE_SHADOWSOCKS=false
                    ENABLE_ANYTLS=false
                    ;;
                d|D)
                    # 检查是否有选择
                    if [[ "$ENABLE_ARGO" != "true" ]] && [[ "$ENABLE_VLESS_REALITY" != "true" ]] && \
                       [[ "$ENABLE_VMESS_WS" != "true" ]] && [[ "$ENABLE_HYSTERIA2" != "true" ]] && \
                       [[ "$ENABLE_TUIC" != "true" ]] && [[ "$ENABLE_ANYTLS" != "true" ]]; then
                        red "请至少选择一个协议!"
                        sleep 1
                        continue
                    fi
                    # 检查端口是否超限
                    if [[ $(calculate_port_usage) -gt $max_ports ]]; then
                        red "端口超出限制! 请调整选择"
                        sleep 1
                        continue
                    fi
                    break
                    ;;
                *)
                    red "无效选项"
                    sleep 0.5
                    ;;
            esac
        done
    fi
    echo
    green "已启用的协议:"
    [[ "$ENABLE_ARGO" == "true" ]] && purple "  ✓ Argo隧道 (0端口)"
    [[ "$ENABLE_VLESS_REALITY" == "true" ]] && purple "  ✓ VLESS-Reality (1 TCP)"
    [[ "$ENABLE_VMESS_WS" == "true" ]] && purple "  ✓ VMess-WS (1 TCP)"
    [[ "$ENABLE_TROJAN_WS" == "true" ]] && purple "  ✓ Trojan-WS (共用VMess端口)"
    [[ "$ENABLE_HYSTERIA2" == "true" ]] && purple "  ✓ Hysteria2 (1 UDP)"
    [[ "$ENABLE_TUIC" == "true" ]] && purple "  ✓ TUIC v5 (1 UDP)"
    [[ "$ENABLE_SHADOWSOCKS" == "true" ]] && purple "  ✓ Shadowsocks-2022 (共用VMess端口)"
    [[ "$ENABLE_ANYTLS" == "true" ]] && purple "  ✓ AnyTLS (1 TCP)"
    
    green "端口占用: $(calculate_port_usage) 个"
    
    # 询问 WARP 出站配置
    ask_warp_outbound
}

# 生成sing-box配置
generate_singbox_config() {
    cd "$WORKDIR"
    
    # 生成SS密码
    SS_PASSWORD=$(openssl rand -base64 16)
    
    # 开始构建配置
    cat > config.json <<EOF
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
EOF

    # 构建inbounds数组
    inbounds=()
    
    # Hysteria2 - 为每个IP创建监听
    if [[ "$ENABLE_HYSTERIA2" == "true" ]]; then
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            inbounds+=("    {
      \"tag\": \"hysteria2-in-$idx\",
      \"type\": \"hysteria2\",
      \"listen\": \"$ip\",
      \"listen_port\": $HY2_PORT,
      \"users\": [{\"password\": \"$UUID\"}],
      \"masquerade\": \"https://www.bing.com\",
      \"ignore_client_bandwidth\": false,
      \"tls\": {
        \"enabled\": true,
        \"alpn\": [\"h3\"],
        \"certificate_path\": \"cert.pem\",
        \"key_path\": \"private.key\"
      }
    }")
            ((idx++))
        done
    fi
    
    # VLESS Reality
    if [[ "$ENABLE_VLESS_REALITY" == "true" ]]; then
        inbounds+=("    {
      \"tag\": \"vless-reality-in\",
      \"type\": \"vless\",
      \"listen\": \"::\",
      \"listen_port\": $VLESS_PORT,
      \"users\": [{
        \"uuid\": \"$UUID\",
        \"flow\": \"xtls-rprx-vision\"
      }],
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"$REALITY_DOMAIN\",
        \"reality\": {
          \"enabled\": true,
          \"handshake\": {
            \"server\": \"$REALITY_DOMAIN\",
            \"server_port\": 443
          },
          \"private_key\": \"$REALITY_PRIVATE_KEY\",
          \"short_id\": [\"\"]
        }
      }
    }")
    fi
    
    # VMess WS
    if [[ "$ENABLE_VMESS_WS" == "true" ]] || [[ "$ENABLE_ARGO" == "true" ]]; then
        inbounds+=("    {
      \"tag\": \"vmess-ws-in\",
      \"type\": \"vmess\",
      \"listen\": \"::\",
      \"listen_port\": $VMESS_PORT,
      \"users\": [{\"uuid\": \"$UUID\"}],
      \"transport\": {
        \"type\": \"ws\",
        \"path\": \"/$UUID-vm\",
        \"early_data_header_name\": \"Sec-WebSocket-Protocol\"
      }
    }")
    fi
    
    # Trojan WS
    if [[ "$ENABLE_TROJAN_WS" == "true" ]]; then
        inbounds+=("    {
      \"tag\": \"trojan-ws-in\",
      \"type\": \"trojan\",
      \"listen\": \"::\",
      \"listen_port\": $VMESS_PORT,
      \"users\": [{\"password\": \"$UUID\"}],
      \"transport\": {
        \"type\": \"ws\",
        \"path\": \"/$UUID-tr\"
      },
      \"tls\": {
        \"enabled\": true,
        \"certificate_path\": \"cert.pem\",
        \"key_path\": \"private.key\"
      }
    }")
    fi
    
    # TUIC v5 - 为每个IP创建监听
    if [[ "$ENABLE_TUIC" == "true" ]]; then
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            inbounds+=("    {
      \"tag\": \"tuic-in-$idx\",
      \"type\": \"tuic\",
      \"listen\": \"$ip\",
      \"listen_port\": $TUIC_PORT,
      \"users\": [{
        \"uuid\": \"$UUID\",
        \"password\": \"$UUID\"
      }],
      \"congestion_control\": \"bbr\",
      \"tls\": {
        \"enabled\": true,
        \"alpn\": [\"h3\"],
        \"certificate_path\": \"cert.pem\",
        \"key_path\": \"private.key\"
      }
    }")
            ((idx++))
        done
    fi
    
    # Shadowsocks 2022
    if [[ "$ENABLE_SHADOWSOCKS" == "true" ]]; then
        inbounds+=("    {
      \"tag\": \"ss-in\",
      \"type\": \"shadowsocks\",
      \"listen\": \"::\",
      \"listen_port\": $((VMESS_PORT + 1)),
      \"method\": \"2022-blake3-aes-128-gcm\",
      \"password\": \"$SS_PASSWORD\"
    }")
    fi
    
    # AnyTLS - 为每个IP创建监听 (v1.12+)
    if [[ "$ENABLE_ANYTLS" == "true" ]]; then
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            inbounds+=("    {
      \"tag\": \"anytls-in-$idx\",
      \"type\": \"anytls\",
      \"listen\": \"$ip\",
      \"listen_port\": $ANYTLS_PORT,
      \"users\": [{\"name\": \"default\", \"password\": \"$UUID\"}],
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"www.bing.com\",
        \"certificate_path\": \"cert.pem\",
        \"key_path\": \"private.key\"
      }
    }")
            ((idx++))
        done
    fi
    
    # 如果启用 WARP，添加回环 Socks 入站用于出口 IP 检测
    # 注意: FreeBSD mac_portacl 只允许绑定 devil 已注册端口, get_free_loopback_port
    # 会优先从已注册端口挑选; 若全部被占(返回31092兜底), 跳过注入避免启动失败
    if [[ "$WARP_ENABLED" == "true" ]]; then
        local loopback_port
        loopback_port=$(get_free_loopback_port)
        local lp_rc=$?
        if [[ "$loopback_port" != "31092" ]] || devil port list 2>/dev/null | grep -qw "31092"; then
            inbounds+=("    {
      \"tag\": \"socks-loopback\",
      \"type\": \"socks\",
      \"listen\": \"127.0.0.1\",
      \"listen_port\": $loopback_port
    }")
        else
            yellow "[!] 无可用已注册端口用于 socks-loopback，跳过注入 (WARP 出口检测不可用)"
        fi
    fi
    
    # 用逗号连接inbounds
    IFS=','
    echo "${inbounds[*]}" >> config.json
    unset IFS

    
    # 关闭inbounds并添加outbounds
    cat >> config.json <<EOF
  ],
EOF

    # 获取 WARP endpoint (优先使用优选的)
    local warp_endpoint=$(get_warp_endpoint)
    local warp_port=$(cat "$WORKDIR/warp_best_port.txt" 2>/dev/null)
    warp_port=${warp_port:-2408}
    local warp_ipv6="${WARP_IPV6:-2606:4700:110:8d8d:1845:c39f:2dd5:a03a}"
    local warp_private_key="${WARP_PRIVATE_KEY:-52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A=}"
    local warp_reserved="${WARP_RESERVED:-[215, 69, 233]}"

    # 根据 WARP 配置生成 outbounds
    if [[ "$WARP_ENABLED" == "true" ]] && [[ "$WARP_MODE" == "all" ]]; then
        # 全部流量走 WARP
        yellow "配置: 全部流量通过 WARP 出站"
        cat >> config.json <<EOF
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "wireguard",
      "tag": "warp-out",
      "server": "$warp_endpoint",
      "server_port": $warp_port,
      "local_address": [
        "172.16.0.2/32",
        "${warp_ipv6}/128"
      ],
      "private_key": "${warp_private_key}",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "reserved": ${warp_reserved}
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["socks-loopback"],
        "outbound": "warp-out"
      }
    ],
    "final": "warp-out"
  }
}
EOF
    elif [[ "$WARP_ENABLED" == "true" ]] && [[ "$WARP_MODE" == "google" ]]; then
        # 仅 Google/YouTube 走 WARP
        yellow "配置: Google/YouTube 通过 WARP 出站"
        cat >> config.json <<EOF
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "wireguard",
      "tag": "warp-out",
      "server": "$warp_endpoint",
      "server_port": $warp_port,
      "local_address": [
        "172.16.0.2/32",
        "${warp_ipv6}/128"
      ],
      "private_key": "${warp_private_key}",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "reserved": ${warp_reserved}
    }
  ],
  "route": {
    "rule_set": [
      {
        "tag": "youtube",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs",
        "download_detour": "direct"
      },
      {
        "tag": "google",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs",
        "download_detour": "direct"
      },
      {
        "tag": "openai",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs",
        "download_detour": "direct"
      },
      {
        "tag": "netflix",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/netflix.srs",
        "download_detour": "direct"
      }
    ],
    "rules": [
      {
        "inbound": ["socks-loopback"],
        "outbound": "warp-out"
      },
      {
        "rule_set": ["google", "youtube", "openai", "netflix"],
        "outbound": "warp-out"
      }
    ],
    "final": "direct"
  }
}
EOF
    elif [[ "$HOSTNAME" =~ s14|s15 ]]; then
        # 特殊服务器(s14/s15)保留原有逻辑
        yellow "S14/S15服务器: 使用默认WARP分流 (Google/YouTube)"
        cat >> config.json <<EOF
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    },
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "server": "162.159.192.200",
      "server_port": 4500,
      "local_address": [
        "172.16.0.2/32",
        "2606:4700:110:8f77:1ca9:f086:846c:5f9e/128"
      ],
      "private_key": "wIxszdR2nMdA7a2Ul3XQcniSfSZqdqjPb6w6opvf5AU=",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "reserved": [126, 246, 173]
    }
  ],
  "route": {
    "rule_set": [
      {
        "tag": "youtube",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs",
        "download_detour": "direct"
      },
      {
        "tag": "google",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs",
        "download_detour": "direct"
      }
    ],
    "rules": [
      {
        "inbound": ["socks-loopback"],
        "outbound": "wireguard-out"
      },
      {
        "rule_set": ["google", "youtube"],
        "outbound": "wireguard-out"
      }
    ],
    "final": "direct"
  }
}
EOF
    else
        # 默认直连出站
        cat >> config.json <<EOF
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}
EOF
    fi
    
    # 保存SS密码
    echo "$SS_PASSWORD" > "$WORKDIR/ss_password.txt"
    
    # 自动恢复挂载所有已配置的副节点 (赛风多出口组与自定义代理组，确保主副节点互不丢失)
    sync_all_secondary_nodes
    
    green "主节点基础配置已生成，已完成副节点平行合并"
}

# ==================== 副节点平行合并同步函数 ====================
# 同步所有副节点 (赛风多出口组 + 自定义代理组) 到 sing-box 配置
sync_all_secondary_nodes() {
    local cfg="$WORKDIR/config.json"
    [[ -f "$cfg" ]] || return 0

    # 1. 恢复赛风多出口副节点
    if [[ -f "$WORKDIR/egress_node_groups.txt" ]] && [[ -s "$WORKDIR/egress_node_groups.txt" ]]; then
        local psi_groups
        psi_groups="$(cat "$WORKDIR/egress_node_groups.txt" 2>/dev/null)"
        IFS=',' read -ra cc_arr <<< "$psi_groups"
        for cc in "${cc_arr[@]}"; do
            cc="$(echo "$cc" | tr '[:upper:]' '[:lower:]' | xargs)"
            [[ -z "$cc" ]] && continue
            local vless_p=$(cat "$PSI_INSTANCES_DIR/${cc^^}/vless_port.txt" 2>/dev/null || echo "0")
            local hy2_p=$(cat "$PSI_INSTANCES_DIR/${cc^^}/hy2_port.txt" 2>/dev/null || echo "0")
            local tuic_p=$(cat "$PSI_INSTANCES_DIR/${cc^^}/tuic_port.txt" 2>/dev/null || echo "0")
            local psi_p=$(get_instance_socks_port "${cc^^}")
            if [[ -n "$psi_p" && "$psi_p" != "0" ]]; then
                sync_egress_group_to_singbox "${cc^^}" "$vless_p" "$hy2_p" "$tuic_p" "$psi_p" >/dev/null 2>&1 || true
            fi
        done
    fi

    # 2. 恢复自定义代理副节点
    if [[ -d "$PROXY_GROUPS_DIR" ]]; then
        sync_all_proxy_groups >/dev/null 2>&1 || true
    fi

    # 3. 去重防御: 全部副节点合并完成后，清理 config.json 中重复的 inbound
    #    (同 tag 或同 (listen, listen_port, type))，防止 sing-box 启动时
    #    bind 冲突报 "address already in use"
    dedup_inbounds_in_config
}

# ==================== inbounds 去重防御 ====================
# 防止 config.json 内出现重复 inbound (同 tag 或同 listen+listen_port+type)，
# 该问题会导致 sing-box 按序绑定时第二个 inbound 报 "address already in use"。
# 与 upstream apply_changes 的 jq unique_by(.tag) 对齐，serv00 版用 python3
# (保留原始顺序，仅按 key 去重，不影响订阅生成时的节点顺序)
dedup_inbounds_in_config() {
    [ -f "$WORKDIR/config.json" ] || return 0

    python3 - <<PY 2>/dev/null
import json

cfg = r"$WORKDIR/config.json"
try:
    with open(cfg, "r", encoding="utf-8") as f:
        data = json.load(f)
    ibs = data.get("inbounds", [])
    if not isinstance(ibs, list) or len(ibs) <= 1:
        raise SystemExit(0)

    seen_addr = set()   # (listen, listen_port, type) 唯一，防端口冲突
    seen_tag = set()    # tag 唯一，对齐 upstream unique_by(.tag)
    out = []
    removed = 0
    for ib in ibs:
        if not isinstance(ib, dict):
            out.append(ib)
            continue
        tag = ib.get("tag") or ""
        addr_key = (ib.get("listen") or "::", ib.get("listen_port"), ib.get("type"))
        if addr_key in seen_addr:
            removed += 1
            continue
        if tag and tag in seen_tag:
            removed += 1
            continue
        seen_addr.add(addr_key)
        if tag:
            seen_tag.add(tag)
        out.append(ib)

    if removed:
        data["inbounds"] = out
        with open(cfg, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print("[i] inbounds 去重: 移除 %d 个重复 inbound (同 tag 或同 listen+port+type)" % removed)
except SystemExit:
    pass
except Exception as e:
    print("[!] inbounds 去重跳过: %s" % e)
PY
}

# ==================== 全量端口重置 (核武器级回退) ====================
# 当个别端口修复失败时触发：删除所有端口 → 主节点用 all-IP 检查 → 代理组用单 IP 检查+端口复用
full_port_reset_and_realloc() {
    yellow "============================================"
    yellow "[!] 个别端口修复失败，执行全量端口重置..."
    yellow "============================================"
    
    # 0. 停止 sing-box (使用精确路径匹配，避免误杀)
    local sb_binary=$(cat "$WORKDIR/sb.txt" 2>/dev/null)
    if [[ -n "$sb_binary" ]]; then
        pkill -f "$WORKDIR/$sb_binary" >/dev/null 2>&1 || true
        pkill -x "$sb_binary" >/dev/null 2>&1 || true
    fi
    sleep 1
    
    # 1. 删除所有 devil 端口
    yellow "[1/5] 删除所有现有端口..."
    local portlist=$(devil port list 2>/dev/null | grep -E '^[0-9]+[[:space:]]+[a-zA-Z]+' | sed 's/^[[:space:]]*//')
    if [[ -n "$portlist" ]]; then
        while read -r line; do
            local dp=$(echo "$line" | awk '{print $1}')
            local dt=$(echo "$line" | awk '{print $2}')
            devil port del "$dt" "$dp" >/dev/null 2>&1
            yellow "  已删除: $dp ($dt)"
        done <<< "$portlist"
    fi
    sleep 1
    
    # 2. 重新获取 IP 列表和配置
    yellow "[2/5] 重新获取 IP 列表..."
    get_all_ips 2>/dev/null || true
    load_saved_config 2>/dev/null || true
    
    if [[ ${#ALL_IPS[@]} -eq 0 ]]; then
        red "[!] 无法获取本机 IP 列表，全量重置失败"
        return 2
    fi
    
    local all_reset_ok=true
    
    # 3. 分配主节点端口（必须在所有 IP 上可 bind）
    yellow "[3/5] 分配主节点端口 (需在 ${#ALL_IPS[@]} 个 IP 上均可 bind)..."
    
    if [[ "$ENABLE_VMESS_WS" == "true" || "$ENABLE_TROJAN_WS" == "true" ]]; then
        local new_vmess=$(alloc_new_port_all_ips "tcp" "singbox-vmess")
        if [[ "$new_vmess" =~ ^[0-9]+$ ]]; then
            export VMESS_PORT=$new_vmess
            green "  VMess 主端口: $VMESS_PORT (TCP, ${#ALL_IPS[@]} IP 可用)"
        else
            red "  VMess 主端口分配失败"
            all_reset_ok=false
        fi
    fi
    
    if [[ "$ENABLE_VLESS_REALITY" == "true" ]]; then
        local new_vless=$(alloc_new_port_all_ips "tcp" "singbox-vless")
        if [[ "$new_vless" =~ ^[0-9]+$ ]]; then
            export VLESS_PORT=$new_vless
            green "  VLESS 主端口: $VLESS_PORT (TCP, ${#ALL_IPS[@]} IP 可用)"
        else
            red "  VLESS 主端口分配失败"
            all_reset_ok=false
        fi
    fi
    
    if [[ "$ENABLE_HYSTERIA2" == "true" ]]; then
        local new_hy2=$(alloc_new_port_all_ips "udp" "singbox-hy2")
        if [[ "$new_hy2" =~ ^[0-9]+$ ]]; then
            export HY2_PORT=$new_hy2
            green "  Hysteria2 主端口: $HY2_PORT (UDP, ${#ALL_IPS[@]} IP 可用)"
        else
            red "  Hysteria2 主端口分配失败"
            all_reset_ok=false
        fi
    fi
    
    if [[ "$ENABLE_TUIC" == "true" ]]; then
        local new_tuic=$(alloc_new_port_all_ips "udp" "singbox-tuic")
        if [[ "$new_tuic" =~ ^[0-9]+$ ]]; then
            export TUIC_PORT=$new_tuic
            green "  TUIC 主端口: $TUIC_PORT (UDP, ${#ALL_IPS[@]} IP 可用)"
        else
            red "  TUIC 主端口分配失败"
            all_reset_ok=false
        fi
    fi
    
    # 4. 分配代理组端口（端口复用模式: 单 IP 绑定, 同端口可跨不同 IP 复用）
    yellow "[4/5] 分配代理组端口 (端口复用: 单 IP 绑定, 同端口可跨不同 IP 复用)..."
    
    # 可用端口池 (预先包含主节点端口，支持跨 IP / 多代理组智能复用)
    local available_hy2_ports=()
    local available_tuic_ports=()
    [[ -n "$HY2_PORT" && "$HY2_PORT" =~ ^[0-9]+$ ]] && available_hy2_ports+=("$HY2_PORT")
    [[ -n "$TUIC_PORT" && "$TUIC_PORT" =~ ^[0-9]+$ ]] && available_tuic_ports+=("$TUIC_PORT")

    # 追踪已分配的 (port,ip) 对，防止同端口同 IP 冲突
    local port_ip_map=()
    local proxy_all_ok=true

    local group_tags
    group_tags=$(get_all_proxy_groups 2>/dev/null || true)
    
    if [[ -n "$group_tags" ]]; then
        for gtag in $group_tags; do
            local g_dir="${PROXY_GROUPS_DIR}/${gtag}"
            [[ ! -d "$g_dir" ]] && continue
            [[ ! -f "$g_dir/ip_protos.txt" ]] && continue
            
            local need_hy2=false need_tuic=false
            local hy2_ips=() tuic_ips=()
            
            while IFS='|' read -r ip proto; do
                [[ -z "$ip" ]] && continue
                case "$proto" in
                    hy2)  need_hy2=true;  hy2_ips+=("$ip")  ;;
                    tuic) need_tuic=true; tuic_ips+=("$ip") ;;
                    both) need_hy2=true;  hy2_ips+=("$ip")
                          need_tuic=true; tuic_ips+=("$ip") ;;
                esac
            done < "$g_dir/ip_protos.txt"
            
            # --- Hy2 端口 ---
            if [[ "$need_hy2" == "true" && ${#hy2_ips[@]} -gt 0 ]]; then
                local hy2_port=""
                # 1. 尝试复用已有可用端口 (在绑定的 IP 上无映射冲突)
                for cand_p in "${available_hy2_ports[@]}"; do
                    local can_reuse=true
                    for ip in "${hy2_ips[@]}"; do
                        if ! check_port_available_on_ip "$cand_p" "udp" "$ip"; then
                            can_reuse=false; break
                        fi
                        for m2 in "${port_ip_map[@]}"; do
                            [[ "$m2" == "${cand_p}|${ip}" ]] && { can_reuse=false; break; }
                        done
                        [[ "$can_reuse" == "false" ]] && break
                    done
                    if [[ "$can_reuse" == "true" ]]; then
                        hy2_port="$cand_p"
                        break
                    fi
                done
                # 2. 无法复用且额度未满，尝试申请新端口
                if [[ -z "$hy2_port" ]]; then
                    local retry=0
                    while [[ $retry -lt 40 && -z "$hy2_port" ]]; do
                        local cand=$(shuf -i 10000-65535 -n 1)
                        local can_use=true
                        for ip in "${hy2_ips[@]}"; do
                            check_port_available_on_ip "$cand" "udp" "$ip" || { can_use=false; break; }
                        done
                        if [[ "$can_use" == "true" ]]; then
                            local res=$(devil port add udp "$cand" "singbox-proxy-hy2" 2>&1)
                            local ec=$?
                            if [[ $ec -eq 0 ]] && ! echo "$res" | grep -qiE 'błąd|error|limit|istnieje|fail'; then
                                hy2_port="$cand"
                                available_hy2_ports+=("$cand")
                            fi
                        fi
                        ((retry++))
                    done
                fi
                # 3. 智能 Fallback: 如果端口额度受限 (limit) 导致申请新端口失败，退回复用已有端口
                if [[ -z "$hy2_port" && ${#available_hy2_ports[@]} -gt 0 ]]; then
                    hy2_port="${available_hy2_ports[0]}"
                    yellow "  [!] 代理组 [$gtag] 端口配额已满，自动退回复用端口: $hy2_port"
                fi

                if [[ -n "$hy2_port" ]]; then
                    echo "$hy2_port" > "$g_dir/hy2_port.txt"
                    for ip in "${hy2_ips[@]}"; do port_ip_map+=("${hy2_port}|${ip}"); done
                    green "  → 代理组 [$gtag] Hy2: $hy2_port (IP: ${hy2_ips[*]})"
                else
                    red "  [!] 代理组 [$gtag] Hy2 端口分配失败"
                    proxy_all_ok=false
                fi
            fi
            
            # --- TUIC 端口 ---
            if [[ "$need_tuic" == "true" && ${#tuic_ips[@]} -gt 0 ]]; then
                local tuic_port=""
                # 1. 尝试复用已有可用端口 (在绑定的 IP 上无映射冲突)
                for cand_p in "${available_tuic_ports[@]}"; do
                    local can_reuse=true
                    for ip in "${tuic_ips[@]}"; do
                        if ! check_port_available_on_ip "$cand_p" "udp" "$ip"; then
                            can_reuse=false; break
                        fi
                        for m2 in "${port_ip_map[@]}"; do
                            [[ "$m2" == "${cand_p}|${ip}" ]] && { can_reuse=false; break; }
                        done
                        [[ "$can_reuse" == "false" ]] && break
                    done
                    if [[ "$can_reuse" == "true" ]]; then
                        tuic_port="$cand_p"
                        break
                    fi
                done
                # 2. 无法复用且额度未满，尝试申请新端口
                if [[ -z "$tuic_port" ]]; then
                    local retry=0
                    while [[ $retry -lt 40 && -z "$tuic_port" ]]; do
                        local cand=$(shuf -i 10000-65535 -n 1)
                        local can_use=true
                        for ip in "${tuic_ips[@]}"; do
                            check_port_available_on_ip "$cand" "udp" "$ip" || { can_use=false; break; }
                        done
                        if [[ "$can_use" == "true" ]]; then
                            local res=$(devil port add udp "$cand" "singbox-proxy-tuic" 2>&1)
                            local ec=$?
                            if [[ $ec -eq 0 ]] && ! echo "$res" | grep -qiE 'błąd|error|limit|istnieje|fail'; then
                                tuic_port="$cand"
                                available_tuic_ports+=("$cand")
                            fi
                        fi
                        ((retry++))
                    done
                fi
                # 3. 智能 Fallback: 如果端口额度受限 (limit) 导致申请新端口失败，退回复用已有端口
                if [[ -z "$tuic_port" && ${#available_tuic_ports[@]} -gt 0 ]]; then
                    tuic_port="${available_tuic_ports[0]}"
                    yellow "  [!] 代理组 [$gtag] 端口配额已满，自动退回复用端口: $tuic_port"
                fi

                if [[ -n "$tuic_port" ]]; then
                    echo "$tuic_port" > "$g_dir/tuic_port.txt"
                    for ip in "${tuic_ips[@]}"; do port_ip_map+=("${tuic_port}|${ip}"); done
                    green "  → 代理组 [$gtag] TUIC: $tuic_port (IP: ${tuic_ips[*]})"
                else
                    red "  [!] 代理组 [$gtag] TUIC 端口分配失败"
                    proxy_all_ok=false
                fi
            fi
        done
    else
        yellow "  无代理组，跳过"
    fi
    
    # 5. 保存配置并重新生成
    yellow "[5/5] 保存配置并重新生成 config.json..."
    
    cat > "$WORKDIR/ports.txt" <<EOF
VMESS_PORT=${VMESS_PORT:-}
VLESS_PORT=${VLESS_PORT:-}
HY2_PORT=${HY2_PORT:-}
TUIC_PORT=${TUIC_PORT:-}
EOF
    
    generate_singbox_config 2>/dev/null || { red "[!] config.json 生成失败"; all_reset_ok=false; }
    
    if [[ -n "$group_tags" ]]; then
        sync_all_proxy_groups 2>/dev/null || true
    fi
    
    if [[ "$all_reset_ok" == "true" && "$proxy_all_ok" == "true" ]]; then
        green "============================================"
        green "[✓] 全量端口重置完成！"
        green "============================================"
        return 0
    else
        red "============================================"
        red "[!] 全量端口重置部分失败，请检查端口额度是否充足"
        red "============================================"
        return 2
    fi
}

# 自动探测冲突端口: 先申请 3 地址可用新端口 -> 删除原端口 -> 将原端口绑定的 3 地址节点更新为新端口
auto_repair_conflicting_ports() {
    load_saved_config 2>/dev/null || true
    get_all_ips 2>/dev/null || true
    init_proxy_groups_dir 2>/dev/null || true

    local repaired_main=false
    local repaired_proxy=false

    # ---------------- 1. 检测与更换主节点 4 大端口 ----------------
    if [ -n "$VMESS_PORT" ] && ! check_port_available_all_ips "$VMESS_PORT" "tcp"; then
        yellow "[!] VMess 主端口 $VMESS_PORT (TCP) 部分 IP 不可用，更换中..."
        local old_vmess=$VMESS_PORT
        local new_p=$(replace_occupied_port "tcp" "singbox-vmess" "$VMESS_PORT")
        if [[ "$new_p" =~ ^[0-9]+$ ]]; then
            export VMESS_PORT=$new_p
            relink_proxy_refs "$old_vmess" "$new_p"
            repaired_main=true
            green "  → 已申请新端口并更新 VMess 主节点端口: $VMESS_PORT"
        else
            red "  [!] VMess 主端口修复失败，触发全量端口重置..."
            full_port_reset_and_realloc
            return $?
        fi
    fi

    if [ -n "$VLESS_PORT" ] && ! check_port_available_all_ips "$VLESS_PORT" "tcp"; then
        yellow "[!] VLESS 主端口 $VLESS_PORT (TCP) 部分 IP 不可用，更换中..."
        local old_vless=$VLESS_PORT
        local new_p=$(replace_occupied_port "tcp" "singbox-vless" "$VLESS_PORT")
        if [[ "$new_p" =~ ^[0-9]+$ ]]; then
            export VLESS_PORT=$new_p
            relink_proxy_refs "$old_vless" "$new_p"
            repaired_main=true
            green "  → 已申请新端口并更新 VLESS 主节点端口: $VLESS_PORT"
        else
            red "  [!] VLESS 主端口修复失败，触发全量端口重置..."
            full_port_reset_and_realloc
            return $?
        fi
    fi

    if [ -n "$HY2_PORT" ] && ! check_port_available_all_ips "$HY2_PORT" "udp"; then
        yellow "[!] Hysteria2 主端口 $HY2_PORT (UDP) 部分 IP 不可用，更换中..."
        local old_hy2main=$HY2_PORT
        local new_p=$(replace_occupied_port "udp" "singbox-hy2" "$HY2_PORT")
        if [[ "$new_p" =~ ^[0-9]+$ ]]; then
            export HY2_PORT=$new_p
            relink_proxy_refs "$old_hy2main" "$new_p"
            repaired_main=true
            green "  → 已申请新端口并更新 Hysteria2 主节点端口: $HY2_PORT"
        else
            red "  [!] Hysteria2 主端口修复失败，触发全量端口重置..."
            full_port_reset_and_realloc
            return $?
        fi
    fi

    if [ -n "$TUIC_PORT" ] && ! check_port_available_all_ips "$TUIC_PORT" "udp"; then
        yellow "[!] TUIC 主端口 $TUIC_PORT (UDP) 部分 IP 不可用，更换中..."
        local old_tuicmain=$TUIC_PORT
        local new_p=$(replace_occupied_port "udp" "singbox-tuic" "$TUIC_PORT")
        if [[ "$new_p" =~ ^[0-9]+$ ]]; then
            export TUIC_PORT=$new_p
            relink_proxy_refs "$old_tuicmain" "$new_p"
            repaired_main=true
            green "  → 已申请新端口并更新 TUIC 主节点端口: $TUIC_PORT"
        else
            red "  [!] TUIC 主端口修复失败，触发全量端口重置..."
            full_port_reset_and_realloc
            return $?
        fi
    fi

    # ---------------- 2. 检测与更换自定义代理出站多出口路由管理节点的端口 ----------------
    # 代理组使用端口复用模式：每个入站只绑定单一 IP，同端口可在不同 IP 上复用
    # 因此检查时只需校验端口在对应绑定 IP 上是否可用（而非全部 IP）
    local group_tags
    group_tags=$(get_all_proxy_groups 2>/dev/null || true)
    if [ -n "$group_tags" ]; then
        for gtag in $group_tags; do
            local g_dir="${PROXY_GROUPS_DIR}/${gtag}"
            [ ! -d "$g_dir" ] && continue

            local g_hy2=$(cat "$g_dir/hy2_port.txt" 2>/dev/null || echo "0")
            local g_tuic=$(cat "$g_dir/tuic_port.txt" 2>/dev/null || echo "0")

            # 读取该组的 IP 绑定关系
            local hy2_ips=() tuic_ips=()
            if [[ -f "$g_dir/ip_protos.txt" ]]; then
                while IFS='|' read -r ip proto; do
                    [[ -z "$ip" ]] && continue
                    case "$proto" in
                        hy2)  hy2_ips+=("$ip")  ;;
                        tuic) tuic_ips+=("$ip") ;;
                        both) hy2_ips+=("$ip"); tuic_ips+=("$ip") ;;
                    esac
                done < "$g_dir/ip_protos.txt"
            fi

            # 检查代理组 Hysteria2 端口 (仅检查绑定的 IP)
            if [ -n "$g_hy2" ] && [ "$g_hy2" != "0" ]; then
                local hy2_need_repair=false
                if [[ ${#hy2_ips[@]} -gt 0 ]]; then
                    for ip in "${hy2_ips[@]}"; do
                        check_port_available_on_ip "$g_hy2" "udp" "$ip" || { hy2_need_repair=true; break; }
                    done
                else
                    # 无 ip_protos.txt 或没有 hy2 绑定 → 回退到全 IP 检查
                    check_port_available_all_ips "$g_hy2" "udp" || hy2_need_repair=true
                fi
                if [[ "$hy2_need_repair" == "true" ]]; then
                    yellow "[!] 代理组 [$gtag] 的 Hysteria2 端口 $g_hy2 (UDP) 在绑定 IP 上不可用，联动换组中..."
                    # 端口号可能被多组共享(同端口×多IP, 各走不同出站), 必须按端口号整体联动换
                    # 而不是只换当前组 — 否则端口复用链断裂, 其他共享组仍引用旧端口继续冲突
                    if repair_port_group_unified "udp" "$g_hy2"; then
                        repaired_proxy=true
                    elif [[ -n "$HY2_PORT" && "$HY2_PORT" =~ ^[0-9]+$ ]]; then
                        echo "$HY2_PORT" > "$g_dir/hy2_port.txt"
                        repaired_proxy=true
                        yellow "  → 联动修复失败，代理组 [$gtag] 退回使用 Hysteria2 主节点端口: $HY2_PORT"
                    else
                        red "  [!] 代理组 [$gtag] Hy2 端口修复失败，触发全量端口重置..."
                        full_port_reset_and_realloc
                        return $?
                    fi
                fi
            fi

            # 检查代理组 TUIC 端口 (仅检查绑定的 IP)
            if [ -n "$g_tuic" ] && [ "$g_tuic" != "0" ]; then
                local tuic_need_repair=false
                if [[ ${#tuic_ips[@]} -gt 0 ]]; then
                    for ip in "${tuic_ips[@]}"; do
                        check_port_available_on_ip "$g_tuic" "udp" "$ip" || { tuic_need_repair=true; break; }
                    done
                else
                    check_port_available_all_ips "$g_tuic" "udp" || tuic_need_repair=true
                fi
                if [[ "$tuic_need_repair" == "true" ]]; then
                    yellow "[!] 代理组 [$gtag] 的 TUIC 端口 $g_tuic (UDP) 在绑定 IP 上不可用，联动换组中..."
                    if repair_port_group_unified "udp" "$g_tuic"; then
                        repaired_proxy=true
                    elif [[ -n "$TUIC_PORT" && "$TUIC_PORT" =~ ^[0-9]+$ ]]; then
                        echo "$TUIC_PORT" > "$g_dir/tuic_port.txt"
                        repaired_proxy=true
                        yellow "  → 联动修复失败，代理组 [$gtag] 退回使用 TUIC 主节点端口: $TUIC_PORT"
                    else
                        red "  [!] 代理组 [$gtag] TUIC 端口修复失败，触发全量端口重置..."
                        full_port_reset_and_realloc
                        return $?
                    fi
                fi
            fi
        done
    fi

    # ---------------- 3. 从日志集中提取冲突端口，逐端口联动修复 ----------------
    # 日志修复是最后防线：sections 1/2 已做了主动检查，如果日志中仍有端口冲突，
    # 说明存在遗漏的端口绑定问题。此时按端口号联动修复(只动共享该端口的那一组)，
    # 只有联动修复也失败时才触发全量重置。
    if [ -f "$WORKDIR/singbox.log" ]; then
        local err_ports
        err_ports=$(grep -E "address already in use|bind: address already in use" "$WORKDIR/singbox.log" 2>/dev/null | grep -oE ":[0-9]+" | tr -d ':' | sort -u || true)
        
        if [ -n "$err_ports" ]; then
            yellow "[!] 日志中发现端口冲突: $(echo "$err_ports" | tr '\n' ' ')"
            local log_repaired=false
            local ep
            for ep in $err_ports; do
                yellow "[*] 尝试按端口联动修复冲突端口 (UDP) : $ep ..."
                if repair_port_group_unified "udp" "$ep"; then
                    log_repaired=true
                else
                    yellow "[*] UDP 联动无引用/失败，尝试 TCP : $ep ..."
                    if repair_port_group_unified "tcp" "$ep"; then
                        log_repaired=true
                    fi
                fi
            done
            if [ "$log_repaired" = true ]; then
                yellow "[+] 日志冲突端口已按组联动修复，继续重试启动"
                return 0
            else
                red "[!] 日志冲突端口联动修复全部失败，触发全量端口重置..."
                full_port_reset_and_realloc
                return $?
            fi
        fi
    fi

    # ---------------- 4. 执行配置更新与生成 ----------------
    if [ "$repaired_main" = true ] || [ "${MAIN_PORT_CHANGED:-}" = true ]; then
        cat > "$WORKDIR/ports.txt" <<EOF
VMESS_PORT=$VMESS_PORT
VLESS_PORT=$VLESS_PORT
HY2_PORT=$HY2_PORT
TUIC_PORT=$TUIC_PORT
ANYTLS_PORT=$ANYTLS_PORT
EOF
        generate_singbox_config
    fi

    if [ "$repaired_proxy" = true ]; then
        yellow "[*] 重新同步所有代理分组 Inbound 配置..."
        sync_all_proxy_groups 2>/dev/null || true
    fi

    if [ "$repaired_main" = true ] || [ "$repaired_proxy" = true ] || [ "${MAIN_PORT_CHANGED:-}" = true ]; then
        return 0
    fi

    red "[!] 未发现待更换的冲突端口"
    return 1
}

# 主节点端口更换后，把引用旧主节点端口的代理组/egress 组端口文件联动更新为新端口
# (场景: 代理组端口配额满自动退回主节点端口时，两者共享同一端口号, 主节点换端口必须连带)
relink_proxy_refs() {
    local old_port=$1 new_port=$2
    [ -z "$old_port" ] || [ "$old_port" == "$new_port" ] && return 0
    local gtag gdir gval found=false
    for gtag in $(get_all_proxy_groups 2>/dev/null || true); do
        gdir="${PROXY_GROUPS_DIR}/${gtag}"
        gval=$(cat "$gdir/hy2_port.txt" 2>/dev/null || echo "")
        if [ "$gval" == "$old_port" ]; then
            echo "$new_port" > "$gdir/hy2_port.txt"
            yellow "  → 代理组 $gtag hy2 联动: $old_port→$new_port"
            found=true
        fi
        gval=$(cat "$gdir/tuic_port.txt" 2>/dev/null || echo "")
        if [ "$gval" == "$old_port" ]; then
            echo "$new_port" > "$gdir/tuic_port.txt"
            yellow "  → 代理组 $gtag tuic 联动: $old_port→$new_port"
            found=true
        fi
    done
    local cc cval
    if [ -d "${PSI_INSTANCES_DIR:-}" ]; then
        for cc in $(ls "$PSI_INSTANCES_DIR" 2>/dev/null || true); do
            cval=$(cat "$PSI_INSTANCES_DIR/$cc/hy2_port.txt" 2>/dev/null || echo "")
            if [ "$cval" == "$old_port" ]; then
                echo "$new_port" > "$PSI_INSTANCES_DIR/$cc/hy2_port.txt"
                yellow "  → egress 组 $cc hy2 联动: $old_port→$new_port"
                found=true
            fi
            cval=$(cat "$PSI_INSTANCES_DIR/$cc/tuic_port.txt" 2>/dev/null || echo "")
            if [ "$cval" == "$old_port" ]; then
                echo "$new_port" > "$PSI_INSTANCES_DIR/$cc/tuic_port.txt"
                yellow "  → egress 组 $cc tuic 联动: $old_port→$new_port"
                found=true
            fi
        done
    fi
    [ "$found" = true ] && repaired_proxy=true 2>/dev/null || true
}

# ===================== 端口组联动修复 (2026-09-08 用户核心需求) =====================
# 同一端口号可被多个入站共享(同端口×多IP, 每 IP 对应不同出站: 主节点/代理组/egress)。
# 例: 63556×3 IP → proxy-1-out / proxy-2-out / proxy-3-out 三个不同中转节点。
# 任一 IP 上该端口被占 → 整个端口组换新端口(端口复用链不拆散), 所有引用位置联动更新。
# 输入: proto(udp/tcp) + old_port; 返回: 0=换端口成功 1=失败/无需
repair_port_group_unified() {
    local proto=$1
    local old_port=$2
    [[ -z "$proto" || -z "$old_port" || "$old_port" == "0" ]] && return 1

    local refs=()
    # 1) 主节点变量引用
    if [ "$proto" == "tcp" ] && [ -n "${VMESS_PORT:-}" ] && [ "$VMESS_PORT" == "$old_port" ]; then refs+=("var|VMESS_PORT"); fi
    if [ "$proto" == "tcp" ] && [ -n "${VLESS_PORT:-}" ] && [ "$VLESS_PORT" == "$old_port" ]; then refs+=("var|VLESS_PORT"); fi
    if [ "$proto" == "udp" ] && [ -n "${HY2_PORT:-}" ] && [ "$HY2_PORT" == "$old_port" ]; then refs+=("var|HY2_PORT"); fi
    if [ "$proto" == "udp" ] && [ -n "${TUIC_PORT:-}" ] && [ "$TUIC_PORT" == "$old_port" ]; then refs+=("var|TUIC_PORT"); fi
    if [ "$proto" == "tcp" ] && [ -n "${ANYTLS_PORT:-}" ] && [ "$ANYTLS_PORT" == "$old_port" ]; then refs+=("var|ANYTLS_PORT"); fi

    # 2) 代理组端口文件引用
    local gtag gdir gval
    for gtag in $(get_all_proxy_groups 2>/dev/null || true); do
        gdir="${PROXY_GROUPS_DIR}/${gtag}"
        gval=$(cat "$gdir/hy2_port.txt" 2>/dev/null || echo "")
        [ "$gval" == "$old_port" ] && refs+=("proxy|${gtag}|hy2")
        gval=$(cat "$gdir/tuic_port.txt" 2>/dev/null || echo "")
        [ "$gval" == "$old_port" ] && refs+=("proxy|${gtag}|tuic")
    done

    # 3) egress 组(赛风/openrung)端口文件引用
    local cc cval
    if [ -d "${PSI_INSTANCES_DIR:-}" ]; then
        for cc in $(ls "$PSI_INSTANCES_DIR" 2>/dev/null || true); do
            cval=$(cat "$PSI_INSTANCES_DIR/$cc/hy2_port.txt" 2>/dev/null || echo "")
            [ "$cval" == "$old_port" ] && refs+=("egress|${cc}|hy2")
            cval=$(cat "$PSI_INSTANCES_DIR/$cc/tuic_port.txt" 2>/dev/null || echo "")
            [ "$cval" == "$old_port" ] && refs+=("egress|${cc}|tuic")
        done
    fi

    if [ ${#refs[@]} -eq 0 ]; then
        yellow "  [!] 端口 ${proto}:${old_port} 无任何引用位置, 跳过"
        return 1
    fi
    yellow "  [*] 该端口被 ${#refs[@]} 处引用: ${refs[*]} — 整体联动换新端口"

    # 4) 收集该端口涉及的全部绑定 IP (从 config.json 提取)
    local involved_ips
    involved_ips=$(python3 - "$old_port" <<'PYPROBE' 2>/dev/null
import json, sys
try:
    cfg = json.load(open("config.json"))
except Exception:
    sys.exit(0)
ips = set()
for ib in cfg.get("inbounds", []):
    if str(ib.get("listen_port")) == sys.argv[1] and ib.get("listen"):
        ip = ib["listen"]
        if ip not in ("::", "0.0.0.0", ""):
            ips.add(ip)
print(" ".join(sorted(ips)))
PYPROBE
)
    if [ -z "$involved_ips" ]; then
        involved_ips="${ALL_IPS[*]:-}"
        involved_ips=$(echo "$involved_ips" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    fi
    yellow "  [*] 涉及绑定 IP: ${involved_ips:-<未知>}"

    # 5) 删旧端口释放配额
    devil port del "$proto" "$old_port" >/dev/null 2>&1
    sleep 1

    # 6) 申请新端口(在涉及的全部 IP 上可用)
    local new_p="" cand can_use ip rc=0 res
    local retry=0
    while [[ $retry -lt 60 && -z "$new_p" ]]; do
        cand=$(shuf -i 10000-65535 -n 1)
        can_use=true
        for ip in $involved_ips; do
            if ! check_port_available_on_ip "$cand" "$proto" "$ip" >/dev/null 2>&1; then
                can_use=false; break
            fi
        done
        if [[ "$can_use" == "true" ]]; then
            res=$(devil port add "$proto" "$cand" "singbox-shared-${proto}" 2>&1)
            rc=$?
            if [[ $rc -eq 0 ]] && ! echo "$res" | grep -qiE 'błąd|error|limit|istnieje|fail'; then
                new_p="$cand"
            fi
        fi
        ((retry++))
    done

    if [[ -z "$new_p" ]]; then
        red "  [!] 端口组 ${proto}:${old_port} 无法申请新端口 (配额?), 回滚旧端口"
        devil port add "$proto" "$old_port" "singbox-shared-${proto}" >/dev/null 2>&1
        return 1
    fi

    # 7) 联动更新所有引用位置
    local ref kind loc sub
    for ref in "${refs[@]}"; do
        IFS='|' read -r kind loc sub <<< "$ref"
        case "$kind" in
            var)
                export "$loc=$new_p"
                yellow "  → 主节点变量 $loc → $new_p"
                ;;
            proxy)
                echo "$new_p" > "${PROXY_GROUPS_DIR}/${loc}/${sub}_port.txt"
                yellow "  → 代理组 $loc ${sub}_port.txt → $new_p"
                ;;
            egress)
                echo "$new_p" > "${PSI_INSTANCES_DIR}/${loc}/${sub}_port.txt"
                yellow "  → egress 组 $loc ${sub}_port.txt → $new_p"
                ;;
        esac
    done

    # 8) 主节点变量变化则重写 ports.txt, 并通知 auto_repair 尾部也需重新生成主配置
    local main_var_changed=false ref2
    for ref2 in "${refs[@]}"; do
        case "$ref2" in
            var\|*) main_var_changed=true ;;
        esac
    done
    if [ "$main_var_changed" == "true" ]; then
        cat > "$WORKDIR/ports.txt" <<EOF
VMESS_PORT=${VMESS_PORT:-}
VLESS_PORT=${VLESS_PORT:-}
HY2_PORT=${HY2_PORT:-}
TUIC_PORT=${TUIC_PORT:-}
ANYTLS_PORT=${ANYTLS_PORT:-}
EOF
        export MAIN_PORT_CHANGED=true
        yellow "  → ports.txt 已重写 (主节点端口已变更)"
    fi

    green "  [+] 端口组 ${proto}:${old_port} 已整体更换为 ${proto}:${new_p}"
    return 0
}

# 启动sing-box (支持端口冲突捕获与自愈重试)
start_singbox() {
    local retry_count=${1:-0}
    local max_retries=3

    cd "$WORKDIR"
    SB_BINARY=$(cat sb.txt 2>/dev/null)
    
    # 自动同步代理节点组配置
    sync_all_proxy_groups 2>/dev/null || true
    
    if [ -z "$SB_BINARY" ] || [ ! -f "$WORKDIR/$SB_BINARY" ]; then
        red "sing-box二进制文件未找到"
        return 1
    fi
    
    # 杀掉现有进程
    pkill -f "$WORKDIR/$SB_BINARY" >/dev/null 2>&1 || true
    pkill -x "$SB_BINARY" >/dev/null 2>&1 || true
    sleep 1
    
    # 清空旧日志
    > "$WORKDIR/singbox.log"
    
    # 先验证配置
    yellow "验证配置文件..."
    config_check=$(cd "$WORKDIR" && ./"$SB_BINARY" check -c "$WORKDIR/config.json" 2>&1)
    if [ $? -ne 0 ]; then
        red "配置文件验证失败:"
        echo "$config_check" | head -20
        return 1
    fi
    green "配置文件验证通过"
    
    # 使用 run_detached 启动 (FreeBSD 使用 daemon 命令可靠脱离终端)
    run_detached "$WORKDIR/singbox.pid" "$WORKDIR/singbox.log" \
        "$WORKDIR/$SB_BINARY" run -c "$WORKDIR/config.json"
    sleep 3
    
    if pgrep -f "$WORKDIR/$SB_BINARY" > /dev/null 2>&1 || pgrep -x "$SB_BINARY" > /dev/null 2>&1; then
        green "sing-box 主进程已启动"
        return 0
    else
        red "sing-box 主进程启动失败"
        yellow "========== sing-box 错误日志 =========="
        tail -30 "$WORKDIR/singbox.log" 2>/dev/null
        yellow "======================================"

        # 捕获端口占用/绑定错误，自动自愈换端口并重试
        if grep -qE "address already in use|bind:" "$WORKDIR/singbox.log" 2>/dev/null; then
            if [ $retry_count -lt $max_retries ]; then
                yellow "[!] 检测到端口冲突 (address already in use)，正在自动更换全 IP 可用的新端口并重试 (尝试 $((retry_count + 1))/$max_retries)..."
                if auto_repair_conflicting_ports; then
                    start_singbox $((retry_count + 1))
                    return $?
                fi
            fi
        fi
        return 1
    fi
}

# 显示sing-box日志
show_singbox_log() {
    local log_file="$WORKDIR/singbox.log"
    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
        echo
        yellow "========== sing-box 错误日志 =========="
        tail -30 "$log_file"
        yellow "======================================="
        echo
        yellow "完整日志: $log_file"
    else
        yellow "暂无日志信息"
    fi
}

# 启动Argo隧道
start_argo() {
    cd "$WORKDIR"
    load_saved_config
    CF_BINARY=$(cat cf.txt 2>/dev/null)
    
    if [ -z "$CF_BINARY" ] || [ ! -f "$CF_BINARY" ]; then
        yellow "cloudflared二进制文件未找到"
        return 1
    fi
    
    # 杀掉现有进程 (与甬哥一致，分别处理临时和固定隧道的进程)
    ps aux | grep '[t]unnel --u' | awk '{print $2}' | xargs -r kill -9 > /dev/null 2>&1
    ps aux | grep '[t]unnel --n' | awk '{print $2}' | xargs -r kill -9 > /dev/null 2>&1
    pkill -x "$CF_BINARY" >/dev/null 2>&1
    
    # 清空旧日志
    > "$WORKDIR/argo.log"
    
    local args=""
    if [[ -n "$ARGO_AUTH" ]]; then
        if [[ $ARGO_AUTH =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
            # Token格式 (与甬哥一致，不添加额外参数)
            args="tunnel --no-autoupdate run --token ${ARGO_AUTH}"
        elif [[ $ARGO_AUTH =~ TunnelSecret ]]; then
            # JSON格式
            echo "$ARGO_AUTH" > tunnel.json
            cat > tunnel.yml <<EOF
tunnel: $(echo "$ARGO_AUTH" | jq -r '.TunnelID')
credentials-file: tunnel.json
protocol: http2

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$VMESS_PORT
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
            args="tunnel --edge-ip-version auto --config tunnel.yml run"
        fi
    else
        # 临时隧道 - 与甬哥一致: 不指定 --protocol http2，让 cloudflared 自行选择最佳协议
        rm -rf boot.log
        args="tunnel --url http://localhost:$VMESS_PORT --no-autoupdate --logfile boot.log --loglevel info"
    fi
    
    # 启动cloudflared，保存日志
    nohup ./"$CF_BINARY" $args >> "$WORKDIR/argo.log" 2>&1 &
    sleep 10
    
    if pgrep -x "$CF_BINARY" > /dev/null; then
        green "Argo隧道已启动"
        # 验证隧道是否真正可用 (与甬哥一致: curl 检查返回 404 表示隧道有效)
        if [ -f "$WORKDIR/boot.log" ]; then
            local argosl=$(cat "$WORKDIR/boot.log" 2>/dev/null | grep -a trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
            local checkhttp=$(curl -o /dev/null -s -w "%{http_code}\n" "https://$argosl" 2>/dev/null)
            if [[ "$checkhttp" == "404" ]]; then
                green "Argo临时隧道验证通过 (域名有效)"
            else
                yellow "Argo临时隧道域名暂未验证通过，可能需要等待，保活会自动恢复"
            fi
        else
            local argogd=$(cat "$WORKDIR/ARGO_DOMAIN.log" 2>/dev/null)
            local checkhttp=$(curl --max-time 2 -o /dev/null -s -w "%{http_code}\n" "https://$argogd" 2>/dev/null)
            if [[ "$checkhttp" == "404" ]]; then
                green "Argo固定隧道验证通过 (域名有效)"
            else
                yellow "Argo固定隧道域名验证未通过，请检查域名/端口/密钥配置"
            fi
        fi
        return 0
    else
        red "Argo隧道启动失败，重启中..."
        pkill -x "$CF_BINARY" 2>/dev/null
        nohup ./"$CF_BINARY" $args >> "$WORKDIR/argo.log" 2>&1 &
        sleep 5
        if pgrep -x "$CF_BINARY" > /dev/null; then
            purple "Argo隧道重启成功"
            return 0
        else
            red "Argo隧道重启仍然失败"
            show_argo_log
            return 1
        fi
    fi
}

# 显示Argo日志
show_argo_log() {
    local log_file="$WORKDIR/argo.log"
    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
        echo
        yellow "========== Argo 错误日志 =========="
        tail -20 "$log_file"
        yellow "===================================="
        echo
        yellow "完整日志: $log_file"
    else
        yellow "暂无Argo日志信息"
    fi
}

# 启动哪吒探针
start_nezha() {
    cd "$WORKDIR"
    
    if [ -z "$NEZHA_SERVER" ] || [ -z "$NEZHA_KEY" ]; then
        return 0
    fi
    
    NZ_BINARY=$(cat nz.txt 2>/dev/null)
    if [ -z "$NZ_BINARY" ] || [ ! -f "$NZ_BINARY" ]; then
        yellow "哪吒探针二进制文件未找到"
        return 1
    fi
    
    # 杀掉现有进程 (精确匹配 nezha 二进制)
    [ -n "$NZ_BINARY" ] && pkill -x "$NZ_BINARY" >/dev/null 2>&1 || true
    [ -n "$NZ_BINARY" ] && pkill -f "$WORKDIR/$NZ_BINARY" >/dev/null 2>&1 || true
    
    # 确定TLS设置
    tlsPorts=("443" "8443" "2096" "2087" "2083" "2053")
    NEZHA_TLS=""
    
    if [ -n "$NEZHA_PORT" ]; then
        # Nezha v0
        [[ "${tlsPorts[*]}" =~ "${NEZHA_PORT}" ]] && NEZHA_TLS="--tls"
        export TMPDIR=$(pwd)
        nohup ./"$NZ_BINARY" -s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${NEZHA_TLS} >/dev/null 2>&1 &
    else
        # Nezha v1
        cat > config.yaml <<EOF
client_secret: ${NEZHA_KEY}
debug: false
disable_auto_update: true
disable_command_execute: false
disable_force_update: true
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 1
server: ${NEZHA_SERVER}
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: $(case "${NEZHA_SERVER##*:}" in 443|8443|2096|2087|2083|2053) echo -n true;; *) echo -n false;; esac)
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: ${UUID}
EOF
        nohup ./"$NZ_BINARY" -c config.yaml >/dev/null 2>&1 &
    fi
    
    sleep 2
    if pgrep -x "$NZ_BINARY" > /dev/null; then
        green "哪吒探针已启动"
        return 0
    else
        yellow "哪吒探针启动失败"
        return 1
    fi
}

# 停止所有进程
stop_all() {
    yellow "正在停止所有进程并深度清理系统资源..."
    
    cd "$WORKDIR" 2>/dev/null || true
    
    # 深度清理僵尸进程与孤儿进程 (包括 Psiphon, sing-box, cloudflared, nezha 及端口死锁)
    cleanup_zombie_processes
    
    # 全量清理 Psiphon 主进程与所有多出口实例
    stop_psiphon_userland
    stop_all_psiphon_instances 2>/dev/null || true
    kill_all_user_psiphon_processes

    SB_BINARY=$(cat sb.txt 2>/dev/null)
    CF_BINARY=$(cat cf.txt 2>/dev/null)
    NZ_BINARY=$(cat nz.txt 2>/dev/null)
    
    [ -n "$SB_BINARY" ] && pkill -9 -x "$SB_BINARY" >/dev/null 2>&1
    [ -n "$CF_BINARY" ] && pkill -9 -x "$CF_BINARY" >/dev/null 2>&1
    [ -n "$NZ_BINARY" ] && pkill -9 -x "$NZ_BINARY" >/dev/null 2>&1
    
    [ -n "$SB_BINARY" ] && pkill -9 -f "$WORKDIR/$SB_BINARY" >/dev/null 2>&1 || true
    [ -n "$CF_BINARY" ] && pkill -9 -f "$WORKDIR/$CF_BINARY" >/dev/null 2>&1 || true
    [ -n "$NZ_BINARY" ] && pkill -9 -f "$WORKDIR/$NZ_BINARY" >/dev/null 2>&1 || true
    
    # 清理历史垃圾与大日志截断
    cleanup_garbage_and_logs
    
    green "所有进程已停止，僵尸进程与残留垃圾已彻底清理并释放系统配额"
}

# ==================== 节点链接生成 ====================

# 加载已保存的配置 (端口/UUID/协议/密钥等)
load_saved_config() {
    cd "$WORKDIR" 2>/dev/null || return 1

    # 加载端口 (带自动净化与纯数字严格校验)
    if [ -f "$WORKDIR/ports.txt" ]; then
        while IFS='=' read -r key val; do
            key=$(echo "$key" | tr -d ' \r\n')
            val=$(echo "$val" | grep -oE '[0-9]+' | head -n1)
            [[ "$key" == "VMESS_PORT" ]] && export VMESS_PORT="$val"
            [[ "$key" == "VLESS_PORT" ]] && export VLESS_PORT="$val"
            [[ "$key" == "HY2_PORT"   ]] && export HY2_PORT="$val"
            [[ "$key" == "TUIC_PORT"  ]] && export TUIC_PORT="$val"
            [[ "$key" == "ANYTLS_PORT" ]] && export ANYTLS_PORT="$val"
        done < "$WORKDIR/ports.txt"

        # 自动将净化后的端口回写盘中
        cat > "$WORKDIR/ports.txt" <<EOF
VMESS_PORT=${VMESS_PORT:-}
VLESS_PORT=${VLESS_PORT:-}
HY2_PORT=${HY2_PORT:-}
TUIC_PORT=${TUIC_PORT:-}
ANYTLS_PORT=${ANYTLS_PORT:-}
EOF
    fi

    # 加载UUID
    if [ -f "$WORKDIR/UUID.txt" ]; then
        UUID=$(cat "$WORKDIR/UUID.txt" 2>/dev/null)
    fi

    # 加载协议开关
    [ -f "$WORKDIR/enable_argo.txt" ]   && ENABLE_ARGO=$(cat "$WORKDIR/enable_argo.txt" 2>/dev/null)
    [ -f "$WORKDIR/enable_vless.txt" ]   && ENABLE_VLESS_REALITY=$(cat "$WORKDIR/enable_vless.txt" 2>/dev/null)
    [ -f "$WORKDIR/enable_vmess.txt" ]   && ENABLE_VMESS_WS=$(cat "$WORKDIR/enable_vmess.txt" 2>/dev/null)
    [ -f "$WORKDIR/enable_trojan.txt" ]  && ENABLE_TROJAN_WS=$(cat "$WORKDIR/enable_trojan.txt" 2>/dev/null)
    [ -f "$WORKDIR/enable_hy2.txt" ]     && ENABLE_HYSTERIA2=$(cat "$WORKDIR/enable_hy2.txt" 2>/dev/null)
    [ -f "$WORKDIR/enable_tuic.txt" ]    && ENABLE_TUIC=$(cat "$WORKDIR/enable_tuic.txt" 2>/dev/null)
    [ -f "$WORKDIR/enable_ss.txt" ]      && ENABLE_SHADOWSOCKS=$(cat "$WORKDIR/enable_ss.txt" 2>/dev/null)
    [ -f "$WORKDIR/enable_anytls.txt" ]  && ENABLE_ANYTLS=$(cat "$WORKDIR/enable_anytls.txt" 2>/dev/null)

    # 加载Reality密钥
    [ -f "$WORKDIR/public_key.txt" ]  && REALITY_PUBLIC_KEY=$(cat "$WORKDIR/public_key.txt" 2>/dev/null)
    [ -f "$WORKDIR/private_key.txt" ] && REALITY_PRIVATE_KEY=$(cat "$WORKDIR/private_key.txt" 2>/dev/null)

    # 加载Reality域名
    [ -f "$WORKDIR/reym.txt" ] && REALITY_DOMAIN=$(cat "$WORKDIR/reym.txt" 2>/dev/null)

    # 加载SUB_TOKEN
    export SUB_TOKEN=${SUB_TOKEN:-${UUID:0:8}}

    # 加载Argo信息
    [ -f "$WORKDIR/ARGO_AUTH.log" ]   && ARGO_AUTH=$(cat "$WORKDIR/ARGO_AUTH.log" 2>/dev/null)
    [ -f "$WORKDIR/ARGO_DOMAIN.log" ] && ARGO_DOMAIN=$(cat "$WORKDIR/ARGO_DOMAIN.log" 2>/dev/null)

    # 加载WARP出站状态 (与磁盘保持一致, 防止残留状态导致生成废 WARP 配置)
    if [ -f "$WORKDIR/warp_enabled.txt" ]; then
        WARP_ENABLED=$(cat "$WORKDIR/warp_enabled.txt" 2>/dev/null)
    fi
    if [ -f "$WORKDIR/warp_mode.txt" ]; then
        WARP_MODE=$(cat "$WORKDIR/warp_mode.txt" 2>/dev/null)
    fi

    # WARP 状态自检: enabled=true 但 WARP 参数不完整时自动降级为直连
    if [[ "$WARP_ENABLED" == "true" ]]; then
        if [ ! -f "$WORKDIR/warp_private_key.txt" ] || [ ! -f "$WORKDIR/warp_ipv6.txt" ] || [ ! -f "$WORKDIR/warp_reserved.txt" ]; then
            yellow "[!] WARP 参数不完整，自动降级为直连出站"
            WARP_ENABLED=false
            echo "false" > "$WORKDIR/warp_enabled.txt"
        fi
    fi
}

# 获取Argo域名
get_argo_domain() {
    if [[ -n $ARGO_AUTH ]] && [[ -n $ARGO_DOMAIN ]]; then
        echo "$ARGO_DOMAIN"
    else
        local retry=0
        local max_retries=6
        local argodomain=""
        
        while [[ $retry -lt $max_retries ]]; do
            ((retry++))
            # 与甬哥一致: 使用 awk NR==2 提取第2行匹配的域名 (第2行通常是最终确定的隧道域名)
            argodomain=$(cat "$WORKDIR/boot.log" 2>/dev/null | grep -a trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
            if [[ -n $argodomain ]]; then
                break
            fi
            sleep 2
        done
        
        if [ -z "$argodomain" ]; then
            argodomain="Argo临时域名暂时获取失败，Argo节点暂不可用(保活过程中会自动恢复)，其他节点依旧可用"
        fi
        echo "$argodomain"
    fi
}

# 生成节点链接
generate_links() {
    # 加载已保存的配置 (确保端口/UUID等变量可用)
    load_saved_config
    cd "$WORKDIR"
    
    # 读取IP列表
    if [ -f "$WORKDIR/all_ips.txt" ]; then
        mapfile -t ALL_IPS < "$WORKDIR/all_ips.txt"
    fi
    IP_COUNT=${#ALL_IPS[@]}
    
    ARGO_DOMAIN_FINAL=$(get_argo_domain)
    
    green "生成节点链接中... (共 ${IP_COUNT} 个IP)"
    echo
    
    # 清空链接文件
    > links.txt
    > list.txt
    
    # ISP检测
    ISP=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" 2>/dev/null | jq -r '.isp // "Unknown"' | sed 's/ /_/g')
    NAME="${ISP}-${snb}"
    
    echo "========================================" >> list.txt
    echo "Serv00/Hostuno 多协议节点配置" >> list.txt
    echo "========================================" >> list.txt
    echo "" >> list.txt
    echo "可用IP列表 (共 ${IP_COUNT} 个):" >> list.txt
    local idx=1
    for ip in "${ALL_IPS[@]}"; do
        local status=$(cat "$WORKDIR/ip_status_${ip}.txt" 2>/dev/null)
        if [[ "$status" == "Available" ]]; then
            echo "  [$idx] $ip : 可用" >> list.txt
        elif [[ "$status" == "Blocked" ]]; then
            echo "  [$idx] $ip : 被墙 (Argo与CDN回源节点、proxyip依旧有效)" >> list.txt
        else
            echo "  [$idx] $ip : 未知 (检测超时)" >> list.txt
        fi
        ((idx++))
    done
    echo "" >> list.txt
    echo "UUID: $UUID" >> list.txt
    echo "" >> list.txt
    echo "端口分配:" >> list.txt
    [[ -n "$VMESS_PORT" ]] && echo "  VMess/Trojan: $VMESS_PORT (TCP)" >> list.txt
    [[ -n "$VLESS_PORT" ]] && echo "  VLESS-Reality: $VLESS_PORT (TCP)" >> list.txt
    [[ -n "$HY2_PORT" ]] && echo "  Hysteria2: $HY2_PORT (UDP)" >> list.txt
    [[ -n "$TUIC_PORT" ]] && echo "  TUIC v5: $TUIC_PORT (UDP)" >> list.txt
    echo "" >> list.txt
    
    local node_count=0
    
    # 为每个IP生成 VLESS Reality
    if [[ "$ENABLE_VLESS_REALITY" == "true" ]]; then
        echo "=== VLESS-Reality ===" >> list.txt
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            vless_link="vless://$UUID@$ip:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_DOMAIN&fp=chrome&pbk=$REALITY_PUBLIC_KEY&type=tcp&headerType=none#$NAME-vless-$idx"
            echo "$vless_link" >> links.txt
            echo "[$idx] $ip" >> list.txt
            echo "$vless_link" >> list.txt
            echo "" >> list.txt
            ((idx++))
            ((node_count++))
        done
        purple "VLESS-Reality 节点已生成 (${IP_COUNT} 个)"
    fi
    
    # 为每个IP生成 VMess WS (直连)
    if [[ "$ENABLE_VMESS_WS" == "true" ]]; then
        echo "=== VMess-WS (直连) ===" >> list.txt
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            vmess_direct=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-vmess-$idx\", \"add\": \"$ip\", \"port\": \"$VMESS_PORT\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"\", \"sni\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_direct" >> links.txt
            echo "[$idx] $ip" >> list.txt
            echo "vmess://$vmess_direct" >> list.txt
            echo "" >> list.txt
            ((idx++))
            ((node_count++))
        done
        purple "VMess-WS 直连节点已生成 (${IP_COUNT} 个)"
    fi
    
    # VMess WS Argo - 与甬哥一致: add地址统一使用CDN优选地址, 通过host/sni携带Argo域名路由
    if [[ "$ENABLE_ARGO" == "true" ]] && [[ -n "$ARGO_DOMAIN_FINAL" ]]; then
        echo "=== VMess-WS-Argo ===" >> list.txt
        
        # 与甬哥一致: add地址统一使用 $CFIP (默认 cdn.2020111.xyz)
        # 无论临时还是固定隧道, 都通过CF CDN网络, 客户端需连接CF入口节点
        local argo_add="$CFIP"
        
        # 主 Argo TLS 节点 (与甬哥一致: 端口8443, add使用CDN优选地址)
        vmess_argo_tls=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-tls\", \"add\": \"$argo_add\", \"port\": \"8443\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN_FINAL\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)
        echo "vmess://$vmess_argo_tls" >> links.txt
        
        # 主 Argo 非TLS 节点 (与甬哥一致: 端口8880)
        vmess_argo=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo\", \"add\": \"$argo_add\", \"port\": \"8880\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"\"}" | base64 -w0)
        echo "vmess://$vmess_argo" >> links.txt
        
        echo "Argo TLS (CDN优选IP节点, 地址可自行修改优选IP/域名, 被墙依旧能用):" >> list.txt
        echo "vmess://$vmess_argo_tls" >> list.txt
        echo "" >> list.txt
        echo "Argo NoTLS (CDN优选IP节点, 地址可自行修改优选IP/域名, 被墙依旧能用):" >> list.txt
        echo "vmess://$vmess_argo" >> list.txt
        echo "" >> list.txt
        ((node_count+=2))
        
        # 与甬哥一致: 通过curl检测Argo域名是否返回404来判断隧道是否有效
        # 有效则生成CDN多端口优选节点 (使用不同的CF IP段, 与甬哥完全一致)
        local argo_valid=false
        if [ -f "$WORKDIR/boot.log" ]; then
            local argosl=$(cat "$WORKDIR/boot.log" 2>/dev/null | grep -a trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
            local checkhttp=$(curl -o /dev/null -s -w "%{http_code}\n" "https://$argosl" 2>/dev/null)
            [[ "$checkhttp" == "404" ]] && argo_valid=true
        else
            local argogd=$(cat "$WORKDIR/ARGO_DOMAIN.log" 2>/dev/null)
            local checkhttp=$(curl --max-time 2 -o /dev/null -s -w "%{http_code}\n" "https://$argogd" 2>/dev/null)
            [[ "$checkhttp" == "404" ]] && argo_valid=true
        fi
        
        if [[ "$argo_valid" == "true" ]]; then
            # 与甬哥一致: 生成CDN优选IP多端口节点 (使用不同的CF IP段 104.16~104.27)
            # 6个 TLS 443系端口节点
            vmess_cdn1=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-443\", \"add\": \"104.16.0.0\", \"port\": \"443\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN_FINAL\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_cdn1" >> links.txt
            vmess_cdn2=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-2053\", \"add\": \"104.17.0.0\", \"port\": \"2053\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN_FINAL\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_cdn2" >> links.txt
            vmess_cdn3=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-2083\", \"add\": \"104.18.0.0\", \"port\": \"2083\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN_FINAL\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_cdn3" >> links.txt
            vmess_cdn4=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-2087\", \"add\": \"104.19.0.0\", \"port\": \"2087\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN_FINAL\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_cdn4" >> links.txt
            vmess_cdn5=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-2096\", \"add\": \"104.20.0.0\", \"port\": \"2096\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN_FINAL\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_cdn5" >> links.txt
            
            # 7个非TLS 80系端口节点
            vmess_cdn6=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-80\", \"add\": \"104.21.0.0\", \"port\": \"80\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_cdn6" >> links.txt
            vmess_cdn7=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-8080\", \"add\": \"104.22.0.0\", \"port\": \"8080\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_cdn7" >> links.txt
            vmess_cdn8=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-2052\", \"add\": \"104.24.0.0\", \"port\": \"2052\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_cdn8" >> links.txt
            vmess_cdn9=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-2082\", \"add\": \"104.25.0.0\", \"port\": \"2082\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_cdn9" >> links.txt
            vmess_cdn10=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-2086\", \"add\": \"104.26.0.0\", \"port\": \"2086\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_cdn10" >> links.txt
            vmess_cdn11=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-2095\", \"add\": \"104.27.0.0\", \"port\": \"2095\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_cdn11" >> links.txt
            
            ((node_count+=11))
            purple "VMess-WS-Argo 节点已生成 (含13个CDN优选IP节点, 已添加CF不死IP)"
        else
            purple "VMess-WS-Argo 主节点已生成 (CDN优选节点待隧道验证通过后生成)"
        fi
    fi
    
    # 为每个IP生成 Trojan WS
    if [[ "$ENABLE_TROJAN_WS" == "true" ]]; then
        echo "=== Trojan-WS ===" >> list.txt
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            trojan_link="trojan://$UUID@$ip:$VMESS_PORT?security=tls&sni=${USERNAME}.${DOMAIN}&type=ws&path=/$UUID-tr#$NAME-trojan-$idx"
            echo "$trojan_link" >> links.txt
            echo "[$idx] $ip" >> list.txt
            echo "$trojan_link" >> list.txt
            echo "" >> list.txt
            ((idx++))
            ((node_count++))
        done
        purple "Trojan-WS 节点已生成 (${IP_COUNT} 个)"
    fi
    
    # 为每个IP生成 Hysteria2
    if [[ "$ENABLE_HYSTERIA2" == "true" ]]; then
        echo "=== Hysteria2 ===" >> list.txt
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            hy2_link="hysteria2://$UUID@$ip:$HY2_PORT?security=tls&sni=www.bing.com&alpn=h3&insecure=1#$NAME-hy2-$idx"
            echo "$hy2_link" >> links.txt
            echo "[$idx] $ip" >> list.txt
            echo "$hy2_link" >> list.txt
            echo "" >> list.txt
            ((idx++))
            ((node_count++))
        done
        purple "Hysteria2 节点已生成 (${IP_COUNT} 个)"
    fi
    
    # 为每个IP生成 TUIC v5
    if [[ "$ENABLE_TUIC" == "true" ]]; then
        echo "=== TUIC v5 ===" >> list.txt
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            tuic_link="tuic://$UUID:$UUID@$ip:$TUIC_PORT?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#$NAME-tuic-$idx"
            echo "$tuic_link" >> links.txt
            echo "[$idx] $ip" >> list.txt
            echo "$tuic_link" >> list.txt
            echo "" >> list.txt
            ((idx++))
            ((node_count++))
        done
        purple "TUIC v5 节点已生成 (${IP_COUNT} 个)"
    fi
    
    # 为每个IP生成 AnyTLS (v1.12+)
    if [[ "$ENABLE_ANYTLS" == "true" ]]; then
        echo "=== AnyTLS === " >> list.txt
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            anytls_link="anytls://$UUID@$ip:$ANYTLS_PORT?security=tls&sni=www.bing.com&allowInsecure=1#$NAME-anytls-$idx"
            echo "$anytls_link" >> links.txt
            echo "[$idx] $ip" >> list.txt
            echo "$anytls_link" >> list.txt
            echo "" >> list.txt
            ((idx++))
            ((node_count++))
        done
        purple "AnyTLS 节点已生成 (${IP_COUNT} 个)"
    fi
    
    # Shadowsocks (只需要一个，监听::)
    if [[ "$ENABLE_SHADOWSOCKS" == "true" ]]; then
        echo "=== Shadowsocks-2022 ===" >> list.txt
        SS_PASSWORD=$(cat ss_password.txt 2>/dev/null)
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            ss_link="ss://$(echo -n "2022-blake3-aes-128-gcm:$SS_PASSWORD" | base64 -w0)@$ip:$((VMESS_PORT+1))#$NAME-ss-$idx"
            echo "$ss_link" >> links.txt
            echo "[$idx] $ip" >> list.txt
            echo "$ss_link" >> list.txt
            echo "" >> list.txt
            ((idx++))
            ((node_count++))
        done
        purple "Shadowsocks-2022 节点已生成 (${IP_COUNT} 个)"
    fi
    
    echo "" >> list.txt
    echo "========================================" >> list.txt
    echo "总计节点数: $node_count" >> list.txt
    echo "Argo域名: $ARGO_DOMAIN_FINAL" >> list.txt
    echo "========================================" >> list.txt
    
    # 复制到公共目录
    cp links.txt "${FILE_PATH}/links.txt"
    base64 -w0 links.txt > "${FILE_PATH}/${SUB_TOKEN}.txt"
    
    # 生成订阅链接
    SUB_LINK="https://${USERNAME}.${DOMAIN}/${SUB_TOKEN}.txt"
    echo "" >> list.txt
    echo "订阅链接:" >> list.txt
    echo "$SUB_LINK" >> list.txt
    
    echo
    green "=========================================="
    green "节点总数: $node_count 个"
    green "节点链接文件: $WORKDIR/links.txt"
    green "详细信息文件: $WORKDIR/list.txt" 
    green "订阅链接: $SUB_LINK"
    green "=========================================="
}


# 显示主节点链接
show_links() {
    if [ -f "$WORKDIR/list.txt" ]; then
        # 显示WARP状态
        local warp_status=$(cat "$WORKDIR/warp_enabled.txt" 2>/dev/null)
        local warp_mode=$(cat "$WORKDIR/warp_mode.txt" 2>/dev/null)
        echo
        if [[ "$warp_status" == "true" ]]; then
            if [[ "$warp_mode" == "all" ]]; then
                blue "╔════════════════════════════════════════════╗"
                blue "║  主节点出站: ✓ WARP 全局出站 (全部流量)     ║"
                blue "╚════════════════════════════════════════════╝"
            else
                blue "╔════════════════════════════════════════════╗"
                blue "║  主节点出站: ✓ WARP 分流出站 (流媒体/指定域名)║"
                blue "╚════════════════════════════════════════════╝"
            fi
        else
            green "╔════════════════════════════════════════════╗"
            green "║  主节点出站: ✓ 直连出站 (Direct 原生直连)   ║"
            green "╚════════════════════════════════════════════╝"
        fi
        echo
        cat "$WORKDIR/list.txt"
    else
        red "未找到主节点信息，请先安装"
    fi
}

# 查看全部节点信息总览 (主节点 + 副节点分类汇总)
show_all_nodes_summary() {
    clear
    echo
    green "============================================================"
    green "  全部节点信息总览 (主节点与副节点分类汇总)"
    green "============================================================"
    echo
    
    # 1. 主节点信息
    purple "【一、主节点列表 (多协议主节点群)】"
    show_links
    echo
    
    # 2. 副节点 - 赛风出站节点组
    purple "【二、副节点 - 赛风出站多出口节点组】"
    local psi_groups=($(get_egress_node_groups 2>/dev/null))
    if [[ ${#psi_groups[@]} -gt 0 ]]; then
        for cc in "${psi_groups[@]}"; do
            generate_egress_node_links "$cc"
        done
    else
        yellow "  (当前未配置赛风副节点出口组)"
    fi
    echo
    
    # 3. 副节点 - 自定义代理出站节点组
    purple "【三、副节点 - 自定义代理出站多出口节点组】"
    init_proxy_groups_dir
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

# ==================== 自定义节点推送 ====================

# 自定义选择节点组合推送
custom_push_nodes() {
    if [ ! -f "$WORKDIR/links.txt" ]; then
        red "未找到节点信息，请先安装主节点"
        return 1
    fi
    
    # 加载已保存的配置 (确保端口/UUID/协议等变量可用)
    load_saved_config
    cd "$WORKDIR"
    
    # 读取当前启用的协议
    local has_vless=$(cat "$WORKDIR/enable_vless.txt" 2>/dev/null)
    local has_vmess=$(cat "$WORKDIR/enable_vmess.txt" 2>/dev/null)
    local has_argo=$(cat "$WORKDIR/enable_argo.txt" 2>/dev/null)
    local has_trojan=$(cat "$WORKDIR/enable_trojan.txt" 2>/dev/null)
    local has_hy2=$(cat "$WORKDIR/enable_hy2.txt" 2>/dev/null)
    local has_tuic=$(cat "$WORKDIR/enable_tuic.txt" 2>/dev/null)
    local has_ss=$(cat "$WORKDIR/enable_ss.txt" 2>/dev/null)
    
    # 初始化选择状态 (默认全选)
    local sel_vless=${has_vless:-false}
    local sel_vmess=${has_vmess:-false}
    local sel_argo=${has_argo:-false}
    local sel_trojan=${has_trojan:-false}
    local sel_hy2=${has_hy2:-false}
    local sel_tuic=${has_tuic:-false}
    local sel_ss=${has_ss:-false}
    
    # 选择菜单循环
    while true; do
        clear
        echo
        green "============================================================"
        green "  自定义节点组合推送"
        green "============================================================"
        echo
        purple "当前选择 (✓=已选, ✗=未选):"  
        echo
        
        # 显示可用协议
        local idx=1
        
        if [[ "$has_vless" == "true" ]]; then
            if [[ "$sel_vless" == "true" ]]; then
                green "  [$idx] [✓] VLESS-Reality"
            else
                yellow "  [$idx] [✗] VLESS-Reality"
            fi
            ((idx++))
        fi
        
        if [[ "$has_vmess" == "true" ]]; then
            if [[ "$sel_vmess" == "true" ]]; then
                green "  [$idx] [✓] VMess-WS (直连)"
            else
                yellow "  [$idx] [✗] VMess-WS (直连)"
            fi
            ((idx++))
        fi
        
        if [[ "$has_argo" == "true" ]]; then
            if [[ "$sel_argo" == "true" ]]; then
                green "  [$idx] [✓] VMess-WS-Argo (含CDN节点)"
            else
                yellow "  [$idx] [✗] VMess-WS-Argo (含CDN节点)"
            fi
            ((idx++))
        fi
        
        if [[ "$has_trojan" == "true" ]]; then
            if [[ "$sel_trojan" == "true" ]]; then
                green "  [$idx] [✓] Trojan-WS"
            else
                yellow "  [$idx] [✗] Trojan-WS"
            fi
            ((idx++))
        fi
        
        if [[ "$has_hy2" == "true" ]]; then
            if [[ "$sel_hy2" == "true" ]]; then
                green "  [$idx] [✓] Hysteria2"
            else
                yellow "  [$idx] [✗] Hysteria2"
            fi
            ((idx++))
        fi
        
        if [[ "$has_tuic" == "true" ]]; then
            if [[ "$sel_tuic" == "true" ]]; then
                green "  [$idx] [✓] TUIC v5"
            else
                yellow "  [$idx] [✗] TUIC v5"
            fi
            ((idx++))
        fi
        
        if [[ "$has_ss" == "true" ]]; then
            if [[ "$sel_ss" == "true" ]]; then
                green "  [$idx] [✓] Shadowsocks-2022"
            else
                yellow "  [$idx] [✗] Shadowsocks-2022"
            fi
            ((idx++))
        fi
        
        echo
        echo "------------------------------------------------------------"
        blue "  a. 全选所有协议"
        blue "  n. 取消全选"
        green "  g. 生成并推送选中的节点"
        red "  0. 返回主菜单"
        echo "============================================================"
        echo
        reading "输入数字切换选择，或选择操作 [1-$((idx-1))/a/n/g/0]: " choice
        
        # 处理输入
        case "$choice" in
            a|A)
                # 全选
                [[ "$has_vless" == "true" ]] && sel_vless=true
                [[ "$has_vmess" == "true" ]] && sel_vmess=true
                [[ "$has_argo" == "true" ]] && sel_argo=true
                [[ "$has_trojan" == "true" ]] && sel_trojan=true
                [[ "$has_hy2" == "true" ]] && sel_hy2=true
                [[ "$has_tuic" == "true" ]] && sel_tuic=true
                [[ "$has_ss" == "true" ]] && sel_ss=true
                green "已全选"
                sleep 0.5
                ;;
            n|N)
                # 取消全选
                sel_vless=false
                sel_vmess=false
                sel_argo=false
                sel_trojan=false
                sel_hy2=false
                sel_tuic=false
                sel_ss=false
                yellow "已取消全选"
                sleep 0.5
                ;;
            g|G)
                # 生成推送
                generate_custom_subscription "$sel_vless" "$sel_vmess" "$sel_argo" "$sel_trojan" "$sel_hy2" "$sel_tuic" "$sel_ss"
                reading "按回车返回..." _
                ;;
            0)
                return 0
                ;;
            [1-9])
                # 切换选择
                local toggle_idx=1
                
                if [[ "$has_vless" == "true" ]]; then
                    if [[ "$choice" == "$toggle_idx" ]]; then
                        [[ "$sel_vless" == "true" ]] && sel_vless=false || sel_vless=true
                    fi
                    ((toggle_idx++))
                fi
                
                if [[ "$has_vmess" == "true" ]]; then
                    if [[ "$choice" == "$toggle_idx" ]]; then
                        [[ "$sel_vmess" == "true" ]] && sel_vmess=false || sel_vmess=true
                    fi
                    ((toggle_idx++))
                fi
                
                if [[ "$has_argo" == "true" ]]; then
                    if [[ "$choice" == "$toggle_idx" ]]; then
                        [[ "$sel_argo" == "true" ]] && sel_argo=false || sel_argo=true
                    fi
                    ((toggle_idx++))
                fi
                
                if [[ "$has_trojan" == "true" ]]; then
                    if [[ "$choice" == "$toggle_idx" ]]; then
                        [[ "$sel_trojan" == "true" ]] && sel_trojan=false || sel_trojan=true
                    fi
                    ((toggle_idx++))
                fi
                
                if [[ "$has_hy2" == "true" ]]; then
                    if [[ "$choice" == "$toggle_idx" ]]; then
                        [[ "$sel_hy2" == "true" ]] && sel_hy2=false || sel_hy2=true
                    fi
                    ((toggle_idx++))
                fi
                
                if [[ "$has_tuic" == "true" ]]; then
                    if [[ "$choice" == "$toggle_idx" ]]; then
                        [[ "$sel_tuic" == "true" ]] && sel_tuic=false || sel_tuic=true
                    fi
                    ((toggle_idx++))
                fi
                
                if [[ "$has_ss" == "true" ]]; then
                    if [[ "$choice" == "$toggle_idx" ]]; then
                        [[ "$sel_ss" == "true" ]] && sel_ss=false || sel_ss=true
                    fi
                    ((toggle_idx++))
                fi
                ;;
            *)
                red "无效选项"
                sleep 0.5
                ;;
        esac
    done
}

# 根据选择生成自定义订阅
generate_custom_subscription() {
    local sel_vless=$1
    local sel_vmess=$2
    local sel_argo=$3
    local sel_trojan=$4
    local sel_hy2=$5
    local sel_tuic=$6
    local sel_ss=$7
    
    cd "$WORKDIR"
    
    # 检查是否有选择
    if [[ "$sel_vless" != "true" ]] && [[ "$sel_vmess" != "true" ]] && \
       [[ "$sel_argo" != "true" ]] && [[ "$sel_trojan" != "true" ]] && \
       [[ "$sel_hy2" != "true" ]] && [[ "$sel_tuic" != "true" ]] && \
       [[ "$sel_ss" != "true" ]]; then
        red "请至少选择一个协议！"
        return 1
    fi
    
    echo
    yellow "正在生成自定义订阅..."
    
    # 读取IP列表
    if [ -f "$WORKDIR/all_ips.txt" ]; then
        mapfile -t ALL_IPS < "$WORKDIR/all_ips.txt"
    fi
    IP_COUNT=${#ALL_IPS[@]}
    
    # 读取配置 - 优先从保存的文件读取
    UUID=$(cat "$WORKDIR/UUID.txt" 2>/dev/null)
    
    # 端口读取 - 优先从保存文件，否则从 devil port list
    if [ -f "$WORKDIR/ports.txt" ]; then
        source "$WORKDIR/ports.txt"
    else
        # 实时读取端口
        local port_list=$(devil port list 2>/dev/null)
        VMESS_PORT=$(echo "$port_list" | awk '/tcp/ {print $1}' | sed -n '1p')
        VLESS_PORT=$(echo "$port_list" | awk '/tcp/ {print $1}' | sed -n '2p')
        HY2_PORT=$(echo "$port_list" | awk '/udp/ {print $1}' | sed -n '1p')
        # Serv00 只有1个UDP端口, TUIC共用
        TUIC_PORT=${HY2_PORT}
    fi
    
    REALITY_DOMAIN=$(cat "$WORKDIR/reym.txt" 2>/dev/null)
    REALITY_PUBLIC_KEY=$(cat "$WORKDIR/public_key.txt" 2>/dev/null)
    ARGO_DOMAIN_FINAL=$(get_argo_domain)
    SUB_TOKEN=$(cat "$WORKDIR/UUID.txt" 2>/dev/null | head -c 8)
    
    # ISP检测
    ISP=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" 2>/dev/null | jq -r '.isp // "Unknown"' | sed 's/ /_/g')
    NAME="${ISP}-${snb}"
    
    # 创建临时文件
    local custom_links="$WORKDIR/custom_links.txt"
    > "$custom_links"
    local node_count=0
    
    # 根据选择生成链接
    if [[ "$sel_vless" == "true" ]]; then
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            vless_link="vless://$UUID@$ip:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_DOMAIN&fp=chrome&pbk=$REALITY_PUBLIC_KEY&type=tcp&headerType=none#$NAME-vless-$idx"
            echo "$vless_link" >> "$custom_links"
            ((idx++))
            ((node_count++))
        done
        purple "✓ 已添加 VLESS-Reality 节点 (${IP_COUNT} 个)"
    fi
    
    if [[ "$sel_vmess" == "true" ]]; then
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            vmess_direct=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-vmess-$idx\", \"add\": \"$ip\", \"port\": \"$VMESS_PORT\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"\", \"sni\": \"\"}" | base64 -w0)
            echo "vmess://$vmess_direct" >> "$custom_links"
            ((idx++))
            ((node_count++))
        done
        purple "✓ 已添加 VMess-WS 直连节点 (${IP_COUNT} 个)"
    fi
    
    if [[ "$sel_argo" == "true" ]] && [[ -n "$ARGO_DOMAIN_FINAL" ]]; then
        CFIP=${CFIP:-'cdn.2020111.xyz'}
        
        # 与甬哥一致: add地址统一使用 $CFIP (CDN优选地址)
        local argo_add="$CFIP"
        
        # 主 Argo TLS 节点 (端口8443)
        vmess_argo_tls=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-tls\", \"add\": \"$argo_add\", \"port\": \"8443\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN_FINAL\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)
        echo "vmess://$vmess_argo_tls" >> "$custom_links"
        
        # 主 Argo 非TLS 节点 (端口8880)
        vmess_argo=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo\", \"add\": \"$argo_add\", \"port\": \"8880\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"\"}" | base64 -w0)
        echo "vmess://$vmess_argo" >> "$custom_links"
        ((node_count+=2))
        
        # CDN优选IP多端口节点 (使用不同CF IP段, 与甬哥一致)
        local argo_valid=false
        if [ -f "$WORKDIR/boot.log" ]; then
            local argosl=$(cat "$WORKDIR/boot.log" 2>/dev/null | grep -a trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
            local checkhttp=$(curl -o /dev/null -s -w "%{http_code}\n" "https://$argosl" 2>/dev/null)
            [[ "$checkhttp" == "404" ]] && argo_valid=true
        else
            local argogd=$(cat "$WORKDIR/ARGO_DOMAIN.log" 2>/dev/null)
            local checkhttp=$(curl --max-time 2 -o /dev/null -s -w "%{http_code}\n" "https://$argogd" 2>/dev/null)
            [[ "$checkhttp" == "404" ]] && argo_valid=true
        fi
        
        if [[ "$argo_valid" == "true" ]]; then
            # TLS 443系端口
            for entry in "443:104.16.0.0" "2053:104.17.0.0" "2083:104.18.0.0" "2087:104.19.0.0" "2096:104.20.0.0"; do
                local port="${entry%%:*}"
                local ip="${entry#*:}"
                vmess_cdn=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-$port\", \"add\": \"$ip\", \"port\": \"$port\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"tls\", \"sni\": \"$ARGO_DOMAIN_FINAL\", \"alpn\": \"\", \"fp\": \"\"}" | base64 -w0)
                echo "vmess://$vmess_cdn" >> "$custom_links"
                ((node_count++))
            done
            # 非TLS 80系端口
            for entry in "80:104.21.0.0" "8080:104.22.0.0" "2052:104.24.0.0" "2082:104.25.0.0" "2086:104.26.0.0" "2095:104.27.0.0"; do
                local port="${entry%%:*}"
                local ip="${entry#*:}"
                vmess_cdn=$(echo "{ \"v\": \"2\", \"ps\": \"$NAME-argo-$port\", \"add\": \"$ip\", \"port\": \"$port\", \"id\": \"$UUID\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"$ARGO_DOMAIN_FINAL\", \"path\": \"/$UUID-vm?ed=2048\", \"tls\": \"\"}" | base64 -w0)
                echo "vmess://$vmess_cdn" >> "$custom_links"
                ((node_count++))
            done
            purple "✓ 已添加 VMess-WS-Argo 节点 (含CDN优选IP节点)"
        else
            purple "✓ 已添加 VMess-WS-Argo 主节点 (CDN节点待隧道验证后生成)"
        fi
    fi
    
    if [[ "$sel_trojan" == "true" ]]; then
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            trojan_link="trojan://$UUID@$ip:$VMESS_PORT?security=tls&sni=${USERNAME}.${DOMAIN}&type=ws&path=/$UUID-tr#$NAME-trojan-$idx"
            echo "$trojan_link" >> "$custom_links"
            ((idx++))
            ((node_count++))
        done
        purple "✓ 已添加 Trojan-WS 节点 (${IP_COUNT} 个)"
    fi
    
    if [[ "$sel_hy2" == "true" ]]; then
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            hy2_link="hysteria2://$UUID@$ip:$HY2_PORT?security=tls&sni=www.bing.com&alpn=h3&insecure=1#$NAME-hy2-$idx"
            echo "$hy2_link" >> "$custom_links"
            ((idx++))
            ((node_count++))
        done
        purple "✓ 已添加 Hysteria2 节点 (${IP_COUNT} 个)"
    fi
    
    if [[ "$sel_tuic" == "true" ]]; then
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            tuic_link="tuic://$UUID:$UUID@$ip:$TUIC_PORT?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#$NAME-tuic-$idx"
            echo "$tuic_link" >> "$custom_links"
            ((idx++))
            ((node_count++))
        done
        purple "✓ 已添加 TUIC v5 节点 (${IP_COUNT} 个)"
    fi
    
    if [[ "$sel_ss" == "true" ]]; then
        SS_PASSWORD=$(cat "$WORKDIR/ss_password.txt" 2>/dev/null)
        local idx=1
        for ip in "${ALL_IPS[@]}"; do
            ss_link="ss://$(echo -n "2022-blake3-aes-128-gcm:$SS_PASSWORD" | base64 -w0)@$ip:$((VMESS_PORT+1))#$NAME-ss-$idx"
            echo "$ss_link" >> "$custom_links"
            ((idx++))
            ((node_count++))
        done
        purple "✓ 已添加 Shadowsocks-2022 节点 (${IP_COUNT} 个)"
    fi
    
    echo
    green "=========================================="
    green "自定义订阅已生成！"
    green "节点总数: $node_count 个"
    green "=========================================="
    echo
    
    # 生成自定义订阅文件名 (基于选择的协议)
    local sub_suffix="custom"
    [[ "$sel_vless" == "true" ]] && sub_suffix="${sub_suffix}-vl"
    [[ "$sel_vmess" == "true" ]] && sub_suffix="${sub_suffix}-vm"
    [[ "$sel_argo" == "true" ]] && sub_suffix="${sub_suffix}-ar"
    [[ "$sel_trojan" == "true" ]] && sub_suffix="${sub_suffix}-tr"
    [[ "$sel_hy2" == "true" ]] && sub_suffix="${sub_suffix}-h2"
    [[ "$sel_tuic" == "true" ]] && sub_suffix="${sub_suffix}-tu"
    [[ "$sel_ss" == "true" ]] && sub_suffix="${sub_suffix}-ss"
    
    # 保存到公共目录
    local custom_sub_file="${SUB_TOKEN}-${sub_suffix}.txt"
    base64 -w0 "$custom_links" > "${FILE_PATH}/${custom_sub_file}"
    
    local custom_sub_link="https://${USERNAME}.${DOMAIN}/${custom_sub_file}"
    
    blue "自定义订阅链接:"
    echo
    green "$custom_sub_link"
    echo
    
    # 询问是否复制链接或显示节点
    yellow "选项:"
    yellow "  1. 显示所有节点链接"
    yellow "  2. 保存为主订阅链接 (覆盖原订阅)"
    yellow "  0. 返回"
    reading "请选择: " sub_action
    
    case "$sub_action" in
        1)
            echo
            green "========== 节点链接 =========="
            cat "$custom_links"
            green "=============================="
            ;;
        2)
            cp "$custom_links" "$WORKDIR/links.txt"
            base64 -w0 "$custom_links" > "${FILE_PATH}/${SUB_TOKEN}.txt"
            green "已保存为主订阅链接!"
            green "订阅链接: https://${USERNAME}.${DOMAIN}/${SUB_TOKEN}.txt"
            ;;
    esac
}

# ==================== 快捷命令 ====================

# 创建快捷命令
create_quick_command() {
    COMMAND="sb"
    SCRIPT_PATH="$HOME/bin/$COMMAND"
    mkdir -p "$HOME/bin"
    
    cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
if [ -f "$HOME/serv00_nodes.sh" ]; then
    bash "$HOME/serv00_nodes.sh" "$@"
else
    bash <(curl -Lks "https://raw.githubusercontent.com/hxzl666/serv00-singbox/main/serv00_nodes.sh?t=$(date +%s)") "$@"
fi
EOF
    
    chmod +x "$SCRIPT_PATH"
    
    # 立即将 ~/bin 加入当前会话的 PATH
    if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
        export PATH="$HOME/bin:$PATH"
    fi
    
    # 持久化：写入所有常见的 shell 配置文件（兼容 FreeBSD / Linux）
    local path_line='export PATH="$HOME/bin:$PATH"'
    for rc_file in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc"; do
        if [[ -f "$rc_file" ]]; then
            # 文件存在但尚未包含该行，则追加
            grep -qxF "$path_line" "$rc_file" 2>/dev/null || \
                echo "$path_line" >> "$rc_file"
        else
            # 文件不存在，创建并写入
            echo "$path_line" > "$rc_file"
        fi
    done
    
    green "快捷命令 'sb' 已创建 (重新登录 SSH 后也可使用)"
}

# ==================== 安装 ====================

# 主安装函数
install_nodes() {
    clear
    echo
    green "=============================================="
    green "  Serv00/Hostuno 多协议节点一键安装脚本"
    green "=============================================="
    echo
    
    # 检查是否已安装
    if [ -f "$WORKDIR/config.json" ]; then
        yellow "检测到已安装，请先卸载再重新安装"
        reading "是否继续覆盖安装? (y/N): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            return
        fi
        stop_all
    fi
    
    # 深度清理旧僵尸进程与残留端口
    cleanup_zombie_processes
    
    # 初始化目录并自动维护垃圾
    init_directories
    
    # 先选择协议 (Serv00需要先知道要几个端口)
    select_protocols
    
    # 根据选择的协议分配端口
    check_port
    
    # 下载二进制文件
    download_singbox
    if [ $? -ne 0 ]; then
        red "下载失败，请检查网络连接"
        return 1
    fi
    
    # 生成证书和密钥
    generate_certificate
    generate_reality_keys
    
    # 读取用户配置 (IP选择、UUID等)
    read_user_config
    configure_argo
    
    # 保存协议配置 (用于后续修改)
    echo "$ENABLE_ARGO" > "$WORKDIR/enable_argo.txt"
    echo "$ENABLE_VLESS_REALITY" > "$WORKDIR/enable_vless.txt"
    echo "$ENABLE_VMESS_WS" > "$WORKDIR/enable_vmess.txt"
    echo "$ENABLE_TROJAN_WS" > "$WORKDIR/enable_trojan.txt"
    echo "$ENABLE_HYSTERIA2" > "$WORKDIR/enable_hy2.txt"
    echo "$ENABLE_TUIC" > "$WORKDIR/enable_tuic.txt"
    echo "$ENABLE_SHADOWSOCKS" > "$WORKDIR/enable_ss.txt"
    echo "$ENABLE_ANYTLS" > "$WORKDIR/enable_anytls.txt"
    
    # 保存端口配置 (用于后续自定义推送)
    cat > "$WORKDIR/ports.txt" <<EOF
VMESS_PORT=$VMESS_PORT
VLESS_PORT=$VLESS_PORT
HY2_PORT=$HY2_PORT
TUIC_PORT=$TUIC_PORT
ANYTLS_PORT=$ANYTLS_PORT
EOF
    
    # 生成配置
    generate_singbox_config
    
    # 启动进程
    start_singbox
    if [[ "$ENABLE_ARGO" == "true" ]]; then
        start_argo
    fi
    start_nezha
    
    # 生成并显示链接
    sleep 3
    generate_links
    
    # 清理安装产生的临时垃圾
    cleanup_garbage_and_logs
    
    # 创建快捷命令
    create_quick_command
    
    echo
    green "=============================================="
    green "  安装完成！"
    green "=============================================="
    green "  快捷命令: sb"
    green "  工作目录: $WORKDIR"
    green "=============================================="
    
    show_links
}

# 卸载
uninstall_nodes() {
    reading "确定要卸载吗? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi
    
    stop_all
    
    rm -rf "$WORKDIR"
    rm -rf "$KEEP_PATH"
    find "${FILE_PATH}" -mindepth 1 ! -name 'index.html' -exec rm -rf {} + 2>/dev/null
    rm -rf "${HOME}/bin/sb" 2>/dev/null
    
    green "卸载完成！"
}

# 重启所有服务 (主节点 + 赛风多实例 + 自定义代理)
restart_processes() {
    # 加载已保存的配置 (确保端口/UUID/协议等变量可用)
    load_saved_config
    yellow "正在重启所有服务 (主节点 + 副节点)..."
    
    stop_all
    sleep 2
    
    cd "$WORKDIR"
    
    # 1. 主节点端口检测与修复
    yellow "[1/5] 检测所有端口在多IP上的可用性..."
    auto_repair_conflicting_ports
    local repair_rc=$?
    if [[ $repair_rc -eq 0 ]]; then
        yellow "已修复端口冲突，主节点与副节点配置已重新同步"
    elif [[ $repair_rc -eq 1 ]]; then
        green "所有端口在对应 IP 上均可用"
        generate_singbox_config 2>/dev/null || true
    else
        red "[!] 端口检测异常，尝试重新生成基础配置"
        generate_singbox_config 2>/dev/null || true
    fi
    
    # 2. 重启副节点 - 赛风多出口实例 (如果有配置)
    if [[ -f "$WORKDIR/egress_node_groups.txt" && -s "$WORKDIR/egress_node_groups.txt" ]]; then
        yellow "[2/5] 重启副节点: 赛风多出口后台实例..."
        local groups
        groups="$(cat "$WORKDIR/egress_node_groups.txt" 2>/dev/null)"
        IFS=',' read -ra cc_arr <<< "$groups"
        local inst_count=0
        for cc in "${cc_arr[@]}"; do
            cc="$(echo "$cc" | xargs)"
            [[ -z "$cc" ]] && continue
            if (( inst_count >= 3 )); then
                yellow "[!] 提示: 已限制并发 Psiphon 后台实例数 (最多 3 个)"
                break
            fi
            start_psiphon_instance "$cc" 2>/dev/null || true
            ((inst_count++))
        done
        sleep 2
        sync_all_psiphon_ports
    else
        yellow "[2/5] 未检测到赛风多出口副节点，跳过"
    fi
    
    # 3. 同步副节点 - 自定义代理分组配置到 sing-box
    yellow "[3/5] 同步副节点: 自定义代理出站多出口配置..."
    sync_all_proxy_groups
    
    # 4. 启动 sing-box 主服务
    yellow "[4/5] 启动 sing-box 核心服务..."
    start_singbox
    
    # 5. 启动主节点 Argo 隧道与 Nezha 探针
    yellow "[5/5] 启动 Argo 隧道与监控探针..."
    ARGO_AUTH=$(cat ARGO_AUTH.log 2>/dev/null)
    ARGO_DOMAIN=$(cat ARGO_DOMAIN.log 2>/dev/null)
    if [[ "$ENABLE_ARGO" == "true" ]]; then
        start_argo
    fi
    start_nezha
    
    sleep 3
    generate_links
    
    green "所有服务重启完成！(主节点与副节点均已就绪)"
}

# 重置Argo
reset_argo() {
    yellow "重置Argo隧道..."
    
    cd "$WORKDIR"
    
    # 显示当前状态
    if [ -f "boot.log" ]; then
        green "当前使用: Argo临时隧道"
        current_domain=$(cat boot.log 2>/dev/null | grep -a trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
        [ -n "$current_domain" ] && purple "临时域名: $current_domain"
    else
        green "当前使用: Argo固定隧道"
        [ -f "ARGO_DOMAIN.log" ] && purple "固定域名: $(cat ARGO_DOMAIN.log)"
    fi
    
    echo
    configure_argo
    
    # 杀掉并重启Argo
    CF_BINARY=$(cat cf.txt 2>/dev/null)
    [ -n "$CF_BINARY" ] && pkill -x "$CF_BINARY" >/dev/null 2>&1
    
    start_argo
    
    sleep 5
    generate_links
}

# Argo隧道管理 (开关/重置)
argo_management_menu() {
    clear
    echo
    green "============================================================"
    green "  Argo 隧道管理"
    green "============================================================"
    
    # 加载配置
    load_saved_config
    
    # 获取当前运行状态
    CF_BINARY=$(cat cf.txt 2>/dev/null)
    local cf_running=false
    if [ -n "$CF_BINARY" ] && pgrep -x "$CF_BINARY" >/dev/null 2>&1; then
        cf_running=true
    fi
    
    purple "当前状态:"
    if [[ "$ENABLE_ARGO" == "true" ]]; then
        green "  开关状态: 已启用 (ENABLE_ARGO=true)"
        if [ "$cf_running" = true ]; then
            green "  运行状态: 运行中 (cloudflared 在线)"
        else
            yellow "  运行状态: 未运行 (正在等待拉起或配置有误)"
        fi
    else
        red "  开关状态: 已禁用 (ENABLE_ARGO=false)"
        if [ "$cf_running" = true ]; then
            yellow "  运行状态: 运行中 (开关已关，但残留了 cloudflared 进程，建议重启或清理)"
        else
            green "  运行状态: 已关闭"
        fi
    fi
    
    # 获取隧道域名信息
    if [[ "$ENABLE_ARGO" == "true" ]]; then
        if [ -f "boot.log" ] && [ ! -f "ARGO_DOMAIN.log" ]; then
            local current_domain=$(cat boot.log 2>/dev/null | grep -a trycloudflare.com | awk 'NR==2{print}' | awk -F// '{print $2}' | awk '{print $1}')
            [ -n "$current_domain" ] && purple "  隧道模式: 临时隧道 ($current_domain)"
        elif [ -f "ARGO_DOMAIN.log" ]; then
            purple "  隧道模式: 固定隧道 ($(cat ARGO_DOMAIN.log 2>/dev/null))"
        else
            purple "  隧道模式: 未配置或正在获取..."
        fi
    fi
    
    echo "------------------------------------------------------------"
    green "  1. 开启 Argo 隧道"
    red   "  2. 关闭 Argo 隧道"
    green "  3. 重置/重新配置 Argo 隧道"
    echo "------------------------------------------------------------"
    yellow "  0. 返回主菜单"
    echo "============================================================"
    
    reading "请选择 [0-3]: " argo_choice
    echo
    
    case "$argo_choice" in
        1)
            ENABLE_ARGO="true"
            echo "true" > "$WORKDIR/enable_argo.txt"
            green "Argo 开关已设定为: 开启"
            
            # 确认是否有 cf.txt (cloudflared 是否已下载)
            if [ ! -f "$WORKDIR/cf.txt" ] || [ ! -s "$WORKDIR/cf.txt" ]; then
                yellow "未找到 Argo 二进制配置，正在启动配置向导..."
                configure_argo
            fi
            
            yellow "正在启动 Argo 隧道..."
            start_argo
            generate_links
            ;;
        2)
            ENABLE_ARGO="false"
            echo "false" > "$WORKDIR/enable_argo.txt"
            green "Argo 开关已设定为: 关闭"
            
            yellow "正在停止 Argo 进程..."
            ps aux | grep '[t]unnel --u' | awk '{print $2}' | xargs -r kill -9 > /dev/null 2>&1
            ps aux | grep '[t]unnel --n' | awk '{print $2}' | xargs -r kill -9 > /dev/null 2>&1
            if [ -n "$CF_BINARY" ]; then
                pkill -x "$CF_BINARY" >/dev/null 2>&1
            fi
            green "Argo 进程已关闭"
            generate_links
            ;;
        3)
            reset_argo
            ;;
        0)
            return
            ;;
        *)
            red "无效选项"
            ;;
    esac
    
    echo
    reading "按回车继续..." _
    argo_management_menu
}

# ==================== 日志管理 ====================

# 查看日志菜单
view_logs_menu() {
    clear
    echo
    green "============================================================"
    green "  运行日志查看"
    green "============================================================"
    echo
    
    # 显示日志文件状态
    purple "日志文件状态:"
    
    # sing-box日志
    if [ -f "$WORKDIR/singbox.log" ]; then
        local sb_size=$(stat -f%z "$WORKDIR/singbox.log" 2>/dev/null || stat -c%s "$WORKDIR/singbox.log" 2>/dev/null)
        if [ "$sb_size" -gt 0 ] 2>/dev/null; then
            green "  [1] sing-box.log - ${sb_size} bytes"
        else
            yellow "  [1] sing-box.log - 空"
        fi
    else
        yellow "  [1] sing-box.log - 不存在"
    fi
    
    # Argo日志
    if [ -f "$WORKDIR/argo.log" ]; then
        local argo_size=$(stat -f%z "$WORKDIR/argo.log" 2>/dev/null || stat -c%s "$WORKDIR/argo.log" 2>/dev/null)
        if [ "$argo_size" -gt 0 ] 2>/dev/null; then
            green "  [2] argo.log - ${argo_size} bytes"
        else
            yellow "  [2] argo.log - 空"
        fi
    else
        yellow "  [2] argo.log - 不存在"
    fi
    
    # boot.log (Argo临时隧道日志)
    if [ -f "$WORKDIR/boot.log" ]; then
        local boot_size=$(stat -f%z "$WORKDIR/boot.log" 2>/dev/null || stat -c%s "$WORKDIR/boot.log" 2>/dev/null)
        if [ "$boot_size" -gt 0 ] 2>/dev/null; then
            green "  [3] boot.log (Argo隧道) - ${boot_size} bytes"
        else
            yellow "  [3] boot.log (Argo隧道) - 空"
        fi
    else
        yellow "  [3] boot.log (Argo隧道) - 不存在"
    fi
    
    echo
    echo "------------------------------------------------------------"
    green "  1. 查看 sing-box 日志"
    green "  2. 查看 Argo 日志"
    green "  3. 查看 boot.log (Argo临时隧道)"
    green "  4. 查看 WARP 运行日志 (过滤自 sing-box)"
    echo "------------------------------------------------------------"
    blue "  5. 查看所有日志"
    blue "  6. 清空所有日志"
    echo "------------------------------------------------------------"
    yellow "  0. 返回主菜单"
    echo "============================================================"
    
    reading "请选择 [0-6]: " log_choice
    echo
    
    case "$log_choice" in
        1)
            echo
            green "========== sing-box 日志 (最近50行) =========="
            if [ -f "$WORKDIR/singbox.log" ] && [ -s "$WORKDIR/singbox.log" ]; then
                tail -50 "$WORKDIR/singbox.log"
            else
                yellow "sing-box日志为空或不存在"
            fi
            green "=============================================="
            echo
            yellow "完整日志路径: $WORKDIR/singbox.log"
            ;;
        2)
            echo
            green "========== Argo 日志 (最近50行) =========="
            if [ -f "$WORKDIR/argo.log" ] && [ -s "$WORKDIR/argo.log" ]; then
                tail -50 "$WORKDIR/argo.log"
            else
                yellow "Argo日志为空或不存在"
            fi
            green "========================================="
            echo
            yellow "完整日志路径: $WORKDIR/argo.log"
            ;;
        3)
            echo
            green "========== boot.log (Argo隧道日志) 最近50行 =========="
            if [ -f "$WORKDIR/boot.log" ] && [ -s "$WORKDIR/boot.log" ]; then
                tail -50 "$WORKDIR/boot.log"
            else
                yellow "boot.log为空或不存在"
            fi
            green "===================================================="
            echo
            yellow "完整日志路径: $WORKDIR/boot.log"
            ;;
        4)
            echo
            green "========== WARP 运行日志 (过滤自 sing-box 最近50行) =========="
            if [ -f "$WORKDIR/singbox.log" ] && [ -s "$WORKDIR/singbox.log" ]; then
                local warp_logs=$(grep -iE "wireguard|warp-out|warp" "$WORKDIR/singbox.log" | tail -50)
                if [ -n "$warp_logs" ]; then
                    echo "$warp_logs"
                else
                    yellow "未过滤到 WARP 相关日志 (可能是没有产生相关连接信息)，以下为最新 20 行 sing-box 日志："
                    tail -20 "$WORKDIR/singbox.log"
                fi
            else
                yellow "sing-box日志为空或不存在，无法读取 WARP 日志"
            fi
            green "============================================================"
            echo
            yellow "提示: WARP 作为 sing-box 出站运行，完整日志保存在: $WORKDIR/singbox.log"
            ;;
        5)
            echo
            green "========== 所有日志概览 =========="
            echo
            
            if [ -f "$WORKDIR/singbox.log" ] && [ -s "$WORKDIR/singbox.log" ]; then
                purple ">>> sing-box 日志 (最近10行):"
                tail -10 "$WORKDIR/singbox.log"
                echo
            fi
            
            if [ -f "$WORKDIR/argo.log" ] && [ -s "$WORKDIR/argo.log" ]; then
                purple ">>> Argo 日志 (最近10行):"
                tail -10 "$WORKDIR/argo.log"
                echo
            fi
            
            if [ -f "$WORKDIR/boot.log" ] && [ -s "$WORKDIR/boot.log" ]; then
                purple ">>> boot.log (最近10行):"
                tail -10 "$WORKDIR/boot.log"
                echo
            fi
            
            green "================================="
            ;;
        6)
            reading "确定清空所有日志? (y/N): " confirm_clear
            if [[ "$confirm_clear" =~ ^[Yy]$ ]]; then
                > "$WORKDIR/singbox.log" 2>/dev/null
                > "$WORKDIR/argo.log" 2>/dev/null
                > "$WORKDIR/boot.log" 2>/dev/null
                green "所有日志已清空"
            fi
            ;;
        0)
            return
            ;;
        *)
            red "无效选项"
            ;;
    esac
    
    echo
    reading "按回车继续..." _
    view_logs_menu
}

# 配置WARP出站 (安装后修改 - 保留现有节点)
# ==================== 主节点出站管理 ====================
# 仅控制【主节点】流量的出站方式 (直连出站 / WARP全局出站 / WARP分流出站)
# 副节点 (赛风多出口、自定义代理出站) 为独立平行系统，拥有独立入站端口与专属路由，绝不受此设置影响
configure_warp_outbound() {
    clear
    echo
    green "============================================================"
    green "  主节点出站管理 (直连出站 / WARP 出站)"
    green "============================================================"
    yellow "  说明: 本设置仅作用于【主节点】入站流量"
    yellow "        副节点(赛风出站、自定义代理出站)为独立平行系统，不受影响"
    echo "============================================================"
    
    if [ ! -f "$WORKDIR/config.json" ]; then
        red "未检测到安装，请先安装主节点"
        return 1
    fi
    
    cd "$WORKDIR"
    
    # 显示当前主节点出站状态
    local current_status=$(cat "$WORKDIR/warp_enabled.txt" 2>/dev/null)
    local current_mode=$(cat "$WORKDIR/warp_mode.txt" 2>/dev/null)
    local current_endpoint=$(cat "$WORKDIR/warp_best_endpoint.txt" 2>/dev/null)
    local current_port=$(cat "$WORKDIR/warp_best_port.txt" 2>/dev/null)
    
    echo
    purple "当前主节点出站状态:"
    if [[ "$current_status" == "true" ]]; then
        if [[ "$current_mode" == "all" ]]; then
            blue "  主节点出站模式: ✓ WARP 全局出站 (全部主节点流量走 WARP)"
        else
            blue "  主节点出站模式: ✓ WARP 分流出站 (Google/YouTube/Netflix/OpenAI 走 WARP)"
        fi
        
        # 显示当前 Endpoint
        if [ -n "$current_endpoint" ]; then
            green "  WARP Endpoint: ${current_endpoint}:${current_port:-2408}"
        else
            yellow "  WARP Endpoint: 默认 (未优选)"
        fi
    else
        green "  主节点出站模式: ✓ 直连出站 (Direct 原生直连)"
    fi
    
    echo
    echo "------------------------------------------------------------"
    yellow "  0. 主节点 - 直连出站 (Direct, 恢复原生出站)"
    yellow "  1. 主节点 - WARP 全局出站 (全部主节点流量走 WARP)"
    yellow "  2. 主节点 - WARP 分流出站 (仅 Google/YouTube/Netflix/OpenAI)"
    echo "------------------------------------------------------------"
    green  "  3. 优选 WARP Endpoint IP (优化连接质量与延迟)"
    blue   "  4. 恢复 Cloudflare 默认 Endpoint"
    blue   "  5. 重新获取勇哥 WARP API 配置"
    green  "  6. 检测主节点 WARP 出口 IP"
    echo "------------------------------------------------------------"
    red    "  7. 返回主菜单"
    echo "============================================================"
    reading "请选择 [0-7]: " new_choice
    
    if [[ "$new_choice" == "7" || "$new_choice" == "" ]]; then
        return 0
    fi
    
    if [[ "$new_choice" == "6" ]]; then
        warp_egress_test
        echo
        reading "按回车键继续..." temp
        return 0
    fi
    
    # 恢复默认 Endpoint
    if [[ "$new_choice" == "4" ]]; then
        echo
        yellow "将恢复 Cloudflare 默认 Endpoint..."
        
        # 检测网络环境选择默认endpoint
        local default_endpoint="162.159.192.1"
        local default_port="2408"
        
        # 检测是否纯IPv6
        local has_ipv4=false
        curl -s4m2 https://www.cloudflare.com/cdn-cgi/trace -k 2>/dev/null | grep -q "h=" && has_ipv4=true
        
        if [ "$has_ipv4" = false ]; then
            default_endpoint="2606:4700:d0::a29f:c001"
        fi
        
        # 清除优选结果
        rm -f "$WORKDIR/warp_best_endpoint.txt"
        rm -f "$WORKDIR/warp_best_port.txt"
        rm -f "$WORKDIR/warp_result_history.txt"
        
        green "默认 Endpoint: $default_endpoint:$default_port"
        
        # 更新配置
        update_warp_config "$default_endpoint" "$default_port" "restart"
        
        green "已恢复默认 Cloudflare Endpoint"
        return 0
    fi
    
    # 重新获取勇哥API配置
    if [[ "$new_choice" == "5" ]]; then
        echo
        yellow "正在重新获取勇哥API配置..."
        
        if init_warp_config; then
            green "WARP 配置已更新:"
            green "  Private Key: ${WARP_PRIVATE_KEY:0:20}..."
            green "  IPv6: $WARP_IPV6"
            green "  Reserved: $WARP_RESERVED"
            
            # 落盘保存最新获取的凭据，防止后方读到旧文件
            echo "$WARP_PRIVATE_KEY" > "$WORKDIR/warp_private_key.txt"
            echo "$WARP_IPV6" > "$WORKDIR/warp_ipv6.txt"
            echo "$WARP_RESERVED" > "$WORKDIR/warp_reserved.txt"
            
            # 重新生成配置
            reading "是否重新生成配置文件? [Y/n]: " regen
            if [[ ! "$regen" =~ ^[Nn]$ ]]; then
                yellow "正在更新配置文件..."
                local warp_endpoint=$(get_warp_endpoint)
                local warp_port=$(cat "$WORKDIR/warp_best_port.txt" 2>/dev/null)
                warp_port=${warp_port:-2408}
                
                update_warp_config "$warp_endpoint" "$warp_port" "restart"
                green "配置已更新并重启服务"
            fi
        else
            red "获取勇哥API配置失败"
        fi
        return 0
    fi
    
    # 如果选择优选 Endpoint
    if [[ "$new_choice" == "3" ]]; then
        if [[ "$current_status" != "true" ]]; then
            yellow "WARP 未启用，是否先启用 WARP?"
            reading "选择模式 (1=全部流量, 2=分流, 其他=取消): " enable_mode
            
            case "$enable_mode" in
                1)
                    if init_warp_config; then
                        WARP_ENABLED=true
                        WARP_MODE="all"
                        echo "true" > "$WORKDIR/warp_enabled.txt"
                        echo "all" > "$WORKDIR/warp_mode.txt"
                        green "已启用 WARP (全部流量)"
                    else
                        red "WARP 配置失败"
                        return 1
                    fi
                    ;;
                2)
                    if init_warp_config; then
                        WARP_ENABLED=true
                        WARP_MODE="google"
                        echo "true" > "$WORKDIR/warp_enabled.txt"
                        echo "google" > "$WORKDIR/warp_mode.txt"
                        green "已启用 WARP (分流模式)"
                    else
                        red "WARP 配置失败"
                        return 1
                    fi
                    ;;
                *)
                    yellow "已取消"
                    return 0
                    ;;
            esac
        fi
        
        echo
        yellow "选择优选模式:"
        yellow "  1. IPv4 优选 (默认)"
        yellow "  2. IPv6 优选"
        reading "请选择 [1-2]: " opt_mode
        
        if [[ "$opt_mode" == "2" ]]; then
            optimize_warp_endpoint 6
        else
            optimize_warp_endpoint
        fi
        return 0
    fi
    
    # 根据选择设置变量
    case "$new_choice" in
        1)
            if init_warp_config; then
                WARP_ENABLED=true
                WARP_MODE="all"
                echo "true" > "$WORKDIR/warp_enabled.txt"
                echo "all" > "$WORKDIR/warp_mode.txt"
                green "已选择: 主节点全部流量通过 WARP 出站"
            else
                red "WARP 配置获取失败"
                return 1
            fi
            ;;
        2)
            if init_warp_config; then
                WARP_ENABLED=true
                WARP_MODE="google"
                echo "true" > "$WORKDIR/warp_enabled.txt"
                echo "google" > "$WORKDIR/warp_mode.txt"
                green "已选择: 主节点 Google/YouTube/Netflix/OpenAI 通过 WARP 出站"
            else
                red "WARP 配置获取失败"
                return 1
            fi
            ;;
        0)
            WARP_ENABLED=false
            WARP_MODE=""
            echo "false" > "$WORKDIR/warp_enabled.txt"
            echo "" > "$WORKDIR/warp_mode.txt"
            green "已选择: 主节点直连出站 (Direct)"
            ;;
        *)
            red "无效选项"
            return 1
            ;;
    esac
    
    echo
    yellow "正在修改配置文件 (严格保持副节点配置与路由隔离)..."
    
    # 备份原配置
    cp config.json config.json.bak.$(date +%Y%m%d%H%M%S)
    green "已备份原配置"
    
    # 获取 WARP 配置
    local warp_endpoint=$(get_warp_endpoint)
    local warp_port=$(cat "$WORKDIR/warp_best_port.txt" 2>/dev/null)
    warp_port=${warp_port:-2408}
    local warp_ipv6="${WARP_IPV6:-2606:4700:110:8d8d:1845:c39f:2dd5:a03a}"
    local warp_private_key="${WARP_PRIVATE_KEY:-52cuYFgCJXp0LAq7+nWJIbCXXgU9eGggOc+Hlfz5u6A=}"
    local warp_reserved="${WARP_RESERVED:-[215, 69, 233]}"
    
    local loopback_port
    loopback_port=$(get_free_loopback_port)
    
    python3 - <<PY
import json
import sys

cfg_path = "config.json"
warp_enabled = "$WARP_ENABLED"
warp_mode = "$WARP_MODE"
warp_endpoint = "$warp_endpoint"
warp_port = int("$warp_port")
warp_ipv6 = "$warp_ipv6"
warp_private_key = "$warp_private_key"
warp_reserved_str = "$warp_reserved"
loopback_port = int("$loopback_port")

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"[!] 读取配置失败: {e}")
    sys.exit(1)

outbounds = data.setdefault("outbounds", [])
route = data.setdefault("route", {})
rules = route.setdefault("rules", [])
inbounds = data.setdefault("inbounds", [])

warp_tag = "warp-out"
inbound_tag = "socks-loopback"

# 1. 严格保护副节点规则：仅移除旧的主节点 WARP 相关规则 (loopback 规则和 WARP 分流域名规则)
def is_warp_or_loopback_rule(r):
    if r.get("inbound") and inbound_tag in r["inbound"]:
        return True
    if r.get("outbound") == warp_tag and ("domain_suffix" in r or "rule_set" in r):
        return True
    return False

rules[:] = [r for r in rules if not is_warp_or_loopback_rule(r)]

# 2. 如果启用 WARP，则追加并更新 warp outbound 以及 socks-loopback inbound
if warp_enabled == "true":
    try:
        warp_reserved = json.loads(warp_reserved_str)
    except Exception:
        warp_reserved = [215, 69, 233]
        
    warp_found = False
    for o in outbounds:
        if o.get("tag") == warp_tag:
            o.clear()
            o.update({
                "type": "wireguard",
                "tag": warp_tag,
                "server": warp_endpoint,
                "server_port": warp_port,
                "local_address": [
                    "172.16.0.2/32",
                    warp_ipv6 if "/" in warp_ipv6 else f"{warp_ipv6}/128"
                ],
                "private_key": warp_private_key,
                "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
                "reserved": warp_reserved,
                "mtu": 1280
            })
            warp_found = True
            break
            
    if not warp_found:
        outbounds.append({
            "type": "wireguard",
            "tag": warp_tag,
            "server": warp_endpoint,
            "server_port": warp_port,
            "local_address": [
                "172.16.0.2/32",
                warp_ipv6 if "/" in warp_ipv6 else f"{warp_ipv6}/128"
            ],
            "private_key": warp_private_key,
            "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
            "reserved": warp_reserved,
            "mtu": 1280
        })

    # 确保 socks-loopback 入站存在
    inbound_found = False
    for ib in inbounds:
        if ib.get("tag") == inbound_tag:
            ib.clear()
            ib.update({
                "tag": inbound_tag,
                "type": "socks",
                "listen": "127.0.0.1",
                "listen_port": loopback_port
            })
            inbound_found = True
            break
    if not inbound_found:
        inbounds.append({
            "tag": inbound_tag,
            "type": "socks",
            "listen": "127.0.0.1",
            "listen_port": loopback_port
        })

    # 插入 loopback 专用路由规则
    rules.insert(0, {
        "inbound": [inbound_tag],
        "outbound": warp_tag
    })

    if warp_mode == "all":
        route["final"] = warp_tag
    elif warp_mode == "google":
        route["final"] = "direct"
        
        # 仅针对 Google/YouTube/OpenAI/Netflix 分流走 WARP
        rules.append({
            "domain_suffix": [
                "google.com", "google.co.jp", "google.com.hk",
                "googleapis.com", "gstatic.com", "ggpht.com",
                "youtube.com", "ytimg.com", "youtu.be",
                "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com",
                "netflix.com", "nflxvideo.net", "nflxso.net"
            ],
            "outbound": warp_tag
        })
else:
    # 移除 warp-out outbound 和 socks-loopback inbound
    outbounds[:] = [o for o in outbounds if o.get("tag") != warp_tag]
    inbounds[:] = [ib for ib in inbounds if ib.get("tag") != inbound_tag]
    
    def first_tag_by_type(t, fallback):
        for o in outbounds:
            if o.get("type") == t and o.get("tag"):
                return o["tag"]
        return fallback
    route["final"] = first_tag_by_type("direct", "direct")

# 3. 规范化 rules 顺序：副节点(自定义代理 / 赛风)规则置顶，确保精准匹配互不干扰
proxy_rules = [r for r in rules if r.get("outbound", "").endswith("-out") and r.get("outbound") != warp_tag]
psi_rules = [r for r in rules if r.get("outbound", "").startswith("psiphon-")]
other_rules = [r for r in rules if r not in proxy_rules and r not in psi_rules]
rules[:] = proxy_rules + psi_rules + other_rules

try:
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print("[+] sing-box 配置文件修改成功 (主节点出站已更新，副节点配置完好保留)")
except Exception as e:
    print(f"[!] 写入配置失败: {e}")
    sys.exit(1)
PY

    if [ $? -ne 0 ]; then
        red "[!] 配置文件修改失败"
        return 1
    fi

    # 验证配置
    SB_BINARY=$(cat sb.txt 2>/dev/null)
    if [ -n "$SB_BINARY" ] && [ -f "$SB_BINARY" ]; then
        yellow "验证配置文件..."
        config_check=$(./"$SB_BINARY" check -c config.json 2>&1)
        if [ $? -ne 0 ]; then
            red "配置验证失败:"
            echo "$config_check" | head -10
            yellow "正在恢复备份..."
            mv config.json.bak.* config.json 2>/dev/null
            return 1
        fi
        green "配置验证通过"
    fi
    
    # 询问是否重启服务
    echo
    reading "是否立即重启服务使配置生效? [Y/n]: " restart_now
    
    if [[ ! "$restart_now" =~ ^[Nn]$ ]]; then
        yellow "正在重启服务..."
        
        # 只重启 sing-box
        pkill -x "$SB_BINARY" >/dev/null 2>&1 || true
        pkill -f "$WORKDIR/$SB_BINARY" >/dev/null 2>&1 || true
        sleep 1
        
        run_detached "$WORKDIR/singbox.pid" "$WORKDIR/singbox.log" \
            ./"$SB_BINARY" run -c config.json
        sleep 2
        
        if pgrep -x "$SB_BINARY" > /dev/null; then
            green "服务重启成功！"
            
            if [[ "$WARP_ENABLED" == "true" ]]; then
                if [[ "$WARP_MODE" == "all" ]]; then
                    blue "✓ 主节点 WARP 出站已启用 (全部主节点流量走 WARP)"
                else
                    blue "✓ 主节点 WARP 出站已启用 (Google/YouTube/Netflix/OpenAI)"
                fi
                # 等待 sing-box 建立连接，然后检测出口 IP
                sleep 2
                warp_egress_test || true
            else
                green "✓ 主节点已切换为直连出站 (Direct)"
            fi
        else
            red "服务重启失败"
            show_singbox_log
            return 1
        fi
    else
        yellow "配置已保存，请手动重启服务使其生效"
    fi
    
    green "操作完成！副节点与现有配置未受任何干扰"
}

# ==================== 自定义代理出站节点组 ====================
# 扩展 Psiphon 多出口框架：支持任意代理协议出站
# 架构: 不同本机IP同一端口(Hy2/TUIC UDP入站) → 路由 → 自定义代理出站
# 支持的出站协议: vless / vmess / trojan / hy2 / hysteria2 / tuic / ss

PROXY_GROUPS_DIR="${WORKDIR}/proxy_groups"

# 初始化代理分组目录
init_proxy_groups_dir() {
    mkdir -p "${PROXY_GROUPS_DIR}" 2>/dev/null
    if [[ ! -f "${PROXY_GROUPS_DIR}/groups.txt" ]]; then
        : > "${PROXY_GROUPS_DIR}/groups.txt"
    else
        # 兼容与修复：如果包含逗号，转为换行符
        if grep -q ',' "${PROXY_GROUPS_DIR}/groups.txt" 2>/dev/null; then
            local content
            content=$(cat "${PROXY_GROUPS_DIR}/groups.txt" | tr ',' '\n' | grep -v '^$')
            echo "$content" > "${PROXY_GROUPS_DIR}/groups.txt"
        fi
    fi
}

# 获取所有代理分组 tag（逐行输出）
get_all_proxy_groups() {
    if [[ -f "${PROXY_GROUPS_DIR}/groups.txt" ]]; then
        grep -v '^$' "${PROXY_GROUPS_DIR}/groups.txt" | sort -t'-' -k2,2n 2>/dev/null || \
        grep -v '^$' "${PROXY_GROUPS_DIR}/groups.txt" | sort -V 2>/dev/null || \
        grep -v '^$' "${PROXY_GROUPS_DIR}/groups.txt" || true
    fi
}

# 检查代理分组是否存在
proxy_group_exists() {
    get_all_proxy_groups | grep -qxF "$1"
}

# 生成唯一分组 tag（proxy-1, proxy-2 ...）
generate_proxy_group_tag() {
    local n=1
    while proxy_group_exists "proxy-${n}" 2>/dev/null || \
          [[ -d "${PROXY_GROUPS_DIR}/proxy-${n}" ]]; do
        ((n++))
    done
    echo "proxy-${n}"
}

# ===== 家宽/机房判定(带缓存) =====
# 缓存文件: IP 类型结果, 每行 "IP R|H|U", 查过不重复查
IP_TYPE_CACHE_FILE="${IP_TYPE_CACHE_FILE:-$HOME/.cache/ip_type_cache.txt}"

# 从节点链接标签解析家宽标记(R=家宽 H=机房 U=未知); 标签格式 CC-NNN[-R|H]-protocol
tag_type() {
    local tag="${1##*#}"
    local seg3
    seg3=$(echo "$tag" | cut -d- -f3)
    case "$seg3" in
        R|H) echo "$seg3" ;;
        *) echo "U" ;;
    esac
}

# 判定 host/ip 的类型: R(家宽) H(机房) U(未知)
# 流程: ① 本地缓存 ② ip-api.com 查 org, 大厂关键词命中→机房 ③ 未中的 ipwho.is 精查 type
detect_ip_type() {
    local host="$1" ip cached j org t
    [[ -z "$host" ]] && { echo "U"; return; }
    ip=$(python3 -c "import socket,sys
try: print(socket.gethostbyname('$host'))
except: print('')" 2>/dev/null)
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "U"; return; }
    cached=$(awk -v k="$ip" '$1==k{print $2; exit}' "$IP_TYPE_CACHE_FILE" 2>/dev/null)
    [[ -n "$cached" ]] && { echo "$cached"; return; }
    j=$(curl -s --max-time 6 "http://ip-api.com/json/$ip?fields=status,org" 2>/dev/null)
    org=$(echo "$j" | jq -r '.org // ""' 2>/dev/null)
    if [[ -z "$org" || "$org" == "null" ]]; then
        t="U"
    elif echo "$org" | grep -qiE 'hinet|chunghwa|china telecom|chinanet|china unicom|chinamobile|ntt |kddi|softbank|vodafone|comcast|verizon|t-mobile|tmobile|deutsche telekom|telekom|british telecom|sky uk|talktalk|virgin media|kt corp|sk telecom|singtel|starhub|telia|telenor|telstra|optus|telefonica|sfr|bouygues|korea telecom'; then
        t="R"
    elif echo "$org" | grep -qiE 'amazon|aws|google|microsoft|azure|ovh|hetzner|digitalocean|digital ocean|vultr|linode|akamai|cloudflare|fastly|contabo|m247|leaseweb|choopa|psychz|datapacket|hostinger|namecheap|ionos|scaleway|serverius|hivelocity|oracle|alibaba|tencent|huawei|ibm|rackspace|equinix|softlayer|godaddy|netlify|vercel|heroku|netcup|stackscale|datacamp|g-core|racknerd|colocrossing|hosting|datacenter|data center|colocation|vps|server|cloud|iomart|oneprovider|redstation|servercore|ucloud|globalit|firstheberg|interserver|internap|terrahost|xyun|idc'; then
        t="H"
    else
        t=$(curl -s --max-time 6 "https://ipwho.is/$ip" 2>/dev/null | jq -r '.type // ""' 2>/dev/null)
        case "$t" in
            isp) t="R" ;;
            hosting|business|education|government) t="H" ;;
            *) t="U" ;;
        esac
    fi
    mkdir -p "$(dirname "$IP_TYPE_CACHE_FILE")" 2>/dev/null
    echo "$ip $t" >> "$IP_TYPE_CACHE_FILE"
    echo "$t"
}

# 多行 URL 列表按 家宽→机房→未知 排序(家宽优先)
sort_relays_by_type() {
    local resi="" hostt="" unkt=""
    while IFS= read -r ln; do
        [[ -z "$ln" ]] && continue
        local h t
        h=$(echo "$ln" | sed -E 's|^[a-z0-9]+://([^@/]*@)?([^:/]+).*|\2|')
        h="${h%%:*}"
        t=$(tag_type "$ln")
        [[ "$t" == "U" ]] && t=$(detect_ip_type "$h")
        case "$t" in
            R) resi+="$ln"$'\n' ;;
            H) hostt+="$ln"$'\n' ;;
            *) unkt+="$ln"$'\n' ;;
        esac
    done <<< "$1"
    printf '%s' "${resi}${hostt}${unkt}"
}

# ==== 代理链接解析（全协议支持）====
# 通过环境变量传入，避免特殊字符转义问题
# 成功: stdout=JSON; 失败: stdout 以 "ERROR: " 开头且退出码非0
parse_proxy_url_to_json() {
    local url="$1"
    local tag="$2"
    PROXY_URL="$url" PROXY_TAG="$tag" python3 - <<'PY'
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
    insec = params.get('insecure', ['0'])[0] == '1' or \
            params.get('allowInsecure', ['0'])[0] == '1'
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
    out = {'type': 'vless', 'tag': tag, 'server': host, 'server_port': p.port,
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
    elif net == 'h2':
        t = {'type': 'http', 'path': path}
        if hdr: t['host'] = [hdr]
        out['transport'] = t
    if tls_s == 'tls':
        tls = {'enabled': True, 'server_name': sni}
        if fp: tls['utls'] = {'enabled': True, 'fingerprint': fp}
        out['tls'] = tls
    return out

def parse_trojan(url, tag):
    p = urlparse(url); params = parse_qs(p.query); host = p.hostname
    out = {'type': 'trojan', 'tag': tag, 'server': host, 'server_port': p.port,
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
    out = {'type': 'hysteria2', 'tag': tag, 'server': host, 'server_port': p.port,
           'password': pw, 'tls': {'enabled': True, 'server_name': sni, 'insecure': insec}}
    if obfs_t: out['obfs'] = {'type': obfs_t, 'password': obfs_p}
    return out

def parse_tuic(url, tag):
    p = urlparse(url); params = parse_qs(p.query); host = p.hostname
    alpn = [a for a in params.get('alpn', ['h3'])[0].split(',') if a] or ['h3']
    sni  = params.get('sni', [host])[0] or host
    insec = params.get('allow_insecure', ['0'])[0] == '1'
    cc   = params.get('congestion_control', ['bbr'])[0]
    return {'type': 'tuic', 'tag': tag, 'server': host, 'server_port': p.port,
            'uuid': unquote(p.username or ''), 'password': unquote(p.password or ''),
            'congestion_control': cc,
            'tls': {'enabled': True, 'server_name': sni, 'alpn': alpn, 'insecure': insec}}

def parse_ss(url, tag):
    p = urlparse(url); host = p.hostname; port = p.port
    if p.username and p.password:
        method = unquote(p.username); password = unquote(p.password)
    else:
        userinfo = unquote(p.username or '')
        try:    method, password = b64d(userinfo).split(':', 1)
        except: method = 'aes-256-gcm'; password = userinfo
    return {'type': 'shadowsocks', 'tag': tag, 'server': host, 'server_port': port,
            'method': method, 'password': password}

def parse_socks5(url, tag):
    import re as _re
    m = _re.match(r'socks5h?://(?:([^:@/]+)(?::([^@/]*))?@)?([^:/]+):(\d+)', url.strip())
    if not m:
        raise ValueError('bad socks5 url')
    user, pwd, host, port = m.group(1), m.group(2), m.group(3), int(m.group(4))
    r = {'type': 'socks', 'tag': tag, 'server': host, 'server_port': port, 'version': '5'}
    if user:
        r['username'] = user
    if pwd:
        r['password'] = pwd
    return r

try:
    if   url.startswith('vless://'):                   r = parse_vless(url, tag)
    elif url.startswith('vmess://'):                   r = parse_vmess(url, tag)
    elif url.startswith('trojan://'):                  r = parse_trojan(url, tag)
    elif url.startswith(('hy2://', 'hysteria2://')):   r = parse_hy2(url, tag)
    elif url.startswith('tuic://'):                    r = parse_tuic(url, tag)
    elif url.startswith('ss://'):                      r = parse_ss(url, tag)
    elif url.startswith('socks5://') or url.startswith('socks5h://'):
        r = parse_socks5(url, tag)
    else:
        print('ERROR: 不支持的协议，支持: vless/vmess/trojan/hy2/hysteria2/tuic/ss')
        sys.exit(1)
    print(json.dumps(r, ensure_ascii=False, indent=2))
except SystemExit:
    raise
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
PY
}

# 验证并解析代理链接 → 成功: stdout=JSON 返回0；失败: 打印错误 返回1
validate_and_parse_proxy_url() {
    local url="$1" tag="${2:-proxy-out}" result rc
    result=$(parse_proxy_url_to_json "$url" "$tag" 2>&1); rc=$?
    if [[ $rc -ne 0 ]] || echo "$result" | grep -q '^ERROR:'; then
        red "[!] 链接解析失败: $(echo "$result" | grep '^ERROR:' | head -1 | sed 's/^ERROR: //')"
        return 1
    fi
    if ! echo "$result" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        red "[!] 生成的 JSON 格式不正确"; return 1
    fi
    echo "$result"; return 0
}

# ==== 添加自定义代理出站节点组（交互式）====
add_proxy_egress_group() {
    init_proxy_groups_dir

    # 确保 ALL_IPS 已加载
    if [[ ${#ALL_IPS[@]} -eq 0 ]]; then
        [[ -f "$WORKDIR/all_ips.txt" ]] && mapfile -t ALL_IPS < "$WORKDIR/all_ips.txt" \
                                        || get_all_ips > /dev/null 2>&1
    fi
    [[ ${#ALL_IPS[@]} -eq 0 ]] && { red "[!] 无法获取本机 IP 列表"; return 1; }

    echo
    green "==== 添加自定义代理出站节点组 ===="
    echo

    # 1. 备注名称
    reading "请输入分组备注名称 (如 美国VPS、JP节点等): " remark
    remark="${remark:-代理节点}"

    # 2. 代理链接
    echo
    yellow "支持的出站链接格式:"
    blue   "  vless://uuid@host:port?security=tls|reality&flow=xtls-rprx-vision&sni=xxx&..."
    blue   "  vmess://base64encodedJSON..."
    blue   "  trojan://password@host:port?security=tls&sni=xxx"
    blue   "  hy2://password@host:port?sni=xxx  或  hysteria2://..."
    blue   "  tuic://uuid:password@host:port?alpn=h3&congestion_control=bbr"
    blue   "  ss://method:password@host:port  或  ss://base64@host:port"
    echo
    reading "请粘贴代理链接: " proxy_url
    proxy_url="${proxy_url// /}"
    [[ -z "$proxy_url" ]] && { red "[!] 链接不能为空"; return 1; }

    # 3. 解析链接
    local group_tag out_tag outbound_json
    group_tag=$(generate_proxy_group_tag)
    out_tag="${group_tag}-out"

    yellow "[*] 正在解析链接..."
    outbound_json=$(validate_and_parse_proxy_url "$proxy_url" "$out_tag")
    [[ $? -ne 0 ]] && return 1

    local ptype pserver pport
    ptype=$(echo "$outbound_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type','?'))" 2>/dev/null)
    pserver=$(echo "$outbound_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('server','?'))" 2>/dev/null)
    pport=$(echo "$outbound_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('server_port','?'))" 2>/dev/null)
    green "[+] 解析成功: [$ptype] $pserver:$pport"

    # 家宽/机房标注(手动链接无 R/H 标记, 走 detect_ip_type + 缓存)
    local ip_type
    ip_type=$(detect_ip_type "$pserver")
    case "$ip_type" in
        R) green  "[+] 节点类型: 家宽 ✓ (住宅 IP, 抗封性强)" ;;
        H) yellow "[+] 节点类型: 机房 (数据中心 IP, 可能易被风控)" ;;
        *) yellow "[+] 节点类型: 未知 (无法判定)" ;;
    esac

    # 4. 询问所需入站协议类型
    echo
    green "==== 选择此出站组所需的入站协议 ===="
    yellow "  1. 仅 Hysteria2 UDP 入站"
    yellow "  2. 仅 TUIC v5   UDP 入站"
    yellow "  3. Hy2 + TUIC   双 UDP 入站"
    reading "  请选择 [1-3]: " proto_type
    
    local need_hy2=false need_tuic=false
    case "$proto_type" in
        1) need_hy2=true ;;
        2) need_tuic=true ;;
        3) need_hy2=true; need_tuic=true ;;
        *) red "[!] 无效选择，默认启用仅 Hysteria2"; need_hy2=true ;;
    esac

    # 收集全局端口占用 (主节点 + 自定义代理组 + 赛风出口组), 全局共享资源池
    local GLOBAL_BINDS=()
    mapfile -t GLOBAL_BINDS < <(collect_global_udp_binds 2>/dev/null || true)
    local used_binds=()
    local used_hy2_ports=()
    local used_tuic_ports=()
    local gb
    for gb in "${GLOBAL_BINDS[@]}"; do
        local gp gpr gip gowner
        IFS='|' read -r gp gpr gip gowner <<< "$gb"
        [[ -z "$gp" ]] && continue
        if [[ "$gpr" == "hy2" ]]; then
            used_binds+=("${gp}|${gip}|hy2")
            local found=false
            for p in "${used_hy2_ports[@]}"; do [[ "$p" == "$gp" ]] && found=true; done
            [[ "$found" == "false" ]] && used_hy2_ports+=("$gp")
        elif [[ "$gpr" == "tuic" ]]; then
            used_binds+=("${gp}|${gip}|tuic")
            local found=false
            for p in "${used_tuic_ports[@]}"; do [[ "$p" == "$gp" ]] && found=true; done
            [[ "$found" == "false" ]] && used_tuic_ports+=("$gp")
        fi
    done

    # 5. 确定 Hysteria2 端口
    local hy2_port=""
    if [[ "$need_hy2" == "true" ]]; then
        if [[ ${#used_hy2_ports[@]} -gt 0 ]]; then
            echo
            yellow "检测到目前已有 Hysteria2 端口: ${used_hy2_ports[*]}"
            yellow "为了节省端口资源（每个账号限额通常为3个），你可以选择复用已有端口，绑定至不同的本机 IP。"
            echo "  1. 复用已有 Hysteria2 端口"
            echo "  2. 申请新的 Hysteria2 端口"
            reading "  请选择 [1-2]: " port_choice
            if [[ "$port_choice" == "1" ]]; then
                echo "已有端口列表 (括号内为占用情况):"
                for i in "${!used_hy2_ports[@]}"; do
                    local hp="${used_hy2_ports[$i]}"
                    local occ=()
                    local gb2
                    for gb2 in "${GLOBAL_BINDS[@]}"; do
                        local gp2 gpr2 gip2 gowner2
                        IFS='|' read -r gp2 gpr2 gip2 gowner2 <<< "$gb2"
                        [[ "$gp2" == "$hp" && "$gpr2" == "hy2" ]] && occ+=("$gip2($gowner2)")
                    done
                    if [[ ${#occ[@]} -eq 0 ]]; then
                        green "  $((i+1)). $hp  [全部 ${#ALL_IPS[@]} 个IP可用]"
                    elif [[ ${#occ[@]} -ge ${#ALL_IPS[@]} ]]; then
                        red "  $((i+1)). $hp  [!! 所有IP已被占用: ${occ[*]}]"
                    else
                        yellow "  $((i+1)). $hp  [可用 $(( ${#ALL_IPS[@]} - ${#occ[@]} ))/${#ALL_IPS[@]} 个IP, 已占用: ${occ[*]}]"
                    fi
                done
                reading "  请选择复用的端口序号: " p_idx
                p_idx=$((p_idx-1))
                if [[ $p_idx -ge 0 && $p_idx -lt ${#used_hy2_ports[@]} ]]; then
                    hy2_port="${used_hy2_ports[$p_idx]}"
                    green "  → 选择复用 Hysteria2 端口: $hy2_port"
                    # 预告该端口在各 IP 上的可用性
                    local free_ips=() occ_ips=()
                    for ip2 in "${ALL_IPS[@]}"; do
                        local ip_occ=false
                        local gb4
                        for gb4 in "${GLOBAL_BINDS[@]}"; do
                            local gp4 gpr4 gip4 gowner4
                            IFS='|' read -r gp4 gpr4 gip4 gowner4 <<< "$gb4"
                            if [[ "$gp4" == "$hy2_port" && "$gpr4" == "hy2" && "$gip4" == "$ip2" ]]; then
                                ip_occ=true; occ_ips+=("$ip2($gowner4)"); break
                            fi
                        done
                        [[ "$ip_occ" == "false" ]] && free_ips+=("$ip2")
                    done
                    yellow "    可用IP: ${free_ips[*]:-无}"
                    [[ ${#occ_ips[@]} -gt 0 ]] && red "    已被占用(将自动跳过): ${occ_ips[*]}"
                else
                    red "  [!] 无效选择，将申请新端口"
                fi
            fi
        fi

        # 如果没有复用，则申请新端口
        if [[ -z "$hy2_port" ]]; then
            yellow "[*] 申请新的 Hysteria2 UDP 端口..."
            local retry=0
            while [[ $retry -lt 30 && -z "$hy2_port" ]]; do
                local cand=$(shuf -i 10000-65535 -n 1)
                if check_port_available_all_ips "$cand" "udp"; then
                    local alloc_result
                    alloc_result=$(devil port add udp "$cand" "singbox-proxy-hy2" 2>&1)
                    if [[ "$alloc_result" == *"succesfully"* || "$alloc_result" == *"Ok"* ]]; then
                        hy2_port="$cand"
                        green "    已成功申请 Hy2 UDP 端口: $hy2_port"
                    fi
                fi
                ((retry++))
            done
            [[ -z "$hy2_port" ]] && { red "[!] Hy2 UDP 端口申请失败"; return 1; }
        fi
    fi

    # 6. 确定 TUIC 端口
    local tuic_port=""
    if [[ "$need_tuic" == "true" ]]; then
        if [[ ${#used_tuic_ports[@]} -gt 0 ]]; then
            echo
            yellow "检测到目前已有 TUIC 端口: ${used_tuic_ports[*]}"
            yellow "为了节省端口资源，建议复用已有端口绑定到不同的本机 IP。"
            echo "  1. 复用已有 TUIC 端口"
            echo "  2. 申请新的 TUIC 端口"
            reading "  请选择 [1-2]: " port_choice
            if [[ "$port_choice" == "1" ]]; then
                echo "已有端口列表 (括号内为占用情况):"
                for i in "${!used_tuic_ports[@]}"; do
                    local tp="${used_tuic_ports[$i]}"
                    local tocc=()
                    local gb3
                    for gb3 in "${GLOBAL_BINDS[@]}"; do
                        local gp3 gpr3 gip3 gowner3
                        IFS='|' read -r gp3 gpr3 gip3 gowner3 <<< "$gb3"
                        [[ "$gp3" == "$tp" && "$gpr3" == "tuic" ]] && tocc+=("$gip3($gowner3)")
                    done
                    if [[ ${#tocc[@]} -eq 0 ]]; then
                        green "  $((i+1)). $tp  [全部 ${#ALL_IPS[@]} 个IP可用]"
                    elif [[ ${#tocc[@]} -ge ${#ALL_IPS[@]} ]]; then
                        red "  $((i+1)). $tp  [!! 所有IP已被占用: ${tocc[*]}]"
                    else
                        yellow "  $((i+1)). $tp  [可用 $(( ${#ALL_IPS[@]} - ${#tocc[@]} ))/${#ALL_IPS[@]} 个IP, 已占用: ${tocc[*]}]"
                    fi
                done
                reading "  请选择复用的端口序号: " p_idx
                p_idx=$((p_idx-1))
                if [[ $p_idx -ge 0 && $p_idx -lt ${#used_tuic_ports[@]} ]]; then
                    tuic_port="${used_tuic_ports[$p_idx]}"
                    green "  → 选择复用 TUIC 端口: $tuic_port"
                    # 预告该端口在各 IP 上的可用性
                    local tfree_ips=() tocc_ips=()
                    for ip2 in "${ALL_IPS[@]}"; do
                        local tip_occ=false
                        local gb5
                        for gb5 in "${GLOBAL_BINDS[@]}"; do
                            local gp5 gpr5 gip5 gowner5
                            IFS='|' read -r gp5 gpr5 gip5 gowner5 <<< "$gb5"
                            if [[ "$gp5" == "$tuic_port" && "$gpr5" == "tuic" && "$gip5" == "$ip2" ]]; then
                                tip_occ=true; tocc_ips+=("$ip2($gowner5)"); break
                            fi
                        done
                        [[ "$tip_occ" == "false" ]] && tfree_ips+=("$ip2")
                    done
                    yellow "    可用IP: ${tfree_ips[*]:-无}"
                    [[ ${#tocc_ips[@]} -gt 0 ]] && red "    已被占用(将自动跳过): ${tocc_ips[*]}"
                else
                    red "  [!] 无效选择，将申请新端口"
                fi
            fi
        fi

        # 如果没有复用，则申请新端口
        if [[ -z "$tuic_port" ]]; then
            yellow "[*] 申请新的 TUIC UDP 端口..."
            local retry=0
            while [[ $retry -lt 30 && -z "$tuic_port" ]]; do
                local cand=$(shuf -i 10000-65535 -n 1)
                if check_port_available_all_ips "$cand" "udp"; then
                    local alloc_result
                    alloc_result=$(devil port add udp "$cand" "singbox-proxy-tuic" 2>&1)
                    if [[ "$alloc_result" == *"succesfully"* || "$alloc_result" == *"Ok"* ]]; then
                        tuic_port="$cand"
                        green "    已成功申请 TUIC UDP 端口: $tuic_port"
                    fi
                fi
                ((retry++))
            done
            if [[ -z "$tuic_port" ]]; then
                red "[!] TUIC UDP 端口申请失败"
                local is_new_hy2=true
                for p in "${used_hy2_ports[@]}"; do [[ "$p" == "$hy2_port" ]] && is_new_hy2=false; done
                if [[ "$is_new_hy2" == "true" && -n "$hy2_port" ]]; then
                    devil port del udp "$hy2_port" > /dev/null 2>&1
                fi
                return 1
            fi
        fi
    fi

    # 7. 为每个 IP 选择是否绑定
    echo
    green "==== 配置入站 IP ===="
    blue  "在此步骤，你将选择哪些 IP 映射到此出站组"
    echo

    local ip_protos=()
    for i in "${!ALL_IPS[@]}"; do
        local ip="${ALL_IPS[$i]}"
        local st=$(cat "$WORKDIR/ip_status_${ip}.txt" 2>/dev/null)
        local st_str=""
        [[ "$st" == "Available" ]] && st_str=" [大陆可用]"
        [[ "$st" == "Blocked"   ]] && st_str=" [被墙]"
        
        # 探测是否在选定的端口上已被绑定
        local hy2_already_used=false
        local tuic_already_used=false
        
        if [[ "$need_hy2" == "true" ]]; then
            for b in "${used_binds[@]}"; do
                if [[ "$b" == "${hy2_port}|${ip}|hy2" ]]; then
                    hy2_already_used=true
                    break
                fi
            done
        fi
        
        if [[ "$need_tuic" == "true" ]]; then
            for b in "${used_binds[@]}"; do
                if [[ "$b" == "${tuic_port}|${ip}|tuic" ]]; then
                    tuic_already_used=true
                    break
                fi
            done
        fi

        echo
        blue "  IP[$((i+1))]: $ip${st_str}"

        local can_hy2=false
        local can_tuic=false
        [[ "$need_hy2" == "true" && "$hy2_already_used" == "false" ]] && can_hy2=true
        [[ "$need_tuic" == "true" && "$tuic_already_used" == "false" ]] && can_tuic=true

        if [[ "$can_hy2" == "false" && "$can_tuic" == "false" ]]; then
            if [[ "$need_hy2" == "true" && "$need_tuic" == "true" ]]; then
                yellow "    [自动跳过] 该 IP 的 Hysteria2(端口 ${hy2_port}) 和 TUIC(端口 ${tuic_port}) 均已被其它节点组占用，无法在此 IP 上绑定双入站。"
            elif [[ "$need_hy2" == "true" ]]; then
                yellow "    [自动跳过] 该 IP 的 Hysteria2(端口 ${hy2_port}) 已被其它节点组占用，无需选择。"
            else
                yellow "    [自动跳过] 该 IP 的 TUIC(端口 ${tuic_port}) 已被其它节点组占用，无需选择。"
            fi
            continue
        fi

        if [[ "$can_hy2" == "true" && "$can_tuic" == "true" ]]; then
            yellow "    1. 启用 Hysteria2 + TUIC 双入站"
            yellow "    2. 仅启用 Hysteria2 入站"
            yellow "    3. 仅启用 TUIC 入站"
            yellow "    0. 跳过此 IP"
            reading "    选择 [0-3]: " pc
            case "$pc" in
                1) ip_protos+=("${ip}|both"); green "    → 绑定 Hysteria2 + TUIC" ;;
                2) ip_protos+=("${ip}|hy2");  green "    → 仅绑定 Hysteria2" ;;
                3) ip_protos+=("${ip}|tuic"); green "    → 仅绑定 TUIC" ;;
                *) yellow "    → 跳过 $ip" ;;
            esac
        elif [[ "$can_hy2" == "true" ]]; then
            if [[ "$need_tuic" == "true" ]]; then
                yellow "    (此 IP 在端口 ${tuic_port} 上已被别的组占用 TUIC)"
            fi
            yellow "    1. 启用 Hysteria2 入站"
            yellow "    0. 跳过此 IP"
            reading "    选择 [0-1]: " pc
            case "$pc" in
                1) ip_protos+=("${ip}|hy2"); green "    → 仅绑定 Hysteria2" ;;
                *) yellow "    → 跳过 $ip" ;;
            esac
        elif [[ "$can_tuic" == "true" ]]; then
            if [[ "$need_hy2" == "true" ]]; then
                yellow "    (此 IP 在端口 ${hy2_port} 上已被别的组占用 Hysteria2)"
            fi
            yellow "    1. 启用 TUIC 入站"
            yellow "    0. 跳过此 IP"
            reading "    选择 [0-1]: " pc
            case "$pc" in
                1) ip_protos+=("${ip}|tuic"); green "    → 仅绑定 TUIC" ;;
                *) yellow "    → 跳过 $ip" ;;
            esac
        fi
    done

    if [[ ${#ip_protos[@]} -eq 0 ]]; then
        red "[!] 未绑定任何 IP，操作取消。"
        local is_new_hy2=true
        for p in "${used_hy2_ports[@]}"; do [[ "$p" == "$hy2_port" ]] && is_new_hy2=false; done
        if [[ "$is_new_hy2" == "true" && -n "$hy2_port" ]]; then
            devil port del udp "$hy2_port" > /dev/null 2>&1
        fi
        local is_new_tuic=true
        for p in "${used_tuic_ports[@]}"; do [[ "$p" == "$tuic_port" ]] && is_new_tuic=false; done
        if [[ "$is_new_tuic" == "true" && -n "$tuic_port" ]]; then
            devil port del udp "$tuic_port" > /dev/null 2>&1
        fi
        return 1
    fi

    # 8. 保存分组数据
    local group_dir="${PROXY_GROUPS_DIR}/${group_tag}"
    mkdir -p "$group_dir"
    echo "proxy"          > "$group_dir/type.txt"
    echo "$remark"        > "$group_dir/remark.txt"
    echo "$proxy_url"     > "$group_dir/proxy_url.txt"
    echo "$outbound_json" > "$group_dir/outbound.json"
    printf '%s\n' "${ip_protos[@]}" > "$group_dir/ip_protos.txt"
    [[ -n "$hy2_port"  ]] && echo "$hy2_port"  > "$group_dir/hy2_port.txt"
    [[ -n "$tuic_port" ]] && echo "$tuic_port" > "$group_dir/tuic_port.txt"

    # 注册到分组列表 (一行一个)
    echo "$group_tag" >> "${PROXY_GROUPS_DIR}/groups.txt"

    # 9. 同步到 sing-box 配置
    yellow "[*] 更新 sing-box 配置..."
    if ! sync_proxy_group_to_singbox "$group_tag"; then
        red "[!] 配置更新失败，正在回滚..."
        rm -rf "$group_dir"
        
        local temp_file
        temp_file=$(mktemp)
        get_all_proxy_groups | grep -vxF "$group_tag" > "$temp_file"
        mv "$temp_file" "${PROXY_GROUPS_DIR}/groups.txt"
        
        local is_new_hy2=true
        for p in "${used_hy2_ports[@]}"; do [[ "$p" == "$hy2_port" ]] && is_new_hy2=false; done
        if [[ "$is_new_hy2" == "true" && -n "$hy2_port" ]]; then
            devil port del udp "$hy2_port" > /dev/null 2>&1
        fi
        local is_new_tuic=true
        for p in "${used_tuic_ports[@]}"; do [[ "$p" == "$tuic_port" ]] && is_new_tuic=false; done
        if [[ "$is_new_tuic" == "true" && -n "$tuic_port" ]]; then
            devil port del udp "$tuic_port" > /dev/null 2>&1
        fi
        return 1
    fi

    # 10. 重启 sing-box
    yellow "[*] 重启 sing-box..."
    start_singbox || { red "[!] sing-box 重启失败"; return 1; }

    echo
    green "==== ✓ 节点组 [$remark] ($group_tag) 添加完成 ===="
    echo
    generate_proxy_group_links "$group_tag"
    return 0
}

# ==== 同步代理分组到 sing-box config.json ====
# 使用 sys.argv 传参避免 shell 特殊字符转义问题
sync_proxy_group_to_singbox() {
    local group_tag="$1"
    local group_dir="${PROXY_GROUPS_DIR}/${group_tag}"
    local cfg="$WORKDIR/config.json"

    [[ -f "$cfg" ]]                        || { red "[!] sing-box 配置不存在"; return 1; }
    [[ -d "$group_dir" ]]                  || { red "[!] 分组目录不存在: $group_dir"; return 1; }
    [[ -f "$group_dir/outbound.json" ]]    || { red "[!] outbound.json 不存在"; return 1; }
    [[ -f "$group_dir/ip_protos.txt"  ]]   || { red "[!] ip_protos.txt 不存在"; return 1; }

    local hy2_port=$(cat  "$group_dir/hy2_port.txt"  2>/dev/null | grep -oE '[0-9]+' | head -n1 || echo "0")
    local tuic_port=$(cat "$group_dir/tuic_port.txt" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || echo "0")
    hy2_port=${hy2_port:-0}
    tuic_port=${tuic_port:-0}
    local uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null)
    local out_tag="${group_tag}-out"

    cp "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null

    python3 - \
        "$cfg" \
        "$group_tag" \
        "$out_tag" \
        "${hy2_port:-0}" \
        "${tuic_port:-0}" \
        "$uuid" \
        "$WORKDIR" \
        "$group_dir/outbound.json" \
        "$group_dir/ip_protos.txt" <<'PY'
import json, sys

cfg_path    = sys.argv[1]
group_tag   = sys.argv[2]
out_tag     = sys.argv[3]
hy2_port    = int(sys.argv[4]) if sys.argv[4] else 0
tuic_port   = int(sys.argv[5]) if sys.argv[5] else 0
uuid        = sys.argv[6]
workdir     = sys.argv[7]
outbound_f  = sys.argv[8]
ip_protos_f = sys.argv[9]

try:
    with open(outbound_f, 'r', encoding='utf-8') as f:
        outbound_obj = json.load(f)
except Exception as e:
    print(f'[!] 读取 outbound.json 失败: {e}'); sys.exit(1)

ip_protos = []
try:
    with open(ip_protos_f, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if '|' in line:
                ip, proto = line.split('|', 1)
                ip_protos.append({'ip': ip.strip(), 'proto': proto.strip()})
except Exception as e:
    print(f'[!] 读取 ip_protos.txt 失败: {e}'); sys.exit(1)

try:
    with open(cfg_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception as e:
    print(f'[!] 读取 config.json 失败: {e}'); sys.exit(1)

inbounds  = data.setdefault('inbounds',  [])
outbounds = data.setdefault('outbounds', [])
route     = data.setdefault('route',     {})
rules     = route.setdefault('rules',    [])

# 更新 outbound（先移除旧的同 tag 配置）
outbounds[:] = [o for o in outbounds if o.get('tag') != out_tag]
outbounds.append(outbound_obj)

# 移除本分组旧的 inbound
def is_mine(ib):
    t = ib.get('tag', '')
    return t.startswith(f'hy2-{group_tag}-') or t.startswith(f'tuic-{group_tag}-')
inbounds[:] = [ib for ib in inbounds if not is_mine(ib)]

cert = f'{workdir}/cert.pem'
key  = f'{workdir}/private.key'
inbound_tags = []

for entry in ip_protos:
    ip    = entry['ip']
    proto = entry['proto']  # 'hy2' | 'tuic' | 'both'
    # 用下划线替换点/冒号，保证 tag 合法
    safe = ip.replace(':', '_').replace('.', '_')

    if proto in ('hy2', 'both') and hy2_port > 0:
        t = f'hy2-{group_tag}-{safe}'
        inbound_tags.append(t)
        inbounds.append({
            'type': 'hysteria2', 'tag': t,
            'listen': ip, 'listen_port': hy2_port,
            'users': [{'password': uuid}],
            'masquerade': 'https://www.bing.com',
            'ignore_client_bandwidth': False,
            'tls': {'enabled': True, 'alpn': ['h3'],
                    'certificate_path': cert, 'key_path': key}
        })

    if proto in ('tuic', 'both') and tuic_port > 0:
        t = f'tuic-{group_tag}-{safe}'
        inbound_tags.append(t)
        inbounds.append({
            'type': 'tuic', 'tag': t,
            'listen': ip, 'listen_port': tuic_port,
            'users': [{'uuid': uuid, 'password': uuid}],
            'congestion_control': 'bbr',
            'tls': {'enabled': True, 'alpn': ['h3'],
                    'certificate_path': cert, 'key_path': key}
        })

# 更新路由规则（移除旧规则，在最前插入新规则）
rules[:] = [r for r in rules if r.get('outbound') != out_tag]
if inbound_tags:
    rules.insert(0, {'inbound': inbound_tags, 'outbound': out_tag})

try:
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f'[+] 配置已更新: {group_tag} → {len(ip_protos)} 个IP, {len(inbound_tags)} 个inbound')
except Exception as e:
    print(f'[!] 写入 config.json 失败: {e}'); sys.exit(1)
PY
    return $?
}

# ==== 删除代理出站节点组 ====
remove_proxy_egress_group() {
    local group_tag="$1"
    local group_dir="${PROXY_GROUPS_DIR}/${group_tag}"

    if ! proxy_group_exists "$group_tag"; then
        yellow "[*] 代理分组 $group_tag 不存在"; return 0
    fi

    local remark=$(cat "$group_dir/remark.txt" 2>/dev/null || echo "$group_tag")
    local out_tag="${group_tag}-out"
    yellow "[*] 正在删除代理节点组: $remark ($group_tag)"

    # 释放端口（检测是否有其它组在使用）
    local hy2_port=$(cat  "$group_dir/hy2_port.txt"  2>/dev/null)
    local tuic_port=$(cat "$group_dir/tuic_port.txt" 2>/dev/null)
    
    local other_groups=()
    for og in $(get_all_proxy_groups); do
        [[ "$og" != "$group_tag" ]] && other_groups+=("$og")
    done
    
    if [[ -n "$hy2_port" ]]; then
        local hy2_in_use=false
        for og in "${other_groups[@]}"; do
            local og_hy2=$(cat "${PROXY_GROUPS_DIR}/${og}/hy2_port.txt" 2>/dev/null)
            [[ "$og_hy2" == "$hy2_port" ]] && hy2_in_use=true
        done
        if [[ "$hy2_in_use" == "false" ]]; then
            devil port del udp "$hy2_port" > /dev/null 2>&1
            yellow "  已释放 Hysteria2 UDP 端口: $hy2_port"
        else
            yellow "  Hysteria2 端口 $hy2_port 仍被其它组复用，不执行释放"
        fi
    fi
    
    if [[ -n "$tuic_port" ]]; then
        local tuic_in_use=false
        for og in "${other_groups[@]}"; do
            local og_tuic=$(cat "${PROXY_GROUPS_DIR}/${og}/tuic_port.txt" 2>/dev/null)
            [[ "$og_tuic" == "$tuic_port" ]] && tuic_in_use=true
        done
        if [[ "$tuic_in_use" == "false" ]]; then
            devil port del udp "$tuic_port" > /dev/null 2>&1
            yellow "  已释放 TUIC UDP 端口: $tuic_port"
        else
            yellow "  TUIC 端口 $tuic_port 仍被其它组复用，不执行释放"
        fi
    fi

    # 从 config.json 移除相关配置
    local cfg="$WORKDIR/config.json"
    if [[ -f "$cfg" ]]; then
        python3 - "$cfg" "$group_tag" "$out_tag" <<'PY'
import json, sys
cfg_path = sys.argv[1]; group_tag = sys.argv[2]; out_tag = sys.argv[3]
try:
    with open(cfg_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    def is_mine(ib):
        t = ib.get('tag', '')
        return t.startswith(f'hy2-{group_tag}-') or t.startswith(f'tuic-{group_tag}-')
    data.get('inbounds',  [])[:] = [i for i in data.get('inbounds',  []) if not is_mine(i)]
    data.get('outbounds', [])[:] = [o for o in data.get('outbounds', []) if o.get('tag') != out_tag]
    data.get('route', {}).get('rules', [])[:] = \
        [r for r in data.get('route', {}).get('rules', []) if r.get('outbound') != out_tag]
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f'[+] 已从配置移除: {group_tag}')
except Exception as e:
    print(f'[!] 配置更新失败: {e}')
PY
    fi

    local temp_file
    temp_file=$(mktemp)
    get_all_proxy_groups | grep -vxF "$group_tag" > "$temp_file"
    mv "$temp_file" "${PROXY_GROUPS_DIR}/groups.txt"
    rm -rf "$group_dir" 2>/dev/null

    start_singbox
    green "[+] 已删除代理节点组: $remark"
}

# ==== 生成代理分组节点链接 ====
generate_proxy_group_links() {
    local group_tag="$1"
    local group_dir="${PROXY_GROUPS_DIR}/${group_tag}"

    local remark=$(cat   "$group_dir/remark.txt"   2>/dev/null || echo "$group_tag")
    local hy2_port=$(cat "$group_dir/hy2_port.txt"  2>/dev/null)
    local tuic_port=$(cat "$group_dir/tuic_port.txt" 2>/dev/null)
    local uuid=$(cat "$WORKDIR/UUID.txt" 2>/dev/null)

    echo
    green "========== 代理节点组 [$remark] 节点链接 =========="

    if [[ ! -f "$group_dir/ip_protos.txt" ]]; then
        yellow "  暂无入站配置"; echo "=================================================="; return
    fi

    while IFS='|' read -r ip proto; do
        [[ -z "$ip" ]] && continue
        echo
        if [[ "$proto" == "hy2" || "$proto" == "both" ]] && [[ -n "$hy2_port" ]]; then
            local name="${remark}-Hy2-${ip}"
            local link="hysteria2://${uuid}@${ip}:${hy2_port}?insecure=1&sni=${HOSTNAME}#${name}"
            purple "Hysteria2 | 入站: $ip:$hy2_port → 出站: $remark"
            echo "$link"
        fi
        if [[ "$proto" == "tuic" || "$proto" == "both" ]] && [[ -n "$tuic_port" ]]; then
            local name="${remark}-TUIC-${ip}"
            local link="tuic://${uuid}:${uuid}@${ip}:${tuic_port}?congestion_control=bbr&alpn=h3&allow_insecure=1#${name}"
            purple "TUIC v5   | 入站: $ip:$tuic_port → 出站: $remark"
            echo "$link"
        fi
    done < "$group_dir/ip_protos.txt"
    echo "=================================================="
}

# 重启时同步所有代理分组配置（供 restart_processes 等调用）
sync_all_proxy_groups() {
    init_proxy_groups_dir
    local groups
    mapfile -t groups < <(get_all_proxy_groups)
    [[ ${#groups[@]} -eq 0 ]] && return 0

    # 检查基础 config.json 是否有效，如损毁或缺失自动重新构建
    if [[ ! -f "$WORKDIR/config.json" ]] || ! python3 -c "import json, sys; json.load(open('$WORKDIR/config.json'))" >/dev/null 2>&1; then
        yellow "[!] 监测到 config.json 损毁或格式异常，正在重新生成基础配置..."
        generate_singbox_config 2>/dev/null || true
    fi

    yellow "[*] 同步代理分组配置 (共 ${#groups[@]} 个)..."
    for tag in "${groups[@]}"; do
        [[ -d "${PROXY_GROUPS_DIR}/${tag}" ]] && sync_proxy_group_to_singbox "$tag"
    done
    return 0
}


# ==================== OpenRung 中继网络 (移植自 hxzl666/singbox upstream) ====================
add_openrung_egress_group() {
    init_proxy_groups_dir

    if [[ ${#ALL_IPS[@]} -eq 0 ]]; then
        [[ -f "$WORKDIR/all_ips.txt" ]] && mapfile -t ALL_IPS < "$WORKDIR/all_ips.txt" \
                                        || get_all_ips > /dev/null 2>&1
    fi
    [[ ${#ALL_IPS[@]} -eq 0 ]] && { red "[!] 无法获取本机 IP 列表"; return 1; }

    echo
    green "==== 一键添加 OpenRung 中继节点 (按国家分类) ===="
    yellow "[*] 正在从 OpenRung Broker 获取最新中继列表..."
    echo

    local relays_json relays_count
    relays_json=$(curl -s --max-time 15 -H "User-Agent: openrung/0.3.8" "https://broker.openrung.org/api/v1/relays?limit=20" 2>/dev/null)
    if ! echo "$relays_json" | jq -e '.relays | type == "array"' >/dev/null 2>&1; then
        red "[!] 获取 OpenRung 中继列表失败 (网络不通或服务不可用)"
        return 1
    fi
    relays_count=$(echo "$relays_json" | jq '.relays | length')
    if [[ "$relays_count" -eq 0 ]]; then
        red "[!] 当前无可用中继"
        return 1
    fi

    local cc_summary
    cc_summary=$(echo "$relays_json" | jq -r '
        [.relays[] | {cc: (.country_code // "?"), cn: (.country // "?"), city: (.city // "?"), host: .public_host, port: .public_port, uuid: .client_id, pbk: .reality_public_key, sid: .short_id}]
        | group_by(.cc)
        | map({cc: .[0].cc, cn: .[0].cn, count: length, relays: .})
        | sort_by(-.count)
        | .[] | [.cc, .cn, (.relays | length), ([.relays[].city] | unique | join("/"))] | @tsv'
    )

    echo "------------------------------------------------------------"
    echo "  共获取到 $relays_count 个中继, 按国家分类如下:"
    echo "------------------------------------------------------------"
    local -a cc_list=() cn_list=() cnt_list=() cities_list=()
    local cc_idx=0
    while IFS=$'\t' read -r cc cn cnt cities; do
        [[ -z "$cc" ]] && continue
        cc_list+=("$cc"); cn_list+=("$cn"); cnt_list+=("$cnt"); cities_list+=("$cities")
        ((cc_idx++))
        yellow "  [$cc_idx] [$cc] $cn (${cnt}个中继: $cities)"
    done < <(echo "$cc_summary")

    echo "------------------------------------------------------------"
    echo "  支持: 单个编号 (如 3) | 多个 (如 1,3,5) | 范围 (如 2-4) | 全部 (a)"
    reading "  请选择要添加的国家: " sel

    if [[ -z "$sel" ]]; then
        red "[!] 未选择任何国家"
        return 1
    fi

    local -a pick_cc=()
    if [[ "$sel" == "a" || "$sel" == "A" || "$sel" == "all" ]]; then
        for ((i=0; i<${#cc_list[@]}; i++)); do pick_cc+=("$i"); done
    else
        local tok
        local old_ifs="$IFS"; IFS=','
        for tok in $sel; do
            tok=$(echo "$tok" | tr -d ' ')
            if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
                for ((i=s; i<=e; i++)); do
                    [[ $i -ge 1 && $i -le ${#cc_list[@]} ]] && pick_cc+=("$((i-1))")
                done
            elif [[ "$tok" =~ ^[0-9]+$ ]]; then
                [[ $tok -ge 1 && $tok -le ${#cc_list[@]} ]] && pick_cc+=("$((tok-1))")
            fi
        done
        IFS="$old_ifs"
    fi

    if [[ ${#pick_cc[@]} -eq 0 ]]; then
        red "[!] 选择无效"
        return 1
    fi

    echo
    purple "请选择本地入站协议:"
    echo "  1. Hysteria2 入站"
    echo "  2. TUIC v5 入站"
    echo "  3. VLESS-Reality 入站"
    echo "  4. 同时开启 Hy2 与 TUIC"
    reading "请选择 [1-4, 默认4]: " oproto
    [[ -z "$oproto" ]] && oproto="4"

    # 收集现有代理组端口 (serv00 端口受限, 优先复用)
    local used_hy2_ports=() used_tuic_ports=()
    local g
    for g in $(get_all_proxy_groups); do
        local g_dir="${PROXY_GROUPS_DIR}/$g"
        [[ -d "$g_dir" ]] || continue
        local h_p=$(cat "$g_dir/hy2_port.txt" 2>/dev/null | grep -oE '[0-9]+' | head -n1)
        local t_p=$(cat "$g_dir/tuic_port.txt" 2>/dev/null | grep -oE '[0-9]+' | head -n1)
        [[ -n "$h_p" ]] && used_hy2_ports+=("$h_p")
        [[ -n "$t_p" ]] && used_tuic_ports+=("$t_p")
    done

    # 辅助: 复用已有端口或 devil 申请新端口 (serv00 模式)
    alloc_or_port() {
        local ptype="$1"   # hy2|tuic|vless
        local -a used_ports=("${@:2}")
        local chosen=""
        if [[ ${#used_ports[@]} -gt 0 ]]; then
            echo
            yellow "已有 ${ptype^^} 端口: ${used_ports[*]} (端口受限, 建议复用)"
            echo "  1. 复用已有端口"
            echo "  2. 申请新端口"
            reading "  请选择 [1-2, 默认1]: " p_choice
            [[ -z "$p_choice" ]] && p_choice="1"
            if [[ "$p_choice" == "1" ]]; then
                for i in "${!used_ports[@]}"; do
                    yellow "  $((i+1)). ${used_ports[$i]}"
                done
                reading "  请选择端口序号 [1-${#used_ports[@]}]: " p_idx
                p_idx=$((p_idx-1))
                if [[ $p_idx -ge 0 && $p_idx -lt ${#used_ports[@]} ]]; then
                    chosen="${used_ports[$p_idx]}"
                    green "  → 复用 ${ptype^^} 端口: $chosen"
                else
                    red "  [!] 无效选择, 将申请新端口"
                fi
            fi
        fi
        if [[ -z "$chosen" ]]; then
            yellow "[*] 申请新的 ${ptype^^} 端口..."
            local retry=0
            while [[ $retry -lt 30 && -z "$chosen" ]]; do
                local cand=$(shuf -i 10000-65535 -n 1)
                if check_port_available_all_ips "$cand" "tcp"; then
                    local alloc_result
                    alloc_result=$(devil port add tcp "$cand" "singbox-or-${ptype}" 2>&1)
                    if [[ "$alloc_result" == *"succesfully"* || "$alloc_result" == *"Ok"* ]]; then
                        chosen="$cand"
                        green "    已成功申请 ${ptype^^} TCP 端口: $chosen"
                    fi
                fi
                ((retry++))
            done
            [[ -z "$chosen" ]] && red "[!] ${ptype^^} 端口申请失败"
        fi
        echo "$chosen"
    }

    local added=0 failed=0
    for ci in "${pick_cc[@]}"; do
        local ccc="${cc_list[$ci]}" cname="${cn_list[$ci]}" ccity="${cities_list[$ci]}"
        local remark="OpenRung-${ccc}"

        local relay_urls
        relay_urls=$(echo "$relays_json" | jq -r --arg cc "$ccc" '
            [.relays[] | select((.country_code // "?") == $cc)]
            | sort_by(.registered_at)
            | .[] | "vless://\(.client_id)@\(.public_host):\(.public_port)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=\(.server_name // "www.cloudflare.com")&fp=chrome&pbk=\(.reality_public_key)&sid=\(.short_id)&type=tcp"' 2>/dev/null)
        [[ -z "$relay_urls" ]] && { red "[✗] [$remark] 无可用中继, 跳过"; ((failed++)); continue; }

        # 家宽优先排序(查缓存/API 标注, 首个=当前激活=家宽优先)
        local sorted_urls
        sorted_urls=$(sort_relays_by_type "$relay_urls")
        relay_urls="$sorted_urls"

        local first_url
        first_url=$(echo "$relay_urls" | head -n 1 | tr -d ' \r\n')
        [[ -z "$first_url" ]] && { red "[✗] [$remark] 中继链接为空, 跳过"; ((failed++)); continue; }

        local group_tag
        group_tag=$(generate_proxy_group_tag)

        local out_json
        out_json=$(validate_and_parse_proxy_url "$first_url" "${group_tag}-out")
        if [[ $? -ne 0 || -z "$out_json" ]]; then
            red "[✗] [$remark] 链接解析失败, 跳过"
            ((failed++))
            continue
        fi

        # 按选择分配端口 (hy2/tuic 走 UDP 需 devil udp 端口; 这里与 add_proxy_egress_group 的申请逻辑对齐)
        local hy2_port_p="0" tuic_port_p="0" vless_port_p="0"
        case "$oproto" in
            1) hy2_port_p=$(alloc_or_port "hy2" "${used_hy2_ports[@]}") ;;
            2) tuic_port_p=$(alloc_or_port "tuic" "${used_tuic_ports[@]}") ;;
            3) vless_port_p=$(alloc_or_port "vless" "${used_tuic_ports[@]}") ;;
            *) hy2_port_p=$(alloc_or_port "hy2" "${used_hy2_ports[@]}")
               tuic_port_p=$(alloc_or_port "tuic" "${used_tuic_ports[@]}") ;;
        esac
        [[ "$hy2_port_p" == "0" && "$tuic_port_p" == "0" && "$vless_port_p" == "0" ]] && { red "[✗] [$remark] 端口分配失败, 跳过"; ((failed++)); continue; }

        local gdir="${PROXY_GROUPS_DIR}/${group_tag}"
        mkdir -p "$gdir"
        echo "$remark" > "$gdir/remark.txt"
        echo "$ccc" > "$gdir/country.txt"
        echo "$relay_urls" > "$gdir/relays.txt"
        echo "0" > "$gdir/active_idx.txt"
        echo "$first_url" > "$gdir/raw_url.txt"
        echo "$out_json" > "$gdir/outbound.json"
        echo "$hy2_port_p" > "$gdir/hy2_port.txt"
        echo "$tuic_port_p" > "$gdir/tuic_port.txt"
        echo "$vless_port_p" > "$gdir/vless_port.txt"
        : > "$gdir/ip_protos.txt"
        local ip_proto=""
        case "$oproto" in
            1) ip_proto="hy2" ;;
            2) ip_proto="tuic" ;;
            3) ip_proto="vless" ;;
            *) ip_proto="both" ;;
        esac
        for ip in "${ALL_IPS[@]}"; do
            echo "${ip}|${ip_proto}" >> "$gdir/ip_protos.txt"
        done

        if sync_proxy_group_to_singbox "$group_tag"; then
            if ! grep -qx "$group_tag" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null; then
                echo "$group_tag" >> "$PROXY_GROUPS_DIR/groups.txt"
            fi
            if start_singbox_safe; then
                green "[✓] OpenRung [$remark] 建组成功! (标识: $group_tag, 备用中继: $(echo "$relay_urls" | wc -l) 个)"
                generate_proxy_group_links "$group_tag"
                ((added++))
            else
                rm -rf "$gdir"
                sed -i "/^${group_tag}$/d" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null || true
                red "[✗] [$remark] sing-box 重启失败, 跳过"
                ((failed++))
            fi
        else
            rm -rf "$gdir"
            sed -i "/^${group_tag}$/d" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null || true
            red "[✗] [$remark] 同步配置失败, 跳过"
            ((failed++))
        fi
        echo
    done

    echo "============================================================"
    green "  OpenRung 中继建组完成: 成功 $added 个国家, 失败 $failed 个"
    cyan  "  自愈探测: 每分钟自动检测出口IP, 失效自动切换同国家备用中继"
    echo "============================================================"
}

# ============ OpenRung 中继自愈探测 (挂 run_cron_check) ============
openrung_health_check() {
    local monitor_log="$WORKDIR/monitor.log"
    local openrung_dir="$WORKDIR/openrung"
    mkdir -p "$openrung_dir" 2>/dev/null || true

    if [[ ! -d "$PROXY_GROUPS_DIR" ]]; then
        return 0
    fi

    local lock_file="$openrung_dir/check.lock"
    if [[ -f "$lock_file" ]]; then
        local old_pid
        old_pid=$(cat "$lock_file" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$lock_file"
    fi
    echo "$$" > "$lock_file"
    trap 'rm -f "$lock_file"' EXIT

    local -a or_groups=()
    for gdir in "$PROXY_GROUPS_DIR"/*/; do
        [[ -d "$gdir" ]] || continue
        [[ -f "$gdir/country.txt" && -f "$gdir/relays.txt" ]] || continue
        or_groups+=("$(basename "$gdir")")
    done

    if [[ ${#or_groups[@]} -eq 0 ]]; then
        rm -f "$lock_file"
        return 0
    fi

    local log_line="$(date '+%Y-%m-%d %H:%M:%S') - [OpenRung自愈] 开始探测 ${#or_groups[@]} 个中继组"
    echo "$log_line" >> "$monitor_log"
    if [[ -f "$monitor_log" && $(wc -c < "$monitor_log" 2>/dev/null || echo 0) -gt 204800 ]]; then
        tail -n 200 "$monitor_log" > "$monitor_log.tmp" 2>/dev/null && mv -f "$monitor_log.tmp" "$monitor_log" 2>/dev/null || true
    fi

    local changed=false
    for tag in "${or_groups[@]}"; do
        local gdir="${PROXY_GROUPS_DIR}/$tag"
        local remark=$(cat "$gdir/remark.txt" 2>/dev/null || echo "$tag")

        local egress_ip ok
        egress_ip=$(openrung_probe_egress_ip "$gdir")
        ok=$?

        if [[ $ok -eq 0 && -n "$egress_ip" ]]; then
            echo "$egress_ip" > "$gdir/last_egress_ip.txt"
            echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$gdir/last_check_ok.txt"
            continue
        fi

        local cc=$(cat "$gdir/country.txt" 2>/dev/null || echo "?")
        local idx=$(cat "$gdir/active_idx.txt" 2>/dev/null || echo "0")
        local total=$(wc -l < "$gdir/relays.txt" 2>/dev/null || echo "0")
        [[ -z "$total" || "$total" -eq 0 ]] && total=0
        # 家宽优先: 失效时从第 1 个节点起按序 TCP 探测, 选第一个可达的(R→H→U 排序 => 优先家宽, 避免单向轮换后永远回不来)
        local __found=-1 __i __u __host __port
        for ((__i=0; __i<total; __i++)); do
            __u=$(sed -n "$((__i + 1))p" "$gdir/relays.txt" 2>/dev/null | tr -d ' \r\n')
            [[ -z "$__u" ]] && continue
            __host=$(echo "$__u" | sed -E 's|^[a-zA-Z0-9]+://[^@]*@([^:/]+).*|\1|')
            __port=$(echo "$__u" | sed -E 's|^[a-zA-Z0-9]+://[^@]*@[^:/]+:([0-9]+).*|\1|')
            if timeout 6 bash -c "cat < /dev/null > /dev/tcp/$__host/$__port" 2>/dev/null; then
                __found=$__i
                echo "$(date '+%Y-%m-%d %H:%M:%S') - [OpenRung自愈] [$remark] 探测到可用节点 #$((__i+1)) $__host (共 $total), 回跳/切换" >> "$monitor_log"
                break
            fi
        done
        local new_idx=$((idx + 1))
        if [[ "$__found" -ge 0 ]]; then
            new_idx=$__found
        fi
        if [[ "$new_idx" -ge "$total" ]]; then
            new_idx=0
        fi

        local new_url
        new_url=$(sed -n "$((new_idx + 1))p" "$gdir/relays.txt" 2>/dev/null | tr -d ' \r\n')
        if [[ -z "$new_url" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [OpenRung自愈] [$remark] 探测失败且无备用中继, 跳过" >> "$monitor_log"
            continue
        fi

        local new_out
        new_out=$(validate_and_parse_proxy_url "$new_url" "${tag}-out" 2>/dev/null)
        if [[ -z "$new_out" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [OpenRung自愈] [$remark] 备用中继解析失败, 跳过" >> "$monitor_log"
            continue
        fi

        echo "$new_url" > "$gdir/raw_url.txt"
        echo "$new_out" > "$gdir/outbound.json"
        echo "$new_idx" > "$gdir/active_idx.txt"
        rm -f "$gdir/last_egress_ip.txt"

        if sync_proxy_group_to_singbox "$tag"; then
            changed=true
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [OpenRung自愈] [$remark] 中继失效, 已自动切换至备用 #$((new_idx+1)): $(echo "$new_url" | sed -E 's|^[a-zA-Z0-9]+://([^@]+)@([^:/]+):?([0-9]*).*|\2|')" >> "$monitor_log"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [OpenRung自愈] [$remark] 切换同步失败!" >> "$monitor_log"
        fi
        sleep 1
    done

    if $changed; then
        start_singbox_safe
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [OpenRung自愈] 配置已生效 (sing-box 已重启)" >> "$monitor_log"
    fi

    rm -f "$lock_file"
    return 0
}

# 探测单个 OpenRung 组出口 IP (轻量临时 sing-box, 严格超时, 用完即杀并清理)
openrung_probe_egress_ip() {
    local gdir="$1"
    local outbound_json
    outbound_json=$(cat "$gdir/outbound.json" 2>/dev/null)
    [[ -z "$outbound_json" ]] && return 1

    local sb_bin
    sb_bin=$(cat "$WORKDIR/sb.txt" 2>/dev/null)
    if [[ -n "$sb_bin" && -x "$WORKDIR/$sb_bin" ]]; then
        sb_bin="$WORKDIR/$sb_bin"
    elif command -v sing-box >/dev/null 2>&1; then
        sb_bin=$(command -v sing-box)
    else
        return 1
    fi

    local out_tag
    out_tag=$(echo "$outbound_json" | jq -r '.tag // empty' 2>/dev/null)
    if [[ -z "$out_tag" ]]; then
        out_tag="probe-out"
        outbound_json=$(echo "$outbound_json" | jq -c --arg t "$out_tag" '.tag = $t' 2>/dev/null)
    fi

    local probe_port=$((20000 + RANDOM % 20000))
    local probe_dir
    probe_dir=$(mktemp -d /tmp/or-probe-XXXXXX 2>/dev/null) || return 1

    cat > "$probe_dir/probe.json" <<EOF
{
  "log": {"level": "error"},
  "inbounds": [{"type": "socks", "tag": "probe-in", "listen": "127.0.0.1", "listen_port": $probe_port}],
  "outbounds": [
    $outbound_json,
    {"type": "direct", "tag": "direct"}
  ],
  "route": {"final": "$out_tag", "rules": []}
}
EOF

    if ! "$sb_bin" check -c "$probe_dir/probe.json" >/dev/null 2>&1; then
        rm -rf "$probe_dir" 2>/dev/null || true
        return 1
    fi

    local sb_pid=""
    timeout 10 "$sb_bin" run -c "$probe_dir/probe.json" >/dev/null 2>&1 &
    sb_pid=$!
    [[ -n "$sb_pid" ]] || { rm -rf "$probe_dir" 2>/dev/null || true; return 1; }

    local egress_ip=""
    for ((i=1; i<=8; i++)); do
        sleep 1
        if ! kill -0 "$sb_pid" 2>/dev/null; then break; fi
        local res
        res=$(timeout 3 curl -sx "socks5h://127.0.0.1:${probe_port}" -s4 --connect-timeout 1 -m 2 "http://api.ipify.org" 2>/dev/null | tr -d ' \r\n') || true
        if [[ -n "$res" && "$res" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            egress_ip="$res"
            break
        fi
    done

    kill -9 "$sb_pid" 2>/dev/null || true
    wait "$sb_pid" 2>/dev/null || true
    pkill -9 -f "$probe_dir/probe.json" 2>/dev/null || true
    rm -rf "$probe_dir" 2>/dev/null || true

    if [[ -n "$egress_ip" ]]; then
        echo "$egress_ip"
        return 0
    fi
    sleep 1
    return 1
}


# ==================== URPool 中继网络 (自建 API 服务: 用户提供地址+token) ====================
add_urpool_egress_group() {
    init_proxy_groups_dir

    if [[ ${#ALL_IPS[@]} -eq 0 ]]; then
        [[ -f "$WORKDIR/all_ips.txt" ]] && mapfile -t ALL_IPS < "$WORKDIR/all_ips.txt" \
                                        || get_all_ips > /dev/null 2>&1
    fi
    [[ ${#ALL_IPS[@]} -eq 0 ]] && { red "[!] 无法获取本机 IP 列表"; return 1; }

    echo
    green "==== 一键添加 URPool 中继节点 (API 按国家, 自动自愈) ===="

    # 读取/输入 URPool API 地址与 token (持久化 $WORKDIR/urpool/api.txt, 两行: 地址 / token)
    local urpool_dir="$WORKDIR/urpool"
    mkdir -p "$urpool_dir" 2>/dev/null || true
    local api_base="" api_token=""
    if [[ -f "$urpool_dir/api.txt" ]]; then
        api_base=$(sed -n '1p' "$urpool_dir/api.txt" 2>/dev/null | tr -d ' \r\n')
        api_token=$(sed -n '2p' "$urpool_dir/api.txt" 2>/dev/null | tr -d ' \r\n')
    fi
    if [[ -n "$api_base" ]]; then
        yellow "[*] 检测到已保存的 URPool API: $api_base"
        echo "  1. 使用已保存配置"
        echo "  2. 重新输入 API 地址与 token"
        reading "  请选择 [1-2, 默认1]: " api_choice
        [[ -z "$api_choice" ]] && api_choice="1"
        if [[ "$api_choice" != "1" ]]; then
            api_base=""; api_token=""
        fi
    fi
    if [[ -z "$api_base" ]]; then
        reading "  请输入 URPool API 地址 (如 http://127.0.0.1:8899): " api_base
        reading "  请输入 URPool API Token: " api_token
        api_base=$(echo "$api_base" | tr -d ' \r\n')
        api_token=$(echo "$api_token" | tr -d ' \r\n')
    fi
    if [[ -z "$api_base" || -z "$api_token" ]]; then
        red "[!] URPool API 地址与 token 不能为空"
        return 1
    fi
    api_base="${api_base%/}"

    echo
    yellow "[*] 正在从 URPool API 获取国家列表..."
    local countries_json
    countries_json=$(curl -s --max-time 15 -H "Authorization: Bearer ${api_token}" "${api_base}/api/countries" 2>/dev/null)
    if ! echo "$countries_json" | jq -e '.countries | type == "array"' >/dev/null 2>&1; then
        red "[!] 获取 URPool 国家列表失败 (地址/token 错误或服务不可用)"
        return 1
    fi
    echo "$api_base" > "$urpool_dir/api.txt"
    echo "$api_token" >> "$urpool_dir/api.txt"

    local cc_summary
    cc_summary=$(echo "$countries_json" | jq -r '
        [.countries[] | {cc: (.country_code // "?"), cn: (.name // "?"), pc: (.provider_count // 0)}]
        | sort_by(-.pc)
        | .[] | [.cc, .cn, .pc] | @tsv' 2>/dev/null)

    echo "------------------------------------------------------------"
    echo "  URPool 可用国家 (按节点数降序):"
    echo "------------------------------------------------------------"
    local -a cc_list=() cn_list=() pc_list=()
    local cc_idx=0
    while IFS=$'\t' read -r cc cn pc; do
        [[ -z "$cc" ]] && continue
        cc_list+=("$cc"); cn_list+=("$cn"); pc_list+=("$pc")
        ((cc_idx++))
        yellow "  [$cc_idx] [$cc] $cn (${pc}个节点)"
    done < <(echo "$cc_summary")

    echo "------------------------------------------------------------"
    echo "  支持: 单个编号 (如 3) | 多个 (如 1,3,5) | 范围 (如 2-4) | 全部 (a)"
    reading "  请选择要添加的国家: " sel

    if [[ -z "$sel" ]]; then
        red "[!] 未选择任何国家"
        return 1
    fi

    local -a pick_cc=()
    if [[ "$sel" == "a" || "$sel" == "A" || "$sel" == "all" ]]; then
        for ((i=0; i<${#cc_list[@]}; i++)); do pick_cc+=("$i"); done
    else
        local tok
        local old_ifs="$IFS"; IFS=','
        for tok in $sel; do
            tok=$(echo "$tok" | tr -d ' ')
            if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
                for ((i=s; i<=e; i++)); do
                    [[ $i -ge 1 && $i -le ${#cc_list[@]} ]] && pick_cc+=("$((i-1))")
                done
            elif [[ "$tok" =~ ^[0-9]+$ ]]; then
                [[ $tok -ge 1 && $tok -le ${#cc_list[@]} ]] && pick_cc+=("$((tok-1))")
            fi
        done
        IFS="$old_ifs"
    fi

    if [[ ${#pick_cc[@]} -eq 0 ]]; then
        red "[!] 选择无效"
        return 1
    fi

    echo
    purple "请选择本地入站协议:"
    echo "  1. Hysteria2 入站"
    echo "  2. TUIC v5 入站"
    echo "  3. VLESS-Reality 入站"
    echo "  4. 同时开启 Hy2 与 TUIC"
    reading "请选择 [1-4, 默认4]: " oproto
    [[ -z "$oproto" ]] && oproto="4"

    # 收集现有代理组端口 (serv00 端口受限, 优先复用)
    local used_hy2_ports=() used_tuic_ports=()
    local g
    for g in $(get_all_proxy_groups); do
        local g_dir="${PROXY_GROUPS_DIR}/$g"
        [[ -d "$g_dir" ]] || continue
        local h_p=$(cat "$g_dir/hy2_port.txt" 2>/dev/null | grep -oE '[0-9]+' | head -n1)
        local t_p=$(cat "$g_dir/tuic_port.txt" 2>/dev/null | grep -oE '[0-9]+' | head -n1)
        [[ -n "$h_p" ]] && used_hy2_ports+=("$h_p")
        [[ -n "$t_p" ]] && used_tuic_ports+=("$t_p")
    done

    # 辅助: 复用已有端口或 devil 申请新端口 (serv00 模式)
    alloc_or_port() {
        local ptype="$1"   # hy2|tuic|vless
        local -a used_ports=("${@:2}")
        local chosen=""
        if [[ ${#used_ports[@]} -gt 0 ]]; then
            echo
            yellow "已有 ${ptype^^} 端口: ${used_ports[*]} (端口受限, 建议复用)"
            echo "  1. 复用已有端口"
            echo "  2. 申请新端口"
            reading "  请选择 [1-2, 默认1]: " p_choice
            [[ -z "$p_choice" ]] && p_choice="1"
            if [[ "$p_choice" == "1" ]]; then
                for i in "${!used_ports[@]}"; do
                    yellow "  $((i+1)). ${used_ports[$i]}"
                done
                reading "  请选择端口序号 [1-${#used_ports[@]}]: " p_idx
                p_idx=$((p_idx-1))
                if [[ $p_idx -ge 0 && $p_idx -lt ${#used_ports[@]} ]]; then
                    chosen="${used_ports[$p_idx]}"
                    green "  → 复用 ${ptype^^} 端口: $chosen"
                else
                    red "  [!] 无效选择, 将申请新端口"
                fi
            fi
        fi
        if [[ -z "$chosen" ]]; then
            yellow "[*] 申请新的 ${ptype^^} 端口..."
            local retry=0
            while [[ $retry -lt 30 && -z "$chosen" ]]; do
                local cand=$(shuf -i 10000-65535 -n 1)
                if check_port_available_all_ips "$cand" "tcp"; then
                    local alloc_result
                    alloc_result=$(devil port add tcp "$cand" "singbox-or-${ptype}" 2>&1)
                    if [[ "$alloc_result" == *"succesfully"* || "$alloc_result" == *"Ok"* ]]; then
                        chosen="$cand"
                        green "    已成功申请 ${ptype^^} TCP 端口: $chosen"
                    fi
                fi
                ((retry++))
            done
            [[ -z "$chosen" ]] && red "[!] ${ptype^^} 端口申请失败"
        fi
        echo "$chosen"
    }

    local added=0 failed=0
    for ci in "${pick_cc[@]}"; do
        local ccc="${cc_list[$ci]}" cname="${cn_list[$ci]}"

        local proxy_json proxy_url
        proxy_json=$(curl -s --max-time 30 -H "Authorization: Bearer ${api_token}" "${api_base}/api/proxy?country=${ccc}" 2>/dev/null)
        proxy_url=$(echo "$proxy_json" | jq -r '.socks5 // empty' 2>/dev/null | tr -d ' \r\n')
        if [[ -z "$proxy_url" ]]; then
            red "[✗] [URPool-$ccc] 获取代理失败 ($(echo "$proxy_json" | jq -r '.error // "未知错误"' 2>/dev/null)), 跳过"
            ((failed++))
            continue
        fi

        local group_tag
        group_tag=$(generate_proxy_group_tag)

        local out_json
        out_json=$(validate_and_parse_proxy_url "$proxy_url" "${group_tag}-out")
        if [[ $? -ne 0 || -z "$out_json" ]]; then
            red "[✗] [URPool-$ccc] 链接解析失败, 跳过"
            ((failed++))
            continue
        fi

        # 按选择分配端口 (hy2/tuic 走 UDP 需 devil udp 端口; 与 add_proxy_egress_group 的申请逻辑对齐)
        local hy2_port_p="0" tuic_port_p="0" vless_port_p="0"
        case "$oproto" in
            1) hy2_port_p=$(alloc_or_port "hy2" "${used_hy2_ports[@]}") ;;
            2) tuic_port_p=$(alloc_or_port "tuic" "${used_tuic_ports[@]}") ;;
            3) vless_port_p=$(alloc_or_port "vless" "${used_tuic_ports[@]}") ;;
            *) hy2_port_p=$(alloc_or_port "hy2" "${used_hy2_ports[@]}")
               tuic_port_p=$(alloc_or_port "tuic" "${used_tuic_ports[@]}") ;;
        esac
        [[ "$hy2_port_p" == "0" && "$tuic_port_p" == "0" && "$vless_port_p" == "0" ]] && { red "[✗] [URPool-$ccc] 端口分配失败, 跳过"; ((failed++)); continue; }

        local gdir="${PROXY_GROUPS_DIR}/${group_tag}"
        mkdir -p "$gdir"
        echo "URPool-${ccc}" > "$gdir/remark.txt"
        echo "$ccc" > "$gdir/country.txt"
        echo "$api_base" > "$gdir/urpool_api.txt"
        echo "$api_token" >> "$gdir/urpool_api.txt"
        echo "$(date +%s)" > "$gdir/urpool_ts.txt"
        echo "$proxy_url" > "$gdir/raw_url.txt"
        echo "$out_json" > "$gdir/outbound.json"
        echo "$hy2_port_p" > "$gdir/hy2_port.txt"
        echo "$tuic_port_p" > "$gdir/tuic_port.txt"
        echo "$vless_port_p" > "$gdir/vless_port.txt"
        : > "$gdir/ip_protos.txt"
        local ip_proto=""
        case "$oproto" in
            1) ip_proto="hy2" ;;
            2) ip_proto="tuic" ;;
            3) ip_proto="vless" ;;
            *) ip_proto="both" ;;
        esac
        for ip in "${ALL_IPS[@]}"; do
            echo "${ip}|${ip_proto}" >> "$gdir/ip_protos.txt"
        done

        if sync_proxy_group_to_singbox "$group_tag"; then
            if ! grep -qx "$group_tag" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null; then
                echo "$group_tag" >> "$PROXY_GROUPS_DIR/groups.txt"
            fi
            if start_singbox_safe; then
                green "[✓] URPool [$ccc] 建组成功! (标识: $group_tag, 出口约需预热45秒)"
                generate_proxy_group_links "$group_tag"
                ((added++))
            else
                rm -rf "$gdir"
                sed -i "/^${group_tag}$/d" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null || true
                red "[✗] [URPool-$ccc] sing-box 重启失败, 跳过"
                ((failed++))
            fi
        else
            rm -rf "$gdir"
            sed -i "/^${group_tag}$/d" "$PROXY_GROUPS_DIR/groups.txt" 2>/dev/null || true
            red "[✗] [URPool-$ccc] 同步配置失败, 跳过"
            ((failed++))
        fi
        echo
    done

    echo "============================================================"
    green "  URPool 中继建组完成: 成功 $added 个国家, 失败 $failed 个"
    cyan  "  自愈探测: 每分钟自动检测出口IP, 失效自动调 rotate 端点换新"
    echo "============================================================"
}

# ============ URPool 中继自愈探测 (挂 run_cron_check) ============
urpool_health_check() {
    local monitor_log="$WORKDIR/monitor.log"
    local urpool_dir="$WORKDIR/urpool"
    mkdir -p "$urpool_dir" 2>/dev/null || true

    if [[ ! -d "$PROXY_GROUPS_DIR" ]]; then
        return 0
    fi

    local lock_file="$urpool_dir/check.lock"
    if [[ -f "$lock_file" ]]; then
        local old_pid
        old_pid=$(cat "$lock_file" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$lock_file"
    fi
    echo "$$" > "$lock_file"
    trap 'rm -f "$lock_file"' EXIT

    local -a up_groups=()
    for gdir in "$PROXY_GROUPS_DIR"/*/; do
        [[ -d "$gdir" ]] || continue
        [[ -f "$gdir/urpool_api.txt" && -f "$gdir/country.txt" ]] || continue
        up_groups+=("$(basename "$gdir")")
    done

    if [[ ${#up_groups[@]} -eq 0 ]]; then
        rm -f "$lock_file"
        return 0
    fi

    local log_line="$(date '+%Y-%m-%d %H:%M:%S') - [URPool自愈] 开始探测 ${#up_groups[@]} 个中继组"
    echo "$log_line" >> "$monitor_log"
    if [[ -f "$monitor_log" && $(wc -c < "$monitor_log" 2>/dev/null || echo 0) -gt 204800 ]]; then
        tail -n 200 "$monitor_log" > "$monitor_log.tmp" 2>/dev/null && mv -f "$monitor_log.tmp" "$monitor_log" 2>/dev/null || true
    fi

    local changed=false
    local now_ts
    now_ts=$(date +%s)
    for tag in "${up_groups[@]}"; do
        local gdir="${PROXY_GROUPS_DIR}/$tag"
        local remark=$(cat "$gdir/remark.txt" 2>/dev/null || echo "$tag")
        local cc=$(cat "$gdir/country.txt" 2>/dev/null || echo "?")

        # 预热宽限期: 新实例需 ~45s 预热, 期间跳过探测, 避免"建了又死、死了又建"循环
        local ts=$(cat "$gdir/urpool_ts.txt" 2>/dev/null || echo "0")
        [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
        if (( now_ts - ts < 90 )); then
            continue
        fi

        local egress_ip ok
        egress_ip=$(openrung_probe_egress_ip "$gdir")
        ok=$?

        if [[ $ok -eq 0 && -n "$egress_ip" ]]; then
            echo "$egress_ip" > "$gdir/last_egress_ip.txt"
            echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$gdir/last_check_ok.txt"
            continue
        fi

        # 失效 → 调 URPool rotate 端点强制换新实例
        local api_base api_token
        api_base=$(sed -n '1p' "$gdir/urpool_api.txt" 2>/dev/null | tr -d ' \r\n')
        api_token=$(sed -n '2p' "$gdir/urpool_api.txt" 2>/dev/null | tr -d ' \r\n')
        if [[ -z "$api_base" || -z "$api_token" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [URPool自愈] [$remark] API 配置缺失, 跳过" >> "$monitor_log"
            continue
        fi

        local new_json new_url
        new_json=$(curl -s --max-time 30 -X POST -H "Authorization: Bearer ${api_token}" "${api_base%/}/api/rotate?country=${cc}" 2>/dev/null)
        new_url=$(echo "$new_json" | jq -r '.socks5 // empty' 2>/dev/null | tr -d ' \r\n')
        if [[ -z "$new_url" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [URPool自愈] [$remark] rotate 失败 ($(echo "$new_json" | jq -r '.error // "未知错误"' 2>/dev/null)), 跳过" >> "$monitor_log"
            continue
        fi

        local new_out
        new_out=$(validate_and_parse_proxy_url "$new_url" "${tag}-out" 2>/dev/null)
        if [[ -z "$new_out" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [URPool自愈] [$remark] rotate 返回链接解析失败, 跳过" >> "$monitor_log"
            continue
        fi

        echo "$new_url" > "$gdir/raw_url.txt"
        echo "$new_out" > "$gdir/outbound.json"
        echo "$(date +%s)" > "$gdir/urpool_ts.txt"
        rm -f "$gdir/last_egress_ip.txt"

        if sync_proxy_group_to_singbox "$tag"; then
            changed=true
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [URPool自愈] [$remark] 中继失效, 已 rotate 换新: $(echo "$new_url" | sed -E 's|^[a-zA-Z0-9]+://([^@]+)@([^:/]+):?([0-9]*).*|\2|')" >> "$monitor_log"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [URPool自愈] [$remark] 切换同步失败!" >> "$monitor_log"
        fi
        sleep 1
    done

    if $changed; then
        start_singbox_safe
        echo "$(date '+%Y-%m-%d %H:%M:%S') - [URPool自愈] 配置已生效 (sing-box 已重启)" >> "$monitor_log"
    fi

    rm -f "$lock_file"
    return 0
}


# ==== 修改代理出站后端 (保持入站配置不变) ====
edit_proxy_egress_backend() {
    init_proxy_groups_dir
    local groups
    mapfile -t groups < <(get_all_proxy_groups)
    if [[ ${#groups[@]} -eq 0 ]]; then
        yellow "暂无代理节点组可修改"
        return 1
    fi

    echo
    green "==== 修改代理出站后端 (保持入站不变) ===="
    echo "请选择要修改的分组:"
    for i in "${!groups[@]}"; do
        local t="${groups[$i]}"
        local r=$(cat "${PROXY_GROUPS_DIR}/$t/remark.txt" 2>/dev/null || echo "$t")
        printf "  %d. [%-10s] %s\n" "$((i+1))" "$t" "$r"
    done
    echo
    reading "请输入要修改的分组 tag (如 proxy-1): " edit_tag
    if ! proxy_group_exists "$edit_tag"; then
        red "[!] 分组 $edit_tag 不存在"; return 1
    fi

    local group_dir="${PROXY_GROUPS_DIR}/${edit_tag}"
    local old_url=$(cat "$group_dir/proxy_url.txt" 2>/dev/null)
    local old_remark=$(cat "$group_dir/remark.txt" 2>/dev/null)
    
    echo
    blue "当前分组: $old_remark ($edit_tag)"
    blue "当前后端: $old_url"
    echo
    reading "请输入新代理链接: " new_url
    new_url="${new_url// /}"
    [[ -z "$new_url" ]] && { red "[!] 链接不能为空"; return 1; }

    local out_tag="${edit_tag}-out"
    local outbound_json
    yellow "[*] 正在解析新链接..."
    outbound_json=$(validate_and_parse_proxy_url "$new_url" "$out_tag")
    [[ $? -ne 0 ]] && return 1

    local ptype pserver pport
    ptype=$(echo "$outbound_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type','?'))" 2>/dev/null)
    pserver=$(echo "$outbound_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('server','?'))" 2>/dev/null)
    pport=$(echo "$outbound_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('server_port','?'))" 2>/dev/null)
    green "[+] 解析成功: [$ptype] $pserver:$pport"

    # 家宽/机房标注(手动链接无 R/H 标记, 走 detect_ip_type + 缓存)
    local ip_type
    ip_type=$(detect_ip_type "$pserver")
    case "$ip_type" in
        R) green  "[+] 节点类型: 家宽 ✓ (住宅 IP, 抗封性强)" ;;
        H) yellow "[+] 节点类型: 机房 (数据中心 IP, 可能易被风控)" ;;
        *) yellow "[+] 节点类型: 未知 (无法判定)" ;;
    esac

    # 仅更新后端数据，不触碰前端绑定(ip_protos.txt/ports)
    echo "$new_url"     > "$group_dir/proxy_url.txt"
    echo "$outbound_json" > "$group_dir/outbound.json"

    # 询问是否顺便修改备注
    echo
    reading "是否修改分组备注名称? (当前: $old_remark, 回车不修改): " new_remark
    if [[ -n "$new_remark" ]]; then
        echo "$new_remark" > "$group_dir/remark.txt"
        green "[+] 备注已更新为: $new_remark"
    fi

    # 同步并重启
    yellow "[*] 更新 sing-box 配置并重启..."
    if ! sync_proxy_group_to_singbox "$edit_tag"; then
        red "[!] 同步配置失败，请检查日志"
        return 1
    fi

    start_singbox || { red "[!] sing-box 重启失败"; return 1; }
    green "==== ✓ 分组后端修改完成！前端客户端链接保持不变 ===="
}

# ==== 批量测试外部多节点延迟 ====
test_external_nodes_latency() {
    clear
    echo
    green "============================================================"
    green "  批量测试外部代理节点真实延迟 (全链路代理测速)"
    green "  说明: 支持 vless / vmess / trojan / hy2 / tuic / ss 链接"
    green "============================================================"
    echo
    yellow "请粘贴你的节点链接 (一行一个)。"
    yellow "输入完毕后，请在空行中输入 'EOF' 并回车开始测试："
    echo

    local raw_links=()
    while read -r line; do
        line=$(echo "$line" | xargs)
        [[ "$line" == "EOF" || "$line" == "eof" ]] && break
        [[ -n "$line" ]] && raw_links+=("$line")
    done

    if [[ ${#raw_links[@]} -eq 0 ]]; then
        yellow "未输入任何节点，返回上级菜单。"
        return 0
    fi

    echo
    yellow "[*] 正在解析并启动临时测速内核，测试 ${#raw_links[@]} 个节点，请稍候..."
    echo

    # 导出必要的变量给 Python 子进程
    # 获取用户在 devil 下注册的有效 TCP 端口列表
    local tcp_ports=()
    if command -v devil &>/dev/null; then
        mapfile -t tcp_ports < <(devil port list 2>/dev/null | grep -i 'tcp' | awk '{print $1}')
    fi

    # 转成逗号隔开的字符串
    local ports_str=""
    if [[ ${#tcp_ports[@]} -gt 0 ]]; then
        ports_str=$(IFS=,; echo "${tcp_ports[*]}")
    fi

    export RAW_NODE_LINKS=$(printf "%s\n" "${raw_links[@]}")
    export WORKDIR="$WORKDIR"
    export DEVIL_TCP_PORTS="$ports_str"

    python3 - <<'PY'
import sys, socket, time, json, base64, os, subprocess
from urllib.parse import urlparse, parse_qs, unquote

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
    insec = params.get('insecure', ['0'])[0] == '1' or \
            params.get('allowInsecure', ['0'])[0] == '1'
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
    out = {'type': 'vless', 'tag': tag, 'server': host, 'server_port': p.port,
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
    elif net == 'h2':
        t = {'type': 'http', 'path': path}
        if hdr: t['host'] = [hdr]
        out['transport'] = t
    if tls_s == 'tls':
        tls = {'enabled': True, 'server_name': sni}
        if fp: tls['utls'] = {'enabled': True, 'fingerprint': fp}
        out['tls'] = tls
    return out

def parse_trojan(url, tag):
    p = urlparse(url); params = parse_qs(p.query); host = p.hostname
    out = {'type': 'trojan', 'tag': tag, 'server': host, 'server_port': p.port,
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
    out = {'type': 'hysteria2', 'tag': tag, 'server': host, 'server_port': p.port,
           'password': pw, 'tls': {'enabled': True, 'server_name': sni, 'insecure': insec}}
    if obfs_t: out['obfs'] = {'type': obfs_t, 'password': obfs_p}
    return out

def parse_tuic(url, tag):
    p = urlparse(url); params = parse_qs(p.query); host = p.hostname
    alpn = [a for a in params.get('alpn', ['h3'])[0].split(',') if a] or ['h3']
    sni  = params.get('sni', [host])[0] or host
    insec = params.get('allow_insecure', ['0'])[0] == '1'
    cc   = params.get('congestion_control', ['bbr'])[0]
    return {'type': 'tuic', 'tag': tag, 'server': host, 'server_port': p.port,
            'uuid': unquote(p.username or ''), 'password': unquote(p.password or ''),
            'congestion_control': cc,
            'tls': {'enabled': True, 'server_name': sni, 'alpn': alpn, 'insecure': insec}}

def parse_ss(url, tag):
    p = urlparse(url); host = p.hostname; port = p.port
    if p.username and p.password:
        method = unquote(p.username); password = unquote(p.password)
    else:
        userinfo = unquote(p.username or '')
        try:    method, password = b64d(userinfo).split(':', 1)
        except: method = 'aes-256-gcm'; password = userinfo
    return {'type': 'shadowsocks', 'tag': tag, 'server': host, 'server_port': port,
            'method': method, 'password': password}

def parse_to_outbound(url, tag):
    try:
        url = url.strip()
        if url.startswith('vless://'):                   return parse_vless(url, tag)
        elif url.startswith('vmess://'):                   return parse_vmess(url, tag)
        elif url.startswith('trojan://'):                  return parse_trojan(url, tag)
        elif url.startswith(('hy2://', 'hysteria2://')):   return parse_hy2(url, tag)
        elif url.startswith('tuic://'):                    return parse_tuic(url, tag)
        elif url.startswith('ss://'):                      return parse_ss(url, tag)
    except Exception:
        pass
    return None

def test_socks5_http_latency(proxy_port, target_host="cp.cloudflare.com", timeout=3.0):
    start = time.perf_counter()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(("127.0.0.1", proxy_port))
        
        # 1. Socks5 协商
        s.sendall(b"\x05\x01\x00")
        resp = s.recv(2)
        if len(resp) < 2 or resp[0] != 5 or resp[1] != 0:
            return -1.0
        
        # 2. 连接 target_host:80
        host_bytes = target_host.encode('utf-8')
        req = b"\x05\x01\x00\x03" + bytes([len(host_bytes)]) + host_bytes + b"\x00\x50"
        s.sendall(req)
        resp2 = s.recv(10)
        if len(resp2) < 4 or resp2[1] != 0:
            return -1.0
            
        # 3. 发送 HTTP GET
        http_req = f"GET /generate_204 HTTP/1.1\r\nHost: {target_host}\r\nConnection: close\r\n\r\n".encode('utf-8')
        s.sendall(http_req)
        
        # 4. 接收响应首字节
        data = s.recv(1)
        if not data:
            return -1.0
        
        s.close()
        return round((time.perf_counter() - start) * 1000, 2)
    except Exception:
        return -1.0

# 读取输入
links_str = os.environ.get("RAW_NODE_LINKS", "")
inputs = [line.strip() for line in links_str.split('\n') if line.strip()]

workdir = os.environ.get("WORKDIR", "/tmp")
sb_txt_path = os.path.join(workdir, "sb.txt")
sb_binary = "sing-box"
if os.path.exists(sb_txt_path):
    with open(sb_txt_path, "r") as f:
        name_sb = f.read().strip()
        if name_sb:
            sb_binary = os.path.join(workdir, name_sb)

temp_config_path = os.path.join(workdir, "temp_test_config.json")
temp_log_path    = os.path.join(workdir, "temp_test_sb.log")

def check_port_in_use(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", port))
        s.close()
        return False
    except:
        return True

# 自动匹配 Devil 允许的 TCP 端口
ports_str = os.environ.get("DEVIL_TCP_PORTS", "")
allowed_ports = [int(p) for p in ports_str.split(',') if p.strip().isdigit()]

test_port = None
need_stop_sb = False

if allowed_ports:
    # 优先找一个未被占用的端口
    for p in allowed_ports:
        if not check_port_in_use(p):
            test_port = p
            break
    # 若都被占用，借用第一个并设置 need_stop_sb
    if not test_port:
        test_port = allowed_ports[0]
        need_stop_sb = True
else:
    # Fallback
    test_port = 29876

# 如果需要释放已占用端口，临时杀掉主进程
if need_stop_sb:
    subprocess.run(["pkill", "-x", "sing-box"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if os.path.exists(sb_txt_path):
        with open(sb_txt_path, "r") as f:
            name_sb = f.read().strip()
            if name_sb:
                subprocess.run(["pkill", "-x", name_sb], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)


# 解析所有节点
parsed_nodes = []
for idx, url in enumerate(inputs):
    tag = f"test-out-{idx}"
    outbound = parse_to_outbound(url, tag)
    name = "未命名节点"
    if url.strip().startswith('vmess://'):
        try:
            name = json.loads(b64d(url.strip()[8:])).get('ps', '未命名节点')
        except: pass
    else:
        try:
            p = urlparse(url.strip())
            if p.fragment: name = unquote(p.fragment)
        except: pass
    target = "解析失败"
    if outbound:
        target = f"{outbound.get('server','')}:{outbound.get('server_port','')}"
    parsed_nodes.append((name, target, outbound, tag))

if not any(n[2] for n in parsed_nodes):
    print("[!] 未解析到任何有效的代理节点。")
    sys.exit(0)

total = sum(1 for n in parsed_nodes if n[2])
print(f"[*] 已解析 {total} 个有效节点，开始逐个测速...")
print()

results = []
tested = 0
for name, target, outbound, tag in parsed_nodes:
    if not outbound:
        results.append((name, target, -1.0))
        continue
    tested += 1
    sys.stdout.write(f"\r[{tested}/{total}] 正在测试: {name[:30]}...")
    sys.stdout.flush()
    temp_cfg = {
        "log": {"disabled": True},
        "inbounds": [{"type":"socks","tag":"test-in","listen":"127.0.0.1","listen_port":test_port}],
        "outbounds": [outbound, {"type":"direct","tag":"direct"}],
        "route": {"rules":[{"inbound":["test-in"],"outbound":tag}],"final":"direct"}
    }
    with open(temp_config_path, "w", encoding="utf-8") as f:
        json.dump(temp_cfg, f, indent=2)
    process = None; latency = -1.0; log_f = None
    try:
        log_f = open(temp_log_path, "w")
        process = subprocess.Popen(
            [sb_binary, "run", "-c", temp_config_path],
            stdout=subprocess.DEVNULL, stderr=log_f, cwd=workdir)
        time.sleep(0.8)
        if process.poll() is not None:
            latency = -1.0
            try:
                log_f.close()
                with open(temp_log_path, "r", encoding="utf-8", errors="ignore") as f_err:
                    err_txt = f_err.read().strip()
                if err_txt:
                    print(f"\n[!] 节点 [{name}] 测速内核启动失败，报错:\n{err_txt}\n")
            except Exception as e:
                print(f"\n[!] 读取日志错误: {e}")
        else:
            latency = test_socks5_http_latency(test_port, timeout=4.0)
    except Exception as e:
        print(f"\n[!] 测速执行错误: {e}")
        latency = -1.0
    finally:
        if process and process.poll() is None:
            try: process.terminate(); process.wait(timeout=2)
            except:
                try: process.kill()
                except: pass
        if log_f:
            try: log_f.close()
            except: pass
    results.append((name, target, latency))

for fp in [temp_config_path, temp_log_path]:
    try: os.remove(fp)
    except: pass

sys.stdout.write("\r" + " " * 60 + "\r")
sys.stdout.flush()
print()

results.sort(key=lambda x: (x[2] < 0, x[2]))
ok_count   = sum(1 for r in results if r[2] > 0)
fail_count = sum(1 for r in results if r[2] <= 0)

print("=" * 78)
print(f"{'节点名称 (备注)':<28} | {'节点出站目标':<30} | {'真实延迟':<12}")
print("-" * 78)
for r in results:
    name, target, latency = r
    nd = name[:25] + ".." if len(name) > 27 else name
    if latency <= 0:
        ls = f"\033[91m不可用\033[0m"
    elif latency < 500:
        ls = f"\033[92m{latency:.0f} ms\033[0m"
    elif latency < 1500:
        ls = f"\033[93m{latency:.0f} ms\033[0m"
    else:
        ls = f"\033[91m{latency:.0f} ms\033[0m"
    print(f"{nd:<28} | {target:<30} | {ls}")
print("=" * 78)
print(f"\n\033[92m可用: {ok_count}\033[0m | \033[91m不可用: {fail_count}\033[0m | 共计: {len(results)}")
sys.exit(99 if need_stop_sb else 0)
PY
    local py_status=$?
    if [[ $py_status -eq 99 ]]; then
        yellow "[*] 测速结束，正在重新启动主代理服务以恢复运行..."
        start_singbox
    fi
    return 0
}

# ==== 【副节点】自定义代理出站管理菜单 ====
proxy_egress_menu() {
    while true; do
        clear 2>/dev/null || true
        echo
        green "============================================================"
        green "  自定义代理出站管理"
        green "============================================================"
        yellow "  说明: 副节点拥有独立入站端口与专属路由，出站转发至外部代理"
        yellow "        与主节点完全平行独立，互不干扰"
        green "============================================================"
        echo

        init_proxy_groups_dir
        local groups
        mapfile -t groups < <(get_all_proxy_groups)

        purple "【当前已配置代理组】 (共 ${#groups[@]} 组):"
        if [[ ${#groups[@]} -gt 0 ]]; then
            local idx=1
            for t in "${groups[@]}"; do
                [[ -z "$t" ]] && continue
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
        blue   "  5. 重新同步全部代理配置并重启"
        cyan   "  6. 一键添加 OpenRung 中继节点 (按国家分类, 自动自愈)"
        cyan   "  7. 一键添加 URPool 中继节点 (API 按国家, 自动自愈)"
        echo "------------------------------------------------------------"
        red    "  0. 返回上一级菜单"
        echo "============================================================"
        reading "请选择 [0-7]: " choice
        echo

        case "$choice" in
            1)
                add_proxy_egress_group
                ;;
            6)
                add_openrung_egress_group
                ;;
            7)
                add_urpool_egress_group
                ;;
            2)
                if [[ ${#groups[@]} -eq 0 ]]; then
                    yellow "暂无代理节点组"
                else
                    for tag in "${groups[@]}"; do
                        generate_proxy_group_links "$tag"
                    done
                fi
                ;;
            3)
                edit_proxy_egress_backend
                ;;
            4)
                if [[ ${#groups[@]} -eq 0 ]]; then
                    yellow "暂无代理节点组可删除"
                else
                    echo
                    for i in "${!groups[@]}"; do
                        local t="${groups[$i]}"
                        local r=$(cat "${PROXY_GROUPS_DIR}/$t/remark.txt" 2>/dev/null || echo "$t")
                        printf "  %d. [%-10s] %s\n" "$((i+1))" "$t" "$r"
                    done
                    echo
                    reading "请输入要删除的分组 tag (如 proxy-1): " del_tag
                    [[ -n "$del_tag" ]] && remove_proxy_egress_group "$del_tag"
                fi
                ;;
            5)
                if [[ ${#groups[@]} -eq 0 ]]; then
                    yellow "暂无代理节点组"
                else
                    for tag in "${groups[@]}"; do
                        yellow "[*] 同步 $tag..."
                        sync_proxy_group_to_singbox "$tag"
                    done
                    yellow "[*] 重启 sing-box..."
                    start_singbox
                    green "全部代理出站配置已同步并重启！"
                fi
                ;;
            0)
                return 0
                ;;
            *)
                red "无效选项"
                ;;
        esac

        echo
        reading "按回车继续..." _
    done
}

# ==================== 菜单 ====================

# ==================== 主菜单 ====================

menu() {
    clear
    # 默认静默执行自动清理与维护 (清理过期临时垃圾与日志截断)
    auto_system_maintenance
    echo
    green "============================================================"
    green "  Serv00/Hostuno 多协议节点安装脚本 v${SCRIPT_VERSION}"
    green "============================================================"
    purple "  支持协议: Argo, VLESS-Reality, VMess, Trojan, Hy2, TUIC, SS"
    echo "============================================================"
    
    # 确保 ALL_IPS 已加载
    if [ ${#ALL_IPS[@]} -eq 0 ]; then
        if [ -f "$WORKDIR/all_ips.txt" ]; then
            mapfile -t ALL_IPS < "$WORKDIR/all_ips.txt"
        else
            get_all_ips >/dev/null 2>&1
        fi
    fi
    
    # 检测并显示IP状态（优先读取缓存）
    purple "【本机网络环境】"
    echo -e "  平台环境: ${green}${PLATFORM^^}${re} | 用户: ${green}$USERNAME${re} | 主机: ${green}$HOSTNAME${re}"
    local all_cached=true
    for ip in "${ALL_IPS[@]}"; do
        if [ ! -f "$WORKDIR/ip_status_${ip}.txt" ]; then
            all_cached=false
            break
        fi
    done
    
    if [ "$all_cached" = "false" ]; then
        display_ip_list >/dev/null 2>&1
    fi
    
    local idx=1
    for ip in "${ALL_IPS[@]}"; do
        local status=$(cat "$WORKDIR/ip_status_${ip}.txt" 2>/dev/null)
        if [[ "$status" == "Available" ]]; then
            echo -e "  IP 地址 [$idx]  : ${green}$ip${re}  ->  ${green}[可用] (大陆未阻断)${re}"
        elif [[ "$status" == "Blocked" ]]; then
            echo -e "  IP 地址 [$idx]  : ${red}$ip${re}  ->  ${red}[被墙] (Argo/CDN回源依旧有效)${re}"
        else
            echo -e "  IP 地址 [$idx]  : ${yellow}$ip${re}  ->  ${yellow}[未知] (检测超时)${re}"
        fi
        ((idx++))
    done
    echo "------------------------------------------------------------"
    
    purple "【核心服务状态】"
    if [ -f "$WORKDIR/config.json" ]; then
        SB_BINARY=$(cat "$WORKDIR/sb.txt" 2>/dev/null)
        if pgrep -x "$SB_BINARY" > /dev/null 2>&1; then
            echo -e "  Sing-box 核心 : ${green}✓ 运行中${re}"
        else
            echo -e "  Sing-box 核心 : ${yellow}⚠ 已安装但未运行${re}"
        fi
        
        local warp_status=$(cat "$WORKDIR/warp_enabled.txt" 2>/dev/null)
        local warp_mode=$(cat "$WORKDIR/warp_mode.txt" 2>/dev/null)
        if [[ "$warp_status" == "true" ]]; then
            if [[ "$warp_mode" == "all" ]]; then
                echo -e "  主节点出站模式: ${blue}WARP 全局出站${re}"
            else
                echo -e "  主节点出站模式: ${blue}WARP 规则分流${re}"
            fi
        else
            echo -e "  主节点出站模式: ${green}原生直连出站${re}"
        fi
    else
        echo -e "  Sing-box 核心 : ${red}✗ 未安装${re}"
    fi
    echo "------------------------------------------------------------"

    purple "【副节点出口状态】"
    local psi_groups=($(get_egress_node_groups 2>/dev/null))
    if [[ ${#psi_groups[@]} -gt 0 ]]; then
        echo -e "  赛风出口副节点: ${green}✓ 已配置 ${#psi_groups[@]} 组${re} [ ${psi_groups[*]} ]"
    else
        echo -e "  赛风出口副节点: ${yellow}✗ 未配置${re}"
    fi

    init_proxy_groups_dir
    local proxy_tags=($(get_all_proxy_groups 2>/dev/null))
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
    yellow " 10. 端口冲突检测与重置"
    blue   " 11. 查看运行日志"
    yellow " 12. 卸载删除主节点服务"
    red    " 13. 系统初始化与环境重置"
    echo "------------------------------------------------------------"
    red    "  0. 退出脚本"
    echo "============================================================"
    
    reading "请选择 [0-13]: " choice
    echo
    
    case "$choice" in
        1) install_nodes ;;
        2) configure_warp_outbound ;;
        3) argo_management_menu ;;
        4) show_links ;;
        5) psiphon_management_menu ;;
        6) proxy_egress_menu ;;
        7) custom_push_nodes ;;
        8) show_all_nodes_summary ;;
        9) restart_processes ;;
        10) reset_all_ports ;;
        11) view_logs_menu ;;
        12) uninstall_nodes ;;
        13)
            reading "确定清理所有内容? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # 停止所有服务
                stop_all
                SB_BINARY=$(cat "$WORKDIR/sb.txt" 2>/dev/null)
                [ -n "$SB_BINARY" ] && pkill -x "$SB_BINARY" 2>/dev/null
                CF_BINARY=$(cat "$WORKDIR/cf.txt" 2>/dev/null)
                [ -n "$CF_BINARY" ] && pkill -x "$CF_BINARY" 2>/dev/null
                NZ_BINARY=$(cat "$WORKDIR/nz.txt" 2>/dev/null)
                [ -n "$NZ_BINARY" ] && pkill -x "$NZ_BINARY" 2>/dev/null
                rm -rf "$HOME/domains"
                find "$HOME" -maxdepth 1 -type f -name "*.sh" -exec rm -f {} \;
                green "系统已重置"
            fi
            ;;
        0) exit 0 ;;
        *) red "无效选项" ;;
    esac
    
    echo
    reading "按回车返回菜单..." _
    menu
}

# 强制热更新脚本自身至 GitHub 最新版
update_script_self() {
    yellow "正在强制更新 Serv00 Sing-box 脚本至最新版本..."
    local urls=(
        "https://raw.githubusercontent.com/hxzl666/serv00-singbox/main/serv00_nodes.sh"
        "https://ghproxy.net/https://raw.githubusercontent.com/hxzl666/serv00-singbox/main/serv00_nodes.sh"
        "https://fastly.jsdelivr.net/gh/hxzl666/serv00-singbox@main/serv00_nodes.sh"
    )
    local done_u=false
    local tmp_f="$WORKDIR/serv00_nodes.sh.tmp"
    mkdir -p "$WORKDIR" 2>/dev/null
    
    for u in "${urls[@]}"; do
        if curl -fsSL --connect-timeout 8 --max-time 30 "$u" -o "$tmp_f" 2>/dev/null && [[ -s "$tmp_f" ]] && bash -n "$tmp_f" 2>/dev/null; then
            cp -f "$tmp_f" "$HOME/serv00_nodes.sh" 2>/dev/null || true
            local cur_script
            cur_script=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
            if [[ -n "$cur_script" && "$cur_script" != "$HOME/serv00_nodes.sh" && -w "$cur_script" ]]; then
                cp -f "$tmp_f" "$cur_script" 2>/dev/null || true
            fi
            chmod +x "$HOME/serv00_nodes.sh" 2>/dev/null || true
            done_u=true
            break
        fi
    done
    rm -f "$tmp_f" 2>/dev/null || true
    
    if $done_u; then
        create_quick_command
        green "脚本已成功强制更新至最新版本！"
    else
        red "更新失败，请检查网络连通性！"
    fi
}

# 后台定时健康检查与自愈守护
run_cron_check() {
    auto_system_maintenance
    if [[ ! -f "$WORKDIR/config.json" ]]; then
        return 0
    fi
    local sb_bin
    sb_bin=$(cat "$WORKDIR/sb.txt" 2>/dev/null)
    local need_restart=false
    
    if [[ -n "$sb_bin" ]] && ! pgrep -x "$sb_bin" >/dev/null 2>&1; then
        yellow "[!] 定时检测发现 Sing-box 核心离线，正在拉起..."
        need_restart=true
    fi
    
    # 检查 Psiphon 多实例
    local groups=($(get_egress_node_groups 2>/dev/null))
    if [[ ${#groups[@]} -gt 0 ]]; then
        for cc in "${groups[@]}"; do
            [[ -z "$cc" ]] && continue
            local pid_file="$PSI_INSTANCES_DIR/$cc/psiphon.pid"
            if [[ ! -f "$pid_file" ]] || ! kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null; then
                yellow "[!] 定时检测发现 Psiphon [$cc] 离线，正在拉起..."
                start_psiphon_instance "$cc" 2>/dev/null || true
            fi
        done
    fi
    
    if [[ "$need_restart" == "true" ]]; then
        start_singbox_safe
        green "[✓] 服务已自愈恢复"
    fi
    
    # OpenRung 中继自愈探测
    openrung_health_check
    # URPool 中继自愈探测
    urpool_health_check
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
        restart_processes
        exit 0
        ;;
    reconfig)
        install_nodes
        exit 0
        ;;
    update)
        update_script_self
        exit 0
        ;;
    *)
        if [[ ! -f "$WORKDIR/config.json" ]]; then
            install_nodes
        else
            menu
        fi
        ;;
esac