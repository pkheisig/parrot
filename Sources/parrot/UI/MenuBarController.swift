import AppKit
import CoreGraphics

/// Compact settings popover anchored to the menu-bar icon.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    var onShortcutChanged: ((HotkeyShortcut) -> Void)?
    var onActivationModeChanged: ((ActivationMode) -> Void)?

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let settings: DictationSettings
    private let contentController: SettingsViewController

    init(modelID: String, settings: DictationSettings) {
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.contentController = SettingsViewController(
            modelID: modelID,
            shortcut: settings.shortcut,
            activationMode: settings.activationMode
        )
        super.init()

        contentController.onShortcutChanged = { [weak self] shortcut in
            self?.settings.shortcut = shortcut
            self?.onShortcutChanged?(shortcut)
            if let self {
                self.contentController.setState(self.idleText)
            }
        }
        contentController.onActivationModeChanged = { [weak self] mode in
            self?.settings.activationMode = mode
            self?.onActivationModeChanged?(mode)
            if let self {
                self.contentController.setState(self.idleText)
            }
        }
        contentController.onQuit = {
            NSApp.terminate(nil)
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 280)
        popover.contentViewController = contentController
        popover.delegate = self

        if let button = statusItem.button {
            let image = Self.birdImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Parrot settings"
        }
    }

    func setRecording(_ recording: Bool) {
        contentController.setState(recording ? "● recording" : idleText)
        statusItem.button?.appearsDisabled = false
    }

    func setTranscribing() {
        contentController.setState("transcribing…")
    }

    func setUnavailable(_ message: String) {
        contentController.setState(message)
    }

    private var idleText: String {
        let verb = settings.activationMode == .hold ? "hold" : "press"
        return "idle · \(verb) \(settings.shortcut.displayName.lowercased()) to dictate"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            contentController.setState(idleText)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

@MainActor
private final class SettingsViewController: NSViewController {
    var onShortcutChanged: ((HotkeyShortcut) -> Void)?
    var onActivationModeChanged: ((ActivationMode) -> Void)?
    var onQuit: (() -> Void)?

    private let stateLabel = NSTextField(labelWithString: "")
    private let shortcutButton = ShortcutRecorderButton()
    private let modeControl = NSSegmentedControl(
        labels: ActivationMode.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let launchAtLogin = LaunchAtLoginManager()
    private let loginCheckbox = NSButton()
    private let loginStatusLabel = NSTextField(labelWithString: "")

    init(modelID: String, shortcut: HotkeyShortcut, activationMode: ActivationMode) {
        super.init(nibName: nil, bundle: nil)

        let title = NSTextField(labelWithString: "Parrot")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        stateLabel.font = .systemFont(ofSize: 12)
        stateLabel.textColor = .secondaryLabelColor

        let modelLabel = NSTextField(labelWithString: "model: \(modelID)")
        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .tertiaryLabelColor
        modelLabel.lineBreakMode = .byTruncatingMiddle

        shortcutButton.shortcut = shortcut
        shortcutButton.toolTip = "Click, then press a shortcut. Modifier-only keys are supported."
        shortcutButton.onShortcutChanged = { [weak self] shortcut in
            self?.onShortcutChanged?(shortcut)
        }

        modeControl.selectedSegment = ActivationMode.allCases.firstIndex(of: activationMode) ?? 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        let shortcutRow = Self.row(label: "Hotkey", control: shortcutButton)
        let modeRow = Self.row(label: "Behavior", control: modeControl)

        loginCheckbox.setButtonType(.switch)
        loginCheckbox.title = "Launch Parrot at login"
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginSettingChanged)
        loginCheckbox.state = launchAtLogin.isRegistered ? .on : .off
        loginCheckbox.isEnabled = launchAtLogin.isAvailable

        loginStatusLabel.font = .systemFont(ofSize: 10)
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.maximumNumberOfLines = 2
        loginStatusLabel.lineBreakMode = .byWordWrapping
        refreshLoginStatus()

        let loginControl = NSStackView(views: [loginCheckbox, loginStatusLabel])
        loginControl.orientation = .vertical
        loginControl.alignment = .leading
        loginControl.spacing = 3
        let loginRow = Self.row(label: "Startup", control: loginControl)

        let separator = NSBox()
        separator.boxType = .separator

        let quitButton = NSButton(title: "Quit Parrot", target: self, action: #selector(quitClicked))
        quitButton.bezelStyle = .inline
        quitButton.alignment = .left
        quitButton.contentTintColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            title, stateLabel, modelLabel, shortcutRow, modeRow, loginRow, separator, quitButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(2, after: stateLabel)
        stack.setCustomSpacing(14, after: modelLabel)
        stack.setCustomSpacing(12, after: loginRow)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.addSubview(stack)
        view = container

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -12),
            shortcutRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            loginRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setState(_ text: String) {
        stateLabel.stringValue = text
    }

    private static func row(label: String, control: NSView) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 12)
        labelView.textColor = .secondaryLabelColor
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        labelView.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    @objc private func modeChanged() {
        let modes = ActivationMode.allCases
        guard modes.indices.contains(modeControl.selectedSegment) else { return }
        onActivationModeChanged?(modes[modeControl.selectedSegment])
    }

    @objc private func loginSettingChanged() {
        let requested = loginCheckbox.state == .on
        do {
            try launchAtLogin.setRegistered(requested)
        } catch {
            loginCheckbox.state = launchAtLogin.isRegistered ? .on : .off
            loginStatusLabel.textColor = .systemRed
            loginStatusLabel.stringValue = error.localizedDescription
            return
        }
        loginCheckbox.state = launchAtLogin.isRegistered ? .on : .off
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.stringValue = launchAtLogin.statusMessage ?? ""
        loginStatusLabel.isHidden = loginStatusLabel.stringValue.isEmpty
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}

@MainActor
private final class ShortcutRecorderButton: NSButton {
    var onShortcutChanged: ((HotkeyShortcut) -> Void)?
    var shortcut: HotkeyShortcut = .fn {
        didSet { title = shortcut.displayName }
    }

    private var isRecordingShortcut = false
    private var pendingModifier: (keyCode: CGKeyCode, flags: CGEventFlags)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func beginRecording() {
        isRecordingShortcut = true
        pendingModifier = nil
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {
            cancelRecording()
            return
        }

        let modifiers = Self.cgModifiers(from: event.modifierFlags)
        let functionKey = (96...126).contains(event.keyCode)
        guard !modifiers.isEmpty || functionKey else {
            NSSound.beep()
            title = "Add a modifier"
            return
        }

        commit(HotkeyShortcut(
            keyCode: CGKeyCode(event.keyCode),
            modifiersRawValue: modifiers.rawValue,
            isModifierOnly: false
        ))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecordingShortcut else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecordingShortcut,
              let flag = Self.flag(forModifierKeyCode: event.keyCode)
        else {
            super.flagsChanged(with: event)
            return
        }

        let flags = Self.cgModifiers(from: event.modifierFlags)
        if flags.contains(flag) {
            pendingModifier = (CGKeyCode(event.keyCode), flag)
            title = HotkeyShortcut(
                keyCode: CGKeyCode(event.keyCode),
                modifiersRawValue: flag.rawValue,
                isModifierOnly: true
            ).displayName
        } else if let pendingModifier {
            commit(HotkeyShortcut(
                keyCode: pendingModifier.keyCode,
                modifiersRawValue: pendingModifier.flags.rawValue,
                isModifierOnly: true
            ))
        }
    }

    override func resignFirstResponder() -> Bool {
        if isRecordingShortcut {
            cancelRecording()
        }
        return super.resignFirstResponder()
    }

    private func commit(_ shortcut: HotkeyShortcut) {
        self.shortcut = shortcut
        isRecordingShortcut = false
        pendingModifier = nil
        onShortcutChanged?(shortcut)
        window?.makeFirstResponder(nil)
    }

    private func cancelRecording() {
        isRecordingShortcut = false
        pendingModifier = nil
        title = shortcut.displayName
        window?.makeFirstResponder(nil)
    }

    private static func cgModifiers(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }

    private static func flag(forModifierKeyCode keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: .maskCommand
        case 56, 60: .maskShift
        case 58, 61: .maskAlternate
        case 59, 62: .maskControl
        case 63: .maskSecondaryFn
        default: nil
        }
    }
}
