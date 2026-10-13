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
                if let existing = observed.first(where: { $0.serviceName == action.serviceName }) {
                    if let live = (try? await engine.list(all: true))?.first(where: { $0.name == existing.name }),
                       live.state.isActive {
                        _ = try? await engine.stop(live.id)
                        events.append(.containerStopped(live.name))
                    }
                    _ = try? await engine.remove(existing.name, force: true)
                    events.append(.containerRemoved(existing.name))
                }
            case .noOp:
                break
            }
        }

        // Start services in dependency order
        let order = composeFile.serviceOrder()
        var startedContainers: [(serviceName: String, info: ContainerInfo)] = []

        let awaited = Self.servicesAwaitedForCompletion(composeFile)
        var completions: [String: Task<Int32, Error>] = [:]

        for serviceName in order where !skipSet.contains(serviceName) {
            guard let service = composeFile.services[serviceName] else { continue }
            for dependency in service.dependsOn where service.dependsOnConditions[dependency] == "service_healthy" {
                try await waitUntilHealthy(dependency, composeFile: composeFile)
            }
            for dependency in service.dependsOn where service.dependsOnConditions[dependency] == "service_completed_successfully" {
                guard let exitCode = try await completions[dependency]?.value, exitCode != 0 else { continue }
                throw MockerError.operationFailed("service \"\(dependency)\" didn't complete successfully: exit \(exitCode)")
            }

            // A service others wait on to complete runs in the background until it
            // exits, so its exit code is known when they need it.
            if awaited.contains(serviceName) {
                let config = try await containerConfig(for: service, composeFile: composeFile, detach: detach, forceBuild: build, noBuild: noBuild)
                // Like any service, it needs the names of the services started before it.
                let lines = startedContainers
                    .filter { !$0.info.networkAddress.isEmpty }
                    .map { "\($0.info.networkAddress) \($0.serviceName)\n" }
                    .joined()
                completions[serviceName] = Task {
                    try await engine.runToCompletion(config) { started in
                        if !lines.isEmpty { await self.appendHosts(lines, to: started.id) }
                    }
                }
                events.append(.containerStarted("\(projectName)-\(service.name)-1"))
                continue
            }

            let info = try await startService(
                service, composeFile: composeFile,
                detach: detach, forceBuild: build, noBuild: noBuild
            )
            let containerName = "\(projectName)-\(service.name)-1"
            // Give a starting container the names of the services started before it,
            // which include its dependencies, so it can reach them at startup.
            if let lines = Self.hostnameLines(for: info, after: startedContainers) {
                await appendHosts(lines, to: info.id)
            }
            startedContainers.append((serviceName: serviceName, info: info))
            events.append(.containerStarted(containerName))
        }

        // Then give each container the names of the services started after it.
        for write in Self.remainingHostnameWrites(startedContainers) {
            await appendHosts(write.lines, to: write.containerID)
        }

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

        for container in containers {
            if container.state.isActive {
                _ = try await engine.stop(container.id, timeout: timeout)
                events.append(.containerStopped(container.name))
            }
            _ = try await engine.remove(container.id)
            events.append(.containerRemoved(container.name))
        }

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

        return events
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

    /// Whether a container belongs to this project, by the label written when compose
    /// created it (since the first release, so every project container carries it).
    ///
    /// Deliberately no name-prefix fallback: `app-prod-web-1` is indistinguishable from
    /// project `app`'s service `prod-web` by name alone, and `down`/`restart` remove what
    /// they select — a guess there deletes another project's containers.
    public nonisolated static func belongs(_ container: ContainerInfo, toProject projectName: String) -> Bool {
        container.labels["com.mocker.compose.project"] == projectName
    }

    /// Restart a specific service or all services.
    public func restart(composeFile: ComposeFile, service: String? = nil) async throws -> [ComposeEvent] {
        var events: [ComposeEvent] = []
        let containers = try await ps()
        let targets: [ContainerInfo]

        if let service {
            // Exact service match: a `hasPrefix` here also restarted `web2`/`webhook`
            // when asked for `web`, and restart stops and REMOVES what it selects.
            targets = containers.filter { Self.belongs($0, to: service, projectName: projectName) }
        } else {
            targets = containers
        }

        // Stop and remove targets
        for container in targets {
            if container.state.isActive {
                _ = try await engine.stop(container.id)
                events.append(.containerStopped(container.name))
            }
            _ = try await engine.remove(container.id)
            events.append(.containerRemoved(container.name))
        }

        // Recreate services
        if let service, let svc = composeFile.services[service] {
            _ = try await startService(svc, composeFile: composeFile, detach: true)
            events.append(.containerStarted("\(projectName)-\(service)-1"))
        } else {
            for serviceName in composeFile.serviceOrder() {
                guard let svc = composeFile.services[serviceName] else { continue }
                _ = try await startService(svc, composeFile: composeFile, detach: true)
                events.append(.containerStarted("\(projectName)-\(serviceName)-1"))
            }
        }

        // Restarted containers have new IPs, so rewrite every running container's
        // hostnames, not just the restarted ones'.
        let running = try await ps().filter { $0.state.isActive && !$0.networkAddress.isEmpty }
        let serviceNames = Set(composeFile.services.keys)
        for container in running {
            let lines = running
                .filter { $0.id != container.id }
                .compactMap { other in other.labels["com.mocker.compose.service"].map { "\(other.networkAddress) \($0)\n" } }
                .joined()
            guard let current = await readHosts(of: container.id) else { continue }
            await writeHosts(Self.hostsReplacing(serviceNames, in: current, with: lines), to: container.id)
        }

        return events
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

    private func waitUntilReady(_ composeFile: ComposeFile, completions: [String: Task<Int32, Error>]) async throws {
        let awaited = Self.servicesAwaitedForCompletion(composeFile)
        for serviceName in composeFile.serviceOrder() {
            guard let service = composeFile.services[serviceName] else { continue }
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
    }

    /// Services another service waits on with `condition: service_completed_successfully`.
    nonisolated static func servicesAwaitedForCompletion(_ composeFile: ComposeFile) -> Set<String> {
        Set(composeFile.services.values.flatMap { service in
            service.dependsOn.filter { service.dependsOnConditions[$0] == "service_completed_successfully" }
        })
    }

    /// /etc/hosts content with the lines for `serviceNames` replaced by `lines`.
    nonisolated static func hostsReplacing(_ serviceNames: Set<String>, in current: String, with lines: String) -> String {
        let kept = current
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let names = line.split(whereSeparator: \.isWhitespace).dropFirst()
                return !names.contains { serviceNames.contains(String($0)) }
            }
            .joined(separator: "\n")
        let base = kept.hasSuffix("\n") || kept.isEmpty ? kept : kept + "\n"
        return base + lines
    }

    private func readHosts(of containerID: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLIResolver.resolve())
        process.arguments = ["exec", containerID, "cat", "/etc/hosts"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        } catch {
            return nil
        }
    }

    private func writeHosts(_ content: String, to containerID: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLIResolver.resolve())
        // As root, like the append: /etc/hosts is root-owned.
        process.arguments = ["exec", "-i", "--user", "0", containerID, "tee", "--", "/etc/hosts"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(content.utf8))
            input.fileHandleForWriting.closeFile()
            process.waitUntilExit()
        } catch {
            // Silently ignore if container doesn't support exec (e.g. no tee)
        }
    }

    // MARK: - Private

    /// Block until `serviceName`'s health check passes, as `depends_on`
    /// `condition: service_healthy` asks. Errors match Docker Compose's.
    private func waitUntilHealthy(_ serviceName: String, composeFile: ComposeFile) async throws {
        let containerName = "\(projectName)-\(serviceName)-1"
        guard let check = composeFile.services[serviceName]?.healthcheck, !check.isDisabled else {
            throw MockerError.operationFailed("dependency failed to start: container \(containerName) has no healthcheck configured")
        }

        let healthy = try await HealthCheck.waitUntilHealthy(
            check,
            probe: { await self.runHealthCheck(check, in: containerName) },
            sleep: { try await Task.sleep(for: .seconds($0)) }
        )
        guard healthy else {
            throw MockerError.operationFailed("dependency failed to start: container \(containerName) is unhealthy")
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

    /// Inject other services' IPs into /etc/hosts of each running container.
    /// This enables service-name DNS resolution (e.g. "db:5432") in compose projects.
    private func injectServiceHostnames(_ containers: [(serviceName: String, info: ContainerInfo)]) async {
        // Only containers with a known IP can participate
        let withIP = containers.filter { !$0.info.networkAddress.isEmpty }
        guard withIP.count > 1 else { return }

        for target in withIP {
            // Build /etc/hosts entries for all *other* services
            let otherServices = withIP.filter { $0.serviceName != target.serviceName }
            guard !otherServices.isEmpty else { continue }

            // Build args array for safe execution — no shell interpolation
            // Each entry is passed as a separate argument to avoid injection
            var hostsContent = ""
            for svc in otherServices {
                hostsContent += "\(svc.info.networkAddress) \(svc.serviceName)\n"
            }

            await appendHosts(hostsContent, to: target.info.id)
        }
    }

    /// /etc/hosts lines for a container that just started: the services started
    /// before it. Nil when there is nothing to write.
    nonisolated static func hostnameLines(
        for new: ContainerInfo,
        after earlier: [(serviceName: String, info: ContainerInfo)]
    ) -> String? {
        let others = earlier.filter { !$0.info.networkAddress.isEmpty }
        guard !new.networkAddress.isEmpty, !others.isEmpty else { return nil }
        return others.map { "\($0.info.networkAddress) \($0.serviceName)\n" }.joined()
    }

    /// Once every container has started, the /etc/hosts lines each one still
    /// needs: the services started after it.
    nonisolated static func remainingHostnameWrites(
        _ started: [(serviceName: String, info: ContainerInfo)]
    ) -> [(containerID: String, lines: String)] {
        started.indices.compactMap { index in
            let container = started[index].info
            guard let lines = hostnameLines(for: container, after: Array(started[(index + 1)...])) else {
                return nil
            }
            return (containerID: container.id, lines: lines)
        }
    }

    /// Append `lines` to a container's /etc/hosts.
    private func appendHosts(_ lines: String, to containerID: String) async {
        // Use tee -a to append to /etc/hosts without shell interpolation
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLIResolver.resolve())
        process.arguments = Self.hostsAppendArguments(containerID: containerID)
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(lines.utf8))
            inputPipe.fileHandleForWriting.closeFile()
            // Async-safe: use terminationHandler instead of blocking waitUntilExit
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        } catch {
            // Silently ignore if container doesn't support exec (e.g. no tee)
        }
    }

    /// `container exec` arguments that append stdin to a container's /etc/hosts.
    /// Runs as root: /etc/hosts is root-owned, so the append fails in images that
    /// run as a non-root user.
    nonisolated static func hostsAppendArguments(containerID: String) -> [String] {
        ["exec", "-i", "--user", "0", containerID, "tee", "-a", "--", "/etc/hosts"]
    }

    private func startService(
        _ service: ComposeService,
        composeFile: ComposeFile = ComposeFile(),
        detach: Bool,
        forceBuild: Bool = false,
        noBuild: Bool = false
    ) async throws -> ContainerInfo {
        try await engine.run(try await containerConfig(
            for: service, composeFile: composeFile, detach: detach, forceBuild: forceBuild, noBuild: noBuild
        ))
    }

    /// Pull or build the service's image and return the config its container runs with.
    private func containerConfig(
        for service: ComposeService,
        composeFile: ComposeFile = ComposeFile(),
        detach: Bool,
        forceBuild: Bool = false,
        noBuild: Bool = false
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
                    tag: tag,
                    context: absContext,
                    dockerfile: dockerfilePath,
                    buildArgs: build.argList,
                    target: build.target
                )
            }
        case .none:
            break
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
        )

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
            entrypoint: exec.entrypoint,
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
        composeFile.serviceOrder().compactMap { serviceName -> ReconcileAction? in
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
