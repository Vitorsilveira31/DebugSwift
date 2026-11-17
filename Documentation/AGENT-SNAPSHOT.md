# Agent snapshot

`agent-snapshot.json` tells a coding agent where the app stands at one moment. It pairs with
`agent-debug.ndjson`: the log is a timeline of what happened, the snapshot is the current state.
iOS and Android write the same schema, so an agent reads both the same way.

## Writing it

| Platform | From the app | From code | File |
| --- | --- | --- | --- |
| iOS | App > Agent Debug Log > Write snapshot | `try DebugSwift.App.writeAgentSnapshot()` | next to the NDJSON log: `Documents/agent-snapshot.json`, or the folder of `AGENT_DEBUG_LOG_PATH` when set |
| Android | App > Agent Debug Log > Write snapshot | the `app.agentlog.snapshot` operation of `DebugSwiftAppAPI` | `files/agent-snapshot.json` |

Each write replaces the previous file and adds a `lifecycle` entry to the NDJSON log (when capture is
on) with the file's path, so the timeline shows when each snapshot was taken.

Pulling it:

```bash
# iOS Simulator
cat "$(xcrun simctl get_app_container booted <bundle-id> data)/Documents/agent-snapshot.json"
```

```bash
# Android (debuggable build)
adb exec-out run-as <package> cat files/agent-snapshot.json
```

## Schema, version 1

```json
{
  "schemaVersion": 1,
  "generatedAt": 1763400000000,
  "platform": "ios",
  "app": { "bundleId": "com.example.app", "version": "2.4.0", "build": "311" },
  "device": { "model": "iPhone", "osVersion": "iOS 27.2" },
  "metrics": { "cpuPercent": 18.5, "memoryBytes": 212336640, "activeLeaks": 0 },
  "network": [
    { "method": "GET", "url": "https://api.example.com/me?token=%3Credacted%3E", "status": 200, "durationMs": 182 },
    { "method": "POST", "url": "https://api.example.com/orders", "status": 0, "durationMs": 30001, "error": "The request timed out." }
  ],
  "agentLog": { "path": "/…/Documents/agent-debug.ndjson", "enabled": true, "sessionId": "" }
}
```

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Grows only when a field changes meaning or goes away. New fields can appear in the same version; ignore what you do not know. |
| `generatedAt` | Milliseconds since 1970, like `timestamp` in the NDJSON log. |
| `platform` | `ios` or `android`. |
| `app` | `bundleId` (the Android package name on Android), `version`, `build`. |
| `device` | `model`, `osVersion`. |
| `metrics` | Known keys: `cpuPercent`, `memoryBytes` (resident memory on iOS, used JVM heap on Android), `fps` (Android), `activeLeaks` (iOS). A platform leaves out what it cannot measure. |
| `network` | The latest 50 HTTP requests, oldest first. `status` is 0 when no response arrived, with `error` set. URLs went through the network sanitizer, so tokens in query strings and URL passwords are masked. |
| `agentLog` | Where the NDJSON log lives, whether capture is on, and the session id written on each log line: `AGENT_DEBUG_SESSION_ID` on iOS (empty when unset), the runtime's session id on Android. |

The Swift model is `AgentSnapshot` in `DebugSwiftCore`; decode the file with it when the reader is Swift.
