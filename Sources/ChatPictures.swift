// Pictures in the chat: ones Mercury searches for on Wikimedia Commons, molecule drawings from PubChem,
// linked pictures and files on your Mac. Downloads happen off the main thread so the chat never stalls.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import CryptoKit
import ScreenCaptureKit
import Speech
import SwiftUI
import WebKit

// MARK: - Pictures Mercury finds itself

enum PictureFetch {
    static let agent = "Mercury/1.0 (https://github.com/HarryNGU/mercury)"

    /// The download happens off the main thread; the picture itself is made on the main actor,
    /// where every view that shows it lives (NSImage isn't safe to pass between threads).
    @MainActor static func image(_ url: URL) async -> NSImage? {
        guard let d = await data(url) else { return nil }
        return NSImage(data: d)
    }

    static func data(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }

    /// Up to six pictures for `query` from Wikimedia Commons (free, no account): (thumbnail, page).
    /// Long searches often match nothing, so it retries with fewer words.
    static func commons(_ query: String) async -> [(URL, URL, URL?)] {
        let words = query.split(separator: " ")
        for n in [words.count, min(words.count, 3), min(words.count, 2), 1] where n > 0 {
            let found = await commonsOnce(words.prefix(n).joined(separator: " "))
            if !found.isEmpty { return found }
        }
        return []
    }

    private static func commonsOnce(_ query: String) async -> [(URL, URL, URL?)] {
        var c = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrnamespace", value: "6"),
            .init(name: "gsrlimit", value: "10"), .init(name: "gsrsearch", value: query + " filetype:bitmap|drawing"),
            .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|mime"), .init(name: "iiurlwidth", value: "420"),
        ]
        var req = URLRequest(url: c.url!)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let pages = (json["query"] as? [String: Any])?["pages"] as? [String: [String: Any]] else { return [] }
        let ordered = pages.values.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return ordered.compactMap { p in
            guard let info = (p["imageinfo"] as? [[String: Any]])?.first,
                  let mime = info["mime"] as? String, mime.hasPrefix("image/"),
                  let thumb = (info["thumburl"] as? String).flatMap(URL.init(string:)),
                  let page = (info["descriptionurl"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (thumb, page, (info["url"] as? String).flatMap(URL.init(string:)))
        }
        .prefix(6).map { $0 }
    }
}

/// A row of pictures for a search, from Wikimedia Commons. Click one to open its page.
struct ImageSearchStrip: View {
    let query: String
    @State private var items: [(NSImage, URL, URL?)] = []
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(query, systemImage: "photo.on.rectangle").font(.system(size: 11, weight: .medium)).opacity(0.6)
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)).frame(height: 110)
                    .overlay { if done { Text("No pictures found").font(.system(size: 12)).opacity(0.6) } else { ProgressView().controlSize(.small) } }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                            Image(nsImage: it.0).resizable().scaledToFill()
                                .frame(width: 150, height: 120).background(Color.white).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .opensInViewer(it.0, fullSize: it.2, open: it.1, openLabel: "Open on Wikimedia Commons")
                                .contextMenu { Button("Open on Wikimedia Commons") { NSWorkspace.shared.open(it.1) } }
                        }
                    }
                }
            }
        }
        .task(id: query) {
            let found = await PictureFetch.commons(query)
            var loaded: [(NSImage, URL, URL?)] = []
            for (thumb, page, full) in found { if let img = await PictureFetch.image(thumb) { loaded.append((img, page, full)); items = loaded } }
            done = true
        }
    }
}

/// A compound's 2D and 3D structure from PubChem.
struct MoleculeCard: View {
    let name: String
    @Environment(\.chatMediaWidth) private var mediaWidth
    @State private var flat: NSImage?
    @State private var solid: NSImage?
    @State private var done = false

    private func url(_ threeD: Bool) -> URL? {
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        // PubChem only draws 3D models at its fixed "large" size.
        return URL(string: "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/\(n)/PNG?" + (threeD ? "record_type=3d&image_size=large" : "image_size=400x400"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name.capitalized, systemImage: "atom").font(.system(size: 11, weight: .medium)).opacity(0.6)
            HStack(spacing: 8) {
                tile(flat, "2D")
                tile(solid, "3D")
            }
            .contextMenu { if let u = pubchem { Button("Open on PubChem") { NSWorkspace.shared.open(u) } } }
        }
        .task(id: name) {
            if let u = url(false) { flat = await PictureFetch.image(u) }
            if let u = url(true) { solid = await PictureFetch.image(u) }
            done = true
        }
    }

    private var pubchem: URL? {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return URL(string: "https://pubchem.ncbi.nlm.nih.gov/#query=\(q)")
    }

    private func tile(_ img: NSImage?, _ label: String) -> some View {
        Group {
            if let img { tileBody(img, label).opensInViewer(img, open: pubchem, openLabel: "Open on PubChem") }
            else { tileBody(nil, label) }
        }
    }

    private func tileBody(_ img: NSImage?, _ label: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(.white)
            if let img { Image(nsImage: img).resizable().scaledToFit().padding(6) }
            else if done { Text("Not found").font(.system(size: 11)).foregroundStyle(.gray).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.5)).padding(6)
        }
        .frame(width: min(170, (mediaWidth - 8) / 2), height: 150)
    }
}

/// A picture from a link in the answer, loaded with a polite user agent (some sites refuse
/// requests without one). Shows a note instead of spinning forever if it can't load.
struct LinkedPicture: View {
    let url: URL
    @Environment(\.chatMediaWidth) private var mediaWidth
    @State private var img: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let img {
                Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: min(480, mediaWidth), maxHeight: 420, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .opensInViewer(img, open: url.isFileURL ? LocalPicture.existing(url) : url, openLabel: url.isFileURL ? "Open in Preview" : "Open in Browser")
            } else if failed {
                Label(url.isFileURL ? "This picture is no longer on your Mac." : "Couldn't load this picture. Click to open it.",
                      systemImage: "photo").font(.system(size: 12)).opacity(0.65)
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)).frame(height: 120).overlay(ProgressView().controlSize(.small))
            }
        }
        .onTapGesture { if img == nil { open() } }
        .contextMenu {
            Button(url.isFileURL ? "Open in Preview" : "Open in Browser") { open() }
            if let img { Button("Copy Picture") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img]) } }
            if url.isFileURL, let file = LocalPicture.existing(url) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
        .task(id: url) {
            img = url.isFileURL ? LocalPicture.load(url) : await PictureFetch.image(url)
            // Claude sometimes mentions a picture a moment before it has finished saving it: keep looking.
            var tries = 0
            while img == nil, url.isFileURL, tries < 40, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                img = LocalPicture.load(url)
                tries += 1
            }
            failed = img == nil
        }
    }

    private func open() {
        if url.isFileURL { if let f = LocalPicture.existing(url) { NSWorkspace.shared.open(f) } }
        else { NSWorkspace.shared.open(url) }
    }
}

/// Picture files on this Mac shown in the chat, such as a chart Claude just drew. They are only shown here,
/// never uploaded. Mercury keeps its own copy (in Application Support/Bubble/Pictures, readable only by you),
/// so a saved chat still shows its pictures after a temporary file is cleaned up.
enum LocalPicture {
    static let kinds: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "pdf"]

    /// Where Ask Mercury saves pictures it draws for you (diagrams, shapes, charts). Writing a picture
    /// here doesn't need your OK; it's only ever shown in the chat.
    static var drawings: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bubble/Drawings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return d
    }

    /// A drawing being saved into the drawings folder.
    static func isDrawing(_ tool: String, _ input: [String: Any]) -> Bool {
        guard tool == "Write", let p = input["file_path"] as? String else { return false }
        let full = ((p as NSString).expandingTildeInPath as NSString).standardizingPath
        return full.hasPrefix(drawings.path + "/") && kinds.contains((full as NSString).pathExtension.lowercased())
    }

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bubble/Pictures", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return d
    }

    /// Looks like a path or file address of a picture.
    static func isPicture(_ s: String) -> Bool {
        guard s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("file://") else { return false }
        return kinds.contains((s as NSString).pathExtension.lowercased())
    }

    /// A file address for a path, `~/…` path or file:// address, if it names a picture somewhere it's fine to show.
    static func url(_ s: String) -> URL? {
        var path: String
        if s.hasPrefix("file://") { guard let u = URL(string: s) ?? URL(string: s.replacingOccurrences(of: " ", with: "%20")) else { return nil }; path = u.path }
        else { path = (s.removingPercentEncoding ?? s) }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), kinds.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        let full = (path as NSString).standardizingPath
        if ClaudeCodeSession.privatePaths.contains(where: { full.contains($0) }) { return nil }
        return URL(fileURLWithPath: full)
    }

    private static func copyURL(_ u: URL) -> URL {
        let key = SHA256.hash(data: Data(u.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(key).appendingPathExtension(u.pathExtension.lowercased())
    }

    /// The original if it's still there, otherwise Mercury's copy.
    static func existing(_ u: URL) -> URL? {
        for f in [u, copyURL(u)] where FileManager.default.fileExists(atPath: f.path) { return f }
        return nil
    }

    static func load(_ u: URL) -> NSImage? {
        let fm = FileManager.default
        if let a = try? fm.attributesOfItem(atPath: u.path), a[.type] as? FileAttributeType == .typeRegular,
           (a[.size] as? Int ?? 0) <= 60_000_000, let img = NSImage(contentsOf: u), img.isValid {
            let copy = copyURL(u)
            if Settings.chatKeepDays != 0, u.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL {
                try? fm.removeItem(at: copy)
                if (try? fm.copyItem(at: u, to: copy)) != nil { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path) }
            }
            return img
        }
        let copy = copyURL(u)
        return fm.fileExists(atPath: copy.path) ? NSImage(contentsOf: copy) : nil
    }

    static func deleteAll() { try? FileManager.default.removeItem(at: dir) }

    /// Removes copies older than chats are kept.
    static func prune(olderThan cutoff: Date) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff { try? fm.removeItem(at: f) }
        }
    }
}
