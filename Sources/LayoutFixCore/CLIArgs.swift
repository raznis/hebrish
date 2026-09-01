import Foundation

/// Tiny `--flag value` parser, so the package stays dependency-free.
public struct CLIArgs {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    public init(_ argv: [String] = Array(CommandLine.arguments.dropFirst())) {
        var i = 0
        while i < argv.count {
            let token = argv[i]
            guard token.hasPrefix("--") else { i += 1; continue }
            let name = String(token.dropFirst(2))
            if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                values[name] = argv[i + 1]
                i += 2
            } else {
                flags.insert(name)
                i += 1
            }
        }
    }

    public func string(_ name: String) -> String? { values[name] }
    public func flag(_ name: String) -> Bool { flags.contains(name) }

    public func double(_ name: String) -> Double? { values[name].flatMap(Double.init) }
    public func int(_ name: String) -> Int? { values[name].flatMap(Int.init) }

    public func require(_ name: String, usage: String) -> String {
        guard let v = values[name] else {
            FileHandle.standardError.write("error: missing --\(name)\n\(usage)\n".data(using: .utf8)!)
            exit(2)
        }
        return v
    }
}
