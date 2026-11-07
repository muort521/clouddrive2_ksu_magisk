#!/system/bin/sh
# KernelSU / Magisk v28+ 模块卡片 [执行 / Action] 按钮触发脚本
MODDIR="${0%/*}"
CTL_SCRIPT="$MODDIR/scripts/cd2_ctl.sh"
DATA_DIR="/data/adb/clouddrive"
RUN_DIR="$DATA_DIR/run"
WEBUI_ACTION_FILE="$RUN_DIR/webui_action"

export CD2_FROM_KSUD_ACTION=1

# 若由 KSU WebUI 控制台通过 `ksud module action` 委派触发，则直接以原生 ksud Action 环境执行对应指令 (start / stop / restart)，不弹窗打开浏览器
if [ -f "$WEBUI_ACTION_FILE" ]; then
  REQ_ACT="$(cat "$WEBUI_ACTION_FILE" 2>/dev/null | tr -d ' \r\n')"
  rm -f "$WEBUI_ACTION_FILE" 2>/dev/null || true
  case "$REQ_ACT" in
    start|stop|restart)
      "$CTL_SCRIPT" "$REQ_ACT"
      exit $?
      ;;
  esac
fi

echo "=========================================="
echo "  CloudDrive2 KSU/Magisk 快捷控制台"
echo "=========================================="

# 调用 status 会自动执行 dedup_running_pids 清理因重复拉起而产生 os error 98 端口冲突的冗余实例
STATUS_OUT=$("$CTL_SCRIPT" status)
INFO_LINE=$(echo "$STATUS_OUT" | cut -d'|' -f2-5 | tr '|' ' ')
MOUNT_LINE=$(echo "$STATUS_OUT" | awk -F'MOUNTS=' '{print $2}' | cut -d'|' -f1)

LAN_IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
[ -z "$LAN_IP" ] && LAN_IP="127.0.0.1"

if echo "$STATUS_OUT" | grep -q "^RUNNING"; then
  echo "- 运行状态: 已在运行中 (已自动清理冗余实例与刷新状态卡片)"
  echo "- 进程详情: $INFO_LINE"
  echo "- 用户挂载: $MOUNT_LINE"
  echo "- 本地管理: http://127.0.0.1:19798"
  echo "- 局域网管理: http://${LAN_IP}:19798"
  echo "- 正在为您唤起浏览器打开 CloudDrive2 管理界面..."
  am start -a android.intent.action.VIEW -d "http://127.0.0.1:19798" >/dev/null 2>&1 || true
else
  echo "- 当前状态: 已停止，正在为您启动 CloudDrive2..."
  "$CTL_SCRIPT" start
  echo "- 启动完成! 正在打开 http://127.0.0.1:19798 ..."
  am start -a android.intent.action.VIEW -d "http://127.0.0.1:19798" >/dev/null 2>&1 || true
fi

echo "- 最新运行日志摘要:"
if [ -f "/data/adb/clouddrive/log/2026-11-04.log" ]; then
  tail -n 6 "/data/adb/clouddrive/log/2026-11-04.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\[[0-9;]*m//g; s/\[Om//g'
else
  echo "  (暂无日志)"
fi
echo "=========================================="
exit 0
