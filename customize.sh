#!/system/bin/sh
# CloudDrive2 多架构智能适配 (aarch64 / armv7 / x86_64) KSU / Magisk / APatch 模块安装定制脚本
SKIPUNZIP=1

ui_print "=================================================="
ui_print "  CloudDrive2 System Mount & Daemon"
ui_print "  智能多架构适配: aarch64 / armv7 / x86_64"
ui_print "  动态 GitHub 版本探测与国内加速镜像支持"
ui_print "=================================================="

# 1. 智能判定设备 CPU 架构 (aarch64 / armv7 / x86_64)
# 优先识别安装器环境 $ARCH (如 MuMu 等 PC 模拟器为 x64，即使 uname -m 伪装为 aarch64 也应使用原生 x86_64)
# 同时检测模拟器特征属性 (ro.dalvik.vm.isa.arm64 / abilist / cpuinfo)，避免 x86_64 模拟器误装 arm64 包
detect_arch() {
  local um abi isa cpu_vendor
  um="$(uname -m 2>/dev/null)"
  abi="$(getprop ro.product.cpu.abi 2>/dev/null) $(getprop ro.product.cpu.abilist 2>/dev/null) $(getprop ro.system.product.cpu.abilist 2>/dev/null)"
  isa="$(getprop ro.dalvik.vm.isa.arm64 2>/dev/null) $(getprop ro.dalvik.vm.isa.arm 2>/dev/null)"
  cpu_vendor="$(grep -iE 'GenuineIntel|AuthenticAMD|vendor_id.*(Intel|AMD)' /proc/cpuinfo 2>/dev/null)"

  # 1) 若 $ARCH 明确为 x64/x86_64/amd64，或检测到 PC 模拟器/x86 底层特征，直接采用原生 x86_64 架构
  case "$ARCH $um $abi $isa" in
    *x86_64*|*amd64*|*x64*)
      echo "x86_64"
      return
      ;;
  esac
  if [ -n "$cpu_vendor" ]; then
    echo "x86_64"
    return
  fi

  # 2) 检测 ARM64 (aarch64)
  case "$ARCH $um $abi" in
    *aarch64*|*arm64*)
      echo "aarch64"
      return
      ;;
  esac

  # 3) 检测 ARM 32位 (armv7)
  case "$ARCH $um $abi" in
    *armv7*|*armv8l*|*armeabi*|*arm*)
      echo "armv7"
      return
      ;;
  esac

  # 4) 兜底通过系统动态链接器判断
  if [ -e "/system/bin/linker64" ]; then
    echo "aarch64"
  elif [ -e "/system/bin/linker" ]; then
    echo "armv7"
  else
    echo "unsupported"
  fi
}

TARGET_ARCH="$(detect_arch)"
if [ "$TARGET_ARCH" = "unsupported" ]; then
  abort "! 架构不兼容: 当前设备架构为 [$ARCH / $(uname -m 2>/dev/null)]，CloudDrive2 仅支持 aarch64、armv7 和 x86_64!"
fi

if [ "$TARGET_ARCH" = "aarch64" ]; then
  ARCH_LABEL="ARM64 (aarch64)"
  LINKER_BIN="/system/bin/linker64"
  LIB_DIR_NAME="lib64"
elif [ "$TARGET_ARCH" = "armv7" ]; then
  ARCH_LABEL="ARM 32位 (armv7)"
  LINKER_BIN="/system/bin/linker"
  LIB_DIR_NAME="lib"
else
  ARCH_LABEL="x86_64 (amd64)"
  LINKER_BIN="/system/bin/linker64"
  LIB_DIR_NAME="lib64"
fi

ui_print "- 目标架构检测通过: $ARCH_LABEL (解释器: $LINKER_BIN)"

# 2. 识别 Root 框架环境 (KernelSU / APatch / Magisk)
if [ "$KSU" = "true" ]; then
  ui_print "- 检测到 KernelSU 环境 (KSU_VER=$KSU_VER, KSU_VER_CODE=$KSU_VER_CODE)"
elif [ "$APATCH" = "true" ]; then
  ui_print "- 检测到 APatch 环境 (APATCH_VER=$APATCH_VER)"
else
  ui_print "- 检测到 Magisk 环境 (MAGISK_VER=$MAGISK_VER, CODE=$MAGISK_VER_CODE)"
fi

# 3. 解压模块基础控制脚本与 WebUI (排除所有 tgz/apk 归档，防止无用解包)
ui_print "- 正在释放模块控制脚本与配置文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' '*.tgz' '*.apk' '*.APK' -d "$MODPATH" >&2

mkdir -p "$MODPATH/bin"
mkdir -p "$MODPATH/bin/wwwroot"
rm -rf "$MODPATH/wwwroot" "$MODPATH/lib64" "$MODPATH/lib" 2>/dev/null || true
mkdir -p "$MODPATH/scripts"

# 4. 智能选择与部署官方压缩包 (优先内置官方包，次选动态拉取最新版)
# 国内加速代理镜像池
PROXIES="https://ghproxy.net/ https://gh-proxy.com/ https://mirror.ghproxy.com/"

# 网络请求包装函数，优先使用国内加速代理，回退到官方直连
fetch_data() {
  local target_url="$1"
  local dest_path="$2"
  local mirror
  for mirror in $PROXIES ""; do
    local req_url="${mirror}${target_url}"
    if [ -n "$dest_path" ]; then
      if command -v curl >/dev/null 2>&1; then
        if curl -sL --connect-timeout 10 --max-time 180 --retry 2 "$req_url" -o "$dest_path" 2>/dev/null && [ -s "$dest_path" ]; then
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
        resp="$(curl -sL --connect-timeout 8 --max-time 15 "$req_url" 2>/dev/null)"
      elif command -v wget >/dev/null 2>&1; then
        resp="$(wget -q -T 8 -t 1 -O - "$req_url" 2>/dev/null)"
      fi
      if [ -n "$resp" ]; then
        printf "%s" "$resp"
        return 0
      fi
    fi
  done
  return 1
}

# 动态探测 GitHub 官方最新 Release 版本号 (避免硬编码 RELEASE_URL)
get_latest_release_tag() {
  local api_url="https://api.github.com/repos/cloud-fs/cloud-fs.github.io/releases/latest"
  local json
  json="$(fetch_data "$api_url")"
  local tag=""
  if [ -n "$json" ]; then
    tag=$(printf "%s" "$json" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4)
  fi
  [ -z "$tag" ] && tag="v1.1.3"
  echo "$tag"
}

# 检查是否存在已解包就绪的主程序与 WebUI (仅存放在 bin/ 目录下)
TGZ_UNPACKED=0
if [ -f "$MODPATH/bin/clouddrive" ] && [ -f "$MODPATH/bin/wwwroot/index.html" ]; then
  ui_print "- 检测到已预置解包完成的 clouddrive ($TARGET_ARCH) 与 bin/wwwroot 资源"
  rm -rf "$MODPATH/wwwroot" 2>/dev/null || true
  TGZ_UNPACKED=1
fi

# 若刷入包内内置官方通用 APK，仅在临时目录解压提取程序与前端资源，绝不保存 APK 至模块目录
if [ "$TGZ_UNPACKED" -eq 0 ]; then
  if [ -f "$ZIPFILE" ]; then
    APK_IN_ZIP=$(unzip -l "$ZIPFILE" 2>/dev/null | awk '{print $NF}' | grep -iE "\.apk$" | head -n 1)
    if [ -n "$APK_IN_ZIP" ]; then
      ui_print "- 发现刷入包内包含官方通用 APK ($APK_IN_ZIP)，正在提取核心与前端组件..."
      rm -rf "$TMPDIR/apk_unpacked" "$TMPDIR/apk_file"
      mkdir -p "$TMPDIR/apk_file"
      unzip -o "$ZIPFILE" "$APK_IN_ZIP" -d "$TMPDIR/apk_file" >&2
      APK_FILE="$TMPDIR/apk_file/$(basename "$APK_IN_ZIP")"
      if [ -f "$APK_FILE" ]; then
        APK_BIN_ENTRY="assets/bin/${TARGET_ARCH}/clouddrive"
        if unzip -l "$APK_FILE" 2>/dev/null | grep -q "$APK_BIN_ENTRY"; then
          ui_print "- 命中 APK 内置原生核心: $APK_BIN_ENTRY"
          mkdir -p "$MODPATH/bin" "$MODPATH/bin/wwwroot" "$TMPDIR/apk_unpacked"
          rm -rf "$MODPATH/wwwroot" 2>/dev/null || true
          unzip -o "$APK_FILE" "$APK_BIN_ENTRY" -d "$TMPDIR/apk_unpacked" >&2
          if [ -f "$TMPDIR/apk_unpacked/$APK_BIN_ENTRY" ]; then
            cp -af "$TMPDIR/apk_unpacked/$APK_BIN_ENTRY" "$MODPATH/bin/clouddrive"
            ui_print "- 成功从 APK 提取 $TARGET_ARCH 原生核心二进制程序"
            
            # 提取 WebUI assets/wwwroot.zip 并直接解压至 bin/wwwroot/ 实体目录，坚决杜绝软链接与冗余副本
            if unzip -l "$APK_FILE" 2>/dev/null | grep -q "assets/wwwroot.zip"; then
              ui_print "- 正在从 APK 提取 WebUI 静态资源并直接部署至 bin/wwwroot 实体目录..."
              unzip -o "$APK_FILE" "assets/wwwroot.zip" -d "$TMPDIR/apk_unpacked" >&2
              if [ -f "$TMPDIR/apk_unpacked/assets/wwwroot.zip" ]; then
                mkdir -p "$TMPDIR/apk_web" "$MODPATH/bin/wwwroot"
                unzip -o "$TMPDIR/apk_unpacked/assets/wwwroot.zip" -d "$TMPDIR/apk_web" >&2
                if [ -d "$TMPDIR/apk_web/wwwroot" ]; then
                  cp -af "$TMPDIR/apk_web/wwwroot/." "$MODPATH/bin/wwwroot/"
                elif [ -f "$TMPDIR/apk_web/index.html" ]; then
                  cp -af "$TMPDIR/apk_web/." "$MODPATH/bin/wwwroot/"
                fi
                rm -rf "$TMPDIR/apk_web"
              fi
            fi

            # 严密平铺与自检：严防出现嵌套 bin/wwwroot/wwwroot 导致路径失效
            if [ -d "$MODPATH/bin/wwwroot/wwwroot" ]; then
              cp -af "$MODPATH/bin/wwwroot/wwwroot/." "$MODPATH/bin/wwwroot/" 2>/dev/null || true
              rm -rf "$MODPATH/bin/wwwroot/wwwroot" 2>/dev/null || true
            fi

            # 彻底移除根目录 wwwroot 副本，仅保留 bin/wwwroot 唯一物理目录
            rm -rf "$MODPATH/wwwroot" 2>/dev/null || true

            if [ -f "$MODPATH/bin/wwwroot/index.html" ]; then
              WEB_FILES_CNT=$(find "$MODPATH/bin/wwwroot" -type f 2>/dev/null | wc -l)
              ui_print "- 官方 WebUI 静态资源已直接解压至 bin/wwwroot ($WEB_FILES_CNT 个实体文件)"
              TGZ_UNPACKED=1
            fi
          fi
        fi
      fi
      rm -rf "$TMPDIR/apk_file" "$TMPDIR/apk_unpacked"
    fi
  fi
fi

if [ "$TGZ_UNPACKED" -eq 0 ]; then
  # 优先扫描模块 ZIP 包内是否包含当前架构的官方压缩包
  BUILTIN_TGZ=$(unzip -l "$ZIPFILE" 2>/dev/null | awk '{print $NF}' | grep -E "^clouddrive-2-android-${TARGET_ARCH}-.*\.tgz$" | head -n 1)
  if [ -z "$BUILTIN_TGZ" ]; then
    BUILTIN_TGZ=$(unzip -l "$ZIPFILE" 2>/dev/null | awk '{print $NF}' | grep -E "clouddrive-2-android-${TARGET_ARCH}-.*\.tgz$" | head -n 1)
  fi

  if [ -n "$BUILTIN_TGZ" ]; then
    ui_print "- 发现模块内置官方压缩包: $BUILTIN_TGZ，正在解压部署..."
    unzip -o "$ZIPFILE" "$BUILTIN_TGZ" -d "$TMPDIR" >&2
    TARGET_TGZ="$TMPDIR/$(basename "$BUILTIN_TGZ")"
  else
    # 在线拉取模式：动态获取最新版下载链接并通过国内加速镜像拉取
    ui_print "- 模块未内置 $TARGET_ARCH 架构离线包，正在通过国内加速节点动态获取最新 Release..."
    LATEST_TAG="$(get_latest_release_tag)"
    VER_NUM="${LATEST_TAG#v}"
    ONLINE_TGZ_NAME="clouddrive-2-android-${TARGET_ARCH}-${VER_NUM}.tgz"
    ONLINE_URL="https://github.com/cloud-fs/cloud-fs.github.io/releases/download/${LATEST_TAG}/${ONLINE_TGZ_NAME}"
    ui_print "- 探测到最新官方版本: ${LATEST_TAG} (${ONLINE_TGZ_NAME})"
    ui_print "- 正在连接国内加速镜像下载: ${ONLINE_TGZ_NAME} ..."
    TARGET_TGZ="$TMPDIR/${ONLINE_TGZ_NAME}"
    if ! fetch_data "$ONLINE_URL" "$TARGET_TGZ"; then
      abort "! 自动下载 ${ONLINE_TGZ_NAME} 失败，请检查网络或在模块包中内置该架构离线包!"
    fi
  fi

  ui_print "- 正在解包官方组件到 bin 与 bin/wwwroot 实体目录..."
  tar -xzf "$TARGET_TGZ" -C "$TMPDIR"
  EXT_DIR=$(find "$TMPDIR" -maxdepth 1 -type d -name "clouddrive-2-android-*" | head -n 1)
  if [ -d "$EXT_DIR" ] && [ -f "$EXT_DIR/clouddrive" ]; then
    cp -af "$EXT_DIR/clouddrive" "$MODPATH/bin/clouddrive"
    mkdir -p "$MODPATH/bin/wwwroot"
    rm -rf "$MODPATH/wwwroot" 2>/dev/null || true
    cp -af "$EXT_DIR/wwwroot/." "$MODPATH/bin/wwwroot/"
    rm -rf "$EXT_DIR" "$TARGET_TGZ"
    ui_print "- 官方组件解包部署完成 ($TARGET_ARCH)"
  else
    abort "! 解压官方包失败，未在归档中找到 clouddrive 二进制文件!"
  fi
fi

# 记录当前安装的架构与版本信息供 WebUI 与控制器读取
echo "ARCH=$TARGET_ARCH" > "$MODPATH/arch.prop"
echo "LINKER=$LINKER_BIN" >> "$MODPATH/arch.prop"

# 严防护航：仅保留 bin/wwwroot 唯一物理目录，清理根目录残留与任何 APK 副本
rm -rf "$MODPATH/wwwroot" "$MODPATH"/*.apk "$MODPATH"/*.APK 2>/dev/null || true
[ -L "$MODPATH/bin/wwwroot" ] && rm -f "$MODPATH/bin/wwwroot" 2>/dev/null || true
mkdir -p "$MODPATH/bin/wwwroot"

# 5. 初始化持久化数据目录与日志目录 (临时文件统一使用系统 /data/local/tmp，不生成多余冗余目录)
DATA_DIR="/data/adb/clouddrive"
LOG_DIR="/data/adb/clouddrive/log"

ui_print "- 初始化持久化运行目录: $DATA_DIR"
mkdir -p "$DATA_DIR/userdata"
mkdir -p "$LOG_DIR"
rm -rf "$DATA_DIR/tmp" "$DATA_DIR/run/cd2_bin_version.cache" 2>/dev/null || true

# 6. 检查内核 /dev/fuse 支持情况
if [ -c "/dev/fuse" ]; then
  ui_print "- 内核 FUSE 设备检查通过: /dev/fuse 已就绪"
else
  ui_print "! 注意: 当前未检测到 /dev/fuse，将在开机 service.sh 阶段尝试加载 fuse 模块"
fi

# 7. 设置严格的二进制执行权限、属主 (UID:0/GID:2000) 与 SELinux 上下文
ui_print "- 正在设置二进制与脚本执行权限 (0755) 及 SELinux 标签 (u:object_r:system_file:s0)..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/scripts" 0 2000 0755 0755 u:object_r:system_file:s0
set_perm "$MODPATH/bin/clouddrive" 0 2000 0755 u:object_r:system_file:s0
set_perm "$MODPATH/service.sh" 0 0 0755 u:object_r:system_file:s0
set_perm "$MODPATH/action.sh" 0 0 0755 u:object_r:system_file:s0
set_perm "$MODPATH/uninstall.sh" 0 0 0755 u:object_r:system_file:s0

# 显式使用 chcon 强化 SELinux 安全上下文，防止 Android 13/14/15 拒绝执行
chcon -R u:object_r:system_file:s0 "$MODPATH/bin" 2>/dev/null
chcon -R u:object_r:system_file:s0 "$MODPATH/scripts" 2>/dev/null
chmod 0755 "$MODPATH/bin/clouddrive"
chmod 0755 "$MODPATH/scripts/"*.sh "$MODPATH/service.sh" "$MODPATH/action.sh" "$MODPATH/uninstall.sh"

ui_print "- 安装完成! 请重启设备以使模块生效"
ui_print "- WebUI 地址: http://127.0.0.1:19798"
ui_print "=================================================="
