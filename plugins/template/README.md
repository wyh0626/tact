# 自定义平台插件模板

这是开发模板，所有能力默认关闭，不能直接用于聊天建议，也不会随应用注册。任何 IM 都通过导入插件接入。

1. 复制整个目录到独立位置，改 `manifest.json` 的 `id`、`name`、`version` 和客户端 `bundle_ids`。
2. 实现 `adapter.py chats` 和 `adapter.py history <chat_id> <limit>`，返回格式见仓库 `docs/ADAPTER.md`，或应用开发资料中的上级 `ADAPTER.md`。`drafts` 可继续返回退出码 3。
3. 验证消息连接器后，将 `conversations.list`、`messages.read` 改为 `true`。完成当前客户端的输入框读取、填入和 OCR 校准后，再声明相应桌面能力。
4. 把整个插件文件夹（或它的 `.zip`）拖进「聊天工具 → 添加」。导入只验证和注册，默认停用；按「准备」完成安装登录后打开开关，Tact 先检测连接（会读取会话列表），通过才启用。当前版本要求 `conversations.list` 和 `messages.read` 均为 `true`，未实现的原始模板会作为不完整插件被拒绝。

插件需要自包含。`${plugin_dir}` 会替换成 manifest 所在目录，避免引用开发者电脑上的路径。若依赖 Python、Node、CLI 或其他运行时，用户需要自行安装。不要在包里附带真实账号、会话缓存、凭据或访问令牌。

插件作为当前用户的外部进程运行，这不是权限沙箱。只导入信任的实现；不要仅凭 manifest 的能力声明判断代码是否可信。

可选 `setup` 元数据用于展示环境要求、准备命令和真实帮助链接，普通用户按指引完成安装/登录，无需改 JSON；`setup.commands` 里的命令只在用户点「在终端中运行」时执行。`composer.read` 和 `composer.apply` 都实现后才启用桌面建议，事件订阅当前必须关闭。
