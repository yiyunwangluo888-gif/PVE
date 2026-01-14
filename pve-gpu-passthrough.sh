#!/bin/bash
# ============================================================================
# PVE GPU直通完整配置脚本 v4.0
# 功能：一键配置GPU直通 + 反虚拟化检测
# 作者：基于DeepSeek讨论总结
# 使用方法：bash pve-gpu-passthrough-full.sh
# 或：curl -sSL https://your-url.com/pve-gpu-passthrough-full.sh | bash
# ============================================================================

set -e  # 遇到错误立即退出

# ============================================================================
# 1. 颜色定义（用于终端输出）
# ============================================================================
RED='\033[0;31m'      # 错误信息
GREEN='\033[0;32m'    # 成功信息
YELLOW='\033[1;33m'   # 警告信息
BLUE='\033[0;34m'     # 步骤信息
PURPLE='\033[0;35m'   # 提示信息
CYAN='\033[0;36m'     # 说明信息
NC='\033[0m'          # 重置颜色

# ============================================================================
# 2. 日志输出函数
# ============================================================================
log_info() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[→]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_input() {
    echo -e "${PURPLE}[?]${NC} $1"
}

log_debug() {
    echo -e "${CYAN}[#]${NC} $1"
}

# ============================================================================
# 3. 环境检查函数
# ============================================================================
check_environment() {
    log_step "检查系统环境..."
    
    # 检查是否以root运行
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 sudo 或以 root 用户运行此脚本！"
        exit 1
    fi
    
    # 检查是否为Proxmox VE系统
    if ! command -v pveversion &> /dev/null; then
        log_error "此脚本仅适用于 Proxmox VE 系统！"
        log_error "检测到非PVE系统，请确认您正在运行Proxmox VE"
        exit 1
    fi
    
    # 显示系统信息
    log_info "系统检测通过："
    log_debug "PVE版本: $(pveversion | grep pve-manager)"
    log_debug "内核版本: $(uname -r)"
    log_debug "系统时间: $(date)"
}

# ============================================================================
# 4. 硬件检测函数
# ============================================================================
detect_hardware() {
    log_step "检测硬件信息..."
    
    echo "══════════════════════════════════════════════════"
    echo "                  硬件信息报告"
    echo "══════════════════════════════════════════════════"
    
    # CPU信息
    CPU_VENDOR=$(grep "vendor_id" /proc/cpuinfo | head -1 | awk '{print $3}')
    CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
    CPU_FAMILY=$(grep "cpu family" /proc/cpuinfo | head -1 | awk '{print $3}')
    CPU_MODEL_ID=$(grep "model" /proc/cpuinfo | head -1 | awk '{print $3}')
    CPU_STEPPING=$(grep "stepping" /proc/cpuinfo | head -1 | awk '{print $3}')
    
    echo "CPU:"
    echo "  供应商: $CPU_VENDOR"
    echo "  型号: $CPU_MODEL"
    echo "  家族: $CPU_FAMILY"
    echo "  型号ID: $CPU_MODEL_ID"
    echo "  步进: $CPU_STEPPING"
    echo ""
    
    # 内存信息
    MEM_TOTAL=$(free -h | grep Mem | awk '{print $2}')
    echo "内存: $MEM_TOTAL"
    echo ""
    
    # GPU信息
    echo "GPU设备:"
    if lspci | grep -q "VGA\|3D\|Display"; then
        lspci | grep -E "VGA|3D|Display" | while read line; do
            PCI_ID=$(echo $line | cut -d' ' -f1)
            GPU_NAME=$(echo $line | cut -d' ' -f2-)
            echo "  $PCI_ID - $GPU_NAME"
            
            # 检测音频设备
            AUDIO_ID=$(echo $PCI_ID | sed 's/\.0/.1/')
            if lspci -s $AUDIO_ID 2>/dev/null | grep -qi "audio"; then
                AUDIO_NAME=$(lspci -s $AUDIO_ID | cut -d' ' -f2-)
                echo "   音频设备: $AUDIO_ID - $AUDIO_NAME"
            fi
        done
    else
        echo "  未检测到GPU设备"
    fi
    
    echo "══════════════════════════════════════════════════"
    echo ""
}

# ============================================================================
# 5. 用户确认函数
# ============================================================================
confirm_execution() {
    echo ""
    log_warn "⚠️  重要警告：此脚本将修改系统关键配置！"
    echo ""
    echo "脚本将执行以下操作："
    echo "1. 修改系统软件源为国内镜像"
    echo "2. 修改GRUB引导参数（启用IOMMU）"
    echo "3. 配置VFIO驱动和模块黑名单"
    echo "4. 生成反虚拟化检测参数"
    echo "5. 需要重启系统生效"
    echo ""
    log_warn "建议在执行前："
    echo "  • 备份重要数据"
    echo "  • 确保系统已经更新到最新"
    echo "  • 了解您的硬件配置"
    echo ""
    
    log_input "是否继续执行？(输入 y 继续，其他键退出): "
    read -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "用户取消执行"
        exit 0
    fi
    echo ""
}

# ============================================================================
# 6. 配置软件源函数
# ============================================================================
configure_sources() {
    log_step "配置软件源为国内镜像..."
    
    # 备份原文件
    BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p $BACKUP_DIR
    
    if [ -f /etc/apt/sources.list ]; then
        cp /etc/apt/sources.list $BACKUP_DIR/sources.list.bak
        log_debug "已备份 /etc/apt/sources.list"
    fi
    
    if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
        cp /etc/apt/sources.list.d/pve-enterprise.list $BACKUP_DIR/pve-enterprise.list.bak
        log_debug "已备份企业版源"
    fi
    
    # 配置Debian清华源
    log_info "配置Debian清华镜像源..."
    cat > /etc/apt/sources.list << 'DEB_SOURCE'
# 清华大学 Debian 12 (bookworm) 镜像源
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware
DEB_SOURCE
    
    # 配置PVE非订阅源
    log_info "配置Proxmox VE非订阅源..."
    cat > /etc/apt/sources.list.d/pve-no-subscription.list << 'PVE_SOURCE'
# 清华大学 Proxmox VE 镜像源
deb https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian bookworm pve-no-subscription
PVE_SOURCE
    
    # 禁用企业版源（避免认证错误）
    rm -f /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null || true
    
    log_info "软件源配置完成，备份保存在: $BACKUP_DIR"
}

# ============================================================================
# 7. 配置IOMMU函数
# ============================================================================
configure_iommu() {
    log_step "配置IOMMU直通..."
    
    # 检测CPU类型并配置相应参数
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
    
    # 添加PCIe ACS覆盖（解决IOMMU分组问题）
    IOMMU_PARAMS="$IOMMU_PARAMS pcie_acs_override=downstream,multifunction"
    
    # 获取当前GRUB配置
    GRUB_FILE="/etc/default/grub"
    cp $GRUB_FILE $GRUB_FILE.bak
    log_debug "已备份GRUB配置: $GRUB_FILE.bak"
    
    # 检查是否已包含IOMMU参数
    CURRENT_CMDLINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' $GRUB_FILE | cut -d'"' -f2)
    
    if echo "$CURRENT_CMDLINE" | grep -q "iommu="; then
        log_warn "GRUB已包含IOMMU参数，跳过配置"
        log_debug "当前参数: $CURRENT_CMDLINE"
    else
        # 更新GRUB配置
        NEW_CMDLINE="$CURRENT_CMDLINE $IOMMU_PARAMS"
        sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"$CURRENT_CMDLINE\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_CMDLINE\"|g" $GRUB_FILE
        
        log_info "已添加IOMMU参数到GRUB"
        log_debug "新参数: $NEW_CMDLINE"
    fi
    
    log_info "IOMMU配置完成"
}

# ============================================================================
# 8. 配置VFIO驱动函数
# ============================================================================
configure_vfio() {
    log_step "配置VFIO驱动..."
    
    # 备份原modules文件
    MODULES_FILE="/etc/modules"
    cp $MODULES_FILE $MODULES_FILE.bak 2>/dev/null || true
    
    # 添加VFIO模块到自动加载
    log_info "添加VFIO模块到 /etc/modules"
    
    # 检查是否已添加
    if ! grep -q "^vfio$" $MODULES_FILE; then
        echo -e "\n# ========================================" >> $MODULES_FILE
        echo "# VFIO for GPU Passthrough (Added by script)" >> $MODULES_FILE
        echo "# ========================================" >> $MODULES_FILE
        echo "vfio" >> $MODULES_FILE
        echo "vfio_iommu_type1" >> $MODULES_FILE
        echo "vfio_pci" >> $MODULES_FILE
        echo "vfio_virqfd" >> $MODULES_FILE
        log_info "VFIO模块已添加到启动加载"
    else
        log_warn "VFIO模块已存在，跳过添加"
    fi
    
    # 配置显卡驱动黑名单
    log_info "配置显卡驱动黑名单..."
    
    BLACKLIST_FILE="/etc/modprobe.d/blacklist-gpu.conf"
    cat > $BLACKLIST_FILE << 'BLACKLIST'
# ========================================
# GPU驱动黑名单配置
# 防止原生驱动与VFIO冲突
# ========================================

# 禁用NVIDIA驱动
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
blacklist nvidia_modeset

# 禁用AMD驱动
blacklist radeon
blacklist amdgpu

# 禁用Intel集成显卡（如果需要）
# blacklist i915

# 禁用音频驱动（避免冲突）
blacklist snd_hda_intel
BLACKLIST
    
    log_info "驱动黑名单配置完成: $BLACKLIST_FILE"
    
    # 配置VFIO参数
    VFIO_CONF_FILE="/etc/modprobe.d/vfio.conf"
    cat > $VFIO_CONF_FILE << 'VFIO_CONF'
# ========================================
# VFIO 驱动配置
# ========================================

# 允许不安全中断（某些设备需要）
options vfio_iommu_type1 allow_unsafe_interrupts=1

# 默认情况下禁用VFIO VGA（避免宿主机无法显示）
options vfio-pci disable_vga=1

# 设备ID将在后续步骤中自动添加
# options vfio-pci ids=xxxx:xxxx
VFIO_CONF
    
    log_info "VFIO参数配置完成: $VFIO_CONF_FILE"
}

# ============================================================================
# 9. 检测GPU并配置绑定
# ============================================================================
configure_gpu_binding() {
    log_step "检测GPU设备并配置绑定..."
    
    # 查找所有GPU设备
    GPU_LIST=$(lspci | grep -E "VGA|3D|Display" | awk '{print $1}')
    
    if [ -z "$GPU_LIST" ]; then
        log_warn "未检测到GPU设备，跳过GPU绑定配置"
        return 0
    fi
    
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "              检测到的GPU设备"
    echo "══════════════════════════════════════════════════"
    
    VFIO_IDS=""
    GPU_COUNT=0
    
    for GPU in $GPU_LIST; do
        GPU_INFO=$(lspci -s $GPU)
        GPU_ID=$(lspci -n -s $GPU | awk '{print $3}')
        
        echo ""
        echo "[GPU $((++GPU_COUNT))]"
        echo "  PCI地址: $GPU"
        echo "  设备ID: $GPU_ID"
        echo "  描述: ${GPU_INFO#*: }"
        
        # 检测音频设备
        AUDIO_GPU=$(echo $GPU | sed 's/\.0/.1/')
        if lspci -s $AUDIO_GPU 2>/dev/null | grep -qi "audio"; then
            AUDIO_ID=$(lspci -n -s $AUDIO_GPU | awk '{print $3}')
            AUDIO_INFO=$(lspci -s $AUDIO_GPU)
            echo "  音频设备:"
            echo "    PCI地址: $AUDIO_GPU"
            echo "    设备ID: $AUDIO_ID"
            echo "    描述: ${AUDIO_INFO#*: }"
            
            # 添加到绑定列表
            if [ -n "$VFIO_IDS" ]; then
                VFIO_IDS="$VFIO_IDS,$GPU_ID,$AUDIO_ID"
            else
                VFIO_IDS="$GPU_ID,$AUDIO_ID"
            fi
        else
            # 只有视频设备
            if [ -n "$VFIO_IDS" ]; then
                VFIO_IDS="$VFIO_IDS,$GPU_ID"
            else
                VFIO_IDS="$GPU_ID"
            fi
        fi
    done
    
    echo "══════════════════════════════════════════════════"
    echo ""
    
    if [ -n "$VFIO_IDS" ]; then
        log_info "检测到GPU设备，自动配置VFIO绑定"
        log_debug "设备ID列表: $VFIO_IDS"
        
        # 更新VFIO配置
        echo "options vfio-pci ids=$VFIO_IDS" >> /etc/modprobe.d/vfio.conf
        
        log_info "已配置VFIO自动绑定以下设备:"
        echo "$VFIO_IDS" | tr ',' '\n' | while read ID; do
            echo "  - $ID"
        done
        
        # 询问是否选择特定GPU
        echo ""
        log_input "是否要选择特定GPU进行直通？(输入y手动选择，直接回车使用全部GPU): "
        read -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            manual_select_gpu
        fi
    else
        log_warn "未获取到有效的GPU设备ID，跳过自动绑定"
    fi
}

# ============================================================================
# 10. 手动选择GPU函数
# ============================================================================
manual_select_gpu() {
    log_step "手动选择GPU设备..."
    
    echo ""
    echo "请选择要直通的GPU（输入数字，多个用逗号分隔，如 1,3）:"
    
    # 显示GPU列表
    GPU_INDEX=0
    declare -A GPU_MAP
    
    lspci | grep -E "VGA|3D|Display" | while read line; do
        GPU_INDEX=$((GPU_INDEX + 1))
        PCI_ID=$(echo $line | awk '{print $1}')
        GPU_DESC=$(echo $line | cut -d' ' -f2-)
        GPU_MAP[$GPU_INDEX]=$PCI_ID
        
        echo "  $GPU_INDEX. $PCI_ID - $GPU_DESC"
    done
    
    echo ""
    log_input "请输入选择（直接回车跳过）: "
    read -r SELECTION
    
    if [ -n "$SELECTION" ]; then
        # 清空之前的绑定配置
        sed -i '/options vfio-pci ids=/d' /etc/modprobe.d/vfio.conf
        
        NEW_VFIO_IDS=""
        IFS=',' read -ra SELECTED <<< "$SELECTION"
        
        for INDEX in "${SELECTED[@]}"; do
            INDEX=$(echo $INDEX | xargs)  # 去除空格
            if [ -n "${GPU_MAP[$INDEX]}" ]; then
                GPU_PCI=${GPU_MAP[$INDEX]}
                GPU_ID=$(lspci -n -s $GPU_PCI | awk '{print $3}')
                
                # 获取音频设备
                AUDIO_PCI=$(echo $GPU_PCI | sed 's/\.0/.1/')
                AUDIO_ID=$(lspci -n -s $AUDIO_PCI 2>/dev/null | awk '{print $3}')
                
                if [ -n "$NEW_VFIO_IDS" ]; then
                    if [ -n "$AUDIO_ID" ]; then
                        NEW_VFIO_IDS="$NEW_VFIO_IDS,$GPU_ID,$AUDIO_ID"
                    else
                        NEW_VFIO_IDS="$NEW_VFIO_IDS,$GPU_ID"
                    fi
                else
                    if [ -n "$AUDIO_ID" ]; then
                        NEW_VFIO_IDS="$GPU_ID,$AUDIO_ID"
                    else
                        NEW_VFIO_IDS="$GPU_ID"
                    fi
                fi
                
                log_info "已选择GPU: $GPU_PCI ($GPU_ID)"
            fi
        done
        
        if [ -n "$NEW_VFIO_IDS" ]; then
            echo "options vfio-pci ids=$NEW_VFIO_IDS" >> /etc/modprobe.d/vfio.conf
            log_info "已更新VFIO绑定配置"
        fi
    fi
}

# ============================================================================
# 11. 生成反虚拟化参数函数
# ============================================================================
generate_anti_vm_config() {
    log_step "生成反虚拟化检测参数..."
    
    # 获取CPU信息
    CPU_VENDOR=$(grep "vendor_id" /proc/cpuinfo | head -1 | awk '{print $3}')
    CPU_FAMILY=$(grep "cpu family" /proc/cpuinfo | head -1 | awk '{print $3}')
    CPU_MODEL=$(grep "model" /proc/cpuinfo | head -1 | awk '{print $3}')
    CPU_STEPPING=$(grep "stepping" /proc/cpuinfo | head -1 | awk '{print $3}')
    CPU_MODEL_NAME=$(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
    
    # 清理CPU型号名称
    CLEAN_MODEL_NAME=$(echo "$CPU_MODEL_NAME" | sed -e 's/Intel(R) //' -e 's/CPU //' -e 's/ @.*//' -e 's/ Processor//')
    
    # 生成反虚拟化参数
    ANTIVM_ARGS="-cpu host"
    
    # CPU参数
    ANTIVM_ARGS="$ANTIVM_ARGS,family='$CPU_FAMILY',model='$CPU_MODEL',stepping='$CPU_STEPPING'"
    
    # 自定义型号ID（可以修改为您想要显示的名称）
    CUSTOM_MODEL_ID="Intel Core i7 12700 @ 4.90GHz"
    log_input "输入想要显示的CPU型号（直接回车使用默认: $CUSTOM_MODEL_ID）: "
    read -r USER_MODEL_ID
    if [ -n "$USER_MODEL_ID" ]; then
        CUSTOM_MODEL_ID="$USER_MODEL_ID"
    fi
    ANTIVM_ARGS="$ANTIVM_ARGS,model_id='$CUSTOM_MODEL_ID'"
    
    # KVM参数
    ANTIVM_ARGS="$ANTIVM_ARGS,+kvm_pv_unhalt,+kvm_pv_eoi"
    
    # Hyper-V参数
    ANTIVM_ARGS="$ANTIVM_ARGS,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_reset,hv_vpindex,hv_runtime,hv_relaxed"
    
    # 虚拟化检测绕过
    ANTIVM_ARGS="$ANTIVM_ARGS,kvm=off"
    
    # 厂商ID（根据CPU类型选择）
    if [ "$CPU_VENDOR" = "GenuineIntel" ]; then
        ANTIVM_ARGS="$ANTIVM_ARGS,hv_vendor_id=intel"
    else
        ANTIVM_ARGS="$ANTIVM_ARGS,hv_vendor_id=amd"
    fi
    
    # 其他参数
    ANTIVM_ARGS="$ANTIVM_ARGS,vmware-cpuid-freq=false,enforce=false,host-phys-bits=true,hypervisor=off"
    
    # SMBIOS参数（模拟真实硬件）
    ANTIVM_ARGS="$ANTIVM_ARGS -smbios type=0"
    ANTIVM_ARGS="$ANTIVM_ARGS -smbios type=9"
    ANTIVM_ARGS="$ANTIVM_ARGS -smbios type=8"
    ANTIVM_ARGS="$ANTIVM_ARGS -smbios type=8"
    
    # 保存参数到文件
    ANTIVM_FILE="/root/anti-vm-args.txt"
    echo "$ANTIVM_ARGS" > $ANTIVM_FILE
    
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "           生成的反虚拟化参数"
    echo "══════════════════════════════════════════════════"
    echo "$ANTIVM_ARGS"
    echo "══════════════════════════════════════════════════"
    echo ""
    
    log_info "参数已保存到: $ANTIVM_FILE"
    log_info "在创建虚拟机时，将此参数添加到'args:'配置项中"
    
    # 询问是否创建示例虚拟机配置
    log_input "是否创建示例虚拟机配置文件？(y/N): "
    read -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        create_example_vm_config "$ANTIVM_ARGS"
    fi
}

# ============================================================================
# 12. 创建示例虚拟机配置
# ============================================================================
create_example_vm_config() {
    local ARGS="$1"
    
    log_step "创建示例虚拟机配置文件..."
    
    EXAMPLE_FILE="/root/vm-gpu-example.conf"
    
    cat > $EXAMPLE_FILE << EXAMPLE_CONF
# ========================================
# Proxmox VE GPU直通虚拟机配置示例
# 生成时间: $(date)
# ========================================

# 虚拟机基本信息
boot: order=scsi0;net0
cores: 4
cpu: host
memory: 8192
name: gpu-vm-example
net0: virtio=xx:xx:xx:xx:xx:xx,bridge=vmbr0
numa: 1
ostype: win11
scsi0: local-lvm:vm-100-disk-0,size=128G
scsihw: virtio-scsi-pci
smbios1: uuid=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
sockets: 1
vmgenid: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# ========================================
# GPU直通配置（根据您的GPU修改）
# ========================================

# 视频设备（示例：第一个NVIDIA GPU）
# hostpci0: 03:00.0,pcie=1,x-vga=1

# 音频设备（与GPU配套）
# hostpci1: 03:00.1,pcie=1

# ========================================
# 反虚拟化检测参数（复制以下内容）
# ========================================
args: $ARGS

# ========================================
# 其他优化配置
# ========================================

# 启用QEMU代理（需要在虚拟机内安装qemu-guest-agent）
agent: 1

# 禁用Ballooning（避免内存动态调整影响性能）
balloon: 0

# 使用Q35机器类型（推荐）
machine: pc-q35-9.0

# 使用OVMF UEFI（推荐用于Windows 10/11）
bios: ovmf
efidisk0: local-lvm:4M

# 启用NUMA（多CPU插槽系统）
numa: 1

# ========================================
# 使用说明：
# 1. 复制此配置到 /etc/pve/qemu-server/XXX.conf
# 2. 修改hostpciX指向您的GPU设备
# 3. 修改网络MAC地址
# 4. 调整CPU、内存等参数
# 5. 创建虚拟机磁盘
# ========================================
EXAMPLE_CONF
    
    log_info "示例配置文件已创建: $EXAMPLE_FILE"
    log_info "请根据您的硬件修改配置"
}

# ============================================================================
# 13. 更新系统配置
# ============================================================================
update_system_config() {
    log_step "更新系统配置..."
    
    # 更新软件包列表
    log_info "更新软件包列表..."
    apt update 2>/dev/null || {
        log_warn "apt update 失败，尝试继续..."
    }
    
    # 更新GRUB引导
    log_info "更新GRUB引导配置..."
    if update-grub; then
        log_info "GRUB更新成功"
    else
        log_error "GRUB更新失败"
        exit 1
    fi
    
    # 更新initramfs
    log_info "更新initramfs..."
    if update-initramfs -u -k all; then
        log_info "initramfs更新成功"
    else
        log_error "initramfs更新失败"
        exit 1
    fi
    
    # 创建验证脚本
    create_verification_script
    
    log_info "系统配置更新完成"
}

# ============================================================================
# 14. 创建验证脚本
# ============================================================================
create_verification_script() {
    log_step "创建验证脚本..."
    
    VERIFY_SCRIPT="/root/check-gpu-passthrough.sh"
    
    cat > $VERIFY_SCRIPT << 'VERIFY_EOF'
#!/bin/bash
# GPU直通验证脚本
# 使用方法：bash check-gpu-passthrough.sh

echo "══════════════════════════════════════════════════"
echo "            GPU直通配置验证"
echo "══════════════════════════════════════════════════"
echo ""

# 检查系统信息
echo "1. 系统信息:"
echo "   PVE版本: $(pveversion 2>/dev/null | grep pve-manager || echo "未安装PVE")"
echo "   内核版本: $(uname -r)"
echo "   系统时间: $(date)"
echo ""

# 检查GRUB配置
echo "2. GRUB配置:"
GRUB_CMD=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null | cut -d'"' -f2)
if [ -n "$GRUB_CMD" ]; then
    echo "   当前参数: $GRUB_CMD"
    
    # 检查关键参数
    if echo "$GRUB_CMD" | grep -q "iommu=on"; then
        echo "   ✅ IOMMU已启用"
    else
        echo "   ❌ IOMMU未启用"
    fi
    
    if echo "$GRUB_CMD" | grep -q "iommu=pt"; then
        echo "   ✅ IOMMU PT模式已启用"
    else
        echo "   ❌ IOMMU PT模式未启用"
    fi
else
    echo "   ❌ 无法读取GRUB配置"
fi
echo ""

# 检查VFIO驱动
echo "3. VFIO驱动状态:"
if lsmod | grep -q vfio; then
    echo "   ✅ VFIO驱动已加载"
    lsmod | grep vfio | while read line; do
        echo "      $line"
    done
else
    echo "   ❌ VFIO驱动未加载"
fi
echo ""

# 检查GPU设备
echo "4. GPU设备状态:"
GPU_COUNT=0
lspci | grep -E "VGA|3D|Display" | while read line; do
    GPU_COUNT=$((GPU_COUNT + 1))
    PCI_ID=$(echo $line | awk '{print $1}')
    DEVICE_NAME=$(echo $line | cut -d' ' -f2-)
    
    echo "   GPU $GPU_COUNT:"
    echo "     地址: $PCI_ID"
    echo "     名称: $DEVICE_NAME"
    
    # 检查驱动绑定
    DRIVER_INFO=$(lspci -k -s $PCI_ID 2>/dev/null | grep "Kernel driver in use:" || echo "")
    if [ -n "$DRIVER_INFO" ]; then
        echo "     驱动: $DRIVER_INFO"
        if echo "$DRIVER_INFO" | grep -q "vfio-pci"; then
            echo "     ✅ 已绑定到VFIO（可直通）"
        else
            echo "     ⚠️  未绑定到VFIO"
        fi
    fi
    
    # 检查音频设备
    AUDIO_PCI=$(echo $PCI_ID | sed 's/\.0/.1/')
    if lspci -s $AUDIO_PCI 2>/dev/null | grep -qi "audio"; then
        echo "     音频设备: $AUDIO_PCI"
    fi
    echo ""
done

if [ $GPU_COUNT -eq 0 ]; then
    echo "   ⚠️  未检测到GPU设备"
fi

# 检查配置文件
echo "5. 配置文件检查:"
echo "   GRUB配置: /etc/default/grub"
echo "   模块配置: /etc/modules"
echo "   黑名单: /etc/modprobe.d/blacklist-gpu.conf"
echo "   VFIO配置: /etc/modprobe.d/vfio.conf"
echo ""

# 检查IOMMU分组
echo "6. IOMMU分组信息（前5组）:"
for group in $(find /sys/kernel/iommu_groups/ -maxdepth 1 -type d | sort -V | head -6); do
    group_num=$(basename $group)
    if [ "$group_num" != "iommu_groups" ]; then
        devices=$(ls $group/devices/ 2>/dev/null | wc -l)
        if [ $devices -gt 0 ]; then
            echo "   组 $group_num: $devices 个设备"
            # 显示设备信息
            for device in $(ls $group/devices/ 2>/dev/null | head -3); do
                device_info=$(lspci -s $device 2>/dev/null | cut -d' ' -f2-)
                echo "     - $device: $device_info"
            done
            if [ $devices -gt 3 ]; then
                echo "     ... 还有 $((devices - 3)) 个设备"
            fi
        fi
    fi
done
echo ""

# 使用建议
echo "7. 使用建议:"
echo "   ✅ 如果所有检查通过，可以创建虚拟机并添加PCI设备"
echo "   ⚠️  需要重启系统以使配置生效"
echo "   📝 反虚拟化参数保存在: /root/anti-vm-args.txt"
echo "   📋 示例配置: /root/vm-gpu-example.conf"
echo ""

echo "══════════════════════════════════════════════════"
echo "验证完成！"
echo ""

# 询问是否测试
read -p "是否测试VFIO绑定？(y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "测试VFIO绑定..."
    for GPU in $(lspci | grep -E "VGA|3D|Display" | awk '{print $1}'); do
        echo "测试设备 $GPU:"
        if lspci -k -s $GPU | grep -q "vfio-pci"; then
            echo "  ✅ 已绑定到VFIO"
        else
            echo "  ⚠️  未绑定到VFIO，可能需要重启"
        fi
    done
fi
VERIFY_EOF
    
    chmod +x $VERIFY_SCRIPT
    log_info "验证脚本已创建: $VERIFY_SCRIPT"
}

# ============================================================================
# 15. 显示完成信息
# ============================================================================
show_completion() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "                   配置完成！🎉"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "✅ 所有配置已完成！"
    echo ""
    echo "📋 已执行的操作："
    echo "   1. 系统环境检查"
    echo "   2. 硬件信息检测"
    echo "   3. 软件源配置（清华镜像）"
    echo "   4. IOMMU配置"
    echo "   5. VFIO驱动配置"
    echo "   6. GPU设备检测和绑定"
    echo "   7. 反虚拟化参数生成"
    echo "   8. 系统配置更新"
    echo ""
    echo "📁 生成的文件："
    echo "   • /root/anti-vm-args.txt        - 反虚拟化参数"
    echo "   • /root/vm-gpu-example.conf     - 虚拟机配置示例"
    echo "   • /root/check-gpu-passthrough.sh - 验证脚本"
    echo ""
    echo "⚠️  重要提示："
    echo "   必须重启系统才能使所有配置生效！"
    echo ""
    echo "🚀 重启后操作："
    echo "   1. 运行验证脚本：bash /root/check-gpu-passthrough.sh"
    echo "   2. 创建虚拟机并添加PCI设备"
    echo "   3. 在虚拟机配置中添加反虚拟化参数"
    echo "   4. 安装操作系统和GPU驱动"
    echo ""
    echo "🔧 验证命令："
    echo "   # 检查IOMMU"
    echo "   dmesg | grep -i iommu"
    echo ""
    echo "   # 检查VFIO驱动"
    echo "   lsmod | grep vfio"
    echo ""
    echo "   # 检查GPU绑定"
    echo "   lspci -k | grep -A2 -B2 vfio-pci"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    
    # 询问是否重启
    echo ""
    log_input "是否立即重启系统？(输入 y 重启，其他键稍后手动重启): "
    read -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "系统将在10秒后重启..."
        echo "按 Ctrl+C 可以取消重启"
        sleep 10
        reboot
    else
        log_info "请记得手动重启系统以使配置生效"
        log_info "重启命令: reboot"
    fi
}

# ============================================================================
# 16. 错误处理函数
# ============================================================================
handle_error() {
    log_error "脚本执行出错！"
    log_error "错误发生在第 $1 行"
    log_error "退出状态: $2"
    
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "                   故障排除"
    echo "══════════════════════════════════════════════════"
    echo ""
    echo "1. 检查错误信息"
    echo "2. 查看日志: tail -f /var/log/syslog"
    echo "3. 恢复备份: 备份文件在 /root/backup_*/"
    echo "4. 手动检查配置"
    echo ""
    echo "如果需要帮助，请提供以下信息："
    echo "   • 错误信息"
    echo "   • 系统版本: pveversion"
    echo "   • 硬件信息: lspci | grep -E 'VGA|3D'"
    echo ""
    
    exit 1
}

# ============================================================================
# 17. 主执行流程
# ============================================================================
main() {
    # 设置错误处理
    trap 'handle_error ${LINENO} ${?}' ERR
    
    # 显示欢迎信息
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "      Proxmox VE GPU直通一键配置脚本"
    echo "               版本 4.0 - 完整版"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "📌 功能："
    echo "   • 自动检测硬件"
    echo "   • 配置IOMMU和VFIO"
    echo "   • 生成反虚拟化参数"
    echo "   • 创建验证脚本"
    echo ""
    echo "⏱️  预计时间：3-5分钟"
    echo ""
    
    # 执行所有步骤
    check_environment
    detect_hardware
    confirm_execution
    configure_sources
    configure_iommu
    configure_vfio
    configure_gpu_binding
    generate_anti_vm_config
    update_system_config
    show_completion
    
    log_info "脚本执行完成！"
}

# ============================================================================
# 18. 脚本入口
# ============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
