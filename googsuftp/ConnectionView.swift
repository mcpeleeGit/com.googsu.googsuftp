import SwiftUI
import Network

struct ConnectionView: View {
    @ObservedObject var ftpManager: FTPManager
    @State private var host: String = ""
    @State private var port: String = "21"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var useSSL: Bool = false
    @State private var showPassword: Bool = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("FTP 서버 연결")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("서버 주소:")
                        .frame(width: 100, alignment: .leading)
                    TextField("예: ftp.example.com", text: $host)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focusable()
                        .frame(height: 30)
                        .padding(.horizontal, 8)
                }
                
                HStack {
                    Text("포트:")
                        .frame(width: 100, alignment: .leading)
                    TextField("포트", text: $port)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focusable()
                        .frame(height: 30)
                        .padding(.horizontal, 8)
                }
                
                HStack {
                    Text("사용자명:")
                        .frame(width: 100, alignment: .leading)
                    TextField("사용자명 (선택사항)", text: $username)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focusable()
                        .frame(height: 30)
                        .padding(.horizontal, 8)
                }
                
                HStack {
                    Text("비밀번호:")
                        .frame(width: 100, alignment: .leading)
                    if showPassword {
                        TextField("비밀번호", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .focusable()
                            .frame(height: 30)
                            .padding(.horizontal, 8)
                    } else {
                        SecureField("비밀번호", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .focusable()
                            .frame(height: 30)
                            .padding(.horizontal, 8)
                    }
                    Button(action: { showPassword.toggle() }) {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                }
                
                HStack {
                    Text("SSL 사용:")
                        .frame(width: 100, alignment: .leading)
                    Toggle("", isOn: $useSSL)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            
            // 연결 상태 표시
            connectionStatusView
            
            // 연결 문제 해결 도움말
            if case .error = ftpManager.connectionState {
                troubleshootingHelpView
            }
            
            // 연결/해제 버튼
            HStack(spacing: 20) {
                Button(action: connectToServer) {
                    HStack {
                        if ftpManager.connectionState == .connecting {
                            ProgressView()
                                .scaleEffect(0.7)
                                .foregroundColor(.white)
                        } else {
                            Image(systemName: "link")
                        }
                        Text(connectionButtonText)
                    }
                    .frame(minWidth: 100)
                    .padding()
                    .background(connectionButtonColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(ftpManager.connectionState == .connected || ftpManager.connectionState == .connecting || host.isEmpty)
                
                Button(action: disconnectFromServer) {
                    HStack {
                        Image(systemName: "link.slash")
                        Text("해제")
                    }
                    .frame(minWidth: 100)
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(ftpManager.connectionState != .connected)
            }
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: 500)
    }
    
    private var connectionStatusView: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
                Text(statusText)
                    .fontWeight(.medium)
                    .foregroundColor(statusColor)
            }
            
            if !ftpManager.statusDetail.isEmpty {
                Text(ftpManager.statusDetail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if !ftpManager.attemptPlan.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("재시도 시도 목록")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    if let idx = ftpManager.currentAttemptIndex, idx < ftpManager.attemptPlan.count {
                        Text("현재 재시도: \(idx + 1)/\(ftpManager.attemptPlan.count) - \(ftpManager.attemptPlan[idx])")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    
                    ForEach(Array(ftpManager.attemptPlan.enumerated()), id: \.offset) { idx, label in
                        HStack(spacing: 6) {
                            Text(idx == ftpManager.currentAttemptIndex ? "▶︎" : "•")
                                .font(.caption2)
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
                            .multilineTextAlignment(.leading)
                    }
                    
                    Button(action: { ftpManager.retryLastListing() }) {
                        HStack {
                            if ftpManager.isAttemptRunning {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(ftpManager.isAttemptRunning ? "재시도 중..." : "목록 조회 재시도")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(ftpManager.connectionState == .connected ? Color.orange : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                    }
                    .disabled(ftpManager.connectionState != .connected || ftpManager.isAttemptRunning)
                }
                .padding(.horizontal)
            }
            
            if ftpManager.connectionState == .connecting {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    
                    Text("서버에 연결 중...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("잠시만 기다려주세요")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
            
            switch ftpManager.connectionState {
            case .error(let message):
                VStack(spacing: 4) {
                    Text("오류 상세:")
                        .font(.caption)
                        .foregroundColor(.red)
                    
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            default:
                EmptyView()
            }
        }
        .padding()
        .background(statusColor.opacity(0.1))
        .cornerRadius(8)
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
            return "연결됨"
        case .error:
            return "재연결"
        }
    }
    
    private var connectionButtonColor: Color {
        switch ftpManager.connectionState {
        case .disconnected:
            return .blue
        case .connecting:
            return .orange
        case .connected:
            return .gray
        case .error:
            return .blue
        }
    }
    
    private var troubleshootingHelpView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("연결 문제 해결")
                    .font(.headline)
                    .foregroundColor(.orange)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("다음 사항들을 확인해보세요:")
                    .font(.caption)
                    .fontWeight(.medium)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("• FTP 서버가 실행 중인지 확인")
                    Text("• 서버 주소와 포트가 올바른지 확인")
                    Text("• 방화벽 설정 확인")
                    Text("• 네트워크 연결 상태 확인")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            
            // 연결 테스트 버튼
            Button(action: testConnection) {
                HStack {
                    Image(systemName: "network")
                    Text("연결 테스트")
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
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
        guard let portInt = Int(port) else { 
            print("포트 번호가 유효하지 않습니다: \(port)")
            return 
        }
        
        print("FTP 서버 연결 시도:")
        print("  - 호스트: \(host)")
        print("  - 포트: \(portInt)")
        print("  - 사용자명: \(username.isEmpty ? "익명" : username)")
        print("  - SSL 사용: \(useSSL)")
        
        let server = FTPServer(
            host: host,
            port: portInt,
            username: username,
            password: password,
            useSSL: useSSL
        )
        
        ftpManager.connect(to: server)
    }
    
    private func testConnection() {
        guard let portInt = Int(port) else { 
            print("포트 번호가 유효하지 않습니다: \(port)")
            return 
        }
        
        print("연결 테스트 시작: \(host):\(portInt)")
        
        // 간단한 연결 테스트
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(portInt))
        )
        
        let testConnection = NWConnection(to: endpoint, using: .tcp)
        
        testConnection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("✅ 연결 테스트 성공: \(self.host):\(portInt)")
                DispatchQueue.main.async {
                    // 성공 메시지 표시
                }
            case .failed(let error):
                print("❌ 연결 테스트 실패: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    // 실패 메시지 표시
                }
            case .cancelled:
                print("🔄 연결 테스트 취소됨")
            default:
                break
            }
        }
        
        // 5초 타임아웃
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            testConnection.cancel()
        }
        
        testConnection.start(queue: .global())
    }
    
    private func disconnectFromServer() {
        ftpManager.disconnect()
    }
}

#Preview {
    ConnectionView(ftpManager: FTPManager())
}
