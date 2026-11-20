//
//  LeakView.swift
//  Example
//

import Foundation
import SwiftUI

/// Leaves an object alive after the screen closes, for the leak detector to find.
struct LeakView: View {
    @State var leakManager = LeakManager()

    var body: some View {
        ZStack {
            Color.orange
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "drop.triangle")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 160, height: 160)
                    .foregroundColor(.black)
                Text("Go back: this screen's helper object will keep itself alive.")
                    .foregroundColor(.black)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .navigationTitle("Memory Leak")
        .onDisappear {
            leakManager.createLeak()
        }
    }
}

/// Holds a reference to itself once `createLeak()` has run, so it is never deinitialized.
@MainActor
final class LeakManager {
    private var strongSelfReference: LeakManager?

    func createLeak() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self.strongSelfReference = self
            print("LeakManager instance leaked: \(self)")
        }
    }

    deinit {
        print("LeakManager deinitialized") // Never printed: the instance leaks.
    }
}
