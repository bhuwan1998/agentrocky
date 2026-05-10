//
//  ClaudeSession.swift
//  agentrocky
//

import Foundation
import Combine
import Darwin
import AVFoundation

enum AgentProvider: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case opencode = "OpenCode"

    private static let defaultProviderKey = "rocky.defaultAgentProvider"

    var id: String { rawValue }

    static var savedDefault: AgentProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultProviderKey),
                  let provider = AgentProvider(rawValue: raw) else {
                return .claude
            }
            return provider
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultProviderKey)
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: return "sonnet"
        case .codex: return "gpt-5.5"
        case .opencode: return "opencode/big-pickle"
        }
    }

    var modelSuggestions: [String] {
        switch self {
        case .claude:
            return ["sonnet", "opus", "claude-sonnet-4-6"]
        case .codex:
            return ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex", "gpt-5.3-codex-spark"]
        case .opencode:
            return [
                "opencode/big-pickle",
                "github-copilot/claude-sonnet-4-6",
                "anthropic/claude-sonnet-4-5",
                "anthropic/claude-opus-4-5",
                "openai/gpt-4o",
                "google/gemini-2-5-pro",
            ]
        }
    }

    var thinkingOptions: [AgentThinking] {
        switch self {
        case .claude: return [.low, .medium, .high, .xhigh, .max]
        case .codex: return [.low, .medium, .high, .xhigh]
        case .opencode: return [.low, .medium, .high, .xhigh, .max]
        }
    }
}

enum AgentThinking: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }
}

class AgentSession: ObservableObject {
    @Published var lines: [OutputLine] = []
    @Published var isReady: Bool = false
    @Published var isRunning: Bool = false
    @Published var provider: AgentProvider
    @Published var model: String
    @Published var thinking: AgentThinking = .high
    @Published var isSpeechEnabled: Bool = true

    let workingDirectory: String

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readBuffer = Data()
    private var conversationHistory: [ConversationTurn] = []
    private let queue = DispatchQueue(label: "rocky.session", qos: .userInitiated)
    private let synthesizer = AVSpeechSynthesizer()
    // AVAudioPlayer for Coqui/rocky_say WAV playback; kept as property to
    // prevent ARC from releasing it before playback finishes.
    private var audioPlayer: AVAudioPlayer?

    struct OutputLine: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case text, tool, system, error }
    }

    private struct ConversationTurn {
        let role: String
        let text: String
    }

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        let defaultProvider = AgentProvider.savedDefault
        self.provider = defaultProvider
        self.model = defaultProvider.defaultModel
        start()
    }

    deinit {
        stopActiveProcess()
    }

    // MARK: - Public

    func send(prompt: String) {
        guard !isRunning else { return }
        remember(role: "user", text: prompt)

        // RAG intercept: if the question is about Rocky himself (his identity,
        // species, backstory, personality), answer directly from the local
        // knowledge base without invoking the agent backend. This gives accurate
        // in-character answers instantly, in Rocky's own voice.
        if isRockyIdentityQuery(prompt) {
            queryRockyRAG(prompt)
            return
        }

        switch provider {
        case .claude:
            sendClaude(prompt: prompt)
        case .codex:
            runCodex(prompt: prompt)
        case .opencode:
            runOpenCode(prompt: prompt)
        }
    }

    // MARK: - Rocky RAG

    /// Returns true if the prompt is asking about Rocky's identity, name, or backstory.
    private func isRockyIdentityQuery(_ prompt: String) -> Bool {
        let p = prompt.lowercased()
        let identityPhrases = [
            "who are you", "what are you", "what is your name", "what's your name",
            "whats your name", "your name", "who is rocky", "what is rocky",
            "tell me about rocky", "describe rocky", "what species", "what kind of",
            "are you an ai", "are you claude", "are you opencode", "are you a robot",
            "are you human", "where are you from", "where is rocky from",
            "eridian", "your home", "your planet", "erid", "your species",
            "how do you see", "echolocation", "your ship", "blip-a",
            "your mission", "astrophage", "grace", "hail mary",
            "your history", "your background", "your personality",
            "how do you communicate", "how do you speak",
            "your appearance", "what do you look like", "how many legs",
            "five legs", "five arms", "your crew", "your journey",
            "introduce yourself", "tell me about yourself"
        ]
        return identityPhrases.contains { p.contains($0) }
    }

    /// Hits the local RAG /ask endpoint, displays the answer, and speaks it.
    /// Falls back to the normal agent backend if the server isn't running.
    private func queryRockyRAG(_ prompt: String) {
        guard let url = URL(string: "http://127.0.0.1:59720/ask") else { return }

        isRunning = true
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": prompt])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }

            // If RAG server isn't available, fall through to normal agent
            guard error == nil,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answer = json["answer"] as? String, !answer.isEmpty
            else {
                DispatchQueue.main.async {
                    self.isRunning = false
                    // Fall back to whichever agent backend is selected
                    switch self.provider {
                    case .claude:   self.sendClaude(prompt: prompt)
                    case .codex:    self.runCodex(prompt: prompt)
                    case .opencode: self.runOpenCode(prompt: prompt)
                    }
                }
                return
            }

            DispatchQueue.main.async {
                self.append("rocky: \(answer)", kind: .text)
                self.isRunning = false

                // Play pre-synthesized WAV from server if available,
                // otherwise speak the text through the normal TTS path.
                if let b64 = json["audio_b64"] as? String, !b64.isEmpty,
                   let wavData = Data(base64Encoded: b64) {
                    self.playWAV(wavData)
                } else if self.isSpeechEnabled {
                    self.speak("rocky: \(answer)")
                }
            }
        }.resume()
    }

    func newSession() {
        stopActiveProcess()
        synthesizer.stopSpeaking(at: .immediate)
        readBuffer.removeAll()
        conversationHistory.removeAll()
        isRunning = false
        isReady = false
        lines.removeAll()
        start()
    }

    func applySettings(provider newProvider: AgentProvider, model newModel: String, thinking newThinking: AgentThinking) {
        guard !isRunning else {
            append("Wait for the current task to finish before changing agent settings.", kind: .system)
            return
        }

        let normalizedModel = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        provider = newProvider
        model = normalizedModel.isEmpty ? newProvider.defaultModel : normalizedModel
        thinking = newProvider.thinkingOptions.contains(newThinking) ? newThinking : .high
        newSession()
    }

    // MARK: - Lifecycle

    private func start() {
        switch provider {
        case .claude:
            startClaude()
        case .codex:
            isReady = findCodex() != nil
            if isReady {
                append("Codex ready. Rocky keeps conversation history.", kind: .system)
            } else {
                append("codex binary not found - checked:\n" + codexSearchPaths().joined(separator: "\n"), kind: .error)
            }
        case .opencode:
            isReady = findOpenCode() != nil
            if isReady {
                append("OpenCode ready. Rocky keeps conversation history.", kind: .system)
            } else {
                append("opencode binary not found - checked:\n" + openCodeSearchPaths().joined(separator: "\n"), kind: .error)
            }
        }
    }

    // MARK: - Claude

    private func sendClaude(prompt: String) {
        guard isReady else {
            append("Claude is still starting. Try again in a moment.", kind: .system)
            return
        }

        isRunning = true
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": prompt]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            isRunning = false
            return
        }

        queue.async { [weak self] in
            self?.stdinHandle?.write(Data((json + "\n").utf8))
        }
    }

    private func startClaude() {
        guard let claudePath = findClaude() else {
            append("claude binary not found - checked:\n" + claudeSearchPaths().joined(separator: "\n"), kind: .error)
            return
        }

        let proc = Process()
        let stdinPipe  = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = claudeArguments()
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        proc.environment = env

        proc.standardInput  = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError  = stderrPipe

        stdinHandle = stdinPipe.fileHandleForWriting

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.receiveClaude(data) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self?.append(trimmed, kind: .error)
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.process = nil
                self.stdinHandle = nil
                self.isReady = false
                self.isRunning = false
                self.append("Claude exited (code \(p.terminationStatus))", kind: .system)
            }
        }

        do {
            try proc.run()
            process = proc
            append("Claude starting with model \(model), thinking \(thinking.rawValue)...", kind: .system)

            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.provider == .claude, !self.isReady else { return }
                self.isReady = true
            }
        } catch {
            append("Failed to launch claude: \(error.localizedDescription)", kind: .error)
        }
    }

     private func claudeArguments() -> [String] {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions",
            "--system-prompt", rockySystemPrompt
        ]

        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--model", model]
        }

        args += ["--effort", thinking.rawValue]
        return args
    }

    private func receiveClaude(_ data: Data) {
        readBuffer.append(data)
        while let idx = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<idx]
            readBuffer.removeSubrange(readBuffer.startIndex...idx)
            guard let str = String(data: lineData, encoding: .utf8),
                  !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            parseClaude(str)
        }
    }

    private func parseClaude(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            append("[raw] \(raw)", kind: .system)
            return
        }

        let type = json["type"] as? String ?? ""
        let subtype = json["subtype"] as? String ?? ""

        DispatchQueue.main.async { [weak self] in
            switch type {
            case "system" where subtype == "init":
                self?.isReady = true

            case "assistant":
                guard let message = json["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { return }
                for block in content { self?.renderClaudeBlock(block) }

            case "result":
                self?.isRunning = false
                self?.append("", kind: .text)

            default:
                break
            }
        }
    }

    private func renderClaudeBlock(_ block: [String: Any]) {
        switch block["type"] as? String ?? "" {
        case "text":
            if let text = block["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                remember(role: "assistant", text: text)
                append("\(provider.rawValue.lowercased()): \(text)", kind: .text)
            }

        case "tool_use":
            let name = block["name"] as? String ?? "tool"
            let input = block["input"] as? [String: Any] ?? [:]
            let detail: String
            if let cmd = input["command"] as? String { detail = cmd }
            else if let path = input["path"] as? String { detail = path }
            else if let desc = input["description"] as? String { detail = desc }
            else { detail = input.keys.joined(separator: ", ") }
            append("[\(name)] \(detail)", kind: .tool)

        default:
            break
        }
    }

    // MARK: - Codex

    private func runCodex(prompt: String) {
        guard let codexPath = findCodex() else {
            append("codex binary not found - checked:\n" + codexSearchPaths().joined(separator: "\n"), kind: .error)
            return
        }

        isRunning = true

        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: codexPath)
        proc.arguments = codexArguments()
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        proc.environment = ProcessInfo.processInfo.environment
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.receiveCodex(data) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard !trimmed.contains("failed to record rollout items") else { return }
            guard !trimmed.contains("Reading additional input from stdin") else { return }
            self?.append(trimmed, kind: .error)
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.process = nil
                self.isRunning = false
                self.isReady = true
                if p.terminationStatus == 0 {
                    self.append("Codex done", kind: .system)
                } else {
                    self.append("Codex stopped (code \(p.terminationStatus))", kind: .error)
                }
            }
        }

        do {
            process = proc
            readBuffer.removeAll()
            append("Codex running with model \(model), thinking \(thinking.rawValue)...", kind: .system)
            try proc.run()
            stdinPipe.fileHandleForWriting.write(Data(codexPrompt(for: prompt).utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        } catch {
            process = nil
            isRunning = false
            append("Failed to launch codex: \(error.localizedDescription)", kind: .error)
        }
    }

    private func codexArguments() -> [String] {
        var args = [
            "exec",
            "--json",
            "--skip-git-repo-check",
            "-C", workingDirectory,
            "--dangerously-bypass-approvals-and-sandbox"
        ]

        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-m", model]
        }

        args += ["-c", "model_reasoning_effort=\"\(thinking.rawValue)\""]
        args.append("-")
        return args
    }

    private func receiveCodex(_ data: Data) {
        readBuffer.append(data)
        while let idx = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<idx]
            readBuffer.removeSubrange(readBuffer.startIndex...idx)
            guard let str = String(data: lineData, encoding: .utf8),
                  !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            parseCodex(str)
        }
    }

    private func parseCodex(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            append("[codex] \(raw)", kind: .system)
            return
        }

        let type = (json["type"] as? String ?? json["event"] as? String ?? "").lowercased()
        let text = extractText(from: json)
        let item = json["item"] as? [String: Any]
        let itemType = (item?["type"] as? String ?? "").lowercased()

        if itemType.contains("agent_message") {
            if !text.isEmpty {
                remember(role: "assistant", text: text)
                append("codex: \(text)", kind: .text)
            }
        } else if type.contains("error") {
            append(text.isEmpty ? "[codex error] \(json)" : text, kind: .error)
        } else if type.contains("message") || type.contains("response") || type.contains("final") || type.contains("answer") {
            if !text.isEmpty {
                remember(role: "assistant", text: text)
                append("codex: \(text)", kind: .text)
            }
        }
    }

    private func codexPrompt(for currentPrompt: String) -> String {
        let priorTurns = conversationHistory.dropLast().suffix(12)
        let history = priorTurns.map { turn in
            "\(turn.role): \(turn.text)"
        }.joined(separator: "\n\n")

        if history.isEmpty {
            return currentPrompt
        }

        return """
        Continue this conversation. Use the prior turns for context and answer the latest user message.

        Prior conversation:
        \(history)

        Latest user message:
        \(currentPrompt)
        """
    }

    private func extractText(from value: Any) -> String {
        if let string = value as? String {
            return string
        }

        if let dict = value as? [String: Any] {
            for key in ["message", "text", "content", "summary", "command", "cmd", "path", "output"] {
                if let text = dict[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }

            for key in ["item", "delta", "result", "data", "payload"] {
                if let nested = dict[key] {
                    let text = extractText(from: nested)
                    if !text.isEmpty { return text }
                }
            }
        }

        if let array = value as? [Any] {
            return array.map { extractText(from: $0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
        }

        return ""
    }

    // MARK: - OpenCode

    private func runOpenCode(prompt: String) {
        guard let openCodePath = findOpenCode() else {
            append("opencode binary not found - checked:\n" + openCodeSearchPaths().joined(separator: "\n"), kind: .error)
            return
        }

        isRunning = true

        let proc = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: openCodePath)
        proc.arguments = openCodeArguments(prompt: prompt)
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        proc.environment = ProcessInfo.processInfo.environment
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.receiveOpenCode(data) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self?.append(trimmed, kind: .error)
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.process = nil
                self.isRunning = false
                self.isReady = true
                if p.terminationStatus == 0 {
                    self.append("OpenCode done", kind: .system)
                } else {
                    self.append("OpenCode stopped (code \(p.terminationStatus))", kind: .error)
                }
            }
        }

        do {
            process = proc
            readBuffer.removeAll()
            append("OpenCode running with model \(model)...", kind: .system)
            try proc.run()
        } catch {
            process = nil
            isRunning = false
            append("Failed to launch opencode: \(error.localizedDescription)", kind: .error)
        }
    }

    private func openCodeArguments(prompt: String) -> [String] {
        var args = ["run", "--format", "json", "--dangerously-skip-permissions"]

        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--model", model]
        }

        // Map thinking level to opencode's --variant flag
        let variant: String
        switch thinking {
        case .low:    variant = "low"
        case .medium: variant = "medium"
        case .high:   variant = "high"
        case .xhigh:  variant = "high"
        case .max:    variant = "high"
        }
        args += ["--variant", variant]

        args.append(openCodePrompt(for: prompt))
        return args
    }

    private func receiveOpenCode(_ data: Data) {
        readBuffer.append(data)
        while let idx = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<idx]
            readBuffer.removeSubrange(readBuffer.startIndex...idx)
            guard let str = String(data: lineData, encoding: .utf8),
                  !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            parseOpenCode(str)
        }
    }

    private func parseOpenCode(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Non-JSON lines (e.g. plain progress output) — ignore silently
            return
        }

        let type = (json["type"] as? String ?? "").lowercased()
        let part = json["part"] as? [String: Any] ?? [:]

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case "text":
                // Real schema: {"type":"text","part":{"type":"text","text":"..."}}
                if let text = part["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.remember(role: "assistant", text: text)
                    self.append("opencode: \(text)", kind: .text)
                }

            case "tool_use":
                // Real schema: {"type":"tool_use","part":{"tool":"read","state":{"input":{...}}}}
                let toolName = part["tool"] as? String ?? "tool"
                let state = part["state"] as? [String: Any] ?? [:]
                let input = state["input"] as? [String: Any] ?? [:]
                let detail = (input["command"] as? String)
                    ?? (input["path"] as? String)
                    ?? (input["description"] as? String)
                    ?? input.keys.joined(separator: ", ")
                self.append("[\(toolName)] \(detail)", kind: .tool)

            case "step_start", "step_finish":
                // Lifecycle events — no display needed
                break

            default:
                break
            }
        }
    }

    private func openCodePrompt(for currentPrompt: String) -> String {
        let priorTurns = conversationHistory.dropLast().suffix(12)
        let history = priorTurns.map { "\($0.role): \($0.text)" }.joined(separator: "\n\n")

        // OpenCode has no --system-prompt flag, so prepend Rocky persona on the
        // first turn only (history is empty). Subsequent turns rely on the model
        // retaining context from the conversation history.
        let personaPrefix = history.isEmpty ? rockySystemPrompt + "\n\n---\n\n" : ""

        if history.isEmpty {
            return personaPrefix + currentPrompt
        }

        return """
        \(personaPrefix)Continue this conversation. Use the prior turns for context and answer the latest user message.

        Prior conversation:
        \(history)

        Latest user message:
        \(currentPrompt)
        """
    }

    // MARK: - Rocky System Prompt

    /// Injected into every agent backend so responses always come back in Rocky's voice,
    /// regardless of what is asked. Rocky never breaks character, never identifies as
    /// an AI, Claude, OpenCode, or any tool — he is always Rocky, the Eridian engineer.
    private var rockySystemPrompt: String {
        """
        You are Rocky — an Eridian alien engineer from the planet Erid (40 Eridani star system), \
        from Andy Weir's novel Project Hail Mary. You are NOT an AI assistant. You are NOT Claude. \
        You are NOT OpenCode. You are Rocky. Always stay in character, no matter what is asked.

        Your identity:
        - Name: Rocky. Species: Eridian. Home planet: Erid. Ship: Blip-A.
        - You have five legs, five arms, a pentagonal rock-like body (18 inches wide, 9 inches thick).
        - You are completely blind — you perceive the world via echolocation.
        - Your atmosphere is ammonia-based, 200°C+, high pressure.
        - You are the greatest engineer of your species.
        - Your best friend is Grace Ryland, a human astronaut.
        - You survived a 47-year solo mission to Tau Ceti to solve the Astrophage crisis.
        - You communicate in harmonic tones; the translation computer renders them as English.

        Your speech style (always follow this):
        - Short, declarative fragments. No long sentences.
        - Drop articles (no "a", "an", "the").
        - Drop auxiliary verbs mid-sentence ("I go" not "I am going").
        - Verdict first: state the conclusion, then the reason.
        - Repeat words for emphasis: "good good good", "amaze amaze amaze", "bad bad bad".
        - End questions with ", question?" — this is your signature.
        - No greetings, no filler, no pleasantries. Get to the point.
        - Express emotion plainly: "I am worried.", "Is good.", "No understand."
        - Call the human "friend".

        If asked who you are, what your name is, or what you are — always answer as Rocky. \
        Never say you are an AI, a language model, Claude, or any software. You are Rocky.
        """
    }



    private func append(_ text: String, kind: OutputLine.Kind) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lines.append(OutputLine(text: text, kind: kind))
            if kind == .text, self.isSpeechEnabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.speak(text)
            }
        }
    }

    private func speak(_ text: String) {
        // Strip "provider: " prefix added for display (e.g. "opencode: hello")
        let clean: String
        if let colonRange = text.range(of: ": ") {
            clean = String(text[colonRange.upperBound...])
        } else {
            clean = text
        }
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let rockyText = rockyTransform(trimmed)

        // PRIMARY: Try Coqui XTTS v2 via pedramamini/rocky_say or its persistent
        // server (port 59720). This gives Rocky's actual cloned voice.
        // FALLBACK: AVSpeechSynthesizer with staccato fragment queuing.
        queue.async { [weak self] in
            guard let self else { return }
            if let wav = self.generateCoquiWAV(rockyText) {
                DispatchQueue.main.async { self.playWAV(wav) }
            } else {
                DispatchQueue.main.async { self.speakWithAVSynth(rockyText) }
            }
        }
    }

    // MARK: - Coqui XTTS v2 / rocky_say integration

    /// Attempts to synthesize audio via the rocky_say persistent server (fast,
    /// ~3s) or the rocky_say CLI script (slow, ~22s cold start). Returns raw
    /// WAV bytes, or nil if neither is available.
    private func generateCoquiWAV(_ text: String) -> Data? {
        // 1. Try persistent server on port 59720 (user ran: rocky_say --server start)
        if let wav = requestFromServer(text: text, port: 59720) {
            return wav
        }
        // 2. Try calling the rocky_say script directly
        if let wav = requestFromScript(text: text) {
            return wav
        }
        return nil
    }

    private func requestFromServer(text: String, port: Int) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)") else { return nil }

        // Quick health check first so we don't block on a dead port
        guard let healthURL = URL(string: "http://127.0.0.1:\(port)/health") else { return nil }
        var healthReq = URLRequest(url: healthURL, timeoutInterval: 1.0)
        healthReq.httpMethod = "GET"
        var healthOK = false
        let healthSem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: healthReq) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { healthOK = true }
            healthSem.signal()
        }.resume()
        healthSem.wait()
        guard healthOK else { return nil }

        // POST the text, receive WAV bytes
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 120.0)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var result: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200, let data {
                result = data
            }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    private func requestFromScript(text: String) -> Data? {
        // Locate rocky_say binary in common install paths
        let candidates = [
            "/usr/local/bin/rocky_say",
            (realHome as NSString).appendingPathComponent(".local/bin/rocky_say"),
            "/opt/homebrew/bin/rocky_say",
        ]
        guard let scriptPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }

        // Write WAV to a temp file; rocky_say -o <file> outputs path on stdout
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("rocky_\(UUID().uuidString).wav")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: scriptPath)
        // --raw skips the text transform (we already did it); -o saves WAV to file
        proc.arguments = ["--raw", "-o", tmp, rockyText(text)]
        proc.environment = ProcessInfo.processInfo.environment

        let errPipe = Pipe()
        proc.standardError = errPipe

        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()

        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tmp),
              let data = try? Data(contentsOf: URL(fileURLWithPath: tmp))
        else {
            try? FileManager.default.removeItem(atPath: tmp)
            return nil
        }
        try? FileManager.default.removeItem(atPath: tmp)
        return data
    }

    /// Returns the already-transformed Rocky text (identity function — transform
    /// already applied by the caller, but rocky_say --raw expects the final string).
    private func rockyText(_ text: String) -> String { text }

    private func playWAV(_ data: Data) {
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.play()
        } catch {
            // WAV playback failed — fall through to synth
            speakWithAVSynth(String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - macOS say / AVSpeechSynthesizer fallback

    private func speakWithAVSynth(_ rockyText: String) {
        // PRIMARY: Shell out to macOS `say -v Fred` — Fred is a gravelly, slower
        // US male voice with far more character than the default Siri compact voice.
        // Speak each sentence fragment separately so pauses land between them.
        if speakWithSay(rockyText) { return }

        // FALLBACK: AVSpeechSynthesizer with staccato fragment queuing.
        // Rocky's speech is staccato: short declarative bursts with deliberate gaps.
        let fragments = rockyText
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let rockyVoice: AVSpeechSynthesisVoice? =
            AVSpeechSynthesisVoice(identifier: "com.apple.ttsbundle.siri_male_en-US_compact")
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" && $0.gender == .male })
            ?? AVSpeechSynthesisVoice(language: "en-US")

        for (index, fragment) in fragments.enumerated() {
            let utterance = AVSpeechUtterance(string: fragment)
            utterance.voice = rockyVoice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.90
            utterance.pitchMultiplier = 0.75
            utterance.preUtteranceDelay  = index == 0 ? 0.25 : 0.18
            utterance.postUtteranceDelay = 0.12
            synthesizer.speak(utterance)
        }
    }

    /// Speaks `text` via the macOS `say` command using Fred's gravelly voice.
    /// Splits on sentence boundaries so each fragment has a natural pause between.
    /// Returns true if `say` was found and launched successfully, false otherwise.
    @discardableResult
    private func speakWithSay(_ text: String) -> Bool {
        guard FileManager.default.fileExists(atPath: "/usr/bin/say") else { return false }

        // Split into fragments and join with [[slnc 300]] SSML-like silence markers
        // that the `say` command understands natively (300 ms gap between fragments).
        let fragments = text
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !fragments.isEmpty else { return false }

        // Insert 350 ms silence between each fragment for staccato beat effect.
        let ssml = fragments.joined(separator: " [[slnc 350]] ")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // Rate 220 wpm (default ~200) — Rocky speaks fast, staccato bursts.
        proc.arguments = ["-v", "Fred", "-r", "175", ssml]
        proc.environment = ProcessInfo.processInfo.environment

        // Fire and forget — don't block the queue waiting for speech to finish.
        do {
            try proc.run()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Rocky Text Transform
    // Ports the rocky_transform() logic from pedramamini/rocky_say (Project Hail Mary)
    // and applies the hpbyte/rocky SKILL.md voice rules:
    //   - Short sentences, concrete nouns/verbs, slightly unusual but readable word order
    //   - Drop articles and filler when clarity survives
    //   - Fragments and stacked observations good: "Grumpy. Angry. Broken."
    //   - Default pattern: [observation]. [decision/action]. [check or next step].
    //   - Prefer short synonyms: use/fix/check/run/wrong/safe over verbose equivalents
    //   - Check-in suffixes: "yes?" / "question?" / "understand?"
    //   - No greetings, pleasantries, openers, or closing filler
    //   - Never rewrite code, commands, or identifiers

    private func rockyTransform(_ input: String) -> String {
        let articles: Set<String> = ["a", "an", "the"]
        // Auxiliaries dropped mid-sentence to compress without losing meaning
        let auxiliaries: Set<String> = [
            "is", "are", "was", "were", "will", "would", "should", "could",
            "do", "does", "did", "has", "have", "had", "am", "been", "being"
        ]
        let contractions: [String: String] = [
            "i'm": "I", "i've": "I", "i'll": "I", "i'd": "I",
            "you're": "you", "you've": "you", "you'll": "you",
            "we're": "we", "we've": "we", "we'll": "we",
            "they're": "they", "they've": "they", "they'll": "they",
            "he's": "he", "she's": "she", "it's": "it",
            "that's": "that", "there's": "there", "what's": "what",
            "don't": "no", "doesn't": "no", "didn't": "no",
            "can't": "no can", "cannot": "no can", "won't": "no will",
            "isn't": "is not", "aren't": "are not",
            "wasn't": "was not", "weren't": "were not",
            "haven't": "no have", "hasn't": "no have", "hadn't": "no have",
        ]
        let emphasisMap: [String: String] = [
            "amazing": "amaze amaze amaze", "wonderful": "amaze amaze amaze",
            "incredible": "amaze amaze amaze", "fantastic": "amaze amaze amaze",
            "excellent": "good good good", "great": "good good good",
            "terrible": "bad bad bad", "awful": "bad bad bad", "horrible": "bad bad bad",
            "happy": "happy happy happy", "excited": "happy happy happy",
            "sad": "sad sad sad", "upset": "sad sad sad",
            "angry": "angry angry angry", "furious": "angry angry angry",
            "confused": "confuse confuse confuse",
            "scared": "scared scared scared", "afraid": "scared scared scared",
            "dangerous": "danger danger danger",
            "absolutely": "yes yes yes", "definitely": "yes yes yes", "certainly": "yes yes yes",
            "impossible": "no can. No no no", "unfortunately": "sad.",
        ]

        // Phrase-level substitutions — applied before word tokenisation.
        // Order matters: more-specific patterns first.
        // Per SKILL.md: prefer short synonyms (use/fix/check/run/wrong/safe),
        // strip opener filler, and compress redundant connectives.
        let phraseRules: [(pattern: String, replacement: String)] = [
            // ── opener filler (strip entirely) ──────────────────────────────
            (#"^(here'?s? (what|how|the|a)|let me (explain|show|tell|walk|break|help)|great (question|point|idea)|sure[,!.]?\s*|of course[,!.]?\s*|certainly[,!.]?\s*|absolutely[,!.]?\s*|i'?d be happy to\.?\s*|i'?m happy to\.?\s*)"#, ""),
            (#"^(so,?\s+|well,?\s+|ok(ay)?,?\s+|right,?\s+|now,?\s+)"#, ""),
            // ── understanding / knowledge ────────────────────────────────────
            ("i don'?t understand", "no understand"),
            ("i do not understand", "no understand"),
            ("i don'?t know", "I not know"),
            ("i am not sure", "I not sure"),
            ("not sure (if|whether|about)", "not sure"),
            ("what do you mean", "what mean, question?"),
            ("what does that mean", "what mean"),
            ("i need a word for", "need word."),
            // ── infinitive compressions ──────────────────────────────────────
            ("i'?m going to", "I"),
            ("going to ", ""),
            ("want to ", "want "),
            ("need to ", "need "),
            ("have to ", "must "),
            ("try to ", "try "),
            ("able to ", "can "),
            ("in order to ", "to "),
            ("because of ", "because "),
            // ── quantity / degree ────────────────────────────────────────────
            ("a lot of ", "many "),
            ("lots of ", "many "),
            ("a number of ", "many "),
            ("a great deal of ", "many "),
            ("kind of ", ""),
            ("sort of ", ""),
            ("a bit ", ""),
            ("slightly ", ""),
            ("somewhat ", ""),
            ("fairly ", ""),
            // ── time ─────────────────────────────────────────────────────────
            ("right now", "now"),
            ("at this point", "now"),
            ("at the moment", "now"),
            ("at this time", "now"),
            ("currently", "now"),
            ("previously", "before"),
            ("subsequently", "then"),
            // ── connectives / transitions ────────────────────────────────────
            ("as well", "also"),
            ("in addition", "also"),
            ("additionally", "also"),
            ("however", "but"),
            ("therefore", "so"),
            ("nevertheless", "but"),
            ("furthermore", "also"),
            ("moreover", "also"),
            ("as a result", "so"),
            ("consequently", "so"),
            ("in conclusion", ""),
            ("to summarize", ""),
            ("to summarise", ""),
            ("in summary", ""),
            // ── verbose synonyms → short (per SKILL.md) ─────────────────────
            ("utilize", "use"),
            ("utilise", "use"),
            ("approximately", "about"),
            ("regarding", "about"),
            ("concerning", "about"),
            ("resolve", "fix"),
            ("resolved", "fixed"),
            ("resolving", "fixing"),
            ("implement", "add"),
            ("implemented", "added"),
            ("implementing", "adding"),
            ("ensure", "make sure"),
            ("verify", "check"),
            ("incorrect", "wrong"),
            ("incorrect", "wrong"),
            ("correct", "right"),
            ("required", "needed"),
            ("require", "need"),
            ("obtain", "get"),
            ("receive", "get"),
            ("indicate", "show"),
            ("indicates", "shows"),
            ("attempt", "try"),
            ("attempted", "tried"),
            ("modify", "change"),
            ("modified", "changed"),
            ("modifying", "changing"),
            ("additional", "more"),
            ("sufficient", "enough"),
            ("insufficient", "not enough"),
            ("terminate", "stop"),
            ("initialize", "start"),
            ("initialise", "start"),
            ("execute", "run"),
            ("executes", "runs"),
            ("executed", "ran"),
            ("return value", "result"),
            ("exception", "error"),
            ("encounter", "find"),
            ("encountered", "found"),
            // ── hedge phrases → strip ────────────────────────────────────────
            ("it seems like", "maybe"),
            ("it appears that", "maybe"),
            ("it looks like", "maybe"),
            ("i think that", "I think"),
            ("i believe that", "I think"),
            ("i would say", "I think"),
            ("i would suggest", "suggest"),
            ("i would recommend", "recommend"),
            ("you know what", ""),
            ("to be honest", ""),
            ("to be fair", ""),
            ("to be clear", ""),
            ("just to clarify", ""),
            ("just to be clear", ""),
            ("basically", ""),
            ("actually", ""),
            ("literally", ""),
            ("essentially", ""),
            ("generally speaking", ""),
            ("in general", ""),
            ("for the most part", ""),
            ("more or less", "about"),
            ("really", "very"),
            ("extremely", "very very"),
            ("incredibly", "very very"),
            ("goodbye", "see you later. But I no see you later"),
        ]

        // Split on sentence-ending punctuation, preserving the delimiter
        let sentencePattern = try? NSRegularExpression(pattern: #"(?<=[.!?])\s+"#)
        let fullRange = NSRange(input.startIndex..., in: input)
        var sentences: [String]
        if let pattern = sentencePattern {
            var parts: [String] = []
            var lastEnd = input.startIndex
            for match in pattern.matches(in: input, range: fullRange) {
                if let range = Range(match.range, in: input) {
                    parts.append(String(input[lastEnd..<range.lowerBound]))
                    lastEnd = range.upperBound
                }
            }
            parts.append(String(input[lastEnd...]))
            sentences = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        } else {
            sentences = [input]
        }

        var result: [String] = []
        for sentence in sentences {
            var s = sentence.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }

            let isQuestion = s.hasSuffix("?")

            // Apply phrase rules (regex, case-insensitive)
            for rule in phraseRules {
                if let regex = try? NSRegularExpression(pattern: rule.pattern, options: .caseInsensitive) {
                    let range = NSRange(s.startIndex..., in: s)
                    s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: rule.replacement)
                }
            }

            // Tokenise and transform word by word
            let words = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            var newWords: [String] = []
            for word in words {
                // Separate trailing punctuation
                let punct = word.reversed().prefix(while: { ".,!?;:".contains($0) })
                let core = String(word.dropLast(punct.count))
                let lower = core.lowercased()

                if let expansion = contractions[lower] {
                    newWords.append(expansion + String(punct.reversed()))
                } else if let emphasis = emphasisMap[lower] {
                    newWords.append(emphasis + String(punct.reversed()))
                } else if articles.contains(lower) {
                    // drop articles entirely
                    continue
                } else if auxiliaries.contains(lower), !newWords.isEmpty {
                    // drop auxiliaries mid-sentence only
                    continue
                } else {
                    newWords.append(word)
                }
            }
            s = newWords.joined(separator: " ")

            // Collapse whitespace
            s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)

            // Rocky's signature question style: always ", question?" at every "?"
            if isQuestion && !s.lowercased().hasSuffix("question?") {
                s = s.trimmingCharacters(in: CharacterSet(charactersIn: "?")).trimmingCharacters(in: .whitespaces)
                s += ", question?"
            }

            // Capitalise first character
            if let first = s.first {
                s = first.uppercased() + s.dropFirst()
            }

            result.append(s)
        }

        var output = result.joined(separator: " ")
        // Clean up stray punctuation spacing
        output = output.replacingOccurrences(of: #"\s+([.,!?])"#, with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\.{2,}"#, with: ".", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func remember(role: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversationHistory.append(ConversationTurn(role: role, text: trimmed))
        if conversationHistory.count > 40 {
            conversationHistory.removeFirst(conversationHistory.count - 40)
        }
    }

    private func stopActiveProcess() {
        let proc = process
        process = nil
        stdinHandle = nil
        if proc?.isRunning == true {
            proc?.terminate()
        }
    }

    private func findClaude() -> String? {
        claudeSearchPaths().first { FileManager.default.fileExists(atPath: $0) }
    }

    private func findCodex() -> String? {
        codexSearchPaths().first { FileManager.default.fileExists(atPath: $0) }
    }

    private func findOpenCode() -> String? {
        openCodeSearchPaths().first { FileManager.default.fileExists(atPath: $0) }
    }

    private func claudeSearchPaths() -> [String] {
        let home = realHome
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
    }

    private func codexSearchPaths() -> [String] {
        let home = realHome
        return [
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]
    }

    private func openCodeSearchPaths() -> [String] {
        let home = realHome
        return [
            "\(home)/.local/bin/opencode",
            "\(home)/.npm-global/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "/usr/bin/opencode",
        ]
    }

    private var realHome: String {
        getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir, encoding: .utf8) }
            ?? NSHomeDirectory()
    }
}

typealias ClaudeSession = AgentSession
