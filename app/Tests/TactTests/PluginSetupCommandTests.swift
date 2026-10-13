import Foundation
import Testing
@testable import Tact

struct PluginSetupCommandTests {
    @Test func olderSetupWithoutCommandsStillDecodes() throws {
        let json = #"{"summary":"请先登录","requirements":["安装客户端"],"steps":["回到 Tact 检测"],"help_url":"https://example.com/help"}"#
        let setup = try JSONDecoder().decode(PluginSetup.self, from: Data(json.utf8))
        #expect(setup.summary == "请先登录")
        #expect(setup.requirements == ["安装客户端"])
        #expect(setup.steps == ["回到 Tact 检测"])
        #expect(setup.commands == nil)
    }

    @Test func fullSetupDecodesCommandInstructionsAndInputPlaceholder() throws {
        let raw: [String: Any] = [
            "summary": "准备 CLI 并登录", "requirements": ["已安装客户端"],
            "steps": ["复制安装命令", "登录后回到 Tact 检测"], "help_url": "https://example.com/help",
            "commands": [
                ["title": "检查安装", "command": "examplechat --version", "detail": "在终端运行，确认已安装"],
                ["title": "登录账号", "command": "examplechat login ${input}",
                 "detail": "填写自己的邮箱，再复制命令", "input_placeholder": "公司邮箱"],
            ],
        ]
        let setup = try JSONDecoder().decode(PluginSetup.self, from: JSONSerialization.data(withJSONObject: raw))
        let commands = try #require(setup.commands)
        #expect(commands.count == 2)
        #expect(commands[0].title == "检查安装")
        #expect(commands[0].detail == "在终端运行，确认已安装")
        #expect(commands[0].inputPlaceholder == nil)
        #expect(!commands[0].requiresInput)
        #expect(commands[1].title == "登录账号")
        #expect(commands[1].command == "examplechat login ${input}")
        #expect(commands[1].inputPlaceholder == "公司邮箱")
        #expect(commands[1].requiresInput)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(commands[1])) as? [String: Any])
        #expect(encoded["input_placeholder"] as? String == "公司邮箱")
        #expect(encoded["inputPlaceholder"] == nil)
    }

    @Test func inputCommandRejectsEmptyOrWhitespaceOnlyInput() throws {
        let command = try instruction("examplechat login ${input}")
        for value in ["", " ", "\n\t  "] {
            #expect(command.resolvedCommand(input: value) == nil)
        }
    }

    @Test func inputCommandTrimsOuterWhitespaceAndQuotesArgument() throws {
        let command = try instruction("examplechat login ${input}")
        #expect(command.resolvedCommand(input: "  user@example.com  ") == "examplechat login 'user@example.com'")
    }

    @Test func apostropheIsEscapedWithoutOpeningAnUnquotedArgument() throws {
        let command = try instruction("examplechat login ${input}")
        let actual = try #require(command.resolvedCommand(input: "o'neil@example.com"))
        let safeForms = [
            #"examplechat login 'o'\''neil@example.com'"#,
            #"examplechat login 'o'"'"'neil@example.com'"#,
        ]
        #expect(safeForms.contains(actual))
    }

    @Test func shellSubstitutionsRemainLiteralInsideSingleQuotes() throws {
        let command = try instruction("examplechat login ${input}")
        let cases = [
            ("user$(whoami)@example.com", "examplechat login 'user$(whoami)@example.com'"),
            ("user`id`@example.com", "examplechat login 'user`id`@example.com'"),
            ("a; printf secret", "examplechat login 'a; printf secret'"),
            ("user name@example.com", "examplechat login 'user name@example.com'"),
        ]
        for (input, expected) in cases {
            #expect(command.resolvedCommand(input: input) == expected)
        }
    }

    @Test func embeddedControlCharactersAreRejected() throws {
        let command = try instruction("examplechat login ${input}")
        for input in ["a\nb", "a\rb", "a\tb", "a\u{0000}b", "a\u{001B}b", "a\u{007F}b", "a\u{0085}b"] {
            #expect(command.resolvedCommand(input: input) == nil)
        }
    }

    @Test func inputLengthIsBoundedAfterTrimming() throws {
        let command = try instruction("examplechat login ${input}")
        let maximum = String(repeating: "a", count: 512)
        #expect(command.resolvedCommand(input: "  " + maximum + "  ") == "examplechat login '" + maximum + "'")
        #expect(command.resolvedCommand(input: String(repeating: "a", count: 513)) == nil)
    }

    @Test func everyInputPlaceholderGetsTheSameQuotedValue() throws {
        let command = try instruction("tool login --user ${input} --confirm ${input}")
        #expect(command.resolvedCommand(input: "user@example.com") == "tool login --user 'user@example.com' --confirm 'user@example.com'")
    }

    @Test func ordinaryCommandDoesNotRequireInputOrChangeItsText() throws {
        let command = try instruction("examplechat whoami")
        #expect(!command.requiresInput)
        #expect(command.resolvedCommand(input: "") == "examplechat whoami")
        #expect(command.resolvedCommand(input: "unused$(whoami)`id`") == "examplechat whoami")
    }

    @Test func resolvingInputDoesNotStoreItInTheSerializableInstructions() throws {
        let command = try instruction("examplechat login ${input}")
        #expect(command.resolvedCommand(input: "private-user@example.com") != nil)
        #expect(command.command == "examplechat login ${input}")
        let encoded = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        #expect(encoded.contains("${input}"))
        #expect(!encoded.contains("private-user@example.com"))
    }

    private func instruction(_ command: String) throws -> PluginSetupCommand {
        let raw = ["title": "测试指令", "command": command]
        return try JSONDecoder().decode(PluginSetupCommand.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    @Test func pluginToolsRunFromTheInstalledFolder() {
        let command = PluginSetupCommand(title: "扫码登录", command: "${plugin_dir}/tact-telegram login",
                                         detail: nil, inputPlaceholder: nil)
        #expect(command.resolvedCommand(input: "", pluginDirectory: "/Users/me/.tact/plugins/tg's") ==
                "'/Users/me/.tact/plugins/tg'\\''s'/tact-telegram login")
        #expect(command.resolvedCommand(input: "") == nil)
        #expect(command.resolvedCommand(input: "", pluginDirectory: "") == nil)
    }
}
