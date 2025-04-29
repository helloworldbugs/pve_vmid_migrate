# 说明

适用于ProxmoxVE一键修改kvm虚拟机和lxc容器ID的脚本

# 功能

 - [x] 配置文件迁移
 - [x] 磁盘文件迁移
 - [x] 备份文件迁移
 - [ ] 快照文件迁移（未实现，待后续开发）

# 适用版本

\> 8

>已在8.4.1上测试通过

# 使用方法

kvm虚拟机

```
bash qemu_vmid_migrate.sh <原id> <新id>
```
lxc容器
```
bash lxc_id_migrate.sh <原id> <新id>
```

ps：如遇到报错，请检查是否按照要求使用bash执行，本脚本不兼容sh！！！
