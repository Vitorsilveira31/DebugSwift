//
//  SecurityAuditTestView.swift
//  Example
//
//  Created by Matheus Gois on 16/07/26.
//

import Foundation
import SwiftUI

/// Seeds insecure storage so the **Security Audit** in the debug panel has findings to show.
///
/// The audit flags keys matching `key|secret|token|password|apikey|api_key` that hold a non-empty
/// string in UserDefaults (SharedPreferences on Android).
struct SecurityAuditTestView: View {
    @State var seeded = false

    private let sensitiveDefaults: [(String, String)] = [
        ("api_key", "sk-1234567890abcdef"),
        ("user_token", "eyJhbGciOiJIUzI1NiJ9.test.signature"),
        ("password", "hunter2"),
        ("secret_phrase", "open-sesame")
    ]

    var body: some View {
        Form {
            Section {
                Text("Write sensitive keys into UserDefaults. The Security Audit flags each one as a warning.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Seed Sensitive UserDefaults") {
                    for (key, value) in sensitiveDefaults {
                        UserDefaults.standard.set(value, forKey: key)
                    }
                    seeded = true
                }
                .disabled(seeded)
                if seeded {
                    Text("UserDefaults seeded — run the audit to see findings")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            } header: {
                Text("Seed Insecure Data")
            }

            Section {
                Text("Remove the seeded keys so the audit is clean again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Clear Seeded Data") {
                    for (key, _) in sensitiveDefaults {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                    seeded = false
                }
                .disabled(!seeded)
            } header: {
                Text("Clean Up")
            }

            Section {
                Text("1. Seed the sensitive UserDefaults above.")
                Text("2. Open the debug panel → Resources → Security Audit.")
                Text("3. Refresh: there is a warning for each key.")
                Text("4. Clear the data here and refresh the audit: the findings disappear.")
            } header: {
                Text("How to Test")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .navigationTitle("Security Audit Test")
        .onAppear {
            seeded = sensitiveDefaults.contains { UserDefaults.standard.string(forKey: $0.0) != nil }
        }
    }
}
