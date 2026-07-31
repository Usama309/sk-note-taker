import SwiftUI
import SKNoteCore

/// Shown when files are dropped onto the app: describe them in plain language and the assistant
/// routes them into the right project ("this is the Acme SOW, put it in Acme as the signed
/// contract"), creating the project if needed.
struct DropRouteSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let files: [URL]

    @State private var instruction = ""
    @State private var importing = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Import & route", systemImage: "tray.and.arrow.down.fill").font(.skTitle)
                Spacer()
                Button("Cancel") { app.pendingDropFiles = nil; dismiss() }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(files, id: \.self) { file in
                    Label(file.lastPathComponent, systemImage: "doc")
                        .font(.skCallout).foregroundStyle(.secondary)
                }
            }
            Text("Tell me about \(files.count == 1 ? "this file" : "these files") and where it goes")
                .font(.skSubtitle)
            TextField("e.g. This is the Acme SOW — put it in the Acme project as the signed contract.",
                      text: $instruction, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            if let result {
                Label(result, systemImage: "checkmark.circle.fill")
                    .font(.skCallout).foregroundStyle(Theme.success)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            HStack(alignment: .center) {
                Text("Audio and video are transcribed; PDF, Word, and text are read.")
                    .font(.skFootnote).foregroundStyle(.tertiary)
                Spacer()
                Button(action: doImport) {
                    if importing { ProgressView().controlSize(.small) } else { Text("Import") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(importing)
                .animation(Theme.Motion.snap, value: importing)
            }
        }
        .padding(20)
        .frame(width: 520)
        .animation(Theme.Motion.spring, value: result)
    }

    private func doImport() {
        importing = true
        Task {
            await app.routeAndImport(instruction: instruction)
            result = app.dropImportStatus
            importing = false
            if app.pendingDropFiles == nil {   // succeeded
                try? await Task.sleep(for: .seconds(1.3))
                dismiss()
            }
        }
    }
}
