import Foundation
import AVFoundation
import CoreLocation

// MARK: - 语音播报（v3）

/// 中文语音引导：转弯前分级播报、到达提醒、重新规划提示。
/// 会「压低」正在播放的音乐（ducking），播完自动放开。
final class VoiceGuidance: NSObject, AVSpeechSynthesizerDelegate {

    enum Priority: Int {
        case low = 0
        case normal = 1
        case high = 2
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpoken: [String: Date] = [:]
    private var sessionActive = false

    /// 最近一次播报文案（UI 可显示字幕）
    private(set) var lastText: String = ""
    private(set) var lastSpokenAt: Date?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// 是否启用（跟随设置，静音后仍会更新字幕）
    var enabled: Bool { SettingsStore.shared.voiceEnabled }

    func speak(_ text: String, priority: Priority = .normal, dedupWindow: TimeInterval = 8) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lastText = trimmed
        guard enabled else { return }

        let now = Date()
        if let last = lastSpoken[trimmed], now.timeIntervalSince(last) < dedupWindow {
            return
        }
        // 清理过期去重表
        if lastSpoken.count > 40 {
            lastSpoken = lastSpoken.filter { now.timeIntervalSince($0.value) < 60 }
        }
        lastSpoken[trimmed] = now
        lastSpokenAt = now

        if priority == .high {
            synthesizer.stopSpeaking(at: .immediate)
        }

        activateSession()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        let rate = min(max(SettingsStore.shared.voiceRate, 0.35), 0.62)
        utterance.rate = Float(rate)
        utterance.volume = Float(min(max(SettingsStore.shared.voiceVolume, 0.2), 1.0))
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0.05

        synthesizer.speak(utterance)
    }

    /// 只更新字幕不发声（静音时也能看到提示）
    func caption(_ text: String) {
        lastText = text
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivateSession()
    }

    // MARK: - 音频会话

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
            sessionActive = true
        } catch {
            sessionActive = false
        }
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        sessionActive = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking {
            deactivateSession()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking {
            deactivateSession()
        }
    }
}

// MARK: - 安全监控（v8）

/// 超速 / 急加速 / 急刹检测与驾驶评分
final class SafetyMonitor {

    enum Event: String {
        case harshAcceleration
        case harshBraking
        case overspeed

        var title: String {
            switch self {
            case .harshAcceleration: return "急加速"
            case .harshBraking: return "急刹车"
            case .overspeed: return "超速"
            }
        }

        var symbol: String {
            switch self {
            case .harshAcceleration: return "arrow.up.forward"
            case .harshBraking: return "arrow.down.forward"
            case .overspeed: return "speedometer"
            }
        }

        var penalty: Double {
            switch self {
            case .harshAcceleration: return 4
            case .harshBraking: return 6
            case .overspeed: return 5
            }
        }
    }

    struct LogItem: Identifiable {
        let id = UUID()
        let event: Event
        let at: Date
        let detail: String
    }

    private(set) var score: Double = 100
    private(set) var log: [LogItem] = []
    private(set) var isOverspeed = false
    private(set) var overspeedAmount: Double = 0   // 超出多少 km/h

    private var lastSpeed: Double = 0
    private var lastTime: Date?
    private var lastEventAt: [String: Date] = [:]

    func reset() {
        score = 100
        log.removeAll()
        isOverspeed = false
        overspeedAmount = 0
        lastSpeed = 0
        lastTime = nil
        lastEventAt.removeAll()
    }

    /// 返回本次新产生的事件（用于触发播报/震动）
    @discardableResult
    func ingest(speed: Double, now: Date = Date()) -> Event? {
        let settings = SettingsStore.shared
        var triggered: Event?

        // 1. 超速
        if settings.speedAlertEnabled {
            let kmh = max(speed, 0) * 3.6
            let limit = settings.speedLimit
            let over = kmh - limit
            let wasOverspeed = isOverspeed
            isOverspeed = over > settings.speedTolerance
            overspeedAmount = max(over, 0)
            if isOverspeed && !wasOverspeed {
                triggered = .overspeed
                push(.overspeed, detail: String(format: "%.0f km/h（限速 %.0f）", kmh, limit), now: now)
            }
        } else {
            isOverspeed = false
            overspeedAmount = 0
        }

        // 2. 急加速 / 急刹
        defer {
            lastSpeed = speed
            lastTime = now
        }
        guard let previous = lastTime else { return triggered }
        let dt = now.timeIntervalSince(previous)
        guard dt > 0.3, dt < 4 else { return triggered }

        let accel = (speed - lastSpeed) / dt     // m/s²
        if accel > 3.4 {
            if pushIfAllowed(.harshAcceleration, detail: String(format: "+%.1f m/s²", accel), now: now) {
                triggered = .harshAcceleration
            }
        } else if accel < -4.2 {
            if pushIfAllowed(.harshBraking, detail: String(format: "%.1f m/s²", accel), now: now) {
                triggered = .harshBraking
            }
        }
        return triggered
    }

    private func pushIfAllowed(_ event: Event, detail: String, now: Date) -> Bool {
        let key = event.rawValue
        if let last = lastEventAt[key], now.timeIntervalSince(last) < 8 { return false }
        lastEventAt[key] = now
        push(event, detail: detail, now: now)
        return true
    }

    private func push(_ event: Event, detail: String, now: Date) {
        score = max(0, score - event.penalty)
        log.insert(LogItem(event: event, at: now, detail: detail), at: 0)
        if log.count > 40 { log.removeLast(log.count - 40) }
    }

    var grade: String {
        switch score {
        case 90...: return "优秀"
        case 75..<90: return "良好"
        case 60..<75: return "一般"
        default: return "需注意"
        }
    }
}
