import AppKit
import SwiftUI

/// The menu bar popover: one switch and one line about it.
struct AwayMenu: View {
    @Binding var isOn: Bool
    let line: AwayLine
    var open: () -> Void = {}
    var quit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $isOn) {
                Text("Away").font(.headline)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("awaySwitch")
            Label {
                Text(line.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: line.symbol).foregroundStyle(line.tint)
            }
            .accessibilityIdentifier("awayStatus")
            Divider()
            HStack {
                Button("Open CamFetti", action: open)
                Spacer()
                Button("Quit", action: quit)
            }
            .buttonStyle(.link)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 290)
    }
}

/// Menu bar item, inserted only when a room token is installed.
struct AwayMenuScene: Scene {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let away = AwayController.shared
        MenuBarExtra(isInserted: .constant(AwayConfig.isAvailable)) {
            @Bindable var away = away
            AwayMenu(isOn: $away.isOn, line: away.line, open: {
                NSApp.activate()
                openWindow(id: "main")
            }, quit: { NSApp.terminate(nil) })
        } label: {
            Image(systemName: away.isOn ? "video.fill" : "video")
                .accessibilityLabel("CamFetti")
        }
        .menuBarExtraStyle(.window)
    }
}

#if DEBUG
/// `-awayMenuPreview`: every state of the menu in a plain window, for screenshots.
struct AwayMenuPreview: View {
    var body: some View {
        let states: [(Bool, AwayLine)] = [(false, .off), (true, .connecting), (true, .online), (true, .offline), (true, .sleeping)]
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(290), spacing: 20), count: 3), alignment: .leading, spacing: 20) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                AwayMenu(isOn: .constant(state.0), line: state.1)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
            }
        }
        .padding(24)
        .onAppear { NSApp.activate() }
    }
}
#endif
