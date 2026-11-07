# CloudDrive2 Pro (clouddrive2_ksu_magisk)

专为 Android Root 环境（**KernelSU / KernelSU Next / Magisk v20.4+ / APatch / MMRL**）打造的 **CloudDrive2** 系统级 FUSE3 挂载模块。

- **默认 WebUI 端口**：`http://127.0.0.1:19798`
- **数据持久化目录**：`/data/adb/clouddrive`
- **官方二进制App发布页**：<https://github.com/cloud-fs/cloud-fs.github.io/releases>

---

## ✨ 核心特性

1. **多架构智能识别 (`aarch64` / `armv7` / `x86_64`)**
   - 自动识别设备原生 CPU 架构（含 PC 模拟器 `x86_64` 兼容层识别），匹配对应的 `/system/bin/linker64` 或 `/system/bin/linker` 及 Bionic 动态库路径。
   - 刷入时优先使用模块内置的 `bin/clouddrive` 或 `clouddrive-2-android-<arch>-*.tgz` 官方归档；若未内置则动态查询 [CloudDrive2 官方 GitHub Releases (`https://github.com/cloud-fs/cloud-fs.github.io/releases`)](https://github.com/cloud-fs/cloud-fs.github.io/releases) 最新版本并通过国内加速代理（`ghproxy.net` / `gh-proxy.com` / `mirror.ghproxy.com`）自动拉取。
2. **专属 0ms 秒开 WebUI 控制台 (`webroot/index.html`)**
   - 首帧渲染与 Shell 桥接解耦，打开控制台零白屏。
   - 智能显示 **启动 / 平滑重启 / 停止** 按钮、**开机自启** 开关与 **打开 CloudDrive2 管理界面** 入口。
   - 支持 **浅色 / 深色 / 跟随系统** 三态主题切换。
3. **全局命名空间 FUSE3 挂载与读写权限穿透**
   - 通过 `nsenter -t 1 -m` 进入全局 Mount Namespace，自动配置 `/etc/fuse.conf` (`user_allow_other`)。
   - 自动将 `/storage/emulated/0/...` 下的网盘挂载点穿透同步至 `/mnt/runtime/write`、`/mnt/runtime/read`、`/mnt/runtime/default` 与 `/data/media/0`，解决 MT 管理器等应用无法向挂载网盘写入或删除文件（`EACCES: Permission denied`）的问题。

---

## 🛠️ 常用维护命令

在 Root 终端或 `adb shell su -c` 下可执行：

```bash
# 查看运行状态、PID、架构、版本、自启状态与挂载点
sh /data/adb/modules/clouddrive2_ksu_magisk/scripts/cd2_ctl.sh status

# 启动 / 停止 / 平滑重启服务
sh /data/adb/modules/clouddrive2_ksu_magisk/scripts/cd2_ctl.sh start
sh /data/adb/modules/clouddrive2_ksu_magisk/scripts/cd2_ctl.sh stop
sh /data/adb/modules/clouddrive2_ksu_magisk/scripts/cd2_ctl.sh restart

# 检查模块自身更新 (updateJson)
sh /data/adb/modules/clouddrive2_ksu_magisk/scripts/cd2_ctl.sh check-module-update

# 开启 / 关闭开机自启
sh /data/adb/modules/clouddrive2_ksu_magisk/scripts/cd2_ctl.sh autostart-enable
sh /data/adb/modules/clouddrive2_ksu_magisk/scripts/cd2_ctl.sh autostart-disable
```

---

## 📂 数据与日志路径

- **模块安装目录**：`/data/adb/modules/clouddrive2_ksu_magisk`
- **持久化配置与账号数据目录**：`/data/adb/clouddrive/userdata`（卸载模块默认保留）
- **运行日志路径**：`/data/adb/clouddrive/log/2026-11-04.log`
- **官方版本发布页**：<https://github.com/cloud-fs/cloud-fs.github.io/releases>
