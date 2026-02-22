import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class SpeechInputService: ObservableObject {
    enum RecognitionMode {
        case onDevice
        case cloud

        var displayLabel: String {
            switch self {
            case .onDevice:
                return "本地"
            case .cloud:
                return "云端"
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var transcribedText: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var recognitionMode: RecognitionMode = .onDevice

    private let speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var baseText: String = ""
    private var isSwitchingRecognitionMode = false

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        speechRecognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
    }

    func startRecording(seedText: String) async {
        guard !isRecording else { return }
        errorMessage = nil

        do {
            try await ensureAuthorizations()
            try beginRecognition(seedText: seedText, preferOnDevice: true)
        } catch {
            stopRecording()
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        guard isRecording || recognitionTask != nil || recognitionRequest != nil else { return }
        isRecording = false
        stopRecognitionSession()
    }

    func reset() {
        stopRecording()
        baseText = ""
        transcribedText = ""
        errorMessage = nil
        recognitionMode = .onDevice
    }

    private func ensureAuthorizations() async throws {
        let speechStatus = await speechAuthorizationStatus()
        switch speechStatus {
        case .authorized:
            break
        case .notDetermined:
            throw speechError("语音识别权限尚未授予，请重试。")
        case .denied:
            throw speechError("语音识别权限被拒绝，请在系统设置中开启。")
        case .restricted:
            throw speechError("语音识别权限受限，当前设备无法使用。")
        @unknown default:
            throw speechError("无法确认语音识别权限状态。")
        }

        let microphoneGranted = await microphoneAuthorizationGranted()
        guard microphoneGranted else {
            throw speechError("麦克风权限被拒绝，请在系统设置中开启。")
        }
    }

    private func speechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func microphoneAuthorizationGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func beginRecognition(seedText: String, preferOnDevice: Bool) throws {
        guard let speechRecognizer else {
            throw speechError("当前设备不支持语音识别。")
        }

        guard speechRecognizer.isAvailable else {
            throw speechError("语音识别服务暂不可用，请稍后重试。")
        }

        let useOnDevice = preferOnDevice && speechRecognizer.supportsOnDeviceRecognition
        recognitionMode = useOnDevice ? .onDevice : .cloud

        isSwitchingRecognitionMode = true
        stopRecognitionSession()

        baseText = seedText.trimmingCharacters(in: .whitespacesAndNewlines)
        transcribedText = baseText

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = useOnDevice

        recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    self.updateTranscribedText(with: result.bestTranscription.formattedString)
                    if result.isFinal {
                        self.stopRecording()
                    }
                }

                if let error, self.isRecording {
                    if self.recognitionMode == .onDevice, !self.isSwitchingRecognitionMode {
                        do {
                            try self.beginRecognition(seedText: self.transcribedText, preferOnDevice: false)
                            self.errorMessage = nil
                            return
                        } catch {
                            self.errorMessage = "语音识别失败：\(error.localizedDescription)"
                            self.stopRecording()
                            return
                        }
                    }

                    if self.isSwitchingRecognitionMode || self.isExpectedCancellation(error) {
                        return
                    }

                    self.errorMessage = "语音识别失败：\(error.localizedDescription)"
                    self.stopRecording()
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            isSwitchingRecognitionMode = false
        } catch {
            stopRecognitionSession()
            isSwitchingRecognitionMode = false
            throw speechError("麦克风启动失败：\(error.localizedDescription)")
        }
    }

    private func stopRecognitionSession() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func isExpectedCancellation(_ error: Error) -> Bool {
        let message = (error as NSError).localizedDescription.lowercased()
        return message.contains("cancel")
    }

    private func updateTranscribedText(with partial: String) {
        let normalizedPartial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedPartial.isEmpty {
            transcribedText = baseText
            return
        }

        if baseText.isEmpty {
            transcribedText = normalizedPartial
            return
        }

        let joiner = baseText.hasSuffix(" ") ? "" : " "
        transcribedText = "\(baseText)\(joiner)\(normalizedPartial)"
    }

    private func speechError(_ message: String) -> NSError {
        NSError(
            domain: "SpeechInputService",
            code: 3001,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
