import PipitAudio
import PipitCore
import PipitServices
import Observation
import SwiftUI

/// Reading a few sentences aloud, and what that leaves behind.
///
/// Optional, and offered rather than asked for: nothing about setup depends on
/// it. What it buys is recognition on the recordings that carry no microphone
/// track of their own, which is every in-person meeting and every import.
@MainActor
@Observable
public final class VoiceEnrollmentModel {
    public enum Phase: Equatable {
        case idle
        case recording
        case working
        case finished(VoiceProfileStatus)
        case failed(String)
    }

    public private(set) var phase = Phase.idle
    /// How long the current take has been running.
    public private(set) var elapsed: Double = 0
    /// The loudest sample of the last buffer, so the meter shows a live
    /// microphone rather than a spinner that means nothing.
    public private(set) var level: Double = 0

    /// Sentences chosen to be ordinary. A person reading a tongue twister
    /// performs it, and the voice a profile needs is the one they talk in.
    public static let script = [
        "We moved the review to Thursday because half the team is travelling.",
        "The build finished in about nine minutes, which is faster than last week.",
        "I read through the notes this morning and left a few questions at the end.",
        "Can you send me the link before the call so I have it open?",
        "It rained all weekend, so we stayed in and watched three films.",
        "The coffee machine broke again on Tuesday and nobody has fixed it.",
        "My flight lands at seven, so I should be online by nine at the latest.",
        "Let's leave that for now and pick it up when the numbers come back.",
    ]

    /// Roughly how long the script takes to read. The bar fills to this, and the
    /// button stays available past it, because a profile needs 45 seconds of
    /// speech and pauses do not count towards it.
    public static let targetSeconds: Double = 75

    @ObservationIgnored private let runtime: PipitRuntime
    @ObservationIgnored private let recorder = VoiceEnrollmentRecorder()
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var destination: URL?
    /// Called after a successful reading, so the page behind the sheet redraws
    /// the profile it has just changed.
    @ObservationIgnored public var onEnrolled: (() -> Void)?

    public init(runtime: PipitRuntime) {
        self.runtime = runtime
    }

    public var isRecording: Bool { phase == .recording }

    public var progress: Double {
        min(1, elapsed / Self.targetSeconds)
    }

    public func start() async {
        guard !runtime.status.isCapturing else {
            phase = .failed("A meeting is being recorded. Try again once it has finished.")
            return
        }
        let granted = await runtime.permissions.request(.microphone)
        guard granted.isUsable else {
            phase = .failed("Pipit cannot open the microphone. Grant it in System Settings.")
            return
        }
        guard let url = await runtime.newEnrollmentRecording() else {
            phase = .failed("There is nowhere to write the recording.")
            return
        }
        do {
            try recorder.start(writingTo: url)
        } catch {
            phase = .failed("The microphone did not start: \(logSafeDescription(error))")
            return
        }
        destination = url
        elapsed = 0
        level = 0
        phase = .recording
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isRecording else { return }
                self.elapsed = self.recorder.recordedSeconds
                self.level = Double(self.recorder.level)
            }
        }
    }

    public func finish() async {
        meter?.cancel()
        meter = nil
        let seconds = recorder.stop()
        level = 0
        guard let url = destination, seconds > 0 else {
            phase = .failed("Nothing was recorded.")
            return
        }
        phase = .working
        do {
            let status = try await runtime.enrolSpokenSample(audio: url)
            // The archive owns the file from here. Left set, closing the sheet
            // would delete the audio the vector was taken from, which is the
            // one copy anything could ever re-derive it from.
            destination = nil
            phase = .finished(status)
            onEnrolled?()
        } catch let error as SpokenEnrollmentError {
            try? FileManager.default.removeItem(at: url)
            phase = .failed(Self.message(for: error))
        } catch {
            phase = .failed("The recording could not be used.")
        }
    }

    /// Stops without keeping the take, for a closed sheet or a changed mind. A
    /// reading that reached a profile has already been handed to the archive,
    /// so there is nothing here to delete.
    public func cancel() {
        meter?.cancel()
        meter = nil
        recorder.stop()
        if let destination { try? FileManager.default.removeItem(at: destination) }
        destination = nil
        level = 0
        elapsed = 0
        phase = .idle
    }

    static func message(for error: SpokenEnrollmentError) -> String {
        switch error {
        case .modelsUnavailable:
            "The speech models are not installed yet, so the recording cannot be read."
        case .noSingleVoice:
            "Pipit heard either no speech or more than one voice. Record again somewhere quiet."
        case .noLocalUser:
            "Choose which person in People is you first."
        case .rejected(.tooLittleSpeech(let seconds, let required)):
            "That was \(Int(seconds)) seconds of speech. A profile needs \(Int(required)). "
                + "Read the whole script, at your normal pace."
        case .rejected(let rejection):
            "The recording could not be used: \(rejection.description)."
        }
    }
}

public struct VoiceEnrollmentView: View {
    let model: VoiceEnrollmentModel
    let onClose: () -> Void

    public init(model: VoiceEnrollmentModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Learn my voice").font(.title3)
                Text(
                    "Read the sentences below out loud. The recording becomes a voice profile, "
                        + "which is how Pipit recognises you on a recording with no microphone "
                        + "track of its own: an in-person meeting, or an imported file."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            script
            state
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(width: 520, height: 520)
        // Closing the window the sheet is on, rather than the sheet itself, is
        // the path that reaches nothing else. The microphone closes either way.
        .onDisappear { model.cancel() }
    }

    private var script: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(VoiceEnrollmentModel.script.enumerated()), id: \.offset) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(line.offset + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, alignment: .trailing)
                        Text(line.element)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
    }

    @ViewBuilder private var state: some View {
        switch model.phase {
        case .idle:
            Text("Nothing is recorded until you press Start.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .recording:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: model.progress)
                HStack(spacing: 8) {
                    LevelBar(level: model.level)
                    Text("\(Int(model.elapsed))s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("Read at your normal pace. Press Done when you reach the end.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the recording…").font(.callout).foregroundStyle(.secondary)
            }
        case .finished(let status):
            Label(
                "Your voice profile holds \(status.summary.lowercased()).",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Close") {
                model.cancel()
                onClose()
            }
            Spacer()
            switch model.phase {
            case .idle, .failed:
                Button("Start reading") { Task { await model.start() } }
                    .keyboardShortcut(.defaultAction)
            case .recording:
                Button("Done") { Task { await model.finish() } }
                    .keyboardShortcut(.defaultAction)
            case .working:
                Button("Done") {}.disabled(true)
            case .finished:
                Button("Read again") { Task { await model.start() } }
            }
        }
    }
}

/// A microphone level, drawn as a bar that moves.
private struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(2, geometry.size.width * min(1, level * 2.5)))
            }
        }
        .frame(height: 6)
    }
}
