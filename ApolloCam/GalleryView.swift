import SwiftUI
import PhotosUI

struct GalleryView: View {
    @ObservedObject private var store = PhotoStore.shared
    @State private var selected: PhotoEntry?
    @State private var pickerItem: PhotosPickerItem?
    @State private var importedForLearning: UIImage?

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)
    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]

    var body: some View {
        NavigationView {
            Group {
                if store.entries.isEmpty {
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
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(store.entries) { entry in
                                Button { selected = entry } label: {
                                    ZStack(alignment: .bottomTrailing) {
                                        if let thumb = store.thumbnail(for: entry) {
                                            Image(uiImage: thumb)
                                                .resizable().scaledToFill()
                                                .frame(minWidth: 0, maxWidth: .infinity)
                                                .aspectRatio(1, contentMode: .fill)
                                                .clipped()
                                        }
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
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Gallery")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Import", systemImage: "square.and.arrow.down")
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
        }
        .preferredColorScheme(.dark)
    }
}

struct PhotoDetailView: View {
    let entry: PhotoEntry
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var showCritique = false
    @State private var confirmDelete = false

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal)

                if let rule = entry.rule {
                    Label(rule.rawValue, systemImage: rule.icon)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

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
            CritiqueView(image: image, entryID: entry.id, mode: entry.isImported ? .learnFromPro : .myPhoto)
        }
    }
}
