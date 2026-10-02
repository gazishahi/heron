# Heron

Heron is the agent harness behind [Side](https://github.com/gazishahi/side-releases), a native
macOS workspace for coding with agents. It runs a coding agent against a project on disk: the
conversation, the tools, the approvals, and a git checkpoint of what the agent changed.

Heron has no UI. The app supplies the workspace (open buffers, a terminal, where to show a file)
through `WorkspaceBridge`, and renders what the harness reports.

**Status: 0.1, pre-release.** The API is shaped by Side and will change before 1.0.

## What's in it

- **One harness, two kinds of agent.** `Harness` is the interface. `AgentRunner` is Heron's own
  agent, talking to a model provider directly (Anthropic, or any OpenAI-compatible endpoint).
  `ACPHarness` drives an outside agent (Claude Code, Codex, Gemini CLI, Pi, or any
  [Agent Client Protocol](https://agentclientprotocol.com) agent) as a subprocess.
- **Approvals.** Every edit and command is a proposal the user approves, unless the track's
  autonomy says otherwise (`AgentMode`). `CommandRiskClassifier` decides what counts as safe.
- **Checkpoints.** Each turn's changes become a git commit on the track's own branch, built with
  an isolated index so the user's staging area is never touched (`Checkpoint`, `CheckpointRestore`).
- **Sessions.** Conversations persist per track, survive relaunches, and can be archived and
  reopened (`AgentSessionStore`, `OutsideSessionLog`). `SecretRedactor` strips credential-shaped
  values before anything is stored or sent.
- **Tools over MCP.** `SideToolServer` serves the app's track tools to outside agents over MCP
  Streamable HTTP on 127.0.0.1, one unguessable URL per conversation.
- **Usage.** Token counts and estimated cost per project, track and model (`UsageStore`), with an
  optional monthly budget (`UsageBudget`).

## Requirements

macOS 15 or later, Swift 6.

## Using it

```swift
// Package.swift
.package(url: "https://github.com/gazishahi/heron", from: "0.1.2")
```

`AgentRunnerManager` is the entry point an app holds per project: it creates one harness per
track on demand and reports changes to observers. See Side for a complete client.

## Development

```sh
swift build
swift test
```

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
