import ArgumentParser
import Foundation

public struct InitCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Guided first-run setup for permissions and dependencies."
    )

    public init() {}

    public mutating func run() async throws {
        print("pippin init — First-run setup guide")
        print("=".padding(toLength: 40, withPad: "=", startingAt: 0))
        print()

        let checks = runAllChecks()
        var hasFailure = false

        for (index, check) in checks.enumerated() {
            let step = index + 1

            switch check.status {
            case .ok:
                print("Step \(step): \(check.name)")
                print("  ✓ \(check.detail)")
                print()

            case .fail:
                hasFailure = true
                print("Step \(step): \(check.name)")
                print("  ✗ \(check.detail)")
                if let remediation = check.remediation {
                    print()
                    for line in remediation.components(separatedBy: .newlines) {
                        print("  \(line)")
                    }
                }
                print()

            case .skip:
                print("Step \(step): \(check.name)")
                print("  - \(check.detail)")
                if let remediation = check.remediation {
                    print("  \(remediation)")
                }
                print()
            }
        }

        print(String(repeating: "=", count: 40))
        if hasFailure {
            print()
            print("Some checks failed. Fix the issues above, then re-run:")
            print("  pippin doctor")
            throw ExitCode(1)
        } else {
            print()
            print("All checks passed! pippin is ready to use.")
            print()
            print("Try these commands:")
            print("  pippin mail list              # List recent emails")
            print("  pippin memos list             # List voice memos")
            print("  pippin mail show --subject \"test\"  # Find and show an email")
        }
    }
}
