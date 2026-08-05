import SwiftUI

struct JavaScriptMobileOSView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("JavaScript MobileOS Archived", systemImage: "archivebox")
                .font(.headline)
            Text("Native Linux shell bring-up is the active runtime direction.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color(.systemGroupedBackground))
    }
}
