import Foundation
import AppKit

enum ActiveModule: Equatable, Hashable {
    case builtIn(ModuleType)
    case extension_(String)

    /// Stable, persistable key for ordering (matches HomeWidgetSelection.rawValue).
    var orderKey: String {
        switch self {
        case .builtIn(let module): return "builtIn.\(module.rawValue)"
        case .extension_(let id): return "extension.\(id)"
        }
    }

    @MainActor
    var displayName: String {
        switch self {
        case .builtIn(let module):
            return module.displayName
        case .extension_(let id):
            return ExtensionManager.shared.installed.first(where: { $0.id == id })?.name ?? id
        }
    }

    @MainActor
    var iconName: String {
        switch self {
        case .builtIn(let module):
            return module.iconName
        case .extension_:
            return "puzzlepiece.extension"
        }
    }

    @MainActor
    var iconImage: NSImage? {
        switch self {
        case .builtIn:
            return nil
        case .extension_(let id):
            return ExtensionManager.shared.installed.first(where: { $0.id == id })?.iconImage
        }
    }

    /// An SF Symbol suitable for small/compact UI (island tab strip, order
    /// list). Built-ins always have one; extensions only if their manifest
    /// declares `symbol`. When nil, callers fall back to `iconImage`.
    @MainActor
    var compactSymbol: String? {
        switch self {
        case .builtIn(let module):
            return module.iconName
        case .extension_(let id):
            let symbol = ExtensionManager.shared.installed.first(where: { $0.id == id })?.symbol
            return (symbol?.isEmpty == false) ? symbol : nil
        }
    }
}
