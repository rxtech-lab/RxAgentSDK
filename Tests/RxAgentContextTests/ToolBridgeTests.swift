import Foundation
import FoundationModels
import Testing
import RxAgentCore
@testable import RxAgentContext

// MARK: - Fixtures written exactly the way a user would write them

@Generable
struct GrepArgs {
    @Guide(description: "Regex to search for")
    var pattern: String
    @Guide(description: "Glob restricting the search")
    var include: String?
}

struct GrepTool: FoundationModels.Tool {
    let name = "grep_workspace"
    let description = "Search the open workspace for a regex."

    func call(arguments: GrepArgs) async throws -> String {
        "matched \(arguments.pattern) in \(arguments.include ?? "**")"
    }
}

@Generable
struct EmptyArgs {}

struct NoArgTool: FoundationModels.Tool {
    let name = "ping"
    let description = "Returns pong."
    func call(arguments: EmptyArgs) async throws -> String { "pong" }
}

@Generable
struct Report {
    var summary: String
    var count: Int
}

struct ReportTool: FoundationModels.Tool {
    let name = "report"
    let description = "Produce a structured report."
    func call(arguments: EmptyArgs) async throws -> Report {
        Report(summary: "all good", count: 3)
    }
}

struct ThrowingTool: FoundationModels.Tool {
    struct Boom: Error, CustomStringConvertible { var description: String { "tool exploded" } }
    let name = "explode"
    let description = "Always throws."
    func call(arguments: EmptyArgs) async throws -> String { throw Boom() }
}

private let noContext = AgentToolContext(
    threadID: AgentThreadID(),
    workingDirectory: URL(filePath: "/tmp")
)

// MARK: - Schema export

@Suite("JSONSchemaExporter")
struct JSONSchemaExporterTests {

    @Test("Exports a JSON Schema object with properties and required")
    func exportsJSONSchema() {
        let schema = JSONSchemaExporter.export(GrepTool().parameters)
        #expect(schema["type"]?.stringValue == "object")

        let properties = try! #require(schema["properties"]?.objectValue)
        #expect(properties["pattern"]?["type"]?.stringValue == "string")
        #expect(properties["pattern"]?["description"]?.stringValue == "Regex to search for")

        let required = try! #require(schema["required"]?.arrayValue).compactMap(\.stringValue)
        #expect(required.contains("pattern"))
        #expect(!required.contains("include"), "optionals must not be required")
    }

    /// `title` is the Swift type name and `x-order` is a guided-generation
    /// detail; neither belongs in a schema shown to an external agent.
    @Test("Strips FoundationModels-only keys, recursively")
    func stripsNonStandardKeys() {
        let schema = JSONSchemaExporter.export(GrepTool().parameters)
        #expect(schema["title"] == nil)
        #expect(schema["x-order"] == nil)
        #expect(!schema.jsonString.contains("x-order"))
        #expect(!schema.jsonString.contains("GrepArgs"))
    }

    @Test("A zero-argument tool exports an empty object schema")
    func emptySchema() {
        let schema = JSONSchemaExporter.export(NoArgTool().parameters)
        #expect(schema["type"]?.stringValue == "object")
    }
}

// MARK: - Erasure round trip

@Suite("AnyAgentTool")
struct AnyAgentToolTests {

    @Test("Name, description and schema carry through erasure")
    func metadataCarriesThrough() {
        let erased = AnyAgentTool.tool(GrepTool())
        #expect(erased.name == "grep_workspace")
        #expect(erased.description == "Search the open workspace for a regex.")
        #expect(erased.id == "grep_workspace")
        #expect(erased.inputSchema["type"]?.stringValue == "object")
    }

    @Test("JSON arguments decode into the Generable struct and the tool runs")
    func roundTrip() async {
        let erased = AnyAgentTool.tool(GrepTool())
        let result = await erased.call(
            .object(["pattern": .string("TODO"), "include": .string("*.swift")]),
            context: noContext
        )
        #expect(result == .text("matched TODO in *.swift"))
    }

    @Test("Omitted optional arguments decode as nil")
    func optionalArgument() async {
        let erased = AnyAgentTool.tool(GrepTool())
        let result = await erased.call(.object(["pattern": .string("FIXME")]), context: noContext)
        #expect(result == .text("matched FIXME in **"))
    }

    /// `generatedContent.jsonString` on a String output yields `"pong"` with the
    /// quotes included; leaking those into every tool result would be wrong.
    @Test("String output is unquoted")
    func stringOutputIsNotJSONQuoted() async {
        let erased = AnyAgentTool.tool(NoArgTool())
        let result = await erased.call(.object([:]), context: noContext)
        #expect(result == .text("pong"))
        #expect(!result.content.hasPrefix("\""))
    }

    @Test("Structured output is serialized as JSON")
    func structuredOutput() async {
        let erased = AnyAgentTool.tool(ReportTool())
        let result = await erased.call(.object([:]), context: noContext)
        #expect(result.content.contains("all good"))
        #expect(result.content.contains("3"))
    }

    /// A misbehaving tool must report back to the agent, not tear down the turn.
    @Test("A thrown error becomes an error result")
    func thrownErrorBecomesResult() async {
        let erased = AnyAgentTool.tool(ThrowingTool())
        let result = await erased.call(.object([:]), context: noContext)
        #expect(result.isError)
        #expect(result.content.contains("exploded"))
    }

    @Test("Malformed arguments produce an error result, not a crash")
    func malformedArguments() async {
        let erased = AnyAgentTool.tool(GrepTool())
        // `pattern` is required and missing.
        let result = await erased.call(.object(["include": .string("*.swift")]), context: noContext)
        #expect(result.isError)
    }

    @Test("A dynamic tool can be declared without FoundationModels")
    func dynamicTool() async {
        let tool = AnyAgentTool.dynamic(
            name: "echo",
            description: "Echo the input.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["text": .object(["type": .string("string")])]),
            ])
        ) { arguments, _ in
            .text(arguments["text"]?.stringValue ?? "")
        }

        let result = await tool.call(.object(["text": .string("hi")]), context: noContext)
        #expect(result == .text("hi"))
    }
}
