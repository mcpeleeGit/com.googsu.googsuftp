import SwiftUI
import Network

struct ConnectionView: View {
    @ObservedObject var ftpManager: FTPManager
    @State private var host: String = ""
    @State private var port: String = "21"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var connectionName: String = ""
    @State private var encryptionMode: FTPEncryptionMode = .plain
    @State private var logonType: FTPLogonType = .normal
    @State private var showPassword: Bool = false
    @State private var showAdvancedOptions: Bool = true
    @State private var dataConnectionMode: FTPDataConnectionMode = .automatic
    @State private var listingMode: FTPListingMode = .automatic
    @State private var passiveHostMode: FTPPassiveHostMode = .automatic
    @State private var initialPath: String = ""
    @State private var timeoutSeconds: Double = 10
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("FTP 서버 연결")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                recentConnectionsView
                connectionForm
                connectionStatusView
                
                if case .error = ftpManager.connectionState {
                    troubleshootingHelpView
                }
                
                actionButtons
            }
            .padding()
            .frame(maxWidth: 720)
        }
        .onAppear(perform: syncFromLastServerIfNeeded)
    }
    
    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            formRow(title: "서버 주소") {
                TextField("예: ftp.example.com", text: $host)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            formRow(title: "포트") {
                TextField("포트", text: $port)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            formRow(title: "사용자명") {
                TextField("사용자명 (선택사항)", text: $username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            formRow(title: "비밀번호") {
                HStack(spacing: 8) {
                    if showPassword {
                        TextField("비밀번호", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    } else {
                        SecureField("비밀번호", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            formRow(title: "저장 이름") {
                TextField("예: 회사 웹서버", text: $connectionName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            formRow(title: "암호화") {
                Picker("암호화", selection: $encryptionMode) {
                    ForEach(FTPEncryptionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            
            formRow(title: "로그온 유형") {
                Picker("로그온 유형", selection: $logonType) {
                    ForEach(FTPLogonType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            
            if logonType == .anonymous {
                Text("익명 로그인 선택 시 입력한 사용자명과 비밀번호는 무시됩니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if encryptionMode != .plain {
                Text(encryptionMode == .explicitTLS
                     ? "명시적 FTPS는 `AUTH TLS` 방식으로 실제 연결을 시도합니다. 인증서나 데이터 채널 문제는 아래 진단 로그에서 확인할 수 있습니다."
                     : "암시적 FTPS는 아직 지원하지 않습니다.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            
            DisclosureGroup(isExpanded: $showAdvancedOptions) {
                VStack(alignment: .leading, spacing: 12) {
                    formRow(title: "데이터 연결") {
                        Picker("데이터 연결", selection: $dataConnectionMode) {
                            ForEach(FTPDataConnectionMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    
                    formRow(title: "목록 명령") {
                        Picker("목록 명령", selection: $listingMode) {
                            ForEach(FTPListingMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    
                    formRow(title: "PASV 주소") {
                        Picker("PASV 주소", selection: $passiveHostMode) {
                            ForEach(FTPPassiveHostMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    
                    formRow(title: "초기 경로") {
                        TextField("예: /public_html", text: $initialPath)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("타임아웃")
                                .frame(width: 100, alignment: .leading)
                            Text("\(Int(timeoutSeconds))초")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $timeoutSeconds, in: 5...30, step: 1)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("고급 접속 옵션")
                    .fontWeight(.medium)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
    
    private var recentConnectionsView: some View {
        Group {
            if !ftpManager.recentConnections.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("최근 접속")
                            .font(.headline)
                        Spacer()
                        Text("로컬에 저장된 최근 입력값")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    ForEach(ftpManager.recentConnections) { item in
                        HStack(spacing: 10) {
                            Button(action: { applyRecentConnection(item) }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                    Text("\(item.host):\(item.port) · \(item.encryptionMode.title) · \(item.logonType.title)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(item.options.dataConnectionMode.title)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(relativeDateText(for: item.lastUsedAt))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: { ftpManager.removeRecentConnection(item) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                    }
                }
            }
        }
    }
    
    private var connectionStatusView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                Text(statusText)
                    .fontWeight(.medium)
                    .foregroundColor(statusColor)
            }
            
            if !ftpManager.statusDetail.isEmpty {
                Text(ftpManager.statusDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if !ftpManager.attemptPlan.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("목록 조회 재시도")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    if let idx = ftpManager.currentAttemptIndex, idx < ftpManager.attemptPlan.count {
                        Text("현재 시도: \(idx + 1)/\(ftpManager.attemptPlan.count) - \(ftpManager.attemptPlan[idx])")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    
                    ForEach(Array(ftpManager.attemptPlan.enumerated()), id: \.offset) { idx, label in
                        HStack(spacing: 6) {
                            Image(systemName: idx == ftpManager.currentAttemptIndex ? "arrowtriangle.right.fill" : "circle.fill")
                                .font(.system(size: idx == ftpManager.currentAttemptIndex ? 8 : 5))
                                .foregroundColor(idx == ftpManager.currentAttemptIndex ? .orange : .secondary)
                            Text(label)
                                .font(.caption2)
                                .foregroundColor(idx == ftpManager.currentAttemptIndex ? .orange : .secondary)
                        }
                    }
                    
                    if let err = ftpManager.lastAttemptError, !err.isEmpty {
                        Text("마지막 실패: \(err)")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    
                    Button(action: { ftpManager.retryLastListing() }) {
                        Label(ftpManager.isAttemptRunning ? "재시도 중..." : "목록 조회 재시도", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .disabled(ftpManager.connectionState != .connected || ftpManager.isAttemptRunning)
                }
            }
            
            if !ftpManager.diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("문제 분석")
                        .font(.headline)
                    
                    ForEach(ftpManager.diagnostics) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(color(for: item.level))
                                    .frame(width: 8, height: 8)
                                Text(item.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            
                            Text(item.message)
                                .font(.caption)
                                .foregroundColor(.primary)
                            
                            ForEach(item.suggestions, id: \.self) { suggestion in
                                Text("• \(suggestion)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(color(for: item.level).opacity(0.08))
                        .cornerRadius(8)
                    }
                }
            }
            
            if !ftpManager.eventLog.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("최근 통신 로그")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(ftpManager.eventLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
        .padding()
        .background(statusColor.opacity(0.08))
        .cornerRadius(8)
    }
    
    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: connectToServer) {
                    HStack {
                        if ftpManager.connectionState == .connecting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                                .foregroundColor(.white)
                        } else {
                            Image(systemName: "link")
                                .frame(width: 16, height: 16)
                        }
                        Text(connectionButtonText)
                    }
                    .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(ftpManager.connectionState == .connecting || host.isEmpty)
                
                Button(action: disconnectFromServer) {
                    Label("해제", systemImage: "xmark.circle")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.bordered)
                .disabled(ftpManager.connectionState == .disconnected)
            }
            
            if !host.isEmpty {
                HStack(spacing: 10) {
                    quickRetryButton("PASV만 재시도", dataMode: .pasvOnly)
                    quickRetryButton("EPSV만 재시도", dataMode: .epsvOnly)
                    quickRetryButton("LIST만 재시도", listingMode: .listOnly)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var statusIcon: String {
        switch ftpManager.connectionState {
        case .disconnected:
            return "wifi.slash"
        case .connecting:
            return "wifi.exclamationmark"
        case .connected:
            return "wifi"
        case .error:
            return "exclamationmark.triangle"
        }
    }
    
    private var statusColor: Color {
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
    
    private var statusText: String {
        switch ftpManager.connectionState {
        case .disconnected:
            return "연결되지 않음"
        case .connecting:
            return "연결 중..."
        case .connected:
            return "연결됨"
        case .error(let message):
            return "오류: \(message)"
        }
    }
    
    private var connectionButtonText: String {
        switch ftpManager.connectionState {
        case .disconnected:
            return "연결"
        case .connecting:
            return "연결 중..."
        case .connected:
            return "다시 연결"
        case .error:
            return "재연결"
        }
    }
    
    private var troubleshootingHelpView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundColor(.orange)
                Text("이 화면에서 바로 바꿔볼 수 있는 것")
                    .font(.headline)
            }
            
            Text("다른 프로그램에서는 붙는데 여기서만 실패한다면, 서버 자체보다는 접속 전략 차이일 가능성이 큽니다.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("• `PASV만` 또는 `EPSV만`으로 바꿔 보세요.")
                Text("• `LIST만`으로 제한하면 구형 서버에서 성공하는 경우가 있습니다.")
                Text("• PASV 응답에 내부 IP가 내려오는 서버라면 `항상 접속 호스트 사용`이 도움이 됩니다.")
                Text("• 다른 프로그램에서 `TLS를 통한 명시적 FTP`로 붙는 서버라면 현재 앱은 아직 같은 방식으로 연결하지 못합니다.")
                }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange, lineWidth: 1)
        )
    }
    
    private func connectToServer() {
        guard let portInt = Int(port) else { return }
        ftpManager.connect(to: buildServer(port: portInt))
    }
    
    private func disconnectFromServer() {
        ftpManager.disconnect()
    }
    
    private func buildServer(port: Int) -> FTPServer {
        FTPServer(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username,
            password: password,
            encryptionMode: encryptionMode,
            logonType: logonType,
            connectionName: connectionName.trimmingCharacters(in: .whitespacesAndNewlines),
            options: FTPConnectionOptions(
                dataConnectionMode: dataConnectionMode,
                listingMode: listingMode,
                passiveHostMode: passiveHostMode,
                initialPath: initialPath,
                timeoutSeconds: Int(timeoutSeconds.rounded())
            )
        )
    }
    
    private func quickRetryButton(
        _ title: String,
        dataMode: FTPDataConnectionMode? = nil,
        listingMode: FTPListingMode? = nil
    ) -> some View {
        Button(title) {
            guard let portInt = Int(port) else { return }
            var server = buildServer(port: portInt)
            if let dataMode {
                self.dataConnectionMode = dataMode
                server = FTPServer(
                    host: server.host,
                    port: server.port,
                    username: server.username,
                    password: server.password,
                    encryptionMode: server.encryptionMode,
                    logonType: server.logonType,
                    connectionName: server.connectionName,
                    options: FTPConnectionOptions(
                        dataConnectionMode: dataMode,
                        listingMode: self.listingMode,
                        passiveHostMode: self.passiveHostMode,
                        initialPath: self.initialPath,
                        timeoutSeconds: Int(self.timeoutSeconds.rounded())
                    )
                )
            }
            if let listingMode {
                self.listingMode = listingMode
                server = FTPServer(
                    host: server.host,
                    port: server.port,
                    username: server.username,
                    password: server.password,
                    encryptionMode: server.encryptionMode,
                    logonType: server.logonType,
                    connectionName: server.connectionName,
                    options: FTPConnectionOptions(
                        dataConnectionMode: self.dataConnectionMode,
                        listingMode: listingMode,
                        passiveHostMode: self.passiveHostMode,
                        initialPath: self.initialPath,
                        timeoutSeconds: Int(self.timeoutSeconds.rounded())
                    )
                )
            }
            ftpManager.connect(to: server)
        }
        .buttonStyle(.bordered)
    }
    
    private func syncFromLastServerIfNeeded() {
        guard let server = ftpManager.lastUsedServer, host.isEmpty else { return }
        apply(server: server)
    }
    
    private func applyRecentConnection(_ item: FTPRecentConnection) {
        apply(server: item.asServer())
    }
    
    private func apply(server: FTPServer) {
        host = server.host
        port = String(server.port)
        username = server.username
        password = server.password
        connectionName = server.connectionName
        encryptionMode = server.encryptionMode
        logonType = server.logonType
        dataConnectionMode = server.options.dataConnectionMode
        listingMode = server.options.listingMode
        passiveHostMode = server.options.passiveHostMode
        initialPath = server.options.initialPath
        timeoutSeconds = Double(server.options.timeoutSeconds)
    }
    
    private func formRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            Text("\(title):")
                .frame(width: 100, alignment: .leading)
            content()
        }
    }
    
    private func color(for level: FTPDiagnosticLevel) -> Color {
        switch level {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
    
    private func relativeDateText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ConnectionView_Previews: PreviewProvider {
    static var previews: some View {
        ConnectionView(ftpManager: FTPManager())
    }
}
