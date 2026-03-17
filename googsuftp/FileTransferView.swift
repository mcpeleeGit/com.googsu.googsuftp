import SwiftUI
import UniformTypeIdentifiers

struct FileTransferView: View {
    @ObservedObject var ftpManager: FTPManager
    @State private var showingFilePicker = false
    @State private var showingSavePanel = false
    @State private var selectedFileURL: URL?
    @State private var selectedItem: FTPItem?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("파일 전송")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            // 업로드 섹션
            uploadSection
            
            // 다운로드 섹션
            downloadSection
            
            // 진행 중인 작업 목록
            operationsSection
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: 600)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }
    
    private var uploadSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("파일 업로드")
                .font(.title2)
                .fontWeight(.semibold)
            
            HStack {
                Button(action: { showingFilePicker = true }) {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("파일 선택")
                    }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                
                if let selectedFileURL = selectedFileURL {
                    Text(selectedFileURL.lastPathComponent)
                        .foregroundColor(.secondary)
                    
                    Button("업로드") {
                        uploadSelectedFile()
                    }
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                
                Spacer()
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
    
    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("파일 다운로드")
                .font(.title2)
                .fontWeight(.semibold)
            
            if let selectedItem = selectedItem {
                HStack {
                    VStack(alignment: .leading) {
                        Text("선택된 파일: \(selectedItem.name)")
                            .fontWeight(.medium)
                        Text("크기: \(formatFileSize(selectedItem.size))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("다운로드") {
                        downloadSelectedFile()
                    }
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            } else {
                Text("파일 브라우저에서 파일을 선택하세요")
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
    
    private var operationsSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("진행 중인 작업")
                .font(.title2)
                .fontWeight(.semibold)
            
            if ftpManager.operations.isEmpty {
                Text("진행 중인 작업이 없습니다")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ForEach(ftpManager.operations, id: \.id) { operation in
                    OperationRow(operation: operation)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
    
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                selectedFileURL = url
            }
        case .failure(let error):
            print("파일 선택 오류: \(error)")
        }
    }
    
    private func uploadSelectedFile() {
        guard let selectedFileURL = selectedFileURL else { return }
        
        let fileName = selectedFileURL.lastPathComponent
        let remotePath = ftpManager.currentDirectory + "/" + fileName
        
        ftpManager.uploadFile(localPath: selectedFileURL.path, remotePath: remotePath)
        
        // 선택된 파일 초기화
        self.selectedFileURL = nil
    }
    
    private func downloadSelectedFile() {
        guard let selectedItem = selectedItem else { return }
        
        // 실제 구현에서는 파일 저장 위치를 사용자에게 물어봐야 함
        let documentsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localPath = documentsPath.appendingPathComponent(selectedItem.name).path
        
        ftpManager.downloadFile(remotePath: selectedItem.name, localPath: localPath)
        
        // 선택된 파일 초기화
        self.selectedItem = nil
    }
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

struct OperationRow: View {
    let operation: FTPOperation
    
    var body: some View {
        HStack {
            Image(systemName: operationIcon)
                .foregroundColor(operationColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(operationTitle)
                    .fontWeight(.medium)
                
                Text(operation.remotePath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if operation.state == .uploading || operation.state == .downloading {
                    ProgressView(value: operation.progress)
                        .progressViewStyle(LinearProgressViewStyle())
                }
            }
            
            Spacer()
            
            Text(operationStateText)
                .font(.caption)
                .foregroundColor(operationColor)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var operationIcon: String {
        switch operation.type {
        case .upload:
            return "arrow.up.circle"
        case .download:
            return "arrow.down.circle"
        case .delete:
            return "trash.circle"
        case .createDirectory:
            return "folder.badge.plus"
        case .rename:
            return "pencil.circle"
        }
    }
    
    private var operationColor: Color {
        switch operation.state {
        case .idle:
            return .gray
        case .uploading, .downloading, .deleting, .creating:
            return .blue
        case .error:
            return .red
        }
    }
    
    private var operationTitle: String {
        switch operation.type {
        case .upload:
            return "업로드"
        case .download:
            return "다운로드"
        case .delete:
            return "삭제"
        case .createDirectory:
            return "폴더 생성"
        case .rename:
            return "이름 변경"
        }
    }
    
    private var operationStateText: String {
        switch operation.state {
        case .idle:
            return "대기 중"
        case .uploading:
            return "업로드 중"
        case .downloading:
            return "다운로드 중"
        case .deleting:
            return "삭제 중"
        case .creating:
            return "생성 중"
        case .error(let message):
            return "오류: \(message)"
        }
    }
}

// FileTransferView에서 선택된 파일을 설정하기 위한 확장
extension FileTransferView {
    func setSelectedItem(_ item: FTPItem?) {
        selectedItem = item
    }
}

struct FileTransferView_Previews: PreviewProvider {
    static var previews: some View {
        FileTransferView(ftpManager: FTPManager())
    }
}
