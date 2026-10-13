<div align="center">

<img src="docs/images/icon.png" width="112" alt="Tact">

# Tact

### 不知道怎么回？按快捷键就好

**在聊天窗口里按快捷键，Tact 读完最近的聊天，把一句合适的回复放进输入框。**<br>
按 Tab 采用；发不发、怎么改，都由你。

[![License](https://img.shields.io/badge/license-MIT-111111)](LICENSE) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-111111)

**[下载](https://github.com/wyh0626/tact/releases/latest)** &nbsp;·&nbsp; **[使用说明](docs/GUIDE.md)** &nbsp;·&nbsp; **[接入新的聊天工具](docs/ADAPTER.md)**

<br>

<img src="docs/images/demo.gif" width="900" alt="演示：输入框空着时按快捷键，Tact 以灰字给出一句回复，按 Tab 采用；打「拒绝」再按快捷键，改写成得体的话，按 Tab 替换">

</div>

<br>

## 适合你吗？

消息一多，回复就成了体力活：翻上下文、想措辞、打字、再改。Tact 把它缩成两个按键：

- **输入框空着**：按快捷键，结合最近的聊天给出一句你最可能要发的话，以灰字显示，按 Tab 填入。
- **打了几个字**：比如「拒绝」「下周再说」，Tact 当作你的意思，扩写成一句得体的话；写好的长草稿只修语句和语气，不改立场。
- **没有合适的**：提示「这次不建议」，不硬凑。

它**从不替你发送**，只把字放进输入框。如果你回消息本来就快，或者不想让 AI 碰聊天内容，就不需要它。

## 快速开始

**1 · 安装。** 从 [Releases](https://github.com/wyh0626/tact/releases/latest) 下载 `Tact-版本号-arm64.dmg`，把 Tact 拖进「应用程序」。打开后它只在菜单栏显示一只小狗，没有主窗口。

<sub>需要 macOS 14 及以上、Apple Silicon。目前没有经过苹果公证，第一次打开会被拦下：到「系统设置 → 隐私与安全性」点「仍要打开」。</sub>

**2 · 跟着引导走。** 打开辅助功能和屏幕录制权限，选一个模型，再在「试一试」里拿一段模拟聊天练一遍。快捷键可以在设置里换成你顺手的。

**3 · 接入聊天工具。** 微信在「聊天工具」里打开开关就能用；其他 IM 导入它的插件。之后在聊天窗口里按快捷键。

## 接入聊天工具

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-chat-dark.png">
  <img src="docs/images/settings-chat-light.png" width="820" alt="设置里的聊天工具：微信内置，打开开关即可；其他 IM 导入插件">
</picture>

| 聊天工具 | 怎么接入 | 状态 |
| --- | --- | --- |
| 微信 | 内置。在本机截图识别当前聊天和输入框，不读数据库，不改动微信 | 可用 |
| Telegram | 插件。扫码登录，用官方 API 只读最近的消息 | 实验性 |
| 其他 IM | 按[插件规范](docs/ADAPTER.md)写一个插件，拖进「添加聊天工具」 | — |

## 模型

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-model-dark.png">
  <img src="docs/images/settings-model-light.png" width="820" alt="设置里的模型：OpenAI、DeepSeek、本机、自定义四种">
</picture>

- **ChatGPT 账号**：用 Plus / Pro 套餐的额度，不需要 API Key。
- **DeepSeek、OpenAI**，或任何兼容 OpenAI 接口的服务：Key 存在 macOS 钥匙串里。想要快，选不用思考的模型，或把推理程度调到最低。
- **本机**：内置 llama.cpp，在设置里下载一个 Qwen3 模型，聊天内容不出这台 Mac。

## 照你的说话方式写

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-style-dark.png">
  <img src="docs/images/settings-style-light.png" width="820" alt="设置里的表达风格：用几行字写下说话习惯，按工作群、家人分段">
</picture>

用几行字写下你的说话习惯，比如「少用感叹号」「拒绝时给个理由」。用「## 标题」分段，工作群和家人可以各用一套。

## 隐私

- 截图只在本机内存里识别，不保存，不上传。
- 发给模型的只有会话名、最近的聊天文字、你的草稿和表达风格；用本机模型时这些都不出这台 Mac。
- 统计只记次数、长度和耗时，不记聊天文字。

## 从源码构建

需要 Go 1.24 和 Xcode 命令行工具。

```bash
./scripts/setup.sh        # 编译引擎和应用，生成 ~/.tact 下的配置
./scripts/test.sh         # 全部测试
TACT_SIGN_IDENTITY=- ./scripts/build-app.sh && ./scripts/build-dmg.sh   # 打包可分发的 DMG
```

配置项、插件、排错等细节见[使用说明](docs/GUIDE.md)。演示动画用 [HyperFrames](https://github.com/heygen-com/hyperframes) 制作，源文件在 [docs/demo](docs/demo)。

## 许可证

[MIT](LICENSE)。内置的 [llama.cpp](https://github.com/ggml-org/llama.cpp) 和 Telegram 插件依赖的 [gotd](https://github.com/gotd/td) 也都是 MIT。
