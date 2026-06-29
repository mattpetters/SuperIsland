import SwiftUI
import Combine
import AVFoundation

@MainActor
final class MascotManager: ObservableObject {
    static let shared = MascotManager()

    @AppStorage("mascot.selected") var selectedSlug: String = "otto"
    @AppStorage("mascot.showInPomodoro") var showInPomodoro: Bool = true

    @Published private(set) var template: MascotTemplate?
    @Published private(set) var currentNodeID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    // Current video URL for the view layer (loop only, no transitions for instant switching)
    @Published private(set) var currentLoopVideoURL: URL?
    @Published private(set) var thumbnailURL: URL?
    @Published private(set) var currentPetdexPet: PetdexPet?
    @Published private(set) var currentPetdexSpritesheetURL: URL?
    @Published private(set) var petdexPets: [PetdexPet] = []
    @Published private(set) var petdexSearchResults: [PetdexPet] = []
    @Published private(set) var isLoadingPetdexManifest = false
    @Published private(set) var isSearchingPetdex = false
    @Published private(set) var petdexSearchMessage: String?

    // Download status per slug
    @Published var downloadedSlugs: Set<String> = []

    // Expression-to-node mapping
    @Published var currentExpression: String = "idle" {
        didSet {
            guard oldValue != currentExpression else { return }
            transitionToNode(forExpression: currentExpression)
        }
    }

    // Each expression maps to candidate node names (tried in order, case-insensitive)
    private let expressionToNodeCandidates: [String: [String]] = [
        "idle": ["idle"],
        "working": ["working"],
        "alert": ["permission", "needs attention", "alert"],
        "happy": ["idle"],
        "tired": ["thinking", "idle"],
        "clicked": ["needs attention", "idle"]
    ]

    var availableMascots: [MascotCatalogEntry] {
        availableMascots(matching: "")
    }

    func availableMascots(matching rawQuery: String) -> [MascotCatalogEntry] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let maskoEntries = MascotTemplate.remoteTemplates.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.slug.localizedCaseInsensitiveContains(query)
        }
        let downloadedPetdex = downloadedPetdexEntries().filter {
            query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query)
                || $0.slug.localizedCaseInsensitiveContains(query)
        }
        let searchEntries = petdexSearchResults
            .filter { $0.matches(query) }
            .map(\.catalogEntry)

        var seen = Set<String>()
        var result: [MascotCatalogEntry] = []
        func add(_ entries: [MascotCatalogEntry]) {
            for entry in entries where seen.insert(entry.id).inserted {
                result.append(entry)
            }
        }

        add(maskoEntries)
        if let selectedPetdex = currentPetdexPet?.catalogEntry { add([selectedPetdex]) }
        add(downloadedPetdex)               // previously-downloaded pets, even when not in use
        if !query.isEmpty { add(Array(searchEntries.prefix(160))) }
        return result
    }

    /// Petdex pets that have been downloaded (cached spritesheet on disk),
    /// resolved from saved metadata so they show offline and when not in use.
    func downloadedPetdexEntries() -> [MascotCatalogEntry] {
        let directory = petdexSpritesheetCacheDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }

        var bySlug: [String: MascotCatalogEntry] = [:]
        for file in files where ["webp", "png"].contains(file.pathExtension.lowercased()) {
            let slug = file.deletingPathExtension().lastPathComponent
            let name = loadSavedPetdexMetadata(slug: slug)?.displayName ?? slug
            bySlug[slug] = MascotCatalogEntry(
                slug: slug,
                name: name,
                thumbnailURL: file.absoluteString,   // local file URL renders offline
                source: .petdex
            )
        }
        return bySlug.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var currentTemplateName: String {
        if let currentPetdexPet {
            return currentPetdexPet.displayName
        }
        return template?.name ?? selectedSlug.capitalized
    }

    private init() {
        refreshDownloadedSlugs()
        if Self.petdexSlug(from: selectedSlug) != nil {
            loadCachedPetdexManifest()
        }
        Task {
            await loadTemplate(slug: selectedSlug)
        }
    }

    func selectMascot(_ slug: String) {
        guard slug != selectedSlug else { return }
        selectedSlug = slug
        template = nil
        currentNodeID = nil
        currentLoopVideoURL = nil
        thumbnailURL = nil
        currentPetdexPet = nil
        currentPetdexSpritesheetURL = nil
        Task {
            await loadTemplate(slug: slug)
        }
    }

    func setExpression(_ expression: String) {
        currentExpression = expression
    }

    func setInput(_ name: String, _ value: Any) {
        switch name {
        case "isWorking":
            if let boolValue = value as? Bool, boolValue { setExpression("working") }
        case "isIdle":
            if let boolValue = value as? Bool, boolValue { setExpression("idle") }
        case "isAlert":
            if let boolValue = value as? Bool, boolValue { setExpression("alert") }
        case "clicked":
            setExpression("clicked")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                if self?.currentExpression == "clicked" { self?.setExpression("idle") }
            }
        default:
            break
        }
    }

    // MARK: - Download Management

    func isMascotDownloaded(_ slug: String) -> Bool {
        if let petdexSlug = Self.petdexSlug(from: slug) {
            return localPetdexSpritesheetURL(for: petdexSlug) != nil
        }
        if slug == "otto" { return true } // Bundled
        return downloadedSlugs.contains(slug)
    }

    @discardableResult
    func downloadMascot(_ slug: String) async -> Bool {
        guard !isMascotDownloaded(slug) else { return true }

        if let petdexSlug = Self.petdexSlug(from: slug) {
            return await downloadPetdexPet(slug: petdexSlug)
        }

        do {
            let (decoded, data) = try await fetchTemplate(slug: slug)
            saveCachedTemplate(data: data, slug: slug)

            // Download all loop videos (skip transitions for speed)
            await MascotVideoCache.shared.preloadLoopVideos(for: decoded)

            downloadedSlugs.insert(slug)
            loadError = nil
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    private func refreshDownloadedSlugs() {
        var slugs: Set<String> = ["otto"]
        for entry in MascotTemplate.remoteTemplates {
            if loadCachedTemplate(slug: entry.slug) != nil {
                slugs.insert(entry.slug)
            }
        }
        downloadedSlugs = slugs
    }

    // MARK: - Template Loading

    func loadTemplate(slug: String) async {
        isLoading = true
        loadError = nil

        if let petdexSlug = Self.petdexSlug(from: slug) {
            await loadPetdexPet(slug: petdexSlug)
            isLoading = false
            return
        }

        // Otto: try bundled first
        if slug == "otto", let bundled = loadBundledTemplate() {
            applyTemplate(bundled)
            isLoading = false
            // Preload videos in background
            Task { await MascotVideoCache.shared.preloadLoopVideos(for: bundled) }
            return
        }

        // Try local cache
        if let cached = loadCachedTemplate(slug: slug) {
            applyTemplate(cached)
            isLoading = false
            Task { await MascotVideoCache.shared.preloadLoopVideos(for: cached) }
            return
        }

        // Fetch from API
        await fetchAndCacheTemplate(slug: slug)
        isLoading = false
    }

    private func fetchAndCacheTemplate(slug: String) async {
        do {
            let (decoded, data) = try await fetchTemplate(slug: slug)
            saveCachedTemplate(data: data, slug: slug)
            applyTemplate(decoded)
            downloadedSlugs.insert(slug)
            loadError = nil
            Task { await MascotVideoCache.shared.preloadLoopVideos(for: decoded) }
        } catch {
            if template == nil { loadError = error.localizedDescription }
        }
    }

    private func applyTemplate(_ newTemplate: MascotTemplate) {
        currentPetdexPet = nil
        currentPetdexSpritesheetURL = nil
        template = newTemplate

        let initialNode = newTemplate.node(byID: newTemplate.initialNode) ?? newTemplate.nodes.first
        if let thumb = newTemplate.thumbnail ?? initialNode?.transparentThumbnailUrl,
           let url = URL(string: thumb) {
            thumbnailURL = url
        }
        if let initialNode {
            currentNodeID = initialNode.id
            resolveLoopVideo(for: initialNode.id)
        }

        transitionToNode(forExpression: currentExpression)
    }

    // MARK: - State Machine (instant switching, no transition videos)

    private func transitionToNode(forExpression expression: String) {
        guard let template else { return }

        let candidates = expressionToNodeCandidates[expression] ?? ["idle"]
        guard let targetNode = candidates.lazy.compactMap({ template.node(named: $0) }).first
                ?? template.node(named: "idle")
                ?? template.nodes.first else { return }
        guard targetNode.id != currentNodeID else { return }

        currentNodeID = targetNode.id
        resolveLoopVideo(for: targetNode.id)
    }

    private func resolveLoopVideo(for nodeID: String) {
        guard let template else { return }
        guard let loopEdge = template.loopEdge(for: nodeID),
              let hevcURL = loopEdge.videos?.hevcURL else {
            currentLoopVideoURL = nil
            return
        }

        Task {
            let localURL = try? await MascotVideoCache.shared.ensureCached(remoteURL: hevcURL)
            await MainActor.run {
                self.currentLoopVideoURL = localURL ?? hevcURL
            }
        }
    }

    // MARK: - Bundled Otto

    private func loadBundledTemplate() -> MascotTemplate? {
        guard let url = Bundle.main.url(forResource: "otto", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MascotTemplate.self, from: data)
    }

    // MARK: - Local Cache

    private var templateCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("SuperIsland/MascotTemplates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadCachedTemplate(slug: String) -> MascotTemplate? {
        let file = templateCacheDirectory.appendingPathComponent("\(slug).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return decodeTemplate(from: data, slug: slug)
    }

    private func saveCachedTemplate(data: Data, slug: String) {
        let file = templateCacheDirectory.appendingPathComponent("\(slug).json")
        try? data.write(to: file, options: .atomic)
    }

    private func fetchTemplate(slug: String) async throws -> (MascotTemplate, Data) {
        guard let url = URL(string: "\(MascotTemplate.apiBaseURL)/\(slug)") else {
            throw MascotLoadError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response)
        guard let template = decodeTemplate(from: data, slug: slug) else {
            throw MascotLoadError.invalidTemplate
        }
        return (template, data)
    }

    private func decodeTemplate(from data: Data, slug: String) -> MascotTemplate? {
        // The live API payload no longer includes `slug`, so we preserve the requested slug here.
        (try? JSONDecoder().decode(MascotTemplate.self, from: data))?.resolved(slug: slug)
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw MascotLoadError.httpStatus(httpResponse.statusCode)
        }
    }

    // MARK: - Petdex

    private static let petdexSelectionPrefix = "petdex:"
    private static let petdexManifestURL = URL(string: "https://petdex.dev/api/manifest")!

    private static func petdexSlug(from selectionID: String) -> String? {
        guard selectionID.hasPrefix(petdexSelectionPrefix) else { return nil }
        let slug = selectionID.dropFirst(petdexSelectionPrefix.count)
        return slug.isEmpty ? nil : String(slug)
    }

    private var petdexManifestCacheURL: URL {
        templateCacheDirectory.appendingPathComponent("petdex-manifest.json")
    }

    private var petdexSpritesheetCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("SuperIsland/PetdexSprites", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func petdexMetadataURL(for slug: String) -> URL {
        petdexSpritesheetCacheDirectory.appendingPathComponent("\(slug).pet.json")
    }

    private func savePetdexMetadata(_ pet: PetdexPet) {
        guard let data = try? JSONEncoder().encode(pet) else { return }
        try? data.write(to: petdexMetadataURL(for: pet.slug), options: .atomic)
    }

    private func loadSavedPetdexMetadata(slug: String) -> PetdexPet? {
        guard let data = try? Data(contentsOf: petdexMetadataURL(for: slug)) else { return nil }
        return try? JSONDecoder().decode(PetdexPet.self, from: data)
    }

    /// Removes a downloaded mascot (Petdex spritesheet + metadata, or a cached
    /// masko template). Bundled "otto" cannot be removed. Falls back to otto if
    /// the removed mascot was selected.
    func removeMascot(_ selectionID: String) {
        if let petdexSlug = Self.petdexSlug(from: selectionID) {
            let directory = petdexSpritesheetCacheDirectory
            for ext in ["webp", "png"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(petdexSlug).\(ext)"))
            }
            try? FileManager.default.removeItem(at: petdexMetadataURL(for: petdexSlug))
        } else {
            guard selectionID != "otto" else { return }
            try? FileManager.default.removeItem(at: templateCacheDirectory.appendingPathComponent("\(selectionID).json"))
            downloadedSlugs.remove(selectionID)
        }

        if selectedSlug == selectionID {
            selectMascot("otto")
        }
        objectWillChange.send()
    }

    private func loadCachedPetdexManifest() {
        guard let data = try? Data(contentsOf: petdexManifestCacheURL),
              let manifest = try? JSONDecoder().decode(PetdexManifest.self, from: data) else {
            return
        }
        petdexPets = manifest.pets
    }

    func loadPetdexManifest(force: Bool = false) async {
        if isLoadingPetdexManifest { return }
        if !force, !petdexPets.isEmpty { return }

        isLoadingPetdexManifest = true
        defer { isLoadingPetdexManifest = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: Self.petdexManifestURL)
            try validate(response: response)
            let manifest = try JSONDecoder().decode(PetdexManifest.self, from: data)
            try? data.write(to: petdexManifestCacheURL, options: .atomic)
            petdexPets = manifest.pets
        } catch {
            if petdexPets.isEmpty {
                loadError = error.localizedDescription
            }
        }
    }

    func searchPetdex(query rawQuery: String) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            petdexSearchResults = []
            petdexSearchMessage = nil
            return
        }

        if isSearchingPetdex { return }
        isSearchingPetdex = true
        petdexSearchMessage = nil
        defer { isSearchingPetdex = false }

        if petdexPets.isEmpty {
            loadCachedPetdexManifest()
        }
        if petdexPets.isEmpty {
            await loadPetdexManifest()
        }

        guard !petdexPets.isEmpty else {
            petdexSearchResults = []
            petdexSearchMessage = "Petdex search is unavailable."
            return
        }

        let matches = petdexPets.filter { $0.matches(query) }
        petdexSearchResults = Array(matches.prefix(160))
        if matches.isEmpty {
            petdexSearchMessage = "No Petdex matches."
        } else if matches.count > petdexSearchResults.count {
            petdexSearchMessage = "Showing \(petdexSearchResults.count) of \(matches.count) Petdex matches."
        } else {
            petdexSearchMessage = "Showing \(matches.count) Petdex matches."
        }
    }

    private func petdexPet(slug: String) -> PetdexPet? {
        petdexPets.first(where: { $0.slug == slug })
    }

    private func loadPetdexPet(slug: String) async {
        if petdexPets.isEmpty {
            await loadPetdexManifest(force: true)
        }

        if let pet = petdexPet(slug: slug) {
            applyPetdexPet(pet)
            return
        }

        // Offline / manifest-unavailable: use the metadata saved at download time.
        if let pet = loadSavedPetdexMetadata(slug: slug) {
            applyPetdexPet(pet)
            return
        }

        loadError = "Petdex pet not found: \(slug)"
    }

    private func applyPetdexPet(_ pet: PetdexPet) {
        template = nil
        currentNodeID = nil
        currentLoopVideoURL = nil
        thumbnailURL = URL(string: pet.spritesheetUrl)
        currentPetdexPet = pet
        currentPetdexSpritesheetURL = localPetdexSpritesheetURL(for: pet.slug) ?? URL(string: pet.spritesheetUrl)
        loadError = nil
    }

    private func localPetdexSpritesheetURL(for slug: String) -> URL? {
        let directory = petdexSpritesheetCacheDirectory
        for ext in ["webp", "png"] {
            let url = directory.appendingPathComponent("\(slug).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func downloadPetdexPet(slug: String) async -> Bool {
        if petdexPets.isEmpty {
            await loadPetdexManifest(force: true)
        }
        guard let pet = petdexPet(slug: slug),
              let url = URL(string: pet.spritesheetUrl) else {
            loadError = "Petdex pet not found: \(slug)"
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try validate(response: response)
            let ext = url.pathExtension.isEmpty ? "webp" : url.pathExtension
            let destination = petdexSpritesheetCacheDirectory.appendingPathComponent("\(slug).\(ext)")
            try data.write(to: destination, options: .atomic)
            savePetdexMetadata(pet)
            if selectedSlug == pet.catalogEntry.id {
                applyPetdexPet(pet)
            }
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }
}

private enum MascotLoadError: LocalizedError {
    case invalidURL
    case invalidTemplate
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Couldn't build the mascot download URL."
        case .invalidTemplate:
            return "The mascot template response couldn't be read."
        case .httpStatus(let statusCode):
            return "The mascot service returned HTTP \(statusCode)."
        }
    }
}
