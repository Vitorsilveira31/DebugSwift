import DebugSwiftCore
import Foundation

import SwiftUI

#if os(iOS)
@_spi(DebugSwiftUI) import DebugSwift
import UIKit
#endif

struct DebugSwiftSecurityAuditFinding: Codable, Identifiable {
    let severity: String
    let source: String
    let key: String
    let message: String

    var id: String { "\(severity)|\(source)|\(key)|\(message)" }

    var sourceTitle: String {
        switch source {
        case "userDefaults": "User Defaults"
        case "infoPlist": "Info.plist"
        case "bundle": "App Bundle"
        case "keychain": "Keychain"
        case "preferences": "Preferences"
        case "manifest": "Manifest"
        case "privateFile": "Private File"
        case "keyStore": "Android Keystore"
        default: source
        }
    }
}
struct DebugSwiftSecurityAuditSnapshot: Codable {
    let findings: [DebugSwiftSecurityAuditFinding]
    let summary: String
}
struct DebugSwiftSecurityAuditView: View {
    @State var audit = DebugSwiftSecurityAuditSnapshot(
        findings: [],
        summary: "Run the audit to scan this app's settings and bundled resources."
    )
    @State var hasRun = false

    private var criticalFindings: [DebugSwiftSecurityAuditFinding] {
        audit.findings.filter { $0.severity == "critical" }
    }

    private var warningFindings: [DebugSwiftSecurityAuditFinding] {
        audit.findings.filter { $0.severity == "warning" }
    }

    private var infoFindings: [DebugSwiftSecurityAuditFinding] {
        audit.findings.filter { $0.severity == "info" }
    }

    var body: some View {
        List {
            Section("Audit") {
                Text(audit.summary)
                    .font(Font.subheadline)
                    .foregroundColor(Color.secondary)

                Button {
                    refresh()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Run Security Audit")
                    }
                }
            }

            if hasRun, audit.findings.isEmpty {
                Section("Results") {
                    Text("No security findings were reported.")
                        .foregroundColor(Color.secondary)
                }
            }

            if !criticalFindings.isEmpty {
                Section("Critical (\(criticalFindings.count))") {
                    ForEach(criticalFindings) { finding in
                        findingRow(finding, color: Color.red)
                    }
                }
            }

            if !warningFindings.isEmpty {
                Section("Warning (\(warningFindings.count))") {
                    ForEach(warningFindings) { finding in
                        findingRow(finding, color: Color.orange)
                    }
                }
            }

            if !infoFindings.isEmpty {
                Section("Info (\(infoFindings.count))") {
                    ForEach(infoFindings) { finding in
                        findingRow(finding, color: Color.blue)
                    }
                }
            }
        }
        .navigationTitle("Security Audit")
        .onAppear { refresh() }
    }

    private func findingRow(_ finding: DebugSwiftSecurityAuditFinding, color: Color) -> some View {
        HStack(alignment: VerticalAlignment.top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 6, height: 38)

            VStack(alignment: HorizontalAlignment.leading, spacing: 4) {
                HStack(alignment: VerticalAlignment.firstTextBaseline) {
                    Text(finding.sourceTitle)
                        .font(Font.caption)
                        .foregroundColor(Color.secondary)
                    Spacer()
                }
                Text(finding.key)
                    .font(Font.headline)
                    .lineLimit(2)
                Text(finding.message)
                    .font(Font.subheadline)
                    .foregroundColor(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func refresh() {
        audit = DebugSwiftRuntime.securityAuditSnapshot()
        hasRun = true
    }
}
