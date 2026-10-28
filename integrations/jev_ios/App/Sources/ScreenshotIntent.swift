import AppIntents
import Combine
import Foundation
import UniformTypeIdentifiers

/// Shortcuts supplies an explicitly selected/captured image. This action never uploads it.
struct RecognizeChatScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "识别聊天截图（按配置）"
    static var description = IntentDescription("接收截图并打开狗头军师，按识图配置处理。本地模式直接识别；DeepSeek 或 OpenRouter 先预览并确认上传。不会自动分析或发送消息。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "聊天截图", supportedTypeIdentifiers: ["public.image"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var screenshot: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("识别 \(\.$screenshot) 并打开核对页")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        let jpeg = try LocalOCR.boundedJPEG(screenshot.data)
        try Task.checkCancellation()
        ScreenshotInbox.shared.submit(jpeg)
        return .result()
    }
}

/// Receives a system screenshot without opening the companion app. A fresh
/// request from the keyboard is required, so the result cannot target old chats.
struct SendChatScreenshotToKeyboardIntent: AppIntent {
    static var title: LocalizedStringResource = "截图交给键盘（按配置）"
    static var description = IntentDescription("接收系统截屏，按识图配置交给键盘。本地模式直接识别；DeepSeek 或 OpenRouter 在键盘预览后确认上传。不打开主 App，不会自动分析或发送。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "聊天截图", supportedTypeIdentifiers: ["public.image"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var screenshot: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$screenshot) 交给键盘，按配置识别")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try Task.checkCancellation()
        let store = try GoutouStore()
        // 免费签名（个人 Apple ID）的包拿不到 App Group：键盘写下的等待请求在这里读不到，
        // 旧逻辑会一直报“请先切换到狗头军师键盘…”。所以不再强制要求等待页：
        // 有请求就沿用它的裁切参数，没有就用主 App 自己的配置；结果放进剪贴板，键盘轮询取走。
        var active = store.captureMailbox.request()
        if active == nil || active?.relationship != store.relationship() || active?.config != store.config() {
            active = KeyboardCaptureRequest(relationship: store.relationship(),
                                            config: store.config(),
                                            excludedBottomFraction: 0.46)
        }
        guard let request = active else { return .result() }

        // 结果连同主 App 当前的配置与密钥一起塞进剪贴板：键盘拿到结果的同时就把配置补齐，
        // 免得还要手动“复制配置 → 导入”两步。
        @MainActor
        func publish(_ result: KeyboardCaptureResult) {
            var secrets: [String: String] = [:]
            for name in CredentialVault.services { secrets[name] = (try? CredentialVault.read(name)) ?? "" }
            GoutouClipboard.publishCapture(result, config: store.config(),
                                           relationship: store.relationship(), secrets: secrets,
                                           profiles: store.archived())
        }

        do {
            let jpeg = try LocalOCR.boundedJPEG(screenshot.data, maxPixelSize: 1600,
                                                excludedBottomFraction: request.excludedBottomFraction)
            let result = try await CaptureOCR.prepare(jpeg, request: request)
            try Task.checkCancellation()
            publish(result)
            try? store.captureMailbox.publish(result)
        } catch {
            if !(error is CancellationError) {
                let failed = KeyboardCaptureResult(request: request, transcript: "",
                                                  error: error.localizedDescription)
                publish(failed)
                try? store.captureMailbox.publish(failed)
            }
            throw error
        }
        return .result()
    }
}

struct GoutouScreenshotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecognizeChatScreenshotIntent(),
            phrases: ["用 \(.applicationName) 识别聊天截图"],
            shortTitle: "识别聊天截图", systemImageName: "viewfinder")
        AppShortcut(intent: SendChatScreenshotToKeyboardIntent(),
            phrases: ["用 \(.applicationName) 把截图交给键盘"],
            shortTitle: "截图交给键盘", systemImageName: "keyboard")
    }
}

/// Foreground intent and app use the same process; nothing is persisted to an App Group.
@MainActor
final class ScreenshotInbox: ObservableObject {
    static let shared = ScreenshotInbox()
    @Published private(set) var pending: Data?
    func submit(_ data: Data) { pending = data }
    func take() -> Data? {
        let image = pending
        pending = nil
        return image
    }
}
