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
    /// The address actually used: OpenAI when the box is empty, https added when it's missing,
    /// and a pasted ".../chat/completions" trimmed back to the base. Nil when it still isn't a web address.
    static func openAIEndpoint(_ raw: String) -> URL? {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "https://api.openai.com/v1" }
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            let local = base.hasPrefix("localhost") || base.hasPrefix("127.0.0.1")
            base = (local ? "http://" : "https://") + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        if base.lowercased().hasSuffix("/chat/completions") { base.removeLast("/chat/completions".count) }
        guard let url = URL(string: base + "/chat/completions"), let host = url.host, !host.isEmpty,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }
    /// The model to ask. It needs vision to read screenshots.
    static var openAIModel: String {
        get {
            let m = (d.string(forKey: "openAIModel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? "gpt-5-mini" : m
        }
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
    /// Set only by the --openaitest hook, so tests never read or write the Keychain.
    nonisolated(unsafe) static var keyOverride: String?

    /// Plain words for the errors people actually hit.
    static func friendly(status: Int, message: String, raw: [String: Any]?) -> String {
        let code = ((raw?["error"] as? [String: Any])?["code"] as? String) ?? ""
        if code == "insufficient_quota" || message.lowercased().contains("credit") || message.lowercased().contains("quota") {
            return "Your OpenAI account has no credit left. Add some at platform.openai.com, under Billing, or use a free Gemini key from aistudio.google.com instead."
        }
        if status == 401 { return "That key isn't working. Check it in Settings, Assistant, and that the service address matches where the key came from." }
        return "The AI couldn't answer: \(message)"
    }

    static func ask(_ question: String, history: [AssistantClient.Turn], screenshot: Data?, transcript: String,
                    onText: @escaping @MainActor (String) -> Void) async throws {
        let endpoint = Settings.openAIEndpoint(Settings.openAIBaseURL)
        let base = endpoint?.absoluteString ?? ""
        let key = keyOverride ?? Keychain.key(account: Keychain.openAIAccount) ?? ""
        if GeminiClient.isGemini(key: key, base: Settings.openAIBaseURL) {
            try await GeminiClient.ask(question, key: key, history: history, screenshot: screenshot, transcript: transcript, onText: onText)
            return
        }
        // A local server such as Ollama needs no key; anything on the internet does.
        guard !key.isEmpty || base.contains("localhost") || base.contains("127.0.0.1") else {
            throw LiveListener.Failure("Add your OpenAI key in Mercury, Settings, Assistant to start asking.")
        }
        guard let url = endpoint else { throw LiveListener.Failure("That service address doesn't look right. Check it in Settings, Assistant.") }
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
            // OpenAI won't stream some models for accounts that haven't verified their organisation.
            // Ask once more without streaming and show the whole answer.
            if status == 400, msg.lowercased().contains("stream") {
                var plain = req
                plain.httpBody = try JSONSerialization.data(withJSONObject: ["model": Settings.openAIModel, "stream": false, "messages": messages])
                let (data, r2) = try await URLSession.shared.data(for: plain)
                let s2 = (r2 as? HTTPURLResponse)?.statusCode ?? 0
                let j2 = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if s2 == 200, let answer = (((j2?["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any])?["content"] as? String {
                    await onText(answer)
                    return
                }
                let m2 = (j2?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(s2)"
                throw LiveListener.Failure("The AI couldn't answer: \(m2)")
            }
            throw LiveListener.Failure(OpenAIClient.friendly(status: status, message: msg, raw: json))
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


/// Google's Gemini, through its own address. Its newer "AQ." keys are often refused by Google's OpenAI
/// style address, so a Gemini key always goes here, with the key in the x-goog-api-key header.
enum GeminiClient {
    static let defaultModel = "gemini-flash-latest"

    static func isGemini(key: String, base: String) -> Bool {
        key.hasPrefix("AIza") || key.hasPrefix("AQ.") || base.contains("generativelanguage.googleapis.com")
    }

    /// The model to ask: yours if it's a Gemini one, otherwise Google's latest Flash.
    static func model(_ chosen: String) -> String {
        let m = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.lowercased().hasPrefix("gemini") ? m : defaultModel
    }

    /// Where requests go. Tests point it at a fake local server with -geminiBaseURL.
    static var base: String {
        let b = Settings.d.string(forKey: "geminiBaseURL") ?? ""
        return b.isEmpty ? "https://generativelanguage.googleapis.com/v1beta" : b
    }

    static func ask(_ question: String, key: String, history: [AssistantClient.Turn], screenshot: Data?, transcript: String,
                    onText: @escaping @MainActor (String) -> Void) async throws {
        let name = model(Settings.openAIModel)
        guard let url = URL(string: base + "/models/\(name):streamGenerateContent?alt=sse") else {
            throw LiveListener.Failure("That Gemini model name doesn't look right. Check it in Settings, Assistant.")
        }
        var contents: [[String: Any]] = []
        for t in history.suffix(8) where !t.answer.isEmpty {
            contents.append(["role": "user", "parts": [["text": t.question]]])
            contents.append(["role": "model", "parts": [["text": t.answer]]])
        }
        var text = ""
        if !transcript.isEmpty { text += "<recent_conversation>\n\(transcript)\n</recent_conversation>\n\n" }
        text += question
        var parts: [[String: Any]] = [["text": text]]
        if let s = screenshot { parts.append(["inline_data": ["mime_type": "image/jpeg", "data": s.base64EncodedString()]]) }
        contents.append(["role": "user", "parts": parts])

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": AssistantClient.system]]],
            "contents": contents,
        ])
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = Data()
            for try await b in bytes { raw.append(b); if raw.count > 20_000 { break } }
            let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            log("assistant: gemini \(status)")
            throw LiveListener.Failure(friendly(status: status, message: msg))
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "), let d = line.dropFirst(6).data(using: .utf8),
                  let ev = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let cand = (ev["candidates"] as? [[String: Any]])?.first,
                  let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { continue }
            for p in parts { if let t = p["text"] as? String, !t.isEmpty { await onText(t) } }
        }
    }

    static func friendly(status: Int, message: String) -> String {
        let m = message.lowercased()
        if status == 400 && m.contains("api key") || status == 401 || status == 403 {
            return "Google didn't accept that Gemini key. Make a new one at aistudio.google.com and paste it in Settings, Assistant."
        }
        if status == 429 { return "You've used up Gemini's free requests for now. Wait a minute and try again, or turn on billing in Google AI Studio." }
        if status == 404 { return "Gemini doesn't know that model. Clear the Model box in Settings, Assistant, and Mercury will pick one." }
        return "Gemini couldn't answer: \(message)"
    }
}
