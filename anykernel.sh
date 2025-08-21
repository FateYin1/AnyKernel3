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

### ZRAM配置核心函数（默认LZ4，不自动切换ZSTD）
zram_config() {
  ui_print " "
  ui_print "===== 配置ZRAM ====="
  
  # 等待系统初始化完成
  sleep 5

  # 1. 获取物理内存总大小（单位：KB）
  MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  if [ -z "$MEM_TOTAL_KB" ]; then
      ui_print "警告：无法获取物理内存，使用默认8GB配置"
      MEM_TOTAL_KB=$((8 * 1024 * 1024))  # 8GB默认值
  fi

  # 2. 计算内存大小（GB）
  MEM_TOTAL_GB=$((MEM_TOTAL_KB / 1024 / 1024))
  ui_print "检测到物理内存: $MEM_TOTAL_GB GB"

  # 3. 动态计算ZRAM大小（针对16GB/24GB优化）
  ZRAM_SIZE_MB=0
  MAX_ZRAM=0

  if [ $MEM_TOTAL_GB -eq 16 ]; then
      # 16GB设备：固定4.5GB（28%）
      ZRAM_SIZE_MB=4500
      MAX_ZRAM=8192
  elif [ $MEM_TOTAL_GB -ge 24 ]; then
      # 24GB及以上：20%比例
      ZRAM_SIZE_MB=$(echo "scale=0; ($MEM_TOTAL_KB * 0.2) / 1024" | bc)
      MAX_ZRAM=10240
  else
      # 其他内存大小的阶梯配置
      if [ $MEM_TOTAL_GB -le 4 ]; then
          ZRAM_SIZE_MB=$(echo "scale=0; ($MEM_TOTAL_KB * 0.8) / 1024" | bc)
          MAX_ZRAM=4096
      elif [ $MEM_TOTAL_GB -le 8 ]; then
          ZRAM_SIZE_MB=$(echo "scale=0; ($MEM_TOTAL_KB * 0.5) / 1024" | bc)
          MAX_ZRAM=6144
      elif [ $MEM_TOTAL_GB -le 15 ]; then
          ZRAM_SIZE_MB=$(echo "scale=0; ($MEM_TOTAL_KB * 0.3) / 1024" | bc)
          MAX_ZRAM=8192
      fi
  fi

  # 兜底设置（确保合理范围）
  if [ $ZRAM_SIZE_MB -lt 512 ]; then
      ZRAM_SIZE_MB=512
  elif [ $ZRAM_SIZE_MB -gt $MAX_ZRAM ]; then
      ZRAM_SIZE_MB=$MAX_ZRAM
  fi

  ui_print "设置ZRAM大小: $ZRAM_SIZE_MB MB"

  # 4. 创建设备（如不存在）
  if [ ! -e /dev/block/zram0 ]; then
      ui_print "创建设备: /dev/block/zram0"
      echo 1 > /sys/class/zram-control/hot_add
      sleep 1
  fi

  # 5. 配置ZRAM参数（强制默认LZ4）
  echo $((ZRAM_SIZE_MB * 1024 * 1024)) > /sys/block/zram0/disksize
  echo "lz4" > /sys/block/zram0/comp_algorithm  # 明确默认使用LZ4
  ui_print "默认压缩算法: LZ4（未启用ZSTD）"

  # 6. 启用LZ4快速模式（支持的内核）
  if [ -e /sys/block/zram0/fast_mode ]; then
      echo 1 > /sys/block/zram0/fast_mode
      ui_print "已启用LZ4快速压缩模式"
  fi

  # 7. 创建设备节点（兼容处理）
  if [ ! -b /dev/block/zram0 ]; then
      mknod /dev/block/zram0 b 252 0
  fi

  # 8. 启用swap（高优先级）
  mkswap /dev/block/zram0 >/dev/null 2>&1
  swapon /dev/block/zram0 -p 100
  ui_print "已启用ZRAM Swap（优先级100）"

  # 9. 优化系统参数
  echo 10 > /proc/sys/vm/swappiness
  echo 1 > /proc/sys/vm/swapiness_anon
  echo 0 > /proc/sys/vm/swapiness_file
  ui_print "已优化内存交换参数"

  # 10. 仅显示ZSTD手动切换说明（不自动切换）
  ui_print "如需切换至ZSTD算法（手动操作）:"
  ui_print "  1. 执行: swapoff /dev/block/zram0"
  ui_print "  2. 执行: echo zstd > /sys/block/zram0/comp_algorithm"
  ui_print "  3. 执行: swapon /dev/block/zram0 -p 100"
  ui_print "===================="
  ui_print " "
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
ui_print "7、ZRAM动态配置（默认LZ4）"  # 明确标注默认算法
ui_print "作者：Fate 酷安:Fate007"
if [ -L "/dev/block/bootdevice/by-name/init_boot_a" ] || [ -L "/dev/block/by-name/init_boot_a" ]; then
    split_boot
    flash_boot
else
    dump_boot
    write_boot
fi

# 调用ZRAM配置（内核安装后执行，默认LZ4）
zram_config &

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
