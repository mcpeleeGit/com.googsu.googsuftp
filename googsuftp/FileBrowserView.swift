import SwiftUI

struct FileBrowserView: View {
    @ObservedObject var ftpManager: FTPManager
    @State private var selectedItems: Set<String> = []
    @State private var showingNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var showingDeleteAlert = false
    @State private var itemToDelete: FTPItem?
    
    var body: some View {
        VStack(spacing: 0) {
            // 상단 툴바
            toolbarView
            
            // 경로 표시
            pathView
            
            // 파일 목록
            fileListView
            
            // 하단 상태바
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
    
    private var fileListView: some View {
        List {
            ForEach(ftpManager.items, id: \.name) { item in
                FileItemRow(
                    item: item,
                    isSelected: selectedItems.contains(item.name),
                    onSelect: { toggleSelection(item.name) },
                    onDoubleClick: { handleItemDoubleClick(item) }
                )
            }
        }
        .listStyle(PlainListStyle())
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
    
    private func toggleSelection(_ itemName: String) {
        if selectedItems.contains(itemName) {
            selectedItems.remove(itemName)
        } else {
            selectedItems.insert(itemName)
        }
    }
    
    private func handleItemDoubleClick(_ item: FTPItem) {
        if item.isDirectory {
            ftpManager.changeDirectory(item.name)
        } else {
            // 파일 다운로드 또는 미리보기
            print("파일 선택: \(item.name)")
        }
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
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    
    var body: some View {
        HStack {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundColor(item.isDirectory ? .blue : .gray)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .fontWeight(.medium)
                
                HStack {
                    if item.isDirectory {
                        Text("폴더")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text(formatFileSize(item.size))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let permissions = item.permissions {
                        Text(permissions)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleClick()
        }
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

#Preview {
    FileBrowserView(ftpManager: FTPManager())
}
