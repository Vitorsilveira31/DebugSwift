//
//  WebSocketTestView.swift
//  Example
//
//  Created by DebugSwift Test on 2024.
//

import Foundation
import SkipFuse
import SwiftUI
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct WebSocketTestView: View {
    @State var manager = WebSocketTestManager()

    var body: some View {
        List {
            Section {
                HStack {
                    Circle()
                        .fill(manager.isConnected ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(manager.connectionStatus)
                        .foregroundColor(.secondary)
                }
                Button(manager.isConnected ? "Disconnect" : "Connect") {
                    if manager.isConnected {
                        manager.disconnect()
                    } else {
                        manager.connect()
                    }
                }
                Button("Clear Messages") { manager.clearMessages() }
            } header: {
                Text("Connection")
            }

            Section {
                Button("Send JSON") { manager.sendJSONMessage() }
                Button("Send Text") { manager.sendTextMessage() }
                Button("Send Binary") { manager.sendBinaryMessage() }
                Button("Ping Server") { manager.sendPing() }
                Button("Test Commands") { manager.sendTestCommands() }
                Button("Get Stats") { manager.sendStatsCommand() }
                Button("Send Multiple Messages") { manager.sendMultipleMessages() }
            } header: {
                Text("Send Test Messages")
            }
            .disabled(!manager.isConnected)

            Section {
                if manager.messages.isEmpty {
                    Text("No messages yet")
                        .foregroundColor(.secondary)
                }
                ForEach(manager.messages) { message in
                    HStack {
                        Text(message.direction == .sent ? "↗️" : "↙️")
                        Text(message.content)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                        Text(message.timestamp)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Recent Messages")
            }

            Section {
                Text("1. Start the local echo server: https://gist.github.com/maatheusgois-dd/c3f3f92cd109166b5af91874103078e4")
                Text("2. Tap Connect and send messages; the server echoes them back.")
                Text("3. Open the debug panel → Network → WebSocket Inspector to see the frames.")
                #if os(Android)
                Text("On Android the inspector lists OkHttp WebSockets wrapped in DebugSwiftWebSocketListener. A Swift URLSession socket like this one is not captured.")
                #endif
            } header: {
                Text("Instructions")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .navigationTitle("WebSocket Test")
        .onDisappear { manager.disconnect() }
    }
}

@MainActor
@Observable
final class WebSocketTestManager {
    struct TestMessage: Identifiable {
        enum Direction {
            case sent, received
        }

        let id = UUID()
        let direction: Direction
        let content: String
        let timestamp: String
    }

    var isConnected = false
    var connectionStatus = "Disconnected"
    var messages: [TestMessage] = []

    @ObservationIgnored private var webSocketTask: URLSessionWebSocketTask?
    @ObservationIgnored private let urlSession = URLSession(configuration: .default)

    /// The local echo server. The Android emulator reaches the host machine at 10.0.2.2.
    private let serverURL: URL = {
        #if os(Android)
        return URL(string: "ws://10.0.2.2:3001/websocket")!
        #else
        return URL(string: "ws://127.0.0.1:3001/websocket")!
        #endif
    }()

    func connect() {
        guard !isConnected else { return }
        webSocketTask?.cancel()
        connectionStatus = "Connecting..."
        addMessage(.received, "🔄 Connecting to \(serverURL.host ?? serverURL.absoluteString)...")

        let task = urlSession.webSocketTask(with: serverURL)
        webSocketTask = task
        task.resume()
        listen(on: task)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !self.isConnected, self.webSocketTask === task else { return }
            self.connectionStatus = "Connection timeout"
            self.addMessage(.received, "⏰ Connection timeout - please check the server")
            task.cancel()
            self.webSocketTask = nil
        }
    }

    func disconnect() {
        guard isConnected || webSocketTask != nil else { return }
        addMessage(.sent, "🔌 Disconnecting...")
        webSocketTask?.cancel(with: .goingAway, reason: Data("User disconnected".utf8))
        webSocketTask = nil
        isConnected = false
        connectionStatus = "Disconnected"
        addMessage(.received, "❌ Disconnected")
    }

    func sendJSONMessage() {
        let json = """
        {"type": "test_message", "timestamp": "\(Date().timeIntervalSince1970)", \
        "data": {"user": "\(ExampleDebugger.platformName)_Tester", "action": "json_test", \
        "payload": "This is a JSON test message for WebSocket Inspector"}}
        """
        send(.string(json))
        addMessage(.sent, "📤 JSON message sent")
    }

    func sendTextMessage() {
        send(.string("Hello WebSocket Inspector! Time: \(Self.timestamp(style: .medium))"))
        addMessage(.sent, "📤 Text message sent")
    }

    func sendBinaryMessage() {
        let data = Data("Binary test data: \(Date().timeIntervalSince1970)".utf8)
        send(.data(data))
        addMessage(.sent, "📤 Binary message sent (\(data.count) bytes)")
    }

    func sendPing() {
        guard let webSocketTask else { return }
        webSocketTask.sendPing { [weak self] error in
            let text = error.map { "Ping failed: \($0.localizedDescription)" } ?? "Ping sent"
            Task { @MainActor in self?.addMessage(.received, text) }
        }
    }

    func sendMultipleMessages() {
        for index in 1...5 {
            send(.string("Burst message #\(index) - \(Date().timeIntervalSince1970)"))
            addMessage(.sent, "📤 Burst message #\(index)")
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.sendJSONMessage()
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.sendBinaryMessage()
        }
    }

    /// Commands the local server understands.
    func sendTestCommands() {
        Task { [weak self] in
            for command in ["ping", "time", "json", "binary", "burst"] {
                self?.send(.string(command))
                self?.addMessage(.sent, "Command: \(command)")
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    func sendStatsCommand() {
        send(.string("stats"))
        addMessage(.sent, "Command: stats")
    }

    func clearMessages() {
        messages.removeAll()
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        guard let webSocketTask, isConnected else {
            addMessage(.received, "❌ Not connected - cannot send message")
            return
        }
        webSocketTask.send(message) { [weak self] error in
            guard let error else { return }
            let text = "❌ Failed to send: \(error.localizedDescription)"
            Task { @MainActor in self?.addMessage(.received, text) }
        }
    }

    private func listen(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            let event: String
            var failed = false
            switch result {
            case let .success(.string(text)):
                event = "📨 \(text)"
            case let .success(.data(data)):
                event = "📦 Binary: \(data.count) bytes"
            case .success:
                event = "❓ Unknown message"
            case let .failure(error):
                event = "❌ WebSocket error: \(error.localizedDescription)"
                failed = true
            }
            Task { @MainActor in
                guard let self, self.webSocketTask === task else { return }
                if failed {
                    self.connectionStatus = "Connection failed"
                    self.isConnected = false
                    self.webSocketTask = nil
                } else if !self.isConnected {
                    // The first message received means the handshake succeeded.
                    self.isConnected = true
                    self.connectionStatus = "Connected"
                    self.addMessage(.received, "✅ WebSocket connected successfully!")
                }
                self.addMessage(.received, event)
                if !failed { self.listen(on: task) }
            }
        }
    }

    private func addMessage(_ direction: TestMessage.Direction, _ content: String) {
        messages.append(TestMessage(direction: direction, content: content, timestamp: Self.timestamp(style: .none)))
        if messages.count > 20 {
            messages.removeFirst(messages.count - 20)
        }
    }

    private static func timestamp(style dateStyle: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = .medium
        return formatter.string(from: Date())
    }
}
