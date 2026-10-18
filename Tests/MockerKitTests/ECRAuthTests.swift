import Foundation
import Testing
@testable import MockerKit

@Suite("ECRAuth")
struct ECRAuthTests {

    @Test("ECR hosts resolve to their region", arguments: [
        ("655922159383.dkr.ecr.us-east-1.amazonaws.com", "us-east-1"),
        ("123456789012.dkr.ecr-fips.us-gov-west-1.amazonaws.com", "us-gov-west-1"),
        ("123456789012.dkr.ecr.cn-north-1.amazonaws.com.cn", "cn-north-1"),
        ("123456789012.dkr-ecr.eu-west-1.on.aws", "eu-west-1"),
    ])
    func ecrHostRegion(host: String, region: String) {
        #expect(ECRAuth.region(for: host) == region)
    }

    @Test("other hosts are not ECR", arguments: [
        "registry-1.docker.io",
        "ghcr.io",
        "public.ecr.aws",
        "12345.dkr.ecr.us-east-1.amazonaws.com",
        "655922159383.dkr.ecr.us-east-1.amazonaws.com.example.com",
    ])
    func otherHostsAreNotECR(host: String) {
        #expect(ECRAuth.region(for: host) == nil)
    }

    @Test("fetch asks the AWS CLI for the region's password and logs in as AWS")
    func fetchUsesAWSCLI() async throws {
        let runner = MockProcessRunner(responses: [("secret-token\n", 0)])

        let auth = try await ECRAuth.fetch(region: "us-east-1", runner: runner)

        let calls = await runner.calls
        #expect(calls.map(\.executable) == ["/usr/bin/env"])
        #expect(calls.map(\.arguments) == [["aws", "ecr", "get-login-password", "--region", "us-east-1"]])

        let expected = "Basic " + Data("AWS:secret-token".utf8).base64EncodedString()
        #expect(try await auth.token() == expected)
    }

    @Test("fetch fails when the AWS CLI fails")
    func fetchFailsOnCLIError() async {
        let runner = MockProcessRunner(responses: [("Unable to locate credentials", 255)])

        await #expect(throws: ECRAuth.CLIError.self) {
            try await ECRAuth.fetch(region: "us-east-1", runner: runner)
        }
    }

    @Test("fetch fails when the AWS CLI prints no password")
    func fetchFailsOnEmptyOutput() async {
        let runner = MockProcessRunner(responses: [("\n", 0)])

        await #expect(throws: ECRAuth.CLIError.self) {
            try await ECRAuth.fetch(region: "us-east-1", runner: runner)
        }
    }
}
