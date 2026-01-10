#!/bin/bash

# ==============================================
# Proxmox VE 一键自动配置脚本
# 功能：阿里云源 + 存储合并 + vGPU 直通 + 反虚拟化
# 作者：AI助手
# 日期：$(date +%Y-%m-%d)
# ==============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否以root运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi
}

# 备份原始文件
backup_files() {
    local backup_dir="/root/proxmox-backup-$(date +%Y%m%d_%H%M%S)"
    log_info "创建备份目录: $backup_dir"
    mkdir -p "$backup_dir"
    
    # 备份重要文件
    cp /etc/apt/sources.list "$backup_dir/" 2>/dev/null
    cp /etc/apt/sources.list.d/pve-enterprise.list "$backup_dir/" 2>/dev/null || true
    cp /etc/apt/sources.list.d/ceph.list "$backup_dir/" 2>/dev/null || true
    cp /etc/default/grub "$backup_dir/"
    cp /etc/modules "$backup_dir/" 2>/dev/null || true
    cp /usr/share/perl5/PVE/APLInfo.pm "$backup_dir/" 2>/dev/null || true
    
    log_success "备份完成到: $backup_dir"
}

# 步骤1：合并存储空间
merge_storage() {
    log_info "步骤1: 合并存储空间"
    
    # 检查是否存在 local-lvm
    if lvdisplay /dev/pve/data >/dev/null 2>&1; then
        log_warning "即将删除 local-lvm 数据卷，请确认！"
        read -p "是否继续？(输入 y 确认): " confirm
        if [[ "$confirm" != "y" ]]; then
            log_warning "跳过存储合并"
            return
        fi
        
        # 移除 local-lvm 数据卷
        lvremove -y /dev/pve/data
        if [ $? -eq 0 ]; then
            # 扩展 root 分区
            lvextend -rl +100%FREE /dev/pve/root
            log_success "存储空间合并完成"
            
            # 提示手动操作
            echo ""
            log_warning "请在 Proxmox Web 界面中执行以下操作："
            log_warning "1. 进入'数据中心' -> '存储'"
            log_warning "2. 选中 'local-lvm'，点击'移除'"
            log_warning "3. 选中 'local'，点击'编辑'，启用所有内容类型"
            log_warning "4. 重启所有虚拟机"
            echo ""
            read -p "按回车键继续..." dummy
        else
            log_error "存储合并失败"
        fi
    else
        log_warning "local-lvm 不存在，跳过合并"
    fi
}

# 步骤2：更换阿里云源
change_sources() {
    log_info "步骤2: 更换为阿里云源"
    
    # Debian 基础源
    cat > /etc/apt/sources.list << 'EOF'
# 阿里云 Debian 镜像源
deb https://mirrors.aliyun.com/debian/ bookworm main contrib non-free non-free-firmware
deb https://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free non-free-firmware
deb https://mirrors.aliyun.com/debian/ bookworm-backports main contrib non-free non-free-firmware
deb https://mirrors.aliyun.com/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
    
    # Proxmox VE 源（无订阅）
    cat > /etc/apt/sources.list.d/pve-no-subscription.list << 'EOF'
# 阿里云 Proxmox VE 镜像源
deb https://mirrors.aliyun.com/proxmox/debian bookworm pve-no-subscription
EOF
    
    # 移除企业源
    rm -f /etc/apt/sources.list.d/pve-enterprise.list
    
    # Ceph 源
    cat > /etc/apt/sources.list.d/ceph.list << 'EOF'
# 阿里云 Ceph 镜像源
deb https://mirrors.aliyun.com/proxmox/debian/ceph-quincy bookworm no-subscription
EOF
    
    # 修改 Proxmox 模板源
    cp /usr/share/perl5/PVE/APLInfo.pm /usr/share/perl5/PVE/APLInfo.pm.backup
    sed -i 's|http://download.proxmox.com|https://mirrors.aliyun.com/proxmox|g' /usr/share/perl5/PVE/APLInfo.pm
    systemctl restart pvedaemon.service
    
    # 更新软件包列表
    apt update
    if [ $? -eq 0 ]; then
        log_success "源更换完成"
    else
        log_error "源更新失败"
    fi
}

# 步骤3：配置硬件直通
setup_passthrough() {
    log_info "步骤3: 配置硬件直通"
    
    # 检查CPU类型
    local cpu_type="intel"
    if grep -qi "amd" /proc/cpuinfo; then
        cpu_type="amd"
    fi
    
    # 修改GRUB配置
    if [ "$cpu_type" = "intel" ]; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"/g' /etc/default/grub
    else
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"/g' /etc/default/grub
    fi
    
    # 询问是否需要ACS覆盖
    log_warning "PCIe ACS覆盖用于分离多口设备（如多口网卡、多GPU）"
    read -p "是否需要PCIe ACS覆盖？[y/N]: " acs_choice
    if [[ "$acs_choice" =~ ^[Yy]$ ]]; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&pcie_acs_override=downstream,multifunction /' /etc/default/grub
        log_info "已启用PCIe ACS覆盖"
    fi
    
    # 添加VFIO模块
    echo -e "vfio\nvfio_iommu_type1\nvfio_pci\nvfio_virqfd" >> /etc/modules
    
    # 创建黑名单配置（选择性）
    log_warning "显卡驱动黑名单会阻止宿主机使用这些显卡"
    echo "选择要直通的设备类型："
    echo "1) NVIDIA显卡"
    echo "2) AMD显卡"
    echo "3) Intel核显"
    echo "4) 声卡/音频设备"
    echo "5) 全部（慎选，可能导致宿主机无显示输出）"
    echo "0) 跳过黑名单配置"
    
    read -p "请输入选择（多个用逗号分隔，如1,3）: " device_choice
    
    cat > /etc/modprobe.d/vfio.conf << 'EOF'
# VFIO配置
options vfio_iommu_type1 allow_unsafe_interrupts=1
EOF
    
    cat > /etc/modprobe.d/blacklist-vfio.conf << 'EOF'
# 黑名单配置
EOF
    
    if [[ "$device_choice" =~ "1" ]] || [[ "$device_choice" =~ "5" ]]; then
        echo "blacklist nouveau" >> /etc/modprobe.d/blacklist-vfio.conf
        echo "blacklist nvidia" >> /etc/modprobe.d/blacklist-vfio.conf
        echo "blacklist nvidiafb" >> /etc/modprobe.d/blacklist-vfio.conf
    fi
    
    if [[ "$device_choice" =~ "2" ]] || [[ "$device_choice" =~ "5" ]]; then
        echo "blacklist radeon" >> /etc/modprobe.d/blacklist-vfio.conf
        echo "blacklist amdgpu" >> /etc/modprobe.d/blacklist-vfio.conf
    fi
    
    if [[ "$device_choice" =~ "3" ]] || [[ "$device_choice" =~ "5" ]]; then
        echo "blacklist i915" >> /etc/modprobe.d/blacklist-vfio.conf
    fi
    
    if [[ "$device_choice" =~ "4" ]] || [[ "$device_choice" =~ "5" ]]; then
        echo "blacklist snd_hda_intel" >> /etc/modprobe.d/blacklist-vfio.conf
        echo "blacklist snd_hda_codec_hdmi" >> /etc/modprobe.d/blacklist-vfio.conf
    fi
    
    # 更新系统配置
    update-grub
    update-initramfs -u -k all
    
    log_success "直通配置完成，需要重启生效"
}

# 步骤4：安装新内核和QEMU
install_kernel_qemu() {
    log_info "步骤4: 安装新内核和QEMU"
    
    # 更新系统
    apt update
    apt upgrade -y
    
    # 安装指定内核
    log_info "安装内核: proxmox-kernel-6.8.12-5-pve"
    apt install -y proxmox-kernel-6.8.12-5-pve
    
    # 安装指定QEMU版本
    log_info "安装QEMU: pve-qemu-kvm=9.0.2-4"
    apt install -y pve-qemu-kvm=9.0.2-4
    
    # 设置内核启动项
    log_info "设置内核启动顺序"
    proxmox-boot-tool kernel pin 6.8.12-5-pve
    
    log_success "内核和QEMU安装完成"
}

# 步骤5：配置vGPU解锁
setup_vgpu_unlock() {
    log_info "步骤5: 配置vGPU解锁"
    
    # 创建目录结构
    mkdir -p /etc/vgpu_unlock
    mkdir -p /etc/systemd/system/{nvidia-vgpud.service.d,nvidia-vgpu-mgr.service.d}
    mkdir -p /opt/vgpu_unlock-rs/target/release
    
    # 创建配置文件
    touch /etc/vgpu_unlock/profile_override.toml
    
    # 配置服务
    echo -e "[Service]\nEnvironment=LD_PRELOAD=/opt/vgpu_unlock-rs/target/release/libvgpu_unlock_rs.so" > /etc/systemd/system/nvidia-vgpud.service.d/vgpu_unlock.conf
    echo -e "[Service]\nEnvironment=LD_PRELOAD=/opt/vgpu_unlock-rs/target/release/libvgpu_unlock_rs.so" > /etc/systemd/system/nvidia-vgpu-mgr.service.d/vgpu_unlock.conf
    
    # 下载解锁库
    log_info "下载vGPU解锁库..."
    cd /opt/vgpu_unlock-rs/target/release
    wget -q --show-progress -O libvgpu_unlock_rs.so "https://yun.yangwenqing.com/NVIDIA/vGPU/NVIDIA/17.0/libvgpu_unlock_rs_only_17.0.so"
    
    if [ $? -eq 0 ]; then
        log_success "vGPU解锁配置完成"
    else
        log_error "vGPU解锁库下载失败"
    fi
}

# 步骤6：安装NVIDIA vGPU驱动
install_nvidia_driver() {
    log_info "步骤6: 安装NVIDIA vGPU驱动"
    
    # 检查是否要继续
    read -p "是否安装NVIDIA vGPU驱动？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_warning "跳过NVIDIA驱动安装"
        return
    fi
    
    # 安装依赖
    apt install -y build-essential dkms mdevctl pve-headers-$(uname -r)
    
    # 下载驱动
    log_info "下载NVIDIA vGPU驱动..."
    wget -q --show-progress "https://yun.yangwenqing.com/NVIDIA/vGPU/NVIDIA/17.0/NVIDIA-Linux-x86_64-550.54.10-vgpu-kvm-patched-kernel6.8-OA5500.run"
    
    if [ ! -f "NVIDIA-Linux-x86_64-550.54.10-vgpu-kvm-patched-kernel6.8-OA5500.run" ]; then
        log_error "驱动下载失败"
        return
    fi
    
    # 赋予执行权限
    chmod +x NVIDIA-Linux-x86_64-550.54.10-vgpu-kvm-patched-kernel6.8-OA5500.run
    
    # 安装驱动
    log_warning "开始安装NVIDIA驱动..."
    log_warning "安装过程中请仔细阅读提示信息！"
    echo ""
    log_info "重要提示："
    log_info "1. 如果提示'签名密钥'，选择'继续安装'"
    log_info "2. 如果提示'注册DKMS模块'，选择'是'"
    log_info "3. 如果提示'X配置'，选择'否'"
    echo ""
    
    ./NVIDIA-Linux-x86_64-550.54.10-vgpu-kvm-patched-kernel6.8-OA5500.run --kernel-source-path=/usr/src/linux-headers-$(uname -r) -m=kernel
    
    if [ $? -eq 0 ]; then
        log_success "NVIDIA驱动安装完成"
    else
        log_error "NVIDIA驱动安装失败"
    fi
}

# 步骤7：安装反虚拟化QEMU
install_anti_vm_qemu() {
    log_info "步骤7: 安装反虚拟化QEMU"
    
    # 检查是否要继续
    read -p "是否安装反虚拟化QEMU？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_warning "跳过反虚拟化QEMU安装"
        return
    fi
    
    # 创建目录
    mkdir -p /root/qemu-kvm9
    cd /root/qemu-kvm9
    
    # 下载反虚拟化包
    log_info "下载反虚拟化QEMU包..."
    wget -q --show-progress "https://yun.yangwenqing.com/Proxmox/Qemu%E5%8E%BB%E8%99%9A%E6%8B%9F%E5%8C%96/9.0.2-4/pve-qemu-kvm_9.0.2-4_amd64.deb"
    wget -q --show-progress "https://yun.yangwenqing.com/Proxmox/Qemu%E5%8E%BB%E8%99%9A%E6%8B%9F%E5%8C%96/9.0.2-4/pve-edk2-firmware-ovmf_4.2023.08-4_all_anti_detection20240830v5.0.deb"
    
    # 安装包
    dpkg -i pve-qemu-kvm_9.0.2-4_amd64.deb
    dpkg -i pve-edk2-firmware-ovmf_4.2023.08-4_all_anti_detection20240830v5.0.deb
    
    # 修复依赖
    apt --fix-broken install -y
    
    log_success "反虚拟化QEMU安装完成"
}

# 步骤8：配置虚拟机示例
setup_vm_example() {
    log_info "步骤8: 配置虚拟机反虚拟化参数"
    
    echo ""
    log_warning "以下是一个虚拟机反虚拟化配置示例："
    log_warning "添加到虚拟机配置文件（如 /etc/pve/qemu-server/100.conf）"
    echo ""
    cat << 'EOF'
args: -cpu 'host,family=6,model=7,stepping=2,model_id=Intel Core i9 14900 @ 4.90GHz,+kvm_pv_unhalt,+kvm_pv_eoi,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_reset,hv_vpindex,hv_runtime,hv_relaxed,kvm=off,hv_vendor_id=intel,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true,hypervisor=off' -smbios type=0 -smbios type=9 -smbios type=8 -smbios type=8
EOF
    echo ""
    log_info "配置完成后，需要重启虚拟机生效"
}

# 步骤9：显示vGPU配置示例
show_vgpu_example() {
    log_info "步骤9: vGPU配置示例"
    
    echo ""
    log_warning "vGPU配置文件示例 (/etc/vgpu_unlock/profile_override.toml)："
    echo ""
    cat << 'EOF'
[profile.nvidia-762]
num_displays = 1
display_width = 1920
display_height = 1080
max_pixels = 2073600
cuda_enabled = 1
frl_enabled = 0
vgpu_type = "NVS"
framebuffer = 1476395008  # 1.5G显存
pci_id = 0x17F010DE
pci_device_id = 0x17F0
EOF
    echo ""
    log_info "常用显存设置："
    log_info "1.5G显存: framebuffer = 1610612736"
    log_info "1G显存:   framebuffer = 1073741824"
    log_info "512M显存: framebuffer = 536870912"
    log_info "256M显存: framebuffer = 268435456"
}

# 最终检查和建议
final_check() {
    log_info "步骤10: 最终检查和建议"
    
    echo ""
    echo "=" * 60
    log_success "脚本执行完成！"
    echo "=" * 60
    echo ""
    
    log_warning "重要提醒："
    echo "1. 需要重启系统使所有配置生效"
    echo "2. 重启后运行以下命令检查："
    echo "   - nvidia-smi          # 检查NVIDIA驱动"
    echo "   - mdevctl types       # 检查vGPU类型"
    echo "   - dmesg | grep -i iommu  # 检查IOMMU"
    echo ""
    log_warning "后续操作："
    echo "1. 在Proxmox Web界面中配置虚拟机PCI设备"
    echo "2. 为虚拟机添加vGPU设备"
    echo "3. 安装虚拟机显卡驱动"
    echo ""
    
    read -p "是否立即重启系统？[y/N]: " reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        log_info "系统将在5秒后重启..."
        sleep 5
        reboot
    else
        log_info "请手动重启系统：reboot"
    fi
}

# 主菜单
main_menu() {
    clear
    echo "================================================"
    echo "   Proxmox VE 一键自动配置脚本"
    echo "================================================"
    echo ""
    echo "请选择要执行的操作："
    echo "1) 完整配置（推荐）"
    echo "2) 仅更换阿里云源"
    echo "3) 仅配置硬件直通"
    echo "4) 仅安装vGPU驱动"
    echo "5) 仅安装反虚拟化"
    echo "6) 自定义选择"
    echo "0) 退出"
    echo ""
    
    read -p "请输入选择 [0-6]: " main_choice
    
    case $main_choice in
        1)
            # 完整配置
            check_root
            backup_files
            merge_storage
            change_sources
            setup_passthrough
            install_kernel_qemu
            setup_vgpu_unlock
            install_nvidia_driver
            install_anti_vm_qemu
            setup_vm_example
            show_vgpu_example
            final_check
            ;;
        2)
            # 仅换源
            check_root
            backup_files
            change_sources
            log_success "阿里云源更换完成"
            ;;
        3)
            # 仅硬件直通
            check_root
            backup_files
            setup_passthrough
            log_success "硬件直通配置完成，需要重启"
            ;;
        4)
            # 仅vGPU驱动
            check_root
            backup_files
            setup_vgpu_unlock
            install_nvidia_driver
            log_success "vGPU驱动安装完成，需要重启"
            ;;
        5)
            # 仅反虚拟化
            check_root
            backup_files
            install_anti_vm_qemu
            setup_vm_example
            log_success "反虚拟化安装完成"
            ;;
        6)
            # 自定义选择
            custom_selection
            ;;
        0)
            log_info "退出脚本"
            exit 0
            ;;
        *)
            log_error "无效选择"
            exit 1
            ;;
    esac
}

# 自定义选择
custom_selection() {
    clear
    echo "================================================"
    echo "   自定义配置选项"
    echo "================================================"
    echo ""
    
    check_root
    backup_files
    
    echo "选择要执行的步骤："
    echo "1) 合并存储空间"
    echo "2) 更换阿里云源"
    echo "3) 配置硬件直通"
    echo "4) 安装新内核和QEMU"
    echo "5) 配置vGPU解锁"
    echo "6) 安装NVIDIA vGPU驱动"
    echo "7) 安装反虚拟化QEMU"
    echo "8) 显示配置示例"
    echo "0) 开始执行"
    echo ""
    
    selections=()
    while true; do
        read -p "选择步骤（输入序号，0开始执行）: " step
        if [ "$step" = "0" ]; then
            break
        elif [[ "$step" =~ ^[1-8]$ ]]; then
            if [[ ! " ${selections[@]} " =~ " $step " ]]; then
                selections+=($step)
                log_info "已选择步骤: $step"
            else
                log_warning "步骤 $step 已选择"
            fi
        else
            log_error "无效选择"
        fi
    done
    
    # 按顺序执行选择的步骤
    for step in $(echo "${selections[@]}" | tr ' ' '\n' | sort -n); do
        case $step in
            1) merge_storage ;;
            2) change_sources ;;
            3) setup_passthrough ;;
            4) install_kernel_qemu ;;
            5) setup_vgpu_unlock ;;
            6) install_nvidia_driver ;;
            7) install_anti_vm_qemu ;;
            8)
                setup_vm_example
                show_vgpu_example
                ;;
        esac
    done
    
    if [ ${#selections[@]} -gt 0 ]; then
        final_check
    else
        log_warning "未选择任何步骤"
    fi
}

# 脚本开始
main_menu