<div align="center">

<img src="docs/images/icon.png" width="112" alt="Tact">

# Tact

### Stuck on a reply? Press a shortcut.

**Tact reads the recent conversation and drafts a reply in your chat window.**
Press Tab to accept it. Edit and send it yourself.

**[Download](https://github.com/wyh0626/tact/releases/latest)** · **[简体中文](README.md)**

</div>

## Get started

Requires macOS 14 or later and Apple Silicon.

1. Download the DMG from [Releases](https://github.com/wyh0626/tact/releases/latest), drag Tact into Applications, and open it. Look for the dog in the menu bar. The DMG is notarized by Apple, so it opens with a double-click. Requires macOS 14 or later on Apple Silicon. New versions show up in the menu bar and install with a click.
2. Follow the setup guide to grant Accessibility and Screen Recording permissions, choose a model, and practice with a sample conversation.
3. Enable WeChat in **Settings → Chat tools**, or import a plugin for another chat app. Focus the chat input and press the shortcut, which defaults to double-pressing Control.

With an empty input, Tact suggests a complete reply. Type a short intent such as “decline” to turn it into a natural reply; an existing long draft receives light editing. Press Tab to insert the suggestion, or Esc to dismiss it. **Tact never sends a message for you.**

## Language

The interface supports English and Simplified Chinese and follows your system language by default. Choose **System default**, **简体中文**, or **English** on the welcome screen or in **Settings → General → Language**. Changes apply immediately and persist across launches.

The interface language does not overwrite your writing preferences or change the language of your real conversations. On a fresh English installation, the example style follows the conversation’s language. Existing style files are preserved; if yours asks for Chinese replies, edit it in **Writing style**. Plugin names, setup instructions, and external error details appear in the language supplied by the plugin or service.

## Chat apps

| App | Integration | Status |
| --- | --- | --- |
| WeChat | Built in; recognizes the visible chat window locally | Available |
| DingTalk | Built in; reads the open chat, its messages and the input through Accessibility, or recognizes the window when that fails. No admin approval needed | Available |
| Telegram | Optional plugin; reads recent messages through the official API | Experimental |
| Other apps | Import a plugin built with the [adapter specification](docs/ADAPTER.md) | Depends on the plugin |

## Models and writing style

- **ChatGPT account:** sign in to use your plan without an API key.
- **OpenAI, DeepSeek, or a custom OpenAI-compatible endpoint:** API keys stay in the macOS Keychain.
- **Local:** download a supported Qwen3 model and run it on your Mac with the bundled llama.cpp runtime.

In **Writing style**, describe how you speak: concise or casual, preferred language, how you decline requests. Sections headed with `##` can give different conversations different styles.

## Privacy

- Screenshots are recognized locally in memory; they are not saved or uploaded.
- Your selected model receives the current chat name, recent text, input draft, and writing preferences. With a local model, these stay on your Mac.
- Statistics record counts, lengths, and latency. Chat text is excluded by default.
- Update checks go to GitHub only and carry nothing but Tact’s version number. Turn off automatic checks in **Settings → About**.

## Build from source

Requires Go 1.24+ and the Xcode Command Line Tools.

```bash
./scripts/setup.sh
./scripts/test.sh
TACT_SIGN_IDENTITY=- ./scripts/build-app.sh
./scripts/build-dmg.sh
```

The app bundle is written to `dist/Tact.app`. The [full guide](docs/GUIDE.md) and [plugin specification](docs/ADAPTER.md) are currently in Chinese; the app also provides an English developer brief under **Add chat tool**.

## License

[MIT](LICENSE). The bundled [llama.cpp](https://github.com/ggml-org/llama.cpp) runtime, the [Sparkle](https://github.com/sparkle-project/Sparkle) updater, and the Telegram plugin’s [gotd](https://github.com/gotd/td) dependency are also MIT licensed.
