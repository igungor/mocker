import Testing
import Foundation
import Containerization
import ContainerizationOCI
@testable import MockerKit

/// An untagged `mocker build` is stored under a digest-named placeholder, since Apple's
/// store keeps every image under a name, and shown as `<none>:<none>` like Docker does.
@Suite("Dangling images")
struct DanglingImageTests {

    private let digest = "sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0"

    @Test("the placeholder and a leftover build name are dangling, real names are not")
    func recognizesDanglingReferences() {
        #expect(ImageManager.isDanglingReference(ImageManager.danglingReference(digest: digest)))
        #expect(ImageManager.isDanglingReference("mocker-dangling@\(digest)"))
        #expect(ImageManager.isDanglingReference(ImageManager.temporaryBuildReference()))

        #expect(!ImageManager.isDanglingReference("docker.io/library/nginx:latest"))
        #expect(!ImageManager.isDanglingReference("mocker-dangling-app:1"))
        #expect(!ImageManager.isDanglingReference("registry.example.com/mocker-dangling:1"))
    }

    @Test("the placeholder is a valid digest reference")
    func placeholderParses() throws {
        let ref = try ContainerizationOCI.Reference.parse(ImageManager.danglingReference(digest: digest))
        #expect(ref.digest == digest)
        #expect(ref.tag == nil)
    }

    @Test("a dangling image is shown as <none>:<none>")
    func displaysNone() {
        let name = ImageManager.displayName(of: ImageManager.danglingReference(digest: digest))
        #expect(name.repository == "<none>")
        #expect(name.tag == "<none>")

        let named = ImageManager.displayName(of: "docker.io/library/nginx:1.25")
        #expect(named.repository == "docker.io/library/nginx")
        #expect(named.tag == "1.25")
    }

    @Test("listing hides dangling entries of named images and repeats of one image")
    func hidesNamedDangling() {
        let images = [
            ImageInfo(id: "sha256:a", repository: "app", tag: "1"),
            ImageInfo(id: "sha256:a", repository: "<none>", tag: "<none>"),
            ImageInfo(id: "sha256:b", repository: "<none>", tag: "<none>"),
            ImageInfo(id: "sha256:b", repository: "<none>", tag: "<none>"),
        ]

        let listed = ImageManager.hidingNamedDangling(images)

        #expect(listed.map(\.reference) == ["app:1", "<none>:<none>"])
        #expect(listed.map(\.id) == ["sha256:a", "sha256:b"])
    }

    @Test("a container uses a dangling image it was started from by ID or by name")
    func detectsUse() {
        let reference = ImageManager.danglingReference(digest: digest)

        #expect(ImageManager.isUsed(reference: reference, digest: digest, byContainerImages: ["85fe1e81d675"]))
        #expect(ImageManager.isUsed(reference: reference, digest: digest, byContainerImages: ["sha256:85FE1E81"]))
        #expect(ImageManager.isUsed(reference: reference, digest: digest, byContainerImages: [digest]))
        #expect(ImageManager.isUsed(reference: reference, digest: digest, byContainerImages: [reference]))

        #expect(!ImageManager.isUsed(reference: reference, digest: digest, byContainerImages: []))
        #expect(!ImageManager.isUsed(reference: reference, digest: digest, byContainerImages: ["nginx", "beef1234"]))
    }

    @Test("inspect reports no RepoTags or RepoDigests from the placeholder")
    func repoMetadataSkipsPlaceholder() throws {
        let store = try ContainerizationOCI.LocalContentStore(
            path: FileManager.default.temporaryDirectory.appendingPathComponent("mocker-dangling-\(UUID().uuidString)"))
        let placeholder = image(reference: ImageManager.danglingReference(digest: digest), contentStore: store)

        let dangling = ImageManager.repoMetadata(
            for: placeholder, localImages: [placeholder], fallbackReference: placeholder.reference)
        #expect(dangling.tags == [])
        #expect(dangling.digests == [])

        let named = image(reference: "docker.io/library/app:1", contentStore: store)
        let both = ImageManager.repoMetadata(
            for: placeholder, localImages: [placeholder, named], fallbackReference: placeholder.reference)
        #expect(both.tags == ["docker.io/library/app:1"])
        #expect(both.digests == ["docker.io/library/app@\(digest)"])
    }

    @Test("build passes every tag, and none when untagged")
    func buildArgumentsTags() {
        let tagged = ImageManager.makeBuildArguments(
            tags: ["app:1", "app:latest"], dockerfilePath: "/ctx/Dockerfile", context: ".")
        #expect(Array(tagged.prefix(5)) == ["build", "-t", "app:1", "-t", "app:latest"])

        let untagged = ImageManager.makeBuildArguments(tags: [], dockerfilePath: "/ctx/Dockerfile", context: ".")
        #expect(!untagged.contains("-t"))
    }

    private func image(reference: String, contentStore: ContainerizationOCI.ContentStore) -> Containerization.Image {
        let descriptor = ContainerizationOCI.Descriptor(
            mediaType: "application/vnd.oci.image.index.v1+json", digest: digest, size: 100)
        let description = Containerization.Image.Description(reference: reference, descriptor: descriptor)
        return Containerization.Image(description: description, contentStore: contentStore)
    }
}
