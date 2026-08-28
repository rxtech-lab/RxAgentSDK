import Foundation
import FoundationModels
import RxAgentCore

/// Converts a `GenerationSchema` into a plain JSON Schema object suitable for
/// an MCP `tools/list` response.
///
/// `GenerationSchema` is `Codable` and encodes to real JSON Schema, plus two
/// FoundationModels-specific keys that no MCP client understands:
///
/// - `title` — the Swift type name of the arguments struct (`_SmokeArgs`),
///   which leaks an implementation detail into the agent's view of the tool.
/// - `x-order` — property ordering used for guided generation.
///
/// Both are stripped, recursively, so nested object schemas come out clean too.
public enum JSONSchemaExporter {
    /// Keys emitted by FoundationModels that aren't part of JSON Schema.
    static let strippedKeys: Set<String> = ["title", "x-order"]

    public static func export(_ schema: GenerationSchema) -> JSONValue {
        guard let data = try? JSONEncoder().encode(schema),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return emptyObjectSchema
        }
        return strip(decoded)
    }

    /// An `object` schema with no properties — the shape a zero-argument tool
    /// should advertise.
    public static let emptyObjectSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    private static func strip(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields):
            var result: [String: JSONValue] = [:]
            for (key, nested) in fields where !strippedKeys.contains(key) {
                result[key] = strip(nested)
            }
            return .object(result)
        case .array(let items):
            return .array(items.map(strip))
        default:
            return value
        }
    }
}
