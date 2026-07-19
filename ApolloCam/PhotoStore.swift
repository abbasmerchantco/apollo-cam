import UIKit
import Combine

struct PhotoEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let rule: CompositionRule?
    var critique: Critique?
    var isImported: Bool = false

    var filename: String { "\(id.uuidString).jpg" }
}

struct Critique: Codable {
    struct Dimension: Codable, Identifiable {
        let name: String
        let score: Int
        let feedback: String
        let tip: String
        var id: String { name }
    }
    let overall: Int
    let summary: String
    let dimensions: [Dimension]
}

final class PhotoStore: ObservableObject {
    static let shared = PhotoStore()

    @Published private(set) var entries: [PhotoEntry] = []

    private let dir: URL
    private let indexURL: URL
    private var thumbCache = NSCache<NSString, UIImage>()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("photos", isDirectory: true)
        indexURL = dir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([PhotoEntry].self, from: data) else { return }
        entries = decoded.sorted { $0.date > $1.date }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: indexURL)
        }
    }

    @discardableResult
    func save(image: UIImage, rule: CompositionRule?, imported: Bool = false) -> PhotoEntry {
        let entry = PhotoEntry(id: UUID(), date: Date(), rule: rule, critique: nil, isImported: imported)
        if let data = image.jpegData(compressionQuality: 0.88) {
            try? data.write(to: dir.appendingPathComponent(entry.filename))
        }
        entries.insert(entry, at: 0)
        persist()
        return entry
    }

    func attachCritique(_ critique: Critique, to id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].critique = critique
        persist()
    }

    func delete(_ entry: PhotoEntry) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry.filename))
        entries.removeAll { $0.id == entry.id }
        thumbCache.removeObject(forKey: entry.id.uuidString as NSString)
        persist()
    }

    func image(for entry: PhotoEntry) -> UIImage? {
        UIImage(contentsOfFile: dir.appendingPathComponent(entry.filename).path)
    }

    func thumbnail(for entry: PhotoEntry) -> UIImage? {
        let key = entry.id.uuidString as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let full = image(for: entry) else { return nil }
        let side: CGFloat = 300
        let scale = side / max(full.size.width, full.size.height)
        let size = CGSize(width: full.size.width * scale, height: full.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let thumb = renderer.image { _ in full.draw(in: CGRect(origin: .zero, size: size)) }
        thumbCache.setObject(thumb, forKey: key)
        return thumb
    }
}
