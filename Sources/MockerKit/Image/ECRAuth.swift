import Foundation
import ContainerizationOCI

/// Amazon ECR credentials, fetched from the AWS CLI instead of the keychain.
///
/// An ECR password expires after 12 hours, so a stored one goes stale twice a day, and
/// reading a keychain item prompts again whenever the mocker binary is rebuilt. Asking
/// `aws ecr get-login-password` uses the AWS credentials the shell already has, the way
/// Docker's `ecr-login` credential helper does.
enum ECRAuth {
    struct CLIError: Error, CustomStringConvertible {
        let description: String
    }

    private static let cache = TokenCache()

    /// The AWS region of an ECR registry host, or nil when the host is not ECR.
    /// Covers the FIPS, China and dual-stack endpoint forms.
    static func region(for host: String) -> String? {
        let pattern = #/(\d{12})\.dkr[.-]ecr(?:-fips)?\.([a-z0-9-]+)\.(?:amazonaws\.com(?:\.cn)?|on\.aws)/#
        guard let match = host.wholeMatch(of: pattern) else { return nil }

        return String(match.2)
    }

    /// Credentials for an ECR registry host, or nil when the host is not ECR or the AWS CLI
    /// could not provide a token. A token is good for every registry in its region the AWS
    /// identity can reach, so it is fetched once per region per run.
    static func authentication(for host: String) async -> Authentication? {
        guard let region = region(for: host) else { return nil }

        return await cache.authentication(region: region) {
            do {
                return try await fetch(region: region, runner: RealProcessRunner())
            } catch {
                FileHandle.standardError.write(Data("warning: no ECR token for \(host): \(error)\n".utf8))
                return nil
            }
        }
    }

    /// Ask the AWS CLI for a registry password for `region`.
    static func fetch(region: String, runner: ProcessRunning) async throws -> Authentication {
        let (output, status) = try await runner.run(
            executable: "/usr/bin/env",
            arguments: ["aws", "ecr", "get-login-password", "--region", region]
        )
        let password = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard status == 0, !password.isEmpty else {
            throw CLIError(description: "aws ecr get-login-password failed: \(password)")
        }

        return BasicAuthentication(username: "AWS", password: password)
    }
}

/// One token request per region per run, shared by concurrent pulls.
private actor TokenCache {
    private var tasks: [String: Task<Authentication?, Never>] = [:]

    func authentication(
        region: String,
        fetch: @escaping @Sendable () async -> Authentication?
    ) async -> Authentication? {
        if let task = tasks[region] {
            return await task.value
        }

        let task = Task { await fetch() }
        tasks[region] = task

        return await task.value
    }
}
