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
    @State private var selectedView: GuestViewMode = .simulatorInitialView

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConsoleStatusBar(performanceFeed: model.performanceFeed)
                Picker("Guest view", selection: $selectedView) {
                    Label("Terminal", systemImage: "terminal").tag(GuestViewMode.terminal)
                    Label("Display", systemImage: "display").tag(GuestViewMode.display)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))

                switch selectedView {
                case .terminal:
                    TerminalConsole(text: model.terminalText)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            terminalFocused = true
                        }
                    CommandBar(
                        prompt: model.terminalPromptLabel,
                        canSend: model.canSendTerminalInput,
                        focused: $terminalFocused,
                        sendBytes: model.sendTerminalBytes
                    )
                case .display:
                    GuestFramebufferView(
                        feed: model.displayFeed,
                        focused: $displayFocused,
                        onTouch: model.sendTouch,
                        copyFrame: model.withDisplayFrameBytes,
                        onPresented: model.recordDisplayPresented,
                        sendText: model.sendGuestKeyboardText,
                        sendKey: model.sendGuestKey
                    )
                }
            }
            .background(Color.black)
            .navigationTitle("Pinecone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selectedView == .display {
                        Button {
                            displayFocused.toggle()
                            if !displayFocused {
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.resignFirstResponder),
                                    to: nil,
                                    from: nil,
                                    for: nil
                                )
                            }
                        } label: {
                            Image(systemName: displayFocused ? "keyboard.chevron.compact.down" : "keyboard")
                        }
                        .accessibilityLabel(displayFocused ? "Hide guest keyboard" : "Show guest keyboard")
                    }

                    Button {
                        Task { await model.boot() }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Reset VM")
                    .disabled(model.status == .booting)

                    Button {
                        model.sendTerminalBytes(Array("reboot\n".utf8))
                    } label: {
                        Image(systemName: "power")
                    }
                    .accessibilityLabel("Reboot guest")
                    .disabled(model.status != .running)

                    Button {
                        model.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .accessibilityLabel("Stop VM")
                    .disabled(model.status != .running && model.status != .booting)
                }
            }
            .task {
                guard model.status == .idle else {
                    return
                }
                await model.boot()
                terminalFocused = true
            }
            .onChange(of: model.status) { _, status in
                if status == .running && selectedView == .terminal {
                    terminalFocused = true
                }
            }
            .onChange(of: selectedView) { _, view in
                if view == .terminal {
                    displayFocused = false
                    terminalFocused = true
                } else {
                    terminalFocused = false
                    displayFocused = false
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
            }
        }
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
    @State private var lastTouchPoint: (x: UInt32, y: UInt32)?

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
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard let layout,
                              let point = Self.guestPoint(
                                value.location,
                                containerSize: geometry.size,
                                layout: layout
                              ) else {
                            return
                        }
                        lastTouchPoint = point
                        onTouch(point.x, point.y, true)
                    }
                    .onEnded { value in
                        let point = layout.flatMap {
                            Self.guestPoint(value.location, containerSize: geometry.size, layout: $0)
                        } ?? lastTouchPoint
                        if let point {
                            if lastTouchPoint?.x != point.x || lastTouchPoint?.y != point.y {
                                onTouch(point.x, point.y, true)
                            }
                            onTouch(point.x, point.y, false)
                        }
                        lastTouchPoint = nil
                    }
            )
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
        let steps: UInt32 = 32
        Task { @MainActor in
            for step in 0...steps {
                let y = startY - ((startY - endY) * step / steps)
                onTouch(x, y, true)
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            onTouch(x, endY, false)
        }
    }

    private static func guestPoint(
        _ location: CGPoint,
        containerSize: CGSize,
        layout: GuestDisplayLayout
    ) -> (x: UInt32, y: UInt32)? {
        let viewport = viewport(in: containerSize, layout: layout)
        guard viewport.width > 0, viewport.height > 0,
              viewport.contains(location) else {
            return nil
        }
        let x = min(
            layout.width - 1,
            max(0, Int((location.x - viewport.minX) * CGFloat(layout.width) / viewport.width))
        )
        let y = min(
            layout.height - 1,
            max(0, Int((location.y - viewport.minY) * CGFloat(layout.height) / viewport.height))
        )
        return (UInt32(x), UInt32(y))
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
        let scale = min(
            containerSize.width / CGFloat(layout.width),
            containerSize.height / CGFloat(layout.height)
        )
        let size = CGSize(
            width: CGFloat(layout.width) * scale,
            height: CGFloat(layout.height) * scale
        )
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct ConsoleStatusBar: View {
    @EnvironmentObject private var model: MobileOSHostModel
    @ObservedObject var performanceFeed: HostPerformanceFeed

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .foregroundStyle(Color(red: 0.34, green: 0.86, blue: 0.68))
                Text("ttyAMA0")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                Spacer()
                Text(
                    performanceFeed.snapshot.summary.isEmpty
                        ? performanceFeed.snapshot.steps.formatted()
                        : performanceFeed.snapshot.summary
                )
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(model.status.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if let lastError = model.lastError {
                Text(lastError)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private var statusColor: Color {
        switch model.status {
        case .idle:
            return .secondary
        case .booting:
            return .orange
        case .running:
            return Color(red: 0.16, green: 0.62, blue: 0.40)
        case .stopped:
            return .secondary
        case .failed:
            return .red
        }
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

private struct CommandBar: View {
    let prompt: String
    let canSend: Bool
    @Binding var focused: Bool
    let sendBytes: ([UInt8]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(prompt)
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color(red: 0.72, green: 0.96, blue: 0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: 112, alignment: .leading)

                ZStack(alignment: .leading) {
                    TerminalKeyboardBridge(
                        focused: $focused,
                        isEnabled: canSend,
                        sendBytes: sendBytes
                    )
                    .frame(width: 1, height: 1)
                    .opacity(0.01)

                    HStack(spacing: 6) {
                        Capsule()
                            .fill(focused ? Color(red: 0.34, green: 0.86, blue: 0.68) : Color.secondary)
                            .frame(width: 8, height: 18)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(focused ? 0.30 : 0.16), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focused = true
                    }
                }

                TerminalKeyButton(systemImage: "arrow.left", bytes: [0x1b, 0x5b, 0x44], canSend: canSend, sendBytes: sendBytes)
                TerminalKeyButton(systemImage: "arrow.right", bytes: [0x1b, 0x5b, 0x43], canSend: canSend, sendBytes: sendBytes)
                TerminalPasteButton(canSend: canSend, sendBytes: sendBytes)
                TerminalControlMenu(canSend: canSend, sendBytes: sendBytes)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            HStack(spacing: 8) {
                TerminalKeyButton(systemImage: "arrow.up", bytes: [0x1b, 0x5b, 0x41], canSend: canSend, sendBytes: sendBytes)
                TerminalKeyButton(systemImage: "arrow.down", bytes: [0x1b, 0x5b, 0x42], canSend: canSend, sendBytes: sendBytes)
                TerminalKeyButton(systemImage: "arrow.right.to.line", bytes: [0x09], canSend: canSend, sendBytes: sendBytes)
                TerminalKeyButton(systemImage: "escape", bytes: [0x1b], canSend: canSend, sendBytes: sendBytes)
                TerminalKeyButton(systemImage: "delete.left", bytes: [0x7f], canSend: canSend, sendBytes: sendBytes)
                TerminalKeyButton(systemImage: "return", bytes: [0x0a], canSend: canSend, sendBytes: sendBytes)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(red: 0.035, green: 0.043, blue: 0.039))
    }
}

private struct TerminalPasteButton: View {
    let canSend: Bool
    let sendBytes: ([UInt8]) -> Void

    var body: some View {
        Button {
            guard let text = UIPasteboard.general.string, !text.isEmpty else {
                return
            }
            sendBytes(Array(text.utf8))
        } label: {
            Image(systemName: "doc.on.clipboard")
                .frame(minWidth: 26)
        }
        .buttonStyle(.bordered)
        .disabled(!canSend)
    }
}

private struct TerminalKeyButton: View {
    let systemImage: String
    let bytes: [UInt8]
    let canSend: Bool
    let sendBytes: ([UInt8]) -> Void

    var body: some View {
        Button {
            sendBytes(bytes)
        } label: {
            Image(systemName: systemImage)
                .frame(minWidth: 26)
        }
        .buttonStyle(.bordered)
        .disabled(!canSend)
    }
}

private struct TerminalControlMenu: View {
    let canSend: Bool
    let sendBytes: ([UInt8]) -> Void

    var body: some View {
        Menu {
            Button("Ctrl-C") { sendBytes([0x03]) }
            Button("Ctrl-D") { sendBytes([0x04]) }
            Button("Ctrl-L") { sendBytes([0x0c]) }
            Button("Ctrl-Z") { sendBytes([0x1a]) }
        } label: {
            Image(systemName: "control")
                .frame(minWidth: 26)
        }
        .buttonStyle(.bordered)
        .disabled(!canSend)
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
