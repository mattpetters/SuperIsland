import AppKit
import Foundation
import SwiftUI

struct PetdexManifest: Codable {
    let generatedAt: String?
    let total: Int?
    let pets: [PetdexPet]
}

struct PetdexPet: Codable, Equatable, Identifiable {
    let slug: String
    let displayName: String
    let kind: String?
    let submittedBy: String?
    let spritesheetUrl: String
    let petJsonUrl: String?
    let zipUrl: String?

    var id: String { slug }

    var catalogEntry: MascotCatalogEntry {
        MascotCatalogEntry(
            slug: slug,
            name: displayName,
            thumbnailURL: spritesheetUrl,
            source: .petdex
        )
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let haystack = [
            slug,
            displayName,
            kind ?? "",
            submittedBy ?? ""
        ].joined(separator: " ").lowercased()
        return haystack.contains(query.lowercased())
    }
}

enum PetdexSpriteState: Int {
    case idle = 0
    case wave = 1
    case run = 2
    case failed = 3
    case review = 4
    case jump = 5

    static func from(expression: String) -> PetdexSpriteState {
        switch expression {
        case "working":
            return .run
        case "alert":
            return .failed
        case "happy":
            return .wave
        case "tired":
            return .review
        case "clicked":
            return .jump
        default:
            return .idle
        }
    }
}

struct PetdexSpriteMascotView: View {
    let url: URL
    let size: Double
    let expression: String
    var animated = true

    @State private var frameRows: [[NSImage]] = []

    var body: some View {
        Group {
            if animated {
                TimelineView(.periodic(from: .now, by: PetdexSpriteLoader.frameDuration)) { timeline in
                    renderedFrame(at: timeline.date)
                }
            } else {
                renderedFrame(at: nil)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            frameRows = await PetdexSpriteFrameCache.shared.frames(from: url)
        }
    }

    @ViewBuilder
    private func renderedFrame(at date: Date?) -> some View {
        let row = min(PetdexSpriteState.from(expression: expression).rawValue, max(0, frameRows.count - 1))
        if frameRows.indices.contains(row), !frameRows[row].isEmpty {
            let frameCount = min(6, frameRows[row].count)
            let frameIndex = date.map { Int($0.timeIntervalSinceReferenceDate / PetdexSpriteLoader.frameDuration) % frameCount } ?? 0
            Image(nsImage: frameRows[row][frameIndex])
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Color.clear
        }
    }
}

actor PetdexSpriteFrameCache {
    static let shared = PetdexSpriteFrameCache()

    private var cachedFrames: [URL: [[NSImage]]] = [:]

    func frames(from url: URL) async -> [[NSImage]] {
        if let frames = cachedFrames[url] {
            return frames
        }

        let frames = await PetdexSpriteLoader.loadFrames(from: url)
        cachedFrames[url] = frames
        return frames
    }
}

enum PetdexSpriteLoader {
    static let frameDuration = 1.1 / 6.0

    static func loadFrames(from url: URL) async -> [[NSImage]] {
        guard let image = await loadImage(from: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        // Petdex sheets are 8 columns by 9 rows; the first 8 rows map to named states.
        let columns = 8
        let totalRows = 9
        let stateRows = 8
        let frameWidth = cgImage.width / columns
        let frameHeight = cgImage.height / totalRows
        guard frameWidth > 0, frameHeight > 0 else { return [] }

        return (0..<stateRows).map { row in
            (0..<columns).compactMap { column in
                let rect = CGRect(
                    x: column * frameWidth,
                    y: row * frameHeight,
                    width: frameWidth,
                    height: frameHeight
                )
                guard let cropped = cgImage.cropping(to: rect) else { return nil }
                return NSImage(cgImage: cropped, size: NSSize(width: frameWidth, height: frameHeight))
            }
        }
    }

    private static func loadImage(from url: URL) async -> NSImage? {
        if url.isFileURL {
            return NSImage(contentsOf: url)
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }
}
