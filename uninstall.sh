#!/system/bin/sh
# 模块卸载清理脚本
MODDIR="${0%/*}"
CTL_SCRIPT="$MODDIR/scripts/cd2_ctl.sh"
DATA_DIR="/data/adb/clouddrive"

# 停止主工作进程与 housekeeping 父进程并动态卸载所有关联 FUSE 挂载点
[ -x "$CTL_SCRIPT" ] && "$CTL_SCRIPT" stop 2>/dev/null

# 保留用户网盘登录凭证与 WebUI 挂载点配置 ($DATA_DIR/userdata)，仅清理临时与进程锁文件
rm -rf "/data/adb/clouddrive/tmp" "$DATA_DIR/clouddrive.pid" "$DATA_DIR/watchdog.pid" "$DATA_DIR/run"
