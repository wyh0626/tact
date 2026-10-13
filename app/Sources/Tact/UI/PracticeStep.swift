import SwiftUI

/// The guide's "try it" step: a chat with a friend to answer with the real
/// hotkey, before any chat tool is set up.
struct PracticeStep: View {
    @ObservedObject var practice: PracticeChat
    let controller: Controller
    let keyboardReady: Bool
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle(eyebrow: "试一试", title: "先在这里练一次",
                      detail: "\(PracticeChat.friend)约你周六吃火锅，用快捷键回他。这里的消息不会真的发出去。")
            chat
            if !keyboardReady {
                Label("快捷键要等辅助功能权限打开后才生效，可以回到上一步打开。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
            } else if let note = practice.note {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            checklist
        }
        .onAppear {
            controller.beginPractice(practice)
            // Only a window people are looking at takes the keyboard: focus
            // starts the input method's services, which an offscreen render
            // (the guide's screenshots) must not.
            if NSApp.isActive { typing = true }
        }
        .onDisappear { controller.endPractice() }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Monogram(name: String(PracticeChat.friend.dropFirst()), size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PracticeChat.friend).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(practice.working ? "你正在想怎么回…" : "在线").font(.system(size: 11)).foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            RowDivider(inset: 0)
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 6) {
                        Text("今天 21:38").font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.bottom, 2)
                        ForEach(practice.messages) { message in
                            PracticeBubble(message: message).id(message.id)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .animation(Motion.spring, value: practice.messages)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: 204)
                .onChange(of: practice.messages) { _, messages in
                    guard let last = messages.last else { return }
                    withAnimation(Motion.spring) { scroller.scrollTo(last.id, anchor: .bottom) }
                }
            }
            RowDivider(inset: 0)
            TextField("发消息…", text: $practice.draft)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($typing)
                .onSubmit { practice.send() }
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(InputLocator(practice: practice))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.surface)
        }
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.surface))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
        .contentShape(Rectangle())
        .onTapGesture { typing = true }
    }

    private var checklist: some View {
        let next = PracticeTask.allCases.first { !practice.done.contains($0) }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(PracticeTask.allCases, id: \.self) { task in
                let done = practice.done.contains(task)
                HStack(spacing: 8) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13)).foregroundStyle(done ? Theme.ok : (task == next ? Theme.accent : Color.secondary))
                        .contentTransition(.symbolEffect(.replace))
                    Text(task.title(hotkey: practice.hotkey))
                        .font(.system(size: 12, weight: task == next ? .medium : .regular))
                        .foregroundStyle(done ? Color.secondary : (task == next ? Theme.ink : Color.secondary))
                        .strikethrough(done, color: .secondary)
                }
            }
            if practice.finished {
                HStack(spacing: 10) {
                    Text("都会了。点「继续」接入你的聊天工具。").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ok)
                    Button("再练一次") { practice.restart() }.buttonStyle(QuietButtonStyle())
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: practice.done)
    }
}

private struct PracticeBubble: View {
    let message: PracticeMessage

    var body: some View {
        HStack {
            if message.fromMe { Spacer(minLength: 60) }
            Text(message.text)
                .font(.system(size: 13)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(message.fromMe ? Theme.accentSoft : Theme.pill))
                .fixedSize(horizontal: false, vertical: true)
            if !message.fromMe { Spacer(minLength: 60) }
        }
    }
}

/// Tells the practice chat where its input box is on screen, and its
/// colour, for the overlay to line up with it.
private struct InputLocator: NSViewRepresentable {
    let practice: PracticeChat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        practice.inputView = view
        practice.inputColor = { [weak view] in
            var color = Theme.surfaceNS
            (view?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
                color = NSColor(cgColor: Theme.surfaceNS.cgColor) ?? Theme.surfaceNS
            }
            return color
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        practice.inputView = view
    }
}
