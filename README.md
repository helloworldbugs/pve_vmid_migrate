# PVE VMID Migrate

Proxmox VE 一键迁移 QEMU 虚拟机 / LXC 容器 ID 的脚本。合并了原来的 `qemu_vmid_migrate.sh` 和 `lxc_id_migrate.sh`，自动检测 VM 类型，支持多存储后端。

## 功能

- [x] 配置文件迁移（自动重命名 + 内部路径替换）
- [x] 磁盘文件迁移（支持 local / NFS / CIFS 等目录型存储）
- [x] 备份文件迁移（可选，`--skip-backups` 跳过）
- [x] Dry-run 预览模式
- [x] 自动检测 QEMU / LXC 类型
- [ ] 快照文件迁移（未实现）
- [ ] LVM-thin / ZFS / Ceph 等非目录型存储（未实现）

## 适用版本

- PVE 8.x / 9.x
- 已在 **PVE 9.2.3** 上测试通过

## 使用方法

```bash
# 基本用法（自动检测 QEMU / LXC）
bash pve_vmid_migrate.sh <旧ID> <新ID>

# 预览模式 — 只显示会做什么，不实际修改
bash pve_vmid_migrate.sh --dry-run <旧ID> <新ID>

# 跳过备份文件迁移
bash pve_vmid_migrate.sh --skip-backups <旧ID> <新ID>

# 强制指定类型
bash pve_vmid_migrate.sh --type qemu 101 201
bash pve_vmid_migrate.sh --type lxc  110 210

# 指定日志文件
bash pve_vmid_migrate.sh --log /tmp/my_migrate.log 101 201

# 纯文本输出（用于脚本调度）
bash pve_vmid_migrate.sh --no-color 101 201
```

## 选项

| 选项 | 说明 |
|------|------|
| `--dry-run` | 预览变更，不实际执行 |
| `--skip-backups` | 不迁移备份文件 |
| `--no-color` | 纯文本输出（无 ANSI 颜色） |
| `--log FILE` | 指定日志文件路径（默认自动生成） |
| `--type qemu\|lxc` | 强制指定 VM 类型 |
| `-h, --help` | 显示帮助 |

## 前置条件

1. 目标 VM/CT 必须处于 **stopped** 状态
2. 新 VMID 未被占用
3. VMID 必须在 100 以上（Proxmox 保留范围）
4. 必须以 **bash** 执行（不兼容 sh/dash）

## 迁移内容

脚本会处理以下三项：

1. **配置文件** — 重命名 `.conf` 并替换内部 VMID 引用（磁盘路径、vmid 参数）
2. **磁盘文件** — 解析配置中的存储引用，跨存储后端移动磁盘文件
3. **备份文件** — 重命名 `vzdump-*` 备份及其关联文件（日志、notes、protected）

## 从旧版本迁移

旧版本是两个独立脚本：

| 旧脚本 | 新命令 |
|--------|--------|
| `bash qemu_vmid_migrate.sh <旧> <新>` | `bash pve_vmid_migrate.sh <旧> <新>` |
| `bash lxc_id_migrate.sh <旧> <新>` | `bash pve_vmid_migrate.sh <旧> <新>` |

新脚本自动检测类型，无需手动选择。

## 注意事项

- **先 dry-run**：正式执行前务必用 `--dry-run` 预览
- **MAC 地址**：迁移后 MAC 地址保持不变，如需修改请手动编辑配置
- **PCI 直通**：`hostpci` 配置不受影响（不包含 VMID）
- **非目录存储**：LVM-thin、ZFS、Ceph RBD 等存储后端的磁盘文件不会被迁移，仅更新配置文件中的引用
- **运行中 VM**：脚本会拒绝迁移运行中的 VM/CT，请先手动关机
