import Foundation

/// Actions: a saved list of steps, replayed on any project — this tool's commands are already the recipe format, so
/// an action is a JSON file of them with a placeholder where the project goes.
///
///     { "name": "Game-ready texture",
///       "steps": [ ["make-tileable", "{project}", "{layer}", "--band", "14"],
///                  ["filter", "{project}", "{layer}", "Unsharp Mask", "--amount", "60"],
///                  ["export", "{project}", "--out", "{folder}/{name}_albedo.png"] ] }
///
/// {project} is the project's path, {folder} the folder it is in, {name} its name without the extension, and any
/// other {word} comes from --set word=value on the command line.
extension Commands {
    /// compositor-cli run-action <action.json> <project.comp> [--set key=value …] [--dry-run]
    static func runAction(_ raw: [String]) async throws -> String {
        // --set may repeat, which the ordinary option parser does not allow for.
        var values: [String: String] = [:], rest: [String] = []
        var index = 0
        while index < raw.count {
            if raw[index] == "--set", index + 1 < raw.count {
                let pair = raw[index + 1].split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { throw CommandError("--set takes key=value") }
                values[pair[0]] = pair[1]; index += 2
            } else { rest.append(raw[index]); index += 1 }
        }
        let arguments = Arguments(rest)
        let file = try arguments.url(0, "the action file"), project = try arguments.url(1, "the project")
        struct Action: Decodable { let name: String?; let steps: [[String]] }
        let action: Action
        do { action = try JSONDecoder().decode(Action.self, from: try Data(contentsOf: file)) }
        catch { throw CommandError("\(file.lastPathComponent) is not an action: it needs a \"steps\" list of command lists (\(error.localizedDescription))") }
        values["project"] = project.path
        values["folder"] = project.deletingLastPathComponent().path
        values["name"] = project.deletingPathExtension().lastPathComponent

        var done: [[String: Any]] = []
        for (number, step) in action.steps.enumerated() {
            guard let command = step.first, command != "run-action" else { throw CommandError("step \(number + 1) is empty, or is another run-action") }
            let filled = try step.map { word -> String in
                var result = word
                while let open = result.range(of: "{"), let close = result.range(of: "}", range: open.upperBound..<result.endIndex) {
                    let key = String(result[open.upperBound..<close.lowerBound])
                    guard let value = values[key] else { throw CommandError("step \(number + 1) needs {\(key)}; pass --set \(key)=…") }
                    result.replaceSubrange(open.lowerBound..<close.upperBound, with: value)
                }
                return result
            }
            if arguments.flag("dry-run") { done.append(["step": number + 1, "would run": filled]); continue }
            do {
                let output = try await run(filled)
                let parsed = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) ?? output
                done.append(["step": number + 1, "command": filled[0], "result": parsed])
            } catch {
                // Steps before this one have been saved; say exactly where it stopped.
                throw CommandError("step \(number + 1) (\(filled.joined(separator: " "))) failed: \(error.localizedDescription). Steps 1–\(number) were applied.")
            }
        }
        return try json(["action": action.name ?? file.deletingPathExtension().lastPathComponent, "steps": done])
    }
}
