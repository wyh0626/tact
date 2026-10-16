# Tact 使用说明

在已启用的聊天工具里触发快捷键，输入框旁出现一句回复建议，按 Tab 填入，由你自己发送。平台通过插件接入，自定义聊天工具在用户主动导入后加入列表。

- **输入框为空**：根据最近的聊天给一句整句建议，显示成光标后的灰字。
- **输入框有几个字**（比如"婉拒""还要测试，别承诺"）：把这几个字当作你的意图，改写成完整的回复，显示在输入框上方的气泡里。
- **没有合适的建议**：提示"这次不建议"，不硬凑。
- **任何情况下都不会替你发送。**

需要 macOS 14 及以上。微信通过内置的聊天区截图识别接入，钉钉通过内置的辅助功能读取接入；Telegram 有一个实验性插件（`plugins/telegram`）；飞书、Slack、Discord 暂未支持。其他 IM 按 [平台适配器规范](ADAPTER.md) 开发插件后导入。

## 工作方式

```
前台聊天工具 ──Bundle ID 路由──▶ 已启用的平台实例
                                ├── 桌面配置：AX 输入框、顶部栏 OCR、浮层参数
                                └── 消息连接器：command-v1 外部命令
                                         │ 统一会话、消息 JSON
                                         ▼
                              tactd（Go 引擎）──▶ 所选模型
                                         │
                                         ▼
                              Tact.app 建议浮窗 / 灰字
                                         │ 用户按 Tab
                                         ▼
                                  当前输入框草稿
```

当前桌面桥接策略使用辅助功能读取输入框，用本机 OCR 识别聊天顶部栏：

1. 应用截取聊天顶部栏，用 macOS 自带的 Vision 在本机识别会话名；
2. 引擎拿识别结果和插件给的会话列表匹配，只有唯一匹配才继续；
3. 引擎通过插件拉这个会话最近 20 条消息，连同你的意图和表达偏好一起交给模型；
4. 建议绑定在生成时的会话和输入框上。**显示前、按 Tab 写入前各核对一次**：会话或输入框不对就不显示、不写入。

## 上手

### 界面语言

支持「跟随系统」「简体中文」「English」，默认跟随 macOS 的语言偏好；没有匹配的语言时使用英文。欢迎页和「设置 → 通用 → 语言」都可以切换，立即生效并在下次启动时保留。

切换界面语言会保留模型设置、表达风格和未保存的草稿。回复默认跟随会话本身的语言：日文聊天写日文，韩文聊天写韩文；用中文打几个字表达意图时，回复仍然用会话的语言，只有明确要求翻译时才换。默认的表达风格按回复语言分别给出写法（中文参考 humanizer-zh，英文参考 humanizer），从没改过的旧默认风格文件会自动换成新版，改过的不会被翻译或覆盖。英文环境首次启动会使用英文风格示例。插件提供的名称、准备步骤和外部错误信息按原文显示。

### 从源码启动

需要 Go 1.24+（`brew install go`）和 Xcode 命令行工具（`xcode-select --install`）。

```bash
./scripts/setup.sh
```

它会编译引擎、打包出 `dist/Tact.app`，并在 `~/.tact/` 下生成 `config.json` 和 `style.md`。首次安装的 `platforms` 是空数组，导入插件前不会执行任何插件命令。

### 1. 先在终端里验证平台注册（可选）

```bash
engine/bin/tactd platforms          # 只看平台注册和启用状态，不执行插件
```

新安装没有已注册的平台是正常状态。导入一个插件后，可用上面的命令查看系统生成的实例 ID；需要在终端显式测试真实连接时再运行：

```bash
engine/bin/tactd platform-test --platform-id 实际实例ID  # 会读取该平台真实会话列表
```

检测成功并启用后，`tactd check --platform-id 实际实例ID` 还会读取最近消息并调用模型；`suggest --platform-id 实际实例ID --title "真实会话名称"` 会把该会话最近消息交给所选模型。在终端里调用模型时，引擎从环境变量（`model.api_key_env`，默认 `TACT_API_KEY`）读 API Key。

### 2. 打开应用，跟着引导走

```bash
open dist/Tact.app
```

第一次打开会出现引导：

1. **授权**：给 Tact 打开两个权限。授完屏幕录制要重启一次应用，引导里有按钮，重启后回到原来那一步。

   | 权限 | 用途 |
   | --- | --- |
   | 辅助功能 | 读写输入框、取光标位置、拦截 Tab 和 Esc、识别双击快捷键 |
   | 屏幕录制 | 截取聊天顶部栏，在本机认出当前会话 |

2. **模型**：用 **ChatGPT 账号**登录（用 Plus / Pro 套餐额度，不需要 API Key）；或者选「本机」，在列表里下载一个模型，聊天内容不出这台 Mac；或者选择云端服务，填写地址和 API Key（存进 macOS 钥匙串），点模型旁的刷新按钮读取列表，下拉选择或手动填写模型 ID。自定义接口要明确选择协议。再点「测试并继续」。
3. **试一试**：一段模拟的朋友聊天（小林约你周六吃火锅）。在这里按快捷键看灰字、按 Tab 填入，再打「拒绝」两个字按快捷键，看它改写成一句得体的婉拒，再按回车「发出去」。用的是刚配好的真实模型，连不上时用示例演示；消息只在 Tact 的窗口里，不会发出，也不记进统计。
4. **聊天工具**：把 IM 提供的插件（文件夹或 .zip）拖进「添加聊天工具」。导入后插件停用，展开它按「准备」里的步骤安装、登录，再打开开关：Tact 先检测连接，通过才启用。

之后点菜单栏里的小狗图标打开快捷面板：开关聊天工具、切换推理档位都在这里；齿轮或 ⌘, 打开完整设置，大部分改动立即生效。菜单栏图标太多时，小狗可能被刘海挡住，这时再打开一次 Tact（在访达里双击，或用聚焦搜索）会直接弹出设置窗口。

**签名与权限。** 没有苹果开发者账号时，应用用的是本地签名。macOS 把权限绑在签名上，临时签名每次重新打包都会变，权限就得重新授一次。运行一次下面的脚本，在你的登录钥匙串里创建一个只在本机有效的固定证书，之后 `build-app.sh` 都用它签名，权限就能保留：

```bash
./scripts/create-signing-identity.sh
```

**引擎。** 应用会启动安装包里自带的引擎（配置里写了 `app.engine_command` 时用它），并把钥匙串里的 API Key 通过环境变量交给引擎。日志在 `~/.tact/engine.log`。

### 3. 接入聊天工具

聊天工具通过插件接入：一个包含 `manifest.json` 和实现脚本的文件夹。在「聊天工具 → 添加」里把插件文件夹或它的 `.zip` 拖进来（也可以点「选择插件…」）。导入只校验和登记，不运行插件，插件默认停用。插件以当前用户权限运行，不是权限沙箱，只导入信任的来源。

导入后列表里会展开这个插件：

1. **准备**：插件在 manifest 的 `setup` 里写的前置条件和命令。每条命令可以「在终端中运行」（打开一个终端窗口，先显示命令再执行，执行完脚本自行删除）或「复制」；需要填写的信息（如账号邮箱）先填在输入框里。
2. **检测并启用**：打开开关或点这个按钮时，Tact 先运行插件读取会话列表（不发送任何消息），通过才启用；失败的原因显示在这一行。
3. **会话识别校准**：建议出现在错误的会话时，用测试模式和顶部栏位置校准。

自定义插件缺少 `composer.read` 或 `composer.apply` 时仅支持消息读取，不启用桌面快捷键建议；`overlay.inline=false` 且具备这两项能力时使用建议气泡。当前拒绝 `events.subscribe=true` 的插件。插件开发模板在 `plugins/template/`，所有能力默认关闭，需要开发者完成实现后再导入，详见 [平台适配器规范](ADAPTER.md)。

还没有插件时，「添加」面板底部的「复制开发说明」会复制一段给开发者的说明（协议要点、示例 manifest 和模板位置），转给这个 IM 的开发者或技术同事即可。

### 微信（内置）

微信没有插件接口，Mac 版 4.1 也不向辅助功能开放界面，所以 Tact 直接读它的窗口：在「聊天工具 → 内置」里打开微信，需要屏幕录制权限。

- 按快捷键时截一次微信窗口，用分隔线定位当前聊天栏和输入框，仅识别这片区域。聊天区内的 OCR 文字保留相对坐标，交给当前所选 AI 判断发送人、消息换行、群聊昵称、时间和系统提示，并在同一次请求里生成建议；本机不再用气泡颜色来判断消息归属。
- 发给模型的是会话名、聊天区的文字与位置、单独读取的输入框草稿，不上传截图，也不包含左侧其他聊天的预览。继续兼容文本模型，无需另配图片模型。
- 输入框里的字当作意图。建议显示在输入框上方的气泡里，按 Tab 粘贴进去（有字时先全选再替换），Esc 或继续打字就关掉。显示前和粘贴前都会重新读一次会话名和输入框，变了就作废。
- 只读得到窗口里看得到的文字；识别也可能出错，打开「测试模式」后按快捷键，只显示会话名、画面文字数量、末尾几段文字和输入框，不调用 AI，也不在本机猜测发送人。
- 不解密数据库、不注入微信、不模拟点击，也不发送消息。微信更新改了界面时可能读不出来，可以用 `Tact --inspect-app com.tencent.xinWeChat 报告.json` 生成一份只有位置和数量、不含文字的诊断报告。

### 钉钉（内置）

钉钉的 Mac 客户端向辅助功能开放了界面，Tact 直接读它：在「聊天工具 → 内置」里打开钉钉。不需要钉钉的开放平台应用，也不需要管理员开通任何权限。

- 按快捷键时通过辅助功能读出当前会话名、消息列表里已加载的消息（发送人、是不是我发的，按头像在左还是在右判断）和输入框里的草稿，交给所选 AI 生成建议。
- 加载动画和灰字按输入框里实际显示的内容定位：有草稿时接在最后一个字后面，没有时放在「请输入消息」开头，所以和窗口大小、布局无关。
- 辅助功能读不到会话时（比如钉钉更新改了界面），改用截图识别：定位右侧聊天栏、标题栏和输入区，聊天背景上的水印会被过滤掉。这时需要屏幕录制权限。
- 显示前和粘贴前同样会重新读一次会话名和输入框，变了就作废；按 Tab 粘贴，从不发送。测试模式下按快捷键，会显示读到的会话名、消息条数和最后几条是谁发的，不调用 AI。
- 读出来不对时，可以用 `Tact --inspect-app com.alibaba.DingTalkMac 报告.json` 生成诊断报告（Mac App Store 版的 Bundle ID 是 `5ZSL2CJU2T.com.dingtalk.mac`），里面有消息表格的结构和读取器两次读取是否一致，不含文字。

### Telegram（插件，实验性）

`dist/plugins/telegram`（源码在 `plugins/telegram/`）用你自己的账号通过 Telegram 官方 API 读取会话和最近消息：只读，不发送、不修改、不标记已读。**还没有在真实账号和窗口上完整验证**，Telegram 界面的识别规则（顶部栏、输入栏位置）可能需要调整。

1. 在「聊天工具 → 添加」里拖入 `dist/plugins/telegram`。
2. 展开后点「扫码登录」的「在终端中运行」：手机 Telegram → 设置 → 设备 → 关联桌面设备，扫终端里的二维码。开发版第一次会先要 `api_id` / `api_hash`（[my.telegram.org](https://my.telegram.org) 申请，只存在本机）。
3. 打开开关（会先读一次会话列表确认能用）。

Telegram for macOS 不开放辅助功能，所以桌面端和微信一样靠截图：识别顶部栏的会话名去匹配会话列表，找到输入栏和里面的字，按 Tab 粘贴。登录信息在 `~/.tact/telegram/`（只有你能读），手机 Telegram 的「设备」列表里能看到并随时结束名为 Tact 的会话。

### 4. 验证会话识别并生成建议

1. 导入、检测成功并启用插件后，打开对应桌面客户端里的真实会话。
2. 菜单栏 → 勾选 **OCR 测试模式**，或在聊天工具高级设置中打开。这个模式只识别和匹配，不生成建议。
3. 点一下当前会话的输入框，按快捷键。浮层显示识别文字、匹配结果和耗时。
4. 认不出来时，选择 **保存下一次顶部栏截图** 后再次触发，检查 `~/.tact/debug/` 的区域；在「聊天工具 → 高级设置与会话识别调试」调整顶部栏位置并保存。
5. 匹配正确后关闭 OCR 测试模式，按快捷键生成建议，按 Tab 填入，再由你发送。

离线开发测试运行 `./scripts/test.sh`，全部用假数据，不读取真实聊天。

## 使用

| 操作 | 按键 |
| --- | --- |
| 生成建议 | 快捷键（只在已启用的平台客户端在前台时生效，在 `app.hotkey` 里设置，默认 `double+ctrl` 是双击 ⌃）。输入框为空时建议显示成光标后的灰字；写了几个字时按意图改写，显示成气泡 |
| 接受 | `Tab`：写入输入框，光标移到末尾 |
| 取消 | `Esc`：生成中取消生成；建议显示时作废这条建议 |
| 其他按键 | 建议作废，按键照常交给当前聊天工具 |
| 点击 | 建议保留；点到别的会话时先收起，回到原会话自动出现 |

按下快捷键后，输入框上方左侧会出现一个小胶囊显示进度：先是「正在读取聊天」，再是「正在生成」，超过 3 秒加上已用秒数和「Esc 取消」；限流时提示会说明大约多少秒后可以再试。

生成时可以放心切走。切到别的应用或别的会话，生成不会停；生成完或者已经显示的建议会先存在内存里，菜单栏图标右下角显示空心圈表示正在生成，实心点表示建议已准备好。回到原来的会话、输入框和生成时一样，建议就会自动出现。等待中的建议遇到这些情况会作废：输入框内容变了、超过 5 分钟、在任何聊天工具里又生成了一次（只保留最新的一条）。会话里来了新消息不会作废建议，需要的话自己按快捷键重新生成。显示中的建议没有时间限制，点击也不会让它消失，只有打字、按 Esc 或重新生成才会作废。你不在时生成失败，回到这个聊天工具时会提示一次原因。

灰字生成后会挂在这个会话上：接受后又删光、打字后又删光、切走再切回来，只要输入框是空的，灰字就会重新出现，不用重新生成。按回车发出消息、按 Esc、重新触发，或者过了 10 分钟，这条建议才作废；对方发来新消息不会撤销建议。

支持灰字的插件会先尝试在输入框内完整换行显示，只有宽度或高度不足时才改用气泡，不截断建议。意图改写和不支持行内展示的插件使用气泡。

输入框里有字时按快捷键是**改写**：几个字（如「婉拒，下周再说」）当作意图，扩写成一句得体的话；写好的长草稿（80 字以上）保留全部内容和立场，只修语句、错字和语气，长度与原稿相近。按 Tab 替换整个输入框。草稿最多 2000 字，更长的请先分成几条。气泡放不下的长建议只显示开头和总字数，填入后在输入框里检查。微信和 Telegram 的草稿靠截图读取：草稿超出输入框可见范围、可能没读全时，按 Tab 只复制建议，不替换输入框，避免丢掉没读到的部分。

灰字或气泡里出现 ⚠︎ 标记时注意看一眼（灰字里是简写：含承诺、含链接/号码）：

- **含承诺**：建议里有时间、结果之类的承诺。
- **含链接、邮箱或长数字**：防止被对方诱导发出敏感信息。

已启用且具备桌面能力的平台在前台时，应用会提前认出当前会话、拉好消息（预取），按快捷键后只等模型这一步。切换会话（点击、方向键、⌘/⌥/⌃ 组合键、回车发送）后会重新截一次顶部栏；停在同一个会话时，每 15 秒按会话 ID 刷新一次消息，90 秒没有操作就停止刷新。预取只在本机读消息，不会发给模型，也不会因为发现新消息而撤销已有建议。

菜单栏 → **统计**：触发次数、采纳率、原样发出的比例、引擎耗时，对应技术方案里的成功指标。

## 配置

常用的选项都在设置窗口里。下面是 `~/.tact/config.json` 里的完整说明，示例见 [config.example.json](../config.example.json)：

| 键 | 说明 |
| --- | --- |
| `platforms` | 导入的插件实例数组：`id`、manifest 绝对路径、`enabled`，可选 `command` 与 `desktop` 覆盖。新安装为 `[]`；缺省或空数组都表示没有聊天工具。当前按前台 Bundle ID 路由，同一客户端多个实例不自动区分账号。详情见 [平台规范](ADAPTER.md) |
| `model.provider` | 服务商标识：`openai`、`deepseek`、`anthropic`、`gemini`、`zhipu`、`moonshot`、`qwen`、`doubao`、`siliconflow`、`openrouter`、`minimax` 或 `custom`。旧配置缺省或空值仍走 OpenAI 兼容接口。`chatgpt` 使用账号登录和套餐额度；`local` 由内置 llama-server 运行 |
| `model.protocol` | API Key 连接的请求协议：`openai`（Chat Completions）、`responses`（OpenAI Responses）、`anthropic`（Claude Messages）、`gemini`。缺省兼容旧配置：Claude / Gemini 使用原生协议，其余使用 Chat Completions |
| `model.local.path` | `local` 时模型文件（.gguf）的位置，设置里下载的模型在 `~/.tact/models/`。`model.local.context_size` 是上下文长度，默认 8192 |
| `model.base_url` / `model.model` | 接口基址和模型名。Claude 默认 `https://api.anthropic.com`，Gemini 默认 `https://generativelanguage.googleapis.com`；两者不填完整的模型请求路径。自定义网关填写该协议的基址。`chatgpt` 时地址是 `https://api.openai.com/v1`，模型从登录账号可用的列表里选 |
| `model.allowed_base_urls` | **模型端点白名单**。`base_url` 不在里面，引擎拒绝启动。换公司网关时两处都要改 |
| `model.api_key_env` | 引擎读 API Key 的环境变量名，默认 `TACT_API_KEY`。应用会把设置里存进钥匙串的 Key 放进这个变量；在终端里单独跑引擎时自己设置它 |
| `model.api_key_account` | 应用使用的钥匙串条目标识，不含 Key。新连接按服务商、协议和地址来源隔离；旧配置继续使用原条目，普通保存不迁移或删除旧 Key |
| `model.headers` | 高级设置中的额外请求头，JSON 对象且值为字符串。API Key 使用专门字段填写，不能借此覆盖鉴权、Cookie、内容类型或连接控制头 |
| `model.append_no_think` | 用 Qwen3 这类思考模型时设为 `true`，关掉思考以降低延迟 |
| `model.json_mode` | OpenAI 兼容接口支持 `response_format` 时可以打开；Gemini 映射为 JSON 响应类型。Claude 原生通道暂不支持通用 JSON 模式，设为 `true` 会明确报错 |
| `model.max_tokens` | 输出上限；旧配置默认 300，新选云端连接默认 4096，可在高级设置调整。Claude 思考预算不足时请求会提高上限，为预算和最终回复留出空间；Responses 协议映射为 `max_output_tokens`；Chat Completions 服务拒绝 `max_tokens` 并要求 `max_completion_tokens` 时改用后者。ChatGPT 账号通道忽略此项 |
| `model.timeout_ms` | 请求超时毫秒数；旧配置默认 20000，新选云端连接默认 60000，可在高级设置调整 |
| `model.reasoning_effort` | 旧配置和 OpenAI / DeepSeek / ChatGPT 账号使用的推理程度，如 `low`、`medium`、`high`；空着用模型默认。ChatGPT 账号发 `reasoning.effort`，Chat Completions 发 `reasoning_effort`。DeepSeek 选关闭时用 `extra_body.thinking.type=disabled`。Claude / Gemini 原生通道使用下方 `model.reasoning`，不映射此旧字段 |
| `model.reasoning` | 可选对象：`format` 选择参数格式，`effort` 选择档位；预算模式另有 `budget_tokens`，Claude 另有 `thinking_type`。缺省时保持旧配置行为；界面选「默认」时清除请求中该格式的推理覆盖值。只适用于 API Key 通道 |
| `model.capability_cache` | 应用保存的选中模型接口能力快照，按模型、服务商、协议、完整地址、钥匙串条目和请求头指纹匹配；不含 API Key。界面标为「上次接口返回」，手动刷新会更新 |
| `model.service_tier` | 设为 `priority` 开启快速模式（Fast mode）：出结果更快；用 ChatGPT 套餐时会更快消耗额度，用 API Key 时按更高价格计费。Claude / Gemini 原生通道不映射此字段，非空会报错 |
| `model.extra_body` | 高级设置中的服务商专用请求参数，JSON 对象，按所选协议填写。消息、模型、流式开关等字段由适配器管理；原生协议的温度和输出上限由专门配置管理。API Key Responses 默认不发送温度，需要时可在这里显式设置 |
| `context.history_cache_seconds` | 预取的消息在多少秒内可以直接用来生成，默认 20；设为 0 则每次都现拉 |
| `style.file` | 表达偏好，见 `~/.tact/style.md` |
| `style.chat_sections` | 按会话名或会话 ID 指定用 style.md 里的哪一段 |
| `app.hotkey` | 组合键如 `option+space`、`ctrl+shift+g`；双击修饰键如 `double+ctrl`（默认）、`double+option`、`double+cmd`、`double+shift`。双击 ⌃ 只在听写设成「按两下 Control」时冲突；双击 ⌥ 是 Claude 桌面版快速输入的默认键；双击 ⌘ 可能和 Siri 的「按两下 Command」冲突；双击 ⇧ 会让中文输入法来回切换中英文 |
| `app.insert_method` | `auto`（默认）：用普通键盘布局时，短的单行建议模拟逐字输入，完全不碰剪贴板；开着中文等输入法、或者建议较长时用粘贴。`paste`：总是粘贴。`ax`：直接写辅助功能值，失败再粘贴。粘贴时剪贴板内容只留在本机、带「临时」标记，剪贴板历史工具会跳过；等文字确实进了输入框才恢复原来的剪贴板，这期间你复制了新内容就不恢复；原来是密码管理器标记的密码时，只清空不恢复。每次写入后都会读回核对 |
| `app.wechat` | `true` 时在微信里也能用（截图识别，见上文「微信」），默认 `false` |
| `feedback.log_plaintext` | 默认 `false`：反馈日志只记长度、耗时、编辑距离，不记任何聊天文字 |

直接改文件的话，改完重启应用。在设置窗口里改的会自动生效。

API Key 的 Chat Completions 调用使用 Eino 模型组件；Claude、Gemini 和 API Key Responses 直接调用各自的 HTTP 接口。模型对可选参数的支持不按模型名判断：服务因温度、`top_p` 等采样参数或 `max_tokens` 返回 400 并点名这个参数时，引擎去掉它重发一次，并在引擎运行期间对同一地址、模型和推理设置记住；其他错误照常显示。ChatGPT 账号登录继续使用原有认证和 Responses 通道，本机模型继续使用内置 `llama-server`。已有配置无需迁移，普通保存不会自动改变旧接口协议。

设置 → 模型：预设 OpenAI、DeepSeek、Claude、Gemini、智谱、Kimi、通义千问（百炼）、豆包、硅基流动、OpenRouter 和 MiniMax。预设提供常用标准 API 地址，地区网关、工作空间地址和 Coding Plan 地址可以自行修改。填好 Key 和地址后，点模型旁的刷新按钮读取列表；列表不可用时仍可直接输入模型 ID，刷新也不会覆盖手动输入的模型。

模型列表接口返回的能力优先使用，明确返回“不支持”时不显示对应控件；接口缺少的字段用服务商的通用档位补充：Claude、Gemini 协议和 OpenAI、DeepSeek、通义千问预设各有一套固定的参数格式，不按模型名推断。各模型参数格式不同的服务商（智谱、Kimi、MiniMax 等）和自定义网关，只在接口返回能力时显示控件，专用参数可以在高级设置填写。模型不支持所选档位时由接口报错。界面标明能力来源。Claude 可提供思考类型和 effort 支持信息，Gemini 只说明是否支持思考。选中模型的接口能力会随连接保存，重新打开设置或快捷面板仍可使用，并标注为上次接口返回；刷新后更新。

**自定义接口**明确选择 OpenAI Chat Completions、OpenAI Responses、Claude Messages 或 Gemini 协议，再填对应基址。这决定请求路径、鉴权方式和参数结构；厂商专用字段放在折叠的「高级设置」，不再要求普通用户选择 `reasoning_effort` 等参数格式。OpenAI 兼容本机网关可不填 Key；Claude / Gemini 原生协议需要 Key。

**推理与速度**按当前能力显示档位或思考预算，接口说明不能关闭思考的模型不显示关闭选项。快捷面板可以切换档位，预算在完整设置修改。思考和最终回复可能共享输出上限，较深档位可在高级设置提高输出 Token 上限或请求超时。预算范围采用接口返回信息，缺少时使用应用支持的范围：Claude 1,024–32,768，Gemini 1–32,768 或 -1（动态）。

普通保存保留已有推理配置和手写额外参数。修改推理控件才写入 `model.reasoning`；直接修改高级设置中的推理字段会交回手写参数控制，之后再改控件可恢复界面控制。切换服务商会清除上一连接的临时 Key、额外请求头和推理覆盖，已保存的 Key 留在原连接的钥匙串条目里；切换协议还会清除已知不兼容的原生字段。读取模型列表使用当前连接凭据，不把其他连接的旧 Key 自动发往新地址。

## 本机模型

设置 → 模型 → **本机**：Tact 内置了 [llama.cpp](https://github.com/ggml-org/llama.cpp) 的 `llama-server`，在列表里下载一个模型就能用，不需要另装 Ollama。

- 列表按这台 Mac 的内存推荐模型：8 GB 用 Qwen3 1.7B（1.1 GB），16 GB 用 Qwen3 4B（2.5 GB），24 GB 以上用 Qwen3 8B（5 GB）。选「本机」不会自动下载，点了下载才开始；已经下好的模型会被优先选用。
- 下载可以暂停，退出应用后也能接着下；下完按 sha256 逐字节校验，没通过就丢弃。Hugging Face 连不上时自动换 hf-mirror.com，校验保证内容一致。下载前会检查磁盘空间。
- 引擎启动时在后台加载模型：只监听 127.0.0.1，每次启动随机生成访问密钥（经环境变量传入，不出现在进程参数里），引擎退出时一起关掉；引擎被强制结束留下的进程，下次启动时清理。
- 第一次启动要编译 GPU 代码再加载模型，可能要十几秒；之后回复一般在几秒内。Qwen3 1.7B / 8B 的「思考」模式已关闭，写回复用不着。

开发时运行 `scripts/build-llama.sh` 从固定版本（llama.cpp v0.6.0）编译 `engine/bin/llama-server`；`build-app.sh` 会调用它并把运行时打进应用。

## 用 ChatGPT 账号登录

按 OpenAI 的 [Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source) 开源 / 本地应用流程实现：

- 设置 → 模型 → ChatGPT 账号 → **Continue with ChatGPT**，在浏览器里登录并授权。引擎在本机 `127.0.0.1` 上接收回调（OAuth 授权码 + PKCE），第一次登录时动态注册应用。
- 令牌存在 `~/.tact/chatgpt.json`（权限 600），快过期时自动刷新；退出登录会向 OpenAI 吊销并清掉本机令牌。
- 请求走 `https://api.openai.com/v1/responses`，用的是你 ChatGPT 套餐的额度，可以在 [ChatGPT 设置 → 用量](https://chatgpt.com/settings/usage) 里给这个应用设上限。用量到上限时建议会提示，不会悄悄换成别的计费方式。
- 只支持 ChatGPT 账号可用的模型；这条通道不接受 `temperature`、`max_tokens` 等参数，所以这两项配置在 `chatgpt` 时不起作用。
- 每个模型支持哪些推理档位、有没有快速模式，由 OpenAI 的模型列表提供，设置里按所选模型显示。
- 应用的引擎和终端里单独运行的 `tactd` 共用这份登录信息：用之前会检查文件有没有被另一个进程更新过，刷新时加文件锁，不会出现两边同时刷新、把对方登出的情况。

## 隐私

- 聊天内容只发往 `model.allowed_base_urls` 白名单里的地址；模型接口返回重定向时拒绝跟随。
- API Key 存在 macOS 钥匙串里；ChatGPT 登录的令牌存在 `~/.tact/chatgpt.json`（权限 600），都不写进配置文件和日志。
- 顶部栏截图只在内存里做 OCR，不落盘（除非你在菜单里手动保存一次用于调试）。微信窗口的截图同样只在内存里识别，不保存。
- 反馈日志默认不含任何聊天文字，会话 ID 也做了哈希。
- 应用日志 `~/.tact/app.log` 不记会话名和内容；OCR 测试模式的识别结果只打印在终端。
- 引擎 socket 权限是 600，只有你自己的账号能连。
- 检查更新由 [Sparkle](https://sparkle-project.org) 访问 GitHub 上最新版本的 `appcast.xml`，请求里只有 Tact 和 Sparkle 的版本号，不带系统信息和使用数据。第二次打开时会先问要不要自动检查，之后可以在「设置 → 关于」里改。下载的更新包要通过发布者密钥的签名校验，签名不对就不装。
- 自定义插件作为当前用户的外部进程运行，拥有该用户可用的文件和网络权限；manifest 的能力声明不是权限限制。导入默认停用，检测或启用前确认代码来源。
- 在公司里给别人用之前，先确认公司对用 AI 处理聊天内容的要求。

## 排错

| 现象 | 处理 |
| --- | --- |
| 按快捷键没反应 | 菜单栏看快捷键是否注册失败（被占用就换一个）；确认已启用且具备桌面能力的聊天应用在前台、焦点在输入框里 |
| "没拿到输入框" | 先点一下当前聊天窗口的输入框 |
| "截不到顶部栏" | 检查屏幕录制权限，授权后要重启。从终端或 Claude 里直接运行可执行文件时，权限算在终端名下，用 `open dist/Tact.app` 打开就算在应用名下 |
| 每次重新打包都要重新授权 | 运行 `scripts/create-signing-identity.sh` 创建固定证书 |
| 打开时提示「无法验证开发者」 | Releases 里的安装包经过公证，不会这样；自己用临时签名打包的版本第一次打开会被拦下：系统设置 → 隐私与安全性 → 仍要打开 |
| 提示「应用程序 "Tact" 无法打开」 | 多半是已经从安装包里打开了一个 Tact：点菜单栏的小狗退出它，推出安装包，再从「应用程序」打开。从 0.1.2 起，直接在安装包里打开会提示移到「应用程序」 |
| 插件提示找不到命令行工具，终端里却能用 | 0.1.2 起插件用终端里的环境运行。仍然找不到时，看 `~/.tact/engine.log` 里「读取登录 shell 的环境」那一行：shell 启动超过 10 秒或报错时，只会补上几个常见目录 |
| "没认出当前会话" | 按"验证会话识别"那一节校准截取区域；确认插件返回的 `title` 和顶部栏一致 |
| "有多个同名会话" | 设计如此：同名时宁可不出建议 |
| "连不上引擎" | 看 `~/.tact/engine.log`。应用连不上时会自动重启引擎一次 |
| 测试连接提示模型出错 | 设置 → 模型里检查地址、模型名和 Key；云端服务要确认账户有余额 |
| ChatGPT 提示用量到上限 | 去 [chatgpt.com/settings/usage](https://chatgpt.com/settings/usage) 查看套餐用量或这个应用的额度 |
| ChatGPT 登录失效 | 设置 → 模型 → 退出，再 Continue with ChatGPT 重新登录 |
| 灰字位置偏了 | 调整插件实例的 `desktop.overlay.offset_x/y` |
| Tab 后内容没进输入框 | `app.insert_method` 换成另一个试试 |
| 模型太慢 | 换小一点的模型；Qwen3 打开 `append_no_think`，DeepSeek 用 `extra_body` 关掉思考；调小 `context.history_limit` |

## 目录

```
engine/            Go 引擎：插件调用、会话匹配、预取缓存、提示词、模型调用、socket 服务、反馈统计
app/               Swift 菜单栏应用：辅助功能、截图识别（顶部栏、微信、Telegram）、浮层、快捷键、写入
app/.../UI/        引导（含练习）、设置窗口、菜单栏面板、像素抖动着色器、图标与菜单栏标志
assets/            应用图标原图 tact-icon-1024.png 与菜单栏标志；替换后重新打包即可换图标
plugins/telegram/  Telegram 插件（实验性，Go）
plugins/template/  插件开发模板（能力默认关闭，实现后才能导入）
docs/ADAPTER.md    平台插件规范、能力声明、command-v1
scripts/           setup.sh 安装、build-app.sh 打包并同步开发引擎、build-dmg.sh 生成安装包、build-llama.sh 编译本机模型运行时、create-signing-identity.sh 固定签名、test.sh 全部测试
```

开发：

```bash
./scripts/test.sh               # Go 引擎、Telegram 插件、Swift 应用三套测试
./scripts/build-app.sh          # 重新打包 dist/Tact.app
```

Swift 测试里的 `ScreenTests` 会把引导和设置的每一页渲染成 PNG（浅色、深色各一张），放在 `$TACT_SNAPSHOT_DIR` 或临时目录的 `tact-snapshots/` 下，用来检查界面。

## 第一版没做的

新消息到达时自动生成（现在的预取只提前拉消息，不提前调用模型）、多个候选切换、历史表达示例、外部资料查询，以及飞书、Slack、Discord 的实际适配。平台框架第一版不含常驻 JSON-RPC、事件订阅、多账号自动识别、话题输入框定位和原子草稿写入。

## 发布

```bash
TACT_SIGN_IDENTITY=- TACT_VERSION=0.1.0 ./scripts/build-app.sh
./scripts/build-dmg.sh
```

把 `dist/Tact-0.1.0-arm64.dmg`、`dist/appcast.xml`（和实验性的 `dist/plugins/telegram.zip`）上传到 GitHub Release，`build-dmg.sh` 最后打印的 SHA-256 一并写进发布说明。

- **没有苹果开发者账号**：用临时签名（`TACT_SIGN_IDENTITY=-`）打包，不要把本机的自签名证书带进发布版。下载的人第一次打开要到「系统设置 → 隐私与安全性」点「仍要打开」，每次更新都要重新授予辅助功能和屏幕录制权限。
- **有苹果开发者账号**：先用 `xcrun notarytool store-credentials tact-notary` 保存公证凭据，再用 `TACT_SIGN_IDENTITY="Developer ID Application: 名字 (团队ID)"` 打包，`TACT_NOTARY_PROFILE=tact-notary ./scripts/build-dmg.sh` 会签名、公证并装订 DMG。这样用户双击就能打开，升级后权限也保留。
- **应用内更新**：Tact 用 [Sparkle](https://sparkle-project.org) 读取最新 Release 里的 `appcast.xml`，只安装用发布者密钥签过名的更新包。第一次发布前，在「终端」应用里运行一次 `app/.build/artifacts/sparkle/Sparkle/bin/generate_keys`：私钥存进钥匙串，打印出的公钥填进 `scripts/build-app.sh` 的 `UPDATE_KEY`；再用 `generate_keys -x 文件名` 导出私钥，存到密码管理器之类的安全地方。私钥丢了，已安装的用户就收不到更新了。公证之后，`build-dmg.sh` 会调用 `scripts/build-appcast.sh` 签名 DMG、写出 `dist/appcast.xml`；`TACT_RELEASE_NOTES` 指向一份 Markdown 时，内容会显示在更新窗口里。`appcast.xml` 漏传的话，已安装的用户就收不到这一版。
- **Telegram 插件**：发布版用 `TACT_TELEGRAM_APP_ID`、`TACT_TELEGRAM_APP_HASH` 注入 Tact 自己注册的应用，不写进源码。
- 目前只打 Apple Silicon（arm64）的包。

## 许可证

[MIT](../LICENSE)。打包进应用的 [llama.cpp](https://github.com/ggml-org/llama.cpp) 和 [Sparkle](https://github.com/sparkle-project/Sparkle) 同为 MIT（许可证随应用放在 `Contents/Resources/llama.cpp-LICENSE`、`Sparkle-LICENSE`）；Telegram 插件依赖的 [gotd](https://github.com/gotd/td) 为 MIT。
