import PipitAudio
import PipitCore
import PipitServices
import Observation
import SwiftUI

/// Reading a script aloud, and what that leaves behind.
///
/// Optional, and offered rather than asked for: nothing about setup depends on
/// it. What it buys is recognition on the recordings that carry no microphone
/// track of their own, which is every in-person meeting and every import.
@MainActor
@Observable
public final class VoiceEnrollmentModel {
    public enum Phase: Equatable {
        case idle
        case reading
        case working
        /// Read, embedded, and still short. Carries how many more seconds of
        /// speech the profile wants.
        case short(remaining: Double)
        case finished(VoiceProfileStatus)
        case failed(String)
    }

    public private(set) var phase = Phase.idle
    /// Roughly how much speech is behind the reading so far, across every take.
    public private(set) var speechSeconds: Double = 0
    /// The loudest sample of the last buffer, so the meter shows a live
    /// microphone rather than a spinner that means nothing.
    public private(set) var level: Double = 0

    /// What the bar fills to.
    ///
    /// Above the 45 seconds a profile requires, because the number driving the
    /// bar is an energy gate and counts a quiet room as speech now and then.
    /// Overshooting costs a reader fifteen seconds; undershooting costs them
    /// the take.
    public static let targetSeconds: Double = 60

    @ObservationIgnored private let runtime: PipitRuntime
    @ObservationIgnored private let recorder = VoiceEnrollmentRecorder()
    @ObservationIgnored private var meter: Task<Void, Never>?
    /// Every take of this reading, oldest first. A reader told they are short
    /// carries on into a new one, and all of them are judged together.
    @ObservationIgnored private var takes: [URL] = []
    /// The gap between what the bar estimated and what the embedder actually
    /// measured, once it has measured anything. The bar is an energy gate and
    /// the embedder is the thing that decides, so after a short reading the bar
    /// is corrected to what the decision was made on rather than continuing to
    /// show the guess that overshot it.
    @ObservationIgnored private var estimateCorrection: Double = 0
    /// Called after a successful reading, so the page behind the sheet redraws
    /// the profile it has just changed.
    @ObservationIgnored public var onEnrolled: (() -> Void)?

    public init(runtime: PipitRuntime) {
        self.runtime = runtime
    }

    public var isReading: Bool { phase == .reading }

    public var progress: Double { min(1, speechSeconds / Self.targetSeconds) }

    /// What the bar shows: the running estimate, moved onto the embedder's
    /// number once there is one.
    private var measuredSpeechSeconds: Double {
        max(0, recorder.estimatedSpeechSeconds + estimateCorrection)
    }

    /// Whether enough has been read to be worth submitting. Advisory: Done
    /// stays available either way, and a short reading is continued rather than
    /// refused.
    public var hasEnough: Bool { speechSeconds >= Self.targetSeconds }

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
        // A reading that already finished or failed starts from zero. One that
        // was short does not: its takes are still here and still count.
        if takes.isEmpty {
            recorder.reset()
            speechSeconds = 0
            estimateCorrection = 0
        }
        do {
            try recorder.start(writingTo: url)
        } catch {
            phase = .failed("The microphone did not start: \(logSafeDescription(error))")
            return
        }
        takes.append(url)
        phase = .reading
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isReading else { return }
                self.speechSeconds = self.measuredSpeechSeconds
                self.level = Double(self.recorder.level)
            }
        }
    }

    /// Closes the current take and judges the reading so far.
    public func finish() async {
        meter?.cancel()
        meter = nil
        let seconds = recorder.stop()
        level = 0
        speechSeconds = measuredSpeechSeconds
        guard seconds > 0, !takes.isEmpty else {
            // An empty take is not a reading to carry on from, so it goes
            // rather than being joined onto whatever comes next.
            discardTakes(except: nil)
            takes = []
            phase = .failed("Nothing was recorded.")
            return
        }
        phase = .working
        guard let reading = await joinedReading() else {
            phase = .failed("The takes could not be put together.")
            return
        }
        do {
            let status = try await runtime.enrolSpokenSample(audio: reading)
            // The archive owns the audio from here, and the vector came from
            // the joined file rather than any one take.
            discardTakes(except: reading)
            takes = []
            phase = .finished(status)
            onEnrolled?()
        } catch let error as SpokenEnrollmentError {
            if case .rejected(.tooLittleSpeech(let heard, let required)) = error {
                // Kept, all of it. This is the failure a reader hits by talking
                // quickly, and throwing the audio away made them start the
                // script again to reach a bar they could not see.
                if reading != takes.last { try? FileManager.default.removeItem(at: reading) }
                estimateCorrection = heard - recorder.estimatedSpeechSeconds
                speechSeconds = heard
                phase = .short(remaining: max(1, required - heard))
                return
            }
            discardTakes(except: nil)
            takes = []
            phase = .failed(Self.message(for: error))
        } catch {
            phase = .failed("The recording could not be used.")
        }
    }

    /// One file holding every take, or the only take when there is one.
    private func joinedReading() async -> URL? {
        guard takes.count > 1 else { return takes.first }
        guard let destination = await runtime.newEnrollmentRecording() else { return takes.last }
        do {
            try AudioConcatenation.join(takes, into: destination)
            return destination
        } catch {
            // A device changed between takes. The last one still stands on its
            // own, and the reader is told what it was worth.
            Log.ui.notice("takes not joined: \(logSafeDescription(error), privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            return takes.last
        }
    }

    private func discardTakes(except keep: URL?) {
        for take in takes where take != keep {
            try? FileManager.default.removeItem(at: take)
        }
    }

    /// Stops without keeping the reading, for a closed sheet or a changed mind.
    /// A reading that reached a profile has already been handed to the archive.
    public func cancel() {
        meter?.cancel()
        meter = nil
        recorder.reset()
        discardTakes(except: nil)
        takes = []
        level = 0
        speechSeconds = 0
        estimateCorrection = 0
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
            "That was \(Int(seconds)) seconds of speech. A profile needs \(Int(required))."
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
            header
            script
            state
            buttons
        }
        .padding(20)
        .frame(width: 540, height: 580)
        // Closing the window the sheet is on, rather than the sheet itself, is
        // the path that reaches nothing else. The microphone closes either way.
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Learn my voice").font(.title3)
            Text(
                "Read these out loud at your normal pace. The recording becomes a voice "
                    + "profile, which is how Pipit recognises you on a recording with no "
                    + "microphone track of its own: an in-person meeting, or an imported file."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var script: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(VoiceEnrollmentScript.lists) { list in
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(list.sentences.enumerated()), id: \.offset) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\((list.number - 1) * 10 + line.offset + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 18, alignment: .trailing)
                                Text(line.element)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Then, in your own words:")
                        .font(.callout.weight(.medium))
                        .padding(.top, 4)
                    ForEach(VoiceEnrollmentScript.prompts, id: \.self) { prompt in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .trailing)
                            Text(prompt)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(
                        "Talking is not reading, and the profile is matched against meetings, "
                            + "where you talk."
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 26)
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
                .frame(height: 44, alignment: .topLeading)
        case .reading:
            meter(
                caption: model.hasEnough
                    ? "That is enough. Press Done, or keep going to make it stronger."
                    : "Keep reading. Pauses do not count towards the bar."
            )
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the recording…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(height: 44, alignment: .topLeading)
        case .short(let remaining):
            meter(
                caption: "About \(Int(remaining)) more seconds of speech. "
                    + "Press Keep reading and carry on where you left off."
            )
        case .finished(let status):
            Label(
                "Your voice profile holds \(status.summary.lowercased()).",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.callout)
            .frame(height: 44, alignment: .topLeading)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 44, alignment: .topLeading)
        }
    }

    private func meter(caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: model.progress)
            HStack(spacing: 8) {
                if model.isReading { LevelBar(level: model.level) }
                Text(
                    "\(Int(model.speechSeconds))s of "
                        + "\(Int(VoiceEnrollmentModel.targetSeconds))s of speech"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(height: 44, alignment: .topLeading)
    }

    private var buttons: some View {
        HStack {
            Button("Close") {
                model.cancel()
                onClose()
            }
            // Not while the embedder is reading the file this would delete.
            .disabled(model.phase == .working)
            Spacer()
            switch model.phase {
            case .idle, .failed:
                Button("Start reading") { Task { await model.start() } }
                    .keyboardShortcut(.defaultAction)
            case .reading:
                Button("Done") { Task { await model.finish() } }
                    .keyboardShortcut(.defaultAction)
            case .working:
                Button("Done") {}.disabled(true)
            case .short:
                Button("Keep reading") { Task { await model.start() } }
                    .keyboardShortcut(.defaultAction)
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
        .frame(width: 60, height: 6)
    }
}
