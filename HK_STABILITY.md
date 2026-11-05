# HK sing-box stability patch

针对 56IDC 香港 LXD 容器（`VM.Standard.E2.1.Micro`，`pids.max=128`）上
`hxzl666/singbox` 一键脚本的稳定性修复。

## 现场根因

- 容器 `pids.max = 128`，稳态 `pids.current = 82~96`；
  `/etc/s-box/install.sh` 反复报 `fork: retry: Resource temporarily unavailable`。
- FreeVPN / OpenRung 自愈每分钟探测，探测会 fork 临时 `sing-box` + `curl`，
  进程数一冲高就失败，被误判为“节点全挂”，随后切换节点并重启 sing-box。
- `monitor.log` 实测约 2~3 分钟一轮“已切换 / 配置已生效 (sing-box 已重启)”，
  每次重启都会打断所有连接。
- `sing-box.service` 实际是 `inactive`，线上跑的是手动 `nohup` 进程；
  `run_cron_check` 只修正 pid 文件，不会把进程迁回 systemd，所以服务没有自愈能力。

## 修改内容

1. **配置哈希未变不重启**
   `apply_changes` 在 `sing-box check` 后比较 `sb.json` 的 md5 与
   `/etc/s-box/.sb.json.applied`；一致且服务 active 时直接返回，不再 `service_restart`。

2. **pids 压力保护**
   - `run_cron_check` 在自愈探测前检查 `pids.current/pids.max`，
     达到 `max - 24` 就记录 `[pids守护]` 并跳过本轮。
   - `openrung_probe_egress_ip` 起临时 sing-box 前检查 `pids_ok_for_probe`，
     剩余不足 12 个 pid 直接返回失败，不再硬 fork。

3. **FreeVPN / OpenRung 连续失败防抖**
   出口探测失败写入 `fail_count.txt`，连续 3 次失败才切换节点；
   成功或切换后清零。避免慢节点/瞬时抖动触发每轮切换。

## 部署

```bash
cp -a /etc/s-box/install.sh /etc/s-box/install.sh.bak.$(date +%s)
install -m755 install.sh /etc/s-box/install.sh
bash -n /etc/s-box/install.sh
# 一次性：把手动 sing-box 收归 systemd（脚本本身不再每分钟做迁移，避免和自愈重启打架）
systemctl stop sing-box 2>/dev/null || true
pkill -9 -x sing-box 2>/dev/null || true
sleep 2
systemctl reset-failed sing-box 2>/dev/null || true
systemctl enable --now sing-box
timeout 90 /etc/s-box/install.sh cron
systemctl is-active sing-box
```

香港机实测：

- `sing-box.service` active，`MainPID=1967361`，`NRestarts=0`，`0.0.0.0:45590` LISTEN
- 连续两次 `install.sh cron` 都保持 active，无新的 `sing-box 已重启`
- `[pids守护] pids.current=113/128 接近上限，跳过本轮自愈探测` 已生效
- 脚本 md5：`33149808aa4a381e7d535bbe7246ae96`

## 仍需宿主侧处理

`pids.max=128` 是 LXD 容器限制，容器内写 `/sys/fs/cgroup/pids.max` 返回
`DENIED`。要彻底消除 fork 压力，需要 56IDC 在宿主侧执行：

```bash
lxc config set lxd1145118223000 limits.processes 512
```

外部入口 `202.73.4.182:45589-45608` 目前全部不通，宿主 `dmesg` 有
`nfnetlink_queue: nf_queue: full at 128 entries, dropping packets`，
需要 56IDC 重置端口映射/清理 nfqueue，这不是脚本能修的。

## 文件

- `install.sh`：已打补丁的完整脚本（md5 `33149808aa4a381e7d535bbe7246ae96`）
- `hk-stability.patch`：相对上游 `hxzl666/singbox` 的 diff
