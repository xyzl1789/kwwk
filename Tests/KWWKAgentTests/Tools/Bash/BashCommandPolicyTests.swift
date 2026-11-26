import Foundation
import Testing
@testable import KWWKAgent
@testable import KWWKAI

/// `.buildAndTestOnly` reads a command with its own small parser and then
/// hands the original text to the shell. These tests pin both sides of that
/// contract: text the shell could read differently from the parser, or that
/// reaches past the build tool, is rejected before anything is spawned, and
/// ordinary build/test commands still reach the shell unchanged.
@Suite("Bash build-and-test command policy")
struct BashCommandPolicyTests {
    private actor CommandRecorder: BashOperations {
        private(set) var commands: [String] = []

        func execute(
            command: String,
            timeout _: Int?,
            cancellation _: CancellationHandle?
        ) async throws -> BashExecutionResult {
            commands.append(command)
            return BashExecutionResult(stdout: "ok", stderr: "", exitCode: 0)
        }
    }

    private func policyTool(
        recorder: CommandRecorder,
        policy: BashCommandPolicy = .buildAndTestOnly
    ) -> AgentTool {
        createBashTool(cwd: FileManager.default.temporaryDirectory.path, options: BashToolOptions(
            environment: testBashEnvironment,
            operations: recorder,
            commandPolicy: policy
        ))
    }

    private func rejectionMessage(
        _ tool: AgentTool,
        _ command: String
    ) async -> String? {
        do {
            _ = try await tool.execute(
                "policy-command",
                .object(["command": .string(command)]),
                nil,
                nil
            )
            return nil
        } catch CodingToolError.invalidArgument(let message) {
            return message
        } catch {
            return "unexpected error: \(error)"
        }
    }

    @Test("rejects text the shell would read as more, or other, than one build/test command", arguments: [
        // A newline or carriage return ends the command for the shell.
        "swift test\nrm -rf src",
        "swift test\r\nrm -rf src",
        // Inside double quotes the shell drops backslash-newline, joining `$(`.
        "swift test --filter \"$\\\n(rm -rf src)\"",
        "swift test\u{0}",
        // Only space and tab separate shell words; NBSP leaves `rm` as the command.
        "FOO=1\u{00A0}pytest rm -rf src",
        // Expansions can produce words the parser never saw.
        "xcodebuild -scheme App $IFS'clean'",
        "xcodebuild -scheme App ${X-clean}",
        "xcodebuild -scheme App $'\\x63lean'",
        "swift test --filter \"$HOME\"",
        "swift test # comment",
        // env options that run a command string, change directory or take a value.
        "env -S'rm -rf src' swift test",
        "env --split-string=rm swift test",
        "env -u pytest rm -rf src",
        "env -C / swift test",
        // Variables that pick the program, loader, shell startup or interpreter code.
        "PATH=./bin swift test",
        "path=./bin swift test",
        "LD_PRELOAD=/tmp/x.so swift test",
        "DYLD_INSERT_LIBRARIES=/tmp/x.dylib swift test",
        "env BASH_ENV=/tmp/x swift test",
        "NODE_OPTIONS=--require=/tmp/x.js npm test",
        "SHELLOPTS=xtrace PS4=x make test",
        "GIT_CONFIG_COUNT=1 swift build",
        "PYTHONPATH=/tmp/elsewhere pytest",
        "PYTHONPATH=src:../outside pytest",
        // A quoted name is not an assignment, so the shell runs `CI=1`.
        "\"CI\"=1 pytest",
        // Same-named binaries outside the workspace and PATH.
        "/tmp/elsewhere/pytest",
        "/usr/bin/../../tmp/pytest",
        "../other/pytest",
        "~/bin/pytest",
        // A value-taking xcrun option would hide the real tool name.
        "xcrun --toolchain xcodebuild rm -rf src",
        // cmake only builds when --build comes first.
        "cmake -E rm -rf src --build",
    ])
    func rejectsCommand(_ command: String) async {
        let recorder = CommandRecorder()
        let message = await rejectionMessage(policyTool(recorder: recorder), command)
        #expect(message?.contains("build-and-test policy") == true, "\(message ?? "accepted")")
        #expect(await recorder.commands.isEmpty)
    }

    @Test("passes ordinary build/test commands to the shell unchanged", arguments: [
        "CI=1 swift test --filter SubagentToolTests",
        "swift build -c release",
        "swift\ttest",
        "swift test --filter ''",
        "go test ./... -run '^TestFoo$'",
        "go test -run \"^TestA$|^TestB$\" ./pkg/...",
        "go test -run ^TestFoo$ ./pkg",
        "env CI=1 RUST_BACKTRACE=1 cargo test --workspace",
        "env -i cargo check",
        "RUSTFLAGS='-D warnings' cargo build",
        "cargo test -- --nocapture",
        "time swift build",
        "xcrun swift test",
        "xcrun -v xcodebuild -scheme App test",
        "xcodebuild -scheme App -destination 'platform=iOS Simulator,name=iPhone 17' test",
        "./gradlew test",
        ".venv/bin/pytest tests/test_api.py",
        "/usr/bin/python3 -m pytest -q",
        "PYTHONPATH=src:. pytest tests/test_*.py",
        "pytest 'tests/test_x.py::test_case[a b]'",
        "npm run test:unit",
        "bundle exec rspec spec/models",
        "uv run pytest -k 'not slow'",
        "cmake --build build --target check",
        "make -j8 test",
    ])
    func acceptsCommand(_ command: String) async throws {
        let recorder = CommandRecorder()
        _ = try await policyTool(recorder: recorder).execute(
            "policy-command",
            .object(["command": .string(command)]),
            nil,
            nil
        )
        #expect(await recorder.commands == [command])
    }

    @Test("unrestricted policy passes any command through unchanged")
    func unrestrictedPassesThrough() async throws {
        let recorder = CommandRecorder()
        let command = "echo one\necho $HOME | cat"
        _ = try await policyTool(recorder: recorder, policy: .unrestricted).execute(
            "unrestricted-command",
            .object(["command": .string(command)]),
            nil,
            nil
        )
        #expect(await recorder.commands == [command])
    }

    @Test("a newline does not start a second command in the real shell")
    func newlineDoesNotReachShell() async throws {
        let cwdDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: cwdDir) }
        let tool = createBashTool(cwd: cwdDir.path, options: BashToolOptions(
            environment: testBashEnvironment,
            commandPolicy: .buildAndTestOnly
        ))

        let message = await rejectionMessage(tool, "pytest --version\ntouch policy-sentinel")

        #expect(message?.contains("newlines") == true, "\(message ?? "accepted")")
        #expect(!FileManager.default.fileExists(
            atPath: cwdDir.appendingPathComponent("policy-sentinel").path
        ))
    }

    @Test("rejects every command when the tool's shell is not a POSIX shell")
    func nonPosixShellRejected() async throws {
        let outputDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: outputDir) }
        let manager = BackgroundTaskManager(outputDir: outputDir)
        let tools = [
            createBashTool(cwd: outputDir.path, options: BashToolOptions(
                environment: testBashEnvironment,
                shellPath: "/usr/local/bin/fish",
                commandPolicy: .buildAndTestOnly
            )),
            createBashTool(cwd: outputDir.path, options: BashToolOptions(
                environment: testBashEnvironment,
                manager: manager,
                shellPath: "/usr/local/bin/fish",
                commandPolicy: .buildAndTestOnly
            )),
        ]
        for tool in tools {
            let message = await rejectionMessage(tool, "swift test")
            #expect(message?.contains("POSIX") == true, "\(message ?? "accepted")")
        }
    }

    @Test("a custom executor's shell is not judged by the tool's shellPath")
    func customExecutorShellUnknown() async throws {
        let recorder = CommandRecorder()
        let tool = createBashTool(cwd: FileManager.default.temporaryDirectory.path, options: BashToolOptions(
            environment: testBashEnvironment,
            operations: recorder,
            shellPath: "/usr/local/bin/fish",
            commandPolicy: .buildAndTestOnly
        ))
        _ = try await tool.execute(
            "custom-executor",
            .object(["command": .string("swift test")]),
            nil,
            nil
        )
        #expect(await recorder.commands == ["swift test"])
    }
}
