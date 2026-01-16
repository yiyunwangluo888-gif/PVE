#!binbash
# 最简单有效的GPU直通一键脚本（基于你成功的10步）

set -e

echo ========================================
echo    Proxmox GPU直通一键配置脚本（极简版）
echo ========================================
echo 

# 1. 检查权限
if [ $EUID -ne 0 ]; then 
    echo ❌ 请使用 sudo 运行 sudo bash $0
    exit 1
fi

# 2. 显示GPU信息
echo ✅ 检测显卡信息...
GPU_INFO=$(lspci -nn  grep -i nvidia)
if [ -z $GPU_INFO ]; then
    echo ❌ 未检测到NVIDIA显卡
    exit 1
fi
echo 找到显卡 $GPU_INFO

# 3. 确认
read -p ⚠️  继续将配置GPU直通？(yN)  confirm
if [[ ! $confirm =~ ^[Yy]$ ]]; then
    echo ❌ 用户取消
    exit 0
fi

echo 
echo 🚀 开始配置...
echo 

# 4. 配置IOMMU
echo 1. 启用IOMMU...
if ! grep -q intel_iommu=on etcdefaultgrub; then
    sed -i 'sGRUB_CMDLINE_LINUX_DEFAULT=&intel_iommu=on iommu=pt ' etcdefaultgrub
    echo    ✓ IOMMU已启用
else
    echo    ⏭️ IOMMU已存在，跳过
fi

# 5. 屏蔽驱动
echo 2. 屏蔽显卡驱动...
echo blacklist nouveau  etcmodprobe.dblacklist.conf
echo blacklist nvidia  etcmodprobe.dblacklist.conf
echo    ✓ 驱动已屏蔽

# 6. 配置VFIO（GTX 1060专用ID）
echo 3. 配置VFIO绑定...
echo options vfio-pci ids=10de1c03,10de10f1  etcmodprobe.dvfio.conf
echo    ✓ VFIO已配置

# 7. 加载模块
echo 4. 加载VFIO模块...
grep -q vfio etcmodules  echo vfio  etcmodules
grep -q vfio_iommu_type1 etcmodules  echo vfio_iommu_type1  etcmodules
grep -q vfio_pci etcmodules  echo vfio_pci  etcmodules
echo    ✓ 模块配置完成

# 8. 更新系统
echo 5. 更新系统配置...
update-grub 2devnull
update-initramfs -u -k all 2devnull
echo    ✓ 系统更新完成

echo 
echo ========================================
echo ✅ 主机配置完成！
echo ========================================
echo 
echo 下一步操作：
echo 1. 重启系统 sudo reboot
echo 2. 重启后运行验证 lspci -k -s 0300
echo 3. 如果显示 'Kernel driver in use vfio-pci'
echo 4. 使用以下命令配置虚拟机
echo 
echo    # 添加GPU直通
echo    qm set 100 -hostpci0 0300.0,pcie=1,rombar=0
echo    qm set 100 -hostpci1 0300.1,pcie=1
echo 
echo    # 设置CPU（如果未设置）
echo    qm set 100 -cpu host,hidden=1
echo    qm set 100 -machine q35
echo 
echo    # 启动虚拟机
echo    qm start 100
echo 
echo ========================================