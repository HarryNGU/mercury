// Brains for people without Claude. Mercury's free AI runs through Mercury's own small server (the same one
// the Windows app uses): no account, a daily limit per Mac, and Harry's server pays. An OpenAI key, or any
// OpenAI compatible service (Gemini, Grok, DeepSeek, OpenRouter, a local Ollama), works with the person's own key.
// Both answer in the chat and can look at the screen when asked; doing things on the Mac needs Claude Code.

import Foundation

extension Settings {
    /// Where an OpenAI compatible service lives. OpenAI itself by default.
    static var openAIBaseURL: String {
        get { d.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1" }
        set { d.set(newValue, forKey: "openAIBaseURL") }
    }
    /// The model to ask. It needs vision to read screenshots.
    static var openAIModel: String {
        get { d.string(forKey: "openAIModel") ?? "gpt-5-mini" }
        set { d.set(newValue, forKey: "openAIModel") }
    }
}

enum FreeAI {
    static let server = URL(string: "https://mercury-free-ai.mercury-free-ai-server.workers.dev")!
    /// Free messages left today, from the server's last answer.
    @MainActor static var remaining: Int?

    /// A random id made once per Mac, swapped for a signed token. It identifies this install only, not you.
    private static var installID: String {
        if let id = Settings.d.string(forKey: "freeAIInstallID") { return id }
        let id = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(40)
        Settings.d.set(String(id), forKey: "freeAIInstallID")
        return String(id)
    }

    private static func token(fresh: Bool = false) async throws -> String {
        if !fresh, let t = Settings.d.string(forKey: "freeAIToken"), !t.isEmpty { return t }
        var req = URLRequest(url: server.appendingPathComponent("v1/device"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["installId": installID, "platform": "mac"])
        guard let (d, r) = try? await URLSession.shared.data(for: req) else {
            throw LiveListener.Failure("Mercury's free AI can't be reached right now. Check your internet, or add your own key in Settings, Assistant.")
        }
        let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        guard (r as? HTTPURLResponse)?.statusCode == 200, let t = json?["token"] as? String else {
            throw LiveListener.Failure(json?["error"] as? String ?? "Mercury's free AI didn't let this Mac sign in.")
        }
        Settings.d.set(t, forKey: "freeAIToken")
        return t
    }

    static func ask(_ question: String, history: [AssistantClient.Turn], screenshot: Data?, transcript: String,
                    onText: @escaping @MainActor (String) -> Void, retried: Bool = false) async throws {
        var messages: [[String: Any]] = []
        // The server takes at most 16 messages of 8,000 characters, alternating and ending with yours.
        for t in history.filter({ !$0.answer.isEmpty }).suffix(7) {
            messages.append(["role": "user", "text": String(t.question.prefix(8000))])
            messages.append(["role": "assistant", "text": String(t.answer.prefix(8000))])
        }
        var text = ""
        if !transcript.isEmpty { text += "<recent_conversation>\n\(transcript)\n</recent_conversation>\n\n" }
        text += question
        var last: [String: Any] = ["role": "user", "text": String(text.prefix(8000))]
        if let s = screenshot { last["image"] = s.base64EncodedString() }
        messages.append(last)

        let t = try await token(fresh: retried)
        var req = URLRequest(url: server.appendingPathComponent("v1/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(t)", forHTTPHeaderField: "authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "platform": "mac", "client": "mac",
            "system": String(AssistantClient.system.prefix(12_000)),   // Mercury's own voice, the same as with a key
            "messages": messages,
        ])
        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await URLSession.shared.bytes(for: req) }
        catch { throw LiveListener.Failure("Mercury's free AI can't be reached right now. Check your internet, or add your own key in Settings, Assistant.") }
        let http = resp as? HTTPURLResponse
        if http?.statusCode == 401 && !retried {
            return try await ask(question, history: history, screenshot: screenshot, transcript: transcript, onText: onText, retried: true)
        }
        if let r = http?.value(forHTTPHeaderField: "x-mercury-remaining").flatMap(Int.init) { await MainActor.run { remaining = r } }
        guard http?.statusCode == 200 else {
            if http?.statusCode == 503 { throw LiveListener.Failure("Mercury's free AI is resting for now. Try again later, or add your own key in Settings, Assistant.") }
            var raw = Data()
            for try await b in bytes { raw.append(b); if raw.count > 20_000 { break } }
            let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            throw LiveListener.Failure(json?["error"] as? String ?? "Mercury's free AI couldn't answer (\(http?.statusCode ?? 0)).")
        }
        // Server sent events: blank line separated JSON, each `data: {...}`.
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "), let d = line.dropFirst(6).data(using: .utf8),
                  let ev = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            switch ev["type"] as? String {
            case "text": if let s = ev["text"] as? String { await onText(s) }
            case "done": if let r = ev["remaining"] as? Int { await MainActor.run { remaining = r } }
            case "error": throw LiveListener.Failure(ev["message"] as? String ?? "Mercury's free AI stopped.")
            default: break
            }
        }
    }
}

enum OpenAIClient {
    static func ask(_ question: String, history: [AssistantClient.Turn], screenshot: Data?, transcript: String,
                    onText: @escaping @MainActor (String) -> Void) async throws {
        let base = Settings.openAIBaseURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = Keychain.key(account: Keychain.openAIAccount) ?? ""
        // A local server such as Ollama needs no key; anything on the internet does.
        guard !key.isEmpty || base.contains("localhost") || base.contains("127.0.0.1") else {
            throw LiveListener.Failure("Add your OpenAI key in Mercury, Settings, Assistant to start asking.")
        }
        guard let url = URL(string: base + "/chat/completions") else { throw LiveListener.Failure("That service address doesn't look right. Check it in Settings, Assistant.") }
        var messages: [[String: Any]] = [["role": "system", "content": AssistantClient.system]]
        for t in history.suffix(8) where !t.answer.isEmpty {
            messages.append(["role": "user", "content": t.question])
            messages.append(["role": "assistant", "content": t.answer])
        }
        var text = ""
        if !transcript.isEmpty { text += "<recent_conversation>\n\(transcript)\n</recent_conversation>\n\n" }
        text += question
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let s = screenshot { content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + s.base64EncodedString()]]) }
        messages.append(["role": "user", "content": content])

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": Settings.openAIModel, "stream": true, "messages": messages])
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = Data()
            for try await b in bytes { raw.append(b); if raw.count > 20_000 { break } }
            let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            log("assistant: openai \(status)")
            throw LiveListener.Failure(status == 401 ? "That key isn't working. Check it in Settings, Assistant." : "The AI couldn't answer: \(msg)")
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8), let ev = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let choice = (ev["choices"] as? [[String: Any]])?.first else { continue }
            if let s = (choice["delta"] as? [String: Any])?["content"] as? String, !s.isEmpty { await onText(s) }
        }
    }
}
