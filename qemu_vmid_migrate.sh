#!/bin/bash
# 在pve8.4.1上测试通过
# 使用方法 bash qemu_vmid_migrate.sh <原VMID> <新VMID>

###########################|用户配置区|##################################

# 配置文件目录
CONFIG_DIR="/etc/pve/qemu-server"
# 镜像文件目录
IMAGE_BASE="/mnt/pve/smb/images"
# 备份文件目录
BACKUP_DIR="/mnt/pve/smb/dump"

###########################|用户配置区|##################################

echo "${YELLOW}提示：如遇到报错，请检查是否按照要求使用bash执行，本脚本不兼容sh！!!"

# 参数校验
if [ $# -ne 2 ]; then
    echo -e "\033[31m[错误] 用法: $0 <原VMID> <新VMID>\033[0m"
    exit 1
fi

OLD_VMID=$1
NEW_VMID=$2


# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

# --------------------------
# 核心功能模块
# --------------------------

# 状态检测函数
check_vm_status() {
    # 检查原虚拟机配置文件
    if [ ! -f "${CONFIG_DIR}/${OLD_VMID}.conf" ]; then
        echo -e "${RED}[错误] 原虚拟机${OLD_VMID}不存在${NC}" >&2
        exit 2
    fi

    # 检查新ID是否被占用
    if [ -f "${CONFIG_DIR}/${NEW_VMID}.conf" ]; then
        echo -e "${RED}[错误] 新虚拟机ID${NEW_VMID}已被占用${NC}" >&2
        exit 3
    fi

    # 检查虚拟机状态（需完全关闭）
    local status=$(qm status $OLD_VMID | awk '{print $2}')
    if [ "$status" != "stopped" ]; then
        echo -e "${RED}[错误] 虚拟机${OLD_VMID}未关闭，请手动关闭后重试${NC}" >&2
        exit 4
    fi
}

# 配置文件处理
migrate_config() {
    
    # 重命名配置文件
    if ! mv "${CONFIG_DIR}/${OLD_VMID}.conf" "${CONFIG_DIR}/${NEW_VMID}.conf"; then
        echo -e "${RED}[错误] 配置文件重命名失败${NC}" >&2
        exit 5
    fi

    # 修改磁盘路径
    sed -i \
        -e "s/vm-${OLD_VMID}-disk/vm-${NEW_VMID}-disk/g" \
        -e "s/,vmid=${OLD_VMID}/,vmid=${NEW_VMID}/g" \
		-e "s|:${OLD_VMID}/|:${NEW_VMID}/|g" \
        "${CONFIG_DIR}/${NEW_VMID}.conf"

    echo -e "${YELLOW}[1/3] 完成配置文件迁移"
}

# 磁盘文件处理
migrate_disks() {

    if [ ! -d "$IMAGE_BASE" ]; then
        echo -e "${RED}[错误] 镜像存储目录 $IMAGE_BASE 不存在，请检查存储配置！${NC}" >&2
        exit 5
    fi

    # 创建新目录
    mkdir -p "${IMAGE_BASE}/${NEW_VMID}"

    # 处理磁盘文件（兼容多磁盘场景）
    if [ -d "${IMAGE_BASE}/${OLD_VMID}" ]; then
        cd "${IMAGE_BASE}/${OLD_VMID}"
        # 遍历所有旧磁盘文件并重命名
        for file in vm-${OLD_VMID}-disk-*.qcow2; do
            if [ -f "$file" ]; then
                newfile="vm-${NEW_VMID}-disk-${file#*-${OLD_VMID}-disk-}"
                mv "$file" "${IMAGE_BASE}/${NEW_VMID}/$newfile"
            fi
        done
        # 重命名父目录
        mv "${IMAGE_BASE}/${OLD_VMID}/"* "${IMAGE_BASE}/${NEW_VMID}/" 2>/dev/null
        rmdir "${IMAGE_BASE}/${OLD_VMID}" 2>/dev/null
    else
        echo -e "${YELLOW}[警告] 未找到原磁盘目录：${IMAGE_BASE}/${OLD_VMID}${NC}"
    fi
    echo -e "${YELLOW}[2/3] 完成磁盘文件迁移"
}

# 备份文件处理
migrate_backups() {

    if [ ! -d "$BACKUP_DIR" ]; then
        echo -e "${RED}[错误] 备份目录 $BACKUP_DIR 不存在，请检查存储配置！${NC}" >&2
        exit 7
    fi

    cd "$BACKUP_DIR" || {
        echo -e "${RED}[错误] 无法进入备份目录 $BACKUP_DIR${NC}" >&2
        exit 8
    }

    # 遍历所有匹配的备份文件
    for file in vzdump-qemu-${OLD_VMID}-*; do
        if [ -f "$file" ]; then
            newfile="${file//${OLD_VMID}/${NEW_VMID}}"  # 关键替换操作
            mv "$file" "$newfile" 2>/dev/null
        fi
    done

    echo -e "${YELLOW}[3/3] 完成备份文件迁移"
}

# --------------------------
# 主流程控制
# --------------------------
check_vm_status
migrate_config
migrate_disks
migrate_backups

echo -e "${GREEN}"
echo -e "操作成功！"
echo -e "原VMID: ${OLD_VMID} 切换到新VMID: ${NEW_VMID}"
echo -e "${NC}"
