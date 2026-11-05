import Foundation
import MockerKit

enum ComposePSFormat {
    static let defaultTable = "table {{.Name}}\t{{.Image}}\t{{.Command}}\t{{.Service}}\t{{.RunningFor}}\t{{.Status}}\t{{.Ports}}"

    static let raw = """
        container_id: {{.ID}}
        image: {{.Image}}
        command: {{.Command}}
        created_at: {{.CreatedAt}}
        state: {{- pad .State 1 0}}
        status: {{- pad .Status 1 0}}
        names: {{.Names}}
        labels: {{- pad .Labels 1 0}}
        ports: {{- pad .Ports 1 0}}

        """

    static let headers: [String: String] = [
        "ID": "CONTAINER ID", "Name": "NAME", "Project": "PROJECT", "Service": "SERVICE", "Image": "IMAGE",
        "Command": "COMMAND", "CreatedAt": "CREATED AT", "RunningFor": "CREATED", "Ports": "PORTS",
        "State": "STATE", "Status": "STATUS", "Size": "SIZE", "Labels": "LABELS", "Engine": "ENGINE",
    ]

    static func render(
        format: String?,
        entries: [ComposePSEntry],
        trunc: Bool,
        now: Date = Date(),
        zone: @escaping (Date) -> (abbreviation: String, offset: Int) = localZone
    ) throws -> String {
        let source: String
        switch format ?? "" {
        case "", "table": source = defaultTable
        case "raw": source = raw
        default: source = format ?? ""
        }

        let isTable = source.hasPrefix("table")
        let template = try Template(templateString(source))
        let sorted = entries.sorted { $0.name < $1.name }

        var body = ""
        for entry in sorted {
            let row = RowContext(entry: entry, trunc: trunc, now: now, zone: zone)
            body += try template.execute(dot: .row(row)) + "\n"
        }

        guard isTable else { return body }

        let header = template.executeHeader()
        return TabWriter.format(header + "\n" + body)
    }

    /// Docker's `Format.templateString`.
    static func templateString(_ format: String) -> String {
        switch format {
        case "table": return ""
        case "json": return "{{json .}}"
        default: break
        }

        var out = format
        if out.hasPrefix("table") { out = String(out.dropFirst("table".count)) }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return out.replacingOccurrences(of: #"\t"#, with: "\t").replacingOccurrences(of: #"\n"#, with: "\n")
    }

    /// The C library reads the same tz database as Go: `+03` for Europe/Istanbul, where Foundation says `GMT+3`.
    static func localZone(_ date: Date) -> (abbreviation: String, offset: Int) {
        var time = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        localtime_r(&time, &parts)
        let abbreviation = parts.tm_zone.map { String(cString: $0) } ?? ""
        return (abbreviation, parts.tm_gmtoff)
    }
}

struct ComposePSEntry: Sendable {
    struct Publisher: Equatable, Sendable {
        var url: String
        var targetPort: Int
        var publishedPort: Int
        var proto: String
    }

    var id: String
    var name: String
    var names: [String]
    var image: String
    var command: String
    var project: String
    var service: String
    var created: Date
    var state: String
    var status: String
    var health = ""
    var exitCode = 0
    var publishers: [Publisher]
    var labels: [String: String]
    var mounts: [String] = []
    var networks: [String] = []
    var localVolumes = 0

    init(
        id: String, name: String, image: String, command: String, project: String, service: String,
        created: Date, state: String, status: String, publishers: [Publisher] = [], labels: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.names = [name]
        self.image = image
        self.command = command
        self.project = project
        self.service = service
        self.created = created
        self.state = state
        self.status = status
        self.publishers = publishers
        self.labels = labels
    }

    init(_ container: ContainerInfo) {
        let state = container.state == .stopped ? "exited" : container.state.rawValue
        let publishers = container.ports
            .map { Publisher(url: $0.hostIp ?? "0.0.0.0", targetPort: Int($0.containerPort), publishedPort: Int($0.hostPort), proto: $0.portProtocol.rawValue) }
            .enumerated()
            .sorted { ($0.element.targetPort, $0.offset) < ($1.element.targetPort, $1.offset) }
            .map(\.element)

        self.init(
            id: container.id,
            name: container.name,
            image: container.image,
            command: container.command,
            project: container.labels["com.mocker.compose.project"] ?? "",
            service: container.labels["com.mocker.compose.service"] ?? "",
            created: container.created,
            state: state,
            status: container.status,
            publishers: publishers,
            labels: container.labels
        )
    }
}

enum TemplateError: Error, LocalizedError, CustomStringConvertible {
    case unsupported(String)
    case execution(String)

    var description: String {
        switch self {
        case .unsupported(let action):
            return "template parsing error: unsupported template action \(action); compose ps --format supports "
                + "fields, .Label, pipelines and the functions json, lower, upper, title, pad, truncate, split and join"
        case .execution(let message):
            return "template parsing error: \(message)"
        }
    }

    var errorDescription: String? { description }
}

indirect enum TemplateValue {
    case string(String)
    case int(Int)
    case strings([String])
    case publishers([ComposePSEntry.Publisher])
    case row(RowContext)
    case header
    case missing

    /// What `{{...}}` prints: Go's `fmt.Print` of the value.
    func printed() throws -> String {
        switch self {
        case .string(let s): return s
        case .int(let n): return String(n)
        case .strings(let list): return "[" + list.joined(separator: " ") + "]"
        case .publishers(let list):
            return "[" + list.map { "\($0.targetPort)/\($0.proto) -> \(GoFormat.joinHostPort($0.url, String($0.publishedPort)))" }.joined(separator: " ") + "]"
        case .missing: return "<no value>"
        case .row, .header: throw TemplateError.unsupported("{{.}}")
        }
    }
}

/// A container's fields, as Docker Compose's `ContainerContext` methods compute them.
struct RowContext {
    let entry: ComposePSEntry
    let trunc: Bool
    let now: Date
    let zone: (Date) -> (abbreviation: String, offset: Int)

    static let fields = [
        "Command", "CreatedAt", "Engine", "ExitCode", "Health", "ID", "Image", "Labels", "LocalVolumes", "Mounts",
        "Name", "Names", "Networks", "Ports", "Project", "Publishers", "RunningFor", "Service", "Size", "State", "Status",
    ]

    func field(_ name: String) throws -> TemplateValue {
        switch name {
        case "ID": return .string(trunc ? GoFormat.truncateID(entry.id) : entry.id)
        case "Name": return .string(entry.name)
        case "Names": return .string(names())
        case "Service": return .string(entry.service)
        case "Project": return .string(entry.project)
        case "Image": return .string(entry.image)
        case "Command": return .string(GoFormat.quote(trunc ? GoFormat.ellipsis(entry.command, 20) : entry.command))
        case "CreatedAt": return .string(GoFormat.timeString(createdSecond, zone: zone(createdSecond)))
        case "RunningFor": return .string(GoFormat.humanDuration(now.timeIntervalSince(createdSecond)) + " ago")
        case "ExitCode": return .int(entry.exitCode)
        case "State": return .string(entry.state)
        case "Status": return .string(entry.status)
        case "Health": return .string(entry.health)
        case "Publishers": return .publishers(entry.publishers)
        case "Ports": return .string(GoFormat.displayablePorts(entry.publishers))
        case "Labels": return .string(entry.labels.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","))
        case "Engine": return .string(entry.labels["com.docker.compose.engine"] ?? "")
        case "Mounts": return .string(entry.mounts.map { trunc ? GoFormat.ellipsis($0, 15) : $0 }.joined(separator: ","))
        case "LocalVolumes": return .string(String(entry.localVolumes))
        case "Networks": return .string(entry.networks.joined(separator: ","))
        case "Size": return .string("0B")
        default: throw TemplateError.execution("can't evaluate field \(name) in type *formatter.ContainerContext")
        }
    }

    /// `{{json .}}`: every field, keys sorted, as Go's `json.Marshal` writes a map.
    func json() throws -> String {
        let pairs = try Self.fields.map { name in
            "\(GoFormat.jsonString(name, escapeHTML: true)):\(try GoFormat.json(field(name), escapeHTML: true))"
        }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    /// Docker's `time.Unix(created, 0)`: the creation time to the second.
    private var createdSecond: Date {
        Date(timeIntervalSince1970: entry.created.timeIntervalSince1970.rounded(.down))
    }

    private func names() -> String {
        var names = entry.names.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        if trunc, let first = names.first(where: { !$0.contains("/") }) {
            names = [first]
        }
        return names.joined(separator: ",")
    }
}

struct Template {
    enum Node {
        case text(String)
        case action(pipeline: [[Token]], source: String)
    }

    enum Token: Equatable {
        case dot
        case field(String)
        case identifier(String)
        case string(String)
        case number(Int)
    }

    let nodes: [Node]

    init(_ source: String) throws {
        nodes = try Self.parse(source)
    }

    func execute(dot: TemplateValue) throws -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let text): out += text
            case .action(let pipeline, _): out += try evaluate(pipeline, dot: dot, header: false).printed()
            }
        }
        return out
    }

    /// As in Docker, an action that fails on the header map ends the header instead of failing the command.
    func executeHeader() -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let text): out += text
            case .action(let pipeline, _):
                guard let value = try? evaluate(pipeline, dot: .header, header: true).printed() else { return out }
                out += value
            }
        }
        return out
    }

    private static func parse(_ source: String) throws -> [Node] {
        var nodes: [Node] = []
        var rest = Substring(source)

        while let open = rest.range(of: "{{") {
            var text = String(rest[..<open.lowerBound])
            var inner = rest[open.upperBound...]
            guard let close = inner.range(of: "}}") else {
                throw TemplateError.execution("template: :1: unclosed action")
            }
            var action = String(inner[..<close.lowerBound])
            inner = inner[close.upperBound...]

            if action.hasPrefix("- ") || action.hasPrefix("-\t") || action.hasPrefix("-\n") || action == "-" {
                action.removeFirst()
                text = String(text.reversed().drop(while: \.isWhitespace).reversed())
            }
            var trimAfter = false
            if action.hasSuffix(" -") || action.hasSuffix("\t-") || action.hasSuffix("\n-") {
                action.removeLast()
                trimAfter = true
            }

            if !text.isEmpty { nodes.append(.text(text)) }

            let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
            if !(trimmed.hasPrefix("/*") && trimmed.hasSuffix("*/")) {
                nodes.append(.action(pipeline: try pipeline(trimmed), source: "{{\(action)}}"))
            }

            rest = trimAfter ? inner.drop(while: \.isWhitespace) : inner
        }

        if !rest.isEmpty { nodes.append(.text(String(rest))) }
        return nodes
    }

    private static let keywords: Set<String> = ["if", "else", "end", "range", "with", "define", "template", "block", "break", "continue", "nil"]

    private static func pipeline(_ action: String) throws -> [[Token]] {
        var commands: [[Token]] = [[]]
        var chars = Substring(action)

        while let c = chars.first {
            if c.isWhitespace {
                chars.removeFirst()
            } else if c == "|" {
                chars.removeFirst()
                commands.append([])
            } else if c == "\"" {
                let (literal, rest) = try stringLiteral(chars)
                commands[commands.count - 1].append(.string(literal))
                chars = rest
            } else if c == "." {
                chars.removeFirst()
                let name = chars.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
                chars = chars.dropFirst(name.count)
                guard !name.isEmpty || chars.first.map({ $0.isWhitespace || $0 == "|" }) ?? true else {
                    throw TemplateError.unsupported("{{\(action)}}")
                }
                commands[commands.count - 1].append(name.isEmpty ? .dot : .field(String(name)))
            } else if c.isNumber || c == "-" {
                let literal = chars.prefix(while: { $0.isNumber || $0 == "-" })
                chars = chars.dropFirst(literal.count)
                guard let number = Int(literal) else { throw TemplateError.unsupported("{{\(action)}}") }
                commands[commands.count - 1].append(.number(number))
            } else if c.isLetter {
                let name = String(chars.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                chars = chars.dropFirst(name.count)
                guard !keywords.contains(name) else { throw TemplateError.unsupported("{{\(action)}}") }
                commands[commands.count - 1].append(.identifier(name))
            } else {
                throw TemplateError.unsupported("{{\(action)}}")
            }
        }

        guard !commands.contains(where: \.isEmpty) else { throw TemplateError.unsupported("{{\(action)}}") }
        return commands
    }

    private static func stringLiteral(_ chars: Substring) throws -> (String, Substring) {
        var rest = chars.dropFirst()
        var out = ""
        while let c = rest.first {
            rest.removeFirst()
            switch c {
            case "\"": return (out, rest)
            case "\\":
                guard let escaped = rest.first else { break }
                rest.removeFirst()
                switch escaped {
                case "n": out += "\n"
                case "t": out += "\t"
                case "r": out += "\r"
                case "\\": out += "\\"
                case "\"": out += "\""
                default: out += "\\" + String(escaped)
                }
            default: out.append(c)
            }
        }
        throw TemplateError.execution("template: :1: unterminated quoted string")
    }

    private func evaluate(_ pipeline: [[Token]], dot: TemplateValue, header: Bool) throws -> TemplateValue {
        var result: TemplateValue?
        for command in pipeline {
            result = try evaluate(command, dot: dot, header: header, piped: result)
        }
        return result ?? .missing
    }

    private func evaluate(_ command: [Token], dot: TemplateValue, header: Bool, piped: TemplateValue?) throws -> TemplateValue {
        let head = command[0]
        var args = try command.dropFirst().map { try operand($0, dot: dot) }
        if let piped { args.append(piped) }

        switch head {
        case .dot, .string, .number:
            guard args.isEmpty else { throw TemplateError.execution("can't give argument to non-function") }
            return try operand(head, dot: dot)
        case .field(let name):
            if name == "Label" {
                guard args.count == 1, case .string(let key) = args[0] else {
                    throw TemplateError.execution("wrong number of args for Label: want 1 got \(args.count)")
                }
                return .string(header ? Self.headerLabel(key) : Self.row(dot)?.entry.labels[key] ?? "")
            }
            guard args.isEmpty else { throw TemplateError.execution("\(name) has arguments but cannot be invoked as function") }
            return try operand(head, dot: dot)
        case .identifier(let name):
            return try call(name, args, header: header)
        }
    }

    private func operand(_ token: Token, dot: TemplateValue) throws -> TemplateValue {
        switch token {
        case .dot: return dot
        case .string(let s): return .string(s)
        case .number(let n): return .int(n)
        case .identifier(let name): throw TemplateError.unsupported("function \(name) as an argument")
        case .field(let name):
            switch dot {
            case .row(let row): return try row.field(name)
            case .header: return ComposePSFormat.headers[name].map(TemplateValue.string) ?? .missing
            default: throw TemplateError.execution("can't evaluate field \(name)")
            }
        }
    }

    private func call(_ name: String, _ args: [TemplateValue], header: Bool) throws -> TemplateValue {
        func string(_ value: TemplateValue) throws -> String {
            if case .string(let s) = value { return s }
            throw TemplateError.execution("wrong type for value; expected string")
        }
        func int(_ value: TemplateValue) throws -> Int {
            if case .int(let n) = value { return n }
            throw TemplateError.execution("wrong type for value; expected int")
        }
        func arity(_ count: Int) throws {
            guard args.count == count else { throw TemplateError.execution("wrong number of args for \(name): want \(count) got \(args.count)") }
        }

        // Docker's header functions return the column's header as it is, except `pad`.
        if header, ["json", "lower", "upper", "title", "truncate", "split", "join"].contains(name) {
            try arity(["truncate", "split", "join"].contains(name) ? 2 : 1)
            return .string(try string(args[0]))
        }

        switch name {
        case "json":
            try arity(1)
            if case .row(let row) = args[0] { return .string(try row.json()) }
            return .string(try GoFormat.json(args[0], escapeHTML: false))
        case "lower":
            try arity(1)
            return .string(try string(args[0]).lowercased())
        case "upper":
            try arity(1)
            return .string(try string(args[0]).uppercased())
        case "title":
            try arity(1)
            return .string(GoFormat.title(try string(args[0])))
        case "pad":
            try arity(3)
            let s = try string(args[0])
            return .string(s.isEmpty ? s : String(repeating: " ", count: try int(args[1])) + s + String(repeating: " ", count: try int(args[2])))
        case "truncate":
            try arity(2)
            let s = try string(args[0])
            let length = try int(args[1])
            let bytes = Array(s.utf8)
            return .string(bytes.count < length ? s : String(decoding: bytes.prefix(length), as: UTF8.self))
        case "split":
            try arity(2)
            let s = try string(args[0])
            let separator = try string(args[1])
            return .strings(separator.isEmpty ? s.map(String.init) : s.components(separatedBy: separator))
        case "join":
            try arity(2)
            let separator = try string(args[1])
            switch args[0] {
            case .strings(let list): return .string(list.joined(separator: separator))
            case .publishers(let list): return .string(try list.map { try TemplateValue.publishers([$0]).printed().dropFirst().dropLast() }.joined(separator: separator))
            default: throw TemplateError.execution("error calling join: expected slice, got string")
            }
        default:
            throw TemplateError.unsupported("function \(name)")
        }
    }

    private static func row(_ value: TemplateValue) -> RowContext? {
        if case .row(let row) = value { return row }
        return nil
    }

    /// Docker's `SubHeaderContext.Label`.
    private static func headerLabel(_ key: String) -> String {
        String(key.split(separator: ".", omittingEmptySubsequences: false).last ?? "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

enum GoFormat {
    /// go-units' `HumanDuration`.
    static func humanDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        let minutes = Int(interval / 60)
        let hours = Int(interval / 3600 + 0.5)

        if seconds < 1 { return "Less than a second" }
        if seconds == 1 { return "1 second" }
        if seconds < 60 { return "\(seconds) seconds" }
        if minutes == 1 { return "About a minute" }
        if minutes < 60 { return "\(minutes) minutes" }
        if hours == 1 { return "About an hour" }
        if hours < 48 { return "\(hours) hours" }
        if hours < 24 * 7 * 2 { return "\(hours / 24) days" }
        if hours < 24 * 30 * 2 { return "\(hours / 24 / 7) weeks" }
        if hours < 24 * 365 * 2 { return "\(hours / 24 / 30) months" }
        return "\(Int(interval / 3600) / 24 / 365) years"
    }

    /// Go's `time.Time.String` for a whole second: `2006-01-02 15:04:05 -0700 MST`.
    static func timeString(_ date: Date, zone: (abbreviation: String, offset: Int)) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: zone.offset) ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        let sign = zone.offset < 0 ? "-" : "+"
        let offset = abs(zone.offset) / 60
        let numeric = String(format: "%@%02d%02d", sign, offset / 60, offset % 60)
        let day = String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "\(day) \(numeric) \(zone.abbreviation.isEmpty ? numeric : zone.abbreviation)"
    }

    /// Docker's `stringid.TruncateID`.
    static func truncateID(_ id: String) -> String {
        var id = Substring(id)
        if let colon = id.firstIndex(of: ":") { id = id[id.index(after: colon)...] }
        return String(id.prefix(12))
    }

    /// Docker's `formatter.Ellipsis`, counting one column per character.
    static func ellipsis(_ s: String, _ width: Int) -> String {
        let scalars = Array(s.unicodeScalars)
        if width <= 0 { return "" }
        if width == 1 { return scalars.first.map { String($0) } ?? "" }
        if scalars.count <= width { return s }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars.prefix(width - 1))
        return String(out) + "…"
    }

    /// Go's `strconv.Quote`.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\u{07}": out += "\\a"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{0B}": out += "\\v"
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default:
                if isPrint(scalar) {
                    out.unicodeScalars.append(scalar)
                } else if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else if scalar.value < 0x10000 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out += String(format: "\\U%08x", scalar.value)
                }
            }
        }
        return out + "\""
    }

    private static func isPrint(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }

    /// Go's `strings.Title` for the ASCII text these fields hold.
    static func title(_ s: String) -> String {
        var out = ""
        var previous: Character = " "
        for c in s {
            let separator = !(previous.isLetter || previous.isNumber || previous == "_")
            out += separator ? c.uppercased() : String(c)
            previous = c
        }
        return out
    }

    /// Go's `net.JoinHostPort`.
    static func joinHostPort(_ host: String, _ port: String) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Docker's `formatter.DisplayablePorts`, fed from Compose's publishers.
    static func displayablePorts(_ publishers: [ComposePSEntry.Publisher]) -> String {
        struct Port {
            var ip: IPAddress?
            var privatePort: Int
            var publicPort: Int
            var proto: String
        }

        let ports = publishers
            .map { Port(ip: $0.url.isEmpty ? nil : IPAddress($0.url), privatePort: $0.targetPort, publicPort: $0.publishedPort, proto: $0.proto) }
            .sorted { a, b in
                if a.privatePort != b.privatePort { return a.privatePort < b.privatePort }
                if a.ip != b.ip { return IPAddress.less(a.ip, b.ip) }
                if a.publicPort != b.publicPort { return a.publicPort < b.publicPort }
                return a.proto < b.proto
            }

        var groups: [String: (first: Int, last: Int)] = [:]
        var keys: [String] = []
        var result: [String] = []
        var hostMappings: [String] = []

        for port in ports {
            var key = port.proto
            if let ip = port.ip {
                if port.publicPort != port.privatePort {
                    hostMappings.append("\(joinHostPort(ip.text, String(port.publicPort)))->\(port.privatePort)/\(port.proto)")
                    continue
                }
                key = ip.text + "/" + port.proto
            }

            guard let group = groups[key] else {
                groups[key] = (port.privatePort, port.privatePort)
                keys.append(key)
                continue
            }
            if port.privatePort == group.last + 1 {
                groups[key] = (group.first, port.privatePort)
                continue
            }
            result.append(formGroup(key, group.first, group.last))
            groups[key] = (port.privatePort, port.privatePort)
        }

        for key in keys {
            if let group = groups[key] { result.append(formGroup(key, group.first, group.last)) }
        }
        return (result + hostMappings).joined(separator: ", ")
    }

    private static func formGroup(_ key: String, _ first: Int, _ last: Int) -> String {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let (ip, proto) = parts.count > 1 ? (parts[0], parts[1]) : ("", parts[0])
        var group = first == last ? String(first) : "\(first)-\(last)"
        if !ip.isEmpty { group = "\(joinHostPort(ip, group))->\(group)" }
        return group + "/" + proto
    }

    /// A value as Go's `encoding/json` writes it.
    static func json(_ value: TemplateValue, escapeHTML: Bool) throws -> String {
        switch value {
        case .string(let s): return jsonString(s, escapeHTML: escapeHTML)
        case .int(let n): return String(n)
        case .strings(let list): return "[" + list.map { jsonString($0, escapeHTML: escapeHTML) }.joined(separator: ",") + "]"
        case .publishers(let list):
            let objects = list.map { p in
                "{\"URL\":\(jsonString(p.url, escapeHTML: escapeHTML)),\"TargetPort\":\(p.targetPort),\"PublishedPort\":\(p.publishedPort),\"Protocol\":\(jsonString(p.proto, escapeHTML: escapeHTML))}"
            }
            return "[" + objects.joined(separator: ",") + "]"
        case .row(let row): return try row.json()
        case .missing: return "null"
        case .header: throw TemplateError.execution("wrong type for value; expected string")
        }
    }

    static func jsonString(_ s: String, escapeHTML: Bool) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "<", ">", "&" where escapeHTML: out += String(format: "\\u%04x", scalar.value)
            case "\u{2028}", "\u{2029}": out += String(format: "\\u%04x", scalar.value)
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// An IP address, ordered as Go's `netip.Addr.Compare` orders them: IPv4 before IPv6.
struct IPAddress: Equatable {
    let bytes: [UInt8]
    let text: String

    init?(_ text: String) {
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
        } else {
            return nil
        }
        self.text = text
    }

    static func less(_ a: IPAddress?, _ b: IPAddress?) -> Bool {
        guard let a else { return b != nil }
        guard let b else { return false }
        if a.bytes.count != b.bytes.count { return a.bytes.count < b.bytes.count }
        return a.bytes.lexicographicallyPrecedes(b.bytes)
    }
}

/// Go's `text/tabwriter` with Docker's settings. The text after a line's last tab isn't padded.
enum TabWriter {
    static let minWidth = 10
    static let padding = 3

    static func format(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        let endsWithNewline = lines.last == [""]
        if endsWithNewline { lines.removeLast() }

        var out = ""
        var widths: [Int] = []
        format(lines, 0, lines.count, &widths, &out)
        return endsWithNewline ? out : String(out.dropLast())
    }

    /// Go's `Writer.format`: a column block is the run of lines that have a cell in the
    /// column, and its width is the widest cell plus padding, at least `minWidth`.
    private static func format(_ lines: [[String]], _ start: Int, _ end: Int, _ widths: inout [Int], _ out: inout String) {
        let column = widths.count
        var line0 = start
        var this = start

        while this < end {
            guard column < lines[this].count - 1 else {
                this += 1
                continue
            }

            write(lines, line0, this, widths, &out)
            line0 = this

            var width = minWidth
            while this < end, column < lines[this].count - 1 {
                width = max(width, lines[this][column].unicodeScalars.count + padding)
                this += 1
            }

            widths.append(width)
            format(lines, line0, this, &widths, &out)
            widths.removeLast()
            line0 = this
        }

        write(lines, line0, end, widths, &out)
    }

    private static func write(_ lines: [[String]], _ start: Int, _ end: Int, _ widths: [Int], _ out: inout String) {
        guard start < end else { return }
        for line in lines[start..<end] {
            for (j, cell) in line.enumerated() {
                out += cell
                if j < widths.count {
                    out += String(repeating: " ", count: max(0, widths[j] - cell.unicodeScalars.count))
                }
            }
            out += "\n"
        }
    }
}
