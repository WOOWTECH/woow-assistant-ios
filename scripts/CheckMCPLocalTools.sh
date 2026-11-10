#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mcp_local_build=$(mktemp -d "${TMPDIR:-/tmp}/woow-mcp-local.XXXXXX")
trap 'rm -rf "$mcp_local_build"' EXIT
swiftc -swift-version 5 -warnings-as-errors -emit-module -emit-library -enable-testing \
  -module-name AssistantModels Sources/AssistantModels/*.swift \
  -o "$mcp_local_build/libAssistantModels.dylib" \
  -emit-module-path "$mcp_local_build/AssistantModels.swiftmodule"
swiftc -swift-version 5 -warnings-as-errors -emit-module -emit-library -enable-testing \
  -module-name AssistantMCP -I "$mcp_local_build" -L "$mcp_local_build" -lAssistantModels \
  Sources/AssistantMCP/*.swift -o "$mcp_local_build/libAssistantMCP.dylib" \
  -emit-module-path "$mcp_local_build/AssistantMCP.swiftmodule"
swiftc -swift-version 5 -warnings-as-errors -D MCP_LOCAL_STANDALONE -parse-as-library \
  -I "$mcp_local_build" -L "$mcp_local_build" -lAssistantModels -lAssistantMCP \
  -Xlinker -rpath -Xlinker "$mcp_local_build" \
  Tests/AssistantMCPTests/MCPLocalToolsTests.swift -o "$mcp_local_build/local-checks"
"$mcp_local_build/local-checks"
# The CLT-only host lacks XCTest. Parse the wrapper there, and typecheck it
# when a real XCTest module is available. Never substitute a fake XCTest API.
swiftc -frontend -parse Tests/AssistantMCPTests/MCPLocalToolsTests.swift
printf 'import XCTest\n' > "$mcp_local_build/XCTestProbe.swift"
if swiftc -typecheck "$mcp_local_build/XCTestProbe.swift" > "$mcp_local_build/xctest-probe.log" 2>&1; then
  swiftc -swift-version 5 -warnings-as-errors -typecheck -I "$mcp_local_build" \
    Tests/AssistantMCPTests/MCPLocalToolsTests.swift
  printf 'XCTest wrapper typecheck passed; native execution still requires CI.\n'
else
  printf 'XCTest unavailable in this toolchain: wrapper syntax parsed; native typecheck/execution required in CI.\n'
fi
# Preserve the existing real transport fixture and remote conversation checks.
swiftc -swift-version 5 -warnings-as-errors -D MCP_SMOKE -parse-as-library \
  -I "$mcp_local_build" -L "$mcp_local_build" -lAssistantModels \
  -Xlinker -rpath -Xlinker "$mcp_local_build" Sources/AssistantMCP/*.swift \
  Tests/AssistantMCPTests/MCPProtocolFixture.swift Tests/AssistantMCPTests/MCPClientChecks.swift \
  Tests/AssistantMCPTests/MCPConversationChecks.swift Tests/AssistantMCPTests/MCPCommandCorrectionChecks.swift \
  Tests/AssistantMCPTests/MCPClientTests.swift -o "$mcp_local_build/remote-checks"
"$mcp_local_build/remote-checks"
bash scripts/CheckUserProfileChatFlow.sh
