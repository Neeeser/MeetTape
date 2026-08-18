import Foundation
import TestKit

let suites: [Suite] = CaptureRecoveryTests.all + [
    ManifestTests.suite,
    StorageTests.suite,
    AudioTests.suite,
]

let code = await TestRunner.run(suites, arguments: Array(CommandLine.arguments.dropFirst()))
exit(code)
