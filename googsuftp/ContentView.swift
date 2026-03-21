import SwiftUI

struct ContentView: View {
    @StateObject private var ftpManager = FTPManager()

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
            FileBrowserView(ftpManager: ftpManager)
                .frame(minWidth: 720)
        }
        .frame(minWidth: 1160, minHeight: 760)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ConnectionView(ftpManager: ftpManager)
            Divider()
            footerStatus
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GoogsuFTP")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: 9, height: 9)
                Text(connectionStatusText)
                    .font(.subheadline)
                    .foregroundColor(connectionStatusColor)
            }
            if ftpManager.connectionState == .connected {
                Text(ftpManager.currentDirectory)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var footerStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !ftpManager.operations.isEmpty {
                Text("진행 중인 작업 \(ftpManager.operations.count)개")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !ftpManager.statusDetail.isEmpty {
                Text(ftpManager.statusDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var connectionStatusColor: Color {
        switch ftpManager.connectionState {
        case .disconnected:
            return .gray
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .error:
            return .red
        }
    }

    private var connectionStatusText: String {
        switch ftpManager.connectionState {
        case .disconnected:
            return "연결되지 않음"
        case .connecting:
            return "연결 중"
        case .connected:
            return "연결됨"
        case .error(let message):
            return "오류: \(message)"
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
