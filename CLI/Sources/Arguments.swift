import Foundation

/// A command's arguments split into positionals and `--name value` options. A `--name` with nothing after it, or
/// followed by another option, is a flag.
struct Arguments {
    private(set) var positionals: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let word = raw[index]
            if word.hasPrefix("--"), word.count > 2 {
                let name = String(word.dropFirst(2))
                // A negative number is a value, not the next option.
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") || Double(raw[index + 1]) != nil {
                    options[name] = raw[index + 1]
                    index += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positionals.append(word)
            }
            index += 1
        }
    }

    func string(_ name: String) -> String? { options[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) }
    func has(_ name: String) -> Bool { options[name] != nil || flags.contains(name) }

    func number(_ name: String) throws -> Double? {
        guard let text = options[name] else { return nil }
        guard let value = Double(text), value.isFinite else { throw CommandError("--\(name) needs a number, not '\(text)'") }
        return value
    }
    func integer(_ name: String) throws -> Int? {
        guard let value = try number(name) else { return nil }
        guard value == value.rounded(), abs(value) < 1e9 else { throw CommandError("--\(name) needs a whole number") }
        return Int(value)
    }
    func boolean(_ name: String) throws -> Bool? {
        guard let text = options[name]?.lowercased() else { return nil }
        if ["true", "yes", "on", "1"].contains(text) { return true }
        if ["false", "no", "off", "0"].contains(text) { return false }
        throw CommandError("--\(name) needs true or false, not '\(text)'")
    }
    /// The positional at `index`, or an error naming what was expected there.
    func required(_ index: Int, _ what: String) throws -> String {
        guard positionals.indices.contains(index) else { throw CommandError("missing \(what)") }
        return positionals[index]
    }
    func url(_ index: Int, _ what: String) throws -> URL {
        URL(fileURLWithPath: (try required(index, what) as NSString).expandingTildeInPath)
    }
    func url(option name: String) -> URL? {
        options[name].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
}
