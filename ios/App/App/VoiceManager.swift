import Foundation
import UIKit
import Speech
import AVFoundation

// 语音识别（对齐小程序 WechatSI 语音输入）：SFSpeechRecognizer zh-CN
// 单例管理器 + attach/detach 切换"当前接收者"，同小程序 voice.js 设计
protocol VoiceReceiver: AnyObject {
    func voiceDidStart()
    func voiceDidRecognize(_ text: String, isFinal: Bool)
    func voiceDidFail(_ msg: String)
}

final class VoiceManager: NSObject, SFSpeechRecognizerDelegate {
    static let shared = VoiceManager()

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var engine = AVAudioEngine()
    private var current: VoiceReceiver?
    private var recognitionTask: SFSpeechRecognitionTask?
    private(set) var isRecording = false
    private var permissionAsked = false

    private override init() {
        super.init()
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }

    var isAvailable: Bool {
        recognizer != nil && recognizer?.isAvailable == true
    }

    // 提前申请权限（页面 onLoad 时调用，把弹窗移出"按下"的临界路径）
    func ensurePermission() {
        guard !permissionAsked else { return }
        permissionAsked = true
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    func attach(_ receiver: VoiceReceiver) { current = receiver }
    func detach(_ receiver: VoiceReceiver) {
        if current === receiver { current = nil }
        stop()
    }

    func start() -> Bool {
        guard isAvailable, !isRecording else { return false }
        // 停掉残留会话
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            current?.voiceDidFail("语音识别失败")
            return false
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if let r = recognizer, r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = false }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            current?.voiceDidFail("语音识别失败")
            return false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            current?.voiceDidFail("语音识别失败")
            return false
        }
        isRecording = true
        current?.voiceDidStart()
        recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.current?.voiceDidRecognize(text, isFinal: result.isFinal)
            }
            if error != nil || result?.isFinal == true {
                self.finish()
                if error != nil { self.current?.voiceDidFail("语音识别失败") }
            }
        }
        return true
    }

    func stop() {
        guard isRecording else { return }
        request?.endAudio()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
    }

    private func finish() {
        request = nil
        recognitionTask = nil
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
