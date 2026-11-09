#!/system/bin/sh
# CloudDrive2 核心生命周期管理、依赖库注入、多架构适配、多实例防冲突去重与动态挂载点管理脚本
SCRIPT_DIR="${0%/*}"
MODDIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"
[ -z "$MODDIR" ] && MODDIR="/data/adb/modules/clouddrive2_ksu_magisk"

MODULE_ID="clouddrive2_ksu_magisk"
LIVE_MODDIR="/data/adb/modules/$MODULE_ID"
BIN_DIR="$MODDIR/bin"
[ ! -d "$BIN_DIR" ] && [ -d "$LIVE_MODDIR/bin" ] && BIN_DIR="$LIVE_MODDIR/bin"
BIN_PATH="$BIN_DIR/clouddrive"
[ ! -f "$BIN_PATH" ] && [ -f "$LIVE_MODDIR/bin/clouddrive" ] && BIN_PATH="$LIVE_MODDIR/bin/clouddrive"
WWWROOT_DIR="$BIN_DIR/wwwroot"
DATA_DIR="/data/adb/clouddrive"
USERDATA_DIR="$DATA_DIR/userdata"
LOG_DIR="/data/adb/clouddrive/log"
get_log_file() {
  echo "$LOG_DIR/$(date '+%Y-%m-%d').log"
}
LOG_FILE="$(get_log_file)"
RUN_DIR="$DATA_DIR/run"
PID_FILE="$DATA_DIR/clouddrive.pid"
MANUAL_STOP_FLAG="$RUN_DIR/manual_stopped"
WEBUI_ACTION_FILE="$RUN_DIR/webui_action"
LOCK_DIR="$DATA_DIR/.cd2_start.lock"

WEB_PORT="19798"
DEVICE_NAME="Android-KSU-CloudDrive2"
OOM_ADJ="-900"
ENABLE_WATCHDOG="true"
ACQUIRE_WAKELOCK="false"
WAKELOCK_NAME="clouddrive2_keepalive_wl"

# 1. 动态检测 CPU 架构并注入对应 Bionic 依赖库路径 (32位与64位智能匹配)
detect_arch() {
  local a=""
  [ -f "$MODDIR/arch.prop" ] && a="$(grep '^ARCH=' "$MODDIR/arch.prop" 2>/dev/null | cut -d= -f2)"
  [ -z "$a" ] && [ -f "$LIVE_MODDIR/arch.prop" ] && a="$(grep '^ARCH=' "$LIVE_MODDIR/arch.prop" 2>/dev/null | cut -d= -f2)"
  if [ -z "$a" ]; then
    local isa cpu_vendor
    isa="$(getprop ro.dalvik.vm.isa.arm64 2>/dev/null) $(getprop ro.dalvik.vm.isa.arm 2>/dev/null)"
    cpu_vendor="$(grep -iE 'GenuineIntel|AuthenticAMD|vendor_id.*(Intel|AMD)' /proc/cpuinfo 2>/dev/null)"
    a="$ARCH $(uname -m 2>/dev/null) $(getprop ro.product.cpu.abi 2>/dev/null) $(getprop ro.product.cpu.abilist 2>/dev/null) $isa $cpu_vendor"
  fi
  case "$a" in
    *x86_64*|*amd64*|*x64*|*Intel*|*AMD*|*intel*|*amd*) echo "x86_64" ;;
    *arm64*|*aarch64*) echo "aarch64" ;;
    *armv7*|*armv8l*|*armeabi*|*arm*) echo "armv7" ;;
    *) echo "aarch64" ;;
  esac
}
CURRENT_ARCH="$(detect_arch)"
if [ "$CURRENT_ARCH" = "armv7" ]; then
  ARCH_LD_LIB="/system/lib:/vendor/lib:/apex/com.android.runtime/lib/bionic:$MODDIR/lib:$LIVE_MODDIR/lib"
else
  ARCH_LD_LIB="/system/lib64:/vendor/lib64:/apex/com.android.runtime/lib64/bionic:$MODDIR/lib64:$LIVE_MODDIR/lib64"
fi

# 优先使用 KernelSU / APatch / Magisk 内置的独立 BusyBox 工具链 (与 ksud module action 及 service.sh 环境完全一致)
for _p in /data/adb/ksu/bin /data/adb/ap/bin /data/adb/magisk /system/bin /system/xbin /sbin; do
  [ -d "$_p" ] && PATH="$_p:$PATH"
done
export PATH
export ASH_STANDALONE=1
# 仅对 clouddrive 二进制注入 CD2_LD_LIBRARY_PATH，不在全局 Shell 导出 LD_LIBRARY_PATH
# 避免高通机型 (一加 ColorOS / 魅族 Flyme) 上 /vendor/lib64/libc++.so 污染系统 /system/bin/cmd 与 pm 导致静默崩溃
CD2_LD_LIBRARY_PATH="/system/lib64:/vendor/lib64:/apex/com.android.runtime/lib64/bionic:$MODDIR/lib64:$ARCH_LD_LIB"
unset LD_LIBRARY_PATH
export HOME="$USERDATA_DIR"
export CLOUDDRIVE_HOME="$USERDATA_DIR"
export CLOUDDRIVE_DEVICE_NAME="$DEVICE_NAME"
export CLOUDDRIVE_SIGNING_IDENTITY="1e43b9e9e1b314368314b3a807fc1d46ca8eecd9869224b5daf550c06af20811"
export PORT="$WEB_PORT"
export TMPDIR="/data/local/tmp"
export TEMP="/data/local/tmp"
export SQLITE_TMPDIR="/data/local/tmp"
export SSL_CERT_DIR="/apex/com.android.conscrypt/cacerts:/system/etc/security/cacerts"
export ANDROID_DATA="/data"
export ANDROID_ROOT="/system"
export NO_COLOR="1"
export CLICOLOR="0"
export CLICOLOR_FORCE="0"
export RUST_LOG_STYLE="never"
export TERM="dumb"

# 关键修复：将当前脚本及衍生进程从 KernelSU Manager App 的受限 Cgroup (uid_10xxx) 迁移至系统根 Cgroup
# 当从 KSU WebUI (window.ksu.exec) 点击启动或平滑重启时，子进程默认继承了管理器 App 的 Cgroup；
# 一旦用户切出管理器打开文件管理器或选择文件，Android CachedAppOptimizer (Cgroup Freezer) 会立即冻结管理器 Cgroup 内的所有进程！
# 被冻结的 clouddrive 进程无法响应内核 /dev/fuse 请求，直接导致所有访问 /storage/emulated/0 的文件管理器与系统文件选择器死锁崩溃或空白。
switch_to_root_cgroups() {
  local pid="${1:-$$}"
  local cg
  for cg in /acct /dev/cg2_bpf /sys/fs/cgroup /dev/cpuctl /dev/stune /dev/freezer /dev/memcg /dev/blkio; do
    [ -w "$cg/cgroup.procs" ] && echo "$pid" > "$cg/cgroup.procs" 2>/dev/null || true
    [ -w "$cg/tasks" ] && echo "$pid" > "$cg/tasks" 2>/dev/null || true
  done
  if [ -r "/proc/$pid/cgroup" ]; then
    local rel
    for rel in $(awk -F: '{print $3}' "/proc/$pid/cgroup" 2>/dev/null); do
      if [ -n "$rel" ] && [ "$rel" != "/" ]; then
        [ -w "/sys/fs/cgroup${rel}/cgroup.freeze" ] && echo 0 > "/sys/fs/cgroup${rel}/cgroup.freeze" 2>/dev/null || true
        [ -w "/dev/freezer${rel}/freezer.state" ] && echo THAWED > "/dev/freezer${rel}/freezer.state" 2>/dev/null || true
      fi
    done
  fi
}

# 借道 ksud module action 执行启动/停止/平滑重启，使其 100% 运行在 KSU 模块列表「执行」按钮的原生环境中
# ksud module action 原生会在底层执行 switch_cgroups() + switch_mnt_ns(1) + busybox sh standalone
run_via_ksud_action() {
  local target_act="$1"
  mkdir -p "$RUN_DIR" 2>/dev/null || true
  echo "$target_act" > "$WEBUI_ACTION_FILE"
  chmod 0644 "$WEBUI_ACTION_FILE" 2>/dev/null || true

  # KSU 官方文档：优先用 ksud（KSU/KSU Next 都提供）
  if command -v ksud >/dev/null 2>&1; then
    ksud module action "$MODULE_ID" >/dev/null 2>&1
    [ ! -f "$WEBUI_ACTION_FILE" ] && return 0
  fi
  # APatch
  if command -v apd >/dev/null 2>&1; then
    apd module action "$MODULE_ID" >/dev/null 2>&1
    [ ! -f "$WEBUI_ACTION_FILE" ] && return 0
  fi

  rm -f "$WEBUI_ACTION_FILE" 2>/dev/null || true
  switch_to_root_cgroups "$$"
  # 模块自带 busybox 兜底（KSU 文档要求模块自包含）
  local bb=""
  [ -x "$MODDIR/bin/busybox" ] && bb="$MODDIR/bin/busybox"
  [ -z "$bb" ] && [ -x "/data/adb/ksu/bin/busybox" ] && bb="/data/adb/ksu/bin/busybox"
  [ -z "$bb" ] && [ -x "/data/adb/magisk/busybox" ] && bb="/data/adb/magisk/busybox"
  if [ -n "$bb" ]; then
    CD2_FROM_KSUD_ACTION=1 ASH_STANDALONE=1 "$bb" sh -o standalone "$0" "$target_act"
    return $?
  fi
  CD2_FROM_KSUD_ACTION=1 "$0" "$target_act"
  return $?
}

switch_to_root_cgroups "$$"

# KSU 官方：action.sh / service.sh 已在正确的全局命名空间中运行。
# 此处仅做一次检测并记录告警，不再 exec nsenter 自我重入（避免 KSU 下重复触发/死锁）。
if [ -r /proc/1/ns/mnt ] && [ "$(readlink /proc/self/ns/mnt 2>/dev/null)" != "$(readlink /proc/1/ns/mnt 2>/dev/null)" ]; then
  log_msg "warning: running outside init mount namespace, FUSE mounts may be invisible"
fi

# 实时过滤流中的 ANSI 颜色与控制转义符 (消除 [2m / [31m / [0m 等乱码)
strip_ansi_stream() {
  tr -d '\033\r' 2>/dev/null | sed 's/\[[0-9;]*[a-zA-Z]//g; s/\[[0-9;]*m//g; s/\[Om//g'
}

log_msg() {
  local ts lf
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  lf="$(get_log_file)"
  mkdir -p "$LOG_DIR"
  echo "[$ts] [cd2_ctl] $1" >> "$lf"
}

get_recommended_mount_point() {
  local cand
  for cand in "/storage/emulated/0" "/mnt/user/0/emulated/0" "/mnt/pass_through/0/emulated/0" "/sdcard"; do
    if [ -d "$cand" ] || nsenter -t 1 -m -- [ -d "$cand" ]; then
      echo "$cand"
      return 0
    fi
  done
  echo "/storage/emulated/0"
}

# 从 /proc/mounts 检索由 CloudDrive2 (CloudFS) 挂载的真实网盘目录
# 自动将 Android 挂载命名空间内部镜像路径 (/mnt/user/0/emulated/0/ 等) 规范化换算为用户可直接访问的真实存储路径 (/storage/emulated/0/ 等)
list_cd2_fuse_mounts() {
  nsenter -t 1 -m -- awk '
    ($1 == "CloudFS" || $1 ~ /^(CloudFS|clouddrive)/ || $3 ~ /^fuse\.(CloudFS|clouddrive)/) {
      mp = $2
      gsub(/\\040/, " ", mp)
      if (mp ~ /^\/(sys|proc|dev|apex|system|vendor|product|odm|data)(\/|$)/) next
      if (mp ~ /^\/storage\/emulated(\/[0-9]+)?$/) next
      if (mp ~ /^\/storage\/emulated\/[0-9]+\/Android(\/|$)/) next
      if (mp ~ /^\/mnt\/runtime\/(default|read|write|full)\/emulated(\/[0-9]+)?$/) next
      if (mp ~ /^\/mnt\/(user|pass_through|installer|androidwritable)\/[0-9]+\/emulated(\/[0-9]+)?$/) next
      if (mp ~ /^\/mnt\/.*\/Android(\/|$)/) next

      norm = mp
      sub(/^\/mnt\/runtime\/(default|read|write|full)\/emulated\/[0-9]+\//, "/storage/emulated/0/", norm)
      sub(/^\/mnt\/(user|pass_through|installer|androidwritable)\/[0-9]+\/emulated\/[0-9]+\//, "/storage/emulated/0/", norm)

      key = norm

      if (!(key in best) || mp ~ /^\/storage\/emulated\/0\//) {
        best[key] = norm
      }
      if (!(key in seen)) {
        order[++n] = key
        seen[key] = 1
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        print best[order[i]]
      }
    }
  ' /proc/mounts 2>/dev/null | sort -u
}

# 仅清理属于 CloudDrive2 (CloudFS) 的残留挂载点 (对齐官方二进制 linux_fuse3_raw.rs 的 6 视图全量卸载逻辑)
# 严禁扫描或卸载任何非 CloudFS 的 fuse 挂载点，彻底杜绝误伤 Android MediaProvider (/dev/fuse) 导致文件管理器崩溃或选择文件空白
cleanup_cd2_fuse_mounts() {
  nsenter -t 1 -m -- awk '
    ($1 == "CloudFS" || $1 ~ /^(CloudFS|clouddrive)/ || $3 ~ /^fuse\.(CloudFS|clouddrive)/) {
      mp = $2
      gsub(/\\040/, " ", mp)
      if (mp ~ /^\/(sys|proc|dev|apex|system|vendor|product|odm|data)(\/|$)/) next
      if (mp ~ /^\/storage\/emulated(\/[0-9]+)?$/) next
      if (mp ~ /^\/storage\/emulated\/[0-9]+\/Android(\/|$)/) next
      if (mp ~ /^\/mnt\/.*\/Android(\/|$)/) next
      print mp
    }
  ' /proc/mounts 2>/dev/null | sort -r -u | while IFS= read -r mp; do
    [ -z "$mp" ] && continue
    log_msg "正在卸载残留 CloudFS 挂载点: $mp"
    nsenter -t 1 -m -- umount -l "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    nsenter -t 1 -m -- umount -f "$mp" 2>/dev/null || true
    nsenter -t 1 -m -- fusermount -u -z "$mp" 2>/dev/null || true

    # 同步清理该挂载点在 Android 6 大存储视图命名空间中的关联绑定 (对齐官方 linux_fuse3_raw.rs 卸载逻辑)
    local rel=""
    case "$mp" in
      /mnt/user/0/emulated/0/*) rel="${mp#/mnt/user/0/emulated/0/}" ;;
      /mnt/pass_through/0/emulated/0/*) rel="${mp#/mnt/pass_through/0/emulated/0/}" ;;
      /mnt/androidwritable/0/emulated/0/*) rel="${mp#/mnt/androidwritable/0/emulated/0/}" ;;
      /mnt/runtime/default/emulated/0/*) rel="${mp#/mnt/runtime/default/emulated/0/}" ;;
      /mnt/runtime/read/emulated/0/*) rel="${mp#/mnt/runtime/read/emulated/0/}" ;;
      /mnt/runtime/write/emulated/0/*) rel="${mp#/mnt/runtime/write/emulated/0/}" ;;
      /storage/emulated/0/*) rel="${mp#/storage/emulated/0/}" ;;
    esac
    if [ -n "$rel" ]; then
      local prefix
      for prefix in "/mnt/user/0/emulated/0" "/mnt/pass_through/0/emulated/0" "/mnt/androidwritable/0/emulated/0" "/mnt/runtime/default/emulated/0" "/mnt/runtime/read/emulated/0" "/mnt/runtime/write/emulated/0" "/storage/emulated/0"; do
        nsenter -t 1 -m -- umount -l "$prefix/$rel" 2>/dev/null || true
      done
    fi
  done
}

# 自检与理顺：物理确保 bin/wwwroot 静态 Web 前端资源完好，避免 WebUI 打不开或 404
ensure_wwwroot_assets() {
  # 彻底清除根目录冗余副本与可能残留的软链接，确保仅保留 bin/wwwroot 唯一物理实体目录
  rm -rf "$MODDIR/wwwroot" "$LIVE_MODDIR/wwwroot" 2>/dev/null || true
  [ -L "$WWWROOT_DIR" ] && rm -f "$WWWROOT_DIR" 2>/dev/null || true
  mkdir -p "$WWWROOT_DIR" 2>/dev/null

  # 1. 修复可能由历史解压异常造成的嵌套
  if [ -d "$WWWROOT_DIR/wwwroot" ]; then
    cp -af "$WWWROOT_DIR/wwwroot/." "$WWWROOT_DIR/" 2>/dev/null || true
    rm -rf "$WWWROOT_DIR/wwwroot" 2>/dev/null || true
  fi
}

# 枚举系统中所有真实的 clouddrive ELF 进程 PID
list_all_cd2_pids() {
  local pids=""
  if command -v pidof >/dev/null 2>&1; then
    pids="$(pidof clouddrive 2>/dev/null)"
  fi
  if [ -z "$pids" ]; then
    pids="$(grep -l '^clouddrive$' /proc/[0-9]*/comm 2>/dev/null | awk -F'/' '{print $3}')"
  fi
  for p in $pids; do
    [ -d "/proc/$p" ] && echo "$p"
  done | sort -n -u
}

# 自动接管主工作进程 (clouddrive Start-Service <ppid>) 与官方原生 housekeeping 父进程
# 逆向官方 clouddrive 二进制 (src/main.rs) 可知：官方原生采用双进程架构，无参父进程作为 housekeeping 引导与进程监控，
# 由其拉起 'clouddrive Start-Service <ppid>' 真正承载 gRPC/WebUI/FUSE3 服务；脚本优先识别工作进程，并协同保留父子进程。
dedup_running_pids() {
  local all_pids
  all_pids="$(list_all_cd2_pids)"
  [ -z "$all_pids" ] && return 1

  for p in $all_pids; do
    switch_to_root_cgroups "$p"
  done

  local count
  count=$(printf "%s\n" "$all_pids" | grep -c '^[0-9]' 2>/dev/null || echo 0)
  if [ "$count" -le 1 ]; then
    local single_pid
    single_pid=$(printf "%s\n" "$all_pids" | head -n 1)
    if [ -n "$single_pid" ]; then
      echo "$single_pid" > "$PID_FILE"
      echo "$OOM_ADJ" > "/proc/$single_pid/oom_score_adj" 2>/dev/null || true
      echo "$single_pid"
      return 0
    fi
    return 1
  fi

  local best_pid=""
  local best_rss=-1
  local best_is_worker=0
  for p in $all_pids; do
    local cmdline is_worker rss
    cmdline="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
    is_worker=0
    case "$cmdline" in
      *Start-Service*) is_worker=1 ;;
    esac
    rss=$(awk '/VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null)
    [ -z "$rss" ] && rss=0

    if [ "$is_worker" -gt "$best_is_worker" ]; then
      best_is_worker="$is_worker"
      best_rss="$rss"
      best_pid="$p"
    elif [ "$is_worker" -eq "$best_is_worker" ] && [ "$rss" -gt "$best_rss" ]; then
      best_rss="$rss"
      best_pid="$p"
    fi
  done

  [ -z "$best_pid" ] && best_pid=$(printf "%s\n" "$all_pids" | head -n 1)

  local best_ppid
  best_ppid=$(awk '/PPid/{print $2}' "/proc/$best_pid/status" 2>/dev/null)

  for p in $all_pids; do
    if [ "$p" != "$best_pid" ]; then
      if [ "$p" = "$best_ppid" ]; then
        # 官方原生父外壳为 housekeeping 守护/引导进程，将其加入系统根 cgroup 协同保活，严禁 kill 避免主工作进程连带退出或断连
        switch_to_root_cgroups "$p"
      else
        log_msg "检测到额外 clouddrive 冗余进程 (PID=$p)，已清理并保留主工作进程 (PID=$best_pid)"
        kill -TERM "$p" 2>/dev/null || true
      fi
    fi
  done

  switch_to_root_cgroups "$best_pid"
  echo "$best_pid" > "$PID_FILE"
  echo "$OOM_ADJ" > "/proc/$best_pid/oom_score_adj" 2>/dev/null || true
  echo "$best_pid"
  return 0
}

# 原子级更新 module.prop 状态描述 (状态图标: ✅运行中 / ⏳初始化或启动中 / ⚠️异常告警 / ❌已停止 / ❓未知状态)
update_module_prop_status() {
  local status_text="$1"
  [ -z "$status_text" ] && status_text="[❓ 状态未知]"
  local mounts_list
  mounts_list="$(list_cd2_fuse_mounts)"
  local mnt_count=0
  local mnt_summary="未挂载(WebUI内添加)"
  if [ -n "$mounts_list" ]; then
    mnt_count=$(printf "%s\n" "$mounts_list" | grep -c '^/' 2>/dev/null || echo 0)
    local first_mp
    first_mp=$(printf "%s\n" "$mounts_list" | head -n 1)
    if [ "$mnt_count" -eq 1 ]; then
      mnt_summary="已挂载: $first_mp"
    else
      mnt_summary="已挂载 ${mnt_count} 项 ($first_mp 等)"
    fi
  fi

  local new_desc="description=${status_text} CloudDrive2 (${CURRENT_ARCH}) · WebUI :${WEB_PORT} · ${mnt_summary}"

  for target_prop in "$MODDIR/module.prop" "$LIVE_MODDIR/module.prop"; do
    if [ -f "$target_prop" ]; then
      local tmp_prop="${target_prop}.tmp.$$"
      awk -v desc="$new_desc" '
        /^description=/ { print desc; found=1; next }
        { print }
        END { if (!found) print desc }
      ' "$target_prop" > "$tmp_prop" 2>/dev/null && mv -f "$tmp_prop" "$target_prop" 2>/dev/null
      chmod 0644 "$target_prop" 2>/dev/null || true
    fi
  done
}

# 每次启动或重启时：先将旧日志备份为 backup.YYYY-MM-DD.log (仅保留一份备份，不产生 .tmp 残留)，再创建新日志
backup_old_logs() {
  mkdir -p "$LOG_DIR"
  rm -f "$LOG_DIR"/*.tmp "$LOG_DIR"/backup.*.tmp 2>/dev/null || true
  LOG_FILE="$(get_log_file)"
  local target_old=""
  local old_date=""
  local f

  for f in $(ls -1t "$LOG_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].log 2>/dev/null); do
    if [ -s "$f" ]; then
      target_old="$f"
      old_date="$(basename "$f" .log)"
      break
    fi
  done

  if [ -z "$target_old" ] && [ -s "$LOG_DIR/clouddrive.log" ]; then
    target_old="$LOG_DIR/clouddrive.log"
    old_date="$(date '+%Y-%m-%d')"
  fi

  if [ -n "$target_old" ] && [ -s "$target_old" ]; then
    rm -f "$LOG_DIR"/backup.*.log "$LOG_DIR"/clouddrive.log.* "$LOG_DIR"/*.tmp 2>/dev/null || true
    local backup_path="$LOG_DIR/backup.${old_date}.log"
    strip_ansi_stream < "$target_old" > "$backup_path" 2>/dev/null
    if [ ! -s "$backup_path" ]; then
      cp -f "$target_old" "$backup_path" 2>/dev/null || true
    fi
  fi

  rm -f "$LOG_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].log "$LOG_DIR/clouddrive.log" "$LOG_DIR"/clouddrive.log.* "$LOG_DIR"/*.tmp 2>/dev/null || true
  : > "$LOG_FILE"
}

# 原地清理当前日志文件中的 ANSI 颜色控制符 (保持文件 inode 不变，避免使用管道子进程导致残留两个 sh cd2_ctl.sh 进程)
clean_log_ansi_inplace() {
  local lf
  lf="$(get_log_file)"
  [ ! -s "$lf" ] && return 0
  if grep -q "$(printf '\033')" "$lf" 2>/dev/null || grep -qE '\[[0-9;]*m|\[Om' "$lf" 2>/dev/null; then
    local cleaned
    cleaned="$(strip_ansi_stream < "$lf" 2>/dev/null)"
    if [ -n "$cleaned" ]; then
      printf '%s\n' "$cleaned" > "$lf" 2>/dev/null || true
    fi
  fi
}

# 日志超限轮转逻辑 (单份备份 backup.YYYY-MM-DD.log，无 .tmp 残留)
rotate_logs() {
  local max_bytes=$(( 10 * 1024 * 1024 ))
  rm -f "$LOG_DIR"/*.tmp "$LOG_DIR"/backup.*.tmp 2>/dev/null || true
  clean_log_ansi_inplace
  LOG_FILE="$(get_log_file)"
  if [ -f "$LOG_FILE" ]; then
    local cur_size
    cur_size=$(stat -c '%s' "$LOG_FILE" 2>/dev/null || wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$cur_size" -ge "$max_bytes" ]; then
      local cur_date
      cur_date="$(date '+%Y-%m-%d')"
      rm -f "$LOG_DIR"/backup.*.log "$LOG_DIR"/clouddrive.log.* "$LOG_DIR"/*.tmp 2>/dev/null || true
      strip_ansi_stream < "$LOG_FILE" > "$LOG_DIR/backup.${cur_date}.log" 2>/dev/null
      if [ ! -s "$LOG_DIR/backup.${cur_date}.log" ]; then
        cp -f "$LOG_FILE" "$LOG_DIR/backup.${cur_date}.log" 2>/dev/null || true
      fi
      : > "$LOG_FILE"
      log_msg "日志体积达到 ${cur_size} bytes，已备份至 backup.${cur_date}.log 并重置新日志 (仅保留 1 份备份)"
    fi
  fi
}

prepare_fuse_env() {
  if [ ! -c "/dev/fuse" ]; then
    log_msg "未检测到 /dev/fuse，正在尝试 modprobe / insmod fuse..."
    modprobe fuse 2>/dev/null || insmod /vendor/lib/modules/fuse.ko 2>/dev/null || true
  fi

  if [ -c "/dev/fuse" ]; then
    chmod 0666 /dev/fuse 2>/dev/null || true
  else
    log_msg "错误: 内核缺少 /dev/fuse 字符设备，WebUI 中的 FUSE 挂载可能无法生效!"
  fi

  if [ ! -f /etc/fuse.conf ] || ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
    echo "user_allow_other" >> /etc/fuse.conf 2>/dev/null || true
  fi

  # 注意: 严禁执行 mount --make-rshared /mnt/runtime/default
  # CloudDrive2 (v1.1.3+) 原生已内置 Entering PID 1 mount namespace for system-wide FUSE visibility；
  # 强行修改 /mnt/runtime/default 共享传播属性会导致卸载/重启时破坏 Android vold 与 MediaProvider 挂载树，引发文件管理器崩溃与选择文件空白。
  cleanup_cd2_fuse_mounts

  mkdir -p "$USERDATA_DIR" "$LOG_DIR"
  rm -rf "$DATA_DIR/tmp" "$RUN_DIR/cd2_bin_version.cache" 2>/dev/null || true
}

get_running_pid() {
  dedup_running_pids
}

start_service() {
  switch_to_root_cgroups "$$"
  mkdir -p "$DATA_DIR" "$RUN_DIR"
  rm -f "$MANUAL_STOP_FLAG" 2>/dev/null || true
  local existing_pid
  existing_pid="$(get_running_pid)"
  if [ -n "$existing_pid" ]; then
    switch_to_root_cgroups "$existing_pid"
    local existing_ppid
    existing_ppid=$(awk '/PPid/{print $2}' "/proc/$existing_pid/status" 2>/dev/null)
    if [ -n "$existing_ppid" ] && [ "$existing_ppid" -gt 1 ] && [ -d "/proc/$existing_ppid" ]; then
      switch_to_root_cgroups "$existing_ppid"
      echo "$OOM_ADJ" > "/proc/$existing_ppid/oom_score_adj" 2>/dev/null || true
    fi
    log_msg "CloudDrive2 已在运行中 (主工作进程 PID: $existing_pid)"
    update_module_prop_status "[✅ PID:$existing_pid]"
    rm -f "$RUN_DIR/op_state" 2>/dev/null || true
    return 0
  fi

  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    sleep 1
    existing_pid="$(get_running_pid)"
    if [ -n "$existing_pid" ]; then
      switch_to_root_cgroups "$existing_pid"
      local existing_ppid
      existing_ppid=$(awk '/PPid/{print $2}' "/proc/$existing_pid/status" 2>/dev/null)
      if [ -n "$existing_ppid" ] && [ "$existing_ppid" -gt 1 ] && [ -d "/proc/$existing_ppid" ]; then
        switch_to_root_cgroups "$existing_ppid"
        echo "$OOM_ADJ" > "/proc/$existing_ppid/oom_score_adj" 2>/dev/null || true
      fi
      update_module_prop_status "[✅ PID:$existing_pid]"
      rm -f "$RUN_DIR/op_state" 2>/dev/null || true
      return 0
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || true
  fi

  update_module_prop_status "[⏳ 正在启动]"
  backup_old_logs
  [ -n "$CD2_BOOT_MSG" ] && log_msg "$CD2_BOOT_MSG"
  prepare_fuse_env

  chmod 0755 "$BIN_PATH" 2>/dev/null
  chcon u:object_r:system_file:s0 "$BIN_PATH" 2>/dev/null
  ensure_wwwroot_assets
  rm -rf "$MODDIR/wwwroot" "$LIVE_MODDIR/wwwroot" 2>/dev/null || true
  [ -L "$MODDIR/bin/wwwroot" ] && rm -f "$MODDIR/bin/wwwroot" 2>/dev/null || true
  mkdir -p "$MODDIR/bin/wwwroot"

  log_msg "正在启动 CloudDrive2 (架构: $CURRENT_ARCH, 二进制: $BIN_PATH, 端口: $WEB_PORT, 推荐挂载路径: $(get_recommended_mount_point))..."
  cd "$BIN_DIR" 2>/dev/null || cd "$MODDIR" || exit 1

  local cur_log_file
  cur_log_file="$(get_log_file)"
  (
    switch_to_root_cgroups "$$"
    export LD_LIBRARY_PATH="$CD2_LD_LIBRARY_PATH"
    exec </dev/null >>"$cur_log_file" 2>&1
    for fd in 3 4 5 6 7 8 9; do eval "exec ${fd}>&-" 2>/dev/null || true; done
    echo "$OOM_ADJ" > /proc/self/oom_score_adj 2>/dev/null || true
    trap '' PIPE HUP
    exec nsenter -t 1 -m -- "$BIN_PATH"
  ) </dev/null >/dev/null 2>&1 &
  sleep 1
  rm -rf "$LOCK_DIR" 2>/dev/null
  clean_log_ansi_inplace

  local new_pid
  new_pid="$(dedup_running_pids)"
  if [ -z "$new_pid" ]; then
    sleep 1
    new_pid="$(dedup_running_pids)"
  fi
  clean_log_ansi_inplace

  if [ -n "$new_pid" ] && [ -d "/proc/$new_pid" ]; then
    switch_to_root_cgroups "$new_pid"
    echo "$new_pid" > "$PID_FILE"
    echo "$OOM_ADJ" > "/proc/$new_pid/oom_score_adj" 2>/dev/null || true

    local new_ppid
    new_ppid=$(awk '/PPid/{print $2}' "/proc/$new_pid/status" 2>/dev/null)
    if [ -n "$new_ppid" ] && [ "$new_ppid" -gt 1 ] && [ -d "/proc/$new_ppid" ]; then
      switch_to_root_cgroups "$new_ppid"
      echo "$OOM_ADJ" > "/proc/$new_ppid/oom_score_adj" 2>/dev/null || true
    fi

    if [ "$ACQUIRE_WAKELOCK" = "true" ] && [ -w /sys/power/wake_lock ]; then
      echo "$WAKELOCK_NAME" > /sys/power/wake_lock 2>/dev/null || true
    fi

    local ppid_info="无父进程(直接运行)"
    [ -n "$new_ppid" ] && [ "$new_ppid" -gt 1 ] && ppid_info="PPID=$new_ppid (官方原生 housekeeping 父进程)"
    log_msg "CloudDrive2 启动成功! 主工作进程 PID=$new_pid, $ppid_info, 架构=$CURRENT_ARCH, oom_score_adj=$(cat /proc/$new_pid/oom_score_adj 2>/dev/null)"
    update_module_prop_status "[✅ PID:$new_pid]"
    rm -f "$RUN_DIR/op_state" 2>/dev/null || true
    return 0
  else
    log_msg "错误: CloudDrive2 启动失败! 请检查 $LOG_FILE 中的动态链接或权限日志"
    dmesg | grep -iE "fuse|clouddrive|avc: denied" | tail -n 15 >> "$LOG_FILE" 2>/dev/null
    update_module_prop_status "[⚠️ 启动异常 请看日志]"
    rm -f "$RUN_DIR/op_state" 2>/dev/null || true
    return 1
  fi
}

stop_service() {
  switch_to_root_cgroups "$$"
  touch "$MANUAL_STOP_FLAG" 2>/dev/null || true
  log_msg "收到停止指令，正在优雅关闭所有 CloudDrive2 核心与父进程，并清理 CloudFS 挂载点..."
  rm -rf "$LOCK_DIR" 2>/dev/null

  local all_pids
  all_pids="$(list_all_cd2_pids)"
  if [ -n "$all_pids" ]; then
    for p in $all_pids; do
      switch_to_root_cgroups "$p"
      kill -TERM "$p" 2>/dev/null || true
    done
    local count=0
    while [ -n "$(list_all_cd2_pids)" ] && [ $count -lt 4 ]; do
      sleep 1
      count=$(( count + 1 ))
    done
    for p in $(list_all_cd2_pids); do
      kill -KILL "$p" 2>/dev/null || true
    done
  fi
  rm -f "$PID_FILE"

  # 仅清理残留的 CloudFS 挂载点，绝不触碰 Android 系统挂载
  cleanup_cd2_fuse_mounts

  if [ "$ACQUIRE_WAKELOCK" = "true" ] && [ -w /sys/power/wake_unlock ]; then
    echo "$WAKELOCK_NAME" > /sys/power/wake_unlock 2>/dev/null || true
  fi

  update_module_prop_status "[❌ 已停止]"
  rm -f "$RUN_DIR/op_state" 2>/dev/null || true
  log_msg "CloudDrive2 主工作进程与官方原生 housekeeping 父进程已停止，相关 CloudFS 挂载点已安全清理"
}

status_service() {
  ensure_wwwroot_assets
  local pid
  pid="$(get_running_pid)"
  local mounts
  mounts=$(list_cd2_fuse_mounts | tr '\n' ',' | sed 's/,$//')
  [ -z "$mounts" ] && mounts="暂无挂载(请在WebUI添加)"
  local lan_ip
  lan_ip=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
  [ -z "$lan_ip" ] && lan_ip="127.0.0.1"
  local cur_ver
  cur_ver="$(get_current_version)"
  local autostart_flag="ENABLED"
  if [ -f "$DATA_DIR/disable_autostart" ] || [ -f "$MODDIR/disable_autostart" ]; then
    autostart_flag="DISABLED"
  fi
  local rec_mount
  rec_mount="$(get_recommended_mount_point)"
  if [ -n "$pid" ]; then
    local ppid="--"
    local ppid_rss="--"
    local cand_ppid
    cand_ppid=$(awk '/PPid/{print $2}' "/proc/$pid/status" 2>/dev/null)
    if [ -n "$cand_ppid" ] && [ "$cand_ppid" -gt 1 ] && [ -d "/proc/$cand_ppid" ]; then
      ppid="$cand_ppid"
      ppid_rss=$(awk '/VmRSS/{print $2 $3}' "/proc/$ppid/status" 2>/dev/null || echo "--")
      [ -z "$ppid_rss" ] && ppid_rss="--"
      switch_to_root_cgroups "$ppid"
      echo "$OOM_ADJ" > "/proc/$ppid/oom_score_adj" 2>/dev/null || true
    fi

    update_module_prop_status "[✅ PID:$pid]"
    local oom
    oom=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null || echo "N/A")
    local rss
    rss=$(awk '/VmRSS/{print $2 $3}' "/proc/$pid/status" 2>/dev/null || echo "未知")
    echo "RUNNING|PID=$pid|PORT=$WEB_PORT|OOM_ADJ=$oom|RSS=$rss|PPID=$ppid|PPID_RSS=$ppid_rss|MOUNTS=$mounts|LAN_IP=$lan_ip|ARCH=$CURRENT_ARCH|VER=$cur_ver|AUTOSTART=$autostart_flag|REC_MOUNT=$rec_mount"
    return 0
  else
    update_module_prop_status "[❌ 已停止]"
    echo "STOPPED|PORT=$WEB_PORT|MOUNTS=$mounts|LAN_IP=$lan_ip|ARCH=$CURRENT_ARCH|VER=$cur_ver|AUTOSTART=$autostart_flag|REC_MOUNT=$rec_mount"
    return 1
  fi
}

# 国内加速代理镜像池
PROXIES="https://ghproxy.net/ https://gh-proxy.com/ https://mirror.ghproxy.com/"

fetch_ctl_data() {
  local target_url="$1"
  local dest_path="$2"
  local mirror
  for mirror in $PROXIES ""; do
    local req_url="${mirror}${target_url}"
    if [ -n "$dest_path" ]; then
      if command -v curl >/dev/null 2>&1; then
        if curl -sL --connect-timeout 8 --max-time 180 --retry 2 "$req_url" -o "$dest_path" 2>/dev/null && [ -s "$dest_path" ]; then
          return 0
        fi
      elif command -v wget >/dev/null 2>&1; then
        if wget -q -T 10 -t 2 -O "$dest_path" "$req_url" 2>/dev/null && [ -s "$dest_path" ]; then
          return 0
        fi
      fi
    else
      local resp=""
      if command -v curl >/dev/null 2>&1; then
        resp="$(curl -sL --connect-timeout 6 --max-time 12 "$req_url" 2>/dev/null)"
      elif command -v wget >/dev/null 2>&1; then
        resp="$(wget -q -T 6 -t 1 -O - "$req_url" 2>/dev/null)"
      fi
      if [ -n "$resp" ]; then
        printf "%s" "$resp"
        return 0
      fi
    fi
  done
  return 1
}

# 获取模块自身版本 (读取 module.prop 中的 version=v1.1.6-r14，仅用于模块自身更新检测)
get_module_version() {
  local ver=""
  if [ -f "$LIVE_MODDIR/module.prop" ]; then
    ver=$(grep '^version=' "$LIVE_MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
  elif [ -f "$MODDIR/module.prop" ]; then
    ver=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
  fi
  [ -z "$ver" ] && ver="v1.1.6-r14"
  echo "$ver"
}

# 实时获取本机真实正在使用的 CloudDrive2 二进制版本 (如 v1.1.3)，绝不混用模块版本
# 优先读取签名缓存与运行日志横幅 (耗时 <2ms)，次选通过 grep -a 快速扫描二进制特征段，避免大文件 tr 阻塞 WebUI
get_current_version() {
  local target_bin="$BIN_PATH"
  local running_pid=""
  if [ -f "$PID_FILE" ]; then
    running_pid="$(cat "$PID_FILE" 2>/dev/null)"
  fi
  if [ -n "$running_pid" ] && [ -r "/proc/$running_pid/exe" ]; then
    target_bin="/proc/$running_pid/exe"
  fi

  local ver_num=""

  # 1. 从当前真实运行日志中的 "welcome to clouddrive vX.Y.Z" 启动横幅提取 (<2ms)
  local cur_log
  cur_log="$(get_log_file)"
  if [ -s "$cur_log" ]; then
    ver_num=$(grep -oE 'welcome to clouddrive v[0-9]+\.[0-9]+\.[0-9]+' "$cur_log" 2>/dev/null | tail -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  fi
  if [ -z "$ver_num" ] && ls "$LOG_DIR"/*.log >/dev/null 2>&1; then
    ver_num=$(grep -h -oE 'welcome to clouddrive v[0-9]+\.[0-9]+\.[0-9]+' "$LOG_DIR"/*.log 2>/dev/null | tail -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  fi

  # 2. 直接使用 grep -a 从本机 clouddrive ELF 二进制快速匹配首个版本常量 (FORCED_VERSIONx.y.z / 123panCd2/Vx.y.z)
  if [ -z "$ver_num" ] && [ -r "$target_bin" ]; then
    ver_num=$(grep -a -oE 'FORCED_VERSION[0-9]+\.[0-9]+\.[0-9]+|123panCd2/V[0-9]+\.[0-9]+\.[0-9]+' "$target_bin" 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  fi

  if [ -n "$ver_num" ]; then
    echo "v${ver_num#v}"
    return 0
  fi

  echo "v1.1.3"
  return 0
}

get_current_version_code() {
  local code=""
  if [ -f "$LIVE_MODDIR/module.prop" ]; then
    code=$(grep '^versionCode=' "$LIVE_MODDIR/module.prop" 2>/dev/null | cut -d= -f2 | tr -cd '0-9')
  elif [ -f "$MODDIR/module.prop" ]; then
    code=$(grep '^versionCode=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2 | tr -cd '0-9')
  fi
  [ -z "$code" ] && code="11614"
  echo "$code"
}

get_update_json_url() {
  local url=""
  if [ -f "$LIVE_MODDIR/module.prop" ]; then
    url=$(grep '^updateJson=' "$LIVE_MODDIR/module.prop" 2>/dev/null | cut -d= -f2-)
  elif [ -f "$MODDIR/module.prop" ]; then
    url=$(grep '^updateJson=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-)
  fi
  [ -z "$url" ] && url="https://raw.githubusercontent.com/a422015028/clouddrive2_ksu_magisk/main/update.json"
  echo "$url"
}

# 检查模块自身更新 (读取 module.prop 中的 updateJson 并对比 integer versionCode)
check_module_update() {
  local update_url
  update_url="$(get_update_json_url)"
  local local_ver
  local_ver="$(get_module_version)"
  local local_code
  local_code="$(get_current_version_code)"

  local json=""
  json="$(fetch_ctl_data "$update_url")"
  if [ -z "$json" ]; then
    echo "MODULE_CHECK_ERR|LOCAL_VER=$local_ver|LOCAL_CODE=$local_code|URL=$update_url"
    return 1
  fi

  local remote_ver
  remote_ver=$(printf "%s" "$json" | grep -o '"version" *: *"[^"]*"' | head -n 1 | cut -d'"' -f4)
  local remote_code
  remote_code=$(printf "%s" "$json" | grep -o '"versionCode" *: *[0-9]*' | head -n 1 | grep -o '[0-9]*$')
  local zip_url
  zip_url=$(printf "%s" "$json" | grep -o '"zipUrl" *: *"[^"]*"' | head -n 1 | cut -d'"' -f4)
  local changelog_url
  changelog_url=$(printf "%s" "$json" | grep -o '"changelog" *: *"[^"]*"' | head -n 1 | cut -d'"' -f4)

  [ -z "$remote_ver" ] && remote_ver="$local_ver"
  [ -z "$remote_code" ] && remote_code="$local_code"

  local mod_update_avail=0
  if [ "$remote_code" -gt "$local_code" ] 2>/dev/null; then
    mod_update_avail=1
  fi

  echo "MODULE_CHECK_OK|LOCAL_VER=$local_ver|LOCAL_CODE=$local_code|REMOTE_VER=$remote_ver|REMOTE_CODE=$remote_code|UPDATE_AVAIL=$mod_update_avail|ZIP_URL=$zip_url|CHANGELOG=$changelog_url"
  return 0
}

case "$1" in
  start)
    if [ "${CD2_FROM_KSUD_ACTION:-0}" != "1" ]; then
      run_via_ksud_action "start"
    else
      start_service
    fi
    ;;
  stop)
    if [ "${CD2_FROM_KSUD_ACTION:-0}" != "1" ]; then
      run_via_ksud_action "stop"
    else
      stop_service
    fi
    ;;
  restart)
    if [ "${CD2_FROM_KSUD_ACTION:-0}" != "1" ]; then
      run_via_ksud_action "restart"
    else
      stop_service
      sleep 1
      start_service
    fi
    ;;
  start-bg)
    mkdir -p "$DATA_DIR" "$RUN_DIR" 2>/dev/null || true
    rm -f "$MANUAL_STOP_FLAG" 2>/dev/null || true
    echo "STARTING" > "$RUN_DIR/op_state"
    (
      switch_to_root_cgroups "$$"
      exec </dev/null >/dev/null 2>&1
      for fd in 3 4 5 6 7 8 9; do eval "exec ${fd}>&-" 2>/dev/null || true; done
      run_via_ksud_action "start" </dev/null >/dev/null 2>&1 &
    ) </dev/null >/dev/null 2>&1 &
    echo "BG_OK|ACTION=start"
    exit 0
    ;;
  stop-bg)
    mkdir -p "$DATA_DIR" "$RUN_DIR" 2>/dev/null || true
    touch "$MANUAL_STOP_FLAG" 2>/dev/null || true
    echo "STOPPING" > "$RUN_DIR/op_state"
    (
      switch_to_root_cgroups "$$"
      exec </dev/null >/dev/null 2>&1
      for fd in 3 4 5 6 7 8 9; do eval "exec ${fd}>&-" 2>/dev/null || true; done
      run_via_ksud_action "stop" </dev/null >/dev/null 2>&1 &
    ) </dev/null >/dev/null 2>&1 &
    echo "BG_OK|ACTION=stop"
    exit 0
    ;;
  restart-bg)
    mkdir -p "$DATA_DIR" "$RUN_DIR" 2>/dev/null || true
    echo "RESTARTING" > "$RUN_DIR/op_state"
    (
      switch_to_root_cgroups "$$"
      exec </dev/null >/dev/null 2>&1
      for fd in 3 4 5 6 7 8 9; do eval "exec ${fd}>&-" 2>/dev/null || true; done
      run_via_ksud_action "restart" </dev/null >/dev/null 2>&1 &
    ) </dev/null >/dev/null 2>&1 &
    echo "BG_OK|ACTION=restart"
    exit 0
    ;;
  status)
    status_service
    ;;
  check-module-update)
    check_module_update
    ;;
  get-arch)
    echo "$CURRENT_ARCH"
    ;;
  update-prop)
    status_service >/dev/null 2>&1
    ;;
  rotate-log)
    rotate_logs
    ;;
  logs)
    LOG_FILE="$(get_log_file)"
    if [ -s "$LOG_FILE" ]; then
      tail -n 25 "$LOG_FILE" 2>/dev/null | strip_ansi_stream
    elif ls "$LOG_DIR"/backup.*.log >/dev/null 2>&1; then
      tail -n 25 "$LOG_DIR"/backup.*.log 2>/dev/null | strip_ansi_stream
    fi
    ;;
  autostart-status)
    if [ -f "$MODDIR/disable_autostart" ] || [ -f "$DATA_DIR/disable_autostart" ] || [ -f "$LIVE_MODDIR/disable_autostart" ]; then
      echo "DISABLED"
      return 1
    else
      echo "ENABLED"
      return 0
    fi
    ;;
  autostart-enable)
    rm -f "$MODDIR/disable_autostart" "$DATA_DIR/disable_autostart" "$LIVE_MODDIR/disable_autostart" 2>/dev/null || true
    echo "ENABLED"
    return 0
    ;;
  autostart-disable)
    mkdir -p "$DATA_DIR"
    touch "$MODDIR/disable_autostart" "$DATA_DIR/disable_autostart" "$LIVE_MODDIR/disable_autostart" 2>/dev/null || true
    echo "DISABLED"
    return 0
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|check-module-update|get-arch|update-prop|rotate-log|logs|autostart-status|autostart-enable|autostart-disable}"
    exit 1
    ;;
esac
