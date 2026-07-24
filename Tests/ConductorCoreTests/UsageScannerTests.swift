import XCTest
@testable import ConductorCore
#if canImport(SQLite3)
import SQLite3
#endif

final class UsageScannerTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testClaudeAggregationAndDedup() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let proj = claude.appendingPathComponent("-Users-test")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)

        // 两行：同一条 assistant 消息（相同 id+requestId）应只计一次；另一条不同 id 正常计。
        let cwdLine = #"{"type":"user","cwd":"/Users/test/proj-a","message":{"role":"user"}}"#
        let line1 = #"{"type":"assistant","timestamp":"2026-06-08T10:00:00.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-4-7","role":"assistant","usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":50,"cache_read_input_tokens":1000}}}"#
        let line1dup = line1   // 重复行
        let line2 = #"{"type":"assistant","timestamp":"2026-06-08T11:00:00.000Z","requestId":"req_2","message":{"id":"msg_2","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let content = [cwdLine, line1, line1dup, line2].joined(separator: "\n") + "\n"
        try content.write(to: proj.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        // 去重后：opus 100/200/50/1000，sonnet 10/20/0/0
        XCTAssertEqual(report.grand.inputTokens, 110)
        XCTAssertEqual(report.grand.outputTokens, 220)
        XCTAssertEqual(report.grand.cacheCreationTokens, 50)
        XCTAssertEqual(report.grand.cacheReadTokens, 1000)
        XCTAssertEqual(report.grand.requestCount, 2)
        XCTAssertEqual(report.sourceInfo?.source, .directScan)

        // 成本：opus($5/$25/$6.25/$0.50) + sonnet($3/$15)
        // opus = (100*5 + 200*25 + 50*6.25 + 1000*0.5)/1e6 = (500+5000+312.5+500)/1e6
        // sonnet = (10*3 + 20*15)/1e6 = (30+300)/1e6
        let opusCost = 500.0 + 5_000.0 + 312.5 + 500.0
        let sonnetCost = 30.0 + 300.0
        let expected = (opusCost + sonnetCost) / 1_000_000
        XCTAssertEqual(report.grand.costUSD, expected, accuracy: 1e-9)

        XCTAssertEqual(report.byModel.count, 2)
        XCTAssertEqual(report.byDay.count, 1)
        XCTAssertEqual(report.byDay.first?.day, "2026-06-08")
        XCTAssertEqual(report.byMonth.count, 1)
        XCTAssertEqual(report.byMonth.first?.month, "2026-06")
        XCTAssertEqual(report.byMonth.first?.totals.inputTokens, 110)
        XCTAssertEqual(report.byMonth.first?.totals.requestCount, 2)
        XCTAssertEqual(report.bySession.count, 1)
        XCTAssertEqual(report.bySession.first?.session, "s1")
        XCTAssertEqual(report.bySession.first?.source, .claude)
        XCTAssertEqual(report.bySession.first?.lastActivity, "2026-06-08")
        XCTAssertEqual(report.bySession.first?.totals.requestCount, 2)
        XCTAssertEqual(report.bySource[.claude]?.inputTokens, 110)
        XCTAssertEqual(report.byDay.first?.modelBreakdowns.map(\.model), ["claude-opus-4-7", "claude-sonnet-4-6"])
        XCTAssertEqual(report.byDay.first?.modelBreakdowns.first?.source, .claude)
        XCTAssertEqual(report.byDay.first?.modelBreakdowns.first?.totals.cacheReadTokens, 1000)

        // 每日按来源细分 + 项目维度
        XCTAssertEqual(report.byDay.first?.bySource[.claude]?.inputTokens, 110)
        XCTAssertEqual(report.byDay.first?.bySource[.claude]?.requestCount, 2)
        XCTAssertEqual(report.byProject.count, 1)
        XCTAssertEqual(report.byProject.first?.path, "/Users/test/proj-a")
        XCTAssertEqual(report.byProject.first?.totals.inputTokens, 110)
        XCTAssertEqual(report.byProject.first?.totals.requestCount, 2)
        XCTAssertEqual(report.byProject.first?.bySource[.claude]?.inputTokens, 110)
        XCTAssertEqual(report.sessionsBySource[.claude], 1)
    }

    func testClaudeOneHourCacheCreationUsesInputDoubleRate() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let proj = claude.appendingPathComponent("-Users-cache-1h")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)

        let line = #"{"type":"assistant","timestamp":"2026-06-08T10:00:00.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":70,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_1h_input_tokens":40}}}}"#
        try (line + "\n").write(to: proj.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 100)
        XCTAssertEqual(report.grand.outputTokens, 200)
        XCTAssertEqual(report.grand.cacheCreationTokens, 70)
        XCTAssertEqual(report.grand.cacheReadTokens, 30)
        // Sonnet: input $3/M, output $15/M, cache read $0.30/M.
        // 30 cache-create tokens use 5m write rate $3.75/M; 40 use 1h rate = input*2 = $6/M.
        let inputCost = 100.0 * 3.0
        let outputCost = 200.0 * 15.0
        let cacheCreateFiveMinuteCost = 30.0 * 3.75
        let cacheCreateOneHourCost = 40.0 * 6.0
        let cacheReadCost = 30.0 * 0.30
        let expected = (
            inputCost + outputCost + cacheCreateFiveMinuteCost + cacheCreateOneHourCost + cacheReadCost
        ) / 1_000_000
        XCTAssertEqual(report.grand.costUSD, expected, accuracy: 1e-12)
    }

    func testClaudeCrossFileDedupPrefersParentOverSidechainSubagent() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let project = claude.appendingPathComponent("-Users-cross-file", isDirectory: true)
        let subagents = project.appendingPathComponent("session-cross/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)

        let parent = #"{"type":"assistant","timestamp":"2026-06-08T10:00:00.000Z","sessionId":"session-cross","requestId":"req_overlap","isSidechain":false,"message":{"id":"msg_overlap","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":100,"output_tokens":30,"cache_creation_input_tokens":20,"cache_read_input_tokens":10}}}"#
        let compact = #"{"type":"assistant","timestamp":"2026-06-08T10:00:01.000Z","sessionId":"session-cross","requestId":"req_overlap","isSidechain":true,"message":{"id":"msg_overlap","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":900,"output_tokens":300,"cache_creation_input_tokens":200,"cache_read_input_tokens":100}}}"#
        let uniqueSidechain = #"{"type":"assistant","timestamp":"2026-06-08T10:00:02.000Z","sessionId":"session-cross","requestId":"req_unique","isSidechain":true,"message":{"id":"msg_unique","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":70,"output_tokens":20,"cache_creation_input_tokens":5,"cache_read_input_tokens":0}}}"#
        try (parent + "\n").write(to: project.appendingPathComponent("session-cross.jsonl"), atomically: true, encoding: .utf8)
        try ([compact, uniqueSidechain].joined(separator: "\n") + "\n")
            .write(to: subagents.appendingPathComponent("agent-a.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 170)
        XCTAssertEqual(report.grand.outputTokens, 50)
        XCTAssertEqual(report.grand.cacheCreationTokens, 25)
        XCTAssertEqual(report.grand.cacheReadTokens, 10)
        XCTAssertEqual(report.grand.requestCount, 2)
    }

    func testClaudeSameFileStreamingUsesLastCumulativeRow() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let project = claude.appendingPathComponent("-Users-streaming", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let first = #"{"type":"assistant","timestamp":"2026-06-08T10:00:00.000Z","requestId":"req_stream","isSidechain":false,"message":{"id":"msg_stream","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":1}}}"#
        let final = #"{"type":"assistant","timestamp":"2026-06-08T10:00:01.000Z","requestId":"req_stream","isSidechain":false,"message":{"id":"msg_stream","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":40,"output_tokens":20,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}"#
        try ([first, final].joined(separator: "\n") + "\n")
            .write(to: project.appendingPathComponent("stream.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 40)
        XCTAssertEqual(report.grand.outputTokens, 20)
        XCTAssertEqual(report.grand.cacheCreationTokens, 3)
        XCTAssertEqual(report.grand.cacheReadTokens, 4)
        XCTAssertEqual(report.grand.requestCount, 1)
    }

    func testClaudeIgnoresNonAssistantUsageRows() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let project = claude.appendingPathComponent("-Users-non-assistant", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let userUsage = #"{"type":"user","timestamp":"2026-06-08T10:00:00.000Z","requestId":"req_user","message":{"id":"msg_user","model":"claude-sonnet-4-6","role":"user","usage":{"input_tokens":999,"output_tokens":999,"cache_creation_input_tokens":999,"cache_read_input_tokens":999}}}"#
        let assistantUsage = #"{"type":"assistant","timestamp":"2026-06-08T10:00:01.000Z","requestId":"req_assistant","message":{"id":"msg_assistant","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":11,"output_tokens":7,"cache_creation_input_tokens":3,"cache_read_input_tokens":5}}}"#
        try ([userUsage, assistantUsage].joined(separator: "\n") + "\n")
            .write(to: project.appendingPathComponent("assistant-only.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 11)
        XCTAssertEqual(report.grand.outputTokens, 7)
        XCTAssertEqual(report.grand.cacheCreationTokens, 3)
        XCTAssertEqual(report.grand.cacheReadTokens, 5)
        XCTAssertEqual(report.grand.requestCount, 1)
    }

    func testClaudeParsesSpacedAssistantUsageJSON() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let project = claude.appendingPathComponent("-Users-spaced-json", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let line = #"{ "type" : "assistant", "timestamp" : "2026-06-08T10:00:00.000Z", "requestId" : "req_spaced", "message" : { "id" : "msg_spaced", "model" : "claude-sonnet-4-6", "role" : "assistant", "usage" : { "input_tokens" : 21, "output_tokens" : 13, "cache_creation_input_tokens" : 5, "cache_read_input_tokens" : 8 } } }"#
        try (line + "\n").write(to: project.appendingPathComponent("spaced.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 21)
        XCTAssertEqual(report.grand.outputTokens, 13)
        XCTAssertEqual(report.grand.cacheCreationTokens, 5)
        XCTAssertEqual(report.grand.cacheReadTokens, 8)
        XCTAssertEqual(report.grand.requestCount, 1)
    }

    func testClaudeHistoricalLongContextPricingUsesLogTimestamp() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let project = claude.appendingPathComponent("-Users-historical-pricing", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","timestamp":"2026-03-01T10:00:00.000Z","requestId":"req_historical","message":{"id":"msg_historical","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":210000,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        try (line + "\n").write(to: project.appendingPathComponent("historical.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        let expected = (210_000.0 * 6.0 + 10.0 * 22.5) / 1_000_000.0
        XCTAssertEqual(report.grand.costUSD, expected, accuracy: 1e-12)
        XCTAssertEqual(report.grand.requestCount, 1)
    }

    func testClaudeLogVertexAIRowsAreSplitIntoVertexAISource() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let project = claude.appendingPathComponent("-Users-vertex", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let anthropic = #"{"type":"assistant","timestamp":"2026-06-08T10:00:00.000Z","requestId":"req_anthropic","message":{"id":"msg_anthropic","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let vertexID = #"{"type":"assistant","timestamp":"2026-06-08T10:00:01.000Z","requestId":"req_vrtx_1","message":{"id":"msg_vrtx_1","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":20,"output_tokens":6,"cache_creation_input_tokens":0,"cache_read_input_tokens":1}}}"#
        let vertexModel = #"{"type":"assistant","timestamp":"2026-06-08T10:00:02.000Z","requestId":"req_vertex_model","message":{"id":"msg_vertex_model","model":"claude-sonnet-4-5@20250514","role":"assistant","usage":{"input_tokens":30,"output_tokens":7,"cache_creation_input_tokens":2,"cache_read_input_tokens":0}}}"#
        let vertexMetadata = #"{"type":"assistant","timestamp":"2026-06-08T10:00:03.000Z","requestId":"req_vertex_meta","metadata":{"provider":"google-vertex-ai"},"message":{"id":"msg_vertex_meta","model":"claude-haiku-4-5","role":"assistant","usage":{"input_tokens":40,"output_tokens":8,"cache_creation_input_tokens":0,"cache_read_input_tokens":3}}}"#
        try ([anthropic, vertexID, vertexModel, vertexMetadata].joined(separator: "\n") + "\n")
            .write(to: project.appendingPathComponent("mixed.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.bySource[.claude]?.inputTokens, 10)
        XCTAssertEqual(report.bySource[.claude]?.outputTokens, 5)
        XCTAssertEqual(report.bySource[.claude]?.requestCount, 1)
        XCTAssertEqual(report.bySource[.vertexai]?.inputTokens, 90)
        XCTAssertEqual(report.bySource[.vertexai]?.outputTokens, 21)
        XCTAssertEqual(report.bySource[.vertexai]?.cacheCreationTokens, 2)
        XCTAssertEqual(report.bySource[.vertexai]?.cacheReadTokens, 4)
        XCTAssertEqual(report.bySource[.vertexai]?.requestCount, 3)
        XCTAssertEqual(report.sessionsBySource[.vertexai], 1)
        XCTAssertEqual(Set(report.byDay.first?.modelBreakdowns.map(\.source) ?? []), Set([.claude, .vertexai]))
    }

    func testClaudeScansWindowRowsFromFilesWithOldModificationTime() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let project = claude.appendingPathComponent("-Users-old-mtime", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("old-mtime.jsonl")
        let line = #"{"type":"assistant","timestamp":"2026-06-08T10:00:00.000Z","requestId":"req_old_mtime","message":{"id":"msg_old_mtime","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":17,"output_tokens":11,"cache_creation_input_tokens":3,"cache_read_input_tokens":5}}}"#
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        let oldDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 1, now: ISO8601DateFormatter().date(from: "2026-06-08T12:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 17)
        XCTAssertEqual(report.grand.outputTokens, 11)
        XCTAssertEqual(report.grand.cacheCreationTokens, 3)
        XCTAssertEqual(report.grand.cacheReadTokens, 5)
        XCTAssertEqual(report.byDay.first?.day, "2026-06-08")
        XCTAssertEqual(report.bySource[.claude]?.requestCount, 1)
    }

    func testCodexUsesLastCumulativeTotal() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let dayDir = codex.appendingPathComponent("2026/06/08")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"x","cwd":"/Users/test/proj-b","model":"gpt-5.5"}}"#
        // 累计值递增：取最后一个 total_token_usage = 1000 in / 300 cached / 200 out
        let tc1 = #"{"timestamp":"2026-06-08T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":560}}}}"#
        let tc2 = #"{"timestamp":"2026-06-08T09:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":300,"output_tokens":200,"reasoning_output_tokens":40,"total_tokens":1200}}}}"#
        let content = [meta, tc1, tc2].joined(separator: "\n") + "\n"
        try content.write(to: dayDir.appendingPathComponent("rollout-x.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        // uncached input = 1000-300=700, cacheRead=300, output=200.
        // Codex reports reasoning_output_tokens as a subset of output_tokens; do not count it twice.
        XCTAssertEqual(report.grand.inputTokens, 700)
        XCTAssertEqual(report.grand.cacheReadTokens, 300)
        XCTAssertEqual(report.grand.outputTokens, 200)
        XCTAssertEqual(report.grand.requestCount, 2)
        XCTAssertEqual(report.sourceInfo?.source, .directScan)
        XCTAssertEqual(report.bySource[.codex]?.outputTokens, 200)
        XCTAssertEqual(report.byDay.first?.day, "2026-06-08")
        XCTAssertEqual(report.byDay.first?.bySource[.codex]?.outputTokens, 200)
        XCTAssertEqual(report.byMonth.first?.month, "2026-06")
        XCTAssertEqual(report.byMonth.first?.bySource[.codex]?.requestCount, 2)
        XCTAssertEqual(report.bySession.first?.session, "x")
        XCTAssertEqual(report.bySession.first?.source, .codex)
        XCTAssertEqual(report.bySession.first?.models, ["gpt-5.5"])
        XCTAssertEqual(report.bySession.first?.totals.requestCount, 2)
        XCTAssertEqual(report.byDay.first?.modelBreakdowns.first?.model, "gpt-5.5")
        XCTAssertEqual(report.byDay.first?.modelBreakdowns.first?.source, .codex)
        XCTAssertEqual(report.byDay.first?.modelBreakdowns.first?.totals.cacheReadTokens, 300)
        XCTAssertEqual(report.byDay.first?.modelBreakdowns.first?.totals.requestCount, 2)
        XCTAssertEqual(report.byProject.first?.path, "/Users/test/proj-b")
        XCTAssertEqual(report.sessionsScanned, 1)
    }

    func testCodexPrefersTotalDeltaWhenLastUsageIsInflated() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let dayDir = codex.appendingPathComponent("2026/06/08")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"inflated","cwd":"/Users/test/proj-b","model":"gpt-5.5"}}"#
        let tc1 = #"{"timestamp":"2026-06-08T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}"#
        let tc2 = #"{"timestamp":"2026-06-08T09:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":300},"total_token_usage":{"input_tokens":180,"cached_input_tokens":50,"output_tokens":20}}}}"#
        try ([meta, tc1, tc2].joined(separator: "\n") + "\n")
            .write(to: dayDir.appendingPathComponent("rollout-inflated.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 130)
        XCTAssertEqual(report.grand.cacheReadTokens, 50)
        XCTAssertEqual(report.grand.outputTokens, 20)
        XCTAssertEqual(report.grand.requestCount, 2)
        XCTAssertEqual(report.byDay.first?.modelBreakdowns.first?.totals.requestCount, 2)
    }

    func testCodexAcceptsLastTokenUsageWithoutTotal() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let dayDir = codex.appendingPathComponent("2026/06/08")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"last-only","cwd":"/Users/test/proj-b","model":"gpt-5.5"}}"#
        let tc1 = #"{"timestamp":"2026-06-08T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":120,"cached_input_tokens":40,"output_tokens":12}}}}"#
        let tc2 = #"{"timestamp":"2026-06-08T09:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":80,"cached_input_tokens":20,"output_tokens":8}}}}"#
        try ([meta, tc1, tc2].joined(separator: "\n") + "\n")
            .write(to: dayDir.appendingPathComponent("rollout-last-only.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 140)
        XCTAssertEqual(report.grand.cacheReadTokens, 60)
        XCTAssertEqual(report.grand.outputTokens, 20)
        XCTAssertEqual(report.grand.requestCount, 2)
    }

    #if canImport(SQLite3)
    func testCodexPriorityTracePopulatesDailyModeSplit() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let traceDB = try makeTempDir().appendingPathComponent("logs_2.sqlite")
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: traceDB.deletingLastPathComponent())
        }

        let dayDir = codex.appendingPathComponent("2026/06/08")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"x","cwd":"/Users/test/proj-b","model":"gpt-5.5"}}"#
        let standard = #"{"timestamp":"2026-06-08T09:01:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"standard-turn"}}"#
        let tc1 = #"{"timestamp":"2026-06-08T09:01:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}"#
        let priority = #"{"timestamp":"2026-06-08T09:02:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"priority-turn"}}"#
        let tc2 = #"{"timestamp":"2026-06-08T09:02:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":40,"output_tokens":20}}}}"#
        try ([meta, standard, tc1, priority, tc2].joined(separator: "\n") + "\n")
            .write(to: dayDir.appendingPathComponent("rollout-priority.jsonl"), atomically: true, encoding: .utf8)

        try Self.createCodexTraceDatabase(at: traceDB)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:00Z",
            body: "thread_id=thread turn.id=priority-turn websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            codexTraceDatabaseURL: traceDB,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)
        let breakdown = try XCTUnwrap(report.byDay.first?.modelBreakdowns.first)
        let standardCost = (80.0 * 5e-6) + (20.0 * 5e-7) + (10.0 * 3e-5)
        let priorityCost = (80.0 * 1.25e-5) + (20.0 * 1.25e-6) + (10.0 * 7.5e-5)

        XCTAssertEqual(breakdown.standardTokens, 110)
        XCTAssertEqual(breakdown.priorityTokens, 110)
        XCTAssertEqual(breakdown.standardCostUSD ?? 0, standardCost, accuracy: 1e-12)
        XCTAssertEqual(breakdown.priorityCostUSD ?? 0, priorityCost, accuracy: 1e-12)
        XCTAssertEqual(breakdown.totals.costUSD, standardCost + priorityCost, accuracy: 1e-12)
    }

    func testCodexPriorityOverInputLimitFallsBackToBaseCost() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let traceDB = try makeTempDir().appendingPathComponent("logs_2.sqlite")
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: traceDB.deletingLastPathComponent())
        }

        let dayDir = codex.appendingPathComponent("2026/06/08")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"priority-limit","cwd":"/Users/test/proj-b","model":"gpt-5.5"}}"#
        let priority = #"{"timestamp":"2026-06-08T09:01:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"priority-turn"}}"#
        let tc = #"{"timestamp":"2026-06-08T09:01:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300000,"cached_input_tokens":0,"output_tokens":10}}}}"#
        try ([meta, priority, tc].joined(separator: "\n") + "\n")
            .write(to: dayDir.appendingPathComponent("rollout-priority-limit.jsonl"), atomically: true, encoding: .utf8)

        try Self.createCodexTraceDatabase(at: traceDB)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:01:00Z",
            body: "thread_id=thread turn.id=priority-turn websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            codexTraceDatabaseURL: traceDB,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)
        let breakdown = try XCTUnwrap(report.byDay.first?.modelBreakdowns.first)
        let baseCost = (300_000.0 * 10.0 + 10.0 * 45.0) / 1_000_000.0

        XCTAssertEqual(breakdown.priorityTokens, 300_010)
        XCTAssertEqual(breakdown.priorityCostUSD ?? 0, baseCost, accuracy: 1e-12)
        XCTAssertEqual(breakdown.totals.costUSD, baseCost, accuracy: 1e-12)
    }

    func testCodexPriorityCompletedTraceOverridesRequestModel() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let traceDB = try makeTempDir().appendingPathComponent("logs_2.sqlite")
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: traceDB.deletingLastPathComponent())
        }

        let dayDir = codex.appendingPathComponent("2026/06/08")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"x","cwd":"/Users/test/proj-b","model":"gpt-5.5"}}"#
        let priority = #"{"timestamp":"2026-06-08T09:02:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"priority-turn"}}"#
        let tc = #"{"timestamp":"2026-06-08T09:02:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}"#
        try ([meta, priority, tc].joined(separator: "\n") + "\n")
            .write(to: dayDir.appendingPathComponent("rollout-priority.jsonl"), atomically: true, encoding: .utf8)

        try Self.createCodexTraceDatabase(at: traceDB)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:00Z",
            body: "thread_id=thread turn.id=priority-turn websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:01Z",
            body: "thread_id=thread turn.id=priority-turn websocket event: "
                + #"{"type":"response.completed","response":{"model":"gpt-5.4"}}"#)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            codexTraceDatabaseURL: traceDB,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)
        let breakdown = try XCTUnwrap(report.byDay.first?.modelBreakdowns.first)
        let completedModelPriorityCost = (80.0 * 5e-6) + (20.0 * 0.5e-6) + (10.0 * 30e-6)

        XCTAssertEqual(breakdown.priorityCostUSD ?? 0, completedModelPriorityCost, accuracy: 1e-12)
        XCTAssertEqual(breakdown.totals.costUSD, completedModelPriorityCost, accuracy: 1e-12)
    }

    func testCodexPriorityMemoPicksUpAppendedCompletedRows() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let traceDB = try makeTempDir().appendingPathComponent("logs_2.sqlite")
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: traceDB.deletingLastPathComponent())
        }

        let dayDir = codex.appendingPathComponent("2026/06/08")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"x","cwd":"/Users/test/proj-b","model":"gpt-5.5"}}"#
        let priority = #"{"timestamp":"2026-06-08T09:02:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"priority-turn"}}"#
        let tc = #"{"timestamp":"2026-06-08T09:02:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}"#
        try ([meta, priority, tc].joined(separator: "\n") + "\n")
            .write(to: dayDir.appendingPathComponent("rollout-priority.jsonl"), atomically: true, encoding: .utf8)

        try Self.createCodexTraceDatabase(at: traceDB)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:00Z",
            body: "thread_id=thread turn.id=priority-turn websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            codexTraceDatabaseURL: traceDB,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let now = ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!
        let first = scanner.scan(daysBack: 3650, now: now)
        XCTAssertEqual(first.byDay.first?.modelBreakdowns.first?.priorityCostUSD ?? 0, 0.001775, accuracy: 1e-12)

        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:01Z",
            body: "thread_id=thread turn.id=priority-turn websocket event: "
                + #"{"type":"response.completed","response":{"model":"gpt-5.4"}}"#)
        let second = scanner.scan(daysBack: 3650, now: now.addingTimeInterval(1))
        let completedModelPriorityCost = (80.0 * 5e-6) + (20.0 * 0.5e-6) + (10.0 * 30e-6)

        XCTAssertEqual(second.byDay.first?.modelBreakdowns.first?.priorityCostUSD ?? 0, completedModelPriorityCost, accuracy: 1e-12)
    }

    func testCodexPriorityMemoPrunesDeletedRequestRows() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let traceDB = try makeTempDir().appendingPathComponent("logs_2.sqlite")
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: traceDB.deletingLastPathComponent())
        }

        let dayDir = codex.appendingPathComponent("2026/06/08")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"x","cwd":"/Users/test/proj-b","model":"gpt-5.5"}}"#
        let priority = #"{"timestamp":"2026-06-08T09:02:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"priority-turn"}}"#
        let tc = #"{"timestamp":"2026-06-08T09:02:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}"#
        try ([meta, priority, tc].joined(separator: "\n") + "\n")
            .write(to: dayDir.appendingPathComponent("rollout-priority.jsonl"), atomically: true, encoding: .utf8)

        try Self.createCodexTraceDatabase(at: traceDB)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:00Z",
            body: "thread_id=thread turn.id=priority-turn websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:01Z",
            body: #"thread_id=thread turn.id=standard websocket request: {"type":"response.create","model":"gpt-5.5"}"#)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            codexTraceDatabaseURL: traceDB,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let now = ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!
        let first = scanner.scan(daysBack: 3650, now: now)
        XCTAssertEqual(first.byDay.first?.modelBreakdowns.first?.priorityCostUSD ?? 0, 0.001775, accuracy: 1e-12)

        try Self.execCodexTrace(into: traceDB, sql: "delete from logs where rowid = 1")
        let second = scanner.scan(daysBack: 3650, now: now.addingTimeInterval(1))
        let standardCost = (80.0 * 5e-6) + (20.0 * 0.5e-6) + (10.0 * 30e-6)

        XCTAssertEqual(second.byDay.first?.modelBreakdowns.first?.priorityCostUSD ?? 0, 0, accuracy: 1e-12)
        XCTAssertEqual(second.byDay.first?.modelBreakdowns.first?.totals.costUSD ?? 0, standardCost, accuracy: 1e-12)
    }

    func testCodexPriorityMemoFallsBackToRetainedDuplicateRows() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let traceDB = try makeTempDir().appendingPathComponent("logs_2.sqlite")
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: traceDB.deletingLastPathComponent())
        }

        let dayDir = codex.appendingPathComponent("2026/06/08")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"x","cwd":"/Users/test/proj-b","model":"gpt-5.5"}}"#
        let priority = #"{"timestamp":"2026-06-08T09:02:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"priority-turn"}}"#
        let tc = #"{"timestamp":"2026-06-08T09:02:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}"#
        try ([meta, priority, tc].joined(separator: "\n") + "\n")
            .write(to: dayDir.appendingPathComponent("rollout-priority.jsonl"), atomically: true, encoding: .utf8)

        try Self.createCodexTraceDatabase(at: traceDB)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:00Z",
            body: "thread_id=thread-old turn.id=priority-turn websocket request: "
                + #"{"type":"response.create","model":"gpt-5.4","service_tier":"priority"}"#)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:01Z",
            body: "thread_id=thread-new turn.id=priority-turn websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:02Z",
            body: "thread_id=thread-old turn.id=priority-turn websocket event: "
                + #"{"type":"response.completed","response":{"model":"gpt-5.4"}}"#)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:03Z",
            body: "thread_id=thread-new turn.id=priority-turn websocket event: "
                + #"{"type":"response.completed","response":{"model":"gpt-5.5"}}"#)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            codexTraceDatabaseURL: traceDB,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let now = ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!
        let first = scanner.scan(daysBack: 3650, now: now)
        XCTAssertEqual(first.byDay.first?.modelBreakdowns.first?.priorityCostUSD ?? 0, 0.001775, accuracy: 1e-12)

        try Self.execCodexTrace(into: traceDB, sql: "delete from logs where rowid in (2, 4)")
        let second = scanner.scan(daysBack: 3650, now: now.addingTimeInterval(1))
        let retainedPriorityCost = (80.0 * 5e-6) + (20.0 * 0.5e-6) + (10.0 * 30e-6)

        XCTAssertEqual(second.byDay.first?.modelBreakdowns.first?.priorityCostUSD ?? 0, retainedPriorityCost, accuracy: 1e-12)
    }

    func testCodexPriorityMemoResetsWhenTraceDatabaseIsReplaced() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let traceDB = try makeTempDir().appendingPathComponent("logs_2.sqlite")
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: traceDB.deletingLastPathComponent())
        }

        let dayDir = codex.appendingPathComponent("2026/06/08")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"x","cwd":"/Users/test/proj-b","model":"gpt-5.5"}}"#
        let turn = #"{"timestamp":"2026-06-08T09:02:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}"#
        let tc = #"{"timestamp":"2026-06-08T09:02:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}"#
        try ([meta, turn, tc].joined(separator: "\n") + "\n")
            .write(to: dayDir.appendingPathComponent("rollout-priority.jsonl"), atomically: true, encoding: .utf8)

        try Self.createCodexTraceDatabase(at: traceDB)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:00Z",
            body: "thread_id=thread turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            codexTraceDatabaseURL: traceDB,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let now = ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!
        let first = scanner.scan(daysBack: 3650, now: now)
        XCTAssertEqual(first.byDay.first?.modelBreakdowns.first?.priorityCostUSD ?? 0, 0.001775, accuracy: 1e-12)

        try FileManager.default.removeItem(at: traceDB)
        try Self.createCodexTraceDatabase(at: traceDB)
        try Self.insertCodexTrace(
            into: traceDB,
            timestamp: "2026-06-08T09:02:00Z",
            body: #"thread_id=thread turn.id=turn-a websocket request: {"type":"response.create","model":"gpt-5.5"}"#)
        let second = scanner.scan(daysBack: 3650, now: now.addingTimeInterval(1))
        let standardCost = (80.0 * 5e-6) + (20.0 * 0.5e-6) + (10.0 * 30e-6)

        XCTAssertEqual(second.byDay.first?.modelBreakdowns.first?.priorityCostUSD ?? 0, 0, accuracy: 1e-12)
        XCTAssertEqual(second.byDay.first?.modelBreakdowns.first?.totals.costUSD ?? 0, standardCost, accuracy: 1e-12)
    }
    #endif

    func testCodexArchivedSessionsAreScanned() throws {
        let claude = try makeTempDir()
        let root = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: pi)
        }

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let archived = root.appendingPathComponent("archived_sessions/2026/06/08", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)

        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"archived","cwd":"/Users/test/old","model":"gpt-5.5"}}"#
        let tc = #"{"timestamp":"2026-06-08T09:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":25,"output_tokens":50,"reasoning_output_tokens":5}}}}"#
        try ([meta, tc].joined(separator: "\n") + "\n")
            .write(to: archived.appendingPathComponent("rollout-archived.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: sessions,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 75)
        XCTAssertEqual(report.grand.cacheReadTokens, 25)
        XCTAssertEqual(report.grand.outputTokens, 50)
        XCTAssertEqual(report.byProject.first?.path, "/Users/test/old")
        XCTAssertEqual(report.sessionsBySource[.codex], 1)
    }

    func testCodexDatePartitionScansWindowFilesWithOldModificationTime() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let dayDir = codex.appendingPathComponent("2026/06/08", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent("rollout-old-mtime.jsonl")
        let meta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"old-mtime","cwd":"/Users/test/old-mtime","model":"gpt-5.5"}}"#
        let usage = #"{"timestamp":"2026-06-08T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":40,"output_tokens":16}}}}"#
        try ([meta, usage].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let oldDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 1, now: ISO8601DateFormatter().date(from: "2026-06-08T12:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 120)
        XCTAssertEqual(report.grand.cacheReadTokens, 40)
        XCTAssertEqual(report.grand.outputTokens, 16)
        XCTAssertEqual(report.byProject.first?.path, "/Users/test/old-mtime")
        XCTAssertEqual(report.sessionsBySource[.codex], 1)
    }

    func testCodexDuplicateSessionKeepsLiveSessionsBeforeArchivedCopy() throws {
        let claude = try makeTempDir()
        let root = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: pi)
        }

        let sessions = root.appendingPathComponent("sessions/2026/06/08", isDirectory: true)
        let archived = root.appendingPathComponent("archived_sessions/2026/06/08", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)

        let liveMeta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"duplicate-session","cwd":"/Users/test/live","model":"gpt-5.5"}}"#
        let liveUsage = #"{"timestamp":"2026-06-08T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10}}}}"#
        let archivedMeta = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"duplicate-session","cwd":"/Users/test/archived","model":"gpt-5.5"}}"#
        let archivedUsage = #"{"timestamp":"2026-06-08T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100}}}}"#
        try ([liveMeta, liveUsage].joined(separator: "\n") + "\n")
            .write(to: sessions.appendingPathComponent("rollout-live.jsonl"), atomically: true, encoding: .utf8)
        try ([archivedMeta, archivedUsage].joined(separator: "\n") + "\n")
            .write(to: archived.appendingPathComponent("rollout-archived-copy.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: root.appendingPathComponent("sessions", isDirectory: true),
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 80)
        XCTAssertEqual(report.grand.cacheReadTokens, 20)
        XCTAssertEqual(report.grand.outputTokens, 10)
        XCTAssertEqual(report.byProject.first?.path, "/Users/test/live")
        XCTAssertEqual(report.sessionsBySource[.codex], 1)
    }

    func testCodexDuplicatePhysicalFilesAreCountedOnce() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let dayDir = codex.appendingPathComponent("2026/06/08", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let original = dayDir.appendingPathComponent("rollout-hardlink-a.jsonl")
        let linked = dayDir.appendingPathComponent("rollout-hardlink-b.jsonl")
        let usage = #"{"timestamp":"2026-06-08T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":40,"output_tokens":12}}}}"#
        try (usage + "\n").write(to: original, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: original, to: linked)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.grand.inputTokens, 80)
        XCTAssertEqual(report.grand.cacheReadTokens, 40)
        XCTAssertEqual(report.grand.outputTokens, 12)
        XCTAssertEqual(report.grand.requestCount, 1)
        XCTAssertEqual(report.sessionsBySource[.codex], 1)
    }

    func testCodexForkedChildSubtractsParentBaseline() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let parentDir = codex.appendingPathComponent("2026/02/27")
        let childDir = codex.appendingPathComponent("2026/03/11")
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)

        let parentID = "sess-parent"
        let childID = "sess-child"
        let parentMeta = #"{"type":"session_meta","payload":{"id":""# + parentID + #"","cwd":"/Users/test/parent","model":"gpt-5.5"}}"#
        let parentTc1 = #"{"timestamp":"2026-02-27T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":1}}}}"#
        let parentTc2 = #"{"timestamp":"2026-02-27T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":2}}}}"#
        let parentTc3 = #"{"timestamp":"2026-02-27T12:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30,"cached_input_tokens":8,"output_tokens":3}}}}"#
        try ([parentMeta, parentTc1, parentTc2, parentTc3].joined(separator: "\n") + "\n")
            .write(to: parentDir.appendingPathComponent("rollout-parent-hidden.jsonl"), atomically: true, encoding: .utf8)

        let childMeta = #"{"type":"session_meta","payload":{"id":""# + childID + #"","forked_from_id":""# + parentID + #"","timestamp":"2026-02-27T12:00:02.500Z","cwd":"/Users/test/child","model":"gpt-5.5"}}"#
        let childTc1 = #"{"timestamp":"2026-03-11T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":2}}}}"#
        let childTc2 = #"{"timestamp":"2026-03-11T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":27,"cached_input_tokens":7,"output_tokens":4}}}}"#
        try ([childMeta, childTc1, childTc2].joined(separator: "\n") + "\n")
            .write(to: childDir.appendingPathComponent("rollout-\(childID).jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-03-12T00:00:00Z")!)
        let childDay = try XCTUnwrap(report.byDay.first { $0.day == "2026-03-11" })

        XCTAssertEqual(childDay.totals.inputTokens, 5)
        XCTAssertEqual(childDay.totals.cacheReadTokens, 2)
        XCTAssertEqual(childDay.totals.outputTokens, 2)
        XCTAssertEqual(childDay.totals.totalTokens, 9)
    }

    func testCodexForkedChildRefreshesBaselineWhenParentFileChanges() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let parentDir = codex.appendingPathComponent("2026/02/27")
        let childDir = codex.appendingPathComponent("2026/03/11")
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)

        let parentID = "sess-parent-refresh"
        let childID = "sess-child-refresh"
        let parentFile = parentDir.appendingPathComponent("rollout-parent-refresh-hidden.jsonl")
        let parentMeta = #"{"type":"session_meta","payload":{"id":""# + parentID + #"","cwd":"/Users/test/parent","model":"gpt-5.5"}}"#
        let parentTc1 = #"{"timestamp":"2026-02-27T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":1}}}}"#
        let parentTc2 = #"{"timestamp":"2026-02-27T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":2}}}}"#
        try ([parentMeta, parentTc1, parentTc2].joined(separator: "\n") + "\n")
            .write(to: parentFile, atomically: true, encoding: .utf8)

        let childMeta = #"{"type":"session_meta","payload":{"id":""# + childID + #"","forked_from_id":""# + parentID + #"","timestamp":"2026-02-27T12:00:02.500Z","cwd":"/Users/test/child","model":"gpt-5.5"}}"#
        let childTc1 = #"{"timestamp":"2026-03-11T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":2}}}}"#
        let childTc2 = #"{"timestamp":"2026-03-11T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":27,"cached_input_tokens":7,"output_tokens":4}}}}"#
        try ([childMeta, childTc1, childTc2].joined(separator: "\n") + "\n")
            .write(to: childDir.appendingPathComponent("rollout-\(childID).jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let now = ISO8601DateFormatter().date(from: "2026-03-12T00:00:00Z")!
        let first = scanner.scan(daysBack: 3650, now: now)
        let firstChildDay = try XCTUnwrap(first.byDay.first { $0.day == "2026-03-11" })
        XCTAssertEqual(firstChildDay.totals.inputTokens, 5)
        XCTAssertEqual(firstChildDay.totals.cacheReadTokens, 2)
        XCTAssertEqual(firstChildDay.totals.outputTokens, 2)

        try ([parentMeta, parentTc1].joined(separator: "\n") + "\n")
            .write(to: parentFile, atomically: true, encoding: .utf8)
        let second = scanner.scan(daysBack: 3650, now: now.addingTimeInterval(1))
        let secondChildDay = try XCTUnwrap(second.byDay.first { $0.day == "2026-03-11" })

        XCTAssertEqual(secondChildDay.totals.inputTokens, 12)
        XCTAssertEqual(secondChildDay.totals.cacheReadTokens, 5)
        XCTAssertEqual(secondChildDay.totals.outputTokens, 3)
        XCTAssertEqual(secondChildDay.totals.totalTokens, 20)
    }

    func testCodexForkedChildRefreshesParentSessionIndexWhenFileMoves() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let parentDir = codex.appendingPathComponent("2026/02/27")
        let childDir = codex.appendingPathComponent("2026/03/11")
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)

        let parentID = "sess-parent-moved"
        let childID = "sess-child-moved"
        let firstParentFile = parentDir.appendingPathComponent("rollout-parent-moved-hidden.jsonl")
        let movedParentFile = parentDir.appendingPathComponent("rollout-hidden-replacement.jsonl")
        let parentMeta = #"{"type":"session_meta","payload":{"id":""# + parentID + #"","cwd":"/Users/test/parent","model":"gpt-5.5"}}"#
        let parentTcLow = #"{"timestamp":"2026-02-27T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":1}}}}"#
        let parentTcHigh = #"{"timestamp":"2026-02-27T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":2}}}}"#
        try ([parentMeta, parentTcLow, parentTcHigh].joined(separator: "\n") + "\n")
            .write(to: firstParentFile, atomically: true, encoding: .utf8)

        let childMeta = #"{"type":"session_meta","payload":{"id":""# + childID + #"","forked_from_id":""# + parentID + #"","timestamp":"2026-02-27T12:00:02.500Z","cwd":"/Users/test/child","model":"gpt-5.5"}}"#
        let childTc1 = #"{"timestamp":"2026-03-11T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":5,"output_tokens":2}}}}"#
        let childTc2 = #"{"timestamp":"2026-03-11T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":27,"cached_input_tokens":7,"output_tokens":4}}}}"#
        try ([childMeta, childTc1, childTc2].joined(separator: "\n") + "\n")
            .write(to: childDir.appendingPathComponent("rollout-\(childID).jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let now = ISO8601DateFormatter().date(from: "2026-03-12T00:00:00Z")!
        let first = scanner.scan(daysBack: 3650, now: now)
        let firstChildDay = try XCTUnwrap(first.byDay.first { $0.day == "2026-03-11" })
        XCTAssertEqual(firstChildDay.totals.inputTokens, 5)
        XCTAssertEqual(firstChildDay.totals.cacheReadTokens, 2)
        XCTAssertEqual(firstChildDay.totals.outputTokens, 2)

        try FileManager.default.removeItem(at: firstParentFile)
        try ([parentMeta, parentTcLow].joined(separator: "\n") + "\n")
            .write(to: movedParentFile, atomically: true, encoding: .utf8)
        let second = scanner.scan(daysBack: 3650, now: now.addingTimeInterval(1))
        let secondChildDay = try XCTUnwrap(second.byDay.first { $0.day == "2026-03-11" })

        XCTAssertEqual(secondChildDay.totals.inputTokens, 12)
        XCTAssertEqual(secondChildDay.totals.cacheReadTokens, 5)
        XCTAssertEqual(secondChildDay.totals.outputTokens, 3)
        XCTAssertEqual(secondChildDay.totals.totalTokens, 20)
    }

    func testCodexForkedChildSkipsCumulativeTotalsWhenParentMissing() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let childDir = codex.appendingPathComponent("2026/03/11")
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
        let childMeta = #"{"type":"session_meta","payload":{"id":"sess-child-missing-parent","forked_from_id":"missing-parent","timestamp":"2026-02-27T12:00:02.500Z","cwd":"/Users/test/child","model":"gpt-5.5"}}"#
        let replayedHistory = #"{"timestamp":"2026-03-11T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":100000,"output_tokens":10000}}}}"#
        try ([childMeta, replayedHistory].joined(separator: "\n") + "\n")
            .write(to: childDir.appendingPathComponent("rollout-child-missing-parent.jsonl"), atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-03-12T00:00:00Z")!)

        XCTAssertFalse(report.byDay.contains { $0.day == "2026-03-11" })
        XCTAssertEqual(report.grand.totalTokens, 0)
    }

    func testPiSessionsAreAttributedToCodexAndClaude() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let file = pi.appendingPathComponent("2026-06-08T09-00-00-000Z_session.jsonl")
        let modelChange = #"{"type":"model_change","timestamp":"2026-06-08T09:00:00.000Z","provider":"openai-codex","modelId":"gpt-5.5"}"#
        let codexMessage = #"{"type":"message","timestamp":"2026-06-08T09:01:00.000Z","cwd":"/Users/test/pi","message":{"role":"assistant","usage":{"inputTokens":100,"cacheReadTokens":20,"outputTokens":30}}}"#
        let claudeMessage = #"{"type":"message","timestamp":"2026-06-08T09:02:00.000Z","cwd":"/Users/test/pi","message":{"role":"assistant","provider":"anthropic","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"cache_creation_input_tokens":5,"output_tokens":15}}}"#
        try ([modelChange, codexMessage, claudeMessage].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let report = scanner.scan(daysBack: 3650, now: ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z")!)

        XCTAssertEqual(report.bySource[.codex]?.inputTokens, 100)
        XCTAssertEqual(report.bySource[.codex]?.cacheReadTokens, 20)
        XCTAssertEqual(report.bySource[.codex]?.outputTokens, 30)
        XCTAssertEqual(report.bySource[.claude]?.inputTokens, 10)
        XCTAssertEqual(report.bySource[.claude]?.cacheCreationTokens, 5)
        XCTAssertEqual(report.bySource[.claude]?.outputTokens, 15)
        XCTAssertEqual(report.byProject.first?.path, "/Users/test/pi")
        XCTAssertEqual(report.sessionsBySource[.codex], 1)
        XCTAssertEqual(report.sessionsBySource[.claude], 1)
        XCTAssertEqual(Set(report.byDay.first?.modelBreakdowns.map(\.source) ?? []), Set([.codex, .claude]))
        XCTAssertEqual(Set(report.byDay.first?.modelBreakdowns.map(\.model) ?? []), Set(["gpt-5.5", "claude-sonnet-4-6"]))
    }

    func testPiSessionFilenameStartKeepsOldMtimeFileInWindow() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
        }

        let file = pi.appendingPathComponent("2026-06-08T09-00-00-000Z_imported-session.jsonl")
        let modelChange = #"{"type":"model_change","timestamp":"2026-06-08T09:00:00.000Z","provider":"openai-codex","modelId":"gpt-5.5"}"#
        let message = #"{"type":"message","timestamp":"2026-06-08T09:01:00.000Z","cwd":"/Users/test/pi-imported","message":{"role":"assistant","usage":{"inputTokens":100,"cacheReadTokens":20,"outputTokens":30}}}"#
        try ([modelChange, message].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let oldDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: pi.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-08T12:00:00Z"))
        let report = scanner.scan(daysBack: 1, now: now)
        let fingerprint = scanner.corpusFingerprint(daysBack: 1, now: now)

        XCTAssertEqual(fingerprint.fileCount, 1)
        XCTAssertEqual(report.bySource[.codex]?.inputTokens, 100)
        XCTAssertEqual(report.bySource[.codex]?.cacheReadTokens, 20)
        XCTAssertEqual(report.bySource[.codex]?.outputTokens, 30)
        XCTAssertEqual(report.byProject.first?.path, "/Users/test/pi-imported")
        XCTAssertEqual(report.sessionsBySource[.codex], 1)
        XCTAssertEqual(report.byDay.first?.day, "2026-06-08")
    }

    func testFileCacheTracksParsedBytesBeforeIncompleteTail() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let cache = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: cache)
        }

        let project = claude.appendingPathComponent("-Users-cache-tail", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("tail.jsonl", isDirectory: false)
        let complete = #"{"type":"assistant","timestamp":"2026-06-08T10:00:00.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let partial = #"{"type":"assistant","timestamp":"2026-06-08T10:01:00.000Z","requestId":"req_2","message":{"id":"msg_2","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":30"#
        try (complete + "\n" + partial).write(to: file, atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: cache.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z"))
        let first = try scanner.scanWithFileCache(daysBack: 3650, now: now, cacheRoot: cache)

        XCTAssertEqual(first.grand.inputTokens, 10)
        XCTAssertEqual(first.grand.outputTokens, 20)
        XCTAssertEqual(first.grand.requestCount, 1)
        let firstEntry = try cachedFileEntry(cacheRoot: cache, file: file)
        XCTAssertLessThan(try cachedParsedBytes(firstEntry), try cachedSize(firstEntry))

        try appendText(
            #","output_tokens":40,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n",
            to: file)
        let second = try scanner.scanWithFileCache(daysBack: 3650, now: now.addingTimeInterval(1), cacheRoot: cache)

        XCTAssertEqual(second.grand.inputTokens, 40)
        XCTAssertEqual(second.grand.outputTokens, 60)
        XCTAssertEqual(second.grand.requestCount, 2)
        let secondEntry = try cachedFileEntry(cacheRoot: cache, file: file)
        XCTAssertEqual(try cachedParsedBytes(secondEntry), try cachedSize(secondEntry))
    }

    func testFileCacheScannerHandlesLinesAcrossReadChunks() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let cache = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: cache)
        }

        let project = claude.appendingPathComponent("-Users-chunked", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("large-lines.jsonl", isDirectory: false)
        let largeLine = String(repeating: "x", count: 300_000)
        let usage = #"{"type":"assistant","timestamp":"2026-06-08T10:00:00.000Z","requestId":"req_chunk","message":{"id":"msg_chunk","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":31,"output_tokens":17,"cache_creation_input_tokens":5,"cache_read_input_tokens":7}}}"#
        try ([largeLine, usage].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: cache.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z"))
        let report = try scanner.scanWithFileCache(daysBack: 3650, now: now, cacheRoot: cache)

        XCTAssertEqual(report.grand.inputTokens, 31)
        XCTAssertEqual(report.grand.outputTokens, 17)
        XCTAssertEqual(report.grand.cacheCreationTokens, 5)
        XCTAssertEqual(report.grand.cacheReadTokens, 7)
        XCTAssertEqual(report.grand.requestCount, 1)

        let entry = try cachedFileEntry(cacheRoot: cache, file: file)
        XCTAssertEqual(try cachedParsedBytes(entry), try cachedSize(entry))
    }

    func testCodexScannerKeepsModelFromTruncatedTurnContextPrefix() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let cache = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: cache)
        }

        let dayDir = codex.appendingPathComponent("2026/06/08", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent("rollout-huge-context.jsonl", isDirectory: false)
        let hugePrompt = String(repeating: "x", count: 270_000)
        let session = #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"huge-context","cwd":"/Users/test/huge"}}"#
        let turnContext = #"{"timestamp":"2026-06-08T09:00:30.000Z","type":"turn_context","payload":{"model":"gpt-5.5","cwd":"/Users/test/huge","prompt":""#
            + hugePrompt
            + #""}}"#
        let tokenCount = #"{"timestamp":"2026-06-08T09:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":20,"output_tokens":30}}}}"#
        try ([session, turnContext, tokenCount].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: cache.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z"))
        let report = try scanner.scanWithFileCache(daysBack: 3650, now: now, cacheRoot: cache)

        XCTAssertEqual(report.bySource[.codex]?.inputTokens, 100)
        XCTAssertEqual(report.bySource[.codex]?.cacheReadTokens, 20)
        XCTAssertEqual(report.bySource[.codex]?.outputTokens, 30)
        XCTAssertTrue(report.byModel.contains { $0.source == .codex && $0.model == "gpt-5.5" })
        XCTAssertFalse(report.byModel.contains { $0.source == .codex && $0.model == "gpt-5-codex" })

        let entry = try cachedFileEntry(cacheRoot: cache, file: file)
        XCTAssertEqual(try cachedParsedBytes(entry), try cachedSize(entry))
    }

    func testFileCacheInvalidatesWhenCodexFileIsReplacedWithSameSizeAndMTime() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let cache = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: cache)
        }

        let dayDir = codex.appendingPathComponent("2026/06/08", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent("rollout-replaced.jsonl", isDirectory: false)
        let fixedMTime = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-08T09:30:00Z"))

        let original = Self.codexSession(
            input: 100,
            cached: 10,
            output: 20)
        let replacement = Self.codexSession(
            input: 900,
            cached: 90,
            output: 80)
        XCTAssertEqual(original.utf8.count, replacement.utf8.count)

        try original.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: fixedMTime], ofItemAtPath: file.path)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: cache.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z"))
        let first = try scanner.scanWithFileCache(daysBack: 3650, now: now, cacheRoot: cache)

        XCTAssertEqual(first.grand.inputTokens, 90)
        XCTAssertEqual(first.grand.cacheReadTokens, 10)
        XCTAssertEqual(first.grand.outputTokens, 20)

        try FileManager.default.removeItem(at: file)
        try replacement.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: fixedMTime], ofItemAtPath: file.path)

        let second = try scanner.scanWithFileCache(daysBack: 3650, now: now.addingTimeInterval(1), cacheRoot: cache)

        XCTAssertEqual(second.grand.inputTokens, 810)
        XCTAssertEqual(second.grand.cacheReadTokens, 90)
        XCTAssertEqual(second.grand.outputTokens, 80)
        XCTAssertEqual(second.sessionsBySource[.codex], 1)
    }

    func testFileCacheScanCancellationStopsDuringFileParsing() throws {
        let claude = try makeTempDir()
        let codex = try makeTempDir()
        let pi = try makeTempDir()
        let cache = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: claude)
            try? FileManager.default.removeItem(at: codex)
            try? FileManager.default.removeItem(at: pi)
            try? FileManager.default.removeItem(at: cache)
        }

        let project = claude.appendingPathComponent("-Users-cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("cancel.jsonl", isDirectory: false)
        let lines = (0..<512).map { index in
            #"{"type":"assistant","timestamp":"2026-06-08T10:00:00.000Z","requestId":"req_\#(index)","message":{"id":"msg_\#(index)","model":"claude-sonnet-4-6","role":"assistant","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let scanner = UsageScanner(
            claudeProjectsDir: claude,
            codexSessionsDir: codex,
            modelsDevCacheRoot: cache.appendingPathComponent("pricing-cache", isDirectory: true),
            piSessionsDir: pi)
        let counter = CancellationCounter()
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-09T00:00:00Z"))

        XCTAssertThrowsError(try scanner.scanWithFileCache(
            daysBack: 3650,
            now: now,
            cacheRoot: cache,
            checkCancellation: {
                try counter.check(after: 5)
            })) { error in
                XCTAssertTrue(error is CancellationError)
            }
        XCTAssertGreaterThanOrEqual(counter.count, 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: UsageScanner.fileCacheFileURL(cacheRoot: cache).path))
    }

    func testCostReportFilteringPreservesDailyModelBreakdowns() throws {
        var codexTotals = UsageTotals()
        codexTotals.inputTokens = 100
        codexTotals.outputTokens = 20
        codexTotals.costUSD = 0.001

        var claudeTotals = UsageTotals()
        claudeTotals.inputTokens = 10
        claudeTotals.outputTokens = 5
        claudeTotals.costUSD = 0.0001

        var report = UsageReport()
        report.daysBack = 7
        report.grand = codexTotals + claudeTotals
        report.bySource = [.codex: codexTotals, .claude: claudeTotals]
        report.byDay = [
            DailyUsage(
                day: "2026-06-08",
                totals: report.grand,
                bySource: report.bySource,
                modelBreakdowns: [
                    UsageModelBreakdown(model: "gpt-5.5", source: .codex, totals: codexTotals),
                    UsageModelBreakdown(model: "claude-sonnet-4-6", source: .claude, totals: claudeTotals),
                ]),
        ]

        let filtered = UsageCostCLIReporter.filtered(report, sources: [.codex])

        XCTAssertEqual(filtered.byDay.count, 1)
        XCTAssertEqual(filtered.byDay.first?.totals.inputTokens, 100)
        XCTAssertEqual(filtered.byDay.first?.modelBreakdowns.map(\.model), ["gpt-5.5"])
        XCTAssertEqual(filtered.byDay.first?.modelBreakdowns.first?.source, .codex)
    }

    func testCostTextRendererIncludesDailyModelsAndPricingLabels() throws {
        var sparkTotals = UsageTotals()
        sparkTotals.inputTokens = 10_000
        sparkTotals.outputTokens = 2_000
        sparkTotals.requestCount = 2

        var fastTotals = UsageTotals()
        fastTotals.inputTokens = 24_000
        fastTotals.cacheReadTokens = 1_000
        fastTotals.outputTokens = 5_000
        fastTotals.costUSD = 0.30
        fastTotals.requestCount = 3

        var report = UsageReport()
        report.daysBack = 7
        report.grand = sparkTotals + fastTotals
        report.bySource = [.codex: report.grand]
        report.sessionsBySource = [.codex: 2]
        report.byModel = [
            ModelUsage(model: "gpt-5.3-codex-spark", source: .codex, totals: sparkTotals),
            ModelUsage(model: "gpt-5.5", source: .codex, totals: fastTotals),
        ]
        report.byDay = [
            DailyUsage(
                day: "2026-06-08",
                totals: report.grand,
                bySource: report.bySource,
                modelBreakdowns: [
                    UsageModelBreakdown(
                        model: "gpt-5.3-codex-spark",
                        source: .codex,
                        totals: sparkTotals),
                    UsageModelBreakdown(
                        model: "gpt-5.5",
                        source: .codex,
                        totals: fastTotals,
                        standardCostUSD: 0.10,
                        priorityCostUSD: 0.20,
                        standardTokens: 10_000,
                        priorityTokens: 20_000),
                ]),
        ]

        let costReport = UsageCostCLIReport(report: report)
        XCTAssertEqual(costReport.byModel.first?.displayLabel, "Research Preview")
        XCTAssertEqual(costReport.byDay.first?.modelBreakdowns.first?.displayLabel, "Research Preview")

        let output = UsageCostCLITextRenderer.render(costReport)
        XCTAssertTrue(output.contains("Top models"))
        XCTAssertTrue(output.contains("Codex / gpt-5.3-codex-spark: Research Preview · 12.00K tokens · 2 requests"))
        XCTAssertTrue(output.contains("Recent days"))
        XCTAssertTrue(output.contains("  2026-06-08: $0.30 · 42.00K tokens · 5 requests"))
        XCTAssertTrue(output.contains("    Codex / gpt-5.5: $0.30 · 30.00K tokens · 3 requests · Std $0.10 10.00K tokens / Fast $0.20 20.00K tokens"))
    }

    func testPricingLookup() {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("conductor-pricing-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        XCTAssertEqual(ModelPricing.forModel("claude-opus-4-7", cacheRoot: cacheRoot).inputPerM, 5)
        XCTAssertEqual(ModelPricing.forModel("claude-opus-4-1-20250101", cacheRoot: cacheRoot).inputPerM, 15)
        XCTAssertEqual(ModelPricing.forModel("claude-fable-5", cacheRoot: cacheRoot).inputPerM, 10)
        XCTAssertEqual(ModelPricing.forModel("claude-fable-5", cacheRoot: cacheRoot).outputPerM, 50)
        XCTAssertEqual(ModelPricing.forModel("claude-sonnet-4-5", cacheRoot: cacheRoot).thresholdTokens, 200_000)
        XCTAssertEqual(ModelPricing.forModel("anthropic.claude-sonnet-4-20250514-v1:0", cacheRoot: cacheRoot).cacheReadPerMAboveThreshold, 0.6)
        XCTAssertEqual(ModelPricing.forModel("claude-sonnet-4-6", cacheRoot: cacheRoot).outputPerM, 15)
        XCTAssertEqual(ModelPricing.forModel("gpt-5.5", cacheRoot: cacheRoot).outputPerM, 30)
        XCTAssertEqual(ModelPricing.codexPriorityForModel("gpt-5.5")?.outputPerM, 75)
        XCTAssertNotNil(ModelPricing.codexPriorityForModel("gpt-5.5", inputTokens: 272_000))
        XCTAssertNil(ModelPricing.codexPriorityForModel("gpt-5.5", inputTokens: 272_001))
        XCTAssertEqual(ModelPricing.forModel("gpt-5.5-pro", cacheRoot: cacheRoot).inputPerM, 30)
        XCTAssertEqual(ModelPricing.forModel("gpt-5.5-pro", cacheRoot: cacheRoot).outputPerM, 180)
        XCTAssertNil(ModelPricing.codexPriorityForModel("gpt-5.5-pro"))
        XCTAssertEqual(ModelPricing.forModel("gpt-5.4", cacheRoot: cacheRoot).inputPerM, 2.5)
        XCTAssertEqual(ModelPricing.forModel("gpt-5.4-pro", cacheRoot: cacheRoot).outputPerM, 180)
        XCTAssertNil(ModelPricing.codexPriorityForModel("gpt-5.4-pro"))
        XCTAssertEqual(ModelPricing.forModel("openai/gpt-5.2-codex-2026-01-15", cacheRoot: cacheRoot).outputPerM, 14)
        XCTAssertEqual(ModelPricing.forModel("gpt-5.3-codex-spark", cacheRoot: cacheRoot).inputPerM, 0)
        XCTAssertEqual(ModelPricing.forModel("gpt-5.3-codex-spark", cacheRoot: cacheRoot).displayLabel, "Research Preview")
        XCTAssertEqual(ModelPricing.codexDisplayLabel("openai/gpt-5.3-codex-spark-2026-02-01"), "Research Preview")
        XCTAssertNil(ModelPricing.codexDisplayLabel("gpt-5.5"))
        XCTAssertEqual(ModelPricing.forModel("gpt-5-nano", cacheRoot: cacheRoot).outputPerM, 0.4)
        XCTAssertEqual(ModelPricing.forModel("gpt-5-mini", cacheRoot: cacheRoot).inputPerM, 0.25)
        let beforeCutoff = ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z")!
        let afterCutoff = ISO8601DateFormatter().date(from: "2026-04-01T00:00:00Z")!
        XCTAssertEqual(
            ModelPricing.forModel("anthropic.claude-sonnet-4-6-v1:0", cacheRoot: cacheRoot, pricingDate: beforeCutoff).thresholdTokens,
            200_000)
        XCTAssertNil(ModelPricing.forModel("claude-sonnet-4-6", cacheRoot: cacheRoot, pricingDate: afterCutoff).thresholdTokens)

        let fingerprint = ModelPricing.builtInPricingFingerprint()
        XCTAssertTrue(fingerprint.contains("codexPriorityInputTokenLimit=272000"))
        XCTAssertTrue(fingerprint.contains("codex|model=gpt-5.5-pro|30|180|30|30"))
        XCTAssertTrue(fingerprint.contains("codex-priority|model=gpt-5.5|12.5|75|12.5|1.25"))
        XCTAssertTrue(fingerprint.contains("codex|model=gpt-5.3-codex-spark|0|0|0|0|nil|nil|nil|nil|nil|Research Preview"))
        XCTAssertTrue(fingerprint.contains("claude|model=claude-fable-5|10|50|12.5|1"))
        XCTAssertTrue(fingerprint.contains("claude-historical|model=claude-sonnet-4-6|"))
    }

    private func cachedFileEntry(cacheRoot: URL, file: URL) throws -> [String: Any] {
        let cacheURL = UsageScanner.fileCacheFileURL(cacheRoot: cacheRoot)
        let data = try Data(contentsOf: cacheURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try XCTUnwrap(object["files"] as? [String: Any])
        return try XCTUnwrap(files[file.standardizedFileURL.path] as? [String: Any])
    }

    private func cachedParsedBytes(_ entry: [String: Any]) throws -> Int64 {
        try XCTUnwrap(entry["parsedBytes"] as? NSNumber).int64Value
    }

    private func cachedSize(_ entry: [String: Any]) throws -> Int64 {
        let stamp = try XCTUnwrap(entry["stamp"] as? [String: Any])
        return try XCTUnwrap(stamp["size"] as? NSNumber).int64Value
    }

    private static func codexSession(input: Int, cached: Int, output: Int) -> String {
        [
            #"{"timestamp":"2026-06-08T09:00:00.000Z","type":"session_meta","payload":{"id":"replace","cwd":"/Users/test/replaced","model":"gpt-5.5"}}"#,
            #"{"timestamp":"2026-06-08T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output)}}}}"#,
        ].joined(separator: "\n") + "\n"
    }

    private func appendText(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private final class CancellationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func check(after threshold: Int) throws {
            lock.lock()
            value += 1
            let shouldCancel = value >= threshold
            lock.unlock()
            if shouldCancel {
                throw CancellationError()
            }
        }
    }

    #if canImport(SQLite3)
    private static func createCodexTraceDatabase(at url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try exec(db, "create table logs (id integer primary key autoincrement, ts integer not null, feedback_log_body text)")
        try exec(db, "create index idx_logs_ts on logs(ts desc, id desc)")
    }

    private static func insertCodexTrace(into url: URL, timestamp: String, body: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "insert into logs (ts, feedback_log_body) values (?, ?)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, epochSeconds(timestamp))
        sqlite3_bind_text(stmt, 2, body, -1, sqliteTransient)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }

    private static func execCodexTrace(into url: URL, sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try exec(db, sql)
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error)
            throw NSError(domain: "UsageScannerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func epochSeconds(_ iso: String) -> Int64 {
        let formatter = ISO8601DateFormatter()
        return Int64((formatter.date(from: iso) ?? Date()).timeIntervalSince1970)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    #endif
}
