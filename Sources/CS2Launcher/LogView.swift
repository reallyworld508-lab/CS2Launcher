import SwiftUI
import AppKit

struct LogView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Журнал").font(.headline)
                Spacer()
                Button("Копировать", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.logLines.joined(separator: "\n"), forType: .string)
                }
                Button("Показать в Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([state.logFileURL])
                }
                Button("Очистить", systemImage: "trash") { state.clearLog() }
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.logLines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: state.logLines.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
                .onAppear {
                    let n = state.logLines.count
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
