import SwiftUI

/// The local models: which one suits this Mac, and each one's download,
/// use and removal.
struct LocalModelsCard: View {
    @ObservedObject var settings: ModelSettings
    @ObservedObject private var store: LocalModelStore
    let controller: Controller
    let compact: Bool

    init(settings: ModelSettings, controller: Controller, compact: Bool) {
        self.settings = settings
        store = settings.localStore
        self.controller = controller
        self.compact = compact
    }

    private var downloading: Bool {
        LocalModel.catalog.contains {
            switch store.state(of: $0) {
            case .downloading, .verifying: return true
            default: return false
            }
        }
    }

    private var memory: Int { LocalModelStore.memoryGB }
    private var recommended: LocalModel { LocalModel.recommended(forMemoryGB: memory) }

    var body: some View {
        Card {
            Text("按这台 Mac 的 \(memory) GB 内存推荐 \(recommended.name)。小模型回得更快，大模型写得更好。聊天内容只在这台 Mac 上处理。"
                 + (downloading ? "下载完会自动启用。" : ""))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            ForEach(Array(LocalModel.catalog.enumerated()), id: \.element.id) { index, model in
                LocalModelRow(model: model, state: store.state(of: model), memory: memory,
                              recommended: model == recommended,
                              inUse: settings.savedLocalModelID == model.id && store.isReady(model),
                              download: { download(model) },
                              pause: { store.pause(model) },
                              use: { use(model) },
                              delete: { store.delete(model) })
                if index < LocalModel.catalog.count - 1 { RowDivider() }
            }
        }
        .animation(Motion.quick, value: store.states)
        .onAppear { store.refresh() }
        // The chosen model just arrived: put it to work, as picking it said.
        .onChange(of: settings.localModel.map { store.state(of: $0) }) { before, after in
            guard after == .ready, before != .ready, settings.provider == .local,
                  settings.savedLocalModelID != settings.localModelID else { return }
            Task { await settings.saveAndTest(controller: controller) }
        }
    }

    /// A model being downloaded is the one to use once it arrives.
    private func download(_ model: LocalModel) {
        withAnimation(Motion.quick) { settings.useLocalModel(model) }
        store.download(model)
    }

    private func use(_ model: LocalModel) {
        withAnimation(Motion.quick) { settings.useLocalModel(model) }
        Task { await settings.saveAndTest(controller: controller) }
    }
}

private struct LocalModelRow: View {
    let model: LocalModel
    let state: LocalModelStore.State
    let memory: Int
    let recommended: Bool
    let inUse: Bool
    let download: () -> Void
    let pause: () -> Void
    let use: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    if recommended {
                        Text("推荐").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accentSoft))
                    }
                }
                Text("\(model.sizeText) · 建议 \(model.recommendedMemoryGB) GB 内存")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                progress
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    @ViewBuilder private var progress: some View {
        switch state {
        case .downloading(let done), .paused(let done):
            HStack(spacing: 8) {
                ProgressView(value: done).progressViewStyle(.linear).frame(maxWidth: 200)
                Text(transferred(done)).font(Theme.mono(10.5, weight: .regular)).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Text(reason).font(.system(size: 11.5)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        if memory < model.minimumMemoryGB {
            Text("需要 \(model.minimumMemoryGB) GB 内存").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            switch state {
            case .ready where inUse:
                Text("使用中").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ok)
            case .ready:
                HStack(spacing: 4) {
                    Button("删除", action: delete).buttonStyle(QuietButtonStyle())
                    Button("使用", action: use).buttonStyle(SecondaryButtonStyle())
                }
            case .downloading:
                Button("暂停", action: pause).buttonStyle(QuietButtonStyle())
            case .paused:
                HStack(spacing: 4) {
                    Button("删除", action: delete).buttonStyle(QuietButtonStyle())
                    Button("继续", action: download).buttonStyle(SecondaryButtonStyle())
                }
            case .verifying:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("校验中…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .absent, .failed:
                Button(action: download) {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func transferred(_ done: Double) -> String {
        let bytes = Int64(Double(model.bytes) * done)
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) / \(model.sizeText)"
    }
}
