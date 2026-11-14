# Changelog

## v1.1.7-r15

- 更新CloudDrive2核心(webui)至-1.2.0-beta
- 官方1.2.0-beta详情：<https://github.com/cloud-fs/cloud-fs.github.io/releases/tag/v1.2.0-beta>

## v1.1.6-r14

- WebUI 控制台操作区重构："打开 CloudDrive2 管理界面"拆分为**系统浏览器打开**（`am start` 调起）与**当前界面直入**（WebView 内跳转）两个并排按钮，均保留启动前状态检测逻辑
- 底部快捷链接行改为两行地址栏：**本机地址** `http://127.0.0.1:19798` 与**局域网地址**（从 `status` 的 `LAN_IP=` 实时读取），各带独立"复制"按钮；长地址自动省略，悬停可查看完整地址
- 端口号不再写死 19798，改为实时读取 `status` 输出的 `PORT=`；局域网 IP 解析到 `127.0.0.1`/`0.0.0.0` 时显示"未检测到局域网 IP"，复制按钮给出友好提示
- 复制功能增加 `execCommand` 兜底（兼容不支持 `navigator.clipboard` 的 WebView），成功后弹出"已复制本机地址/局域网地址"提示
- 状态横幅支持换行、按钮组与地址栏 `nowrap` 处理，修复 360/390px 窄屏下文字折行、开关遮挡等问题
- `cd2_ctl.sh` 模块自检兜底版本号与 `module.prop` 对齐（`get_module_version` / `get_current_version_code` 兜底值统一为 `v1.1.6-r14` / `11614`，原为 r12/11512 历史遗留）

## v1.1.5-r13

- 按 KernelSU 官方文档适配模块安装流程（`update-binary` 支持无 Magisk 的 KSU/APatch 环境）
- `action.sh` 去除自我 re-exec，避免 KSU 下 Action 重复触发
- `cd2_ctl.sh` 去除 `exec nsenter` 自我重入，改为仅检测并记录
- `cd2_ctl.sh` busybox 探测改为 `ksud`/`apd` 优先
- `PATH` 导出改为按目录存在性探测，不再写死
- `module.prop` 新增 `updateJson=`，接入管理器检查更新
- `sepolicy.rule` 去除 Magisk 专有 `magisk` domain，增加 `ksu` domain
- `customize.sh` 修正脚本属主为 `0 0`，支持模块内自带 busybox
- `service.sh` 为 `sys.boot_completed` 等待增加超时
