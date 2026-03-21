import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct DownloadedFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct FileBrowserView: View {
    @ObservedObject var ftpManager: FTPManager

    @State private var selectedItems: Set<String> = []
    @State private var selectedItemName: String?
    @State private var selectionAnchorName: String?
    @State private var showingNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var showingRenameSheet = false
    @State private var renameTargetName = ""
    @State private var showingDeleteAlert = false
    @State private var pendingDeleteItems: [FTPItem] = []
    @State private var showingFilePicker = false
    @State private var editorContent = ""
    @State private var editorOriginalContent = ""
    @State private var editorStatus = "파일을 선택하면 오른쪽에서 내용을 바로 확인하고 수정할 수 있습니다."
    @State private var isEditorLoading = false
    @State private var isSavingEditor = false
    @State private var openingDirectoryName: String?
    @State private var editorErrorMessage: String?
    @State private var showingSingleFileExporter = false
    @State private var singleFileExportDocument = DownloadedFileDocument()
    @State private var singleFileExportName = "download.dat"

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            pathBar
            Divider()
            workspace
            Divider()
            footerBar
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showingNewFolderSheet) {
            nameInputSheet(
                title: "새 폴더 만들기",
                fieldTitle: "폴더명",
                text: $newFolderName,
                confirmTitle: "만들기"
            ) {
                ftpManager.createDirectory(newFolderName)
                newFolderName = ""
            }
        }
        .sheet(isPresented: $showingRenameSheet) {
            nameInputSheet(
                title: "이름 변경",
                fieldTitle: "새 이름",
                text: $renameTargetName,
                confirmTitle: "변경"
            ) {
                guard let item = selectedItem else { return }
                ftpManager.renameItem(from: item.name, to: renameTargetName, isDirectory: item.isDirectory) { result in
                    switch result {
                    case .success:
                        selectedItemName = renameTargetName
                        editorStatus = "이름을 변경했습니다."
                    case .failure(let error):
                        editorStatus = error.localizedDescription
                    }
                }
                renameTargetName = ""
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .fileExporter(
            isPresented: $showingSingleFileExporter,
            document: singleFileExportDocument,
            contentType: .data,
            defaultFilename: singleFileExportName
        ) { result in
            switch result {
            case .success:
                editorStatus = "다운로드를 완료했습니다: \(singleFileExportName)"
            case .failure(let error):
                editorStatus = "다운로드 저장 실패: \(error.localizedDescription)"
            }
        }
        .alert("삭제 확인", isPresented: $showingDeleteAlert) {
            Button("삭제", role: .destructive) {
                for item in pendingDeleteItems {
                    ftpManager.deleteItem(item.name, isDirectory: item.isDirectory)
                }
                if let selectedItemName, pendingDeleteItems.contains(where: { $0.name == selectedItemName }) {
                    self.selectedItemName = nil
                    clearEditor(message: "\(pendingDeleteItems.count)개 항목 삭제를 시작했습니다.")
                }
                selectedItems.subtract(pendingDeleteItems.map(\.name))
                pendingDeleteItems = []
            }
            Button("취소", role: .cancel) { }
        } message: {
            if pendingDeleteItems.count == 1, let item = pendingDeleteItems.first {
                Text("\(item.name)을(를) 삭제하시겠습니까?")
            } else {
                Text("\(pendingDeleteItems.count)개 항목을 삭제하시겠습니까?")
            }
        }
        .onChange(of: ftpManager.currentDirectory) {
            openingDirectoryName = nil
            selectedItems.removeAll()
            selectedItemName = nil
            selectionAnchorName = nil
            clearEditor(message: "폴더가 바뀌었습니다. 새 파일을 선택해 주세요.")
        }
        .onChange(of: ftpManager.pendingNavigationPath) {
            if ftpManager.pendingNavigationPath == nil && !ftpManager.isAttemptRunning {
                openingDirectoryName = nil
            }
        }
        .onChange(of: ftpManager.items.map(\.name)) {
            let validNames = Set(ftpManager.items.map(\.name))
            selectedItems = selectedItems.intersection(validNames)
            guard let selectedItemName else { return }
            guard validNames.contains(selectedItemName) else {
                self.selectedItemName = nil
                clearEditor(message: "선택한 항목이 현재 폴더에 없습니다.")
                return
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            actionButton("arrow.up", title: "상위 폴더") {
                ftpManager.goToParentDirectory()
            }
            .disabled(ftpManager.currentDirectory == "/" || ftpManager.connectionState != .connected)

            actionButton("arrow.clockwise", title: "새로고침") {
                ftpManager.listDirectory(forceRefresh: true)
            }
            .disabled(ftpManager.connectionState != .connected)

            actionButton("square.and.arrow.up", title: "업로드") {
                showingFilePicker = true
            }
            .disabled(ftpManager.connectionState != .connected)

            actionButton("folder.badge.plus", title: "폴더 추가") {
                showingNewFolderSheet = true
            }
            .disabled(ftpManager.connectionState != .connected)

            actionButton("pencil", title: "이름 변경") {
                if let selectedItem {
                    renameTargetName = selectedItem.name
                    showingRenameSheet = true
                }
            }
            .disabled(selectedItem == nil)

            actionButton("trash", title: "삭제") {
                prepareDeleteSelection()
            }
            .disabled(deleteCandidates.isEmpty)

            actionButton("arrow.down.circle", title: "선택 다운로드") {
                downloadSelectedItems()
            }
            .disabled(downloadableSelection.isEmpty)

            Spacer()

            if isDirectoryLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Text(listingStateText)
                .font(.caption)
                .foregroundColor(ftpManager.isUsingCachedListing ? .orange : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var pathBar: some View {
        HStack(spacing: 12) {
            Text("경로")
                .font(.caption)
                .foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pathComponents.indices, id: \.self) { index in
                        let component = pathComponents[index]
                        Button(component.label) {
                            ftpManager.changeDirectory(component.path)
                        }
                        .buttonStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(index == pathComponents.count - 1 ? .primary : .blue)

                        if index < pathComponents.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            Spacer()
            if let lastListingAt = ftpManager.lastListingAt {
                Text(lastListingTimestamp(lastListingAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let duration = ftpManager.lastListingDuration {
                Text(String(format: "%.2fs", duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var workspace: some View {
        HSplitView {
            fileListPane
                .frame(minWidth: 340, idealWidth: 360, maxWidth: 420)
            detailsPane
                .frame(minWidth: 460)
        }
    }

    private var fileListPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("목록")
                    .font(.headline)
                Spacer()
                Text("\(ftpManager.items.count)개")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if isDirectoryLoading {
                directoryLoadingBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if ftpManager.connectionState != .connected {
                placeholderView(
                    title: "연결이 필요합니다",
                    message: "왼쪽에서 서버에 접속하면 이 영역에 파일과 폴더 목록이 표시됩니다."
                )
            } else if ftpManager.items.isEmpty && !isDirectoryLoading {
                placeholderView(
                    title: "표시할 항목이 없습니다",
                    message: "새 폴더를 만들거나 업로드해서 작업을 시작할 수 있습니다."
                )
            } else {
                List(ftpManager.items) { item in
                    FileItemRow(
                        item: item,
                        isSelected: selectedItems.contains(item.name),
                        isFocused: selectedItemName == item.name,
                        onSelect: { handleSelection(item, extendRange: NSEvent.modifierFlags.contains(.shift)) },
                        onOpen: { openItem(item) }
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                }
                .listStyle(.plain)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var detailsPane: some View {
        VStack(spacing: 0) {
            detailsHeader
            Divider()
            detailsBody
        }
        .background(Color(NSColor.underPageBackgroundColor))
    }

    private var detailsHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedItem?.name ?? "작업 영역")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(editorStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()

            if let selectedItem, !selectedItem.isDirectory {
                Button(isSavingEditor ? "저장 중..." : "저장") {
                    saveEditor()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveEditor)

                Button("다운로드") {
                    downloadSelectedFile()
                }
                .buttonStyle(.bordered)
                .disabled(isEditorLoading)
            } else if let selectedItem, selectedItem.isDirectory {
                Button("폴더 열기") {
                    openItem(selectedItem)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var detailsBody: some View {
        HSplitView {
            detailsContentPane
                .frame(minWidth: 520)

            operationsSidePane
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
        }
    }

    @ViewBuilder
    private var detailsContentPane: some View {
        if let selectedItem {
            if selectedItem.isDirectory {
                directoryDetail(item: selectedItem)
            } else {
                fileEditor(item: selectedItem)
            }
        } else {
            placeholderView(
                title: "항목을 선택해 주세요",
                message: "왼쪽 목록에서 파일을 선택하면 오른쪽에서 미리보기와 편집이 열리고, 폴더를 선택하면 즉시 이동할 수 있습니다."
            )
        }
    }

    private func directoryDetail(item: FTPItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            detailCard(title: "폴더 정보", lines: [
                "이름: \(item.name)",
                "위치: \(ftpManager.currentDirectory)"
            ])

            detailCard(title: "빠른 작업", lines: [
                "더블 클릭 또는 오른쪽 상단의 `폴더 열기`로 하위 목록을 엽니다.",
                "이름 변경과 삭제는 상단 액션 버튼에서 바로 처리됩니다."
            ])

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
    }

    private func fileEditor(item: FTPItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                metaTag(item.isDirectory ? "폴더" : formattedSize(item.size))
                if let permissions = item.permissions {
                    metaTag(permissions)
                }
                Text("\(editorContent.count)자")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            if isEditorLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("파일 내용을 불러오는 중입니다.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let editorErrorMessage {
                placeholderView(
                    title: "파일을 열지 못했습니다",
                    message: editorErrorMessage
                )
            } else {
                if let language = highlightedLanguage(for: item.name) {
                    CodeSyntaxTextEditor(text: $editorContent, language: language)
                        .padding(14)
                        .background(Color(NSColor.textBackgroundColor))
                } else {
                    TextEditor(text: $editorContent)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(14)
                        .background(Color(NSColor.textBackgroundColor))
                }
            }
        }
    }

    private var operationsSidePane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("처리 대기/진행")
                    .font(.headline)
                Spacer()
                Text("\(ftpManager.operations.count)개")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if ftpManager.operations.isEmpty {
                placeholderView(
                    title: "대기 중인 작업이 없습니다",
                    message: "삭제, 업로드, 다운로드, 저장 같은 작업이 시작되면 이 영역에 순서대로 표시됩니다."
                )
            } else {
                List(ftpManager.operations, id: \.id) { operation in
                    CompactOperationRow(operation: operation)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                }
                .listStyle(.plain)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var footerBar: some View {
        HStack {
            Text("\(ftpManager.items.filter(\.isDirectory).count)개 폴더")
                .foregroundColor(.secondary)
            Text("•")
                .foregroundColor(.secondary)
            Text("\(ftpManager.items.filter { !$0.isDirectory }.count)개 파일")
                .foregroundColor(.secondary)
            if !selectedItems.isEmpty {
                Text("•")
                    .foregroundColor(.secondary)
                Text("선택 \(selectedItems.count)개")
                    .foregroundColor(.blue)
            }
            Spacer()
            if !ftpManager.operations.isEmpty {
                Text("\(ftpManager.operations.count)개 작업 진행 중")
                    .foregroundColor(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var directoryLoadingBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(directoryLoadingText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if ftpManager.isUsingCachedListing {
                    Text("캐시 표시 후 갱신")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            AnimatedLoadingBar()
                .frame(height: 8)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .animation(.easeInOut(duration: 0.2), value: isDirectoryLoading)
    }

    private var selectedItem: FTPItem? {
        guard let selectedItemName else { return nil }
        return ftpManager.items.first(where: { $0.name == selectedItemName })
    }

    private var deleteCandidates: [FTPItem] {
        if !selectedItems.isEmpty {
            return ftpManager.items.filter { selectedItems.contains($0.name) }
        }
        if let selectedItem {
            return [selectedItem]
        }
        return []
    }

    private var downloadableSelection: [FTPItem] {
        ftpManager.items.filter { selectedItems.contains($0.name) && !$0.isDirectory }
    }

    private var pathComponents: [(label: String, path: String)] {
        let normalized = ftpManager.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != "/", !normalized.isEmpty else {
            return [(label: "/", path: "/")]
        }

        var current = ""
        var result: [(label: String, path: String)] = [("/", "/")]
        for part in normalized.split(separator: "/").map(String.init) {
            current += "/\(part)"
            result.append((part, current))
        }
        return result
    }

    private var canSaveEditor: Bool {
        guard let selectedItem, !selectedItem.isDirectory else { return false }
        return !isEditorLoading && !isSavingEditor && editorContent != editorOriginalContent
    }

    private var listingStateText: String {
        if ftpManager.pendingNavigationPath != nil {
            return "폴더 이동 중"
        }
        if ftpManager.isUsingCachedListing {
            return "캐시 표시 중"
        }
        return ftpManager.isAttemptRunning ? "새 목록 조회 중" : "실시간 목록"
    }

    private var isDirectoryLoading: Bool {
        ftpManager.pendingNavigationPath != nil || ftpManager.isAttemptRunning
    }

    private var directoryLoadingText: String {
        if let openingDirectoryName {
            return "\(openingDirectoryName) 여는 중"
        }
        return ftpManager.pendingNavigationPath != nil ? "폴더로 이동하는 중" : "폴더 내용을 불러오는 중"
    }

    private func actionButton(_ systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
        }
        .buttonStyle(.bordered)
        .labelStyle(.iconOnly)
        .help(title)
    }

    private func handleSelection(_ item: FTPItem, extendRange: Bool) {
        if extendRange {
            selectRange(to: item)
        } else {
            selectedItems = [item.name]
            selectionAnchorName = item.name
        }
        selectedItemName = item.name
        if item.isDirectory {
            clearEditor(message: "폴더를 선택했습니다. 열기를 누르거나 더블 클릭하면 하위 목록으로 이동합니다.")
        } else {
            loadEditor(for: item)
        }
    }

    private func openItem(_ item: FTPItem) {
        selectedItemName = item.name
        if item.isDirectory {
            openingDirectoryName = item.name
            clearEditor(message: "하위 폴더를 여는 중입니다.")
            ftpManager.changeDirectory(item.name)
        } else {
            loadEditor(for: item)
        }
    }

    private func loadEditor(for item: FTPItem) {
        isEditorLoading = true
        editorErrorMessage = nil
        editorStatus = "\(item.name) 내용을 가져오는 중입니다."
        ftpManager.loadTextFile(named: item.name) { result in
            isEditorLoading = false
            switch result {
            case .success(let text):
                editorContent = text
                editorOriginalContent = text
                editorErrorMessage = nil
                editorStatus = ftpManager.isUsingCachedListing
                    ? "캐시 또는 최근 내용을 불러왔습니다. 수정 후 저장하면 바로 업로드됩니다."
                    : "수정 후 저장하면 같은 이름으로 덮어씁니다."
            case .failure(let error):
                editorContent = ""
                editorOriginalContent = ""
                editorErrorMessage = error.localizedDescription
                editorStatus = error.localizedDescription
            }
        }
    }

    private func saveEditor() {
        guard let selectedItem, !selectedItem.isDirectory else { return }
        isSavingEditor = true
        editorStatus = "\(selectedItem.name)을(를) 저장하는 중입니다."
        ftpManager.saveTextFile(named: selectedItem.name, content: editorContent) { result in
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

    private func downloadSelectedFile() {
        guard let selectedItem, !selectedItem.isDirectory else { return }
        guard !isEditorLoading else {
            editorStatus = "파일 내용을 불러온 뒤 다운로드할 수 있습니다."
            return
        }
        editorStatus = "다운로드 파일을 준비하는 중입니다."
        ftpManager.fetchRemoteFileData(named: selectedItem.name) { result in
            switch result {
            case .success(let data):
                singleFileExportDocument = DownloadedFileDocument(data: data)
                singleFileExportName = selectedItem.name
                showingSingleFileExporter = true
                editorStatus = "저장 위치를 선택해 주세요: \(selectedItem.name)"
            case .failure(let error):
                editorStatus = error.localizedDescription
            }
        }
    }

    private func downloadSelectedItems() {
        let files = downloadableSelection
        guard !files.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "다운로드 폴더 선택"
        panel.prompt = "선택"
        let startDownloads: (URL) -> Void = { directoryURL in
            for item in files {
                let destinationURL = directoryURL.appendingPathComponent(item.name)
                ftpManager.downloadFile(remotePath: item.name, destinationURL: destinationURL, securityScopedAccessURL: directoryURL)
            }

            let skippedCount = selectedItems.count - files.count
            editorStatus = skippedCount > 0
                ? "\(files.count)개 파일 다운로드를 시작했습니다. 폴더 \(skippedCount)개는 건너뛰었습니다."
                : "\(files.count)개 파일 다운로드를 시작했습니다."
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let directoryURL = panel.url else {
                    editorStatus = "다운로드가 취소되었습니다."
                    return
                }
                startDownloads(directoryURL)
            }
        } else {
            let response = panel.runModal()
            guard response == .OK, let directoryURL = panel.url else {
                editorStatus = "다운로드가 취소되었습니다."
                return
            }
            startDownloads(directoryURL)
        }
    }

    private func prepareDeleteSelection() {
        pendingDeleteItems = deleteCandidates
        showingDeleteAlert = !pendingDeleteItems.isEmpty
    }

    private func selectRange(to item: FTPItem) {
        let names = ftpManager.items.map(\.name)
        guard let targetIndex = names.firstIndex(of: item.name) else {
            selectedItems = [item.name]
            selectionAnchorName = item.name
            return
        }

        let anchorName = selectionAnchorName ?? selectedItemName ?? item.name
        guard let anchorIndex = names.firstIndex(of: anchorName) else {
            selectedItems = [item.name]
            selectionAnchorName = item.name
            return
        }

        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        selectedItems = Set(names[lower...upper])
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            ftpManager.uploadFile(localPath: url.path, remotePath: url.lastPathComponent)
            editorStatus = "업로드를 시작했습니다: \(url.lastPathComponent)"
        case .failure(let error):
            editorStatus = error.localizedDescription
        }
    }

    private func clearEditor(message: String) {
        editorContent = ""
        editorOriginalContent = ""
        editorErrorMessage = nil
        editorStatus = message
        isEditorLoading = false
        isSavingEditor = false
    }

    private func nameInputSheet(
        title: String,
        fieldTitle: String,
        text: Binding<String>,
        confirmTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
            VStack(alignment: .leading, spacing: 8) {
                Text(fieldTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(fieldTitle, text: text)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("취소") {
                    text.wrappedValue = ""
                    showingNewFolderSheet = false
                    showingRenameSheet = false
                }
                Button(confirmTitle) {
                    action()
                    showingNewFolderSheet = false
                    showingRenameSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func placeholderView(title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func detailCard(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(14)
    }

    private func metaTag(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(Capsule())
    }

    private func formattedSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private func highlightedLanguage(for name: String) -> CodeLanguage? {
        let lowercased = name.lowercased()
        if lowercased.hasSuffix(".php") {
            return .php
        }
        if lowercased.hasSuffix(".html") || lowercased.hasSuffix(".htm") {
            return .html
        }
        return nil
    }

    private func lastListingTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "갱신 \(formatter.string(from: date))"
    }
}

private enum CodeLanguage {
    case php
    case html
}

private struct CodeSyntaxTextEditor: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, language: language)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.backgroundColor = .textBackgroundColor
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.delegate = context.coordinator
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 8)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.applyHighlightedText(text)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.applyHighlightedText(text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        private let language: CodeLanguage
        weak var textView: NSTextView?
        private var isApplyingProgrammaticChange = false

        init(text: Binding<String>, language: CodeLanguage) {
            _text = text
            self.language = language
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticChange, let textView else { return }
            text = textView.string
            applyHighlightedText(textView.string, preservingSelection: true)
        }

        func applyHighlightedText(_ value: String, preservingSelection: Bool = false) {
            guard let textView else { return }
            if textView.string == value {
                highlight(textView: textView)
                return
            }

            let selection = textView.selectedRanges
            isApplyingProgrammaticChange = true
            textView.string = value
            highlight(textView: textView)
            if preservingSelection {
                textView.selectedRanges = selection
            }
            isApplyingProgrammaticChange = false
        }

        private func highlight(textView: NSTextView) {
            let plain = textView.string
            let selectedRanges = textView.selectedRanges
            let attributed = NSMutableAttributedString(string: plain)
            let fullRange = NSRange(location: 0, length: attributed.length)

            attributed.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ], range: fullRange)

            applyMarkupHighlights(to: attributed)
            applyCSSHighlights(to: attributed)
            applyJavaScriptHighlights(to: attributed)
            if language == .php {
                applyPHPHighlights(to: attributed)
            }

            isApplyingProgrammaticChange = true
            textView.textStorage?.setAttributedString(attributed)
            textView.selectedRanges = selectedRanges
            isApplyingProgrammaticChange = false
        }

        private func applyMarkupHighlights(to attributed: NSMutableAttributedString) {
            apply(pattern: #"(?s)<!--.*?-->"#, color: .systemGreen, to: attributed)
            apply(pattern: #"</?[A-Za-z][A-Za-z0-9:-]*\b"#, color: .systemBlue, to: attributed)
            apply(pattern: #"\b(class|id|src|href|type|name|value|data-[A-Za-z0-9_-]+|style|rel|content|charset)\s*="#, color: .systemOrange, to: attributed)
            apply(pattern: #""([^"\\]|\\.)*"|'([^'\\]|\\.)*'"#, color: .systemRed, to: attributed)
        }

        private func applyCSSHighlights(to attributed: NSMutableAttributedString) {
            guard let blockRegex = try? NSRegularExpression(pattern: #"(?is)<style\b[^>]*>(.*?)</style>"#) else { return }
            let fullRange = NSRange(location: 0, length: attributed.length)
            blockRegex.enumerateMatches(in: attributed.string, options: [], range: fullRange) { match, _, _ in
                guard let innerRange = match?.range(at: 1), innerRange.location != NSNotFound else { return }
                applyCSSRules(in: innerRange, to: attributed)
            }

            guard let inlineRegex = try? NSRegularExpression(pattern: #"(?is)\bstyle\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return }
            inlineRegex.enumerateMatches(in: attributed.string, options: [], range: fullRange) { match, _, _ in
                guard let match else { return }
                let doubleQuoted = match.range(at: 1)
                let singleQuoted = match.range(at: 2)
                let valueRange = doubleQuoted.location != NSNotFound ? doubleQuoted : singleQuoted
                guard valueRange.location != NSNotFound else { return }
                applyCSSRules(in: valueRange, to: attributed)
            }
        }

        private func applyCSSRules(in range: NSRange, to attributed: NSMutableAttributedString) {
            apply(pattern: #"(?s)/\*.*?\*/"#, color: .systemGreen, to: attributed, range: range)
            apply(pattern: #"@[A-Za-z-]+"#, color: .systemPurple, to: attributed, range: range)
            apply(pattern: #"(?m)(^|[{};]\s*)([.#]?[A-Za-z_][A-Za-z0-9_:\-\s>+~\[\]="'()*,.#]*)\s*(?=\{)"#, color: .systemTeal, to: attributed, range: range, matchGroup: 2)
            apply(pattern: #"\b([A-Za-z-]+)\s*:"# , color: .systemOrange, to: attributed, range: range, matchGroup: 1)
            apply(pattern: #"#[0-9A-Fa-f]{3,8}\b"#, color: .systemRed, to: attributed, range: range)
            apply(pattern: #"(?i)\brgba?\([^)]+\)|hsla?\([^)]+\)"#, color: .systemPink, to: attributed, range: range)
            apply(pattern: #"(?i)\b-?(?:\d+(?:\.\d+)?|\.\d+)(?:px|em|rem|%|vh|vw|svh|lvh|dvh|vmin|vmax|s|ms|deg)\b"#, color: .systemPurple, to: attributed, range: range)
            apply(pattern: #"(?i)\b(auto|inherit|initial|unset|none|solid|dashed|absolute|relative|fixed|sticky|block|inline|flex|grid|center|cover|contain|hidden|visible|important)\b"#, color: .systemIndigo, to: attributed, range: range)
        }

        private func applyPHPHighlights(to attributed: NSMutableAttributedString) {
            apply(pattern: #"(?m)//.*$|#.*$"#, color: .systemGreen, to: attributed)
            apply(pattern: #"(?s)/\*.*?\*/"#, color: .systemGreen, to: attributed)
            apply(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*"#, color: .systemOrange, to: attributed)
            apply(pattern: #"\b(function|class|public|private|protected|static|return|if|else|elseif|foreach|for|while|switch|case|break|continue|try|catch|finally|namespace|use|new|echo|require|include|extends|implements|trait|fn)\b"#, color: .systemBlue, to: attributed)
            apply(pattern: #"\b(true|false|null)\b"#, color: .systemPurple, to: attributed)
            apply(pattern: #"<\?php|\?>"#, color: .systemPink, to: attributed)
        }

        private func applyJavaScriptHighlights(to attributed: NSMutableAttributedString) {
            apply(pattern: #"(?m)^\s*//.*$"#, color: .systemGreen, to: attributed)
            apply(pattern: #"\b(function|const|let|var|return|if|else|for|while|switch|case|break|continue|try|catch|finally|class|new|async|await|import|export|from)\b"#, color: .systemIndigo, to: attributed)
            apply(pattern: #"\b(true|false|null|undefined)\b"#, color: .systemPurple, to: attributed)
        }

        private func apply(
            pattern: String,
            color: NSColor,
            to attributed: NSMutableAttributedString,
            range: NSRange? = nil,
            matchGroup: Int = 0
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let searchRange = range ?? NSRange(location: 0, length: attributed.length)
            regex.enumerateMatches(in: attributed.string, options: [], range: searchRange) { match, _, _ in
                guard let match else { return }
                let matchRange = match.range(at: matchGroup)
                guard matchRange.location != NSNotFound else { return }
                attributed.addAttribute(.foregroundColor, value: color, range: matchRange)
            }
        }
    }
}

private struct AnimatedLoadingBar: View {
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 999)
                    .fill(Color.blue.opacity(0.12))

                RoundedRectangle(cornerRadius: 999)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.blue.opacity(0.35),
                                Color.blue.opacity(0.85),
                                Color.cyan.opacity(0.7)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(geometry.size.width * 0.32, 80))
                    .offset(x: isAnimating ? geometry.size.width - max(geometry.size.width * 0.32, 80) : 0)
            }
            .clipped()
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
            .onDisappear {
                isAnimating = false
            }
        }
    }
}

private struct CompactOperationRow: View {
    let operation: FTPOperation

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundColor(tintColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                Text(operation.remotePath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
    }

    private var iconName: String {
        switch operation.type {
        case .upload:
            return "arrow.up.circle.fill"
        case .download:
            return "arrow.down.circle.fill"
        case .delete:
            return "trash.fill"
        case .createDirectory:
            return "folder.badge.plus"
        case .rename:
            return "pencil.circle.fill"
        }
    }

    private var title: String {
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

    private var tintColor: Color {
        switch operation.state {
        case .error:
            return .red
        case .uploading, .downloading, .deleting, .creating:
            return .blue
        case .idle:
            return .gray
        }
    }
}

struct FileItemRow: View {
    let item: FTPItem
    let isSelected: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : (item.isDirectory ? "folder.fill" : "doc.text"))
                .foregroundColor(isSelected ? .blue : (item.isDirectory ? .blue : .secondary))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(item.isDirectory ? "폴더" : formatFileSize(item.size))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let permissions = item.permissions {
                        Text(permissions)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(rowBackground)
        .cornerRadius(10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onTapGesture(count: 2, perform: onOpen)
    }

    private var rowBackground: Color {
        if isFocused {
            return Color.blue.opacity(0.14)
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
