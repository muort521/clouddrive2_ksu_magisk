# Changelog

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

## v1.1.5-r12

- 初始版本
