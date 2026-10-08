import AVFoundation
import AppKit
import Speech

/// "Hey Pix": when turned on, the mic listens on this Mac (on-device recognition only, nothing is sent)
/// for the phrase, then takes what follows as the question. Off by default; macOS shows its mic dot
/// while it's on. Paused while Pix is listening another way or speaking, so it doesn't hear itself.
@MainActor
final class WakeWord {
    static let shared = WakeWord()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var restart: Timer?
    private var generation = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var running = false
    private(set) var capturing = false
    /// Called with what follows "Hey Pix", first when the phrase is heard and again as more words land.
    var onHeard: (String) -> Void = { _ in }

    nonisolated static var on: Bool {
        get { UserDefaults.standard.bool(forKey: "wake.on") }
        set { UserDefaults.standard.set(newValue, forKey: "wake.on") }
    }

    /// The question after the wake phrase ("" if nothing yet), or nil if the phrase isn't there.
    /// Recognizers hear "Pix" as pics, picks, pigs or Pix's, so those count too.
    nonisolated static func command(in text: String) -> String? {
        let pattern = #"(?i)\b(?:hey|hi|okay|ok|yo)[,.!]?\s+(?:pix|pics|picks|pigs|pix's|pick's|pixie|piggs)\b[,.!?]?\s*"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// On-device recognition is required: an always-on mic never sends audio anywhere.
    var available: Bool { recognizer?.supportsOnDeviceRecognition == true }

    func start() {
        guard Self.on, Voice.ready, available, !running else { return }
        running = true
        begin()
        for (center, name, object) in [(NotificationCenter.default, Notification.Name.AVAudioEngineConfigurationChange, engine as AnyObject?),
                                       (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, nil)] {
            let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { WakeWord.shared.renew() }
            }
            observers.append((center, token))
        }
    }

    func stop() {
        running = false
        capturing = false
        end()
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    /// Starts a fresh listen (after a question, a device change, or every minute so the transcript stays short).
    func renew() {
        guard running else { return }
        capturing = false
        end()
        begin()
    }

    private func begin() {
        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.contextualStrings = ["Hey Pix", "Pix"]
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { running = false; return }
        task = recognizer?.recognitionTask(with: req) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true || error != nil
            Task { @MainActor in
                let w = WakeWord.shared
                guard gen == w.generation else { return }
                if let text, let said = WakeWord.command(in: text) {
                    w.capturing = true
                    w.onHeard(said)
                } else if final, !w.capturing {
                    w.renew()
                }
            }
        }
        restart?.invalidate()
        restart = Timer.scheduledTimer(withTimeInterval: 55, repeats: true) { _ in
            MainActor.assumeIsolated { if !WakeWord.shared.capturing { WakeWord.shared.renew() } }
        }
    }

    private func end() {
        restart?.invalidate()
        restart = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }
}

extension PixController {
    /// Turns "Hey Pix" on or off; the first time asks macOS for the mic and speech recognition.
    func setWakeWord(_ on: Bool) {
        WakeWord.on = on
        guard on else { WakeWord.shared.stop(); return }
        guard Voice.ready else {
            Task { @MainActor in if await Voice.requestAccess() { self.startWakeWord() } }
            return
        }
        startWakeWord()
    }

    func startWakeWord() {
        WakeWord.shared.onHeard = { [weak self] said in self?.wakeHeard(said) }
        WakeWord.shared.start()
    }

    /// The phrase was heard: show what follows live, and send it after a pause.
    private func wakeHeard(_ said: String) {
        guard !model.isBusy || model.listening else { WakeWord.shared.renew(); return }
        model.heard = said
        heardAt = Date()
        guard !model.listening else { return }
        noteActivity()
        Voice.shared.hush()
        if case .done = model.phase { reset() }
        tearDownTour()
        model.phase = .idle
        model.permissions = false
        model.welcome = false
        model.listening = true
        wakeRun = true
        model.setTint(.look)
        NSSound(named: "Tink")?.play()
        if !bubbleOpen { buddy.orderFrontRegardless(); openBubble() } else { layoutBubble() }
        let started = Date()
        Task { @MainActor in
            while model.listening && wakeRun {
                try? await Task.sleep(for: .milliseconds(250))
                let quiet = Date().timeIntervalSince(heardAt)
                let empty = model.heard.isEmpty
                if (!empty && quiet > 1.4) || (empty && Date().timeIntervalSince(started) > 6) { finishWake(); break }
            }
        }
    }

    func finishWake() {
        guard wakeRun else { return }
        wakeRun = false
        let said = model.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        model.listening = false
        model.setTint(.base)
        WakeWord.shared.renew()
        guard !said.isEmpty else { closeBubble(); return }
        model.goal = said
        model.followUp = false
        spokenRun = true
        go()
    }
}
