import Foundation

/// Progress events emitted during compose operations.
public enum ComposeEvent: Sendable {
    case networkCreated(String)
    case volumeCreated(String)
    case containerCreated(String)
    case containerStarted(String)
    case containerRunning(String)
    case containerStopped(String)
    case containerRemoved(String)
    case networkRemoved(String)
    case volumeRemoved(String)
    case imageRemoved(String)
}

/// Which images `compose down --rmi` removes.
public enum ComposeImageRemoval: String, Sendable, CaseIterable {
    /// Every image the project's services reference, pulled ones included.
    case all
    /// Only images compose built itself, i.e. services with no explicit `image:`.
    case local
}

/// Orchestrates multi-container deployments from a compose file.
public actor ComposeOrchestrator {
    private let engine: ContainerEngine
    private let imageManager: ImageManager
    private let networkManager: NetworkManager
    private let volumeManager: VolumeManager
    private let projectName: String
    private let projectDir: URL
    private var hostsRefresh: Task<Void, Error>?

    public init(
        projectName: String,
        projectDir: URL,
        engine: ContainerEngine,
        imageManager: ImageManager,
        networkManager: NetworkManager,
        volumeManager: VolumeManager
    ) {
        self.projectName = projectName
        self.projectDir = projectDir
        self.engine = engine
        self.imageManager = imageManager
        self.networkManager = networkManager
        self.volumeManager = volumeManager
    }

    /// Start all services defined in a compose file.
    /// - Parameters:
    ///   - build: force-build images even if they already exist (compose `--build`).
    ///   - noBuild: never build, pull `image:` instead (compose `--no-build`).
    ///   - forceRecreate: recreate every project container regardless of hash
    ///     (compose `--force-recreate`).
    ///   - noRecreate: never recreate existing project containers (compose `--no-recreate`).
    public func up(
        composeFile: ComposeFile,
        detach: Bool = false,
        build: Bool = false,
        noBuild: Bool = false,
        forceRecreate: Bool = false,
        noRecreate: Bool = false,
        wait: Bool = false,
        waitTimeout: Int? = nil
    ) async throws -> [ComposeEvent] {
        var events: [ComposeEvent] = []

        try composeFile.validateNetworkReferences()

        // An external network is declared, not owned: the project joins it and must not
        // start at all if it is missing, rather than silently running unconnected.
        if composeFile.networks.values.contains(where: \.external) {
            // Listed once: a failure here is a backend problem and must surface as itself,
            // not as a misleading "your external network is missing".
            let existing = Set(try await networkManager.list().map(\.name))
            for network in composeFile.networks.values where network.external {
                let name = network.runtimeName(projectName: projectName)
                guard existing.contains(name) else {
                    throw MockerError.operationFailed(
                        "network \(name) declared as external, but could not be found")
                }
            }
        }

        // An unusable name, a missing external volume and a native volume that several
        // services would attach at once have to fail here, before any network or service
        // is created, rather than as a runtime error half-way through.
        let shared = Self.sharedVolumes(composeFile: composeFile, projectName: projectName)
        if !composeFile.volumes.isEmpty {
            let existing = Set(try await volumeManager.list().map(\.name))
            for volume in composeFile.volumes.values {
                let name = volume.runtimeName(projectName: projectName)
                let isDirectory = try volumeManager.directoryPath(name) != nil
                if shared.contains(name) {
                    guard isDirectory || !existing.contains(name) else {
                        let fix = volume.external
                            ? "mount it in one service only"
                            : "copy its data out, then remove it (mocker volume rm \(name)) so it is recreated as a shared directory volume"
                        throw MockerError.operationFailed(
                            "volume \(name) is mounted by several services, but it is a native volume, which only one running container can attach; \(fix)")
                    }
                } else if !isDirectory && !volume.external {
                    try VolumeManager.validateNewName(name)
                }
                guard !volume.external || existing.contains(name) else {
                    throw MockerError.operationFailed(
                        "volume \(name) declared as external, but could not be found")
                }
            }
        }

        // Create networks
        for (fullName, driver) in Self.networksToCreate(composeFile: composeFile, projectName: projectName) {
            do {
                _ = try await networkManager.create(name: fullName, driver: driver)
                events.append(.networkCreated(fullName))
            } catch {
                // Creation fails both when the network already exists and when the runtime
                // rejects it (it has its own naming rules). Only the first is benign, and a
                // service cannot join a network that does not exist — so keep the runtime's
                // own diagnostic rather than replacing it with a generic one.
                guard (try? await networkManager.inspect(fullName)) != nil else {
                    throw error
                }
            }
        }

        // Create volumes. External volumes are declared, not owned — the project
        // must use them as they are and never create (or later remove) them.
        // A volume several services mount is a directory volume: a native one attaches to
        // only one running container, since each container is its own VM.
        for (fullName, driver) in Self.volumesToCreate(composeFile: composeFile, projectName: projectName) {
            do {
                if shared.contains(fullName) {
                    _ = try await volumeManager.createDirectory(name: fullName)
                } else {
                    _ = try await volumeManager.create(name: fullName, driver: driver)
                }
                events.append(.volumeCreated(fullName))
            } catch {
                // Same rule as networks: only "it already exists" is benign.
                guard (try? await volumeManager.inspect(fullName)) != nil else {
                    throw error
                }
            }
        }

        let observed = (try? await engine.list(all: true))?
            .filter { Self.belongs($0, toProject: projectName) }
            .map { container -> ObservedContainer in
                ObservedContainer(
                    name: container.name,
                    serviceName: container.labels["com.mocker.compose.service"] ?? "",
                    configHash: container.labels["com.mocker.compose.config-hash"],
                    network: container.labels["com.mocker.compose.network"],
                    state: container.state
                )
            } ?? []
        let actions = Self.reconcileDecision(
            observedContainers: observed,
            composeFile: composeFile,
            projectName: projectName,
            forceRecreate: forceRecreate,
            noRecreate: noRecreate
        )
        var skipSet: Set<String> = []
        var removals: [String: Task<Void, Never>] = [:]
        for action in actions {
            switch action.kind {
            case .keep:
                // Already running and config-hash matches: true no-op, no engine calls.
                skipSet.insert(action.serviceName)
                events.append(.containerRunning("\(projectName)-\(action.serviceName)-1"))
            case .start:
                // Config-hash matches but the container isn't running (stopped, exited,
                // or crashed) — start the existing container instead of recreating it.
                // This mirrors Docker Compose: a no-op reconcile still starts stopped
                // containers, it just doesn't recreate them.
                skipSet.insert(action.serviceName)
                if let existing = observed.first(where: { $0.serviceName == action.serviceName }),
                   let started = try? await engine.start(existing.name) {
                    events.append(.containerRunning(started.name))
                }
            case .removeAndRecreate:
                // In the background: a service's new container waits only for its own old
                // one, so replacing a service overlaps with what it waits for, such as a build.
                if let existing = observed.first(where: { $0.serviceName == action.serviceName }) {
                    removals[action.serviceName] = Task { _ = try? await self.engine.remove(existing.name, force: true) }
                    if existing.state.isActive { events.append(.containerStopped(existing.name)) }
                    events.append(.containerRemoved(existing.name))
                }
            case .noOp:
                break
            }
        }

        // Images first, one at a time, as Docker does: services that share one
        // would otherwise pull it twice at once.
        let order = composeFile.serviceOrder().filter { !skipSet.contains($0) }
        do {
            for serviceName in order {
                guard let service = composeFile.services[serviceName] else { continue }
                try await ensureImage(for: service, forceBuild: build, noBuild: noBuild)
            }
        } catch {
            // Never exit with a container half removed.
            for removal in removals.values { await removal.value }
            throw error
        }

        // Each service starts as soon as its own dependencies are ready, as in Docker
        // Compose, so a slow one only holds up the services that depend on it. The
        // order is topological, so a service's dependencies have tasks by its turn.
        let awaited = Self.servicesAwaitedForCompletion(composeFile)
        var completions: [String: Task<Int32, Error>] = [:]
        var startups: [String: Task<Void, Error>] = [:]

        for serviceName in order {
            guard let service = composeFile.services[serviceName] else { continue }
            let ready = Self.ready(
                after: dependenciesReady(of: service, composeFile: composeFile, startups: startups, completions: completions),
                removal: removals[serviceName]
            )

            if awaited.contains(serviceName) {
                // Runs until it exits, so its exit code is known when others need it.
                let completion = Task {
                    try await ready.value
                    let config = try await self.containerConfig(for: service, composeFile: composeFile, detach: detach)
                    return try await self.engine.runToCompletion(config) { _ in
                        try? await self.refreshHostsFiles(composeFile)
                    }
                }
                completions[serviceName] = completion
                startups[serviceName] = Task { _ = try await completion.value }
            } else {
                startups[serviceName] = Task {
                    try await ready.value
                    _ = try await self.engine.run(try await self.containerConfig(for: service, composeFile: composeFile, detach: detach))
                    // Its own name now that it has an address, and its name for the others.
                    try await self.refreshHostsFiles(composeFile)
                }
            }
            events.append(.containerStarted("\(projectName)-\(service.name)-1"))
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for startup in startups.values { group.addTask { try await startup.value } }
                try await group.waitForAll()
            }
        } catch {
            startups.values.forEach { $0.cancel() }
            completions.values.forEach { $0.cancel() }
            for removal in removals.values { await removal.value }
            throw error
        }

        // Containers started rather than recreated above have new addresses too.
        try await refreshHostsFiles(composeFile)

        if wait {
            try await waitUntilReady(composeFile, completions: completions, timeout: waitTimeout)
        }

        return events
    }

    /// Stop and remove all services.
    /// - Parameter removeVolumes: also remove the project's named volumes (compose `down -v`).
    /// - Parameter removeImages: also remove the services' images (compose `down --rmi`).
    /// - Parameter timeout: seconds to wait for each container to exit (compose `--timeout`).
    public func down(
        composeFile: ComposeFile,
        removeVolumes: Bool = false,
        removeImages: ComposeImageRemoval? = nil,
        timeout: Int? = nil
    ) async throws -> [ComposeEvent] {
        var events: [ComposeEvent] = []
        let containers = try await ps()

        events += try await Self.tearDown(
            containers,
            dependents: Self.dependents(of: containers, composeFile: composeFile),
            stop: { [engine] in _ = try await engine.stop($0.id, timeout: timeout) },
            remove: { [engine] in _ = try await engine.remove($0.id, force: $1) }
        )

        // Remove networks. The backend can still consider a just-removed container
        // attached for a moment, so retry briefly instead of silently leaving the
        // network behind — and say so if it still cannot be removed.
        let existingNetworks = Set(((try? await networkManager.list()) ?? []).map(\.name))
        for fullName in Self.networksToRemove(composeFile: composeFile, projectName: projectName) {
            // Nothing to do for a project that is already down — retrying that would burn
            // a second and end in a warning telling the user to remove what is not there.
            guard existingNetworks.contains(fullName) else { continue }

            var removed = false
            for attempt in 0..<3 {
                if (try? await networkManager.remove(fullName)) != nil {
                    events.append(.networkRemoved(fullName))
                    removed = true
                    break
                }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(300)) }
            }
            if !removed {
                FileHandle.standardError.write(Data(
                    "WARNING: could not remove network \(fullName); remove it manually once its containers are gone\n".utf8))
            }
        }

        if removeVolumes {
            for fullName in Self.volumesToRemove(composeFile: composeFile, projectName: projectName) {
                do {
                    _ = try await volumeManager.remove(fullName)
                    events.append(.volumeRemoved(fullName))
                } catch MockerError.volumeNotFound {
                    // Never created, or already gone: nothing to remove.
                } catch {
                    // The runtime refuses a native volume something still uses; say so rather
                    // than leave the data for the next `up` to find.
                    FileHandle.standardError.write(Data(
                        "WARNING: could not remove volume \(fullName): \(error.localizedDescription)\n".utf8))
                }
            }
        }

        if let removeImages {
            // Best-effort, like the network and volume loops: an image that is missing or
            // still used by something outside the project must not abort the teardown.
            for tag in Self.imagesToRemove(composeFile: composeFile, projectName: projectName, mode: removeImages) {
                if (try? await imageManager.remove(tag)) != nil {
                    events.append(.imageRemoved(tag))
                } else {
                    FileHandle.standardError.write(Data(
                        "WARNING: could not remove image \(tag)\n".utf8))
                }
            }
        }

        for kind in [FileObjectKind.config, .secret] {
            try? FileManager.default.removeItem(at: hostDirectory(for: kind))
        }
        try? FileManager.default.removeItem(at: hostsDirectory)

        return events
    }

    /// Stops a container that was running when it was listed, and says whether it stopped
    /// it. One that exited on its own since, such as a one-shot service finishing while
    /// `down` stops the others, is already stopped: Docker Compose goes on, and so does this.
    nonisolated static func stopListed(_ stop: @Sendable () async throws -> Void) async throws -> Bool {
        do {
            try await stop()
            return true
        } catch MockerError.containerNotRunning {
            return false
        }
    }

    /// Stops and removes the containers `down` listed, all at the same time, as Docker
    /// Compose does. A container is stopped once the containers in `dependents`, those of
    /// the services that depend on its own, have stopped, so a database stops after the
    /// apps using it. Each is removed by force, as Docker Compose does: one an interrupted
    /// `up` was still starting can be running by now, though it was listed as stopped.
    nonisolated static func tearDown(
        _ containers: [ContainerInfo],
        dependents: [String: [String]] = [:],
        stop: @escaping @Sendable (ContainerInfo) async throws -> Void,
        remove: @escaping @Sendable (ContainerInfo, _ force: Bool) async throws -> Void
    ) async throws -> [ComposeEvent] {
        let byName = Dictionary(containers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var stops: [String: Task<Bool, Error>] = [:]
        var teardowns: [String: Task<[ComposeEvent], Error>] = [:]
        var scheduling: Set<String> = []

        func schedule(_ container: ContainerInfo) {
            guard stops[container.name] == nil, !scheduling.contains(container.name) else { return }
            scheduling.insert(container.name)

            let first = (dependents[container.name] ?? []).compactMap { byName[$0] }
            first.forEach(schedule)
            let waits = first.compactMap { stops[$0.name] }

            let stopped = Task {
                for wait in waits { _ = try? await wait.value }
                guard container.state.isActive else { return false }
                return try await stopListed({ try await stop(container) })
            }
            stops[container.name] = stopped
            teardowns[container.name] = Task {
                var events: [ComposeEvent] = []
                if try await stopped.value {
                    events.append(.containerStopped(container.name))
                }
                try await remove(container, true)
                events.append(.containerRemoved(container.name))
                return events
            }
        }
        containers.forEach(schedule)

        var events: [ComposeEvent] = []
        var firstError: Error?
        for container in containers {
            guard let teardown = teardowns[container.name] else { continue }
            do {
                events += try await teardown.value
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
        return events
    }

    nonisolated static func dependents(of containers: [ContainerInfo], composeFile: ComposeFile) -> [String: [String]] {
        let service = { (container: ContainerInfo) in container.labels["com.mocker.compose.service"] ?? "" }

        var dependents: [String: [String]] = [:]
        for container in containers {
            let name = service(container)
            dependents[container.name] = containers
                .filter { composeFile.services[service($0)]?.dependsOn.contains(name) == true }
                .map(\.name)
        }
        return dependents
    }

    /// Whether a container belongs to `service` in this project. The label written at
    /// creation time is authoritative; containers predating it fall back to the
    /// `<project>-<service>-<index>` naming, which is still an exact match.
    public nonisolated static func belongs(
        _ container: ContainerInfo,
        to service: String,
        projectName: String
    ) -> Bool {
        guard belongs(container, toProject: projectName) else { return false }
        return container.labels["com.mocker.compose.service"] == service
    }

    /// Images `down --rmi` removes, under the tag each service actually runs from.
    /// `local` is limited to images compose built (no explicit `image:`), matching
    /// upstream; `all` covers pulled images too. Pure, so the selection is testable
    /// without a backend.
    public nonisolated static func imagesToRemove(
        composeFile: ComposeFile,
        projectName: String,
        mode: ComposeImageRemoval
    ) -> [String] {
        let services = composeFile.services
            .sorted { $0.key < $1.key }
            .map(\.value)
            .filter { mode == .all || $0.image == nil }
        // A tag can be shared by two services; remove it once.
        var seen = Set<String>()
        return services
            .map { $0.buildTag(projectName: projectName) }
            .filter { seen.insert($0).inserted }
    }

    /// Networks `up` creates: the project-owned ones, under their runtime names.
    /// External networks are joined, never created.
    public nonisolated static func networksToCreate(
        composeFile: ComposeFile,
        projectName: String
    ) -> [(name: String, driver: String)] {
        var networks = composeFile.networks
            .sorted { $0.key < $1.key }
            .filter { !$0.value.external }
            .map { ($0.value.runtimeName(projectName: projectName), $0.value.driver) }
        if implicitDefaultNetworkNeeded(composeFile: composeFile) {
            networks.append((implicitDefaultNetwork(projectName: projectName), "bridge"))
        }
        return networks
    }

    /// The project-scoped network Compose gives services that name none. Without it they
    /// land on the runtime's global network, where unrelated projects can reach each other.
    public nonisolated static func implicitDefaultNetwork(projectName: String) -> String {
        "\(projectName)-default"
    }

    /// The runtime network a service joins: the first it names, else the file's own
    /// `default:` entry if it has one, else the project's implicit default.
    public nonisolated static func networkForService(
        _ service: ComposeService,
        composeFile: ComposeFile,
        projectName: String
    ) -> String {
        if let named = service.networks.first {
            return composeFile.networks[named]?.runtimeName(projectName: projectName)
                ?? "\(projectName)-\(named)"
        }
        return composeFile.networks["default"]?.runtimeName(projectName: projectName)
            ?? implicitDefaultNetwork(projectName: projectName)
    }

    /// Only needed when some service does not name a network of its own.
    nonisolated static func implicitDefaultNetworkNeeded(composeFile: ComposeFile) -> Bool {
        composeFile.services.values.contains { $0.networks.isEmpty }
            && composeFile.networks["default"] == nil
    }

    /// Networks `down` may remove — the mirror of `networksToCreate`, so the two can
    /// never disagree about which networks the project owns.
    public nonisolated static func networksToRemove(
        composeFile: ComposeFile,
        projectName: String
    ) -> [String] {
        networksToCreate(composeFile: composeFile, projectName: projectName).map(\.name)
    }

    /// Volumes `up` creates: the project-owned ones, under their runtime names.
    /// The mirror image of `volumesToRemove`, so the two can never disagree.
    public nonisolated static func volumesToCreate(
        composeFile: ComposeFile,
        projectName: String
    ) -> [(name: String, driver: String)] {
        composeFile.volumes
            .sorted { $0.key < $1.key }
            .filter { !$0.value.external }
            .map { ($0.value.runtimeName(projectName: projectName), $0.value.driver) }
    }

    /// Runtime names of the top-level volumes that more than one service mounts.
    public nonisolated static func sharedVolumes(
        composeFile: ComposeFile,
        projectName: String
    ) -> Set<String> {
        Set(composeFile.sharedVolumeKeys.compactMap { composeFile.volumes[$0]?.runtimeName(projectName: projectName) })
    }

    /// Project-owned volumes that `down --volumes` may remove: every non-`external:`
    /// volume in the file's top-level `volumes:` section, under the name it actually
    /// has at runtime. That is the project-prefixed name unless the file gives an
    /// explicit `name:`, which Compose uses verbatim — an unprefixed volume shared
    /// with another project is therefore in range, exactly as with `docker compose`.
    /// Pure so the removal set can be unit-tested without a container backend.
    public nonisolated static func volumesToRemove(
        composeFile: ComposeFile,
        projectName: String
    ) -> [String] {
        composeFile.volumes
            .sorted { $0.key < $1.key }
            .filter { !$0.value.external }
            .map { $0.value.runtimeName(projectName: projectName) }
    }

    /// List services and their status.
    public func ps() async throws -> [ContainerInfo] {
        let containers = try await engine.list(all: true)
        return containers.filter { Self.belongs($0, toProject: projectName) }
    }

    /// The prefix `compose logs` puts before each container's lines, as Docker Compose
    /// does: the name without the project, padded to the longest, then ` | `.
    public nonisolated static func logPrefixes(_ containerNames: [String], projectName: String) -> [String: String] {
        let shortNames = containerNames.map { name in
            name.hasPrefix(projectName + "-") ? String(name.dropFirst(projectName.count + 1)) : name
        }
        let width = shortNames.map(\.count).max() ?? 0

        var prefixes: [String: String] = [:]
        for (name, short) in zip(containerNames, shortNames) {
            prefixes[name] = short.padding(toLength: width, withPad: " ", startingAt: 0) + " | "
        }
        return prefixes
    }

    /// Whether a container belongs to this project, by the label written when compose
    /// created it (since the first release, so every project container carries it).
    ///
    /// Deliberately no name-prefix fallback: `app-prod-web-1` is indistinguishable from
    /// project `app`'s service `prod-web` by name alone, and `down`/`restart` remove what
    /// they select — a guess there deletes another project's containers.
    public nonisolated static func belongs(_ container: ContainerInfo, toProject projectName: String) -> Bool {
        container.labels["com.mocker.compose.project"] == projectName
    }

    /// Restart a service's containers, or every service's, in place, as Docker Compose
    /// does: the same containers are stopped and started again, so it doesn't apply
    /// changes to the compose file (`up` does) and doesn't create missing containers.
    /// - Parameter timeout: seconds to wait for each container to stop before it is killed.
    public func restart(composeFile: ComposeFile, service: String? = nil, timeout: Int? = nil) async throws -> [ComposeEvent] {
        var events: [ComposeEvent] = []
        let targets = Self.restartTargets(try await ps(), service: service, order: composeFile.serviceOrder(), projectName: projectName)

        for container in targets {
            if container.state.isActive, try await Self.stopListed({ _ = try await engine.stop(container.id, timeout: timeout) }) {
                events.append(.containerStopped(container.name))
            }
            _ = try await engine.start(container.id)
            events.append(.containerStarted(container.name))
        }

        // A restarted container can come back with a new address, so every container's
        // hostnames change.
        try await refreshHostsFiles(composeFile)

        return events
    }

    /// The containers `restart` restarts: the service's, or every service's, in the
    /// order services start in.
    nonisolated static func restartTargets(
        _ containers: [ContainerInfo],
        service: String?,
        order: [String],
        projectName: String
    ) -> [ContainerInfo] {
        let services = service.map { [$0] } ?? order
        return services.flatMap { name in
            containers.filter { belongs($0, to: name, projectName: projectName) }
        }
    }

    /// Ready once the dependencies are and the service's old container, removed in the
    /// background, is gone: the new container takes its name.
    nonisolated static func ready(after dependencies: Task<Void, Error>, removal: Task<Void, Never>?) -> Task<Void, Error> {
        Task {
            await removal?.value
            try await dependencies.value
        }
    }

    /// A task that finishes once `service` may start: every dependency has started,
    /// and is healthy or has completed when its condition asks for that.
    private func dependenciesReady(
        of service: ComposeService,
        composeFile: ComposeFile,
        startups: [String: Task<Void, Error>],
        completions: [String: Task<Int32, Error>]
    ) -> Task<Void, Error> {
        Task {
            for dependency in service.dependsOn {
                try await startups[dependency]?.value
                switch service.dependsOnConditions[dependency] {
                case "service_healthy":
                    try await self.waitUntilHealthy(dependency, composeFile: composeFile)
                case "service_completed_successfully":
                    if let exitCode = try await completions[dependency]?.value, exitCode != 0 {
                        throw MockerError.operationFailed("service \"\(dependency)\" didn't complete successfully: exit \(exitCode)")
                    }
                default:
                    break
                }
            }
        }
    }

    /// `up --wait`: block until every service is running, or healthy when it has a
    /// health check, or has completed when another service waits for that, as Docker
    /// Compose does. With a timeout, give up after `timeout` seconds.
    private func waitUntilReady(
        _ composeFile: ComposeFile,
        completions: [String: Task<Int32, Error>],
        timeout: Int?
    ) async throws {
        guard let timeout, timeout > 0 else {
            try await waitUntilReady(composeFile, completions: completions)
            return
        }

        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await self.waitUntilReady(composeFile, completions: completions); return true }
            group.addTask { try await Task.sleep(for: .seconds(timeout)); return false }
            let ready = try await group.next() ?? false
            group.cancelAll()
            guard ready else { throw MockerError.operationFailed("application not healthy after \(timeout)s") }
        }
    }

    /// Every service is checked at the same time, as Docker Compose does: one after the
    /// other, each health check's round trip into its container added up, even when
    /// every service was already healthy.
    private func waitUntilReady(_ composeFile: ComposeFile, completions: [String: Task<Int32, Error>]) async throws {
        let awaited = Self.servicesAwaitedForCompletion(composeFile)
        try await Self.checkAll(composeFile.serviceOrder()) { serviceName in
            guard let service = composeFile.services[serviceName] else { return }
            try await self.waitUntilReady(serviceName, service: service, awaited: awaited, completions: completions, composeFile: composeFile)
        }
    }

    /// Run `check` for every name at the same time, and throw the first error.
    nonisolated static func checkAll(_ names: [String], check: @escaping @Sendable (String) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in names {
                group.addTask { try await check(name) }
            }
            // Unlike `waitForAll`, this throws as soon as one check fails.
            for try await _ in group {}
        }
    }

    private func waitUntilReady(
        _ serviceName: String,
        service: ComposeService,
        awaited: Set<String>,
        completions: [String: Task<Int32, Error>],
        composeFile: ComposeFile
    ) async throws {
        let containerName = "\(projectName)-\(serviceName)-1"

        if awaited.contains(serviceName) {
            if let exitCode = try await completions[serviceName]?.value, exitCode != 0 {
                throw MockerError.operationFailed("service \"\(serviceName)\" didn't complete successfully: exit \(exitCode)")
            }
        } else if let check = service.healthcheck, !check.isDisabled {
            try await waitUntilHealthy(serviceName, composeFile: composeFile)
        } else {
            // Without a health check, running is enough. The runtime doesn't
            // report exit codes, so unlike Docker the message has none.
            let running = try await engine.list(all: false).contains { $0.name == containerName }
            guard running else { throw MockerError.operationFailed("container \(containerName) exited") }
        }
    }

    /// Services another service waits on with `condition: service_completed_successfully`.
    nonisolated static func servicesAwaitedForCompletion(_ composeFile: ComposeFile) -> Set<String> {
        Set(composeFile.services.values.flatMap { service in
            service.dependsOn.filter { service.dependsOnConditions[$0] == "service_completed_successfully" }
        })
    }

    // MARK: - Private

    /// Block until `serviceName`'s health check passes, as `depends_on`
    /// `condition: service_healthy` asks. Errors match Docker Compose's.
    private func waitUntilHealthy(_ serviceName: String, composeFile: ComposeFile) async throws {
        let containerName = "\(projectName)-\(serviceName)-1"
        guard let check = composeFile.services[serviceName]?.healthcheck, !check.isDisabled else {
            throw MockerError.operationFailed("dependency failed to start: container \(containerName) has no healthcheck configured")
        }

        let outcome = try await HealthCheck.waitUntilHealthy(
            check,
            probe: { await self.runHealthCheck(check, in: containerName) },
            isRunning: { (try? await self.engine.list(all: false))?.contains { $0.name == containerName } ?? true },
            sleep: { try await Task.sleep(for: .seconds($0)) }
        )
        switch outcome {
        case .healthy:
            return
        case .unhealthy:
            throw MockerError.operationFailed("dependency failed to start: container \(containerName) is unhealthy")
        case .exited:
            // The runtime doesn't report exit codes, so unlike Docker the message has none.
            throw MockerError.operationFailed("dependency failed to start: container \(containerName) exited")
        }
    }

    /// Run the check's command in the container: true when it exits 0 within its timeout.
    private func runHealthCheck(_ check: HealthCheck, in containerName: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLIResolver.resolve())
        process.arguments = ["exec", containerName] + check.command
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationReason == .exit && finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + check.timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Each container's /etc/hosts is a file here, mounted in place of the runtime's.
    /// It is written before the container starts, so the services it depends on resolve
    /// from its first instruction, and rewritten when addresses change, without exec.
    nonisolated var hostsDirectory: URL {
        URL(fileURLWithPath: MockerConfig().dataRoot)
            .appendingPathComponent("hosts", isDirectory: true)
            .appendingPathComponent(projectName, isDirectory: true)
    }

    nonisolated func hostsFile(for serviceName: String) -> URL {
        hostsDirectory
            .appendingPathComponent(serviceName, isDirectory: true)
            .appendingPathComponent("hosts")
    }

    /// What a service's hosts file lists: its own hostname and its service name, since
    /// Docker's DNS answers a container for both, then the other services.
    nonisolated static func hostsEntries(
        service: String,
        hostname: String,
        address: String,
        others: [(name: String, address: String)]
    ) -> [(name: String, address: String)] {
        var own = [(name: hostname, address: address)]
        if service != hostname {
            own.append((name: service, address: address))
        }
        return own + others.sorted { $0.name < $1.name }
    }

    /// `current` /etc/hosts updated to map each of `entries` and nothing else under the
    /// `managed` names. Lines that stay keep their place and new ones go at the end:
    /// the container caches the file's size for a moment, so content that moved past
    /// the old end would be cut off from it.
    nonisolated static func updatedHosts(
        _ current: String?,
        entries: [(name: String, address: String)],
        managed: Set<String>
    ) -> String {
        var lines = current?.split(separator: "\n").map(String.init) ?? ["127.0.0.1 localhost"]
        let wanted = entries.map { "\($0.address) \($0.name)" }
        lines = lines.filter { line in
            let names = line.split(whereSeparator: \.isWhitespace).dropFirst()
            return wanted.contains(line) || !names.contains { managed.contains(String($0)) }
        }
        lines += wanted.filter { !lines.contains($0) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write a service's hosts file, appending when only lines were added. Never
    /// truncate first or replace the file: a running container reads this very file.
    private func writeHostsFile(
        for serviceName: String,
        entries: [(name: String, address: String)],
        managed: Set<String>,
        fresh: Bool = false
    ) throws -> URL {
        let file = hostsFile(for: serviceName)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        let current = fresh ? nil : try? String(contentsOf: file, encoding: .utf8)
        let content = Self.updatedHosts(current, entries: entries, managed: managed)
        guard content != current else { return file }
        guard let handle = FileHandle(forWritingAtPath: file.path) else {
            try content.write(to: file, atomically: false, encoding: .utf8)
            return file
        }
        defer { try? handle.close() }

        if let current, content.hasPrefix(current) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(content.utf8.dropFirst(current.utf8.count)))
        } else {
            let data = Data(content.utf8)
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
        }
        return file
    }

    /// Running containers that have an address, with their service.
    private func runningServices() async throws -> [(service: String, info: ContainerInfo)] {
        try await ps().compactMap { container in
            guard container.state.isActive, !container.networkAddress.isEmpty,
                  let service = container.labels["com.mocker.compose.service"] else { return nil }
            return (service, container)
        }
    }

    /// The hosts file a new container starts with: every running service but itself.
    private func writeHostsFileBeforeStart(_ serviceName: String, composeFile: ComposeFile) async throws -> URL {
        let others = try await runningServices()
            .filter { $0.service != serviceName }
            .map { (name: $0.service, address: $0.info.networkAddress) }
            .sorted { $0.name < $1.name }
        return try writeHostsFile(for: serviceName, entries: others, managed: Set(composeFile.services.keys), fresh: true)
    }

    /// Update every running container's hosts file with its own name and the others'.
    /// One at a time: services start at once, and a refresh that read the running
    /// containers earlier would write an older list over a newer one.
    private func refreshHostsFiles(_ composeFile: ComposeFile) async throws {
        let previous = hostsRefresh
        let refresh = Task {
            _ = try? await previous?.value
            try await self.refreshHostsFilesNow(composeFile)
        }
        hostsRefresh = refresh
        try await refresh.value
    }

    private func refreshHostsFilesNow(_ composeFile: ComposeFile) async throws {
        let running = try await runningServices()
        for (service, info) in running {
            let hostname = composeFile.services[service]?.hostname ?? info.name
            let others = running
                .filter { $0.service != service }
                .map { (name: $0.service, address: $0.info.networkAddress) }
            let entries = Self.hostsEntries(service: service, hostname: hostname, address: info.networkAddress, others: others)
            _ = try writeHostsFile(for: service, entries: entries, managed: Set(composeFile.services.keys).union([hostname]))
        }
    }

    /// Pull or build the service's image.
    private func ensureImage(for service: ComposeService, forceBuild: Bool, noBuild: Bool) async throws {
        // Decide whether to build or pull. Per the Compose spec, a service with
        // both `image:` and `build:` is built and tagged with `image:` — not pulled.
        switch service.resolveImageSource(projectName: projectName, noBuild: noBuild) {
        case .pull(let image):
            _ = try await imageManager.pull(image)
        case .build(let tag, let build):
            // Skip the rebuild only when `--build` wasn't requested and the image exists.
            var shouldBuild = forceBuild
            if !shouldBuild {
                // Only repository and tag are compared here, so skip the per-image metadata reads.
                let existingImages = try await imageManager.list(enrich: false)
                shouldBuild = !existingImages.contains { ComposeService.imageMatches($0, tag: tag) }
            }
            if shouldBuild {
                let absContext = ImageManager.resolveContextPath(context: build.context, cwd: projectDir.path)
                let dockerfilePath = ImageManager.composeDockerfilePath(
                    context: absContext,
                    dockerfile: build.dockerfile ?? "Dockerfile",
                    cwd: projectDir.path
                )
                _ = try await imageManager.build(
                    tags: [tag],
                    context: absContext,
                    dockerfile: dockerfilePath,
                    buildArgs: build.argList,
                    target: build.target
                )
            }
        case .none:
            break
        }
    }

    /// The config the service's container runs with. Its image must exist.
    private func containerConfig(
        for service: ComposeService,
        composeFile: ComposeFile = ComposeFile(),
        detach: Bool
    ) async throws -> ContainerConfig {
        let containerName = "\(projectName)-\(service.name)-1"

        // Resolved once: it is both what the container joins and what is recorded on it,
        // so a later change to the network is visible to the reconcile.
        let resolvedNetwork = Self.networkForService(
            service, composeFile: composeFile, projectName: projectName
        )

        if service.networks.count > 1 {
            FileHandle.standardError.write(Data(
                ("WARNING: service \(service.name) lists \(service.networks.count) networks; "
                 + "the runtime attaches one, joining \(service.networks[0])\n").utf8))
        }

        // Same helper the build path tags with, so run and build never disagree.
        let imageName = service.buildTag(projectName: projectName)

        // Parse port mappings
        let ports = try service.ports.map { try PortMapping.parse($0) }

        // Named volumes outlive the container, native or directory-backed, so the data
        // survives container recreation.
        let volumes = try Self.resolveVolumeMounts(
            service.volumes,
            projectDir: projectDir,
            namedVolumeSources: composeFile.volumes.mapValues {
                try volumeManager.composeSource($0.runtimeName(projectName: projectName))
            }
        ) + fileObjectMounts(for: service, composeFile: composeFile)
            + [VolumeMount(source: try await writeHostsFileBeforeStart(service.name, composeFile: composeFile).path, destination: "/etc/hosts")]

        // Docker's exec model concatenates entrypoint + command into one argv.
        // Apple's `container` CLI can only override the executable
        // (`--entrypoint <cmd>`, a single token, no args), so the first
        // entrypoint element is used as the executable and any remaining
        // elements are spliced ahead of the command args.
        let exec = Self.resolveExec(entrypoint: service.entrypoint, command: service.command)

        let config = ContainerConfig(
            name: containerName,
            image: imageName,
            command: exec.command,
            environment: service.environment,
            ports: ports,
            volumes: volumes,
            // Resolved through the network's own declaration so an external network is
            // joined under its real name instead of a project-prefixed one that
            // does not exist. Only the first is used: attaching a container to a second
            // network fails inside the guest on this runtime.
            network: resolvedNetwork,
            detach: detach,
            labels: service.labels.merging(
                [
                    "com.mocker.compose.project": projectName,
                    "com.mocker.compose.service": service.name,
                    "com.mocker.compose.config-hash": ComposeService.hash(of: service),
                    "com.mocker.compose.network": resolvedNetwork,
                ]
            ) { _, new in new },
            workingDir: service.workingDir,
            hostname: service.hostname,
            restartPolicy: service.restart.flatMap { RestartPolicy(rawValue: $0) } ?? .no,
            user: service.user,
            entrypoint: exec.entrypoint,
            platform: service.platform,
            // `restartPolicy` and `shmSize` (like the soft mem/cpu reservations) are stored on the
            // config for Docker surface parity, mirroring `run`/`create`. Apple's `container` CLI
            // currently exposes no `--restart`/`--shm-size` flags, so these are NOT enforced by the
            // runtime today — only `memory` (-m) and `cpus` (-c) are actually emitted.
            shmSize: service.shmSize,
            memory: service.memLimit,
            cpus: service.cpus
        )

        return config
    }

    /// Configs and secrets, which Docker Compose mounts the same way.
    enum FileObjectKind: String {
        case config, secret

        /// Where a reference without an absolute target appears in the container.
        var containerDirectory: String { self == .config ? "/" : "/run/secrets/" }
    }

    /// Where `content` and `environment` configs or secrets are written for the
    /// runtime to mount.
    nonisolated func hostDirectory(for kind: FileObjectKind) -> URL {
        URL(fileURLWithPath: MockerConfig().dataRoot)
            .appendingPathComponent("\(kind.rawValue)s", isDirectory: true)
            .appendingPathComponent(projectName, isDirectory: true)
    }

    func fileObjectMounts(for service: ComposeService, composeFile: ComposeFile) throws -> [VolumeMount] {
        try fileObjectMounts(.config, service.configs, definitions: composeFile.configs, service: service.name)
            + fileObjectMounts(.secret, service.secrets, definitions: composeFile.secrets, service: service.name)
    }

    /// Configs and secrets become read-only file mounts, as in Docker Compose without
    /// Swarm. A `file` one mounts that file. Docker copies `content` and `environment`
    /// ones into the container; here they are written to a file first, with the mode
    /// Docker gives them. Errors match Docker Compose's.
    private func fileObjectMounts(
        _ kind: FileObjectKind,
        _ references: [ComposeFileReference],
        definitions: [String: ComposeFileObject],
        service: String
    ) throws -> [VolumeMount] {
        try references.map { reference in
            guard let object = definitions[reference.source] else {
                throw MockerError.composeParseError(
                    "service \"\(service)\" refers to undefined \(kind.rawValue) \(reference.source): invalid compose project")
            }

            let name = object.runtimeName(key: reference.source, projectName: projectName)
            guard !object.external else {
                throw MockerError.operationFailed("unsupported external \(kind.rawValue) \(name)")
            }

            let target = reference.containerPath(in: kind.containerDirectory)
            if let file = object.file {
                let source = URL(fileURLWithPath: file, relativeTo: projectDir).standardized.path
                return VolumeMount(source: source, destination: target, readOnly: true)
            }

            guard let content = object.content else {
                throw MockerError.operationFailed(object.environment.map {
                    "environment variable \"\($0)\" required by \(kind.rawValue) \"\(name)\" is not set"
                } ?? "\(kind.rawValue) \"\(name)\" has no file, content or environment")
            }

            let file = try write(content, kind: kind, service: service, key: reference.source, mode: reference.mode ?? 0o444)
            return VolumeMount(source: file.path, destination: target, readOnly: true)
        }
    }

    private func write(_ content: String, kind: FileObjectKind, service: String, key: String, mode: Int) throws -> URL {
        guard !key.contains("/"), key != ".", key != ".." else {
            throw MockerError.composeParseError("invalid \(kind.rawValue) name: \(key)")
        }

        // Only the user may read them on the host, whatever mode the container sees.
        let directory = hostDirectory(for: kind).appendingPathComponent(service, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // The previous write is read-only, so replace it rather than write over it.
        let file = directory.appendingPathComponent(key)
        try? FileManager.default.removeItem(at: file)
        try Data(content.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file
    }

    /// Resolve volume spec strings from a compose service into `VolumeMount` values.
    ///
    /// Bind-mount host paths and anonymous volumes (container paths only) are
    /// included as-is. A name declared in the file's top-level `volumes:` section is
    /// mounted from `namedVolumeSources` (the native volume's name, or a directory
    /// volume's backing directory), which is what keeps the data alive across
    /// `compose up --force-recreate`; an undeclared bare name is dropped.
    ///
    /// Relative paths (`./foo`, `../bar`, `data/dir`) are resolved to absolute paths
    /// against `projectDir` (the Compose `--project-directory`, i.e. the directory
    /// containing the compose file unless overridden). This matches Docker Compose
    /// behaviour, where bind-mount sources are anchored to the project directory
    /// rather than the process's current working directory.
    static func resolveVolumeMounts(
        _ volSpecs: [String],
        projectDir: URL,
        namedVolumeSources: [String: String]
    ) throws -> [VolumeMount] {
        var volumes: [VolumeMount] = []
        for volSpec in volSpecs {
            var mount = try VolumeMount.parse(volSpec)
            if mount.source.isEmpty || mount.source.hasPrefix("/") {
                volumes.append(mount)
            } else if mount.source.hasPrefix("~") {
                mount.source = (mount.source as NSString).expandingTildeInPath
                volumes.append(mount)
            } else if mount.source.hasPrefix(".")
                      || mount.source.contains("/") {
                // Relative bind mount, anchored to the project directory.
                mount.source = projectDir.appendingPathComponent(mount.source).standardized.path
                volumes.append(mount)
            } else if let source = namedVolumeSources[mount.source] {
                mount.source = source
                volumes.append(mount)
            }
        }
        return volumes
    }

    /// Mirror Docker's exec model for a compose service: the effective argv is the
    /// entrypoint array concatenated with the command array.
    ///
    /// Apple's `container` CLI can only override the entrypoint executable via
    /// `--entrypoint <cmd>` — a single token with no args (a value like
    /// `/bin/sh -c` is treated as one executable path and fails to launch).
    /// So the first entrypoint element becomes the executable and any remaining
    /// elements are spliced ahead of the command args, preserving Docker's
    /// `ENTRYPOINT [...] + CMD [...]` semantics.
    public nonisolated static func resolveExec(
        entrypoint: [String],
        command: [String]
    ) -> (entrypoint: String?, command: [String]) {
        guard let first = entrypoint.first, !first.isEmpty else {
            return (nil, command)
        }
        return (first, Array(entrypoint.dropFirst()) + command)
    }
}
extension ComposeOrchestrator {
    /// Pure helper that returns one `ReconcileAction` per service in the project.
    /// Mirrors Docker's `mustRecreate` at `pkg/compose/reconcile.go:517-543`.
    public nonisolated static func reconcileDecision(
        observedContainers: [ObservedContainer],
        composeFile: ComposeFile,
        projectName: String,
        forceRecreate: Bool,
        noRecreate: Bool
    ) -> [ReconcileAction] {
        let awaited = servicesAwaitedForCompletion(composeFile)
        return composeFile.serviceOrder().compactMap { serviceName -> ReconcileAction? in
            guard let service = composeFile.services[serviceName] else { return nil }
            let observed = observedContainers.first { $0.serviceName == serviceName }
            let kind: ReconcileAction.Kind
            switch (observed, forceRecreate, noRecreate) {
            case (.none, _, _):
                kind = .noOp
            case (_, true, _):
                kind = .removeAndRecreate
            case (let .some(obs), _, true):
                // --no-recreate never replaces an existing container, but a stopped one
                // still needs to be started — Docker's reconcile is not a pure skip.
                kind = obs.state == .running ? .keep : .start
            case (let .some(obs), false, false):
                let expectedHash = ComposeService.hash(of: service)
                let expectedNetwork = networkForService(
                    service, composeFile: composeFile, projectName: projectName
                )
                if obs.configHash != expectedHash {
                    kind = .removeAndRecreate
                } else if obs.network != expectedNetwork {
                    // Also covers containers from a version that never recorded a network
                    // and never joined one: they need recreating to land on the project's.
                    kind = .removeAndRecreate
                } else if let digest = obs.imageDigest, digest != service.image {
                    kind = .removeAndRecreate
                } else if awaited.contains(serviceName) {
                    // Others wait for this one to complete, so it runs again, as Docker Compose
                    // runs an exited one again. Kept or started in place, it would leave them
                    // nothing to wait for, and they would start on what its last run left.
                    kind = .removeAndRecreate
                } else {
                    kind = obs.state == .running ? .keep : .start
                }
            }
            return ReconcileAction(serviceName: serviceName, kind: kind)
        }
    }
}

/// Snapshot of a project container as observed by `engine.list(all: true)`, scoped to
/// the per-service decision inputs (`configHash`, `imageDigest`, `serviceName`).
public struct ObservedContainer: Sendable, Equatable {
    public let name: String
    public let serviceName: String
    public let configHash: String?
    /// The network the container was created on, from its label — a change here is not
    /// visible in the service hash but still requires a new container.
    public let network: String?
    public let imageDigest: String?
    public let state: ContainerState

    public init(
        name: String,
        serviceName: String,
        configHash: String? = nil,
        network: String? = nil,
        imageDigest: String? = nil,
        state: ContainerState = .running
    ) {
        self.name = name
        self.serviceName = serviceName
        self.configHash = configHash
        self.network = network
        self.imageDigest = imageDigest
        self.state = state
    }
}

/// Per-service action emitted by `ComposeOrchestrator.reconcileDecision`.
public struct ReconcileAction: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Container is already running and its config hash matches: true no-op.
        case keep
        /// Config hash matches but the container isn't running: start it in place.
        case start
        case removeAndRecreate
        case noOp
    }

    public let serviceName: String
    public let kind: Kind

    public init(serviceName: String, kind: Kind) {
        self.serviceName = serviceName
        self.kind = kind
    }
}
