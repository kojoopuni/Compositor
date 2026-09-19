import AppKit
import Testing
@testable import Compositor

/// An assistant driving the app: every request is checked for its token, acts on the front tab's project, and is
/// one ordinary undo step.
@MainActor
@Suite(.serialized)
struct ControlTests {
    private func request(_ server: ControlServer, _ command: String, _ arguments: [String: Any] = [:], token: String = "secret") async throws -> [String: Any] {
        let line = try JSONSerialization.data(withJSONObject: ["token": token, "command": command, "arguments": arguments])
        return try #require(try JSONSerialization.jsonObject(with: await server.respond(to: line)) as? [String: Any])
    }
    private func png(_ width: Int, _ height: Int, red: CGFloat) throws -> String {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return (data as Data).base64EncodedString()
    }

    @Test func requestsNeedTheTokenAndActAsOrdinaryUndoSteps() async throws {
        let workspace = ProjectWorkspace()
        let server = ControlServer()
        server.prepareForTesting(workspace, token: "secret")
        let refused = try await request(server, "info", token: "guess")
        #expect(refused["ok"] as? Bool == false && (refused["error"] as? String)?.contains("token") == true)
        let empty = try #require(try await request(server, "info")["result"] as? [String: Any])
        #expect(empty["open"] as? Bool == false)

        let session = workspace.current.session
        session.createDocument(width: 40, height: 30, emptyLayer: true)
        let count = session.history.undoCount
        let added = try await request(server, "addLayer", ["png": try png(20, 10, red: 1), "name": "From the assistant", "x": 5, "y": 5, "opacity": 50])
        #expect(added["ok"] as? Bool == true, "\(added)")
        let layer = try #require(session.activeLayer)
        #expect(layer.name == "From the assistant" && layer.transform.origin == CGPoint(x: 5, y: 5) && abs(layer.opacity - 0.5) < 0.001)
        #expect(session.history.undoCount > count)

        let info = try #require(try await request(server, "info")["result"] as? [String: Any])
        #expect(info["width"] as? Int == 40 && (info["layers"] as? [[String: Any]])?.first?["name"] as? String == "From the assistant")
        #expect(info["unsavedChanges"] as? Bool == true)

        let view = try #require(try await request(server, "render", ["maxSize": 20])["result"] as? [String: Any])
        #expect(view["width"] as? Int == 20 && (view["png"] as? String)?.isEmpty == false)

        let before = session.history.undoCount
        let blurred = try await request(server, "filter", ["layer": "From the assistant", "filter": "Gaussian Blur", "settings": ["radius": 2, "keepEdges": true]])
        #expect(blurred["ok"] as? Bool == true, "\(blurred)")
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "Gaussian Blur")
        let undone = try #require(try await request(server, "undo")["result"] as? [String: Any])
        #expect(undone["undone"] as? String == "Gaussian Blur")

        let missing = try await request(server, "setLayer", ["layer": "Nope", "opacity": 10])
        #expect(missing["ok"] as? Bool == false && (missing["error"] as? String)?.contains("no layer") == true)
        let unknown = try await request(server, "formatDisk")
        #expect(unknown["ok"] as? Bool == false)
    }
}
