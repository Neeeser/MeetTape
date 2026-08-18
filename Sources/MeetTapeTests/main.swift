import Foundation
import TestKit

let suites: [Suite] = CaptureRecoveryTests.all

let code = await TestRunner.run(suites, arguments: Array(CommandLine.arguments.dropFirst()))
exit(code)
