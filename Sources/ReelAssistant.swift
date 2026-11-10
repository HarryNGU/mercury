// Claude inside the reel editor: it reads the transcript and the current edit, and answers with changes
// ("cut the part about pricing", "add a title") that the editor applies and you can undo.

import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Claude

enum ReelAssistant {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let tool: [String: Any] = [
        "name": "update_edit",
        "description": "Apply the edit. Leave out any field that should stay as it is.",
        "input_schema": [
            "type": "object",
            "properties": [
                "reply": ["type": "string", "description": "One or two short sentences to the user saying what you changed, in plain words."],
                "max_pause": ["type": "number", "description": "Seconds of silence left between phrases (0.1 very tight, 0.25 sharp, 0.5 relaxed). 0 keeps every pause uncut."],
                "removed": ["type": "array", "description": "The full list of parts of the ORIGINAL video to cut, in seconds. Include the existing ones you want to keep cut.",
                            "items": ["type": "object", "properties": ["start": ["type": "number"], "end": ["type": "number"]], "required": ["start", "end"]]],
                "kept": ["type": "array", "description": "The full list of parts of the ORIGINAL video to keep even if silent (e.g. a demo without talking).",
                         "items": ["type": "object", "properties": ["start": ["type": "number"], "end": ["type": "number"]], "required": ["start", "end"]]],
                "speed": ["type": "number", "description": "Playback speed, 0.75 to 2."],
                "captions": ["type": "boolean"],
                "caption_position": ["type": "string", "enum": ["top", "middle", "bottom"]],
                "zoom": ["type": "number", "description": "1 shows the whole recording; up to 4 crops in towards the focus point."],
                "focus_x": ["type": "number", "description": "Where to crop towards, 0 left to 1 right."],
                "focus_y": ["type": "number", "description": "Where to crop towards, 0 top to 1 bottom."],
                "title": ["type": "string", "description": "File name for the reels."],
                "texts": ["type": "array", "description": "The full list of text overlays (titles, labels, callouts). Include existing ones you want to keep. Times are seconds in the ORIGINAL video.",
                          "items": ["type": "object", "properties": [
                            "text": ["type": "string"], "start": ["type": "number"], "end": ["type": "number"],
                            "x": ["type": "number", "description": "Centre, 0 left to 1 right. Default 0.5."],
                            "y": ["type": "number", "description": "Centre, 0 top to 1 bottom. Titles about 0.2, labels about 0.8."],
                            "size": ["type": "number", "description": "Height as a share of the frame's short side: 0.1 title, 0.06 subtitle, 0.045 label."],
                            "style": ["type": "string", "enum": ["plain", "shadow", "outline", "box"]],
                            "animation": ["type": "string", "enum": ["none", "fade", "pop", "slide", "typewriter"]],
                            "color": ["type": "string", "description": "Hex like FFFFFF."],
                          ] as [String: Any], "required": ["text", "start", "end"]] as [String: Any]] as [String: Any],
                "zooms": ["type": "array", "description": "The full list of zoom moments: the view pushes in towards a point and eases back out. Times are seconds in the ORIGINAL video.",
                          "items": ["type": "object", "properties": [
                            "start": ["type": "number"], "end": ["type": "number"],
                            "scale": ["type": "number", "description": "1.25 gentle to 3 close. Default 1.8."],
                            "x": ["type": "number", "description": "Point to zoom towards, 0 left to 1 right."],
                            "y": ["type": "number", "description": "0 top to 1 bottom."],
                          ] as [String: Any], "required": ["start", "end"]] as [String: Any]] as [String: Any],
                "caption_style": ["type": "string", "enum": ["classic", "karaoke", "highlight", "box", "minimal"]],
                "layout": ["type": "string", "enum": ["fit", "fill", "framed"], "description": "fit shows the whole recording on a background, fill crops to fill, framed floats it with rounded corners."],
                "background": ["type": "string", "enum": ["blur", "color", "gradient"]],
            ],
            "required": ["reply"],
        ] as [String: Any],
    ]

    static func ask(_ message: String, history: [ChatLine], plan: EditPlan, analysis a: Analysis,
                    spans: [TimeSpan], editedLength: Double) async throws -> (EditPlan, String) {
        let system = """
        You edit screen recordings into short social media reels inside Mercury, a Mac app. The user tells you what \
        they want; you change the edit with the update_edit tool. Mercury already cuts silences automatically using \
        max_pause, lays the recording out as Original, 1:1, 9:16 and 16:9 over a blurred background, and adds captions. You can \
        also add text overlays and zoom moments, and change the caption style and layout. Times are always seconds in the \
        ORIGINAL recording. Use the transcript to find the parts the user means. To shorten \
        a video, cut repeated takes, false starts, tangents and dead air, and keep the core message. Never invent \
        content. If the request can't be done with these settings, say so in the reply and change nothing.
        """
        var transcript = ""
        if let words = a.words, !words.isEmpty {
            var line = "", lineStart = words[0].start
            for w in words {
                if line.isEmpty { lineStart = w.start }
                line += (line.isEmpty ? "" : " ") + w.text
                if line.count > 90 || w.text.last.map({ ".!?".contains($0) }) == true {
                    transcript += String(format: "[%.1f] %@\n", lineStart, line); line = ""
                }
            }
            if !line.isEmpty { transcript += String(format: "[%.1f] %@\n", lineStart, line) }
        } else {
            transcript = "(Not transcribed yet, or no speech.)"
        }
        let current: [String: Any] = [
            "max_pause": plan.maxPause ?? 0, "speed": plan.speed, "captions": plan.captions,
            "caption_position": plan.captionPosition, "zoom": plan.zoom, "focus_x": plan.focusX, "focus_y": plan.focusY,
            "title": plan.title, "removed": plan.removed.map { ["start": $0.start, "end": $0.end] },
            "kept": plan.kept.map { ["start": $0.start, "end": $0.end] },
            "texts": plan.texts.map { ["text": $0.text, "start": $0.start, "end": $0.end, "x": $0.x, "y": $0.y, "size": $0.size, "style": $0.style,
                                       "animation": $0.animation, "color": $0.color] as [String: Any] },
            "zooms": plan.zooms.map { ["start": $0.start, "end": $0.end, "scale": $0.scale, "x": $0.x, "y": $0.y] },
            "caption_style": plan.captionStyle.preset, "layout": plan.canvas.layout, "background": plan.canvas.background,
        ]
        let currentJSON = (try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let earlier = history.map { ($0.fromUser ? "User: " : "You: ") + $0.text }.joined(separator: "\n")
        let user = """
        <video>
        Original length: \(String(format: "%.1f", a.duration)) s. Current edit: \(String(format: "%.1f", editedLength)) s in \(spans.count) pieces.
        Current settings: \(currentJSON)
        </video>
        <transcript>
        \(transcript)</transcript>
        \(earlier.isEmpty ? "" : "<earlier_chat>\n\(earlier)\n</earlier_chat>\n")
        User's request: \(message)
        """
        let input = try await answer(system: system, user: user)
        return (apply(input, to: plan, duration: a.duration), input["reply"] as? String ?? "Done.")
    }

    /// Uses whichever Claude you've set up: your Claude subscription through Claude Code (no key needed),
    /// or your own API key. If one fails and the other is there, it tries the other.
    private static func answer(system: String, user: String) async throws -> [String: Any] {
        let codeFirst = Settings.assistantBrain == .claudeCode
        let bin = ClaudeCodeSession.binary
        let key = Keychain.apiKey.flatMap { $0.isEmpty ? nil : $0 }
        if codeFirst, let bin {
            do { return try await viaClaudeCode(bin, system: system, user: user) }
            catch { guard let key else { throw error }; log("reel chat: Claude Code failed (\(error.localizedDescription)), using the API key") ; return try await viaAPI(key, system: system, user: user) }
        }
        if let key {
            do { return try await viaAPI(key, system: system, user: user) }
            catch { guard let bin else { throw error }; return try await viaClaudeCode(bin, system: system, user: user) }
        }
        if let bin { return try await viaClaudeCode(bin, system: system, user: user) }
        if Keychain.hasKey {
            throw Failure(message: "Your saved API key couldn't be read (macOS asks again after Mercury updates). Paste it again below, or sign in to Claude Code.")
        }
        throw Failure(message: "Sign in to Claude Code, or add an Anthropic API key below, to chat.")
    }

    /// Claude Code, kept lean: only this prompt and the edit's shape, with no tools, connectors, skills or
    /// memory loaded, so a request costs a couple of thousand tokens of your plan, not hundreds of thousands.
    private static func viaClaudeCode(_ bin: URL, system: String, user: String) async throws -> [String: Any] {
        let schema = tool["input_schema"] ?? [:]
        let schemaJSON = (try? JSONSerialization.data(withJSONObject: schema)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-reels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = bin
        p.arguments = ["-p", "--output-format", "json", "--model", Settings.assistantModel.alias, "--no-session-persistence",
                       "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "",
                       "--system-prompt", system, "--json-schema", schemaJSON]
        p.currentDirectoryURL = dir  // an empty folder: no project files or notes get pulled in
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [bin.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice

        let data: Data = try await withCheckedThrowingContinuation { done in
            DispatchQueue.global().async {
                do { try p.run() } catch { done.resume(throwing: Failure(message: "Couldn't start Claude Code: \(error.localizedDescription)")); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 150, execute: killer)
                input.fileHandleForWriting.write(Data(user.utf8))
                try? input.fileHandleForWriting.close()
                let out = output.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                done.resume(returning: out)
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let u = json["usage"] as? [String: Any] {
            let total = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"].compactMap { (u[$0] as? NSNumber)?.intValue }.reduce(0, +)
            log("reel chat: Claude Code, \(total) tokens")
        }
        if let s = json["structured_output"] as? [String: Any], json["is_error"] as? Bool != true { return s }
        let said = (json["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        log("reel chat: Claude Code didn't return an edit (\(json["subtype"] as? String ?? "no output"))")
        let lower = said.lowercased()
        if lower.contains("limit") { throw Failure(message: "You've reached your Claude usage limit for now. It resets on its own; an API key in Settings keeps the editor going meanwhile.") }
        if lower.contains("log in") || lower.contains("login") || lower.contains("auth") {
            throw Failure(message: "Claude Code isn't signed in. In Terminal run claude, then /login.")
        }
        if data.isEmpty { throw Failure(message: "Claude Code didn't answer. Check it's signed in (claude, then /login in Terminal).") }
        throw Failure(message: said.isEmpty ? "Claude didn't return an edit. Try rephrasing." : "Claude couldn't answer: \(said.prefix(160))")
    }

    private static func viaAPI(_ key: String, system: String, user: String) async throws -> [String: Any] {
        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 8000,
            "output_config": ["effort": "medium"],
            "fallbacks": "default",
            "system": system,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "update_edit"],
            "messages": [["role": "user", "content": user]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            log("reel chat: \(msg)")
            throw Failure(message: "Claude couldn't answer: \(msg)")
        }
        if json["stop_reason"] as? String == "refusal" { throw Failure(message: "Claude declined that request.") }
        guard let input = (json["content"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "tool_use" })?["input"] as? [String: Any] else {
            throw Failure(message: "Claude didn't return an edit. Try rephrasing.")
        }
        return input
    }

    private static func apply(_ i: [String: Any], to plan: EditPlan, duration: Double) -> EditPlan {
        var p = plan
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
        func spans(_ v: Any?) -> [TimeSpan]? {
            (v as? [[String: Any]])?.compactMap { d in
                guard let s = (d["start"] as? NSNumber)?.doubleValue, let e = (d["end"] as? NSNumber)?.doubleValue, e > s else { return nil }
                return TimeSpan(start: clamp(s, 0, duration), end: clamp(e, 0, duration))
            }
        }
        if let v = i["max_pause"] as? NSNumber { p.maxPause = v.doubleValue <= 0 ? 0 : clamp(v.doubleValue, 0.05, 2) }
        if let r = spans(i["removed"]) { p.removed = r }
        if let k = spans(i["kept"]) { p.kept = k }
        if let v = i["speed"] as? NSNumber { p.speed = clamp(v.doubleValue, 0.75, 2) }
        if let v = i["captions"] as? Bool { p.captions = v }
        if let v = i["caption_position"] as? String, ["top", "middle", "bottom"].contains(v) { p.captionPosition = v }
        if let v = i["zoom"] as? NSNumber { p.zoom = clamp(v.doubleValue, 1, 4) }
        if let v = i["focus_x"] as? NSNumber { p.focusX = clamp(v.doubleValue, 0, 1) }
        if let v = i["focus_y"] as? NSNumber { p.focusY = clamp(v.doubleValue, 0, 1) }
        if let v = i["title"] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { p.title = v }
        func num(_ d: [String: Any], _ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        if let list = i["texts"] as? [[String: Any]] {
            p.texts = list.enumerated().compactMap { n, d in
                guard let text = d["text"] as? String, let s = num(d, "start"), let e = num(d, "end"), e > s else { return nil }
                // Keep the look of a text Claude only moved or reworded.
                var t = n < plan.texts.count ? plan.texts[n] : TextItem(text: text, start: s, end: e)
                t.text = text; t.start = clamp(s, 0, duration); t.end = clamp(e, 0, duration)
                if let v = num(d, "x") { t.x = clamp(v, 0, 1) }
                if let v = num(d, "y") { t.y = clamp(v, 0, 1) }
                if let v = num(d, "size") { t.size = clamp(v, 0.02, 0.3) }
                if let v = d["style"] as? String, ["plain", "shadow", "outline", "box"].contains(v) { t.style = v }
                if let v = d["animation"] as? String, ["none", "fade", "pop", "slide", "typewriter"].contains(v) { t.animation = v }
                if let v = d["color"] as? String, v.count == 6 || v.count == 7 { t.color = v.replacingOccurrences(of: "#", with: "") }
                return t
            }
        }
        if let list = i["zooms"] as? [[String: Any]] {
            p.zooms = list.enumerated().compactMap { n, d in
                guard let s = num(d, "start"), let e = num(d, "end"), e > s else { return nil }
                var z = n < plan.zooms.count ? plan.zooms[n] : ZoomItem(start: s, end: e)
                z.start = clamp(s, 0, duration); z.end = clamp(e, 0, duration)
                if let v = num(d, "scale") { z.scale = clamp(v, 1.1, 4) }
                if let v = num(d, "x") { z.x = clamp(v, 0, 1) }
                if let v = num(d, "y") { z.y = clamp(v, 0, 1) }
                return z
            }
        }
        if let v = i["caption_style"] as? String, Captions.presets.contains(where: { $0.0 == v }) { p.captionStyle.preset = v }
        if let v = i["layout"] as? String, ["fit", "fill", "framed"].contains(v) { p.canvas.layout = v }
        if let v = i["background"] as? String, ["blur", "color", "gradient"].contains(v) { p.canvas.background = v }
        return p
    }
}
