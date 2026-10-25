import AppIntents
import Foundation
import WidgetKit

/// Widget instance choices use the same stable IDs as the shared composition.
/// None is a real entity so clearing a slot never requests a replacement module.
struct WidgetModuleEntity: AppEntity, Hashable {
    let id: String
    let title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Widget Module"
    static var defaultQuery = WidgetModuleQuery()
    static var none: Self { Self(id: WidgetModuleCatalog.noneID, title: "None") }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(_ option: WidgetModuleOption) {
        let title = option.workspaceID == nil ? option.title : "\(option.provider.displayName) · \(option.title)"
        self.init(id: option.id, title: title)
    }

    static func unavailable(id: String) -> Self? {
        if id.hasPrefix(WidgetModuleCatalog.workspacePrefix),
           !id.dropFirst(WidgetModuleCatalog.workspacePrefix.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self(id: id, title: "Unavailable Codex workspace")
        }
        if let provider = MeterProvider.allCases.first(where: { "service:\($0.rawValue)" == id }) {
            return Self(id: id, title: "\(provider.displayName) · Unavailable")
        }
        return nil
    }
}

struct WidgetModuleQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetModuleEntity] {
        Self.resolve(identifiers, options: options())
    }

    static func resolve(_ identifiers: [String], options: [WidgetModuleOption]) -> [WidgetModuleEntity] {
        let available = Dictionary(uniqueKeysWithValues: options.map { ($0.id, WidgetModuleEntity($0)) })
        return identifiers.compactMap { id in
            if id == WidgetModuleCatalog.noneID { return WidgetModuleEntity.none }
            // A disappeared workspace keeps its identity in the saved intent.
            // Returning a placeholder stops WidgetKit from replacing the choice.
            return available[id] ?? WidgetModuleEntity.unavailable(id: id)
        }
    }

    func suggestedEntities() async throws -> [WidgetModuleEntity] {
        [.none] + options().map(WidgetModuleEntity.init)
    }

    private func options() -> [WidgetModuleOption] {
        let demo = Bundle.main.object(forInfoDictionaryKey: "BeaverMeterInteractionDemo") as? Bool == true
        let snapshot: UsageSnapshot = demo ? .preview : .load()
        let settings: ProviderSettings = demo ? .default : .load()
        return WidgetModuleCatalog.available(snapshot: snapshot, providers: settings.visibleProviders(in: snapshot))
    }
}

struct WidgetModuleIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose Widget Modules"
    static var description = IntentDescription("Choose services or Codex workspaces in display order. A module includes its quota windows.")

    @Parameter(title: "Primary Module 1")
    var module1: WidgetModuleEntity?

    @Parameter(title: "Primary Module 2")
    var module2: WidgetModuleEntity?

    @Parameter(title: "Module 3")
    var module3: WidgetModuleEntity?

    @Parameter(title: "Module 4")
    var module4: WidgetModuleEntity?

    @Parameter(title: "Module 5")
    var module5: WidgetModuleEntity?

    @Parameter(title: "Module 6")
    var module6: WidgetModuleEntity?

    /// Recommended widgets save the displayed defaults as actual editor choices.
    /// Empty slots are explicit None; legacy instances keep their all-nil fallback.
    static func defaultConfiguration(snapshot: UsageSnapshot, providers: [MeterProvider]) -> Self {
        let options = WidgetModuleCatalog.available(snapshot: snapshot, providers: providers)
        let defaults = WidgetModuleCatalog.defaults(snapshot: snapshot, providers: providers)
        let entities = WidgetModuleQuery.resolve(defaults, options: options)
        let slots = Array(entities.prefix(6)) + Array(repeating: WidgetModuleEntity.none, count: max(0, 6 - entities.count))
        let intent = Self()
        intent.module1 = slots[0]
        intent.module2 = slots[1]
        intent.module3 = slots[2]
        intent.module4 = slots[3]
        intent.module5 = slots[4]
        intent.module6 = slots[5]
        return intent
    }

    static var parameterSummary: some ParameterSummary {
        Switch(.widgetFamily) {
            Case(.systemSmall) {
                Summary {
                    \.$module1
                    \.$module2
                }
            }
            Case(.systemMedium) {
                Summary {
                    \.$module1
                    \.$module2
                    \.$module3
                    \.$module4
                }
            }
            DefaultCase {
                Summary {
                    \.$module1
                    \.$module2
                    \.$module3
                    \.$module4
                    \.$module5
                    \.$module6
                }
            }
        }
    }

    /// All nil means a legacy/unconfigured widget and uses shared defaults.
    /// Once any slot is selected, including None, empty slots stay empty.
    func selectedModuleIDs(for family: WidgetFamily) -> [String]? {
        let slots = [module1, module2, module3, module4, module5, module6]
        guard slots.contains(where: { $0 != nil }) else { return nil }
        let limit: Int
        switch family {
        case .systemSmall: limit = 2
        case .systemMedium: limit = 4
        default: limit = 6
        }
        var seen: Set<String> = []
        return slots.prefix(limit).compactMap { $0?.id }.filter {
            $0 != WidgetModuleCatalog.noneID && seen.insert($0).inserted
        }
    }
}
