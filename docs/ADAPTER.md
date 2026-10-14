# 平台适配器协议 v1

Tact 的平台插件把消息读取和桌面客户端定位一起注册到宿主。模型、建议浮窗、快捷键和填入后的核验仍由宿主负责。微信由宿主内置的聊天区 OCR 接入；Telegram 由 `plugins/telegram` 插件接入（消息走 Telegram API，桌面走截图）；钉钉、飞书、Slack、Discord 暂未支持。其他 IM 通过导入插件接入，插件只有用户主动导入后才会出现。

当前实现是 **`command-v1`：外部命令 + JSON 输出**。每次消息操作启动一个进程，不是常驻 JSON-RPC 服务。事件订阅、多账号自动识别、频道话题定位和原子草稿写入尚未实现，不应通过 manifest 宣称支持。

## 插件包

```text
example-chat/
├── manifest.json
└── adapter.py
```

插件包必须自包含，复制整个目录到其他位置仍可运行；Python、CLI 等外部运行时由用户安装。`plugins/telegram/` 是一个完整的参考实现：用 Go 写成单个可执行文件，不依赖额外运行时。

`plugins/template/` 是未完成的开发模板，不属于已支持平台。先实现会话和消息命令，再修改能力声明后导入。原始模板缺少必需能力，会被拒绝导入。

应用自定义接入向导可生成供提供方或技术人员使用的接入说明，并在「查看接入说明与开发资料」打开开发资料。打包的通用协议位于 `Contents/Resources/PluginSDK/ADAPTER.md`，模板位于 `Contents/Resources/PluginSDK/template/`；这里不包含具体平台的实现。

## Manifest

一个示例 manifest：

```json
{
  "protocol_version": 1,
  "id": "example.chat",
  "name": "Example Chat",
  "version": "1.0.0",
  "transport": "command-v1",
  "entrypoint": ["/usr/bin/python3", "${plugin_dir}/adapter.py"],
  "capabilities": {
    "conversations.list": true,
    "messages.read": true,
    "composer.read": true,
    "composer.apply": true,
    "overlay.inline": true,
    "events.subscribe": false
  },
  "desktop": {
    "strategy": "ax-ocr-v1",
    "bundle_ids": ["com.example.chat"],
    "header": {"top_offset": 28, "height": 64, "left_padding": 0},
    "overlay": {"font_size": 13, "offset_x": 0, "offset_y": 0},
    "send_shortcut": "return"
  },
  "limits": {"timeout_ms": 15000, "chats_cache_seconds": 300}
}
```

| 字段 | 约定 |
| --- | --- |
| `protocol_version` | 整数 `1`；未知版本拒绝加载 |
| `id` / `name` / `version` | 插件标识、显示名、版本；与配置里的实例 `id` 区分 |
| `transport` | 当前仅支持 `command-v1` |
| `entrypoint` | 可执行文件和固定参数的数组；宿主追加操作名和参数，不经过 shell。`${plugin_dir}` 替换为 manifest 所在目录 |
| `capabilities` | 声明已经实现并验证的能力。当前必须支持 `conversations.list`、`messages.read` |
| `desktop.strategy` | `ax-ocr-v1`：辅助功能读写输入框 + 顶部栏 OCR。`screen-ocr-v1`：客户端不开放辅助功能时，输入栏和顶部栏都靠截图识别，按 Tab 时粘贴；宿主要有这个客户端的界面规则，目前只有 Telegram for macOS（`ru.keepcoder.Telegram`） |
| `desktop.bundle_ids` | 客户端应用 Bundle ID，用于前台应用路由；不能留空 |
| `desktop.header` | OCR 区域参数，单位为点，相对窗口与输入框 |
| `desktop.overlay` | 灰字字号和位置偏移 |
| `desktop.send_shortcut` | 客户端原有发送键，用于用户发送后的建议失效检测；不是插件发消息的命令 |
| `limits` | 命令超时与会话列表缓存时长 |

`setup.commands` 里的命令在用户点「在终端中运行」时执行，`${plugin_dir}` 替换为插件所在目录（已加引号），`${input}` 替换为用户填写的内容。

`composer.read`、`composer.apply`、`overlay.inline` 是**插件与宿主组合后的能力**：插件通过声明桌面配置，使用 Swift 宿主已有的输入框读取、填入和灰字浮层。它们不是插件命令，也不代表通过消息 API 读取草稿或发送消息。插件不能仅因其他客户端也有输入框就声明这些能力，必须实际验证。

桌面快捷键建议要求 `composer.read` 和 `composer.apply` 同时为 `true`。缺少任意一项时，插件仍可注册、检测消息读取并在成功后启用，但页面标注「仅支持消息读取」，宿主不注册桌面建议快捷键，也不预取当前桌面会话。`overlay.inline=false` 且具备两项输入框能力时降级为建议气泡。

`events.subscribe` 必须为 `false`；当前框架不消费事件流，声明 `true` 会被拒绝加载和导入。

## 注册、启用和路由

`~/.tact/config.json` 的顶层 `platforms` 存放用户导入的插件实例，新安装是空数组：

```json
{"platforms": []}
```

用户选择插件包后，宿主复制到用户插件目录，注册独立实例并默认停用，例如：

```json
{
  "platforms": [
    {
      "id": "custom-example",
      "manifest": "/绝对路径/用户插件目录/manifest.json",
      "enabled": false
    }
  ]
}
```

- `manifest` 使用绝对路径。插件不是应用内置资源；用户主动导入后才加入列表。
- `command` 可选，用数组覆盖 manifest 的 `entrypoint`；适合部署人员配置不同运行时，不经过 shell。普通用户通过插件指引安装和登录，无需编辑 JSON。
- `desktop` 可选，与 manifest 的 `desktop` 同形，用于该实例的 Bundle ID、OCR 区域与灰字位置覆盖；由桌面宿主消费。
- `platforms` 缺省或为空数组都表示没有聊天工具；新安装和 `setup.sh` 首次生成的配置都是 `platforms: []`。
- 用户可同时启用不同客户端的平台，宿主根据前台 Bundle ID 选择插件。相同 Bundle ID 命中多个已启用实例时需先消除冲突，不猜测账号归属。
- 在「聊天工具 → 添加」拖入插件文件夹或它的 `.zip`（也可以选择包含插件文件夹的上一级目录）。导入只做校验和注册，默认停用，不执行插件或读取消息。用户打开开关或点「检测并启用」时，宿主先运行检测命令读取真实会话列表，通过后才启用。

导入不是安全审核。外部插件以当前用户权限运行，**不是权限沙箱**；manifest 的能力声明也不会限制脚本的实际文件或网络访问。只导入信任的代码，不附带、打印或记录登录凭据。只把必要上下文交给已配置的模型。

## `command-v1` 操作

宿主在 `entrypoint` 后追加操作名和参数，标准输出必须是单个 UTF-8 JSON 对象，不应混入调试日志；日志与错误写入标准错误，并避免凭据、access hash 和聊天正文。

插件以用户终端里的环境运行：引擎启动时在后台以交互登录方式运行一次用户的默认 shell（`$SHELL -i -l`，不支持的 shell 改用 zsh），取它读完启动文件后的环境变量，包括 `PATH`、代理设置等。所以插件依赖的命令行工具，只要在终端里能直接运行，插件里也能找到，不必自己拼 `/usr/local/bin`、`/opt/homebrew/bin` 之类的目录。读取期间设置了 `TACT_RESOLVING_ENVIRONMENT=1`，用户可以在启动文件里据此跳过只适合真实终端的内容；超过 10 秒或失败时，改用应用自己的环境，并在 `PATH` 末尾补上 `~/.local/bin`、`/opt/homebrew/bin`、`/usr/local/bin`。

### `chats`：会话列表

```bash
python3 adapter.py chats
```

```json
{
  "chats": [
    {"id": "1001", "title": "示例联系人", "type": "private", "last_message_at": "2026-10-12T10:05:42+08:00", "unread": 2}
  ]
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `id` | 是 | 稳定的会话 ID，字符串或数字 |
| `title` | 是 | 与客户端顶部栏一致的显示名，包括备注名；OCR 与它唯一匹配才继续 |
| `type` | 否 | `private`、`group` 或 `channel` |
| `last_message_at` | 否 | 最近消息时间 |
| `unread` | 否 | 未读数 |

不要只用标题生成 ID，同名会话仍需不同 ID。没有可靠唯一匹配时宿主拒绝生成建议。

### `history <chat_id> <limit>`：最近消息

```bash
python3 adapter.py history 1001 20
```

```json
{
  "messages": [
    {"id": "m101", "sender": "示例联系人", "from_me": false, "text": "下午的发布评审你能来吗？", "time": "2026-10-12T10:02:00+08:00"},
    {"id": "m102", "sender": "我", "from_me": true, "text": "可以，几点？", "time": "2026-10-12T10:03:10+08:00", "reply_to": "m101"}
  ]
}
```

返回最近 `limit` 条。顺序不限，有 `time` 时引擎按时间排序。

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `id` | 是 | 稳定消息 ID；引擎用它标识上下文及支持显式 `check` 查询，桌面宿主不因新消息撤销建议 |
| `text` | 是 | 文字；媒体可写 `[图片]`、`[文件 example.pdf]` 等摘要 |
| `from_me` | 是 | 是否由当前登录用户发出 |
| `sender` | 否 | 发送人显示名 |
| `time` | 否 | RFC 3339 字符串，或 Unix 秒 / 毫秒数字 |
| `reply_to` | 否 | 被回复消息的 ID |
| `mentions_me` | 否 | 是否 @ 当前登录用户 |

当前协议没有完整消息修订版本，不能保证识别编辑或删除，也没有统一账号和话题接口。需要这些能力时再扩展协议，不能把最新消息 ID 当成完整上下文版本。

### `drafts`：平台草稿列表（可选）

```bash
python3 adapter.py drafts
```

```json
{"drafts": [{"chat_id": "1001", "text": "还要测试"}]}
```

当输入框有字时，引擎用它做额外校验：若另一个会话的草稿与输入框内容相同，可能识别错会话，本次不生成建议。不支持就返回退出码 3。

这与宿主从 AX 读取**当前输入框**的 `composer.read` 能力不同。

### `health`：本地状态检查（可选扩展）

```bash
python3 adapter.py health
```

```json
{"available": true, "authentication": "signed_out", "message": "还没登录，运行「扫码登录」"}
```

只检查本地状态（依赖是否就位、是否保存过登录信息），不联网、不读账号或聊天、不验证登录。此操作不是连接成功的证明；页面的连接测试显式调用 `chats`，会读取真实会话列表。

### 退出码

| 退出码 | 含义 |
| --- | --- |
| 0 | 成功，标准输出是 JSON |
| 3 | 不支持操作；引擎只对可选 `drafts` 跳过处理 |
| 其他 | 失败，标准错误用于显示错误信息 |

## 建议与填入边界

路由、消息缓存与建议需绑定平台实例，避免不同平台相同会话 ID 互相复用。当前会话、输入框和消息检查仍由宿主完成；切换平台、停用实例或改变配置时应使旧建议失效。用户按 Tab 才会填入，发送始终由用户完成。

当前 AX/键盘/粘贴路径不提供原子 `composer.apply` API，也不是严格的多账号快照协议。宿主在显示和填入前核验会话及输入框，并读回核对写入结果；对方新消息不会撤销已有建议。不要把它宣传成支持事务写入、所有输入法状态或全部并发变化。

## 可选接入说明

manifest 可选 `setup` 元数据向普通用户说明前置条件，而不要求修改 JSON：

```json
{
  "setup": {
    "summary": "接入前，请联系提供方安装 CLI 并完成登录。",
    "requirements": ["已安装桌面客户端", "已安装提供方 CLI 并登录"],
    "help_url": "https://example.com/integration-guide",
    "commands": [
      {"title": "安装连接组件", "command": "提供方已核实的单行安装命令", "detail": "在终端执行；已安装可跳过"},
      {"title": "登录", "command": "provider-cli login ${input}", "input_placeholder": "你的账号邮箱", "detail": "复制后粘贴到终端，按提示完成验证"}
    ]
  }
}
```

`summary`、`requirements`、`help_url` 用于指引展示。没有 `commands` 时可以用 `steps` 写一列手动步骤；有 `commands` 时宿主只展示命令，不再重复 `steps`。帮助链接应指向提供方的真实官方指引；没有真实链接时省略，不能把示例地址当成可用服务。

可选 `commands` 按顺序列出准备命令，每条都有「在终端中运行」和「复制」，只在用户点击时执行：宿主写一个临时 `.command` 脚本交给「终端」打开，脚本先原样显示命令再执行，并在开始时删除自身。每项包含 `title`、单行 `command`、可选 `detail` 与 `input_placeholder`。命令含 `${input}` 时先让用户填写信息，再以单引号安全引用替换占位符；输入只在当前视图内存中使用，不写入配置或插件。输入 trim 后最多 512 字，禁止嵌入控制字符；命令最多 8192 字且不能含控制字符。提供方应核实命令、安装目录、运行时和交互登录步骤，不要放入真实账号或密码。

## 自测

新安装没有平台注册。查看用户导入的实例，不执行插件：

```bash
engine/bin/tactd platforms
```

导入插件后，即使实例停用，也可显式使用 `platforms` 返回的实例 ID 检查会话读取能力：

```bash
engine/bin/tactd platform-test --platform-id 实际实例ID
```

这个测试会运行插件并读取真实会话列表，停用状态也允许执行。检测成功并启用后，`check --platform-id 实际实例ID` 还会读取消息并测试模型。接入完成后，先在客户端的真实窗口开启测试模式验证唯一会话匹配，再关闭测试模式生成建议。

开发插件时，先在终端直接运行它的命令（如 `python3 adapter.py chats`）确认输出是单个 JSON 对象；宿主自身的离线测试运行 `./scripts/test.sh`，全部使用假数据。
