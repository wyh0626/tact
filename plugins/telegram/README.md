# Telegram 插件

用你自己的 Telegram 账号，通过 Telegram 官方 API（MTProto，基于 [gotd](https://github.com/gotd/td)）读取会话列表和最近消息，交给 Tact 生成回复建议。

- **只读**：只调用读会话列表和读消息历史两个接口，不发送、不修改、不删除，也不标记已读（读历史不会让对方看到「已读」）。
- **扫码登录**：手机 Telegram → 设置 → 设备 → 关联桌面设备，扫终端里的二维码。不需要输入手机号和验证码；开了两步验证的账号会再要密码。
- **登录信息只在本机**：`~/.tact/telegram/`（权限 700，文件 600），包括会话、API 凭据和各会话的访问哈希。访问哈希不进会话 ID，也不出现在进程参数里。
- **随时可以结束**：手机 Telegram 的 设置 → 设备 里能看到名为「Tact」的会话；插件的「退出登录」会通知 Telegram 结束它并删除本机的登录信息。

## 桌面端

Telegram for macOS 不向辅助功能开放界面，所以插件声明 `desktop.strategy: "screen-ocr-v1"`：Tact 截取窗口，识别顶部栏的会话名去匹配插件给的会话列表，并找到输入栏和里面的字；按 Tab 时把建议粘贴进去。消息本身来自 API，不靠截图。

## API 凭据

Telegram 要求每个客户端用自己的 `api_id` / `api_hash`：

- **发布版**：打包时用环境变量 `TACT_TELEGRAM_APP_ID`、`TACT_TELEGRAM_APP_HASH` 注入 Tact 自己注册的应用（`scripts/build-app.sh`），不写进源码，用户只需要扫码。
- **开发版**：第一次「扫码登录」会提示填写你在 [my.telegram.org](https://my.telegram.org) → API development tools 创建的应用，保存在 `~/.tact/telegram/app.json`。

## 命令

```text
tact-telegram login              扫码登录（终端）
tact-telegram logout             退出登录并删除本机会话
tact-telegram chats              会话列表（JSON，最多 300 个，不含「收藏夹」）
tact-telegram history <id> <n>   最近 n 条消息（JSON，n 最多 100）
tact-telegram health             是否已登录（不联网）
```

会话 ID 形如 `user:123`、`chat:456`、`channel:789`。图片、语音、文件等以 `[图片]`、`[语音]`、`[文件 名称]` 表示。

开发：`GOTOOLCHAIN=local go test ./...`（需要 Go 1.24）。
