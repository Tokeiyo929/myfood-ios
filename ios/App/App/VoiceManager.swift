import Foundation
import Speech
import AVFoundation

// 语音识别（原 UIKit VoiceManager 移植，无 UI 依赖；按钮在 SwiftUI 层）
@MainActor
final class VoiceManager: NSObject {
    var onText: ((String) -> Void)?
    var onFail: ((String) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionID: UUID?
    private var hasTap = false
    private(set) var isRecording = false

    func start() {
        finish()
        let id = UUID()
        sessionID = id
        Task { [weak self] in
            guard let self, self.sessionID == id else { return }
            let allowed = await self.ensurePermission()
            guard self.sessionID == id else { return }
            guard allowed else { self.fail("请允许麦克风和语音识别权限"); return }
            // 断网走设备端识别（zh-CN 支持时）；不支持则明确提示
            let offline = !NetworkMonitor.shared.isOnline
            if offline, self.recognizer?.supportsOnDeviceRecognition != true {
                self.fail("离线状态暂不支持语音识别")
                return
            }
            guard let recognizer = self.recognizer, (offline || recognizer.isAvailable) else { self.fail("语音功能不可用"); return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true)
                let req = SFSpeechAudioBufferRecognitionRequest()
                req.shouldReportPartialResults = true
                req.requiresOnDeviceRecognition = offline
                self.request = req
                let input = self.engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw APIError(message: "麦克风不可用") }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
                self.hasTap = true
                self.engine.prepare()
                try self.engine.start()
                self.isRecording = true
                self.onRecordingChange?(true)
                self.recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, self.sessionID == id else { return }
                        if let result { self.onText?(result.bestTranscription.formattedString) }
                        if result?.isFinal == true { self.finish() }
                        else if error != nil { self.fail("语音识别失败") }
                    }
                }
            } catch { self.fail(error.localizedDescription) }
        }
    }

    func stop() {
        if isRecording {
            stopCapture()
            request?.endAudio() // 保留识别任务，接收最后一段结果
        } else if recognitionTask == nil {
            finish()
        }
    }

    private func ensurePermission() async -> Bool {
        let speech: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else { speech = SFSpeechRecognizer.authorizationStatus() }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private func stopCapture() {
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        if engine.isRunning { engine.stop() }
        if request != nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        isRecording = false
        onRecordingChange?(false)
    }

    private func finish() {
        sessionID = nil
        stopCapture()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
    }

    private func fail(_ message: String) {
        finish()
        onFail?(message)
    }
}
