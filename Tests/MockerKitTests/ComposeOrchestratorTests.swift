import Foundation
import Testing
@testable import MockerKit

@Suite("ComposeOrchestrator Tests")
struct ComposeOrchestratorTests {
    /// Default project directory used by tests that don't care where sources anchor.
    private static let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    @Test("Service order respects depends_on chain")
    func testServiceOrderChain() throws {
        let yaml = """
        version: "3.8"
        services:
          web:
            image: nginx
            depends_on:
              - api
          api:
            image: node
            depends_on:
              - db
          db:
            image: postgres
        """
        let compose = try ComposeFile.parse(yaml)
        let order = compose.serviceOrder()

        // db must come before api, api before web
        let dbIdx = order.firstIndex(of: "db")!
        let apiIdx = order.firstIndex(of: "api")!
        let webIdx = order.firstIndex(of: "web")!

        #expect(dbIdx < apiIdx)
        #expect(apiIdx < webIdx)
    }

    @Test("Service order handles independent services")
    func testServiceOrderIndependent() throws {
        let yaml = """
        version: "3.8"
        services:
          redis:
            image: redis
          postgres:
            image: postgres
          nginx:
            image: nginx
        """
        let compose = try ComposeFile.parse(yaml)
        let order = compose.serviceOrder()
        #expect(order.count == 3)
        #expect(Set(order) == Set(["redis", "postgres", "nginx"]))
    }

    @Test("Compose file filtering preserves requested services")
    func testFilteringServices() throws {
        let yaml = """
        version: "3.8"
        services:
          web:
            image: nginx
          api:
            image: node
          db:
            image: postgres
        """
        let compose = try ComposeFile.parse(yaml)
        let filtered = compose.filtering(services: ["web", "db"])
        #expect(filtered.services.count == 2)
        #expect(filtered.services["web"] != nil)
        #expect(filtered.services["db"] != nil)
        #expect(filtered.services["api"] == nil)
    }

    @Test("--no-deps keeps only the requested services and drops their depends_on")
    func filteringWithoutDependencies() throws {
        let compose = try ComposeFile.parse("""
        services:
          db:
            image: postgres
            healthcheck:
              test: ["CMD", "true"]
          cache:
            image: redis
          app:
            image: node
            depends_on:
              db:
                condition: service_healthy
              cache:
                condition: service_started
        """)

        let withDeps = compose.filtering(services: ["app"])
        #expect(withDeps.services.keys.sorted() == ["app", "cache", "db"])
        #expect(withDeps.services["app"]?.dependsOn.sorted() == ["cache", "db"])

        let noDeps = compose.filtering(services: ["app"], includeDependencies: false)
        #expect(noDeps.services.keys.sorted() == ["app"])
        #expect(noDeps.services["app"]?.dependsOn == [])
        #expect(noDeps.services["app"]?.dependsOnConditions == [:])

        let both = compose.filtering(services: ["app", "db"], includeDependencies: false)
        #expect(both.services["app"]?.dependsOn == ["db"])
    }

    // MARK: - Image source resolution (issue #14)

    @Test("image only resolves to pull")
    func resolveImageOnly() throws {
        let svc = try ComposeFile.parse("""
        services:
          app:
            image: nginx:latest
        """).services["app"]!
        #expect(svc.resolveImageSource(projectName: "proj") == .pull(image: "nginx:latest"))
    }

    @Test("build only resolves to build with synthesized tag")
    func resolveBuildOnly() throws {
        let svc = try ComposeFile.parse("""
        services:
          app:
            build:
              context: .
              target: base
        """).services["app"]!
        let source = svc.resolveImageSource(projectName: "proj")
        guard case .build(let tag, let build) = source else {
            Issue.record("expected .build, got \(source)")
            return
        }
        #expect(tag == "proj-app:latest")
        #expect(build.target == "base")
    }

    @Test("image + build resolves to build, tagged with image name (issue #14)")
    func resolveImageAndBuild() throws {
        let svc = try ComposeFile.parse("""
        services:
          app:
            image: repro-app
            build:
              context: .
              target: base
        """).services["app"]!
        let source = svc.resolveImageSource(projectName: "proj")
        guard case .build(let tag, _) = source else {
            Issue.record("expected .build (not pull) when image + build are both set; got \(source)")
            return
        }
        // image: is used as the tag, NOT pulled from a registry.
        #expect(tag == "repro-app")
    }

    @Test("image + build with --no-build falls back to pull")
    func resolveImageAndBuildNoBuild() throws {
        let svc = try ComposeFile.parse("""
        services:
          app:
            image: repro-app
            build:
              context: .
        """).services["app"]!
        #expect(svc.resolveImageSource(projectName: "proj", noBuild: true) == .pull(image: "repro-app"))
    }

    @Test("empty service resolves to none")
    func resolveNone() throws {
        let svc = ComposeService(
            name: "app", image: nil, build: nil, command: [], environment: [:],
            ports: [], volumes: [], networks: [], dependsOn: [], restart: nil,
            labels: [:], hostname: nil, workingDir: nil,
            memLimit: nil, cpus: nil, memReservation: nil, cpusReservation: nil,
            memSwapLimit: nil,
            shmSize: nil, pidsLimit: nil,
            restartPolicyDelay: nil, restartPolicyMaxAttempts: nil, restartPolicyWindow: nil
        )
        #expect(svc.resolveImageSource(projectName: "proj") == .none)
    }

    @Test("imageMatches compares repository suffix and tag")
    func imageMatching() {
        let img = ImageInfo(id: "abc", repository: "proj-app", tag: "latest")
        #expect(ComposeService.imageMatches(img, tag: "proj-app:latest"))
        #expect(ComposeService.imageMatches(img, tag: "proj-app"))  // implicit :latest
        #expect(!ComposeService.imageMatches(img, tag: "proj-app:v2"))
        #expect(!ComposeService.imageMatches(img, tag: "other-app:latest"))
    }

    // MARK: - depends_on: service_completed_successfully

    @Test("Only services another one waits on to complete are awaited")
    func servicesAwaitedForCompletion() throws {
        let compose = try ComposeFile.parse("""
        services:
          db:
            image: mysql:8.4
          migrate:
            image: alpine
            depends_on: [db]
          app:
            image: alpine
            depends_on:
              db:
                condition: service_started
              migrate:
                condition: service_completed_successfully
        """)

        #expect(ComposeOrchestrator.servicesAwaitedForCompletion(compose) == ["migrate"])
    }

    // MARK: - Service hostnames

    @Test("A container finds itself by its service name too, as Docker's DNS answers both")
    func hostsListOwnServiceName() {
        let entries = ComposeOrchestrator.hostsEntries(
            service: "kafka", hostname: "proj-kafka-1", address: "10.0.0.5", others: [("web", "10.0.0.4"), ("db", "10.0.0.2")]
        )
        let hosts = ComposeOrchestrator.updatedHosts(nil, entries: entries, managed: ["kafka", "web", "db", "proj-kafka-1"])

        #expect(hosts == "127.0.0.1 localhost\n10.0.0.5 proj-kafka-1\n10.0.0.5 kafka\n10.0.0.2 db\n10.0.0.4 web\n")
    }

    @Test("A hostname that is the service name is listed once")
    func hostsListOwnNameOnce() {
        let entries = ComposeOrchestrator.hostsEntries(service: "db", hostname: "db", address: "10.0.0.2", others: [])

        #expect(entries.map(\.name) == ["db"])
    }

    @Test("Network aliases resolve, for the others and for the service itself")
    func hostsListNetworkAliases() throws {
        let compose = try ComposeFile.parse("""
        services:
          miniflake:
            image: miniflake
            networks:
              default:
                aliases: [peakgames.miniflake.local, miniflake]
          app:
            image: app
        networks:
          default:
        """)
        let miniflake = ContainerInfo(
            id: "p-miniflake-1", name: "p-miniflake-1", image: "miniflake", state: .running, status: "Up",
            created: Date(), networkAddress: "10.0.0.7")

        let others = ComposeOrchestrator.namedAddresses(of: [("miniflake", miniflake)], composeFile: compose)
        #expect(others.map(\.name) == ["miniflake", "peakgames.miniflake.local"])
        let appHosts = ComposeOrchestrator.updatedHosts(
            nil, entries: others, managed: ComposeOrchestrator.managedHostNames(compose))
        #expect(appHosts == "127.0.0.1 localhost\n10.0.0.7 miniflake\n10.0.0.7 peakgames.miniflake.local\n")

        let own = ComposeOrchestrator.hostsEntries(
            service: "miniflake", hostname: "p-miniflake-1", address: "10.0.0.7",
            aliases: ComposeOrchestrator.aliases(of: "miniflake", composeFile: compose), others: [])
        #expect(own.map(\.name) == ["p-miniflake-1", "miniflake", "peakgames.miniflake.local"])
    }

    @Test("Only the aliases of the network the service joins apply")
    func aliasesOfJoinedNetworkOnly() throws {
        let compose = try ComposeFile.parse("""
        services:
          db:
            image: mysql
            networks:
              backend:
                aliases: [mysql.local]
              frontend:
                aliases: [db.public]
          web:
            image: nginx
            networks: [frontend]
        networks:
          backend:
          frontend:
        """)

        #expect(ComposeOrchestrator.aliases(of: "db", composeFile: compose) == ["mysql.local"])
        #expect(ComposeOrchestrator.aliases(of: "web", composeFile: compose) == [])
        #expect(ComposeOrchestrator.managedHostNames(compose) == ["db", "web", "mysql.local"])
    }

    @Test("A new hosts file has localhost and the given services")
    func newHostsFile() {
        let hosts = ComposeOrchestrator.updatedHosts(nil, entries: [("db", "10.0.0.2"), ("web", "10.0.0.4")], managed: ["db", "web"])

        #expect(hosts == "127.0.0.1 localhost\n10.0.0.2 db\n10.0.0.4 web\n")
    }

    @Test("New names go at the end, so the lines a container already has don't move")
    func hostsOnlyGrowAtTheEnd() {
        let current = "127.0.0.1 localhost\n10.0.0.2 db\n"

        let hosts = ComposeOrchestrator.updatedHosts(
            current, entries: [("p-cache-1", "10.0.0.3"), ("db", "10.0.0.2"), ("web", "10.0.0.4")], managed: ["db", "web", "cache", "p-cache-1"])

        #expect(hosts == current + "10.0.0.3 p-cache-1\n10.0.0.4 web\n")
    }

    @Test("A service's changed address replaces its line; unrelated lines stay")
    func hostsChangedAddress() {
        let current = "127.0.0.1 localhost\n10.0.0.2 db\n10.0.0.4 web\n10.9.9.9 added-by-entrypoint\n"

        let hosts = ComposeOrchestrator.updatedHosts(current, entries: [("db", "10.0.0.2"), ("web", "10.0.0.5")], managed: ["db", "web"])

        #expect(hosts == "127.0.0.1 localhost\n10.0.0.2 db\n10.9.9.9 added-by-entrypoint\n10.0.0.5 web\n")
    }

    // MARK: - Entrypoint resolution (compose `entrypoint:` support)

    @Test("Empty entrypoint leaves command untouched")
    func resolveExecNoEntrypoint() {
        let exec = ComposeOrchestrator.resolveExec(entrypoint: [], command: ["echo", "hi"])
        #expect(exec.entrypoint == nil)
        #expect(exec.command == ["echo", "hi"])
    }

    @Test("Entrypoint with args: first element is the executable, rest lead the argv")
    func resolveExecSplicesEntrypointArgs() {
        let exec = ComposeOrchestrator.resolveExec(
            entrypoint: ["/bin/sh", "-c"],
            command: ["echo", "hello"]
        )
        #expect(exec.entrypoint == "/bin/sh")
        #expect(exec.command == ["-c", "echo", "hello"])
    }

    @Test("Single-element entrypoint overrides executable, keeps command argv")
    func resolveExecSingleElement() {
        let exec = ComposeOrchestrator.resolveExec(
            entrypoint: ["/bin/echo"],
            command: ["hello"]
        )
        #expect(exec.entrypoint == "/bin/echo")
        #expect(exec.command == ["hello"])
    }

    @Test("Entrypoint with empty first element is treated as absent")
    func resolveExecEmptyFirstElement() {
        let exec = ComposeOrchestrator.resolveExec(
            entrypoint: [""],
            command: ["echo", "hi"]
        )
        #expect(exec.entrypoint == nil)
        #expect(exec.command == ["echo", "hi"])
    }

    // MARK: - Volume mount resolution (issue #49)

    @Test("Absolute bind mount included as-is")
    func resolveAbsoluteBindMount() throws {
        let mounts = try Self.resolve(["/host/data:/container/data"])
        #expect(mounts.count == 1)
        #expect(mounts[0].source == "/host/data")
        #expect(mounts[0].destination == "/container/data")
    }

    @Test(
        "Relative-style sources resolved to absolute path",
        arguments: [
            ("./foo:/bar", "/foo", "/bar"),
            ("../data:/container/data", "/data", "/container/data"),
            ("mydir/data:/container/data", "mydir/data", "/container/data"),
        ]
    )
    func resolveRelativeStyleMounts(spec: String, suffix: String, destination: String) throws {
        let mounts = try Self.resolve([spec])
        #expect(mounts.count == 1)
        #expect(mounts[0].source.hasPrefix("/"))
        #expect(mounts[0].source.hasSuffix(suffix))
        #expect(mounts[0].destination == destination)
    }

    @Test("Declared named volume resolved to its backing directory")
    func resolveDeclaredNamedVolume() throws {
        let mounts = try Self.resolve(["mydata:/container/data"], named: ["mydata": "/volumes/proj-mydata/_data"])
        #expect(mounts.count == 1)
        #expect(mounts[0].source == "/volumes/proj-mydata/_data")
        #expect(mounts[0].destination == "/container/data")
    }

    @Test("Undeclared bare name is dropped")
    func dropUndeclaredName() throws {
        let mounts = try Self.resolve(["mydata:/container/data"])
        #expect(mounts.isEmpty)
    }

    @Test("Anonymous volume included")
    func includeAnonymousVolume() throws {
        let mounts = try Self.resolve(["/container/data"])
        #expect(mounts.count == 1)
        #expect(mounts[0].source == "")
        #expect(mounts[0].destination == "/container/data")
    }

    @Test("Mix of bind mounts, named volumes, and anonymous volumes")
    func resolveMixedVolumes() throws {
        let mounts = try Self.resolve([
            "/abs/path:/app/data",
            "./relative:/app/rel",
            "namedvol:/app/named",
            "/app/anon",
            "sub/dir:/app/sub",
        ], named: ["namedvol": "/volumes/proj-namedvol/_data"])
        #expect(mounts.count == 5)
        let sources = mounts.map(\.source)
        #expect(sources.contains("/abs/path"))
        #expect(sources.contains("/volumes/proj-namedvol/_data"))
        #expect(sources.contains(""))  // anonymous
        #expect(sources.contains(where: { $0.hasSuffix("/relative") }))
        #expect(sources.contains(where: { $0.hasSuffix("sub/dir") }))
    }

    @Test("Read-only relative bind mount preserves ro flag")
    func resolveRelativeReadOnly() throws {
        let mounts = try Self.resolve(["./data:/container/data:ro"])
        #expect(mounts.count == 1)
        #expect(mounts[0].readOnly == true)
        #expect(mounts[0].destination == "/container/data")
        #expect(mounts[0].source.hasSuffix("/data"))
    }

    @Test("Home-relative path resolved")
    func resolveHomeRelativePath() throws {
        let mounts = try Self.resolve(["~/data:/container/data"])
        #expect(mounts.count == 1)
        #expect(mounts[0].source.hasPrefix("/"))
        #expect(mounts[0].source.contains("data"))
        #expect(mounts[0].destination == "/container/data")
    }

    /// Resolve specs against the test project directory, with named volumes already
    /// mapped to their backing directories.
    private static func resolve(
        _ specs: [String],
        named: [String: String] = [:]
    ) throws -> [VolumeMount] {
        try ComposeOrchestrator.resolveVolumeMounts(
            specs,
            projectDir: Self.cwd,
            namedVolumeSources: named
        )
    }

    // MARK: - reconcileDecision (issue #59)

    private func singleServiceFile() throws -> ComposeFile {
        try ComposeFile.parse("""
        services:
          app:
            image: nginx:alpine
        """)
    }

    /// Defaults to the project's implicit network, which is where a container created by
    /// the current code actually lands — pass an explicit value to model an upgrade from a
    /// version that recorded no network at all.
    private func observed(
        name: String,
        serviceName: String,
        configHash: String?,
        network: String? = "proj-default",
        state: ContainerState = .running
    ) -> ObservedContainer {
        ObservedContainer(
            name: name, serviceName: serviceName, configHash: configHash,
            network: network, state: state
        )
    }

    @Test("A container with no recorded network is recreated onto the project's network")
    func reconcileRecreatesUnnetworkedContainer() throws {
        let file = try singleServiceFile()
        let svc = file.services["app"]!

        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-app-1", serviceName: "app",
                         configHash: ComposeService.hash(of: svc), network: nil)
            ],
            composeFile: file,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: false
        )

        // Containers from a version that never passed --network sit on the runtime's
        // global network; leaving them there would silently skip the isolation fix.
        #expect(actions == [ReconcileAction(serviceName: "app", kind: .removeAndRecreate)])
    }

    @Test("reconcileDecision: observed container matches hash + defaults → .keep")
    func reconcileObservedMatchesDefaults() throws {
        let file = try singleServiceFile()
        let svc = file.services["app"]!
        let hash = ComposeService.hash(of: svc)
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-app-1", serviceName: "app", configHash: hash)
            ],
            composeFile: file,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: false
        )
        #expect(actions == [ReconcileAction(serviceName: "app", kind: .keep)])
    }

    @Test("A one-shot service others wait to complete runs again, exited or still running", arguments: [ContainerState.exited, .running])
    func reconcileRerunsAwaitedOneShot(state: ContainerState) throws {
        let file = try ComposeFile.parse("""
        services:
          builder:
            image: golang:alpine
          app:
            image: alpine
            depends_on:
              builder:
                condition: service_completed_successfully
        """)
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: ["builder", "app"].map { name in
                observed(name: "proj-\(name)-1", serviceName: name,
                         configHash: ComposeService.hash(of: file.services[name]!), state: state)
            },
            composeFile: file,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: false
        )

        // Kept or started in place, it leaves app nothing to wait for, so app starts on
        // whatever the last run built, even when that run failed.
        #expect(actions.first { $0.serviceName == "builder" }?.kind == .removeAndRecreate)
        #expect(actions.first { $0.serviceName == "app" }?.kind == (state == .running ? .keep : .start))
    }

    @Test("reconcileDecision: observed container matches hash + --force-recreate → .removeAndRecreate")
    func reconcileForceRecreateOverridesKeep() throws {
        let file = try singleServiceFile()
        let svc = file.services["app"]!
        let hash = ComposeService.hash(of: svc)
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-app-1", serviceName: "app", configHash: hash)
            ],
            composeFile: file,
            projectName: "proj",
            forceRecreate: true,
            noRecreate: false
        )
        #expect(actions == [ReconcileAction(serviceName: "app", kind: .removeAndRecreate)])
    }

    @Test("reconcileDecision: observed container matches hash + --no-recreate → .keep")
    func reconcileNoRecreateEvenWithDrift() throws {
        let file = try singleServiceFile()
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-app-1", serviceName: "app", configHash: "stale-different-value")
            ],
            composeFile: file,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: true
        )
        #expect(actions == [ReconcileAction(serviceName: "app", kind: .keep)])
    }

    @Test("reconcileDecision: observed container has diverged hash + defaults → .removeAndRecreate")
    func reconcileHashDriftDefaults() throws {
        let file = try singleServiceFile()
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-app-1", serviceName: "app", configHash: "sha256:different")
            ],
            composeFile: file,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: false
        )
        #expect(actions == [ReconcileAction(serviceName: "app", kind: .removeAndRecreate)])
    }

    @Test("reconcileDecision: stopped container + matching hash + defaults → .start (not .keep)")
    func reconcileStoppedContainerMatchingHashStarts() throws {
        let file = try singleServiceFile()
        let svc = file.services["app"]!
        let hash = ComposeService.hash(of: svc)
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-app-1", serviceName: "app", configHash: hash, state: .stopped)
            ],
            composeFile: file,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: false
        )
        #expect(actions == [ReconcileAction(serviceName: "app", kind: .start)])
    }

    @Test(
        "reconcileDecision: non-running container + matching hash + defaults → .start",
        arguments: [ContainerState.stopped, .exited, .created, .dead]
    )
    func reconcileNonRunningStatesStart(state: ContainerState) throws {
        let file = try singleServiceFile()
        let svc = file.services["app"]!
        let hash = ComposeService.hash(of: svc)
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-app-1", serviceName: "app", configHash: hash, state: state)
            ],
            composeFile: file,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: false
        )
        #expect(actions == [ReconcileAction(serviceName: "app", kind: .start)])
    }

    @Test("reconcileDecision: running container + matching hash + defaults → .keep")
    func reconcileRunningContainerMatchingHashKeeps() throws {
        let file = try singleServiceFile()
        let svc = file.services["app"]!
        let hash = ComposeService.hash(of: svc)
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-app-1", serviceName: "app", configHash: hash, state: .running)
            ],
            composeFile: file,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: false
        )
        #expect(actions == [ReconcileAction(serviceName: "app", kind: .keep)])
    }

    @Test("reconcileDecision: stopped container + matching hash + --no-recreate → .start")
    func reconcileStoppedContainerNoRecreateStarts() throws {
        let file = try singleServiceFile()
        let svc = file.services["app"]!
        let hash = ComposeService.hash(of: svc)
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-app-1", serviceName: "app", configHash: hash, state: .stopped)
            ],
            composeFile: file,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: true
        )
        #expect(actions == [ReconcileAction(serviceName: "app", kind: .start)])
    }

    @Test("reconcileDecision: stopped container + diverged hash + defaults → .removeAndRecreate (not .start)")
    func reconcileStoppedContainerDivergedHashRecreates() throws {
        let file = try singleServiceFile()
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-app-1", serviceName: "app", configHash: "sha256:different", state: .stopped)
            ],
            composeFile: file,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: false
        )
        #expect(actions == [ReconcileAction(serviceName: "app", kind: .removeAndRecreate)])
    }

    @Test("reconcileDecision: multiple services + --force-recreate → all .removeAndRecreate")
    func reconcileMultipleServicesForceRecreate() throws {
        let file = try ComposeFile.parse("""
        services:
          web:
            image: nginx:alpine
          db:
            image: redis:7
        """)
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-web-1", serviceName: "web", configHash: ComposeService.hash(of: file.services["web"]!)),
                observed(name: "proj-db-1", serviceName: "db", configHash: ComposeService.hash(of: file.services["db"]!)),
            ],
            composeFile: file,
            projectName: "proj",
            forceRecreate: true,
            noRecreate: false
        )
        #expect(actions == [
            ReconcileAction(serviceName: "db", kind: .removeAndRecreate),
            ReconcileAction(serviceName: "web", kind: .removeAndRecreate),
        ])
    }

    @Test("reconcileDecision: empty observedContainers (post-prefix-filter) → all .noOp")
    func reconcileIgnoresForeignProject() throws {
        let file = try singleServiceFile()
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [],
            composeFile: file,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: false
        )
        #expect(actions == [ReconcileAction(serviceName: "app", kind: .noOp)])
    }

    @Test("reconcileDecision: empty composeFile → empty actions list")
    func reconcileEmptyFile() {
        let empty = ComposeFile()
        let actions = ComposeOrchestrator.reconcileDecision(
            observedContainers: [
                observed(name: "proj-app-1", serviceName: "app", configHash: "sha256:x")
            ],
            composeFile: empty,
            projectName: "proj",
            forceRecreate: false,
            noRecreate: false
        )
        #expect(actions.isEmpty)
    }

    @Test("Relative bind-mount source anchors to project directory, not CWD (issue #60)")
    func resolveRelativeBindMountAnchorsToProjectDirectory() throws {
        // Use a project directory that is guaranteed to differ from the process CWD.
        let projectDir = URL(fileURLWithPath: "/tmp/mocker-issue-60-project")
        let mounts = try ComposeOrchestrator.resolveVolumeMounts(
            ["./data:/container/data"],
            projectDir: projectDir,
            namedVolumeSources: [:]
        )
        #expect(mounts.count == 1)
        #expect(mounts[0].source == "/tmp/mocker-issue-60-project/data")
        #expect(mounts[0].source != URL(fileURLWithPath: "./data").standardized.path)
    }

    @Test("Parent-relative bind-mount source anchors to project directory, not CWD (issue #60)")
    func resolveParentRelativeBindMountAnchorsToProjectDirectory() throws {
        let projectDir = URL(fileURLWithPath: "/tmp/mocker-issue-60-project/nested")
        let mounts = try ComposeOrchestrator.resolveVolumeMounts(
            ["../shared:/container/shared"],
            projectDir: projectDir,
            namedVolumeSources: [:]
        )
        #expect(mounts.count == 1)
        #expect(mounts[0].source == "/tmp/mocker-issue-60-project/shared")
    }
}

@Suite("ComposeOrchestrator.replace Tests")
struct ComposeReplaceTests {

    private struct StopFailed: Error {}

    private actor Calls {
        var log: [String] = []
        func add(_ call: String) { log.append(call) }
    }

    private func container(_ state: ContainerState) -> ObservedContainer {
        ObservedContainer(name: "proj-app-1", serviceName: "app", configHash: nil, network: "proj-default", state: state)
    }

    @Test("stops a running container before it removes it, as Docker Compose does")
    func stopsRunning() async {
        let calls = Calls()

        await ComposeOrchestrator.replace(
            container(.running),
            stop: { await calls.add("stop \($0)") },
            remove: { await calls.add("remove \($0)") }
        )

        #expect(await calls.log == ["stop proj-app-1", "remove proj-app-1"])
    }

    @Test("removes a stopped container without stopping it")
    func removesStopped() async {
        let calls = Calls()

        await ComposeOrchestrator.replace(
            container(.stopped),
            stop: { await calls.add("stop \($0)") },
            remove: { await calls.add("remove \($0)") }
        )

        #expect(await calls.log == ["remove proj-app-1"])
    }

    @Test("still removes a container it couldn't stop")
    func removesAfterFailedStop() async {
        let calls = Calls()

        await ComposeOrchestrator.replace(
            container(.running),
            stop: { await calls.add("stop \($0)"); throw StopFailed() },
            remove: { await calls.add("remove \($0)") }
        )

        #expect(await calls.log == ["stop proj-app-1", "remove proj-app-1"])
    }
}
