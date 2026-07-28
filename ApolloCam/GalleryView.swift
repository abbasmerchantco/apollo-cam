import SwiftUI
import PhotosUI

/// Wraps `UIActivityViewController` so the gallery can share a batch of photos.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct GalleryView: View {
    @ObservedObject private var store = PhotoStore.shared
    @State private var selected: PhotoEntry?
    @State private var pickerItem: PhotosPickerItem?
    @State private var importedForLearning: UIImage?

    // Multi-select
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirmBulkDelete = false
    @State private var shareItems: [UIImage]?
    /// Non-nil while a bulk AI evaluation is running: (done, total).
    @State private var evalProgress: (done: Int, total: Int)?
    @State private var bulkMessage: String?

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)
    private let cyan = Color(red: 0.0, green: 0.9, blue: 1.0)
    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    private var busy: Bool { evalProgress != nil }

    var body: some View {
        NavigationView {
            Group {
                if store.entries.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        grid
                        if selecting { selectionBar }
                    }
                }
            }
            .navigationTitle(selecting ? selectionTitle : "Gallery")
            .navigationBarTitleDisplayMode(selecting ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if selecting {
                        Button(selection.count == store.entries.count ? "None" : "All") {
                            selection = selection.count == store.entries.count
                                ? []
                                : Set(store.entries.map(\.id))
                        }
                        .disabled(busy)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selecting {
                        Button("Done") { endSelecting() }.disabled(busy)
                    } else if !store.entries.isEmpty {
                        HStack(spacing: 16) {
                            Button("Select") { selecting = true }
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Image(systemName: "square.and.arrow.down")
                            }
                        }
                    } else {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        let entry = PhotoStore.shared.save(image: image, rule: nil, imported: true)
                        await MainActor.run { selected = entry }
                    }
                    pickerItem = nil
                }
            }
            .sheet(item: $selected) { entry in
                if let img = store.image(for: entry) {
                    PhotoDetailView(entry: entry, image: img)
                }
            }
            .sheet(isPresented: Binding(get: { shareItems != nil },
                                        set: { if !$0 { shareItems = nil } })) {
                if let items = shareItems { ActivityView(items: items) }
            }
            .confirmationDialog(deletePrompt, isPresented: $confirmBulkDelete, titleVisibility: .visible) {
                Button("Delete \(selection.count) photo\(selection.count == 1 ? "" : "s")", role: .destructive) {
                    store.delete(ids: selection)
                    endSelecting()
                    Haptics.success()
                }
            }
            .alert("Gallery", isPresented: Binding(get: { bulkMessage != nil },
                                                   set: { if !$0 { bulkMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(bulkMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    private var selectionTitle: String {
        if let p = evalProgress { return "Evaluating \(min(p.done + 1, p.total)) of \(p.total)…" }
        return selection.isEmpty ? "Select photos" : "\(selection.count) selected"
    }

    private var deletePrompt: String {
        "Delete \(selection.count) photo\(selection.count == 1 ? "" : "s")? This can't be undone."
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("No photos yet").font(.headline)
            Text("Shoot with the camera, or import a photo you admire to learn why it works.")
                .font(.footnote).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(store.entries) { entry in
                    Button {
                        if selecting { toggle(entry) } else { selected = entry }
                    } label: {
                        cell(entry)
                    }
                    .disabled(busy)
                }
            }
        }
    }

    private func cell(_ entry: PhotoEntry) -> some View {
        let isSelected = selection.contains(entry.id)
        return ZStack(alignment: .bottomTrailing) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Group {
                        if let thumb = store.thumbnail(for: entry) {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.gray.opacity(0.2)
                        }
                    }
                )
                .clipped()
                // Dim the unpicked ones rather than highlighting the picked ones:
                // with a wall of thumbnails, "what have I got so far" is much easier
                // to read when the answer is the bright subset.
                .overlay(Color.black.opacity(selecting && !isSelected ? 0.45 : 0))

            if let c = entry.critique {
                Text("\(c.overall)")
                    .font(.caption2.bold().monospaced())
                    .padding(5)
                    .background(gold, in: Circle())
                    .foregroundColor(.black)
                    .padding(5)
            }
            if entry.isImported {
                Image(systemName: "graduationcap.fill")
                    .font(.caption2)
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if selecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(isSelected ? Color.black : Color.white,
                                     isSelected ? cyan : Color.white.opacity(0.35))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private func toggle(_ entry: PhotoEntry) {
        if selection.contains(entry.id) { selection.remove(entry.id) }
        else { selection.insert(entry.id) }
    }

    private func endSelecting() {
        selecting = false
        selection = []
    }

    // MARK: - Bulk actions

    private var selectionBar: some View {
        HStack(spacing: 0) {
            bulkButton("Save", icon: "square.and.arrow.down", tint: .white, action: saveSelectedToPhotos)
            bulkButton("Share", icon: "square.and.arrow.up", tint: .white, action: shareSelected)
            bulkButton("Evaluate", icon: "sparkles", tint: gold, action: evaluateSelected)
            bulkButton("Delete", icon: "trash", tint: .red) { confirmBulkDelete = true }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            if busy { ProgressView().tint(.white).padding(.top, 4) }
        }
    }

    private func bulkButton(_ title: String, icon: String, tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.system(size: 10))
            }
            .foregroundColor(tint)
            .frame(maxWidth: .infinity)
        }
        .disabled(selection.isEmpty || busy)
        .opacity(selection.isEmpty || busy ? 0.35 : 1)
    }

    private var selectedEntries: [PhotoEntry] {
        store.entries.filter { selection.contains($0.id) }
    }

    /// Loads the selected photos off the main thread.
    ///
    /// `PhotoStore.image(for:)` is a full-resolution JPEG decode per photo. One is
    /// unnoticeable, which is why the single-photo screens call it inline — but a
    /// selection of thirty on the main thread is a visible freeze, so the bulk paths
    /// always go through here.
    private func loadSelected(_ entries: [PhotoEntry], then handler: @escaping ([UIImage]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let images = entries.compactMap { PhotoStore.shared.image(for: $0) }
            DispatchQueue.main.async { handler(images) }
        }
    }

    private func saveSelectedToPhotos() {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        loadSelected(entries) { images in
            for image in images { UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil) }
            Haptics.success()
            bulkMessage = "Saved \(images.count) photo\(images.count == 1 ? "" : "s") to your library."
            endSelecting()
        }
    }

    private func shareSelected() {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        loadSelected(entries) { images in
            guard !images.isEmpty else { return }
            shareItems = images
        }
    }

    /// Evaluates the selected photos one at a time.
    ///
    /// Sequential rather than concurrent on purpose: each critique spends a token
    /// from a small daily bucket, and firing them in parallel would blow past the
    /// remaining balance before the counter caught up. Already-critiqued photos are
    /// skipped so re-selecting a batch doesn't quietly re-buy work already paid for.
    private func evaluateSelected() {
        let pending = selectedEntries.filter { $0.critique == nil }
        guard !pending.isEmpty else {
            bulkMessage = "Those photos have all been evaluated already."
            return
        }
        guard TokenManager.shared.canUseEval else {
            bulkMessage = "Out of AI tokens for today. They reset at midnight."
            return
        }

        evalProgress = (0, pending.count)
        Task {
            var done = 0
            var failed = 0
            var ranOut = false

            for entry in pending {
                let hasToken = await MainActor.run { TokenManager.shared.canUseEval }
                guard hasToken else { ranOut = true; break }
                guard let image = store.image(for: entry) else { failed += 1; continue }

                do {
                    let critique = try await CritiqueService.critique(
                        image: image,
                        mode: entry.isImported ? .learnFromPro : .myPhoto)
                    done += 1
                    // Snapshot into a `let`: `MainActor.run` takes a @Sendable body,
                    // which cannot capture a mutable local.
                    let progress = (done: done, total: pending.count)
                    await MainActor.run {
                        store.attachCritique(critique, to: entry.id)
                        TokenManager.shared.useEvalToken()
                        evalProgress = progress
                    }
                } catch {
                    failed += 1
                }
            }

            let summary = done
            let failures = failed
            let stopped = ranOut
            await MainActor.run {
                evalProgress = nil
                var parts = ["Evaluated \(summary) photo\(summary == 1 ? "" : "s")."]
                if failures > 0 { parts.append("\(failures) couldn't be evaluated.") }
                if stopped { parts.append("Ran out of tokens for today.") }
                bulkMessage = parts.joined(separator: " ")
                if summary > 0 { Haptics.success() }
                endSelecting()
            }
        }
    }
}

struct PhotoDetailView: View {
    let entry: PhotoEntry
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var showCritique = false
    @State private var showEditor = false
    @State private var confirmDelete = false
    /// Kept in state so an edit made here updates this screen immediately.
    @State private var displayImage: UIImage?

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)
    private let cyan = Color(red: 0.0, green: 0.9, blue: 1.0)

    private var shown: UIImage { displayImage ?? image }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Image(uiImage: shown)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal)

                if let rule = entry.rule {
                    Label(rule.rawValue, systemImage: rule.icon)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        showCritique = true
                    } label: {
                        Label(entry.critique == nil
                              ? (entry.isImported ? "Why does this work?" : "Evaluate")
                              : "View critique",
                              systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(gold)
                    .foregroundColor(.black)

                    // Same editor as the capture review screen — this is what makes
                    // manual sliders and AI adjust available for gallery photos and
                    // imports, not just the shot you just took.
                    Button {
                        showEditor = true
                    } label: {
                        Label("Edit", systemImage: "slider.horizontal.3")
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(cyan)
                    .foregroundColor(.black)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Image(systemName: "trash")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete this photo?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    PhotoStore.shared.delete(entry)
                    dismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showCritique) {
            CritiqueView(image: shown, entryID: entry.id, mode: entry.isImported ? .learnFromPro : .myPhoto)
        }
        .fullScreenCover(isPresented: $showEditor) {
            PhotoEditorView(entry: entry) { edited in
                PhotoStore.shared.replaceImage(edited, for: entry)
                displayImage = edited
            }
        }
    }
}
