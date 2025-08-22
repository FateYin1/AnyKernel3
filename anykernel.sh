### AnyKernel3 Ramdisk Mod Script
## KernelSU with SUSFS By Numbersf
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=KernelSU by KernelSU Developers
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=1
device.name1=
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### ZRAM配置核心函数（完整修复版）
zram_config() {
  ui_print " "
  ui_print "===== 开始ZRAM配置 ====="
  
  # 强制ROOT权限并前台执行，确保日志完整
  if [ "$(id -u)" -ne 0 ]; then
    ui_print "获取ROOT权限..."
    su -c "$(declare -f zram_core_logic); zram_core_logic"
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
      ui_print "ZRAM配置失败（权限问题）"
    fi
    return $exit_code
  else
    zram_core_logic
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
      ui_print "ZRAM配置失败"
    fi
    return $exit_code
  fi
}

# ZRAM核心逻辑（兼容16GB设备系统显示14GB的情况）
zram_core_logic() {
  # 1. 等待系统初始化
  ui_print "1/10 等待系统设备初始化..."
  sleep 5

  # 2. 获取物理内存（兼容不同设备格式）
  ui_print "2/10 检测物理内存..."
  MEM_TOTAL_KB=$(grep -i "memtotal" /proc/meminfo | awk '{print $2}')
  if [ -z "$MEM_TOTAL_KB" ] || [ "$MEM_TOTAL_KB" -eq 0 ]; then
      ui_print "警告：无法获取内存信息，使用默认8GB"
      MEM_TOTAL_KB=$((8 * 1024 * 1024))
  fi
  MEM_TOTAL_GB=$((MEM_TOTAL_KB / 1024 / 1024))
  ui_print "   系统显示内存: $MEM_TOTAL_GB GB"

  # 3. 计算ZRAM大小（兼容16GB设备显示14GB的情况）
  ui_print "3/10 计算ZRAM大小..."
  ZRAM_SIZE_MB=0
  MAX_ZRAM=0

  # 关键优化：16GB设备（含系统显示14-15GB的情况）强制4.5GB
  if [ $MEM_TOTAL_GB -eq 16 ] || ([ $MEM_TOTAL_GB -ge 14 ] && [ $MEM_TOTAL_GB -le 15 ]); then
      ui_print "   检测到16GB设备（系统显示$MEM_TOTAL_GB GB），应用16GB配置"
      ZRAM_SIZE_MB=4500  # 固定4.5GB
      MAX_ZRAM=8192
  elif [ $MEM_TOTAL_GB -ge 24 ]; then
      ZRAM_SIZE_MB=$(echo "scale=0; ($MEM_TOTAL_KB * 0.2) / 1024" | bc)
      MAX_ZRAM=10240
  else
      if [ $MEM_TOTAL_GB -le 4 ]; then
          ZRAM_SIZE_MB=$(echo "scale=0; ($MEM_TOTAL_KB * 0.8) / 1024" | bc)
          MAX_ZRAM=4096
      elif [ $MEM_TOTAL_GB -le 8 ]; then
          ZRAM_SIZE_MB=$(echo "scale=0; ($MEM_TOTAL_KB * 0.5) / 1024" | bc)
          MAX_ZRAM=6144
      elif [ $MEM_TOTAL_GB -le 13 ]; then  # 原15改为13，避免与16GB逻辑冲突
          ZRAM_SIZE_MB=$(echo "scale=0; ($MEM_TOTAL_KB * 0.3) / 1024" | bc)
          MAX_ZRAM=8192
      fi
  fi

  # 兜底设置（确保不为0）
  if [ $ZRAM_SIZE_MB -lt 512 ] || [ -z "$ZRAM_SIZE_MB" ]; then
      ZRAM_SIZE_MB=512
      ui_print "   兜底调整ZRAM大小为: 512 MB"
  elif [ $ZRAM_SIZE_MB -gt $MAX_ZRAM ]; then
      ZRAM_SIZE_MB=$MAX_ZRAM
      ui_print "   超出最大限制，调整为: $MAX_ZRAM MB"
  fi
  ui_print "   最终ZRAM大小: $ZRAM_SIZE_MB MB"

  # 4. 清理并创建设备
  ui_print "4/10 清理旧设备并创建新设备..."
  if [ -e /dev/block/zram0 ]; then
      ui_print "   发现旧设备，关闭并重置..."
      swapoff /dev/block/zram0 >/dev/null 2>&1
      if [ -e /sys/block/zram0/reset ]; then
          echo 1 > /sys/block/zram0/reset >/dev/null 2>&1
          sleep 1
      fi
  fi
  # 创建设备（带错误检测）
  if ! echo 1 > /sys/class/zram-control/hot_add; then
      ui_print "错误：创建ZRAM设备失败！"
      return 1
  fi
  sleep 2  # 等待设备节点生成
  if [ ! -e /dev/block/zram0 ]; then
      ui_print "错误：ZRAM设备节点未生成！"
      return 1
  fi
  ui_print "   ZRAM设备创建成功: /dev/block/zram0"

  # 5. 设置ZRAM容量（带容错）
  ui_print "5/10 设置ZRAM容量..."
  DISKSIZE_BYTES=$(echo "$ZRAM_SIZE_MB * 1024 * 1024" | bc)
  if ! echo $DISKSIZE_BYTES > /sys/block/zram0/disksize; then
      ui_print "   容量设置失败，尝试降级为4GB..."
      DISKSIZE_BYTES=$((4096 * 1024 * 1024))
      if ! echo $DISKSIZE_BYTES > /sys/block/zram0/disksize; then
          ui_print "错误：容量设置彻底失败！"
          return 1
      fi
      ZRAM_SIZE_MB=4096
  fi
  ACTUAL_DISK_SIZE=$(cat /sys/block/zram0/disksize)
  ui_print "   实际容量: $ACTUAL_DISK_SIZE 字节（约 $ZRAM_SIZE_MB MB）"

  # 6. 配置压缩算法
  ui_print "6/10 配置压缩算法..."
  echo "lz4" > /sys/block/zram0/comp_algorithm
  CURRENT_ALGO=$(cat /sys/block/zram0/comp_algorithm | awk '{print $1}')
  ui_print "   当前算法: $CURRENT_ALGO"

  # 7. 启用快速模式（如支持）
  ui_print "7/10 检查快速压缩模式..."
  if [ -e /sys/block/zram0/fast_mode ]; then
      echo 1 > /sys/block/zram0/fast_mode
      ui_print "   已启用LZ4快速模式"
  else
      ui_print "   不支持快速模式，跳过"
  fi

  # 8. 确认设备节点
  ui_print "8/10 确认设备节点..."
  if [ ! -b /dev/block/zram0 ]; then
      ui_print "   创建设备节点..."
      mknod /dev/block/zram0 b 252 0
  fi
  ui_print "   设备节点正常"

  # 9. 启用Swap
  ui_print "9/10 启用ZRAM Swap..."
  mkswap /dev/block/zram0 >/dev/null 2>&1
  if ! swapon /dev/block/zram0 -p 100; then
      ui_print "   默认swapon失败，尝试busybox版本..."
      if ! busybox swapon /dev/block/zram0 -p 100; then
          ui_print "错误：Swap启用失败！"
          return 1
      fi
  fi

  # 10. 最终验证
  ui_print "10/10 验证ZRAM状态..."
  if grep -q "zram0" /proc/swaps; then
      ui_print "   ZRAM配置成功！状态如下："
      cat /proc/swaps | grep zram0
      ui_print "===== ZRAM配置完成 ====="
      return 0
  else
      ui_print "错误：未检测到ZRAM生效！"
      return 1
  fi
}

### AnyKernel install
## boot shell variables
block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto
no_magisk_check=1

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

kernel_version=$(cat /proc/version | awk -F '-' '{print $1}' | awk '{print $3}')
case $kernel_version in
    4.1*) ksu_supported=true ;;
    5.1*) ksu_supported=true ;;
    6.1*) ksu_supported=true ;;
    6.6*) ksu_supported=true ;;
    *) ksu_supported=false ;;
esac

ui_print "  -> ksu_supported: $ksu_supported"
$ksu_supported || abort "  -> Non-GKI device, abort."

# 确定 root 方式
if [ -d /data/adb/magisk ] || [ -f /sbin/.magisk ]; then
    ui_print "检测到 Magisk，当前 Root 方式为 Magisk。在此情况下刷写 KSU 内核有很大可能会导致你的设备变砖，是否要继续？"
    ui_print "Magisk detected, current root method is Magisk. Flashing the KSU kernel in this case may brick your device, do you want to continue?"
    ui_print "请选择操作："
    ui_print "Please select an action:"
    ui_print "音量上键：退出脚本"
    ui_print "Volume up key: No"
    ui_print "音量下键：继续安装"
    ui_print "Volume down button: Yes"
    key_click=""
    while [ "$key_click" = "" ]; do
        key_click=$(getevent -qlc 1 | awk '{ print $3 }' | grep 'KEY_VOLUME')
        sleep 0.2
    done
    case "$key_click" in
        "KEY_VOLUMEUP") 
            ui_print "您选择了退出脚本"
            ui_print "Exiting…"
            exit 0
            ;;
        "KEY_VOLUMEDOWN")
            ui_print "You have chosen to continue the installation"
            ;;
        *)
            ui_print "未知按键，退出脚本"
            ui_print "Unknown key, exit script"
            exit 1
            ;;
    esac
fi

ui_print "开始安装内核..."
ui_print "功能如下："
ui_print "1、支持KPM"
ui_print "2、LZ4 V1.10.0版本（默认启用）"
ui_print "3、LZ4K"
ui_print "4、BBR"
ui_print "5、完美风驰驱动"
ui_print "6、单BOOT开机"
ui_print "7、ZRAM动态配置"
ui_print "作者：Fate 酷安:Fate007"
if [ -L "/dev/block/bootdevice/by-name/init_boot_a" ] || [ -L "/dev/block/by-name/init_boot_a" ]; then
    split_boot
    flash_boot
else
    dump_boot
    write_boot
fi

# 前台执行ZRAM配置，确保日志完整
zram_config

# 优先选择模块路径
if [ -f "$AKHOME/ksu_module_susfs_1.5.2+_Release.zip" ]; then
    MODULE_PATH="$AKHOME/ksu_module_susfs_1.5.2+_Release.zip"
    ui_print "  -> Installing SUSFS Module from Release"
elif [ -f "$AKHOME/ksu_module_susfs_1.5.2+_CI.zip" ]; then
    MODULE_PATH="$AKHOME/ksu_module_susfs_1.5.2+_CI.zip"
    ui_print "  -> Installing SUSFS Module from CI"
else
    ui_print "  -> No SUSFS Module found,Installing SUSFS Module from NON,Skipping Installation"
    MODULE_PATH=""
fi

# 安装 SUSFS 模块（可选）
if [ -n "$MODULE_PATH" ]; then
    KSUD_PATH="/data/adb/ksud"
    ui_print "安装 SUSFS 模块?"
    ui_print "音量上跳过安装；音量下安装模块"
    ui_print "Install susfs4ksu Module?"
    ui_print "Volume UP: NO；Volume DOWN: YES"

    key_click=""
    while [ "$key_click" = "" ]; do
        key_click=$(getevent -qlc 1 | awk '{ print $3 }' | grep 'KEY_VOLUME')
        sleep 0.2
    done
    case "$key_click" in
        "KEY_VOLUMEDOWN")
            if [ -f "$KSUD_PATH" ]; then
                ui_print "Installing SUSFS Module..."
                /data/adb/ksud module install "$MODULE_PATH"
                ui_print "Installation Complete"
            else
                ui_print "KSUD Not Found, Skipping Installation"
            fi
            ;;
        "KEY_VOLUMEUP")
            ui_print "Skipping SUSFS Module Installation"
            ;;
        *)
            ui_print "Unknown Key Input, Skipping Installation"
            ;;
    esac
fi
