import AVKit
import SwiftUI

/// What the camera recorded to its SD card. Primary action: watch the latest event.
/// The system player gives scrubbing and sound; the strip below picks the day and the event.
struct PlaybackView: View {
    let model: PlaybackModel
    let onLive: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Theme.videoBackground
                content
            }
            if model.phase == .ready { strip }
        }
        .background(Theme.videoBackground.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack {
            Text(model.camera.name).font(Theme.headlineFont).foregroundStyle(Theme.onVideo).lineLimit(1)
            Spacer()
            Button(action: onLive) {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(Theme.pillFont)
                    .padding(.horizontal, Theme.Space.cozy).padding(.vertical, Theme.Space.sm)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(Theme.onVideo)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("backToLive")
        }
        .padding(Theme.Space.lg)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Reading the SD card").tint(Theme.onVideo).foregroundStyle(Theme.onVideo)
        case .ready:
            VideoPlayer(player: model.player)
                .accessibilityIdentifier("playbackVideo")
                .overlay {
                    if model.preparing {
                        ProgressView().tint(Theme.onVideo).controlSize(.large)
                    } else if model.clipFailed {
                        message("Couldn't load this clip", detail: "Pick it again, or try another clip.")
                            .background(Theme.videoBackground)
                    }
                }
        case .noCard:
            message("No SD card", detail: "This camera has no memory card, so there's nothing recorded to play back.")
        case .notRecording:
            message("Not recording", detail: "This camera isn't recording to its SD card. Turn on Record to SD Card in the camera's details.")
        case .noRecordings:
            message("No recordings yet", detail: "The SD card is in, but the camera hasn't recorded anything in the last 90 days.")
        case .wrongPassword:
            message("Wrong password", detail: "Update the password in this camera's details, then open recordings again.")
        case .unreachable:
            VStack(spacing: Theme.Space.md) {
                message("Couldn't read the SD card", detail: "The camera didn't answer. Check that you're on the same network or your away address works.")
                Button("Try Again") { Task { await model.start() } }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: Theme.Space.sm) {
            Text(title).font(Theme.headlineFont).foregroundStyle(Theme.onVideo)
            Text(detail).font(Theme.captionFont).foregroundStyle(Theme.onVideo.opacity(0.7))
                .multilineTextAlignment(.center).frame(maxWidth: Theme.readableWidth)
        }
        .padding(Theme.Space.lg)
    }

    // MARK: Day and event strip

    private var strip: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(model.days, id: \.self) { day in
                        chip(Self.dayLabel(day), selected: day == model.day) { Task { await model.select(day: day) } }
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
            }
            HStack(spacing: 0) {
                if model.highlights != nil {
                    chip("Activity", selected: model.activityOnly) { model.toggleActivityOnly() }
                        .accessibilityIdentifier("activityOnly")
                        .accessibilityValue(model.activityOnly ? "Showing activity" : "Showing every clip")
                        .padding(.leading, Theme.Space.lg)
                }
                clipStrip
            }
        }
        .padding(.vertical, Theme.Space.md)
    }

    private var clipStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    if model.loadingDay {
                        ProgressView().tint(Theme.onVideo).padding(.horizontal, Theme.Space.lg)
                    } else if model.clips.isEmpty {
                        Text("Nothing recorded this day").font(Theme.captionFont).foregroundStyle(Theme.onVideo.opacity(0.7))
                    } else if model.visibleClips.isEmpty {
                        Text("No activity this day. Tap Activity to see every clip.")
                            .font(Theme.captionFont).foregroundStyle(Theme.onVideo.opacity(0.7))
                    }
                    ForEach(model.visibleClips) { clip in
                        chip(Self.clipLabel(clip), selected: clip == model.current) { model.play(clip) }
                            .id(clip.id)
                            .accessibilityLabel("Event at \(clip.start.formatted(date: .omitted, time: .shortened)), \(Self.durationText(clip.duration))")
                    }
                }
                .padding(.horizontal, Theme.Space.lg)
            }
            .onChange(of: model.current) { _, clip in
                if let clip { withAnimation { proxy.scrollTo(clip.id, anchor: .center) } }
            }
            .onAppear { if let id = model.current?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(Theme.pillFont)
                .monospacedDigit()
                .padding(.horizontal, Theme.Space.cozy).padding(.vertical, Theme.Space.sm)
                .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.pillMaterial), in: Capsule())
                .foregroundStyle(Theme.onVideo)
        }
        .buttonStyle(.plain)
    }

    static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func clipLabel(_ clip: Recording) -> String {
        "\(clip.start.formatted(date: .omitted, time: .shortened)) · \(durationText(clip.duration))"
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : "\(s / 60)m \(String(format: "%02d", s % 60))s"
    }
}
