import UIKit
import Combine

struct PhotoEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let rule: CompositionRule?
    var critique: Critique?
    var isImported: Bool = false

    // Optional shot metadata (nil for older entries / imports).
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var zoom: Double? = nil
    var aperture: Double? = nil
    var shutter: Double? = nil
    var iso: Int? = nil

    // Cached AI-adjust suggestion. Persisted so reopening the editor later reuses
    // it instead of spending another eval token on the same photo. Cleared
    // whenever the image itself changes (see PhotoStore.replaceImage).
    var aiAdjustments: EditAdjustments? = nil
    var aiAdjustNote: String? = nil
    /// Suggested crop, stored in the *un-oriented* frame (see `AdjustService.Result`)
    /// so it survives the user rotating the photo after the analysis was made. It is
    /// deliberately kept out of `aiAdjustments.cropRect`, which means something else.
    var aiCropRect: CGRect? = nil
    var aiCropNote: String? = nil

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
    func save(image: UIImage, rule: CompositionRule?, imported: Bool = false, info: ShotInfo? = nil) -> PhotoEntry {
        let entry = PhotoEntry(id: UUID(), date: Date(), rule: rule, critique: nil, isImported: imported,
                               pixelWidth: info?.pixelWidth, pixelHeight: info?.pixelHeight,
                               zoom: info?.zoom, aperture: info?.aperture,
                               shutter: info?.shutter, iso: info?.iso)
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

    /// Persist the AI's suggested correction so a later editor session can reuse it
    /// without another API call.
    func attachAIAdjustments(_ adjustments: EditAdjustments,
                             note: String,
                             cropRect: CGRect? = nil,
                             cropNote: String? = nil,
                             to id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].aiAdjustments = adjustments
        entries[i].aiAdjustNote = note
        entries[i].aiCropRect = cropRect
        entries[i].aiCropNote = cropNote
        persist()
    }

    func delete(_ entry: PhotoEntry) {
        delete(ids: [entry.id])
    }

    /// Bulk delete for gallery multi-select. Deliberately one pass and one `persist()`
    /// rather than a loop over the single-entry version, which would rewrite the index
    /// file once per photo and republish `entries` on every removal.
    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for entry in entries where ids.contains(entry.id) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry.filename))
            thumbCache.removeObject(forKey: entry.id.uuidString as NSString)
        }
        entries.removeAll { ids.contains($0.id) }
        persist()
    }

    /// Overwrite the stored JPEG after an edit, and drop the stale thumbnail.
    /// The cached AI suggestion is discarded too — it described the OLD pixels, so
    /// reusing it against an already-corrected image would double-apply the fix.
    func replaceImage(_ image: UIImage, for entry: PhotoEntry) {
        if let data = image.jpegData(compressionQuality: 0.92) {
            try? data.write(to: dir.appendingPathComponent(entry.filename))
        }
        thumbCache.removeObject(forKey: entry.id.uuidString as NSString)
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i].aiAdjustments = nil
            entries[i].aiAdjustNote = nil
            entries[i].aiCropRect = nil
            entries[i].aiCropNote = nil
            persist()
        }
        objectWillChange.send()
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
