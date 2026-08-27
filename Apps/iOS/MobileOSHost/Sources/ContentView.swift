import ARM64VizCore
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

struct ContentView: View {
    var body: some View {
        LinuxConsoleView()
    }
}

private struct LinuxConsoleView: View {
    @EnvironmentObject private var model: MobileOSHostModel
    @State private var terminalFocused = false
    @State private var displayFocused = false
    @State private var controlsPresented = false
    @State private var selectedView: GuestViewMode = .simulatorInitialView

    var body: some View {
        ZStack(alignment: .trailing) {
            guestView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            GuestControlDrawer(
                isPresented: $controlsPresented,
                selectedView: selectedView,
                keyboardVisible: activeKeyboardFocused,
                status: model.status,
                performanceFeed: model.performanceFeed,
                selectView: selectView,
                toggleKeyboard: toggleKeyboard,
                reset: {
                    dismissKeyboard()
                    Task { await model.boot() }
                },
                reboot: {
                    model.sendTerminalBytes(Array("reboot\n".utf8))
                },
                stop: {
                    dismissKeyboard()
                    model.stop()
                }
            )
            .padding(.trailing, 8)
        }
        .padding(.bottom, 8)
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            guard model.status == .idle else {
                return
            }
            await model.boot()
        }
        .onChange(of: selectedView) { _, _ in
            dismissKeyboard()
        }
        .onChange(of: model.isPhoshReady) { _, isReady in
            guard isReady else {
                return
            }
            dismissKeyboard()
            controlsPresented = false
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedView = .display
            }
        }
    }

    @ViewBuilder
    private var guestView: some View {
        switch selectedView {
        case .terminal:
            ZStack(alignment: .topLeading) {
                TerminalConsole(text: model.terminalText)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        terminalFocused = true
                    }

                TerminalKeyboardBridge(
                    focused: $terminalFocused,
                    isEnabled: model.canSendTerminalInput,
                    sendBytes: model.sendTerminalBytes
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
        case .display:
            GuestFramebufferView(
                feed: model.displayFeed,
                focused: $displayFocused,
                onTouch: model.sendTouch,
                copyFrame: model.displayFrameLease,
                onPresented: model.recordDisplayPresented,
                sendText: model.sendGuestKeyboardText,
                sendKey: model.sendGuestKey
            )
        }
    }

    private var activeKeyboardFocused: Bool {
        selectedView == .terminal ? terminalFocused : displayFocused
    }

    private func selectView(_ view: GuestViewMode) {
        guard selectedView != view else {
            controlsPresented = false
            return
        }
        dismissKeyboard()
        selectedView = view
        controlsPresented = false
    }

    private func toggleKeyboard() {
        switch selectedView {
        case .terminal:
            terminalFocused.toggle()
        case .display:
            displayFocused.toggle()
        }
        if !activeKeyboardFocused {
            resignFirstResponder()
        }
    }

    private func dismissKeyboard() {
        terminalFocused = false
        displayFocused = false
        resignFirstResponder()
    }

    private func resignFirstResponder() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

private struct GuestControlDrawer: View {
    @Binding var isPresented: Bool
    let selectedView: GuestViewMode
    let keyboardVisible: Bool
    let status: MobileOSHostModel.HostStatus
    @ObservedObject var performanceFeed: HostPerformanceFeed
    let selectView: (GuestViewMode) -> Void
    let toggleKeyboard: () -> Void
    let reset: () -> Void
    let reboot: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ExecutionCounterBadge(feed: performanceFeed)

            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        isPresented.toggle()
                    }
                } label: {
                    Image(systemName: isPresented ? "chevron.right" : "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 46)
                }
                .buttonStyle(PineconeDrawerButtonStyle())
                .accessibilityLabel(isPresented ? "Close controls" : "Open controls")

                if isPresented {
                    VStack(spacing: 6) {
                        drawerButton(
                            image: "terminal",
                            label: "Show terminal",
                            selected: selectedView == .terminal
                        ) {
                            selectView(.terminal)
                        }
                        drawerButton(
                            image: "display",
                            label: "Show guest display",
                            selected: selectedView == .display
                        ) {
                            selectView(.display)
                        }

                        Divider()
                            .overlay(Color.white.opacity(0.18))
                            .frame(width: 28)
                            .padding(.vertical, 2)

                        drawerButton(
                            image: keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard",
                            label: keyboardVisible ? "Hide keyboard" : "Show keyboard",
                            disabled: status != .running
                        ) {
                            toggleKeyboard()
                        }
                        drawerButton(
                            image: "arrow.counterclockwise",
                            label: "Reset VM",
                            disabled: status == .booting
                        ) {
                            reset()
                        }
                        drawerButton(
                            image: "power",
                            label: "Reboot guest",
                            disabled: status != .running
                        ) {
                            reboot()
                        }
                        drawerButton(
                            image: "stop.fill",
                            label: "Stop VM",
                            disabled: status != .running && status != .booting,
                            role: .destructive
                        ) {
                            stop()
                        }
                    }
                    .frame(width: 46)
                    .padding(6)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: isPresented)
    }

    private func drawerButton(
        image: String,
        label: String,
        selected: Bool = false,
        disabled: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: image)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(selected ? Color.black : Color.primary)
                .background(selected ? Color.white : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.34 : 1)
        .accessibilityLabel(label)
    }
}

private struct ExecutionCounterBadge: View {
    @ObservedObject var feed: HostPerformanceFeed

    var body: some View {
        let snapshot = feed.snapshot
        VStack(alignment: .leading, spacing: 1) {
            counterRow(label: "native", value: snapshot.nativeSteps)
            counterRow(label: "fallback", value: snapshot.fallbackSteps)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.78))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Native instructions \(snapshot.nativeSteps), fallback instructions \(snapshot.fallbackSteps)"
        )
    }

    private func counterRow(label: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Spacer(minLength: 4)
            Text(Self.compact(value))
                .foregroundStyle(Color.white)
        }
        .frame(width: 84)
    }

    private static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000_000...:
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return String(value)
        }
    }
}

private struct PineconeDrawerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private enum GuestViewMode: Hashable {
    case terminal
    case display

    static var simulatorInitialView: Self {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["PINECONE_SIMULATOR_SHOW_DISPLAY"] == "1" {
            return .display
        }
#endif
        return .terminal
    }
}

private struct GuestFramebufferView: View {
    @ObservedObject var feed: GuestDisplayFeed
    @Binding var focused: Bool
    let onTouch: (UInt32, UInt32, Bool) -> Void
    let copyFrame: GuestDisplayFrameSource
    let onPresented: GuestDisplayPresentedHandler
    let sendText: (String) -> Void
    let sendKey: (UInt16) -> Void

    var body: some View {
        GeometryReader { geometry in
            let layout = feed.layout
            let viewport = layout.map { Self.viewport(in: geometry.size, layout: $0) }
            ZStack(alignment: .topLeading) {
                Color.black
                if layout != nil {
                    GuestDisplaySurface(
                        feed: feed,
                        copyFrame: copyFrame,
                        onPresented: onPresented
                    )
                        .frame(width: viewport?.width ?? 0, height: viewport?.height ?? 0)
                        .position(x: viewport?.midX ?? 0, y: viewport?.midY ?? 0)
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                DisplayKeyboardBridge(focused: $focused, sendText: sendText, sendKey: sendKey)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                GuestTouchCaptureView(layout: layout, onTouch: onTouch)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .contentShape(Rectangle())
        }
        .background(Color.black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Guest display")
        .accessibilityAction(named: "Swipe up") {
            sendSwipeUp()
        }
    }

    private func sendSwipeUp() {
        guard let layout = feed.layout, layout.width > 0, layout.height > 0 else {
            return
        }
        let x = UInt32(layout.width / 2)
        let startY = UInt32(layout.height - 1)
        let endY: UInt32 = 0
        let steps: UInt32 = 96
        Task { @MainActor in
            for step in 0...steps {
                let y = startY - ((startY - endY) * step / steps)
                onTouch(x, y, true)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            onTouch(x, endY, false)
        }
    }

    private static func viewport(
        in containerSize: CGSize,
        layout: GuestDisplayLayout
    ) -> CGRect {
        guard containerSize.width > 0,
              containerSize.height > 0,
              layout.width > 0,
              layout.height > 0 else {
            return .zero
        }
        let availableHeight = containerSize.height
        let scale = min(
            containerSize.width / CGFloat(layout.width),
            availableHeight / CGFloat(layout.height)
        )
        let size = CGSize(
            width: CGFloat(layout.width) * scale,
            height: CGFloat(layout.height) * scale
        )
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: 0,
            width: size.width,
            height: size.height
        )
    }
}

private struct GuestTouchCaptureView: UIViewRepresentable {
    let layout: GuestDisplayLayout?
    let onTouch: (UInt32, UInt32, Bool) -> Void

    func makeUIView(context: Context) -> GuestTouchCaptureUIView {
        let view = GuestTouchCaptureUIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isMultipleTouchEnabled = false
        return view
    }

    func updateUIView(_ view: GuestTouchCaptureUIView, context: Context) {
        view.layout = layout
        view.onTouch = onTouch
        view.isUserInteractionEnabled = layout != nil
    }
}

private final class GuestTouchCaptureUIView: UIView {
    var layout: GuestDisplayLayout?
    var onTouch: ((UInt32, UInt32, Bool) -> Void)?
    private var lastPoint: (x: UInt32, y: UInt32)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              let point = guestPoint(for: touch.location(in: self)) else { return }
        lastPoint = point
        onTouch?(point.x, point.y, true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first,
              let point = guestPoint(for: touch.location(in: self)),
              point.x != lastPoint?.x || point.y != lastPoint?.y else { return }
        lastPoint = point
        onTouch?(point.x, point.y, true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch(touches.first)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch(touches.first)
    }

    private func finishTouch(_ touch: UITouch?) {
        let point = touch.flatMap { guestPoint(for: $0.location(in: self)) } ?? lastPoint
        if let point {
            if point.x != lastPoint?.x || point.y != lastPoint?.y {
                onTouch?(point.x, point.y, true)
            }
            onTouch?(point.x, point.y, false)
        }
        lastPoint = nil
    }

    private func guestPoint(for location: CGPoint) -> (x: UInt32, y: UInt32)? {
        guard let layout,
              bounds.width > 0, bounds.height > 0,
              layout.width > 0, layout.height > 0 else { return nil }
        let scale = min(
            bounds.width / CGFloat(layout.width),
            bounds.height / CGFloat(layout.height)
        )
        let viewport = CGRect(
            x: (bounds.width - CGFloat(layout.width) * scale) / 2,
            y: 0,
            width: CGFloat(layout.width) * scale,
            height: CGFloat(layout.height) * scale
        )
        let clampedLocation = CGPoint(
            x: min(viewport.maxX, max(viewport.minX, location.x)),
            y: min(viewport.maxY, max(viewport.minY, location.y))
        )
        let x = min(layout.width - 1, max(
            0,
            Int((clampedLocation.x - viewport.minX) * CGFloat(layout.width) / viewport.width)
        ))
        let y = min(layout.height - 1, max(
            0,
            Int((clampedLocation.y - viewport.minY) * CGFloat(layout.height) / viewport.height)
        ))
        return (UInt32(x), UInt32(y))
    }
}

private struct TerminalConsole: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(TerminalTextRenderer.render(text))
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(red: 0.72, green: 0.96, blue: 0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
                Color.clear
                    .frame(height: 1)
                    .id("terminal-bottom")
            }
            .background(Color.black)
            .onChange(of: text) { _, _ in
                proxy.scrollTo("terminal-bottom", anchor: .bottom)
            }
        }
    }
}

private struct TerminalKeyboardBridge: UIViewRepresentable {
    @Binding var focused: Bool
    let isEnabled: Bool
    let sendBytes: ([UInt8]) -> Void

    func makeUIView(context: Context) -> TerminalKeyboardInputView {
        let view = TerminalKeyboardInputView()
        view.sendBytes = sendBytes
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: TerminalKeyboardInputView, context: Context) {
        uiView.sendBytes = sendBytes
        uiView.isUserInteractionEnabled = isEnabled
        if focused && isEnabled {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        } else if !focused || !isEnabled {
            uiView.resignFirstResponder()
        }
    }
}

private final class TerminalKeyboardInputView: UIView, UIKeyInput {
    var sendBytes: ([UInt8]) -> Void = { _ in }

    override var canBecomeFirstResponder: Bool {
        true
    }

    var hasText: Bool {
        true
    }

    func insertText(_ text: String) {
        switch text {
        case "\n", "\r":
            sendBytes([0x0a])
        default:
            sendBytes(Array(text.utf8))
        }
    }

    func deleteBackward() {
        sendBytes([0x7f])
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "\u{1b}", modifierFlags: [], action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "c", modifierFlags: .control, action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "d", modifierFlags: .control, action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "l", modifierFlags: .control, action: #selector(handleKeyCommand(_:))),
            UIKeyCommand(input: "z", modifierFlags: .control, action: #selector(handleKeyCommand(_:)))
        ]
    }

    @objc private func handleKeyCommand(_ command: UIKeyCommand) {
        if command.modifierFlags.contains(.control), let input = command.input?.lowercased() {
            switch input {
            case "c":
                sendBytes([0x03])
            case "d":
                sendBytes([0x04])
            case "l":
                sendBytes([0x0c])
            case "z":
                sendBytes([0x1a])
            default:
                break
            }
            return
        }

        switch command.input {
        case UIKeyCommand.inputUpArrow:
            sendBytes([0x1b, 0x5b, 0x41])
        case UIKeyCommand.inputDownArrow:
            sendBytes([0x1b, 0x5b, 0x42])
        case UIKeyCommand.inputRightArrow:
            sendBytes([0x1b, 0x5b, 0x43])
        case UIKeyCommand.inputLeftArrow:
            sendBytes([0x1b, 0x5b, 0x44])
        case "\t":
            sendBytes([0x09])
        case "\u{1b}":
            sendBytes([0x1b])
        default:
            break
        }
    }
}

private struct DisplayKeyboardBridge: UIViewRepresentable {
    @Binding var focused: Bool
    let sendText: (String) -> Void
    let sendKey: (UInt16) -> Void

    func makeUIView(context: Context) -> DisplayKeyboardInputView {
        let view = DisplayKeyboardInputView()
        view.sendText = sendText
        view.sendKey = sendKey
        return view
    }

    func updateUIView(_ uiView: DisplayKeyboardInputView, context: Context) {
        uiView.sendText = sendText
        uiView.sendKey = sendKey
        if focused {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else {
            uiView.resignFirstResponder()
        }
    }
}

private final class DisplayKeyboardInputView: UIView, UIKeyInput {
    var sendText: (String) -> Void = { _ in }
    var sendKey: (UInt16) -> Void = { _ in }

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        sendText(text)
    }

    func deleteBackward() {
        sendKey(14)
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleKey(_:))),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleKey(_:))),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleKey(_:))),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleKey(_:))),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleKey(_:))),
            UIKeyCommand(input: "\u{1b}", modifierFlags: [], action: #selector(handleKey(_:)))
        ]
    }

    @objc private func handleKey(_ command: UIKeyCommand) {
        switch command.input {
        case UIKeyCommand.inputUpArrow: sendKey(103)
        case UIKeyCommand.inputDownArrow: sendKey(108)
        case UIKeyCommand.inputLeftArrow: sendKey(105)
        case UIKeyCommand.inputRightArrow: sendKey(106)
        case "\t": sendKey(15)
        case "\u{1b}": sendKey(1)
        default: break
        }
    }
}

private enum TerminalTextRenderer {
    static func render(_ raw: String) -> String {
        var lines: [[Character]] = [[]]
        var column = 0
        var index = raw.startIndex

        func ensureColumn(_ target: Int) {
            while lines[lines.count - 1].count < target {
                lines[lines.count - 1].append(" ")
            }
        }

        while index < raw.endIndex {
            let character = raw[index]
            if character == "\u{001B}" {
                let next = raw.index(after: index)
                if next < raw.endIndex, raw[next] == "[" {
                    index = raw.index(after: next)
                    while index < raw.endIndex {
                        let scalar = raw[index].unicodeScalars.first?.value ?? 0
                        let isFinalByte = scalar >= 0x40 && scalar <= 0x7e
                        let final = raw[index]
                        index = raw.index(after: index)
                        if isFinalByte {
                            if final == "K" {
                                lines[lines.count - 1].removeLast(max(0, lines[lines.count - 1].count - column))
                            } else if final == "G" {
                                column = 0
                            }
                            break
                        }
                    }
                    continue
                }
                index = raw.index(after: index)
                continue
            }

            switch character {
            case "\r":
                column = 0
            case "\n":
                lines.append([])
                column = 0
            case "\u{08}", "\u{7f}":
                if column > 0 {
                    column -= 1
                    if lines[lines.count - 1].count > column {
                        lines[lines.count - 1].remove(at: column)
                    }
                }
            default:
                ensureColumn(column)
                if lines[lines.count - 1].count == column {
                    lines[lines.count - 1].append(character)
                } else {
                    lines[lines.count - 1][column] = character
                }
                column += 1
            }
            index = raw.index(after: index)
        }

        return lines.map { String($0) }.joined(separator: "\n")
    }
}
