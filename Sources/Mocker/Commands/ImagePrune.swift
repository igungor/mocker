import ArgumentParser
import Foundation
import MockerKit

struct ImagePrune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Remove unused images"
    )

    @Flag(name: .shortAndLong, help: "Remove all unused images, not just dangling ones")
    var all = false

    @Option(name: .long, parsing: .singleValue, help: "Provide filter values (e.g. \"until=<timestamp>\")")
    var filter: [String] = []

    @Flag(name: .shortAndLong, help: "Do not prompt for confirmation")
    var force = false

    func run() async throws {
        guard !all, filter.isEmpty else {
            throw MockerError.operationFailed(
                "image prune --all and --filter are not yet supported with Apple Containerization")
        }

        if !force {
            print("WARNING! This will remove all dangling images.")
            print("Are you sure you want to continue? [y/N] ", terminator: "")
            guard let answer = readLine(), answer.lowercased() == "y" else {
                return
            }
        }

        let config = MockerConfig()
        let containers = try await ContainerEngine(config: config).list(all: true)
        let result = try await ImageManager(config: config).pruneDangling(containerImages: containers.map(\.image))

        Self.printDeleted(result.deleted)
        print("Total reclaimed space: \(Self.humanSize(result.reclaimed))")
    }

    /// The `Deleted Images:` block Docker prints, nothing when no image went.
    static func printDeleted(_ ids: [String]) {
        guard !ids.isEmpty else { return }

        print("Deleted Images:")
        for id in ids {
            print("deleted: \(id)")
        }
        print("")
    }

    /// A byte count the way Docker prints reclaimed space: decimal units, four
    /// significant digits, no space (`0B`, `12.35MB`).
    static func humanSize(_ bytes: UInt64) -> String {
        let units = ["B", "kB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return String(format: "%.4g%@", value, units[unit])
    }
}
