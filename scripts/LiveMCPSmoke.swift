import AssistantMCP
import Foundation

/// Actual HA acceptance, manual-only. No endpoint, household values, entity IDs,
/// server-provided descriptions or raw errors may be written to logs/artifacts.
@main
struct LiveMCPSmoke {
    static func main() async {
        #if !targetEnvironment(simulator) && !MCP_LOCAL_PROBE
        print("FAIL: live acceptance must run inside iOS Simulator")
        exit(1)
        #else
        #if MCP_LOCAL_PROBE
        print("LOCAL macOS native client probe; this is NOT an iOS Simulator acceptance run")
        #endif
        guard let raw = ProcessInfo.processInfo.environment["WOOW_HA_MCP_TEST_URL"],
              let endpoint = URL(string: raw) else {
            print("FAIL: missing private MCP test configuration")
            exit(1)
        }
        let client = MCPClient(endpoint: endpoint)
        do {
            let info = try await client.initialize()
            guard info.capabilities.contains("tools") else { throw CheckError.failed }
            print("PASS: native MCP initialize + initialized notification")
            try await client.ping()
            print("PASS: native MCP ping")
            let tools = try await client.listTools()
            guard !tools.isEmpty else { throw CheckError.failed }
            print("PASS: native tools discovery; count=\(tools.count)")
            let resources = try await client.listResources()
            let prompts = try await client.listPrompts()
            let templates = try await client.listResourceTemplates()
            print("PASS: native catalogs; resources=\(resources.count), prompts=\(prompts.count), templates=\(templates.count)")
            let cases: [(String, JSONValue)] = [
                ("ha_get_overview", .object([:])),
                ("ha_list_floors_areas", .object([:])),
                ("ha_list_services", .object(["limit": .number(3)])),
                ("ha_search", .object(["query": .string("sensor"), "limit": .number(3), "include_config": .bool(false)])),
                ("ha_get_skill_guide", .object([:])),
                ("ha_config_get_dashboard", .object(["list_only": .bool(true), "include_config": .bool(false), "include_screenshot": .bool(false)])),
                ("ha_eval_template", .object(["template": .string("{{ 1 + 1 }}")]))
            ]
            let available = Set(tools.map(\.name))
            let allowlist = Set(cases.map(\.0)).union(["ha_get_state"])
            var entity: String?
            for (name, arguments) in cases {
                guard available.contains(name) else { throw CheckError.failed }
                let result = try await client.callReadOnlyTool(name: name, arguments: arguments, allowlist: allowlist)
                try assertSuccess(result)
                if name == "ha_search" || name == "ha_get_overview" {
                    entity = entity ?? findEntity(in: result["structuredContent"] ?? .null)
                }
                print("PASS: native read-only tool \(name)")
            }
            guard let entity = entity, available.contains("ha_get_state") else { throw CheckError.failed }
            let state = try await client.callReadOnlyTool(name: "ha_get_state", arguments: .object(["entity_id": .string(entity)]), allowlist: allowlist)
            try assertSuccess(state)
            print("PASS: native discovered-entity state read; target/value redacted")
            let invalid = try await client.callReadOnlyTool(name: "ha_get_state", arguments: .object(["entity_id": .string("sensor.woow_validation_nonexistent")]), allowlist: allowlist)
            guard invalid["isError"] == .bool(true) else { throw CheckError.failed }
            print("PASS: native tool business error preserved")
            do {
                _ = try await client.callReadOnlyTool(name: "ha_call_service", arguments: .object([:]), allowlist: allowlist)
                throw CheckError.failed
            } catch MCPError.toolNotAllowed {
                print("PASS: unapproved mutation blocked locally before network")
            }
            if let guide = resources.first(where: {
                let label = ($0.name + " " + $0.uri).lowercased()
                return ["guide", "best_practice", "best-practice", "skill"].contains(where: label.contains)
            }) {
                let content = try await client.readResource(uri: guide.uri)
                guard case .array(let blocks)? = content["contents"], !blocks.isEmpty else { throw CheckError.failed }
                print("PASS: native documentation resource read; body redacted")
            } else { throw CheckError.failed }
            print("PASS: live native MCP acceptance; mutation calls sent=0")
        } catch {
            // Only client-owned enums have safe descriptions. Never print server data.
            if let safe = error as? MCPError {
                print("FAIL: native MCP acceptance; \(safe.localizedDescription)")
            } else { print("FAIL: native MCP acceptance assertion") }
            exit(1)
        }
        #endif
    }

    static func assertSuccess(_ result: JSONValue) throws {
        guard result["isError"] != .bool(true),
              case .array(let content)? = result["content"], !content.isEmpty else { throw CheckError.failed }
    }

    static func findEntity(in value: JSONValue) -> String? {
        switch value {
        case .object(let object):
            if let id = object["entity_id"]?.stringValue, id.contains(".") { return id }
            for child in object.values { if let id = findEntity(in: child) { return id } }
        case .array(let array):
            for child in array { if let id = findEntity(in: child) { return id } }
        default: break
        }
        return nil
    }

    enum CheckError: Error { case failed }
}
