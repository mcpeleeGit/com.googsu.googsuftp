import Foundation
import Network
import Darwin

final class FTPManager: ObservableObject {
    private static let recentConnectionsKey = "FTPRecentConnections"
    private static let recentConnectionsLimit = 8
    
    @Published var connectionState: FTPConnectionState = .disconnected
    @Published var statusDetail: String = ""
    @Published var attemptPlan: [String] = []
    @Published var currentAttemptIndex: Int? = nil
    @Published var lastAttemptError: String? = nil
    @Published var isAttemptRunning: Bool = false
    @Published var currentDirectory: String = "/"
    @Published var items: [FTPItem] = []
    @Published var operations: [FTPOperation] = []
    @Published var diagnostics: [FTPDiagnostic] = []
    @Published var eventLog: [String] = []
    @Published var lastUsedServer: FTPServer?
    @Published var recentConnections: [FTPRecentConnection] = []
    
    private let networkQueue = DispatchQueue(label: "FTPManager.networkQueue")
    
    private var controlInputStream: InputStream?
    private var controlOutputStream: OutputStream?
    private var currentServer: FTPServer?
    private var controlReceiveBuffer = Data()
    private var isListingInProgress = false
    private var pendingDirectoryChange: String?
    private var lastDirectoryChangeRequest: (path: String, date: Date)?
    private var successfulListAttempt: (label: String, mode: String, command: String)?
    private var featureFlags: Set<String>?
    private var usesPrivateDataProtection = false
    
    init() {
        loadRecentConnections()
    }
    
    private func resetForNewConnection(server: FTPServer) {
        DispatchQueue.main.async {
            self.lastUsedServer = server
            self.connectionState = .connecting
            self.currentDirectory = "/"
            self.items = []
            self.attemptPlan = []
            self.currentAttemptIndex = nil
            self.lastAttemptError = nil
            self.diagnostics = []
            self.eventLog = []
        }
        controlReceiveBuffer = Data()
        successfulListAttempt = nil
        featureFlags = nil
        usesPrivateDataProtection = false
    }
    
    private func appendDiagnostic(level: FTPDiagnosticLevel, title: String, message: String, suggestions: [String] = []) {
        DispatchQueue.main.async {
            self.diagnostics.append(
                FTPDiagnostic(level: level, title: title, message: message, suggestions: suggestions)
            )
        }
    }
    
    private func setStatus(_ text: String) {
        let safeText = redactSensitiveText(in: text)
        DispatchQueue.main.async {
            self.statusDetail = safeText
            self.eventLog.append(safeText)
            if self.eventLog.count > 40 {
                self.eventLog.removeFirst(self.eventLog.count - 40)
            }
        }
        print(safeText)
    }
    
    private func setConnectionError(_ message: String, suggestions: [String] = []) {
        setStatus(message)
        appendDiagnostic(level: .error, title: "연결 실패", message: message, suggestions: suggestions)
        DispatchQueue.main.async {
            self.connectionState = .error(message)
        }
    }
    
    private func setAttemptPlan(_ plan: [String]) {
        DispatchQueue.main.async {
            self.attemptPlan = plan
            self.currentAttemptIndex = nil
            self.lastAttemptError = nil
        }
    }
    
    private func setAttemptProgress(index: Int, error: String? = nil) {
        DispatchQueue.main.async {
            self.currentAttemptIndex = index
            self.lastAttemptError = error
        }
    }
    
    private func setLastAttemptError(_ error: String?) {
        DispatchQueue.main.async {
            self.lastAttemptError = error
        }
    }
    
    func connect(to server: FTPServer) {
        networkQueue.async {
            self.disconnectTransport()
            self.currentServer = server
            self.resetForNewConnection(server: server)
            self.setStatus("FTP 연결 시작: \(server.host):\(server.port)")
            self.appendDiagnostic(
                level: .info,
                title: "연결 설정",
                message: "암호화=\(server.encryptionMode.title), 로그온 유형=\(server.logonType.title), 데이터 연결=\(server.options.dataConnectionMode.title), 목록 조회=\(server.options.listingMode.title), PASV 주소=\(server.options.passiveHostMode.title)"
            )
            
            self.testHostConnectivity(host: server.host, port: server.port, timeout: server.options.timeoutSeconds) { success, message in
                self.networkQueue.async {
                    guard self.currentServer?.host == server.host, self.currentServer?.port == server.port else { return }
                    if success {
                        self.establishFTPConnection(to: server)
                    } else {
                        let detail = message ?? "서버 연결 테스트 실패"
                        self.appendDiagnostic(
                            level: .warning,
                            title: "사전 연결 테스트 실패",
                            message: detail,
                            suggestions: [
                                "이 테스트는 실제 FTP 연결과 다르게 실패할 수 있습니다.",
                                "다른 프로그램에서 접속된다면 실제 제어 채널 연결을 계속 시도해 보는 편이 더 정확합니다."
                            ]
                        )
                        self.setStatus("사전 연결 테스트 실패, 실제 FTP 연결을 계속 시도합니다: \(detail)")
                        self.establishFTPConnection(to: server)
                    }
                }
            }
        }
    }
    
    func removeRecentConnection(_ item: FTPRecentConnection) {
        DispatchQueue.main.async {
            self.recentConnections.removeAll { $0.id == item.id }
            self.persistRecentConnections()
        }
    }
    
    func reconnectLastServer(overriding options: FTPConnectionOptions? = nil) {
        guard let server = lastUsedServer ?? currentServer else { return }
        let nextServer = FTPServer(
            host: server.host,
            port: server.port,
            username: server.username,
            password: server.password,
            encryptionMode: server.encryptionMode,
            logonType: server.logonType,
            connectionName: server.connectionName,
            options: options ?? server.options
        )
        connect(to: nextServer)
    }
    
    private func testHostConnectivity(
        host: String,
        port: Int,
        timeout: Int,
        completion: @escaping (Bool, String?) -> Void
    ) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )
        
        let probe = NWConnection(to: endpoint, using: .tcp)
        var completed = false
        
        func finish(_ success: Bool, _ message: String? = nil) {
            guard !completed else { return }
            completed = true
            probe.cancel()
            completion(success, message)
        }
        
        probe.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setStatus("호스트 연결 테스트 성공")
                finish(true)
            case .failed(let error):
                self?.setStatus("호스트 연결 테스트 실패: \(error.localizedDescription)")
                finish(false, "서버에 도달하지 못했습니다: \(error.localizedDescription)")
            case .waiting(let error):
                self?.setStatus("호스트 연결 대기 중: \(error.localizedDescription)")
            default:
                break
            }
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
            finish(false, "서버 응답이 없어 \(timeout)초 후 연결 테스트가 종료되었습니다.")
        }
        
        probe.start(queue: .global())
    }
    
    private func establishFTPConnection(to server: FTPServer) {
        setStatus("제어 채널 연결 준비 중...")
        
        guard openControlConnection(host: server.host, port: server.port, timeout: server.options.timeoutSeconds) else {
            setConnectionError(
                "제어 채널 연결에 실패했습니다.",
                suggestions: [
                    "서버가 실행 중인지 확인해 보세요.",
                    "방화벽이나 네트워크 장비가 FTP 포트를 차단하고 있지 않은지 점검해 보세요."
                ]
            )
            return
        }
        
        guard let greeting = receiveControlResponse(timeoutSeconds: server.options.timeoutSeconds) else {
            setConnectionError("서버 환영 메시지를 받지 못했습니다.")
            return
        }
        
        let cleanedGreeting = greeting.trimmingCharacters(in: .whitespacesAndNewlines)
        setStatus("서버 환영 메시지: \(cleanedGreeting)")
        
        guard greeting.hasPrefix("220") || greeting.contains("220") else {
            setConnectionError(
                "서버 환영 응답이 예상과 다릅니다: \(cleanedGreeting)",
                suggestions: [
                    "일반 FTP/FTPS 포트가 맞는지 확인해 보세요."
                ]
            )
            return
        }
        
        if server.encryptionMode == .explicitTLS {
            guard startExplicitTLS(server: server) else { return }
        } else if server.encryptionMode == .implicitTLS {
            setConnectionError(
                "암시적 FTPS는 아직 지원하지 않습니다.",
                suggestions: ["현재 구현은 `AUTH TLS` 방식의 명시적 FTPS만 지원합니다."]
            )
            return
        }
        
        authenticate(server: server)
    }
    
    private func startExplicitTLS(server: FTPServer) -> Bool {
        setStatus("AUTH TLS 요청 중...")
        guard let authResponse = sendCommandAndWait("AUTH TLS") else {
            setConnectionError("AUTH TLS 응답을 받지 못했습니다.")
            return false
        }
        
        let cleaned = authResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        setStatus("AUTH TLS 응답: \(cleaned)")
        guard authResponse.hasPrefix("234") || authResponse.hasPrefix("334") else {
            setConnectionError(
                "서버가 AUTH TLS를 허용하지 않았습니다: \(cleaned)",
                suggestions: [
                    "서버 설정에서 명시적 FTPS 지원 여부를 확인해 보세요."
                ]
            )
            return false
        }
        
        guard upgradeControlConnectionToTLS(host: server.host) else {
            setConnectionError(
                "제어 채널 TLS 협상에 실패했습니다.",
                suggestions: [
                    "서버 인증서가 신뢰되지 않거나, TLS 협상이 중간에서 차단될 수 있습니다."
                ]
            )
            return false
        }
        
        guard let pbsz = sendCommandAndWait("PBSZ 0"), pbsz.hasPrefix("200") else {
            setConnectionError("PBSZ 0 설정에 실패했습니다.")
            return false
        }
        setStatus("PBSZ 응답: \(pbsz.trimmingCharacters(in: .whitespacesAndNewlines))")
        
        guard let prot = sendCommandAndWait("PROT P"), prot.hasPrefix("200") else {
            setConnectionError("PROT P 설정에 실패했습니다.")
            return false
        }
        setStatus("PROT 응답: \(prot.trimmingCharacters(in: .whitespacesAndNewlines))")
        usesPrivateDataProtection = true
        appendDiagnostic(level: .info, title: "FTPS 활성화", message: "AUTH TLS, PBSZ 0, PROT P 까지 완료했습니다.")
        return true
    }
    
    private func authenticate(server: FTPServer) {
        let user: String
        let pass: String
        switch server.logonType {
        case .anonymous:
            user = "anonymous"
            pass = "anonymous@"
        case .normal:
            user = server.username.isEmpty ? "anonymous" : server.username
            pass = server.username.isEmpty && server.password.isEmpty ? "anonymous@" : server.password
        }
        
        setStatus("FTP 인증 시작: 사용자명 \(user)")
        
        guard let userResponse = sendCommandAndWait("USER \(user)") else {
            setConnectionError("USER 명령 응답이 없습니다.")
            return
        }
        
        let cleanedUserResponse = userResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        setStatus("FTP USER 응답: \(cleanedUserResponse)")
        
        if userResponse.hasPrefix("331") {
            guard let passResponse = sendCommandAndWait("PASS \(pass)") else {
                setConnectionError("PASS 명령 응답이 없습니다.")
                return
            }
            
            let cleanedPass = passResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            setStatus("FTP PASS 응답: \(cleanedPass)")
            
            guard passResponse.hasPrefix("230") else {
                setConnectionError(
                    "비밀번호 인증 실패: \(cleanedPass)",
                    suggestions: [
                        "사용자명/비밀번호를 다시 확인해 보세요."
                    ]
                )
                return
            }
        } else if !userResponse.hasPrefix("230") {
            setConnectionError(
                "사용자명 인증 실패: \(cleanedUserResponse)",
                suggestions: [
                    "로그온 유형이 `일반`인지, 계정 정보가 맞는지 확인해 보세요."
                ]
            )
            return
        }
        
        DispatchQueue.main.async {
            self.connectionState = .connected
        }
        saveSuccessfulConnection(server)
        appendDiagnostic(level: .info, title: "인증 성공", message: "로그인까지 정상적으로 완료되었습니다.")
        
        let initialPath = server.options.initialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !initialPath.isEmpty {
            changeDirectory(initialPath)
        } else {
            listDirectory()
        }
    }
    
    func listDirectory() {
        listDirectoryWithFallback()
    }
    
    func listDirectoryWithFallback() {
        networkQueue.async {
            guard !self.isListingInProgress else { return }
            self.isListingInProgress = true
            DispatchQueue.main.async { self.isAttemptRunning = true }
            defer {
                self.isListingInProgress = false
                DispatchQueue.main.async { self.isAttemptRunning = false }
            }
            
            guard let server = self.currentServer else { return }
            
            self.drainPendingControlResponses(reason: "목록 조회 전 지연 응답 정리")
            let hasPinnedAttempt = self.successfulListAttempt != nil
            self.setStatus(hasPinnedAttempt ? "디렉터리 목록 가져오기 시작(성공한 설정 재사용)" : "디렉터리 목록 가져오기 시작(재시도 플랜)")
            _ = self.sendCommandAndWait("TYPE A")
            
            let attempts = self.makeListAttempts(for: server)
            self.setAttemptPlan(attempts.map(\.label))
            
            for (index, attempt) in attempts.enumerated() {
                self.setAttemptProgress(index: index, error: nil)
                self.setStatus("재시도 \(index + 1)/\(attempts.count): \(attempt.label)")
                
                if self.runListAttempt(attempt: attempt, server: server) {
                    self.successfulListAttempt = attempt
                    self.appendDiagnostic(level: .info, title: "목록 조회 성공", message: "이 서버는 \(attempt.label) 조합으로 동작했습니다.")
                    return
                }
                
                if hasPinnedAttempt {
                    break
                }
            }
            
            let err = self.lastAttemptError ?? "디렉터리 목록 조회 실패(모든 재시도 실패)"
            self.appendDiagnostic(
                level: .error,
                title: "데이터 채널 문제",
                message: err,
                suggestions: [
                    "데이터 연결을 `PASV만` 또는 `EPSV만`으로 바꿔 다시 시도해 보세요.",
                    "명시적 FTPS 서버라면 방화벽에서 TLS 데이터 채널을 차단하는지 점검해 보세요.",
                    "구형 서버는 `LIST만`으로 제한했을 때 더 잘 동작할 수 있습니다."
                ]
            )
            DispatchQueue.main.async {
                self.connectionState = .error(err)
            }
        }
    }
    
    func retryLastListing() {
        listDirectoryWithFallback()
    }
    
    private func makeListAttempts(for server: FTPServer) -> [(label: String, mode: String, command: String)] {
        if let successfulListAttempt {
            return [successfulListAttempt]
        }
        
        let supportsMLSD = checkFeatureContains("MLSD")
        let commands: [String]
        
        switch server.options.listingMode {
        case .automatic:
            var built: [String] = []
            if supportsMLSD { built.append("MLSD") }
            built.append("LIST")
            built.append("NLST")
            commands = built
        case .listOnly:
            commands = ["LIST"]
        case .mlsdOnly:
            commands = ["MLSD"]
        case .nlstOnly:
            commands = ["NLST"]
        }
        
        let modes: [String]
        switch server.options.dataConnectionMode {
        case .automatic:
            modes = ["EPSV", "PASV"]
        case .epsvOnly:
            modes = ["EPSV"]
        case .pasvOnly:
            modes = ["PASV"]
        case .preferPasv:
            modes = ["PASV", "EPSV"]
        }
        
        return modes.flatMap { mode in
            commands.map { command in
                ("\(mode) + \(command)", mode, command)
            }
        }
    }
    
    private func runListAttempt(attempt: (label: String, mode: String, command: String), server: FTPServer) -> Bool {
        guard let modeResponse = sendCommandAndWait(attempt.mode) else {
            setLastAttemptError("\(attempt.mode) 응답 타임아웃")
            return false
        }
        
        let cleanedMode = modeResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint: (host: String, port: Int)?
        switch attempt.mode {
        case "EPSV":
            guard modeResponse.hasPrefix("229") else {
                setLastAttemptError("EPSV 실패: \(cleanedMode)")
                return false
            }
            endpoint = parseEPSVEndpoint(from: modeResponse, controlHost: server.host)
        default:
            guard modeResponse.hasPrefix("227") else {
                setLastAttemptError("PASV 실패: \(cleanedMode)")
                return false
            }
            endpoint = parsePASVEndpoint(from: modeResponse, server: server)
        }
        
        guard let endpoint else {
            setLastAttemptError("\(attempt.mode) 응답 파싱 실패")
            return false
        }
        
        guard let dataListing = performDataCommand(
            attempt.command,
            host: endpoint.host,
            port: endpoint.port,
            secure: server.encryptionMode == .explicitTLS && usesPrivateDataProtection,
            timeout: server.options.timeoutSeconds
        ) else {
            return false
        }
        
        let parsed: [FTPItem]
        switch attempt.command {
        case "MLSD":
            parsed = parseMLSD(dataListing)
        case "NLST":
            parsed = parseNameList(dataListing)
        default:
            parsed = parseDirectoryListing(dataListing)
        }
        
        DispatchQueue.main.async {
            self.items = parsed
        }
        return true
    }
    
    private func performDataCommand(
        _ command: String,
        host: String,
        port: Int,
        secure: Bool,
        timeout: Int
    ) -> String? {
        setStatus("\(command)용 데이터 연결 준비: \(host):\(port) \(secure ? "(TLS)" : "")")
        
        guard let dataStreams = openStreamPair(host: host, port: port, secure: secure, timeout: timeout) else {
            setLastAttemptError("데이터 연결 실패: \(host):\(port)")
            return nil
        }
        
        defer { closeStreamPair(dataStreams) }
        
        guard let firstResponse = sendCommandAndWait(command) else {
            setLastAttemptError("\(command) 응답 타임아웃")
            return nil
        }
        
        let cleanedFirst = firstResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        setStatus("\(command) 컨트롤 응답: \(cleanedFirst)")
        guard firstResponse.hasPrefix("150") || firstResponse.hasPrefix("125") || firstResponse.hasPrefix("226") || firstResponse.hasPrefix("250") else {
            setLastAttemptError("\(command) 실패: \(cleanedFirst)")
            return nil
        }
        
        let listingResult = readAll(from: dataStreams.input, timeoutSeconds: timeout)
        let listing = listingResult?.text ?? ""
        let dataTransferFinished = listingResult?.didReachEnd ?? false
        let receivedListingBytes = listingResult?.receivedBytes ?? false
        
        if firstResponse.hasPrefix("150") || firstResponse.hasPrefix("125") {
            guard let finalResponse = receiveControlResponse(timeoutSeconds: timeout) else {
                if receivedListingBytes || dataTransferFinished {
                    setStatus("\(command) 완료 응답을 받지 못했지만 데이터 수신이 끝나 성공으로 간주합니다.")
                    drainPendingControlResponses(reason: "\(command) 지연 완료 응답 정리", acceptedPrefixes: ["226", "250"])
                    return listing
                }
                setLastAttemptError("\(command) 완료 응답 타임아웃")
                return nil
            }
            
            let cleanedFinal = finalResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            setStatus("\(command) 완료 응답: \(cleanedFinal)")
            guard finalResponse.hasPrefix("226") || finalResponse.hasPrefix("250") else {
                if receivedListingBytes || dataTransferFinished {
                    setStatus("\(command) 완료 응답이 비정상이지만 데이터 수신이 끝나 성공으로 간주합니다: \(cleanedFinal)")
                    drainPendingControlResponses(reason: "\(command) 추가 지연 응답 정리", acceptedPrefixes: ["226", "250"])
                    return listing
                }
                setLastAttemptError("\(command) 완료 응답 오류: \(cleanedFinal)")
                return nil
            }
        }
        
        return listing
    }
    
    private func refreshCurrentDirectory() {
        guard let response = sendCommandAndWait("PWD") else { return }
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        setStatus("PWD 응답: \(cleaned)")
        if response.hasPrefix("257"),
           let startIndex = response.firstIndex(of: "\""),
           let endIndex = response.lastIndex(of: "\"") {
            let path = String(response[startIndex...endIndex]).replacingOccurrences(of: "\"", with: "")
            DispatchQueue.main.async {
                self.currentDirectory = path
            }
        }
    }
    
    private func checkFeatureContains(_ token: String) -> Bool {
        let features = loadFeatureFlags()
        if features.isEmpty { return true }
        return features.contains(token.uppercased())
    }
    
    private func loadFeatureFlags() -> Set<String> {
        if let featureFlags {
            return featureFlags
        }
        
        guard let response = sendCommandAndWait("FEAT", timeoutSeconds: 8) else {
            featureFlags = []
            return []
        }
        
        let upper = response.uppercased()
        if upper.hasPrefix("500") || upper.hasPrefix("502") {
            featureFlags = []
            return []
        }
        
        var loaded: Set<String> = []
        for line in upper.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("211") { continue }
            loaded.insert(trimmed)
            for token in trimmed.split(separator: " ") {
                loaded.insert(String(token))
            }
        }
        featureFlags = loaded
        return loaded
    }

    private func drainPendingControlResponses(
        reason: String,
        acceptedPrefixes: [String] = ["226", "250"],
        timeoutSeconds: TimeInterval = 0.35
    ) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        
        while Date() < deadline {
            if let parsed = parseFTPResponse(from: &controlReceiveBuffer) {
                let cleaned = parsed.trimmingCharacters(in: .whitespacesAndNewlines)
                if acceptedPrefixes.contains(where: { parsed.hasPrefix($0) }) {
                    setStatus("\(reason): \(cleaned)")
                    continue
                }
                if let data = parsed.data(using: .utf8) {
                    controlReceiveBuffer.insert(contentsOf: data, at: 0)
                }
                return
            }
            
            guard let input = controlInputStream else { return }
            guard input.hasBytesAvailable else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = input.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                controlReceiveBuffer.append(buffer, count: count)
                continue
            }
            return
        }
    }
    
    private func openControlConnection(host: String, port: Int, timeout: Int) -> Bool {
        guard let streams = openStreamPair(host: host, port: port, secure: false, timeout: timeout) else {
            return false
        }
        controlInputStream = streams.input
        controlOutputStream = streams.output
        controlReceiveBuffer = Data()
        setStatus("제어 채널 연결 성공")
        return true
    }
    
    private func upgradeControlConnectionToTLS(host: String) -> Bool {
        guard let input = controlInputStream, let output = controlOutputStream else { return false }
        applyTLSSettings(to: input, output: output, host: host)
        setStatus("제어 채널 TLS 협상 시작")
        
        let timeout = currentServer?.options.timeoutSeconds ?? 10
        let probeCommand = "NOOP"
        guard writeCommand(probeCommand) else { return false }
        guard let response = receiveControlResponse(timeoutSeconds: timeout) else { return false }
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        setStatus("TLS 협상 확인 응답: \(cleaned)")
        return response.hasPrefix("200")
    }
    
    private func sendCommandAndWait(_ command: String, timeoutSeconds: TimeInterval? = nil) -> String? {
        guard writeCommand(command) else { return nil }
        return receiveControlResponse(timeoutSeconds: Int(timeoutSeconds ?? TimeInterval(currentServer?.options.timeoutSeconds ?? 10)))
    }
    
    private func writeCommand(_ command: String) -> Bool {
        guard let output = controlOutputStream else { return false }
        let payload = (command + "\r\n").data(using: .utf8) ?? Data()
        setStatus("FTP 명령 전송: \(command)")
        
        return payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            var totalWritten = 0
            let timeoutDate = Date().addingTimeInterval(TimeInterval(currentServer?.options.timeoutSeconds ?? 10))
            
            while totalWritten < payload.count {
                if output.streamStatus == .error || output.streamStatus == .closed {
                    setStatus("명령 전송 실패: 출력 스트림 닫힘")
                    return false
                }
                
                if output.hasSpaceAvailable {
                    let written = output.write(baseAddress.advanced(by: totalWritten), maxLength: payload.count - totalWritten)
                    if written < 0 {
                        setStatus("명령 전송 오류: \(output.streamError?.localizedDescription ?? "알 수 없음")")
                        return false
                    }
                    totalWritten += written
                } else {
                    if Date() > timeoutDate {
                        setStatus("명령 전송 타임아웃: \(command)")
                        return false
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            return true
        }
    }
    
    private func receiveControlResponse(timeoutSeconds: Int) -> String? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        
        while Date() < deadline {
            if let parsed = parseFTPResponse(from: &controlReceiveBuffer) {
                return parsed
            }
            
            guard let input = controlInputStream else { return nil }
            if input.streamStatus == .error || input.streamStatus == .closed {
                return parseFTPResponse(from: &controlReceiveBuffer)
            }
            
            if input.hasBytesAvailable {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = input.read(&buffer, maxLength: buffer.count)
                if count > 0 {
                    controlReceiveBuffer.append(buffer, count: count)
                    continue
                }
                if count < 0 {
                    setStatus("응답 수신 오류: \(input.streamError?.localizedDescription ?? "알 수 없음")")
                    return nil
                }
            }
            
            Thread.sleep(forTimeInterval: 0.05)
        }
        
        return parseFTPResponse(from: &controlReceiveBuffer)
    }
    
    private func parseFTPResponse(from buffer: inout Data) -> String? {
        guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n") else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.count >= 4 else { return nil }
        
        let code = String(first.prefix(3))
        let marker = first[first.index(first.startIndex, offsetBy: 3)]
        
        if marker == "-" {
            for (index, line) in lines.enumerated() where index > 0 {
                if line.hasPrefix(code + " ") {
                    let response = lines[0...index].joined(separator: "\r\n") + "\r\n"
                    let count = response.data(using: .utf8)?.count ?? 0
                    buffer.removeFirst(min(count, buffer.count))
                    return response
                }
            }
            return nil
        }
        
        guard let range = text.range(of: "\r\n") else { return nil }
        let response = String(text[..<range.upperBound])
        let count = response.data(using: .utf8)?.count ?? 0
        buffer.removeFirst(min(count, buffer.count))
        return response
    }
    
    private func openStreamPair(host: String, port: Int, secure: Bool, timeout: Int) -> (input: InputStream, output: OutputStream)? {
        guard let socket = connectSocket(host: host, port: port, timeout: timeout) else {
            setStatus("소켓 연결 실패: \(host):\(port)")
            return nil
        }
        
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(nil, socket, &readStream, &writeStream)
        
        guard let readStream, let writeStream else {
            close(socket)
            return nil
        }
        
        let input = readStream.takeRetainedValue() as InputStream
        let output = writeStream.takeRetainedValue() as OutputStream
        let closeSocketKey = Stream.PropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket as String)
        input.setProperty(kCFBooleanTrue, forKey: closeSocketKey)
        output.setProperty(kCFBooleanTrue, forKey: closeSocketKey)
        
        if secure {
            applyTLSSettings(to: input, output: output, host: host)
        }
        
        input.open()
        output.open()
        
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            let inputReady = input.streamStatus == .open || input.hasBytesAvailable
            let outputReady = output.streamStatus == .open || output.hasSpaceAvailable
            if inputReady && outputReady {
                return (input, output)
            }
            if input.streamStatus == .error || output.streamStatus == .error {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        
        closeStreamPair((input, output))
        return nil
    }
    
    private func connectSocket(host: String, port: Int, timeout: Int) -> Int32? {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        
        var result: UnsafeMutablePointer<addrinfo>?
        let portString = String(port)
        let status = getaddrinfo(host, portString, &hints, &result)
        guard status == 0, let firstResult = result else {
            let message = String(cString: gai_strerror(status))
            setStatus("DNS 조회 실패: \(message)")
            return nil
        }
        defer { freeaddrinfo(firstResult) }
        
        var pointer: UnsafeMutablePointer<addrinfo>? = firstResult
        while let current = pointer {
            let socketFD = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if socketFD >= 0 {
                if setNonBlocking(socketFD) {
                    let connectResult = Darwin.connect(socketFD, current.pointee.ai_addr, current.pointee.ai_addrlen)
                    if connectResult == 0 || errno == EINPROGRESS {
                        if waitForSocketConnection(socketFD, timeout: timeout) {
                            restoreBlocking(socketFD)
                            return socketFD
                        }
                    }
                }
                close(socketFD)
            }
            pointer = current.pointee.ai_next
        }
        
        return nil
    }
    
    private func setNonBlocking(_ socketFD: Int32) -> Bool {
        let flags = fcntl(socketFD, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0
    }
    
    private func restoreBlocking(_ socketFD: Int32) {
        let flags = fcntl(socketFD, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(socketFD, F_SETFL, flags & ~O_NONBLOCK)
    }
    
    private func waitForSocketConnection(_ socketFD: Int32, timeout: Int) -> Bool {
        var pollFD = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
        let pollResult = Darwin.poll(&pollFD, 1, Int32(timeout * 1000))
        guard pollResult > 0 else { return false }
        
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }
    
    private func applyTLSSettings(to input: InputStream, output: OutputStream, host: String) {
        let sslSettings: [NSString: Any] = [
            kCFStreamSSLPeerName: host as NSString,
            kCFStreamSSLValidatesCertificateChain: kCFBooleanTrue as Any
        ]
        
        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        
        let sslKey = Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String)
        input.setProperty(sslSettings, forKey: sslKey)
        output.setProperty(sslSettings, forKey: sslKey)
    }
    
    private func readAll(from input: InputStream, timeoutSeconds: Int) -> (text: String, didReachEnd: Bool, receivedBytes: Bool)? {
        var data = Data()
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var sawBytes = false
        var reachedEnd = false
        
        while Date() < deadline {
            if input.hasBytesAvailable {
                var buffer = [UInt8](repeating: 0, count: 16384)
                let count = input.read(&buffer, maxLength: buffer.count)
                if count > 0 {
                    data.append(buffer, count: count)
                    sawBytes = true
                    continue
                }
                if count == 0 {
                    reachedEnd = true
                    break
                }
                return nil
            }
            
            if input.streamStatus == .atEnd || input.streamStatus == .closed {
                reachedEnd = true
                break
            }
            
            if sawBytes {
                Thread.sleep(forTimeInterval: 0.05)
            } else {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        
        return (String(data: data, encoding: .utf8) ?? "", reachedEnd, sawBytes)
    }
    
    private func closeStreamPair(_ pair: (input: InputStream, output: OutputStream)) {
        pair.input.close()
        pair.output.close()
    }
    
    private func parseEPSVEndpoint(from response: String, controlHost: String) -> (host: String, port: Int)? {
        guard let start = response.firstIndex(of: "("), let end = response.firstIndex(of: ")") else { return nil }
        let inner = String(response[response.index(after: start)..<end])
        guard let delimiter = inner.first else { return nil }
        let parts = inner.split(separator: delimiter, omittingEmptySubsequences: false)
        guard parts.count >= 4, let port = Int(parts[3]) else { return nil }
        return (controlHost, port)
    }
    
    private func parsePASVEndpoint(from response: String, server: FTPServer) -> (host: String, port: Int)? {
        guard let start = response.firstIndex(of: "("), let end = response.firstIndex(of: ")") else { return nil }
        let inner = String(response[response.index(after: start)..<end])
        let numbers = inner.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count >= 6 else { return nil }
        
        let parsedHost = numbers[0...3].map(String.init).joined(separator: ".")
        let port = numbers[4] * 256 + numbers[5]
        
        let host: String
        switch server.options.passiveHostMode {
        case .useControlHost:
            host = server.host
        case .useServerAddress:
            host = parsedHost
        case .automatic:
            if parsedHost.hasPrefix("10.") ||
                parsedHost.hasPrefix("192.168.") ||
                parsedHost.hasPrefix("172.16.") ||
                parsedHost.hasPrefix("172.17.") ||
                parsedHost.hasPrefix("172.18.") ||
                parsedHost.hasPrefix("172.19.") ||
                parsedHost.hasPrefix("172.2") ||
                parsedHost.hasPrefix("172.30.") ||
                parsedHost.hasPrefix("172.31.") {
                host = server.host
                setStatus("PASV가 사설 IP(\(parsedHost))를 반환 → 데이터 연결은 \(host)로 시도")
            } else {
                host = parsedHost
            }
        }
        
        return (host, port)
    }
    
    private func parseNameList(_ listing: String) -> [FTPItem] {
        listing
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { FTPItem(name: $0, isDirectory: false) }
    }
    
    private func parseMLSD(_ listing: String) -> [FTPItem] {
        var result: [FTPItem] = []
        for raw in listing.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let spaceIndex = line.lastIndex(of: " ") else { continue }
            let facts = String(line[..<spaceIndex])
            let name = String(line[line.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
            let factsLower = facts.lowercased()
            let isDirectory = factsLower.contains("type=dir") || factsLower.contains("type=cdir") || factsLower.contains("type=pdir")
            var size: Int64 = 0
            for fact in facts.split(separator: ";") {
                let parts = fact.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == "size" {
                    size = Int64(parts[1]) ?? 0
                }
            }
            if !name.isEmpty {
                result.append(FTPItem(name: name, isDirectory: isDirectory, size: size))
            }
        }
        return result
    }
    
    private func parseDirectoryListing(_ listing: String) -> [FTPItem] {
        var parsed: [FTPItem] = []
        for line in listing.components(separatedBy: .newlines) {
            if line.isEmpty { continue }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 9 {
                let permissions = parts[0]
                let size = Int64(parts[4]) ?? 0
                let name = parts[8...].joined(separator: " ")
                parsed.append(
                    FTPItem(
                        name: name,
                        isDirectory: permissions.hasPrefix("d"),
                        size: size,
                        permissions: permissions
                    )
                )
            }
        }
        return parsed
    }
    
    func changeDirectory(_ path: String) {
        networkQueue.async {
            let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedPath.isEmpty else { return }
            
            if let lastRequest = self.lastDirectoryChangeRequest,
               lastRequest.path == normalizedPath,
               Date().timeIntervalSince(lastRequest.date) < 1.0 {
                self.setStatus("같은 디렉터리 열기 요청을 무시합니다: \(normalizedPath)")
                return
            }
            self.lastDirectoryChangeRequest = (normalizedPath, Date())
            self.drainPendingControlResponses(reason: "디렉터리 이동 전 지연 응답 정리")
            
            guard self.pendingDirectoryChange != normalizedPath else {
                self.setStatus("같은 디렉터리 이동 요청이 이미 진행 중입니다: \(normalizedPath)")
                return
            }
            self.pendingDirectoryChange = normalizedPath
            defer { self.pendingDirectoryChange = nil }
            
            guard let response = self.sendCommandAndWait("CWD \(normalizedPath)") else { return }
            self.setStatus("CWD 응답: \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
            if response.hasPrefix("250") {
                self.refreshCurrentDirectory()
                self.listDirectory()
            } else {
                self.appendDiagnostic(
                    level: .warning,
                    title: "디렉터리 이동 실패",
                    message: response.trimmingCharacters(in: .whitespacesAndNewlines),
                    suggestions: ["초기 경로를 비워 두고 루트부터 접속해 보세요."]
                )
            }
        }
    }
    
    func goToParentDirectory() {
        networkQueue.async {
            guard let response = self.sendCommandAndWait("CDUP"), response.hasPrefix("250") else { return }
            self.listDirectory()
        }
    }
    
    func uploadFile(localPath: String, remotePath: String) {
        let operation = FTPOperation(type: .upload, localPath: localPath, remotePath: remotePath, state: .uploading)
        DispatchQueue.main.async {
            self.operations.append(operation)
        }
        
        networkQueue.async {
            let result = Result { try Data(contentsOf: URL(fileURLWithPath: localPath)) }
            switch result {
            case .success(let data):
                if self.writeRemoteFile(remotePath: remotePath, data: data) {
                    self.finishOperation(operation.id)
                    self.listDirectory()
                } else {
                    self.failOperation(operation.id, message: self.lastAttemptError ?? "업로드에 실패했습니다.")
                }
            case .failure(let error):
                self.failOperation(operation.id, message: error.localizedDescription)
            }
        }
    }
    
    func downloadFile(remotePath: String, localPath: String) {
        let operation = FTPOperation(type: .download, localPath: localPath, remotePath: remotePath, state: .downloading)
        DispatchQueue.main.async {
            self.operations.append(operation)
        }
        
        networkQueue.async {
            guard let data = self.readRemoteFile(remotePath: remotePath) else {
                self.failOperation(operation.id, message: self.lastAttemptError ?? "다운로드에 실패했습니다.")
                return
            }
            
            do {
                try data.write(to: URL(fileURLWithPath: localPath), options: .atomic)
                self.finishOperation(operation.id)
            } catch {
                self.failOperation(operation.id, message: error.localizedDescription)
            }
        }
    }
    
    func loadTextFile(named fileName: String, completion: @escaping (Result<String, Error>) -> Void) {
        networkQueue.async {
            guard let data = self.readRemoteFile(remotePath: fileName) else {
                let message = self.lastAttemptError ?? "파일 내용을 가져오지 못했습니다."
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "FTPManager", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
                }
                return
            }
            
            guard let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "FTPManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "UTF-8 텍스트 파일이 아니어서 편집기로 열 수 없습니다."])))
                }
                return
            }
            
            DispatchQueue.main.async {
                completion(.success(text))
            }
        }
    }
    
    func saveTextFile(named fileName: String, content: String, completion: @escaping (Result<Void, Error>) -> Void) {
        networkQueue.async {
            let operation = FTPOperation(type: .upload, localPath: nil, remotePath: fileName, state: .uploading)
            DispatchQueue.main.async {
                self.operations.append(operation)
            }
            
            guard let data = content.data(using: .utf8) else {
                self.failOperation(operation.id, message: "UTF-8 인코딩에 실패했습니다.")
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "FTPManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "UTF-8 인코딩에 실패했습니다."])))
                }
                return
            }
            
            if self.writeRemoteFile(remotePath: fileName, data: data) {
                self.finishOperation(operation.id)
                self.listDirectory()
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } else {
                let message = self.lastAttemptError ?? "파일 저장에 실패했습니다."
                self.failOperation(operation.id, message: message)
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "FTPManager", code: 4, userInfo: [NSLocalizedDescriptionKey: message])))
                }
            }
        }
    }
    
    func deleteItem(_ path: String, isDirectory: Bool) {
        let operation = FTPOperation(type: .delete, localPath: nil, remotePath: path)
        operations.append(operation)
        networkQueue.async {
            let command = isDirectory ? "RMD \(path)" : "DELE \(path)"
            guard let response = self.sendCommandAndWait(command) else { return }
            if response.hasPrefix("250") || response.hasPrefix("200") {
                self.listDirectory()
            }
        }
    }
    
    func createDirectory(_ name: String) {
        let operation = FTPOperation(type: .createDirectory, localPath: nil, remotePath: name)
        operations.append(operation)
        networkQueue.async {
            guard let response = self.sendCommandAndWait("MKD \(name)"), response.hasPrefix("257") else { return }
            self.listDirectory()
        }
    }
    
    func disconnect() {
        networkQueue.async {
            _ = self.sendCommandAndWait("QUIT", timeoutSeconds: 3)
            self.disconnectTransport()
            DispatchQueue.main.async {
                self.connectionState = .disconnected
                self.items = []
                self.currentDirectory = "/"
            }
        }
    }
    
    private func disconnectTransport() {
        if let input = controlInputStream, let output = controlOutputStream {
            closeStreamPair((input, output))
        }
        controlInputStream = nil
        controlOutputStream = nil
        controlReceiveBuffer = Data()
        usesPrivateDataProtection = false
    }

    private func transferModeSequence(for server: FTPServer) -> [String] {
        if let successfulListAttempt {
            return [successfulListAttempt.mode]
        }
        
        switch server.options.dataConnectionMode {
        case .automatic:
            return ["EPSV", "PASV"]
        case .epsvOnly:
            return ["EPSV"]
        case .pasvOnly:
            return ["PASV"]
        case .preferPasv:
            return ["PASV", "EPSV"]
        }
    }
    
    private func openDataStreams(for server: FTPServer) -> ((input: InputStream, output: OutputStream), String)? {
        for mode in transferModeSequence(for: server) {
            guard let modeResponse = sendCommandAndWait(mode) else {
                setLastAttemptError("\(mode) 응답 타임아웃")
                continue
            }
            
            let cleanedMode = modeResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            let endpoint: (host: String, port: Int)?
            if mode == "EPSV" {
                guard modeResponse.hasPrefix("229") else {
                    setLastAttemptError("EPSV 실패: \(cleanedMode)")
                    continue
                }
                endpoint = parseEPSVEndpoint(from: modeResponse, controlHost: server.host)
            } else {
                guard modeResponse.hasPrefix("227") else {
                    setLastAttemptError("PASV 실패: \(cleanedMode)")
                    continue
                }
                endpoint = parsePASVEndpoint(from: modeResponse, server: server)
            }
            
            guard let endpoint else {
                setLastAttemptError("\(mode) 응답 파싱 실패")
                continue
            }
            
            setStatus("데이터 연결 준비: \(mode) \(endpoint.host):\(endpoint.port)")
            guard let streams = openStreamPair(
                host: endpoint.host,
                port: endpoint.port,
                secure: server.encryptionMode == .explicitTLS && usesPrivateDataProtection,
                timeout: server.options.timeoutSeconds
            ) else {
                setLastAttemptError("데이터 연결 실패: \(endpoint.host):\(endpoint.port)")
                continue
            }
            return (streams, mode)
        }
        
        return nil
    }
    
    private func readRemoteFile(remotePath: String) -> Data? {
        guard let server = currentServer else { return nil }
        drainPendingControlResponses(reason: "파일 읽기 전 지연 응답 정리")
        _ = sendCommandAndWait("TYPE I")
        
        guard let (streams, mode) = openDataStreams(for: server) else { return nil }
        defer { closeStreamPair(streams) }
        
        guard let firstResponse = sendCommandAndWait("RETR \(remotePath)") else {
            setLastAttemptError("RETR 응답 타임아웃")
            return nil
        }
        
        let cleanedFirst = firstResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        setStatus("RETR 응답: \(cleanedFirst)")
        guard firstResponse.hasPrefix("150") || firstResponse.hasPrefix("125") else {
            setLastAttemptError("RETR 실패: \(cleanedFirst)")
            return nil
        }
        
        let data = readAllData(from: streams.input, timeoutSeconds: server.options.timeoutSeconds)
        guard let finalResponse = receiveControlResponse(timeoutSeconds: server.options.timeoutSeconds) else {
            setLastAttemptError("RETR 완료 응답 타임아웃")
            return nil
        }
        
        let cleanedFinal = finalResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        setStatus("RETR 완료 응답: \(cleanedFinal)")
        guard finalResponse.hasPrefix("226") || finalResponse.hasPrefix("250") else {
            setLastAttemptError("RETR 완료 응답 오류: \(cleanedFinal)")
            return nil
        }
        
        if successfulListAttempt == nil {
            successfulListAttempt = ("\(mode) + LIST", mode, "LIST")
        }
        return data
    }
    
    private func writeRemoteFile(remotePath: String, data: Data) -> Bool {
        guard let server = currentServer else { return false }
        drainPendingControlResponses(reason: "파일 저장 전 지연 응답 정리")
        _ = sendCommandAndWait("TYPE I")
        
        guard let (streams, mode) = openDataStreams(for: server) else { return false }
        defer { closeStreamPair(streams) }
        
        guard let firstResponse = sendCommandAndWait("STOR \(remotePath)") else {
            setLastAttemptError("STOR 응답 타임아웃")
            return false
        }
        
        let cleanedFirst = firstResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        setStatus("STOR 응답: \(cleanedFirst)")
        guard firstResponse.hasPrefix("150") || firstResponse.hasPrefix("125") else {
            setLastAttemptError("STOR 실패: \(cleanedFirst)")
            return false
        }
        
        guard writeAll(data, to: streams.output, timeoutSeconds: server.options.timeoutSeconds) else {
            setLastAttemptError("파일 데이터 전송 실패")
            return false
        }
        streams.output.close()
        
        guard let finalResponse = receiveControlResponse(timeoutSeconds: server.options.timeoutSeconds) else {
            setLastAttemptError("STOR 완료 응답 타임아웃")
            return false
        }
        
        let cleanedFinal = finalResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        setStatus("STOR 완료 응답: \(cleanedFinal)")
        guard finalResponse.hasPrefix("226") || finalResponse.hasPrefix("250") else {
            setLastAttemptError("STOR 완료 응답 오류: \(cleanedFinal)")
            return false
        }
        
        if successfulListAttempt == nil {
            successfulListAttempt = ("\(mode) + LIST", mode, "LIST")
        }
        return true
    }
    
    private func readAllData(from input: InputStream, timeoutSeconds: Int) -> Data? {
        var data = Data()
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        
        while Date() < deadline {
            if input.hasBytesAvailable {
                var buffer = [UInt8](repeating: 0, count: 16384)
                let count = input.read(&buffer, maxLength: buffer.count)
                if count > 0 {
                    data.append(buffer, count: count)
                    continue
                }
                if count == 0 { return data }
                return nil
            }
            
            if input.streamStatus == .atEnd || input.streamStatus == .closed {
                return data
            }
            
            Thread.sleep(forTimeInterval: 0.05)
        }
        
        return data.isEmpty ? nil : data
    }
    
    private func writeAll(_ data: Data, to output: OutputStream, timeoutSeconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return false }
            var totalWritten = 0
            
            while totalWritten < data.count {
                if output.streamStatus == .error || output.streamStatus == .closed {
                    return false
                }
                
                if output.hasSpaceAvailable {
                    let written = output.write(baseAddress.advanced(by: totalWritten), maxLength: data.count - totalWritten)
                    if written <= 0 {
                        return false
                    }
                    totalWritten += written
                } else {
                    if Date() > deadline {
                        return false
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            return true
        }
    }
    
    private func finishOperation(_ id: UUID) {
        DispatchQueue.main.async {
            self.operations.removeAll { $0.id == id }
        }
    }
    
    private func failOperation(_ id: UUID, message: String) {
        DispatchQueue.main.async {
            if let index = self.operations.firstIndex(where: { $0.id == id }) {
                self.operations[index].state = .error(message)
                self.operations[index].errorMessage = message
            }
        }
    }
    
    private func saveSuccessfulConnection(_ server: FTPServer) {
        let entry = FTPRecentConnection(server: server)
        DispatchQueue.main.async {
            var updated = self.recentConnections.filter {
                !($0.host == entry.host &&
                  $0.port == entry.port &&
                  $0.username == entry.username &&
                  $0.encryptionMode == entry.encryptionMode &&
                  $0.logonType == entry.logonType)
            }
            if let existing = self.recentConnections.first(where: {
                $0.host == entry.host &&
                $0.port == entry.port &&
                $0.username == entry.username &&
                $0.encryptionMode == entry.encryptionMode &&
                $0.logonType == entry.logonType
            }), server.connectionName.isEmpty {
                updated.insert(
                    FTPRecentConnection(
                        id: existing.id,
                        name: existing.name,
                        host: entry.host,
                        port: entry.port,
                        username: entry.username,
                        password: entry.password,
                        encryptionMode: entry.encryptionMode,
                        logonType: entry.logonType,
                        options: entry.options,
                        lastUsedAt: Date()
                    ),
                    at: 0
                )
            } else {
                updated.insert(entry, at: 0)
            }
            if updated.count > Self.recentConnectionsLimit {
                updated = Array(updated.prefix(Self.recentConnectionsLimit))
            }
            self.recentConnections = updated
            self.persistRecentConnections()
        }
    }
    
    private func redactSensitiveText(in text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("FTP 명령 전송: PASS ") {
            return "FTP 명령 전송: PASS ********"
        }
        if trimmed.hasPrefix("PASS ") {
            return "PASS ********"
        }
        return text
    }
    
    private func loadRecentConnections() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentConnectionsKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([FTPRecentConnection].self, from: data)
            recentConnections = decoded.sorted { $0.lastUsedAt > $1.lastUsedAt }
        } catch {
            print("최근 접속 이력 로드 실패: \(error)")
        }
    }
    
    private func persistRecentConnections() {
        do {
            let data = try JSONEncoder().encode(recentConnections)
            UserDefaults.standard.set(data, forKey: Self.recentConnectionsKey)
        } catch {
            print("최근 접속 이력 저장 실패: \(error)")
        }
    }
}
