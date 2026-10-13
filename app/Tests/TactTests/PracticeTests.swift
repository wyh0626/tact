import AppKit
import SwiftUI
import Testing
@testable import Tact

/// One window, far off screen, for every practice chat's input box: the
/// overlay never shows on the desktop while tests run, and no window is
/// opened and torn down next to other tests' overlays.
@MainActor
private let offscreen: NSWindow = {
    let window = NSWindow(contentRect: NSRect(x: -20000, y: 400, width: 480, height: 40), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
}()

@MainActor
@Suite(.serialized)
struct PracticeTests {
    private func practice(_ answer: @escaping (String) -> [String: Any]?) -> PracticeChat {
        let chat = PracticeChat(hotkey: "双击 ⌃", overlay: Overlay(level: .statusBar)) { payload in
            answer(payload["input"] as? String ?? "")
        }
        let input = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 32))
        offscreen.contentView?.addSubview(input)
        chat.inputView = input
        chat.inputColor = { .white }
        return chat
    }

    private func key(_ code: CGKeyCode) -> CGEvent {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
    }

    private func wait(until done: () -> Bool) async {
        for _ in 0..<250 where !done() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func theWholePracticeRunsLikeARealChat() async throws {
        let chat = practice { draft in
            ["ok": true, "platform_id": "practice", "mode": draft.isEmpty ? "complete" : "rewrite",
             "suggestion": draft.isEmpty ? "好啊，六点半没问题" : "周六去不了，周日可以吗？"]
        }
        defer { chat.reset(detail: ""); chat.inputView?.removeFromSuperview() }
        #expect(chat.inputFrame?.minX == -20000)

        chat.start()
        await wait { chat.done.contains(.suggest) }
        #expect(chat.done == [.suggest] && chat.note == nil)
        #expect(chat.handle(type: .keyDown, event: key(48)))
        #expect(chat.draft == "好啊，六点半没问题" && chat.done.contains(.accept))

        chat.draft = PracticeChat.draftExample
        chat.start()
        await wait { chat.done.contains(.rewrite) }
        #expect(!chat.handle(type: .keyDown, event: key(0)), "typing passes through and drops the suggestion")
        #expect(!chat.handle(type: .keyDown, event: key(48)), "with nothing shown, Tab is the window's")
        chat.start()
        await wait { chat.working == false }
        #expect(chat.handle(type: .keyDown, event: key(48)))
        #expect(chat.draft == "周六去不了，周日可以吗？" && chat.done.contains(.replace))

        chat.send()
        #expect(chat.draft.isEmpty)
        #expect(chat.messages.last?.fromMe == true && chat.messages.last?.text == "周六去不了，周日可以吗？")
        #expect(chat.messages.count == PracticeChat.opening.count + 1, "nobody answers in the practice")
        #expect(chat.finished)

        chat.restart()
        #expect(chat.messages == PracticeChat.opening && chat.done.isEmpty && chat.draft.isEmpty)
    }

    @Test func withoutAModelTheExampleStillShowsTheIdea() async {
        let chat = practice { _ in nil }
        defer { chat.reset(detail: ""); chat.inputView?.removeFromSuperview() }
        chat.start()
        await wait { chat.done.contains(.suggest) }
        #expect(chat.note?.contains("示例") == true)
        #expect(chat.handle(type: .keyDown, event: key(48)))
        #expect(chat.draft == PracticeChat.example(for: "complete"))
    }

    @Test func aDraftChangedWhileWritingDropsTheSuggestion() async {
        let chat = practice { _ in
            ["ok": true, "platform_id": "practice", "mode": "complete", "suggestion": "好啊"]
        }
        defer { chat.reset(detail: ""); chat.inputView?.removeFromSuperview() }
        chat.start()
        chat.draft = "我"
        await wait { chat.working == false }
        #expect(chat.done.isEmpty)
        #expect(!chat.handle(type: .keyDown, event: key(48)))
    }

    @Test func theRequestCarriesTheChatForThePracticePlatform() throws {
        let payload = PracticeChat.payload(messages: PracticeChat.opening, draft: "周六不行")
        #expect(payload["platform_id"] as? String == "practice" && payload["input"] as? String == "周六不行")
        let screen = try #require(payload["screen"] as? [String: Any])
        #expect(screen["title"] as? String == PracticeChat.friend && screen["type"] as? String == "private")
        let messages = try #require(screen["messages"] as? [[String: Any]])
        #expect(messages.count == PracticeChat.opening.count)
        #expect(messages[2]["from_me"] as? Bool == true && messages[0]["sender"] as? String == PracticeChat.friend)
    }

    @Test func practiceComesRightAfterTheModel() {
        #expect(OnboardingStep.allCases.map(\.title) == ["欢迎", "授权", "模型", "试一试", "聊天工具", "完成"])
    }
}
