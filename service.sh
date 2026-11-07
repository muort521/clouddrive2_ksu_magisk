#!/system/bin/sh
# Magisk / KernelSU / APatch late_start service 启动脚本
MODDIR="${0%/*}"
CTL_SCRIPT="$MODDIR/scripts/cd2_ctl.sh"
LOG_DIR="/data/adb/clouddrive/log"
DATA_DIR="/data/adb/clouddrive"

mkdir -p "$LOG_DIR"

# 0. 检查开机自启开关 (若用户在 WebUI 中关闭了自启，生成了 disable_autostart 标志)
if [ -f "$MODDIR/disable_autostart" ] || [ -f "$DATA_DIR/disable_autostart" ] || [ -f "/data/adb/modules/clouddrive2_ksu_magisk/disable_autostart" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [service.sh] 检测到已禁用开机自启标志 (disable_autostart)，本次开机跳过拉起服务" >> "$LOG_DIR/$(date '+%Y-%m-%d').log"
  exit 0
fi

# 1. 等待系统属性 sys.boot_completed=1
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 2
done

# 2. 等待用户 FBE (File-Based Encryption) 存储解密完成 (最多等待 90 秒)
wait_sec=0
while [ ! -d "/sdcard/Android" ] && [ $wait_sec -lt 90 ]; do
  sleep 2
  wait_sec=$(( wait_sec + 2 ))
done

sleep 3

# 3. 启动 CloudDrive2 核心服务与官方原生 housekeeping 父进程 (start 内部会先将旧日志备份为 backup.YYYY-MM-DD.log 再写入新日志)
export CD2_FROM_KSUD_ACTION=1
CD2_BOOT_MSG="[service.sh] 存储解密已就绪 (耗时 ${wait_sec}s)，正在拉起 CloudDrive2 服务..." "$CTL_SCRIPT" start
