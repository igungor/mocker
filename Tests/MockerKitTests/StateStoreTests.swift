import Foundation
import Testing
@testable import MockerKit

@Suite("State store Tests")
struct StateStoreTests {

    private func directory() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    }

    private func container(_ id: String) -> ContainerInfo {
        ContainerInfo(id: id, name: "app-\(id)-1", image: "alpine", state: .running, status: "", created: Date())
    }

    @Test("lists the containers it can read, skipping a half-written file")
    func containersSkipHalfWritten() async throws {
        let path = directory()
        let store = try ContainerStore(path: path)
        try await store.save(container("web"))
        try await store.save(container("db"))
        try Data("{\"id\":".utf8).write(to: URL(fileURLWithPath: "\(path)/half.json"))

        let ids = try await store.listAll().map(\.id).sorted()

        #expect(ids == ["db", "web"])
    }

    @Test("finds no container whose file is gone")
    func containerGone() async throws {
        let store = try ContainerStore(path: directory())

        #expect(try await store.load("gone") == nil)
    }

    @Test("lists the images it can read, skipping a half-written file")
    func imagesSkipHalfWritten() async throws {
        let path = directory()
        let store = try ImageStore(path: path)
        try await store.save(ImageInfo(id: "sha256:abc", repository: "alpine"))
        try Data("{".utf8).write(to: URL(fileURLWithPath: "\(path)/half.json"))

        let repositories = try await store.listAll().map(\.repository)

        #expect(repositories == ["alpine"])
    }

    @Test("a stored container without an exit code, as written before it was kept, still loads")
    func exitCodeOptional() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let info = ContainerInfo(id: "c", name: "c", image: "i", state: .exited, status: "", created: Date(timeIntervalSince1970: 0), exitCode: 3)

        var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(info)) as? [String: Any])
        #expect(try decoder.decode(ContainerInfo.self, from: encoder.encode(info)).exitCode == 3)

        object.removeValue(forKey: "exitCode")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try decoder.decode(ContainerInfo.self, from: old).exitCode == nil)
    }
}
