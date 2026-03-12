import Cocoa
import AVFoundation
import MediaPlayer

// MARK: - Constants

let APP_NAME = "TTSPlayer"
let SOCKET_PATH = "/tmp/tts_player.sock"
let SEEK_SECONDS: Double = 10
let SPEEDS: [Float] = [1.0, 1.25, 1.5, 1.75, 2.0]
let OUTPUT_PATH = "/tmp/tts_output.mp3"
let LOG_FILE = "/tmp/tts_player.log"

let VOICE_RU = "ru-RU-DmitryNeural"
let VOICE_EN = "en-US-BrianMultilingualNeural"

let DATA_DIR: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.local/share/tts-player"
}()

// MARK: - SF Symbols Helper

func sfIcon(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
}

func sfTemplate(_ name: String, size: CGFloat = 14) -> NSImage? {
    let img = sfIcon(name, size: size, weight: .medium)
    img?.isTemplate = true
    return img
}

// MARK: - Language Detection

func detectLanguage(_ text: String) -> String {
    var cyrillic = 0
    var total = 0
    for scalar in text.unicodeScalars {
        if scalar.value >= 0x0400 && scalar.value <= 0x04FF {
            cyrillic += 1
            total += 1
        } else if CharacterSet.letters.contains(scalar) {
            total += 1
        }
    }
    return (total > 0 && Double(cyrillic) / Double(total) > 0.3) ? "ru" : "en"
}

// MARK: - Hotkey Config

struct HotkeyConfig {
    var keyCode: Int64
    var cmd: Bool
    var ctrl: Bool
    var shift: Bool
    var alt: Bool

    static let defaultConfig = HotkeyConfig(keyCode: 1, cmd: true, ctrl: true, shift: false, alt: false)

    func save() {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: "hotkey_keyCode")
        d.set(cmd, forKey: "hotkey_cmd")
        d.set(ctrl, forKey: "hotkey_ctrl")
        d.set(shift, forKey: "hotkey_shift")
        d.set(alt, forKey: "hotkey_alt")
    }

    static func load() -> HotkeyConfig {
        let d = UserDefaults.standard
        guard d.object(forKey: "hotkey_keyCode") != nil else { return .defaultConfig }
        return HotkeyConfig(
            keyCode: Int64(d.integer(forKey: "hotkey_keyCode")),
            cmd: d.bool(forKey: "hotkey_cmd"),
            ctrl: d.bool(forKey: "hotkey_ctrl"),
            shift: d.bool(forKey: "hotkey_shift"),
            alt: d.bool(forKey: "hotkey_alt")
        )
    }

    var displayString: String {
        var s = ""
        if ctrl { s += "⌃" }
        if alt { s += "⌥" }
        if shift { s += "⇧" }
        if cmd { s += "⌘" }
        s += keyCodeName(keyCode)
        return s
    }

    func matches(_ code: Int64, _ flags: CGEventFlags) -> Bool {
        return code == keyCode
            && flags.contains(.maskCommand) == cmd
            && flags.contains(.maskControl) == ctrl
            && flags.contains(.maskShift) == shift
            && flags.contains(.maskAlternate) == alt
    }
}

let KEY_NAMES: [Int64: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
    8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
    16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
    23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
    30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
    37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
    44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
    50: "`", 51: "⌫", 53: "⎋",
    96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
    101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10",
    111: "F12", 113: "F15", 118: "F4", 120: "F2", 122: "F1",
    123: "←", 124: "→", 125: "↓", 126: "↑",
]

func keyCodeName(_ code: Int64) -> String {
    return KEY_NAMES[code] ?? "Key\(code)"
}

var globalHotkeyConfig = HotkeyConfig.load()

// MARK: - Logging

func ttsLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: LOG_FILE) {
            if let fh = FileHandle(forWritingAtPath: LOG_FILE) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: LOG_FILE, contents: data)
        }
    }
}

// MARK: - Global Hotkey via CGEvent Tap

var globalPlayerRef: TTSPlayer?

func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .keyDown {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        if globalHotkeyConfig.matches(keyCode, flags) {
            ttsLog("Hotkey \(globalHotkeyConfig.displayString) detected!")
            DispatchQueue.main.async {
                globalPlayerRef?.handleGlobalHotkey()
            }
            return nil
        }
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        ttsLog("Event tap disabled, re-enabling...")
        if let tap = globalPlayerRef?.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    return Unmanaged.passUnretained(event)
}

// MARK: - Slider View for Menu Item

class SeekSliderView: NSView {
    let slider = NSSlider()
    let currentLabel = NSTextField(labelWithString: "0:00")
    let durationLabel = NSTextField(labelWithString: "0:00")

    weak var delegate: TTSPlayer?
    var isSeeking = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setup() {
        let padding: CGFloat = 16
        let labelW: CGFloat = 36
        let height: CGFloat = 30

        frame = NSRect(x: 0, y: 0, width: 250, height: height)

        currentLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        currentLabel.textColor = .secondaryLabelColor
        currentLabel.alignment = .right
        currentLabel.frame = NSRect(x: padding, y: 6, width: labelW, height: 16)

        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 0
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.isContinuous = true
        slider.frame = NSRect(x: padding + labelW + 6, y: 6, width: 250 - 2 * padding - 2 * labelW - 12, height: 20)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        durationLabel.textColor = .secondaryLabelColor
        durationLabel.alignment = .left
        durationLabel.frame = NSRect(x: 250 - padding - labelW, y: 6, width: labelW, height: 16)

        addSubview(currentLabel)
        addSubview(slider)
        addSubview(durationLabel)
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        let event = NSApp.currentEvent
        if event?.type == .leftMouseDown || event?.type == .leftMouseDragged {
            isSeeking = true
        }
        if event?.type == .leftMouseUp {
            isSeeking = false
            delegate?.seekFromSlider(sender.doubleValue)
        }
        if isSeeking {
            delegate?.updateTimeFromSlider(sender.doubleValue)
        }
    }

    func update(current: Double, duration: Double) {
        guard !isSeeking else { return }
        if duration > 0 {
            slider.doubleValue = current / duration
        } else {
            slider.doubleValue = 0
        }
        currentLabel.stringValue = formatTime(current)
        durationLabel.stringValue = formatTime(duration)
    }

    func reset() {
        slider.doubleValue = 0
        currentLabel.stringValue = "0:00"
        durationLabel.stringValue = "0:00"
    }

    func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

// MARK: - Hotkey Recorder Window

class HotkeyRecorderWindow: NSPanel {
    var onRecord: ((HotkeyConfig) -> Void)?
    let label = NSTextField(labelWithString: "")
    let hintLabel = NSTextField(labelWithString: "Press desired key combination\nor Esc to cancel")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Record Hotkey"
        isReleasedWhenClosed = false
        level = .floating
        center()

        hintLabel.alignment = .center
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.frame = NSRect(x: 20, y: 60, width: 260, height: 40)

        label.alignment = .center
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.frame = NSRect(x: 20, y: 20, width: 260, height: 36)
        label.stringValue = globalHotkeyConfig.displayString

        contentView?.addSubview(hintLabel)
        contentView?.addSubview(label)
    }

    override var canBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let code = Int64(event.keyCode)

        if code == 53 {
            close()
            return
        }

        let flags = event.modifierFlags
        let hasModifier = flags.contains(.command) || flags.contains(.control)
            || flags.contains(.option) || flags.contains(.shift)

        guard hasModifier else { return }

        let config = HotkeyConfig(
            keyCode: code,
            cmd: flags.contains(.command),
            ctrl: flags.contains(.control),
            shift: flags.contains(.shift),
            alt: flags.contains(.option)
        )

        label.stringValue = config.displayString

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.onRecord?(config)
            self?.close()
        }
    }
}

// MARK: - Player App

class TTSPlayer: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var player: AVPlayer?
    var speed: Float = {
        let saved = UserDefaults.standard.float(forKey: "tts_speed")
        return saved > 0 ? saved : 1.0
    }()
    var playing = false
    var speedItems: [Float: NSMenuItem] = [:]
    var playPauseItem: NSMenuItem!
    var endObserver: Any?
    var timeObserver: Any?
    var seekSliderView: SeekSliderView!

    // Loading state
    var generateProcess: Process?
    var isLoading = false
    var statusMenuItem: NSMenuItem!

    // Global hotkey
    var eventTap: CFMachPort?
    var hotkeyMenuItem: NSMenuItem!
    var hotkeyRecorder: HotkeyRecorderWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupRemoteCommands()
        requestAccessibilityIfNeeded()
        setupGlobalHotkey()
        startSocketListener()
    }

    // MARK: - Accessibility Permissions

    func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            NSLog("TTS Player: Accessibility permission required. Please grant it in System Settings.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        generateProcess?.terminate()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        unlink(SOCKET_PATH)
    }

    // MARK: - Edge TTS path

    var edgeTTSPath: String {
        return "\(DATA_DIR)/.venv/bin/edge-tts"
    }

    // MARK: - Global Hotkey

    func setupGlobalHotkey() {
        globalPlayerRef = self

        guard AXIsProcessTrusted() else {
            NSLog("TTS Player: Accessibility not granted yet. Hotkey will not work until permission is given.")
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    NSLog("TTS Player: Accessibility granted! Setting up hotkey.")
                    self?.installEventTap()
                }
            }
            return
        }

        installEventTap()
    }

    func installEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            NSLog("TTS Player: Failed to create event tap. Check Accessibility permissions.")
            return
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ttsLog("Global hotkey \(globalHotkeyConfig.displayString) registered via CGEvent tap.")
    }

    func handleGlobalHotkey() {
        ttsLog("handleGlobalHotkey called")

        if !AXIsProcessTrusted() {
            NSLog("TTS Player: Not trusted for Accessibility. Opening System Settings.")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }

        getSelectedText { [weak self] text in
            guard let self = self, let text = text, !text.isEmpty else { return }

            let lang = detectLanguage(text)
            let voice = lang == "ru" ? VOICE_RU : VOICE_EN

            let textFile = "/tmp/tts_input_\(ProcessInfo.processInfo.processIdentifier)_\(Int(Date().timeIntervalSince1970 * 1000)).txt"
            do {
                try text.write(toFile: textFile, atomically: true, encoding: .utf8)
                self.generateAndPlay(voice: voice, textFile: textFile)
            } catch {
                ttsLog("Failed to write text file: \(error)")
            }
        }
    }

    func getSelectedText(completion: @escaping (String?) -> Void) {
        ttsLog("getSelectedText: starting")

        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        ttsLog("getSelectedText: Cmd+C posted")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if let tap = self?.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }

            let newText = pasteboard.string(forType: .string)
            ttsLog("getSelectedText: clipboard text = \(newText?.prefix(50).description ?? "nil")")

            pasteboard.clearContents()
            if let old = oldContents {
                pasteboard.setString(old, forType: .string)
            }

            completion(newText)
        }
    }

    // MARK: - Menu Bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = false
        statusItem.button?.image = sfTemplate("speaker.wave.2.fill", size: 15)

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        statusMenuItem.isHidden = true
        menu.addItem(statusMenuItem)

        playPauseItem = NSMenuItem(title: "Play / Pause", action: #selector(onToggle), keyEquivalent: "")
        playPauseItem.target = self
        playPauseItem.image = sfIcon("playpause.fill")
        menu.addItem(playPauseItem)

        let stop = NSMenuItem(title: "Stop", action: #selector(onStop), keyEquivalent: "")
        stop.target = self
        stop.image = sfIcon("stop.fill")
        menu.addItem(stop)

        menu.addItem(.separator())

        seekSliderView = SeekSliderView()
        seekSliderView.delegate = self
        let sliderItem = NSMenuItem()
        sliderItem.view = seekSliderView
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        let rw = NSMenuItem(title: "−10 sec", action: #selector(onRewind), keyEquivalent: "")
        rw.target = self
        rw.image = sfIcon("gobackward.10")
        menu.addItem(rw)

        let fw = NSMenuItem(title: "+10 sec", action: #selector(onForward), keyEquivalent: "")
        fw.target = self
        fw.image = sfIcon("goforward.10")
        menu.addItem(fw)

        menu.addItem(.separator())

        let speedMenu = NSMenu()
        let speedMenuItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedMenuItem.image = sfIcon("speedometer")
        speedMenuItem.submenu = speedMenu

        for s in SPEEDS {
            let marker = s == speed ? "●" : "○"
            let item = NSMenuItem(title: " \(marker)  \(s)x", action: #selector(onSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(s * 100)
            speedItems[s] = item
            speedMenu.addItem(item)
        }

        menu.addItem(speedMenuItem)
        menu.addItem(.separator())

        hotkeyMenuItem = NSMenuItem(title: "Hotkey: \(globalHotkeyConfig.displayString)", action: #selector(onChangeHotkey), keyEquivalent: "")
        hotkeyMenuItem.target = self
        hotkeyMenuItem.image = sfIcon("keyboard")
        menu.addItem(hotkeyMenuItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit TTS Player", action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        quit.image = sfIcon("xmark.circle")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Remote Commands (Media Keys + Now Playing)

    func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in self?.doResume(); return .success }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in self?.doPause(); return .success }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.doToggle(); return .success }

        cc.stopCommand.isEnabled = true
        cc.stopCommand.addTarget { [weak self] _ in self?.doStop(); return .success }

        cc.skipForwardCommand.isEnabled = true
        cc.skipForwardCommand.preferredIntervals = [NSNumber(value: SEEK_SECONDS)]
        cc.skipForwardCommand.addTarget { [weak self] _ in self?.seekRelative(SEEK_SECONDS); return .success }

        cc.skipBackwardCommand.isEnabled = true
        cc.skipBackwardCommand.preferredIntervals = [NSNumber(value: SEEK_SECONDS)]
        cc.skipBackwardCommand.addTarget { [weak self] _ in self?.seekRelative(-SEEK_SECONDS); return .success }

        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.seekAbsolute(e.positionTime)
            }
            return .success
        }
    }

    // MARK: - TTS Generation

    func generateAndPlay(voice: String, textFile: String) {
        if let proc = generateProcess, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        generateProcess = nil

        if playing {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            playing = false
        }

        isLoading = true
        updateIcon()
        setLoadingStatus("Generating speech...")

        let info: [String: Any] = [
            MPMediaItemPropertyTitle: "Generating speech...",
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: 0.0),
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        let process = Process()
        process.executableURL = URL(fileURLWithPath: edgeTTSPath)
        process.arguments = ["--voice", voice, "--file", textFile, "--write-media", OUTPUT_PATH]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        generateProcess = process

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try process.run()
                process.waitUntilExit()

                DispatchQueue.main.async {
                    guard self?.generateProcess === process else {
                        try? FileManager.default.removeItem(atPath: textFile)
                        return
                    }

                    self?.isLoading = false
                    self?.setLoadingStatus(nil)

                    if process.terminationStatus == 0 {
                        self?.playFile(OUTPUT_PATH)
                    } else {
                        self?.updateIcon()
                        self?.clearNowPlaying()
                    }

                    try? FileManager.default.removeItem(atPath: textFile)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isLoading = false
                    self?.setLoadingStatus(nil)
                    self?.updateIcon()
                    self?.clearNowPlaying()
                    try? FileManager.default.removeItem(atPath: textFile)
                }
            }
        }
    }

    // MARK: - Loading Status

    func setLoadingStatus(_ text: String?) {
        if let text = text {
            statusMenuItem.title = text
            statusMenuItem.image = sfIcon("icloud.and.arrow.down")
            statusMenuItem.isHidden = false
        } else {
            statusMenuItem.isHidden = true
        }
    }

    // MARK: - Playback

    func playFile(_ path: String) {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        if let obs = timeObserver {
            player?.removeTimeObserver(obs)
            timeObserver = nil
        }

        let url = URL(fileURLWithPath: path)
        let item = AVPlayerItem(url: url)

        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }

        player?.rate = speed
        playing = true
        updateIcon()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.playing = false
            self?.player?.replaceCurrentItem(with: nil)
            self?.updateIcon()
            self?.clearNowPlaying()
            self?.seekSliderView.reset()
        }

        let interval = CMTimeMakeWithSeconds(0.25, preferredTimescale: 1000)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.updateNowPlaying()
            self?.updateSlider()
        }

        updateNowPlaying()
        updateSlider()
    }

    func doResume() {
        guard player != nil else { return }
        player?.play()
        player?.rate = speed
        playing = true
        updateIcon()
        updateNowPlaying()
    }

    func doPause() {
        player?.pause()
        playing = false
        updateIcon()
        updateNowPlaying()
    }

    func doToggle() {
        if playing { doPause() } else { doResume() }
    }

    func doStop() {
        if let proc = generateProcess, proc.isRunning {
            proc.terminate()
        }
        generateProcess = nil
        isLoading = false
        setLoadingStatus(nil)

        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playing = false
        updateIcon()
        clearNowPlaying()
        seekSliderView.reset()
    }

    func seekRelative(_ delta: Double) {
        guard let p = player else { return }
        let current = CMTimeGetSeconds(p.currentTime())
        seekAbsolute(current + delta)
    }

    func seekAbsolute(_ seconds: Double) {
        guard let p = player, let item = p.currentItem else { return }
        let duration = CMTimeGetSeconds(item.duration)
        guard duration.isFinite else { return }
        let clamped = max(0, min(seconds, duration))
        p.seek(to: CMTimeMakeWithSeconds(clamped, preferredTimescale: 1000))
        updateNowPlaying()
        updateSlider()
    }

    func seekFromSlider(_ fraction: Double) {
        guard let item = player?.currentItem else { return }
        let duration = CMTimeGetSeconds(item.duration)
        guard duration.isFinite else { return }
        seekAbsolute(fraction * duration)
    }

    func updateTimeFromSlider(_ fraction: Double) {
        guard let item = player?.currentItem else { return }
        let duration = CMTimeGetSeconds(item.duration)
        guard duration.isFinite else { return }
        seekSliderView.currentLabel.stringValue = seekSliderView.formatTime(fraction * duration)
    }

    func setSpeedValue(_ newSpeed: Float) {
        speed = newSpeed
        UserDefaults.standard.set(speed, forKey: "tts_speed")
        if playing { player?.rate = speed }
        updateSpeedMenu()
        updateNowPlaying()
    }

    // MARK: - Now Playing Info

    func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Text to Speech",
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: playing ? speed : 0.0),
        ]

        if let item = player?.currentItem {
            let duration = CMTimeGetSeconds(item.duration)
            let elapsed = CMTimeGetSeconds(player?.currentTime() ?? .zero)
            if duration.isFinite { info[MPMediaItemPropertyPlaybackDuration] = duration }
            if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - UI Updates

    func updateIcon() {
        DispatchQueue.main.async {
            if self.isLoading {
                self.statusItem.button?.image = sfTemplate("icloud.and.arrow.down", size: 15)
                self.statusItem.isVisible = true
            } else if self.playing {
                self.statusItem.button?.image = sfTemplate("speaker.wave.2.fill", size: 15)
                self.statusItem.isVisible = true
            } else if self.player?.currentItem != nil {
                self.statusItem.button?.image = sfTemplate("pause.fill", size: 15)
                self.statusItem.isVisible = true
            } else {
                self.statusItem.isVisible = false
            }
        }
    }

    func updateSlider() {
        guard let item = player?.currentItem else { return }
        let duration = CMTimeGetSeconds(item.duration)
        let current = CMTimeGetSeconds(player?.currentTime() ?? .zero)
        guard duration.isFinite && current.isFinite else { return }
        seekSliderView.update(current: current, duration: duration)
    }

    func updateSpeedMenu() {
        for (s, item) in speedItems {
            let marker = s == speed ? "●" : "○"
            item.title = " \(marker)  \(s)x"
        }
    }

    // MARK: - Menu Actions

    @objc func onToggle() { doToggle() }
    @objc func onStop() { doStop() }
    @objc func onRewind() { seekRelative(-SEEK_SECONDS) }
    @objc func onForward() { seekRelative(SEEK_SECONDS) }

    @objc func onSpeed(_ sender: NSMenuItem) {
        setSpeedValue(Float(sender.tag) / 100.0)
    }

    @objc func onChangeHotkey() {
        let recorder = HotkeyRecorderWindow()
        recorder.onRecord = { [weak self] config in
            globalHotkeyConfig = config
            config.save()
            self?.hotkeyMenuItem.title = "Hotkey: \(config.displayString)"
            ttsLog("Hotkey changed to \(config.displayString)")
        }
        recorder.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hotkeyRecorder = recorder
    }

    @objc func onQuit() {
        generateProcess?.terminate()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        unlink(SOCKET_PATH)
        NSApp.terminate(nil)
    }

    // MARK: - Socket Listener (IPC)

    func startSocketListener() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            unlink(SOCKET_PATH)

            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)

            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { ptr in
                    _ = SOCKET_PATH.withCString { strncpy(ptr, $0, 103) }
                }
            }

            withUnsafePointer(to: addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }

            Darwin.listen(fd, 5)

            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { continue }

                var buf = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.read(client, &buf, buf.count)

                guard n > 0 else { Darwin.close(client); continue }
                let cmd = String(bytes: buf[0..<n], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async {
                    self?.handleCommand(cmd, clientFd: client)
                }
            }
        }
    }

    func handleCommand(_ cmd: String, clientFd: Int32) {
        if cmd == "STATUS" {
            let response = buildStatusJSON()
            if let data = response.data(using: .utf8) {
                data.withUnsafeBytes { ptr in
                    _ = Darwin.write(clientFd, ptr.baseAddress!, data.count)
                }
            }
            Darwin.close(clientFd)
            return
        }

        Darwin.close(clientFd)

        if cmd == "QUIT" {
            ttsLog("Received QUIT command, terminating.")
            onQuit()
            return
        } else if cmd.hasPrefix("TTS:") {
            let parts = cmd.dropFirst(4).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            generateAndPlay(voice: parts[0], textFile: parts[1])
        } else if cmd.hasPrefix("PLAY:") {
            playFile(String(cmd.dropFirst(5)))
        } else if cmd == "TOGGLE" {
            doToggle()
        } else if cmd == "STOP" {
            doStop()
        } else if cmd == "FORWARD" {
            seekRelative(SEEK_SECONDS)
        } else if cmd == "REWIND" {
            seekRelative(-SEEK_SECONDS)
        } else if cmd.hasPrefix("SPEED:") {
            if let val = Float(String(cmd.dropFirst(6))) {
                setSpeedValue(val)
            }
        }
    }

    func buildStatusJSON() -> String {
        var state: String
        if isLoading {
            state = "loading"
        } else if playing {
            state = "playing"
        } else if player?.currentItem != nil {
            state = "paused"
        } else {
            state = "idle"
        }

        var position: Double = 0
        var duration: Double = 0
        if let p = player, let item = p.currentItem {
            let d = CMTimeGetSeconds(item.duration)
            let c = CMTimeGetSeconds(p.currentTime())
            if d.isFinite { duration = d }
            if c.isFinite { position = c }
        }

        return """
        {"state":"\(state)","position":\(String(format:"%.1f",position)),"duration":\(String(format:"%.1f",duration)),"speed":\(String(format:"%.2f",speed))}
        """
    }
}

// MARK: - CLI Status Check

func sendSocketCommand(_ command: String) -> String? {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: 104) { ptr in
            _ = SOCKET_PATH.withCString { strncpy(ptr, $0, 103) }
        }
    }

    let connected = withUnsafePointer(to: addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }

    _ = command.withCString { ptr in
        Darwin.write(fd, ptr, strlen(ptr))
    }

    var buf = [UInt8](repeating: 0, count: 8192)
    let n = Darwin.read(fd, &buf, buf.count)
    guard n > 0 else { return "" }
    return String(bytes: buf[0..<n], encoding: .utf8)
}

func isAlreadyRunning() -> Bool {
    return sendSocketCommand("STATUS") != nil
}

func resolveExecutablePath() -> String {
    let arg0 = CommandLine.arguments[0]
    if arg0.contains("/") {
        return (arg0 as NSString).standardizingPath
    }
    // Search in PATH
    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(arg0)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
    }
    return arg0
}

func launchDaemon() {
    let execPath = resolveExecutablePath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: execPath)
    process.arguments = ["--daemon"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        fputs("Failed to start: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// MARK: - Entry Point

let args = CommandLine.arguments

if args.count > 1 {
    switch args[1] {
    case "status":
        if let response = sendSocketCommand("STATUS") {
            print("Running")
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { print(trimmed) }
        } else {
            print("Not running")
        }
        exit(0)

    case "kill":
        if isAlreadyRunning() {
            _ = sendSocketCommand("QUIT")
            print("TTS Player stopped.")
        } else {
            print("Not running")
        }
        exit(0)

    case "play":
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            fputs("Error: clipboard is empty or contains no text\n", stderr)
            exit(1)
        }
        let lang = detectLanguage(text)
        let voice = lang == "ru" ? VOICE_RU : VOICE_EN
        let pid = ProcessInfo.processInfo.processIdentifier
        let timestamp = Int(Date().timeIntervalSince1970)
        let tempFile = "/tmp/tts_input_\(pid)_\(timestamp).txt"
        do {
            try text.write(toFile: tempFile, atomically: true, encoding: .utf8)
        } catch {
            fputs("Error: failed to write temp file: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        if !isAlreadyRunning() {
            launchDaemon()
            var waited = 0.0
            while waited < 3.0 && !isAlreadyRunning() {
                Thread.sleep(forTimeInterval: 0.2)
                waited += 0.2
            }
            if !isAlreadyRunning() {
                fputs("Error: failed to start TTS Player daemon\n", stderr)
                exit(1)
            }
        }
        _ = sendSocketCommand("TTS:\(voice):\(tempFile)")
        print("Playing clipboard text (\(text.count) chars, \(lang))")
        exit(0)

    case "--daemon":
        break // continue to app launch below

    default:
        fputs("Usage: tts_player [status|kill|play]\n", stderr)
        exit(1)
    }
}

// No arguments — check if already running, if not — fork to background
if args.count == 1 {
    if isAlreadyRunning() {
        print("Already running")
        exit(0)
    }
    launchDaemon()
    print("TTS Player started.")
    exit(0)
}

let app = NSApplication.shared
let delegate = TTSPlayer()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
