import Foundation
import TestKit

// Built by appending rather than by chaining `+`: a single chained expression of
// this length exceeds the type checker's budget on the toolchain CI runs.
var suites: [Suite] = []
suites += CaptureRecoveryTests.all
suites.append(CalendarMatchTests.suite)
suites.append(ManifestTests.suite)
suites.append(StorageTests.suite)
suites.append(MeetingFolderNameTests.suite)
suites.append(MeetingFolderRenameTests.suite)
suites.append(AudioTests.suite)
suites += DetectionTests.all
suites += SessionTests.all
suites += HardeningTests.all
suites.append(UITests.suite)
suites.append(SetupFlowTests.suite)
suites += LocalConfigurationTests.all
suites += SpeakerIdentityTests.all
suites.append(VoiceEvidenceTests.suite)
suites.append(TranscriptGroupingTests.suite)
suites += TranscriptDivisionTests.all
suites += SpeechGateTests.all
suites.append(EchoTests.suite)
suites.append(TranscriptPanelTests.suite)
suites.append(ReconnectTests.suite)
suites += SensorAttributionTests.all
suites += SpeakerCorrectionTests.all
suites.append(SpeakerSuggestionTests.suite)
suites.append(SpeakerRematchTests.suite)
suites += PeopleDirectoryTests.all
suites += MeetingsWindowTests.all
suites += BackendSelectionTests.all
suites.append(CloudModelTests.suite)
suites += AlignmentTests.all
suites += ProcessingTests.all
suites.append(PipelineTests.suite)
suites.append(CompactionTests.suite)
suites.append(LocalPipelineTests.suite)
suites.append(LocalModelTests.suite)
suites.append(BenchScorerTests.suite)
suites.append(LiveSlackHuddleTests.suite)
suites.append(LiveOpenAITests.suite)
suites.append(LiveEndToEndTests.suite)

let code = await TestRunner.run(suites, arguments: Array(CommandLine.arguments.dropFirst()))
exit(code)
