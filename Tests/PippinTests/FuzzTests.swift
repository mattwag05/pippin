import Foundation
import JavaScriptCore
@testable import PippinLib
import XCTest

/// Seeded fuzz tests. Every target must hold: never crashes, never hangs,
/// returns a value or throws a typed error. Nothing here reaches an Apple app:
/// the MCP path runs against doubles that keep each real tool's name, schema
/// and `buildArgs` but return a canned envelope.
///
/// Replay a failure with `PIPPIN_FUZZ_SEED=<seed> swift test --filter FuzzTests`.
final class FuzzTests: XCTestCase {
    // MARK: - SchemaValidator and buildArgs over every registered tool

    func testSchemaValidatorAndBuildArgsNeverTrapOnRandomArguments() {
        let seed = Fuzz.seed(default: 0x5EED_0001)
        var rng = FuzzRNG(seed: seed)
        for tool in MCPToolRegistry.tools {
            for _ in 0 ..< 60 {
                let args = Fuzz.arguments(&rng, for: tool.inputSchema)
                let context = "seed \(seed) tool \(tool.name) args \(Fuzz.describe(args))"
                do {
                    try SchemaValidator.validate(args: args, against: tool.inputSchema)
                } catch is SchemaValidatorError {
                    continue
                } catch {
                    XCTFail("validate threw an untyped error \(error): \(context)")
                    continue
                }
                // Accepted arguments must really satisfy the schema.
                if case let .some(.array(required)) = tool.inputSchema["required"] {
                    for name in required.compactMap(\.stringValue) {
                        XCTAssertNotNil(args?[name], "accepted without required '\(name)': \(context)")
                    }
                }
                // buildArgs only builds argv; any throw is fine, a trap is not.
                _ = try? tool.buildArgs(args)
            }
        }
    }

    func testSchemaValidatorNeverTrapsOnRandomSchemas() {
        let seed = Fuzz.seed(default: 0x5EED_0002)
        var rng = FuzzRNG(seed: seed)
        for _ in 0 ..< 2000 {
            let schema = Fuzz.json(&rng)
            let args: JSONValue? = rng.chance(10) ? nil : Fuzz.json(&rng)
            do {
                try SchemaValidator.validate(args: args, against: schema)
            } catch is SchemaValidatorError {
                continue
            } catch {
                XCTFail("untyped error \(error): seed \(seed) schema \(Fuzz.describe(schema)) args \(Fuzz.describe(args))")
            }
        }
    }

    // MARK: - MCP request path

    /// Mirror of the `mcp-server` stdin loop body (McpServerCommand.run), which
    /// is not callable in process: one line in, one JSON-RPC reply or nil out.
    private func serve(_ line: Data, tools: [MCPTool]) async -> Data? {
        // readLine repairs invalid UTF-8 the same way.
        let trimmed = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        let response: JSONRPCResponse
        do {
            let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(trimmed.utf8))
            guard let handled = await MCPDispatcher.handle(
                request, pippinPath: "/usr/bin/false", tools: tools,
                // Mutating tools go through the safety gate to a child; answer for it.
                runner: { _ in (Self.cannedEnvelope, false) }
            ) else {
                return nil
            }
            response = handled
        } catch {
            response = JSONRPCResponse(
                id: .null,
                error: JSONRPCError(code: JSONRPCError.parseError, message: "Invalid JSON-RPC request: \(error.localizedDescription)")
            )
        }
        return try? JSONEncoder().encode(response)
    }

    private static let cannedEnvelope = #"{"v":1,"status":"ok","duration_ms":0,"data":[]}"#

    /// Every real tool, with its real schema and argv builder, answering from a
    /// constant instead of touching an app or spawning a child. Renamed so a
    /// tool another test demoted to the child path cannot change the outcome.
    private static let doubles: [MCPTool] = MCPToolRegistry.tools.map { tool in
        MCPTool(
            name: "fuzz_\(tool.name)", effect: tool.effect, description: tool.description, inputSchema: tool.inputSchema,
            buildArgs: tool.buildArgs, inProcess: { _ in cannedEnvelope }
        )
    }

    private func requestLine(_ rng: inout FuzzRNG) -> Data {
        var object: [String: JSONValue] = [:]
        if rng.chance(90) { object["jsonrpc"] = rng.chance(90) ? .string("2.0") : Fuzz.json(&rng) }
        if rng.chance(85) {
            object["id"] = rng.chance(80)
                ? rng.pick([.int(1), .int(Int64.min), .string("a"), .string(Fuzz.string(&rng)), .null])
                : Fuzz.json(&rng)
        }
        let method = rng.pick(["initialize", "tools/list", "tools/call", "tools/call", "tools/call", "ping", "nope"])
        // tools/list encodes all tool descriptors; keep it rare so the file stays fast.
        object["method"] = rng.chance(90)
            ? .string(method == "tools/list" && rng.chance(90) ? "ping" : method)
            : Fuzz.json(&rng)
        if method == "tools/call", rng.chance(90) {
            let tool = rng.pick(Self.doubles)
            var params: [String: JSONValue] = ["name": rng.chance(90) ? .string(tool.name) : Fuzz.json(&rng)]
            if let arguments = Fuzz.arguments(&rng, for: tool.inputSchema) { params["arguments"] = arguments }
            object["params"] = .object(params)
        } else if rng.chance(50) {
            object["params"] = Fuzz.json(&rng)
        }
        return (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data()
    }

    private func mutate(_ line: Data, _ rng: inout FuzzRNG) -> Data {
        var bytes = [UInt8](line)
        for _ in 0 ... rng.below(3) where !bytes.isEmpty {
            let at = rng.below(bytes.count)
            switch rng.below(5) {
            case 0: bytes[at] = UInt8(truncatingIfNeeded: rng.next())
            case 1: bytes.insert(rng.pick([0x00, 0xFF, 0xC0, 0xED, 0x22, 0x5C, 0x7B, 0x5B]), at: at)
            case 2: bytes.removeSubrange(at...)
            case 3: bytes.remove(at: at)
            default: bytes.insert(contentsOf: bytes[at...].prefix(16), at: at)
            }
        }
        return Data(bytes)
    }

    /// A reply must be one JSON-RPC 2.0 object carrying exactly one of
    /// `result` or `error`; a tool result must carry a JSON envelope.
    /// Returns true when the reply is a successful tool result.
    @discardableResult
    private func assertWellFormedReply(_ reply: Data, _ context: @autoclosure () -> String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            XCTFail("reply is not a JSON object: \(context())")
            return false
        }
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0", context())
        XCTAssertNotNil(object["id"], context())
        XCTAssertNotEqual(object["result"] == nil, object["error"] == nil, "want exactly one of result/error: \(context())")
        guard let result = object["result"] as? [String: Any], let content = result["content"] as? [[String: Any]] else {
            return false
        }
        guard let text = content.first?["text"] as? String,
              let envelope = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else {
            XCTFail("tool result text is not a JSON envelope: \(context())")
            return false
        }
        let isError = result["isError"] as? Bool ?? false
        XCTAssertEqual(envelope["status"] as? String, isError ? "error" : "ok", context())
        return !isError
    }

    func testMCPRequestPathAlwaysRepliesOrIgnores() async {
        let seed = Fuzz.seed(default: 0x5EED_0003)
        var rng = FuzzRNG(seed: seed)
        var replies = 0
        var toolSuccesses = 0
        for iteration in 0 ..< 1500 {
            var line = requestLine(&rng)
            switch rng.below(10) {
            case 0 ... 3: line = mutate(line, &rng)
            case 4: line = Fuzz.bytes(&rng, max: 200)
            default: break
            }
            guard let reply = await serve(line, tools: Self.doubles) else { continue }
            replies += 1
            if assertWellFormedReply(reply, "seed \(seed) iteration \(iteration) line \(String(decoding: line, as: UTF8.self))") {
                toolSuccesses += 1
            }
        }
        // The generator must reach both ends of the path, or it proves nothing.
        print("fuzz seed \(seed): \(replies) replies, \(toolSuccesses) successful tool calls")
        XCTAssertGreaterThan(replies, 500, "seed \(seed)")
        XCTAssertGreaterThan(toolSuccesses, 30, "seed \(seed): too few calls got past validation to a handler")
    }

    func testMCPRequestPathSurvivesPathologicalLines() async {
        let huge = String(repeating: "A", count: 2_000_000)
        let lines: [(name: String, line: Data)] = [
            ("nul bytes", Data([0x00, 0x00, 0x00])),
            ("nul inside json", Data(#"{"jsonrpc":"2.0","id":1,"method":"pi"#.utf8) + Data([0x00]) + Data(#"ng"}"#.utf8)),
            ("invalid utf8", Data([0xFF, 0xFE, 0xC0, 0xAF, 0xED, 0xA0, 0x80])),
            ("invalid utf8 in method", Data(#"{"id":1,"method":""#.utf8) + Data([0xC3, 0x28]) + Data(#""}"#.utf8)),
            ("deep arrays", Data(String(repeating: "[", count: 100_000).utf8)),
            ("deep balanced arrays", Data((String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)).utf8)),
            ("deep params", Data((#"{"id":1,"method":"ping","params":"# + String(repeating: #"{"a":"#, count: 2000) + "1"
                    + String(repeating: "}", count: 2001)).utf8)),
            ("huge method", Data(#"{"jsonrpc":"2.0","id":1,"method":"\#(huge)"}"#.utf8)),
            ("huge tool name", Data(#"{"id":1,"method":"tools/call","params":{"name":"\#(huge)"}}"#.utf8)),
            ("huge argument", Data(#"{"id":1,"method":"tools/call","params":{"name":"fuzz_mail_search","arguments":{"query":"\#(huge)"}}}"#.utf8)),
            ("array root", Data("[1,2,3]".utf8)),
            ("batch", Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.utf8)),
            ("string root", Data(#""ping""#.utf8)),
            ("method wrong type", Data(#"{"id":1,"method":7}"#.utf8)),
            ("id wrong type", Data(#"{"id":{"a":1},"method":"ping"}"#.utf8)),
            ("id float", Data(#"{"id":1.5,"method":"ping"}"#.utf8)),
            ("id overflow", Data(#"{"id":99999999999999999999999,"method":"ping"}"#.utf8)),
            ("params wrong type", Data(#"{"id":1,"method":"tools/call","params":"x"}"#.utf8)),
            ("name wrong type", Data(#"{"id":1,"method":"tools/call","params":{"name":[]}}"#.utf8)),
            ("arguments wrong type", Data(#"{"id":1,"method":"tools/call","params":{"name":"fuzz_mail_list","arguments":[1]}}"#.utf8)),
            ("limit out of range", Data(#"{"id":1,"method":"tools/call","params":{"name":"fuzz_mail_list","arguments":{"limit":1e999}}}"#.utf8)),
            ("duplicate keys", Data(#"{"id":1,"id":2,"method":"ping","method":"x"}"#.utf8)),
            ("truncated", Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/ca"#.utf8)),
            ("bom", Data([0xEF, 0xBB, 0xBF]) + Data(#"{"id":1,"method":"ping"}"#.utf8)),
            ("lone surrogate escape", Data(#"{"id":"\ud800","method":"ping"}"#.utf8)),
        ]
        for (name, line) in lines {
            if let reply = await serve(line, tools: Self.doubles) {
                assertWellFormedReply(reply, name)
            }
        }
    }

    // MARK: - Agent-supplied and store-supplied parsers

    func testMailCompoundIdParserReturnsOrThrowsTyped() {
        let seed = Fuzz.seed(default: 0x5EED_0004)
        var rng = FuzzRNG(seed: seed)
        for _ in 0 ..< 3000 {
            let input = rng.chance(50)
                ? Fuzz.string(&rng)
                : [Fuzz.string(&rng, maxPieces: 2), Fuzz.string(&rng, maxPieces: 2), Fuzz.string(&rng, maxPieces: 2)]
                .joined(separator: "||")
            do {
                let parsed = try MailBridge.parseCompoundId(input)
                // The message id is written into scripts unquoted: digits only.
                XCTAssertTrue(
                    !parsed.messageId.isEmpty && parsed.messageId.utf8.allSatisfy { (0x30 ... 0x39).contains($0) },
                    "non-numeric id accepted: seed \(seed) input \(input.debugDescription)"
                )
                XCTAssertEqual([parsed.account, parsed.mailbox, parsed.messageId].joined(separator: "||"), input)
            } catch MailBridgeError.invalidMessageId {
                continue
            } catch {
                XCTFail("untyped error \(error): seed \(seed) input \(input.debugDescription)")
            }
        }
    }

    func testCursorTokenDecodingReturnsOrThrowsTyped() throws {
        let seed = Fuzz.seed(default: 0x5EED_0005)
        var rng = FuzzRNG(seed: seed)
        let blank = try PaginationOptions.parse([])
        for _ in 0 ..< 3000 {
            let token: String
            switch rng.below(4) {
            case 0: token = Fuzz.string(&rng)
            case 1: token = Fuzz.bytes(&rng).base64EncodedString()
            case 2:
                // A decodable cursor with hostile fields.
                let json = #"{"offset":\#(rng.pick(["0", "-1", "9223372036854775807", "1e3", "\"1\"", "1.5"])),"filter_hash":\#(Fuzz.describe(.string(Fuzz.string(&rng))))}"#
                token = Data(json.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            default: token = Fuzz.describe(Fuzz.json(&rng))
            }
            let context = "seed \(seed) token \(token.debugDescription)"
            var options = blank
            options.cursor = token
            options.pageSize = rng.pick([nil, 0, -1, 1, 50, Int.max])
            do {
                let cursor = try Pagination.decode(token)
                // A decoded cursor must be safe to page with, whatever it carries.
                let resolved = try Pagination.resolve(options, defaultPageSize: 20, filterHash: cursor.filterHash)
                XCTAssertGreaterThanOrEqual(resolved.offset, 0, context)
                let page = try Pagination.paginate(
                    all: [1, 2, 3], offset: cursor.offset, pageSize: resolved.pageSize, filterHash: cursor.filterHash
                )
                XCTAssertLessThanOrEqual(page.items.count, 3, context)
                _ = try Pagination.pageFromPushdown(
                    fetched: [1, 2, 3], offset: cursor.offset, pageSize: resolved.pageSize, filterHash: cursor.filterHash
                )
            } catch is CursorError {
                continue
            } catch {
                XCTFail("untyped error \(error): \(context)")
            }
        }
    }

    /// Largest `--page` the fuzz feeds `Pagination.resolve`. Beyond
    /// `Int.max / maxPageSize` the offset multiplication traps: see
    /// `testKnownBugHugePageNumberTraps`.
    private static let safePageCeiling = Int.max

    func testPageNumberResolutionReturnsOrThrowsTyped() throws {
        let seed = Fuzz.seed(default: 0x5EED_0006)
        var rng = FuzzRNG(seed: seed)
        let blank = try PaginationOptions.parse([])
        for _ in 0 ..< 2000 {
            var options = blank
            options.page = rng.pick([Int.min, -1, 0, 1, 2, 1000, Self.safePageCeiling, rng.below(Self.safePageCeiling)])
            options.pageSize = rng.pick([nil, Int.min, -1, 0, 1, 50, Pagination.maxPageSize, Int.max])
            do {
                let resolved = try Pagination.resolve(options, defaultPageSize: rng.pick([20, 0, -5, Int.max]), filterHash: "h")
                XCTAssertGreaterThanOrEqual(resolved.offset, 0, "seed \(seed) page \(String(describing: options.page))")
                XCTAssertTrue((1 ... Pagination.maxPageSize).contains(resolved.pageSize))
            } catch is CursorError {
                continue
            } catch {
                XCTFail("untyped error \(error): seed \(seed)")
            }
        }
    }

    func testDateAndRangeParsersNeverTrap() {
        let seed = Fuzz.seed(default: 0x5EED_0007)
        var rng = FuzzRNG(seed: seed)
        let started = Date()
        for _ in 0 ..< 1000 {
            let input = Fuzz.string(&rng, maxPieces: 4)
            let context = "seed \(seed) input \(input.debugDescription)"
            _ = parseCalendarDate(input)
            _ = EventSpan(argument: input)
            _ = parseDateString(input)
            _ = parseReminderPriority(input)
            _ = MailBridge.parseFilterDate(input)
            _ = MailEnvelopeIndex.parseFilterDateUTC(input)
            _ = MailBridge.normalizeMessageId(input)
            if let range = parseRange(input) {
                XCTAssertLessThan(range.start, range.end, context)
            }
            if let seconds = parseAlertDuration(input) {
                XCTAssertTrue(seconds.isFinite && seconds >= 0, context)
            }
            if let priority = parseReminderPriority(input) {
                XCTAssertTrue([0, 1, 5, 9].contains(priority), context)
            }
        }
        // Digit runs long enough to overflow every integer type on the way.
        for digits in [20, 40, 400] {
            let run = String(repeating: "9", count: digits)
            XCTAssertNil(parseRange("today+\(run)"))
            XCTAssertNil(parseReminderPriority(run))
            _ = parseAlertDuration("\(run)d")
            _ = parseCalendarDate("\(run)-01-01")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "date parsers took too long: seed \(seed)")
    }

    /// Largest count the fuzz feeds `parseDuration` with a week unit. Beyond
    /// it the unit multiplication traps: see `testKnownBugHugeDurationTraps`.
    private static let safeDurationCeiling = Int.max

    func testJobDurationParserReturnsOrThrowsTyped() {
        let seed = Fuzz.seed(default: 0x5EED_0008)
        var rng = FuzzRNG(seed: seed)
        for _ in 0 ..< 3000 {
            let input: String
            if rng.chance(50) {
                let count = rng.pick([0, 1, 7, rng.below(1_000_000), Self.safeDurationCeiling])
                input = "\(rng.pick(["", " ", "-", "+"]))\(count)\(rng.pick(["s", "m", "h", "d", "w", "W", "y", "", "🌍"]))"
            } else {
                // Skip the counts that reach the documented overflow.
                input = Fuzz.string(&rng, maxPieces: 3)
                if let count = Int(input.trimmingCharacters(in: .whitespaces).dropLast()), count > Self.safeDurationCeiling {
                    continue
                }
            }
            do {
                let seconds = try parseDuration(input)
                XCTAssertGreaterThanOrEqual(seconds, 0, "seed \(seed) input \(input.debugDescription)")
            } catch JobCommandError.invalidDuration {
                continue
            } catch {
                XCTFail("untyped error \(error): seed \(seed) input \(input.debugDescription)")
            }
        }
    }

    func testStoreSuppliedTextParsersNeverTrap() {
        let seed = Fuzz.seed(default: 0x5EED_0009)
        var rng = FuzzRNG(seed: seed)
        for _ in 0 ..< 1500 {
            let input = Fuzz.string(&rng, maxPieces: 12)
            let context = "seed \(seed) input \(input.debugDescription)"
            let headers = RawHeaders.parse(input)
            XCTAssertTrue(headers.allSatisfy { !$0.name.isEmpty && !$0.name.contains(":") }, context)
            _ = RawHeaders.authChain(headers)
            if let mailbox = MailEnvelopeIndex.parseMailboxURL(input) {
                XCTAssertFalse(mailbox.uuid.isEmpty || mailbox.leaf.isEmpty, context)
            }
            _ = FieldProjection.parse(input)
            _ = MessagesDatabase.cleanDecodedBody(input)
            _ = MessagesDatabase.escapeLike(input)
            _ = MessagesDatabase.preview(input, limit: rng.pick([0, 1, 140]))
            _ = try? OutputFormat.parse(input)
            _ = try? IntentPlanner.parsePlan(input)
            _ = try? IntentPlanner.parseExclusions(input)
            _ = try? AccessibilityTree.parse(input)
            // Whatever a child printed, `do` gets a JSON value back.
            _ = DoCommand.decodeChildStdout(Data(input.utf8))
            _ = DoCommand.decodeChildStdout(Fuzz.bytes(&rng))
        }
    }

    func testMessagesTimestampHelpersNeverTrap() {
        let seed = Fuzz.seed(default: 0x5EED_000A)
        var rng = FuzzRNG(seed: seed)
        let edges: [Int64] = [0, 1, -1, 1_000_000_000_000, 1_000_000_000_001, Int64.max, Int64.min]
        for _ in 0 ..< 500 {
            let nanos = rng.chance(30) ? rng.pick(edges) : Int64(truncatingIfNeeded: rng.next())
            let date = MessagesDatabase.date(fromAppleNanos: nanos)
            _ = MessagesDatabase.appleNanos(from: date)
            _ = MessagesDatabase.iso8601(fromAppleNanos: nanos)
            XCTAssertTrue((0 ... 100_000).contains(MessagesDatabase.clampLimit(Int(truncatingIfNeeded: nanos))))
        }
        for date in [Date.distantPast, .distantFuture, Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude)] {
            _ = MessagesDatabase.appleNanos(from: date)
        }
    }

    // MARK: - Messages attributedBody (typedstream) decoder

    /// Same synthetic archive as MessagesAttributedBodyTests: an
    /// NSAttributedString "Hello, typedstream world!" plus an emoji.
    private static let typedstream = Data(base64Encoded:
        "BAtzdHJlYW10eXBlZIHoA4QBQISEhBJOU0F0dHJpYnV0ZWRTdHJpbmcAhIQITlNPYmplY3QAhZKEhIQI" +
            "TlNTdHJpbmcBlIQBKx5IZWxsbywgdHlwZWRzdHJlYW0gd29ybGQhIPCfjI2GhAJpSQEckoSEhAxOU0Rp" +
            "Y3Rpb25hcnkAlIQBaQCGhg==")!

    func testAttributedBodyDecoderSurvivesRandomAndTruncatedBlobs() {
        let seed = Fuzz.seed(default: 0x5EED_000B)
        var rng = FuzzRNG(seed: seed)
        let header = Self.typedstream.prefix(16)
        for _ in 0 ..< 300 {
            // Random bytes, bare or behind a valid typedstream header.
            _ = MessagesDatabase.resolveBody(text: nil, attributedBody: Fuzz.bytes(&rng, max: 128))
            _ = MessagesDatabase.resolveBody(text: nil, attributedBody: header + Fuzz.bytes(&rng, max: 128))
        }
        for length in 0 ... Self.typedstream.count {
            _ = MessagesDatabase.resolveBody(text: nil, attributedBody: Self.typedstream.prefix(length))
        }
    }

    // MARK: - JS string escaping round trip

    private func evaluatedLiteral(_ value: String, quote: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let context = JSContext()!
        let result = context.evaluateScript("(\(quote)\(jsEscape(value))\(quote))")
        if let exception = context.exception {
            XCTFail("literal did not parse (\(exception)): \(value.debugDescription)", file: file, line: line)
            return nil
        }
        guard let result, result.isString else {
            XCTFail("literal did not evaluate to a string: \(value.debugDescription)", file: file, line: line)
            return nil
        }
        return result.toString()
    }

    private static func hostileManifestStrings() throws -> [(key: String, value: String)] {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("bench/competitive/fixtures/manifest.json")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let hostile = try XCTUnwrap(root["hostile_inputs"] as? [String: Any])
        let items = try XCTUnwrap(hostile["items"] as? [[String: Any]])
        return try items.map { item in
            let key = try XCTUnwrap(item["key"] as? String)
            if let value = item["value"] as? String { return (key, value) }
            let spec = try XCTUnwrap(item["value"] as? [String: Any], "\(key): value is neither a string nor a repeat spec")
            return try (key, String(repeating: XCTUnwrap(spec["repeat"] as? String), count: XCTUnwrap(spec["times"] as? Int)))
        }
    }

    func testHostileManifestStringsRoundTripThroughJsEscape() throws {
        let items = try Self.hostileManifestStrings()
        XCTAssertGreaterThanOrEqual(items.count, 20, "hostile fixture list looks truncated")
        for (key, value) in items {
            for quote in ["'", "\""] {
                XCTAssertEqual(evaluatedLiteral(value, quote: quote), value, "\(key) changed inside a \(quote) literal")
            }
            XCTAssertEqual(evaluatedLiteral(value, quote: "'"), value, key)
            // The array form MailBridge builds for mailbox and id lists.
            let context = JSContext()!
            let array = context.evaluateScript(MailBridge.jsStringArray([value, value]))
            XCTAssertNil(context.exception, "\(key): array literal did not parse")
            XCTAssertEqual(array?.toArray() as? [String], [value, value], key)
        }
    }

    func testRandomStringsRoundTripThroughJsEscape() {
        let seed = Fuzz.seed(default: 0x5EED_000C)
        var rng = FuzzRNG(seed: seed)
        var checked = 0
        for _ in 0 ..< 1500 {
            let value = Fuzz.string(&rng)
            checked += 1
            for quote in ["'", "\""] where evaluatedLiteral(value, quote: quote) != value {
                XCTFail("seed \(seed): \(value.debugDescription) changed inside a \(quote) literal")
            }
        }
        XCTAssertEqual(checked, 1500)
    }

    // MARK: - Regressions for bugs the fuzzers found

    func testNulBeforeOctalDigitRoundTrips() {
        XCTAssertEqual(evaluatedLiteral("a\u{0}7b", quote: "'"), "a\u{0}7b")
    }

    func testCharacterBeforeCombiningMarkIsEscaped() {
        XCTAssertEqual(jsEscape("it'\u{301}s"), "it\\'\u{301}s")
        XCTAssertEqual(evaluatedLiteral("it'\u{301}s", quote: "'"), "it'\u{301}s")
        XCTAssertEqual(evaluatedLiteral("a\\\u{301}b", quote: "'"), "a\\\u{301}b")
    }

    func testHugePageNumberIsRejectedNotTrapped() throws {
        var options = try PaginationOptions.parse([])
        options.page = Int.max
        XCTAssertThrowsError(try Pagination.resolve(options, defaultPageSize: 20, filterHash: "h"))
    }

    func testHugeDurationIsRejectedNotTrapped() {
        XCTAssertThrowsError(try parseDuration("9223372036854775807w"))
    }

    private static var nonStrict: XCTExpectedFailure.Options {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        return options
    }
}
