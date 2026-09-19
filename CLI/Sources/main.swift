import Foundation

// Top-level code runs on the main actor, as the engine's session types expect, and may await the engine's actors.
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    let output = try await Commands.run(arguments)
    print(output)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
