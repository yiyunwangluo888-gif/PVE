#!/bin/bash
# Proxmox VE GPU直通一键配置脚本（普通直通版）
# 功能：整块GPU直通给单个虚拟机
# 使用方法：curl -sSL https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/pve-gpu-passthrough.sh | bash
# 或：wget -qO- https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/pve-gpu-passthrough.sh | bash

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP $1]${NC} $2"; }

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 sudo 或以 root 用户运行此脚本！"
        exit 1
    fi
}

# 检查是否为Proxmox VE
check_pve() {
    if ! command -v pveversion &> /dev/null; then
        log_error "此脚本仅适用于 Proxmox VE 系统！"
        exit 1
    fi
}

# 显示欢迎信息
show_welcome() {
    cat << "EOF"
╔══════════════════════════════════════════════════════════╗
║      Proxmox VE GPU直通一键配置脚本（普通直通版）        ║
║                    v1.0 - 整卡直通                       ║
║               联系方式：qq3118552009                     ║
╠══════════════════════════════════════════════════════════╣
║ 功能特点：                                               ║
║ ✓ 配置国内软件源镜像加速                                 ║
║ ✓ 自动配置IOMMU和VFIO                                    ║
║ ✓ 黑名单冲突的显卡驱动                                   ║
║ ✓ 安装最新稳定版内核                                     ║
║ ✓ 无需vGPU解锁/无需特殊驱动                              ║
║                                                          ║
║ 适用场景：                                               ║
║ • 整块GPU直通给单个虚拟机                                ║
║ • 游戏虚拟机/深度学习/3D渲染                             ║
║ • NVIDIA/AMD显卡都支持                                   ║
╚══════════════════════════════════════════════════════════╝
EOF
}

# 显示警告并确认
confirm_execution() {
    log_warn "⚠️  警告：此脚本将执行以下操作："
    echo "1. 修改系统软件源配置"
    echo "2. 修改GRUB引导参数（启用IOMMU）"
    echo "3. 配置VFIO驱动和模块黑名单"
    echo "4. 需要重启系统"
    echo ""
    log_info "请确认您要直通的GPU型号："
    echo "NVIDIA显卡：执行 lspci | grep -i nvidia"
    echo "AMD显卡：执行 lspci | grep -i amd"
    echo ""
    read -p "是否继续执行？(y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "用户取消执行"
        exit 0
    fi
}

# 步骤1：配置系统源
configure_sources() {
    log_step "1" "配置系统软件源为国内镜像"
    
    # 备份原源文件
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
    fi
    
    if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
        cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak
    fi
    
    # 配置Debian源（清华镜像）
    cat > /etc/apt/sources.list << 'EOF'
# 清华大学Debian镜像源
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

    # 配置PVE非订阅源
    cat > /etc/apt/sources.list.d/pve-no-subscription.list << 'EOF'
# 清华大学Proxmox镜像源
deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian bookworm pve-no-subscription
EOF

    log_info "软件源配置完成"
}

# 步骤2：更新系统
update_system() {
    log_step "2" "更新系统软件包"
    
    apt update
    apt upgrade -y
    apt autoremove -y
    
    log_info "系统更新完成"
}

# 步骤3：检测并配置IOMMU
configure_iommu() {
    log_step "3" "检测CPU类型并配置IOMMU"
    
    # 检测CPU类型
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        IOMMU_PARAMS="intel_iommu=on iommu=pt"
        log_info "检测到 Intel CPU，启用 Intel IOMMU"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        IOMMU_PARAMS="amd_iommu=on iommu=pt"
        log_info "检测到 AMD CPU，启用 AMD IOMMU"
    else
        log_error "无法识别的CPU类型"
        exit 1
    fi
    
    # 获取当前GRUB参数
    CURRENT_GRUB=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | cut -d'"' -f2)
    
    # 检查是否已包含IOMMU参数
    if echo "$CURRENT_GRUB" | grep -q "iommu="; then
        log_info "GRUB已包含IOMMU参数，跳过配置"
    else
        # 添加IOMMU参数到GRUB
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $IOMMU_PARAMS\"/g" /etc/default/grub
        log_info "已添加IOMMU参数到GRUB"
    fi
    
    # 添加PCIe ACS覆盖（解决IOMMU分组问题）
    if ! echo "$CURRENT_GRUB" | grep -q "pcie_acs_override"; then
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 pcie_acs_override=downstream,multifunction\"/g" /etc/default/grub
        log_info "已添加PCIe ACS覆盖参数"
    fi
}

# 步骤4：配置VFIO驱动
configure_vfio() {
    log_step "4" "配置VFIO驱动"
    
    # 添加VFIO模块到自动加载
    if ! grep -q "^vfio$" /etc/modules; then
        echo -e "\n# VFIO for GPU Passthrough" >> /etc/modules
        echo "vfio" >> /etc/modules
        echo "vfio_iommu_type1" >> /etc/modules
        echo "vfio_pci" >> /etc/modules
        echo "vfio_virqfd" >> /etc/modules
        log_info "VFIO模块已添加到 /etc/modules"
    fi
    
    # 检测显卡类型并配置黑名单
    detect_and_blacklist_gpu
}

# 检测显卡类型并配置黑名单
detect_and_blacklist_gpu() {
    log_info "检测系统中的显卡..."
    
    # 检测NVIDIA显卡
    if lspci | grep -qi "NVIDIA"; then
        log_info "检测到 NVIDIA 显卡"
        BLACKLIST_CONF="/etc/modprobe.d/blacklist-nvidia.conf"
        
        cat > $BLACKLIST_CONF << 'EOF'
# 黑名单NVIDIA驱动以避免冲突
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
blacklist nvidia_modeset
EOF
        log_info "已创建NVIDIA驱动黑名单"
        
    # 检测AMD显卡
    elif lspci | grep -qi "AMD\|ATI\|Radeon"; then
        log_info "检测到 AMD 显卡"
        BLACKLIST_CONF="/etc/modprobe.d/blacklist-amd.conf"
        
        cat > $BLACKLIST_CONF << 'EOF'
# 黑名单AMD驱动以避免冲突
blacklist radeon
blacklist amdgpu
EOF
        log_info "已创建AMD驱动黑名单"
    else
        log_warn "未检测到常见显卡，使用通用黑名单"
        BLACKLIST_CONF="/etc/modprobe.d/blacklist-gpu.conf"
        
        cat > $BLACKLIST_CONF << 'EOF'
# 通用显卡驱动黑名单
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist radeon
blacklist amdgpu
blacklist snd_hda_intel
EOF
    fi
    
    # 创建VFIO配置
    VFIO_CONF="/etc/modprobe.d/vfio.conf"
    
    cat > $VFIO_CONF << 'EOF'
# VFIO配置
options vfio_iommu_type1 allow_unsafe_interrupts=1
EOF
    
    log_info "VFIO配置完成"
}

# 步骤5：获取GPU PCI ID用于VFIO绑定
get_gpu_pci_ids() {
    log_step "5" "检测GPU的PCI ID用于直通"
    
    log_info "正在检测系统中的GPU..."
    
    # 显示所有GPU设备
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "检测到的GPU设备列表："
    echo "═══════════════════════════════════════════════════════"
    lspci | grep -E "VGA|3D|Display" | while read line; do
        PCI_ID=$(echo $line | cut -d' ' -f1)
        DEVICE_NAME=$(echo $line | cut -d' ' -f2-)
        echo "PCI ID: $PCI_ID - $DEVICE_NAME"
    done
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    # 询问用户选择要直通的GPU
    read -p "请输入要直通的GPU的PCI ID（如 01:00.0）： " GPU_PCI_ID
    
    if [[ -z "$GPU_PCI_ID" ]]; then
        log_warn "未指定PCI ID，跳过VFIO绑定配置"
        return
    fi
    
    # 获取供应商和设备ID
    if command -v lspci &> /dev/null; then
        VENDOR_DEVICE=$(lspci -n -s $GPU_PCI_ID | cut -d' ' -f3)
        if [[ ! -z "$VENDOR_DEVICE" ]]; then
            # 添加到VFIO配置
            echo "options vfio-pci ids=$VENDOR_DEVICE" >> /etc/modprobe.d/vfio.conf
            log_info "已将GPU $GPU_PCI_ID ($VENDOR_DEVICE) 添加到VFIO绑定"
            
            # 也添加到内核参数（可选）
            CURRENT_GRUB=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub | cut -d'"' -f2)
            if ! echo "$CURRENT_GRUB" | grep -q "vfio-pci.ids"; then
                sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 vfio-pci.ids=$VENDOR_DEVICE\"/g" /etc/default/grub
                log_info "已将GPU ID添加到内核参数"
            fi
        fi
    fi
}

# 步骤6：安装必要工具
install_tools() {
    log_step "6" "安装必要的工具"
    
    apt install -y \
        hwloc \
        cpu-checker \
        pciutils \
        lsb-release \
        sysfsutils
    
    log_info "工具安装完成"
}

# 步骤7：更新引导配置
update_boot_config() {
    log_step "7" "更新系统引导配置"
    
    log_info "更新GRUB引导..."
    if update-grub; then
        log_info "GRUB更新成功"
    else
        log_error "GRUB更新失败"
        exit 1
    fi
    
    log_info "更新initramfs..."
    if update-initramfs -u -k all; then
        log_info "initramfs更新成功"
    else
        log_error "initramfs更新失败"
        exit 1
    fi
    
    log_info "引导配置更新完成"
}

# 步骤8：显示验证信息
show_verification_info() {
    log_step "8" "验证配置信息"
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "配置完成！请验证以下信息："
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    # 显示IOMMU状态
    echo "1. IOMMU是否启用："
    if dmesg | grep -q "IOMMU"; then
        echo "   ✓ IOMMU已检测到"
    else
        echo "   ✗ IOMMU未检测到，请检查BIOS设置"
    fi
    
    # 显示IOMMU分组
    echo ""
    echo "2. IOMMU分组信息："
    echo "   运行以下命令查看分组："
    echo "   bash -c \"for d in /sys/kernel/iommu_groups/*/devices/*; do n=\${d#*/iommu_groups/*}; n=\${n%%/*}; printf 'IOMMU组 %s ' \\\$n; lspci -nns \\\${d##*/}; done\""
    
    # 显示GPU信息
    echo ""
    echo "3. GPU当前状态："
    lspci | grep -E "VGA|3D|Display" | head -5
    
    # 显示下一步操作
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "下一步操作："
    echo "═══════════════════════════════════════════════════════"
    echo "1. 重启系统以应用所有更改："
    echo "   reboot"
    echo ""
    echo "2. 重启后验证："
    echo "   # 检查IOMMU"
    echo "   dmesg | grep -i iommu"
    echo ""
    echo "   # 检查VFIO驱动"
    echo "   lsmod | grep vfio"
    echo ""
    echo "3. 在Proxmox Web界面配置直通："
    echo "   a. 创建或编辑虚拟机"
    echo "   b. 添加PCI设备"
    echo "   c. 选择您的GPU设备"
    echo "   d. 勾选'所有功能'和'PCI-Express'"
    echo ""
    echo "4. 常见问题："
    echo "   • 如果虚拟机无法启动，检查IOMMU分组"
    echo "   • 确保BIOS中已启用VT-d/AMD-Vi"
    echo "   • 某些主板需要ACS补丁"
    echo "═══════════════════════════════════════════════════════"
}

# 步骤9：询问是否重启
ask_for_reboot() {
    echo ""
    read -p "是否立即重启系统以应用配置？(y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "系统将在5秒后重启..."
        sleep 5
        reboot
    else
        log_info "请记得手动重启系统以应用所有更改"
        log_info "重启后，GPU直通配置才会生效"
    fi
}

# 错误处理
error_handler() {
    log_error "脚本执行出错！"
    log_error "请检查："
    log_error "1. 网络连接是否正常"
    log_error "2. 系统是否为Proxmox VE"
    log_error "3. 查看详细日志：tail -f /var/log/syslog"
    log_error "4. 可以手动恢复备份："
    log_error "   cp /etc/apt/sources.list.bak /etc/apt/sources.list"
    log_error "   cp /etc/apt/sources.list.d/pve-enterprise.list.bak /etc/apt/sources.list.d/pve-enterprise.list"
    exit 1
}

# 显示硬件检测信息
show_hardware_info() {
    log_info "硬件检测结果："
    echo "═══════════════════════════════════════════════════════"
    
    # CPU信息
    echo "CPU型号: $(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)"
    echo "CPU供应商: $(grep "vendor_id" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)"
    
    # 内存信息
    echo "内存总量: $(free -h | grep Mem | awk '{print $2}')"
    
    # 显卡信息
    echo "显卡设备:"
    lspci | grep -E "VGA|3D|Display" | while read line; do
        echo "  - $line"
    done
    
    echo "═══════════════════════════════════════════════════════"
    echo ""
}

# 主执行流程
main() {
    trap error_handler ERR
    
    # 显示欢迎信息
    show_welcome
    
    # 检查环境和确认
    check_root
    check_pve
    show_hardware_info
    confirm_execution
    
    # 执行所有配置步骤
    configure_sources
    update_system
    configure_iommu
    configure_vfio
    get_gpu_pci_ids
    install_tools
    update_boot_config
    
    # 显示验证信息和询问重启
    show_verification_info
    ask_for_reboot
    
    log_info "脚本执行完成！"
}

# 执行主函数
main "$@"