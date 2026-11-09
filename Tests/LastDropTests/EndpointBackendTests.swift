import XCTest
@testable import LastDrop

final class EndpointBackendTests: XCTestCase {
    func testEndpointEnvironmentScrubsCredentialsAndPinsEveryModelRole() {
        let profile = EndpointProfile(provider: .zai, directory: "/tmp/zai", model: "glm-5.3", effort: "high")
        let request = SubagentRunner.Request(prompt: "x", sessionID: "s", endpoint: profile)
        let base = ["PATH": "/bin", "ANTHROPIC_AUTH_TOKEN": "wrong", "ANTHROPIC_API_KEY": "wrong",
                    "ANTHROPIC_CUSTOM_HEADERS": "wrong", "ANTHROPIC_DEFAULT_OPUS_MODEL": "wrong",
                    "CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CODE_SUBAGENT_MODEL": "wrong",
                    "CLAUDE_EFFORT": "max", "MAX_THINKING_TOKENS": "123", "CLAUDE_CONFIG_DIR": "/account"]
        let env = SubagentRunner.environment(for: ClaudeAccount(id: "main"), from: base, endpoint: profile)
        XCTAssertEqual(env["PATH"], "/bin")
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/tmp/zai")
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"], "") // apiKeyHelper supplies the token at launch.
        XCTAssertNil(env["ANTHROPIC_CUSTOM_HEADERS"])
        XCTAssertNil(env["CLAUDE_CODE_USE_BEDROCK"])
        XCTAssertNil(env["CLAUDE_EFFORT"])
        XCTAssertNil(env["MAX_THINKING_TOKENS"])
        for key in EndpointProfile.modelVariables { XCTAssertEqual(env[key], "glm-5.3") }
        XCTAssertEqual(env["CLAUDE_CODE_AUTO_MODE_SERVER"], "0")
        XCTAssertEqual(env["CLAUDE_CODE_AUTO_MODE_MODEL"], "glm-5.3")
        XCTAssertNil(SubagentRunner.warmSpec(request, on: ClaudeAccount(id: "main"), in: "/tmp", environment: base))
        let account = SubagentRunner.environment(for: ClaudeAccount(id: "main"), from: base)
        XCTAssertFalse(account.keys.contains { $0.hasPrefix("ANTHROPIC_") })
    }

    func testAutoModeIsJudgedByTheProvidersStrongModel() {
        let flash = EndpointProfile(provider: .zai, directory: "/tmp/zai", model: "glm-5.3-flash", effort: nil)
        XCTAssertEqual(flash.environment["CLAUDE_CODE_AUTO_MODE_SERVER"], "0")
        XCTAssertEqual(flash.environment["CLAUDE_CODE_AUTO_MODE_MODEL"], "glm-5.3")
        let routed = EndpointProfile(provider: .openrouter, directory: "/tmp/or", model: "provider/model", effort: nil)
        XCTAssertEqual(routed.environment["CLAUDE_CODE_AUTO_MODE_MODEL"], "provider/model")
        XCTAssertTrue(flash.arguments.joined().contains("CLAUDE_CODE_AUTO_MODE_SERVER"))
    }

    func testOpenRouterModelsRequireToolsAndDecodeReasoning() throws {
        let root: [String: Any] = ["data": [
            ["id": "plain", "supported_parameters": ["temperature"]],
            ["id": "tools", "name": "Tools", "supported_parameters": ["tools"]],
            ["id": "fallback", "supported_parameters": ["tools", "reasoning"]],
            ["id": "metadata", "supported_parameters": ["tools", "reasoning"],
             "reasoning": ["supported_efforts": ["low", "high", "max"], "default_effort": "high"]]
        ]]
        let models = try OpenRouterBackend.decodeModels(root)
        XCTAssertEqual(Set(models.map(\.id)), ["tools", "fallback", "metadata"])
        XCTAssertEqual(models.first { $0.id == "tools" }?.efforts, [])
        XCTAssertEqual(models.first { $0.id == "fallback" }?.efforts, ["low", "medium", "high"])
        XCTAssertEqual(models.first { $0.id == "metadata" }?.efforts, ["low", "high", "max"])
        XCTAssertEqual(models.first { $0.id == "metadata" }?.defaultEffort, "high")
        XCTAssertThrowsError(try OpenRouterBackend.decodeModels([:]))
    }

    func testEndpointErrorsSeparateExhaustionFromThrottling() {
        for code in [1308, 1310, 1316, 1317, 1318, 1319, 1320, 1321] {
            let result = SubagentRunner.parse(["is_error": true, "api_error_status": 429,
                                              "errors": ["API Error: 429 {\"error\":{\"code\":\"\(code)\",\"message\":\"window exhausted\"}}"]], provider: .zai)
            XCTAssertTrue(result.limitReached, "\(code)")
            XCTAssertTrue(result.text.contains("\(code)"))
        }
        for code in [1302, 1305] {
            XCTAssertFalse(SubagentRunner.parse(["is_error": true, "api_error_status": 429,
                                                "result": "API Error: \(code): rate limit reached"], provider: .zai).limitReached)
        }
        XCTAssertFalse(SubagentRunner.parse(["is_error": true, "api_error_status": 429, "result": "rate limit"], provider: .openrouter).limitReached)
        let credits = SubagentRunner.parse(["is_error": true, "api_error_status": 402, "result": "Insufficient credits"], provider: .openrouter)
        XCTAssertTrue(credits.limitReached)
        XCTAssertTrue(credits.text.contains("credits exhausted"))
        XCTAssertFalse(SubagentRunner.parse(["is_error": false, "result": "HTTP 402"], provider: .openrouter).limitReached)
        let auth = SubagentRunner.parse(["is_error": true, "errors": ["API Error: 401 unauthorized"]], provider: .zai)
        XCTAssertTrue(auth.text.contains("Coding Plan API key"))
        XCTAssertFalse(auth.limitReached)
    }

    func testOpenRouterRejectsManagementKeys() throws {
        try OpenRouterProvider.checkInferenceKey(["data": ["is_management_key": false]])
        for field in ["is_management_key", "is_provisioning_key"] {
            XCTAssertThrowsError(try OpenRouterProvider.checkInferenceKey(["data": [field: true]])) { error in
                XCTAssertTrue(error.localizedDescription.contains("Management keys can't run models"))
            }
        }
        XCTAssertThrowsError(try OpenRouterProvider.checkInferenceKey([:]))
    }

    func testProfileOwnsSettingsAndOnboardingWithoutChangingSharedSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared")
        let dir = root.appendingPathComponent("endpoint")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = shared.appendingPathComponent("settings.json")
        let original = Data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"other-account"}}"#.utf8)
        try original.write(to: settings)
        try Data("role".utf8).write(to: shared.appendingPathComponent("CLAUDE.md"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("settings.json"), withDestinationURL: settings)
        let profile = EndpointProfile(provider: .openrouter, directory: dir.path, model: "provider/model", effort: "high")
        try profile.prepare(helperExecutable: "/Applications/lastdrop App/lastdrop", sharedDirectory: shared.path)
        XCTAssertEqual(try Data(contentsOf: settings), original)
        let owned = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("settings.json"))) as! [String: Any]
        XCTAssertEqual(owned["apiKeyHelper"] as? String, "'/Applications/lastdrop App/lastdrop' --agent-key openrouter")
        XCTAssertNil(owned["env"])
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(".claude.json"))) as! [String: Any]
        XCTAssertEqual(state["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("CLAUDE.md").path), shared.path + "/CLAUDE.md")
        let request = SubagentRunner.Request(prompt: "x", model: "provider/model", sessionID: "s", resume: true, endpoint: profile)
        let args = SubagentRunner.arguments(request)
        XCTAssertTrue(args.contains("--resume"))
        XCTAssertTrue(args.contains("--settings"))
        XCTAssertTrue(args.contains("user"))
        XCTAssertFalse(args.joined().contains("other-account"))
    }

    func testTerminalContinuesInTheSameProfileWithoutEmbeddingAKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work tree")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let fake = root.appendingPathComponent("claude")
        try #"""
        #!/usr/bin/python3
        import os, sys, json
        print(json.dumps({'directory':os.getcwd(),'profile':os.getenv('CLAUDE_CONFIG_DIR'),
            'model':os.getenv('ANTHROPIC_MODEL'),'url':os.getenv('ANTHROPIC_BASE_URL'),
            'auth':os.getenv('ANTHROPIC_AUTH_TOKEN'),'apiKey':os.getenv('ANTHROPIC_API_KEY'),
            'contaminated':any(k in os.environ for k in ['ANTHROPIC_CUSTOM_HEADERS','CLAUDE_CODE_USE_BEDROCK','MAX_THINKING_TOKENS']),
            'arguments':sys.argv[1:]}))
        """#.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let profile = EndpointProfile(provider: .openrouter, directory: root.appendingPathComponent("endpoint profile").path,
                                      model: "provider/model", effort: "high")
        let entry = AgentRegistry.Entry(account: "OpenRouter", directory: work.path, sessionID: "s", model: profile.model,
                                        effort: "high", at: Date())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "export PATH=\(ClaudeSignIn.shellQuote(root.path + ":/usr/bin:/bin"))\n" + profile.terminal(entry)]
        process.environment = ["PATH": root.path + ":/usr/bin:/bin", "ANTHROPIC_AUTH_TOKEN": "wrong",
            "ANTHROPIC_CUSTOM_HEADERS": "wrong", "CLAUDE_CODE_USE_BEDROCK": "1", "MAX_THINKING_TOKENS": "1"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let observed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let observedDirectory = try XCTUnwrap(observed["directory"] as? String)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: observedDirectory)[.systemFileNumber] as? NSNumber,
                       try FileManager.default.attributesOfItem(atPath: work.path)[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(observed["profile"] as? String, profile.directory)
        XCTAssertEqual(observed["model"] as? String, "provider/model")
        XCTAssertEqual(observed["url"] as? String, "https://openrouter.ai/api")
        XCTAssertEqual(observed["auth"] as? String, "")
        XCTAssertEqual(observed["apiKey"] as? String, "")
        XCTAssertEqual(observed["contaminated"] as? Bool, false)
        let args = observed["arguments"] as! [String]
        XCTAssertEqual(Array(args.prefix(4)), ["--resume", "s", "--model", "provider/model"])
        XCTAssertEqual(Array(args.suffix(2)), ["--effort", "high"])
    }

    /// Opt-in real CLI against a local Messages server: helper auth and resume without paid inference.
    func testHeadlessKeyHelperAndResume() throws {
        guard ProcessInfo.processInfo.environment["LASTDROP_ENDPOINT_CLI_TEST"] == "1" else {
            throw XCTSkip("Set LASTDROP_ENDPOINT_CLI_TEST=1 to test the installed Claude Code against a local endpoint.")
        }
        guard let claude = SubagentRunner.executable() else { throw XCTSkip("Claude Code is not installed.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("helper")
        try "#!/bin/sh\nprintf synthetic-endpoint-key\nprintf x >> \(ClaudeSignIn.shellQuote(root.appendingPathComponent("helper-calls").path))\n"
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let profile = EndpointProfile(provider: .zai, directory: root.appendingPathComponent("profile").path, model: "glm-5.3-flash", effort: "low")
        try profile.prepare(helperExecutable: helper.path, sharedDirectory: root.appendingPathComponent("unused").path)
        let request = SubagentRunner.Request(prompt: "Reply with exactly: ok", model: profile.model, effort: "low", sessionID: UUID().uuidString.lowercased(), endpoint: profile)
        let configuration: [String: Any] = ["executable": claude, "arguments": SubagentRunner.arguments(request), "cwd": root.path,
            "environment": SubagentRunner.environment(for: ClaudeAccount(id: "main"), from: ["PATH": "/usr/bin:/bin", "HOME": root.path], endpoint: profile)]
        let config = root.appendingPathComponent("probe.json")
        try JSONSerialization.data(withJSONObject: configuration).write(to: config)
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-c", Self.probe, config.path]
        let output = Pipe()
        python.standardOutput = output
        python.standardError = FileHandle.nullDevice
        try python.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        python.waitUntilExit()
        XCTAssertEqual(python.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        let summary = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(summary["answers"] as? [String], ["ok", "ok"])
        XCTAssertEqual(summary["auth"] as? Bool, true)
        XCTAssertEqual(summary["resume"] as? Bool, true)
        XCTAssertEqual(summary["inits"] as? Int, 2)
        XCTAssertGreaterThanOrEqual(summary["helperCalls"] as? Int ?? 0, 2)
        let failure = SubagentRunner.parse(try XCTUnwrap(summary["creditError"] as? [String: Any]), provider: .openrouter)
        XCTAssertTrue(failure.isError)
        XCTAssertTrue(failure.limitReached)
    }

    func testLiveZAI() async throws { try await live(.zai) }

    func testLiveOpenRouter() async throws { try await live(.openrouter) }

    /// Real inference stays opt-in and uses only temporary profiles, one short turn and one resume.
    private func live(_ provider: AgentProvider) async throws {
        guard ProcessInfo.processInfo.environment["LASTDROP_LIVE_ENDPOINT"] == "1" else {
            throw XCTSkip("Set LASTDROP_LIVE_ENDPOINT=1 for a paid endpoint start and resume check.")
        }
        guard let key = EndpointProfile.apiKey(provider) else { throw XCTSkip("No \(provider.displayName) API key is available.") }
        if provider == .openrouter {
            do { try await OpenRouterProvider.validateInferenceKey(key) }
            catch {
                if error.localizedDescription.contains("Management keys") { throw XCTSkip("The saved OpenRouter key is a management key.") }
                throw error
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var model = "glm-5.3-flash"
        if provider == .openrouter {
            let (body, _) = try await HTTP.json(HTTP.request("https://openrouter.ai/api/v1/models"))
            let candidates = (body as? [String: Any])?.array("data") ?? []
            let eligible = candidates.filter {
                ($0["supported_parameters"] as? [String] ?? []).contains("tools")
                    && $0.dict("pricing")?.double("prompt") != nil && $0.dict("pricing")?.double("completion") != nil
            }.sorted {
                let a = ($0.dict("pricing")?.double("prompt") ?? 0) + ($0.dict("pricing")?.double("completion") ?? 0)
                let b = ($1.dict("pricing")?.double("prompt") ?? 0) + ($1.dict("pricing")?.double("completion") ?? 0)
                return a == b ? ($0.string("id") ?? "") < ($1.string("id") ?? "") : a < b
            }
            guard let cheapest = eligible.first?.string("id") else { throw XCTSkip("No tool-capable OpenRouter model with pricing.") }
            model = cheapest
        }
        let profile = EndpointProfile(provider: provider, directory: root.appendingPathComponent("profile").path, model: model,
                                      effort: provider == .zai ? "low" : nil)
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/lastdrop").path
        try profile.prepare(helperExecutable: executable, sharedDirectory: root.appendingPathComponent("unused").path)
        var request = SubagentRunner.Request(prompt: "Reply with exactly: ok", model: model, effort: profile.effort,
            permissionMode: "default", sessionID: UUID().uuidString.lowercased(), endpoint: profile)
        for turn in 0..<2 {
            let deadline = DispatchSource.makeTimerSource(queue: .global())
            deadline.resume()
            let result = await SubagentRunner.run(request, on: ClaudeAccount(id: "main"), in: root.path, onProcess: { pid in
                deadline.setEventHandler { SubagentRunner.terminate(pid) }
                deadline.schedule(deadline: .now() + 60)
            }, check: { SubagentRunner.checkInit($0, subagentType: nil) }, onStep: { _ in })
            deadline.cancel()
            XCTAssertFalse(result.isError, "\(provider.displayName) turn \(turn): " + result.text.replacingOccurrences(of: key, with: "[redacted]"))
            guard !result.isError else { return }
            XCTAssertEqual(result.text.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
            XCTAssertEqual(result.sessionID, request.sessionID)
            let directory = try XCTUnwrap(result.directory)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory)[.systemFileNumber] as? NSNumber,
                           try FileManager.default.attributesOfItem(atPath: root.path)[.systemFileNumber] as? NSNumber)
            request.resume = true
        }
        print("\(provider.displayName): \(model) headless key helper start and resume passed.")
    }

    private static let probe = #"""
import sys, json, pathlib, subprocess, threading, http.server
config = json.load(open(sys.argv[1]))
requests = []
credit_error = False
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append((body, self.headers.get('Authorization') == 'Bearer synthetic-endpoint-key'))
        if credit_error:
            self.send_response(402); self.send_header('Content-Type','application/json'); self.end_headers()
            self.wfile.write(b'{"error":{"type":"billing_error","message":"Insufficient credits","code":402}}'); return
        if '/count_tokens' in self.path:
            self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
            self.wfile.write(b'{"input_tokens":10}'); return
        events = [
            ('message_start', {'type':'message_start','message':{'id':'msg_test','type':'message','role':'assistant','model':body['model'],'content':[],'stop_reason':None,'stop_sequence':None,'usage':{'input_tokens':10,'output_tokens':0}}}),
            ('content_block_start', {'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}}),
            ('content_block_delta', {'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'ok'}}),
            ('content_block_stop', {'type':'content_block_stop','index':0}),
            ('message_delta', {'type':'message_delta','delta':{'stop_reason':'end_turn','stop_sequence':None},'usage':{'output_tokens':1}}),
            ('message_stop', {'type':'message_stop'})]
        self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
        for name, value in events:
            self.wfile.write(('event: '+name+'\ndata: '+json.dumps(value)+'\n\n').encode())
        self.wfile.flush()
server = http.server.HTTPServer(('127.0.0.1',0), Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
url = 'http://127.0.0.1:'+str(server.server_port)
env = config['environment']; env['ANTHROPIC_BASE_URL'] = url
args = config['arguments']; i = args.index('--settings')+1
settings = json.loads(args[i]); settings['env']['ANTHROPIC_BASE_URL'] = url; args[i] = json.dumps(settings)
answers = []
inits = 0
for turn in range(2):
    completed = subprocess.run([config['executable']]+args, input='Reply with exactly: ok', capture_output=True, text=True, env=env, cwd=config['cwd'], timeout=50)
    events = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith('{')]
    inits += sum(e.get('type') == 'system' and e.get('subtype') == 'init' and all(k in e for k in ['session_id','cwd','model','agents']) for e in events)
    results = [e for e in events if e.get('type') == 'result']
    if not results or completed.returncode != 0:
        print(json.dumps({'error':'CLI failed','status':completed.returncode,'result':results})); sys.exit(1)
    answers.append(results[-1].get('result'))
    if turn == 0: args[args.index('--session-id')] = '--resume'
resumed = len(requests[-1][0]['messages']) > len(requests[0][0]['messages'])
credit_error = True
completed = subprocess.run([config['executable']]+args, input='Reply with exactly: ok', capture_output=True, text=True, env=env, cwd=config['cwd'], timeout=50)
errors = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith('{') and json.loads(line).get('type') == 'result']
server.shutdown()
print(json.dumps({'answers':answers,'inits':inits,'auth':all(auth for _,auth in requests),'resume':resumed,
    'creditError':errors[-1] if errors else {}, 'helperCalls':len(pathlib.Path(config['cwd'],'helper-calls').read_text())}))
"""#
}
