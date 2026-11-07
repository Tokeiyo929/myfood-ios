import UIKit
import Speech
import AVFoundation

@MainActor
protocol VoiceReceiver: AnyObject {
    func voiceDidStart()
    func voiceDidStop()
    func voiceDidRecognize(_ text: String, isFinal: Bool)
    func voiceDidFail(_ msg: String)
}

@MainActor
final class VoiceManager: NSObject {
    static let shared = VoiceManager()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private weak var current: VoiceReceiver?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var permissionTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var hasTap = false
    private(set) var isRecording = false

    func attach(_ receiver: VoiceReceiver) {
        if current !== receiver { finish(); current = receiver }
    }

    func detach(_ receiver: VoiceReceiver) {
        guard current === receiver else { return }
        finish()
        current = nil
    }

    private func ensurePermission() async -> Bool {
        let speech: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else { speech = SFSpeechRecognizer.authorizationStatus() }
        guard speech == .authorized, !Task.isCancelled else { return false }
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .undetermined {
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
        return session.recordPermission == .granted
    }

    func start() {
        finish()
        guard let receiver = current else { return }
        let id = UUID()
        sessionID = id
        permissionTask = Task { [weak receiver] in
            let allowed = await ensurePermission()
            guard !Task.isCancelled, sessionID == id, let receiver, current === receiver else { return }
            guard allowed else { fail("请允许麦克风和语音识别权限"); return }
            // 断网走设备端识别（zh-CN 支持时）；不支持则明确提示
            let offline = !NetworkMonitor.shared.isOnline
            if offline, recognizer?.supportsOnDeviceRecognition != true {
                fail("离线状态暂不支持语音识别")
                return
            }
            guard let recognizer, (offline || recognizer.isAvailable) else { fail("语音功能不可用"); return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true)
                let req = SFSpeechAudioBufferRecognitionRequest()
                req.shouldReportPartialResults = true
                req.requiresOnDeviceRecognition = offline
                request = req
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw APIError(message: "麦克风不可用") }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
                hasTap = true
                engine.prepare()
                try engine.start()
                isRecording = true
                receiver.voiceDidStart()
                recognitionTask = recognizer.recognitionTask(with: req) { [weak self, weak receiver] result, error in
                    Task { @MainActor in
                        guard let self, self.sessionID == id, let receiver, self.current === receiver else { return }
                        if let result { receiver.voiceDidRecognize(result.bestTranscription.formattedString, isFinal: result.isFinal) }
                        if result?.isFinal == true { self.finish() }
                        else if error != nil { self.fail("语音识别失败") }
                    }
                }
            } catch { fail(error.localizedDescription) }
        }
    }

    func stop() {
        permissionTask?.cancel()
        permissionTask = nil
        if isRecording {
            stopCapture()
            request?.endAudio() // 保留识别任务，接收最后一段结果。
        } else if recognitionTask == nil { finish() }
    }

    private func stopCapture() {
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        if engine.isRunning { engine.stop() }
        if request != nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        isRecording = false
        current?.voiceDidStop()
    }

    private func finish() {
        sessionID = nil
        permissionTask?.cancel()
        permissionTask = nil
        stopCapture()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
    }

    private func fail(_ message: String) {
        finish()
        current?.voiceDidFail(message)
    }
}

// 按住说话按钮（🎤）：touchDown 开始 / touchUp 结束
final class VoiceButton: UIButton {
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?

    init() {
        super.init(frame: .zero)
        setTitle("🎤", for: .normal)
        titleLabel?.font = .systemFont(ofSize: 20)
        layer.cornerRadius = 16
        backgroundColor = UIColor(white: 0.94, alpha: 1)
        addTarget(self, action: #selector(touchDown), for: .touchDown)
        addTarget(self, action: #selector(touchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func touchDown() {
        backgroundColor = UIColor.systemRed.withAlphaComponent(0.25)
        onStart?()
    }
    @objc private func touchUp() {
        backgroundColor = UIColor(white: 0.94, alpha: 1)
        onEnd?()
    }

    func setRecording(_ rec: Bool) {
        backgroundColor = rec ? UIColor.systemRed.withAlphaComponent(0.5) : UIColor(white: 0.94, alpha: 1)
    }
}
