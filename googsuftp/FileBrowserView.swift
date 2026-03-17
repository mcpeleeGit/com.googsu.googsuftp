import SwiftUI

struct FileBrowserView: View {
    @ObservedObject var ftpManager: FTPManager
    @State private var selectedItems: Set<String> = []
    @State private var selectedItemName: String?
    @State private var showingNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var showingDeleteAlert = false
    @State private var itemToDelete: FTPItem?
    @State private var editorContent = ""
    @State private var editorOriginalContent = ""
    @State private var editorStatus = "파일을 선택하면 미리보기와 편집기가 열립니다."
    @State private var isEditorLoading = false
    @State private var isSavingEditor = false
    
    var body: some View {
        VStack(spacing: 0) {
            toolbarView
            pathView
            browserSplitView
            statusView
        }
        .sheet(isPresented: $showingNewFolderSheet) {
            newFolderSheet
        }
        .alert("삭제 확인", isPresented: $showingDeleteAlert) {
            Button("삭제", role: .destructive) {
                if let item = itemToDelete {
                    ftpManager.deleteItem(item.name, isDirectory: item.isDirectory)
                }
            }
            Button("취소", role: .cancel) { }
        } message: {
            if let item = itemToDelete {
                Text("\(item.name)을(를) 삭제하시겠습니까?")
            }
        }
        .onChange(of: ftpManager.currentDirectory) {
            selectedItems.removeAll()
            selectedItemName = nil
            clearEditor(message: "다른 폴더로 이동했습니다. 파일을 다시 선택해 주세요.")
        }
        .onChange(of: ftpManager.items.map(\.name)) {
            guard let selectedItemName else { return }
            if !ftpManager.items.contains(where: { $0.name == selectedItemName }) {
                self.selectedItemName = nil
                clearEditor(message: "현재 폴더에서 선택한 파일을 찾을 수 없습니다.")
            }
        }
    }
    
    private var toolbarView: some View {
        HStack {
            Button(action: { ftpManager.goToParentDirectory() }) {
                Image(systemName: "arrow.up")
                    .foregroundColor(.blue)
            }
            .disabled(ftpManager.currentDirectory == "/")
            
            Button(action: { ftpManager.listDirectory() }) {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(.blue)
            }
            
            Button(action: { showingNewFolderSheet = true }) {
                Image(systemName: "folder.badge.plus")
                    .foregroundColor(.blue)
            }
            
            Spacer()
            
            if !selectedItems.isEmpty {
                Button(action: deleteSelectedItems) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var pathView: some View {
        HStack {
            Text("현재 경로:")
                .fontWeight(.medium)
            Text(ftpManager.currentDirectory)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var browserSplitView: some View {
        HSplitView {
            fileListView
                .frame(minWidth: 280, idealWidth: 340)
            editorPane
                .frame(minWidth: 360)
        }
    }
    
    private var fileListView: some View {
        List {
            ForEach(ftpManager.items, id: \.name) { item in
                FileItemRow(
                    item: item,
                    isSelected: selectedItems.contains(item.name),
                    isFocused: selectedItemName == item.name,
                    onSelect: { handleSingleClick(item) },
                    onDoubleClick: { handleItemDoubleClick(item) }
                )
            }
        }
        .listStyle(.plain)
    }
    
    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(editorTitle)
                        .font(.headline)
                    Text(editorStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                if selectedFileItem != nil {
                    Button(isSavingEditor ? "저장 중..." : "저장 후 업로드") {
                        saveEditor()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSaveEditor)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Group {
                if let selectedFileItem {
                    if selectedFileItem.isDirectory {
                        placeholderView(
                            title: "폴더가 선택되었습니다",
                            message: "폴더는 오른쪽에서 편집하지 않습니다. 더블 클릭하면 하위 목록으로 이동합니다."
                        )
                    } else if isEditorLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                            Text("파일 내용을 불러오는 중입니다.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TextEditor(text: $editorContent)
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                    }
                } else {
                    placeholderView(
                        title: "파일을 선택해 주세요",
                        message: "왼쪽 목록에서 텍스트 파일을 한 번 클릭하면 내용을 불러오고, 수정 후 바로 저장 업로드할 수 있습니다."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
    
    private var statusView: some View {
        HStack {
            Text("\(ftpManager.items.count)개 항목")
                .foregroundColor(.secondary)
            
            Spacer()
            
            if !ftpManager.operations.isEmpty {
                Text("\(ftpManager.operations.count)개 작업 진행 중")
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var newFolderSheet: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("새 폴더 만들기")
                    .font(.title2)
                    .fontWeight(.bold)
                
                HStack {
                    Text("폴더명:")
                        .frame(width: 80, alignment: .leading)
                    TextField("폴더명을 입력하세요", text: $newFolderName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                Spacer()
            }
            .padding()
            .frame(width: 300, height: 150)
            .navigationTitle("새 폴더")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        showingNewFolderSheet = false
                        newFolderName = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("만들기") {
                        if !newFolderName.isEmpty {
                            ftpManager.createDirectory(newFolderName)
                            showingNewFolderSheet = false
                            newFolderName = ""
                        }
                    }
                    .disabled(newFolderName.isEmpty)
                }
            }
        }
    }
    
    private var selectedFileItem: FTPItem? {
        guard let selectedItemName else { return nil }
        return ftpManager.items.first(where: { $0.name == selectedItemName })
    }
    
    private var editorTitle: String {
        selectedFileItem?.name ?? "편집기"
    }
    
    private var canSaveEditor: Bool {
        guard let selectedFileItem, !selectedFileItem.isDirectory else { return false }
        return !isEditorLoading && !isSavingEditor && editorContent != editorOriginalContent
    }
    
    private func placeholderView(title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func handleSingleClick(_ item: FTPItem) {
        toggleSelection(item.name)
        selectedItemName = item.name
        
        if item.isDirectory {
            clearEditor(message: "폴더를 선택했습니다. 더블 클릭하면 하위 폴더로 이동합니다.")
        } else {
            loadEditor(for: item)
        }
    }
    
    private func handleItemDoubleClick(_ item: FTPItem) {
        if item.isDirectory {
            selectedItemName = item.name
            clearEditor(message: "폴더를 여는 중입니다.")
            ftpManager.changeDirectory(item.name)
        } else {
            selectedItemName = item.name
            loadEditor(for: item)
        }
    }
    
    private func loadEditor(for item: FTPItem) {
        isEditorLoading = true
        editorStatus = "\(item.name) 내용을 불러오는 중입니다."
        ftpManager.loadTextFile(named: item.name) { result in
            isEditorLoading = false
            switch result {
            case .success(let text):
                editorContent = text
                editorOriginalContent = text
                editorStatus = "수정 후 저장하면 같은 이름으로 바로 업로드됩니다."
            case .failure(let error):
                editorContent = ""
                editorOriginalContent = ""
                editorStatus = error.localizedDescription
            }
        }
    }
    
    private func saveEditor() {
        guard let selectedFileItem, !selectedFileItem.isDirectory else { return }
        isSavingEditor = true
        editorStatus = "\(selectedFileItem.name) 저장 후 업로드 중입니다."
        
        ftpManager.saveTextFile(named: selectedFileItem.name, content: editorContent) { result in
            isSavingEditor = false
            switch result {
            case .success:
                editorOriginalContent = editorContent
                editorStatus = "저장과 업로드가 완료되었습니다."
            case .failure(let error):
                editorStatus = error.localizedDescription
            }
        }
    }
    
    private func clearEditor(message: String) {
        editorContent = ""
        editorOriginalContent = ""
        editorStatus = message
        isEditorLoading = false
        isSavingEditor = false
    }
    
    private func toggleSelection(_ itemName: String) {
        selectedItems = [itemName]
    }
    
    private func deleteSelectedItems() {
        for itemName in selectedItems {
            if let item = ftpManager.items.first(where: { $0.name == itemName }) {
                itemToDelete = item
                showingDeleteAlert = true
                break
            }
        }
        selectedItems.removeAll()
    }
}

struct FileItemRow: View {
    let item: FTPItem
    let isSelected: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .blue : .gray)
            
            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                .foregroundColor(item.isDirectory ? .blue : .gray)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .fontWeight(.medium)
                
                HStack {
                    Text(item.isDirectory ? "폴더" : formatFileSize(item.size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let permissions = item.permissions {
                        Text(permissions)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(rowBackground)
        .cornerRadius(6)
        .onTapGesture { onSelect() }
        .onTapGesture(count: 2) { onDoubleClick() }
    }
    
    private var rowBackground: Color {
        if isFocused {
            return Color.blue.opacity(0.16)
        }
        if isSelected {
            return Color.blue.opacity(0.08)
        }
        return .clear
    }
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

struct FileBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        FileBrowserView(ftpManager: FTPManager())
    }
}
