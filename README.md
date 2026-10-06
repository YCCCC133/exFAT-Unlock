# exFAT Unlock · 强制挂载工具

取消外接 exFAT 一致性检查，清除启动扇区中的脏标记，并尝试读写挂载。

## 功能

- 检测 fsck_exfat 与处于阻塞状态的 FSKit 进程
- 按阶段发送 INT、TERM、KILL
- 同步修改主启动扇区与备份启动扇区的 VolumeDirty 位
- 挂载重试与结果通知

## 使用

使用 macOS 自带 zsh、diskutil、Perl、sudo 和钥匙串命令，不需要第三方包。

```bash
chmod +x "取消exFAT一致性检查.command"
./"取消exFAT一致性检查.command" --help
./"取消exFAT一致性检查.command" --dry-run
```

确认预览结果后，可双击 `.command` 文件或在终端不带参数执行。

## 管理员授权

优先使用已有 sudo 授权；随后尝试读取当前用户钥匙串中的 `local.exfat-force-mount.sudo` 项目，最后回退到终端输入密码。仓库不包含密码，也不会创建钥匙串凭据。

## 操作边界

默认处理所有检测到的外接 exFAT 分区。`--dry-run` 只列出检查进程和分区，不取得管理员权限、不发信号、不写磁盘。

跳过一致性检查和清除脏标记不能修复文件系统损坏。实际模式会写原始分区；存在损坏时继续写入可能导致数据丢失。请先备份，正常修复优先使用磁盘工具。FSKit 路径、进程状态和英文 diskutil 输出解析可能受 macOS 版本影响。

## 许可证

[MIT License](LICENSE)。
