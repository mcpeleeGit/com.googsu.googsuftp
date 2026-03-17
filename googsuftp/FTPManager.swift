import Foundation
import Network
import Combine

class FTPManager: ObservableObject {
    @Published var connectionState: FTPConnectionState = .disconnected
    @Published var statusDetail: String = ""
    @Published var attemptPlan: [String] = []
    @Published var currentAttemptIndex: Int? = nil
    @Published var lastAttemptError: String? = nil
    @Published var isAttemptRunning: Bool = false
    @Published var currentDirectory: String = "/"
    @Published var items: [FTPItem] = []
    @Published var operations: [FTPOperation] = []
    
    private var connection: NWConnection?
    private var dataConnection: NWConnection?
    private var currentServer: FTPServer?
    private var cancellables = Set<AnyCancellable>()
    
    private var controlReceiveBuffer = Data()
    private let controlReceiveQueue = DispatchQueue(label: "FTPManager.controlReceiveQueue")
    private let controlCommandQueue = DispatchQueue(label: "FTPManager.controlCommandQueue")
    private let attemptQueue = DispatchQueue(label: "FTPManager.attemptQueue")
    private var isListingInProgress = false
    
    private func setStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusDetail = text
        }
        print(text)
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
    
    // FTP 서버에 연결
    func connect(to server: FTPServer) {
        connectionState = .connecting
        currentServer = server
        setStatus("FTP 연결 시작: \(server.host):\(server.port)")
        
        // 먼저 호스트 연결 가능성 테스트
        testHostConnectivity(host: server.host, port: server.port) { [weak self] isReachable in
            if isReachable {
                self?.establishFTPConnection(to: server)
            } else {
                DispatchQueue.main.async {
                    self?.connectionState = .error("서버에 연결할 수 없습니다. 호스트와 포트를 확인하세요.")
                }
            }
        }
    }
    
    // 호스트 연결 가능성 테스트
    private func testHostConnectivity(host: String, port: Int, completion: @escaping (Bool) -> Void) {
        setStatus("호스트 연결 가능성 테스트: \(host):\(port)")
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )
        
        let testConnection = NWConnection(to: endpoint, using: .tcp)
        
        testConnection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.setStatus("호스트 연결 테스트 성공")
                testConnection.cancel()
                completion(true)
            case .failed(let error):
                self.setStatus("호스트 연결 테스트 실패: \(error.localizedDescription)")
                testConnection.cancel()
                completion(false)
            case .cancelled:
                completion(false)
            default:
                break
            }
        }
        
        // 10초 타임아웃 설정
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            testConnection.cancel()
            completion(false)
        }
        
        testConnection.start(queue: .global())
    }
    
    // 실제 FTP 연결 설정
    private func establishFTPConnection(to server: FTPServer) {
        setStatus("FTP 연결 설정 시작...")
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(server.port))
        )
        
        connection = NWConnection(to: endpoint, using: .tcp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .preparing:
                    self?.statusDetail = "FTP 연결 준비 중..."
                    break
                case .setup:
                    self?.statusDetail = "FTP 연결 설정 중..."
                    break
                case .ready:
                    self?.statusDetail = "FTP 연결 성공, 서버 환영 메시지 수신 중..."
                    self?.receiveServerGreetingThenAuthenticate(server: server)
                case .failed(let error):
                    self?.setStatus("FTP 연결 실패: \(error.localizedDescription)")
                    self?.connectionState = .error("연결 실패: \(error.localizedDescription)")
                case .cancelled:
                    self?.setStatus("FTP 연결 취소됨")
                    self?.connectionState = .disconnected
                case .waiting(let error):
                    self?.setStatus("FTP 연결 대기 중: \(error.localizedDescription)")
                    // 대기 상태에서도 계속 시도
                    break
                @unknown default:
                    self?.setStatus("FTP 연결 알 수 없는 상태: \(state)")
                    break
                }
            }
        }
        
        setStatus("FTP 연결 시작...")
        connection?.start(queue: .global())
    }
    
    private func receiveServerGreetingThenAuthenticate(server: FTPServer) {
        receiveControlResponse { [weak self] response in
            self?.setStatus("서버 환영 메시지: \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
            
            // 대부분 220. 일부 서버는 120(잠시 기다려) 후 220을 주기도 함.
            if response.hasPrefix("120") {
                self?.receiveServerGreetingThenAuthenticate(server: server)
                return
            }
            
            if response.hasPrefix("220") || response.contains("220") {
                self?.authenticate(server: server)
            } else {
                DispatchQueue.main.async {
                    self?.connectionState = .error("서버 응답이 예상과 다릅니다: \(response)")
                }
            }
        }
    }
    
    // FTP 인증
    private func authenticate(server: FTPServer) {
        let user = server.username.isEmpty ? "anonymous" : server.username
        let pass = server.username.isEmpty && server.password.isEmpty ? "anonymous@" : server.password
        setStatus("FTP 인증 시작: 사용자명 \(user)")
        
        sendCommand("USER \(user)") { [weak self] response in
            self?.setStatus("FTP USER 응답: \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
            
            if response.hasPrefix("331") {
                self?.setStatus("사용자명 OK, 비밀번호 인증 시작...")
                self?.sendCommand("PASS \(pass)") { response in
                    self?.setStatus("FTP PASS 응답: \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
                    
                    if response.hasPrefix("230") {
                        self?.setStatus("FTP 인증 완료")
                        DispatchQueue.main.async {
                            self?.connectionState = .connected
                            self?.listDirectory()
                        }
                    } else {
                        self?.setStatus("FTP 비밀번호 인증 실패: \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
                        DispatchQueue.main.async {
                            self?.connectionState = .error("비밀번호 인증 실패: \(response)")
                        }
                    }
                }
            } else if response.hasPrefix("230") {
                // 일부 서버는 PASS 없이도 바로 로그인 완료
                self?.setStatus("FTP 인증 완료(USER만으로 로그인)")
                DispatchQueue.main.async {
                    self?.connectionState = .connected
                    self?.listDirectory()
                }
            } else {
                self?.setStatus("FTP 사용자명 인증 실패: \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
                DispatchQueue.main.async {
                    self?.connectionState = .error("사용자명 인증 실패: \(response)")
                }
            }
        }
    }
    
    // FTP 명령 전송
    private func sendCommand(_ command: String, completion: @escaping (String) -> Void) {
        // FTP 컨트롤 채널은 "명령 1개 ↔ 응답 1개" 순차 처리가 필수.
        // 동시에 여러 send/receive를 수행하면 응답이 섞여서 전체 플로우가 망가질 수 있으므로 직렬화한다.
        controlCommandQueue.async { [weak self] in
            guard let self else { return }
            guard let connection = self.connection else {
                self.setStatus("FTP 연결이 없습니다")
                completion("연결 없음")
                return
            }
            
            self.setStatus("FTP 명령 전송: \(command)")
            let data = (command + "\r\n").data(using: .utf8)!
            
            let sema = DispatchSemaphore(value: 0)
            var responseText: String = ""
            
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    self.setStatus("명령 전송 오류: \(error)")
                    responseText = "명령 전송 오류: \(error.localizedDescription)"
                    sema.signal()
                    return
                }
                
                self.setStatus("명령 전송 완료, 응답 대기 중...")
                self.receiveControlResponse { resp in
                    responseText = resp
                    sema.signal()
                }
            })
            
            if sema.wait(timeout: .now() + 20) == .timedOut {
                responseText = "응답 타임아웃"
                self.setStatus("응답 타임아웃: \(command)")
            }
            
            completion(responseText)
        }
    }
    
    private func sendCommandAndWait(_ command: String, timeoutSeconds: TimeInterval = 20) -> String? {
        let sema = DispatchSemaphore(value: 0)
        var out: String?
        sendCommand(command) { resp in
            out = resp
            sema.signal()
        }
        if sema.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            return nil
        }
        return out
    }
    
    private func receiveControlResponse(completion: @escaping (String) -> Void) {
        guard let connection else {
            completion("연결 없음")
            return
        }
        
        // FTP 응답은 TCP 패킷 분할/멀티라인 가능. 최소한 "완전한 FTP 응답"이 될 때까지 누적.
        func parseIfComplete(from buffer: Data) -> (response: String, remaining: Data)? {
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n") else { return nil }
            
            // 멀티라인 응답 지원: "xyz-"로 시작하면 "xyz "로 끝나는 라인까지 포함
            let lines = text.components(separatedBy: "\r\n")
            guard let first = lines.first, first.count >= 4 else { return nil }
            let code = String(first.prefix(3))
            let fourth = first[first.index(first.startIndex, offsetBy: 3)]
            
            if fourth == "-" {
                // 종료 라인 찾기: "xyz "로 시작하는 라인
                var endLineIndex: Int?
                for (i, line) in lines.enumerated() where i > 0 {
                    if line.hasPrefix(code + " ") {
                        endLineIndex = i
                        break
                    }
                }
                guard let endLineIndex else { return nil }
                let responseText = lines[0...endLineIndex].joined(separator: "\r\n") + "\r\n"
                let consumedBytes = responseText.data(using: .utf8)?.count ?? 0
                if consumedBytes <= buffer.count {
                    return (responseText, buffer.dropFirst(consumedBytes))
                }
                return nil
            } else {
                // 단일 라인 응답: 첫 \r\n 까지만
                guard let range = text.range(of: "\r\n") else { return nil }
                let responseText = String(text[..<range.upperBound])
                let consumedBytes = responseText.data(using: .utf8)?.count ?? 0
                if consumedBytes <= buffer.count {
                    return (responseText, buffer.dropFirst(consumedBytes))
                }
                return nil
            }
        }
        
        controlReceiveQueue.async {
            func pump() {
                if let parsed = parseIfComplete(from: self.controlReceiveBuffer) {
                    self.controlReceiveBuffer = parsed.remaining
                    completion(parsed.response)
                    return
                }
                
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                    if let error {
                        self.setStatus("응답 수신 오류: \(error)")
                        completion("응답 수신 오류: \(error.localizedDescription)")
                        return
                    }
                    if let data {
                        self.controlReceiveBuffer.append(data)
                    }
                    pump()
                }
            }
            
            pump()
        }
    }
    
    // 디렉토리 목록 가져오기
    func listDirectory() {
        listDirectoryWithFallback()
    }

    /// 실패 시 여러 전략을 순서대로 재시도하며 목록을 조회
    func listDirectoryWithFallback() {
        attemptQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isListingInProgress else { return }
            self.isListingInProgress = true
            DispatchQueue.main.async { self.isAttemptRunning = true }
            defer { self.isListingInProgress = false }
            defer { DispatchQueue.main.async { self.isAttemptRunning = false } }
            
            self.setStatus("디렉토리 목록 가져오기 시작(재시도 플랜)")

            // 플랜을 먼저 화면에 노출(네트워크/서버가 중간에 멈춰도 “무슨 시도를 할지”는 보이게)
            let provisionalPlan = [
                "EPSV + MLSD",
                "EPSV + LIST",
                "PASV + MLSD",
                "PASV + LIST",
                "PASV + NLST"
            ]
            self.setAttemptPlan(provisionalPlan)
            
            // ASCII 모드로 목록 파싱 안정화
            if let typeResponse = self.sendCommandAndWait("TYPE A", timeoutSeconds: 10) {
                self.setStatus("TYPE A 응답: \(typeResponse.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            
            // 현재 디렉토리 갱신(PWD)
            if let response = self.sendCommandAndWait("PWD", timeoutSeconds: 10) {
                self.setStatus("PWD 응답: \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
                if response.hasPrefix("257"),
                   let startIndex = response.firstIndex(of: "\""),
                   let endIndex = response.lastIndex(of: "\"") {
                    let path = String(response[startIndex...endIndex]).replacingOccurrences(of: "\"", with: "")
                    self.setStatus("현재 디렉토리: \(path)")
                    DispatchQueue.main.async { self.currentDirectory = path }
                }
            }
            
            let supportsMLSD = self.checkFeatureContains("MLSD")
            
            var attempts: [(label: String, mode: String, command: String)] = []
            if supportsMLSD { attempts.append(("EPSV + MLSD", "EPSV", "MLSD")) }
            attempts.append(("EPSV + LIST", "EPSV", "LIST"))
            if supportsMLSD { attempts.append(("PASV + MLSD", "PASV", "MLSD")) }
            attempts.append(("PASV + LIST", "PASV", "LIST"))
            attempts.append(("PASV + NLST", "PASV", "NLST"))
            
            self.setAttemptPlan(attempts.map(\.label))
            
            for (idx, attempt) in attempts.enumerated() {
                self.setAttemptProgress(index: idx, error: nil)
                self.setStatus("재시도 \(idx + 1)/\(attempts.count): \(attempt.label)")
                
                if self.runListAttempt(mode: attempt.mode, command: attempt.command) {
                    self.setStatus("목록 조회 성공: \(attempt.label)")
                    return
                }
            }
            
            let err = self.lastAttemptError ?? "디렉터리 목록 조회 실패(모든 재시도 실패)"
            DispatchQueue.main.async { self.connectionState = .error(err) }
        }
    }
    
    func retryLastListing() {
        listDirectoryWithFallback()
    }

    private func checkFeatureContains(_ token: String) -> Bool {
        // FEAT 미지원 서버 대비(실제 시도에서 실패하면 폴백)
        guard let response = sendCommandAndWait("FEAT", timeoutSeconds: 8) else { return true }
        let upper = response.uppercased()
        if upper.hasPrefix("500") || upper.hasPrefix("502") { return true }
        return upper.contains(token.uppercased())
    }
    
    private func runListAttempt(mode: String, command: String) -> Bool {
        // 1) EPSV/PASV 진입 + 데이터 연결
        guard let modeResponse = sendCommandAndWait(mode, timeoutSeconds: 10) else {
            let err = "\(mode) 응답 타임아웃"
            lastAttemptError = err
            setAttemptProgress(index: currentAttemptIndex ?? 0, error: err)
            return false
        }
        
        let trimmedMode = modeResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == "EPSV" {
            guard trimmedMode.hasPrefix("229") else {
                let err = "EPSV 실패: \(trimmedMode)"
                lastAttemptError = err
                setAttemptProgress(index: currentAttemptIndex ?? 0, error: err)
                return false
            }
            let sema = DispatchSemaphore(value: 0)
            setupExtendedPassiveConnection(response: modeResponse) { sema.signal() }
            if sema.wait(timeout: .now() + 10) == .timedOut {
                let err = "EPSV 데이터 연결 타임아웃"
                lastAttemptError = err
                setAttemptProgress(index: currentAttemptIndex ?? 0, error: err)
                return false
            }
        } else {
            guard trimmedMode.hasPrefix("227") else {
                let err = "PASV 실패: \(trimmedMode)"
                lastAttemptError = err
                setAttemptProgress(index: currentAttemptIndex ?? 0, error: err)
                return false
            }
            let sema = DispatchSemaphore(value: 0)
            setupPassiveConnection(response: modeResponse) { sema.signal() }
            if sema.wait(timeout: .now() + 10) == .timedOut {
                let err = "PASV 데이터 연결 타임아웃"
                lastAttemptError = err
                setAttemptProgress(index: currentAttemptIndex ?? 0, error: err)
                return false
            }
        }
        
        // 2) 데이터 명령 수행
        let cmdSema = DispatchSemaphore(value: 0)
        var success = false
        performDataCommand(command) { [weak self] listing in
            guard let self else { return }
            let parsed: [FTPItem]
            switch command {
            case "NLST":
                parsed = self.parseNameList(listing)
            case "MLSD":
                parsed = self.parseMLSD(listing)
            default:
                parsed = self.parseDirectoryListing(listing)
            }
            DispatchQueue.main.async { self.items = parsed }
            success = !listing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !parsed.isEmpty
            cmdSema.signal()
        } onError: { [weak self] err in
            self?.lastAttemptError = err
            self?.setAttemptProgress(index: self?.currentAttemptIndex ?? 0, error: err)
            cmdSema.signal()
        }
        
        _ = cmdSema.wait(timeout: .now() + 20)
        return success
    }
    
    private func performDataCommand(_ command: String, onDataComplete: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        setStatus("\(command) 전송, 서버 150/125 응답 대기...")
        
        sendCommand(command) { [weak self] firstResponse in
            guard let self else { return }
            let first = firstResponse.trimmingCharacters(in: .whitespacesAndNewlines)
            self.setStatus("\(command) 컨트롤 응답: \(first)")
            
            if first.hasPrefix("150") || first.hasPrefix("125") {
                self.setStatus("데이터 전송 시작(150/125), 데이터 수신 중...")
                self.receiveDirectoryListingFully { [weak self] listing in
                    guard let self else { return }
                    self.setStatus("데이터 수신 완료, 서버 226 응답 대기...")
                    self.receiveControlResponse { finalResponse in
                        let fin = finalResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.setStatus("\(command) 완료 응답: \(fin)")
                        if fin.hasPrefix("226") || fin.hasPrefix("250") {
                            onDataComplete(listing)
                        } else {
                            onError("\(command) 완료 응답 오류: \(fin)")
                        }
                    }
                }
            } else if first.hasPrefix("226") || first.hasPrefix("250") {
                self.receiveDirectoryListingFully { listing in
                    onDataComplete(listing)
                }
            } else {
                onError("\(command) 실패: \(first)")
            }
        }
    }
    
    private func parseNameList(_ listing: String) -> [FTPItem] {
        let names = listing
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.map { FTPItem(name: $0, isDirectory: false, size: 0, modifiedDate: nil, permissions: nil) }
    }
    
    private func parseMLSD(_ listing: String) -> [FTPItem] {
        var result: [FTPItem] = []
        let lines = listing.components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard let spaceIndex = line.lastIndex(of: " ") else { continue }
            let facts = String(line[..<spaceIndex])
            let name = String(line[line.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
            let factsLower = facts.lowercased()
            let isDir = factsLower.contains("type=dir") || factsLower.contains("type=cdir") || factsLower.contains("type=pdir")
            var size: Int64 = 0
            for fact in facts.split(separator: ";") {
                let parts = fact.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == "size" {
                    size = Int64(parts[1]) ?? 0
                }
            }
            if !name.isEmpty {
                result.append(FTPItem(name: name, isDirectory: isDir, size: size, modifiedDate: nil, permissions: nil))
            }
        }
        return result
    }
    
    private func performDirectoryListOverDataChannel() {
        // 기존 호출부 호환용(현재는 재시도 플랜이 실제로 사용)
        performDataCommand("LIST") { [weak self] listing in
            guard let self else { return }
            let items = self.parseDirectoryListing(listing)
            DispatchQueue.main.async { self.items = items }
        } onError: { [weak self] err in
            DispatchQueue.main.async { self?.connectionState = .error(err) }
        }
    }
    
    // EPSV 연결 설정 (229 Entering Extended Passive Mode (|||port|))
    private func setupExtendedPassiveConnection(response: String, completion: @escaping () -> Void) {
        setStatus("EPSV 응답 파싱: \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
        guard let startIndex = response.firstIndex(of: "("),
              let endIndex = response.firstIndex(of: ")") else {
            setStatus("EPSV 응답 파싱 실패: 괄호를 찾을 수 없음")
            return
        }
        
        let info = String(response[startIndex...endIndex])
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        
        // 형태: |||port|
        // 구분자는 첫 문자. 보통 '|'
        guard let delimiter = info.first else {
            setStatus("EPSV 응답 파싱 실패: 구분자를 찾을 수 없음")
            return
        }
        let parts = info.split(separator: delimiter, omittingEmptySubsequences: false)
        // 예: ["", "", "", "49200", ""]
        guard parts.count >= 5, let port = Int(parts[3].trimmingCharacters(in: .whitespaces)) else {
            setStatus("EPSV 응답 파싱 실패: 포트를 추출할 수 없음 (\(info))")
            return
        }
        
        let host = currentServer?.host ?? "localhost"
        setStatus("EPSV 데이터 연결: \(host):\(port)")
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )
        
        dataConnection = NWConnection(to: endpoint, using: .tcp)
        dataConnection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setStatus("데이터 연결(EPSV) 성공")
                completion()
            case .failed(let error):
                self?.setStatus("데이터 연결(EPSV) 실패: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.connectionState = .error("데이터 연결 실패: \(error.localizedDescription)")
                }
            case .cancelled:
                self?.setStatus("데이터 연결(EPSV) 취소됨")
            default:
                break
            }
        }
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            if self.dataConnection?.state != .ready {
                self.setStatus("데이터 연결(EPSV) 타임아웃")
                self.dataConnection?.cancel()
                DispatchQueue.main.async {
                    self.connectionState = .error("데이터 연결 타임아웃")
                }
            }
        }
        
        dataConnection?.start(queue: .global())
    }
    
    // 패시브 연결 설정
    private func setupPassiveConnection(response: String, completion: @escaping () -> Void) {
        setStatus("패시브(PASV) 응답 파싱: \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
        
        // 227 응답에서 IP와 포트 추출 (더 정확한 파싱)
        guard let startIndex = response.firstIndex(of: "("),
              let endIndex = response.firstIndex(of: ")") else {
            print("패시브 모드 응답 파싱 실패: 괄호를 찾을 수 없음")
            return
        }
        
        let passiveInfo = String(response[startIndex...endIndex])
        setStatus("패시브 정보: \(passiveInfo)")
        
        // 괄호 제거하고 쉼표로 분리
        let cleanInfo = passiveInfo.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        let components = cleanInfo.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        
        guard components.count >= 6 else {
            print("패시브 모드 응답 파싱 실패: 충분한 정보가 없음")
            return
        }
        
        let parsedHost = components[0...3].map(String.init).joined(separator: ".")
        let port = components[4] * 256 + components[5]
        
        // 많은 FTP 서버가 NAT 뒤에 있어 227에 "내부 IP"를 내려주기도 함.
        // 이 경우 클라이언트는 "컨트롤 연결의 호스트"로 데이터 연결을 해야 정상 동작.
        let host: String
        if parsedHost.hasPrefix("10.") || parsedHost.hasPrefix("192.168.") || parsedHost.hasPrefix("172.16.") || parsedHost.hasPrefix("172.17.") || parsedHost.hasPrefix("172.18.") || parsedHost.hasPrefix("172.19.") || parsedHost.hasPrefix("172.2") || parsedHost.hasPrefix("172.30.") || parsedHost.hasPrefix("172.31.") {
            host = currentServer?.host ?? parsedHost
            setStatus("PASV가 사설 IP(\(parsedHost))를 반환 → 데이터 연결은 \(host)로 시도")
        } else {
            host = parsedHost
        }
        
        setStatus("PASV 데이터 연결: \(host):\(port)")
        
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )
        
        dataConnection = NWConnection(to: endpoint, using: .tcp)
        
        dataConnection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setStatus("데이터 연결(PASV) 성공")
                completion()
            case .failed(let error):
                self?.setStatus("데이터 연결(PASV) 실패: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.connectionState = .error("데이터 연결 실패: \(error.localizedDescription)")
                }
            case .cancelled:
                self?.setStatus("데이터 연결(PASV) 취소됨")
            default:
                break
            }
        }
        
        // 10초 타임아웃 설정
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if self.dataConnection?.state != .ready {
                self.setStatus("데이터 연결(PASV) 타임아웃")
                self.dataConnection?.cancel()
                DispatchQueue.main.async {
                    self.connectionState = .error("데이터 연결 타임아웃")
                }
            }
        }
        
        dataConnection?.start(queue: .global())
    }
    
    // 액티브 모드 시도
    private func tryActiveMode() {
        setStatus("액티브 모드 시도")
        // 액티브 모드 구현 (PORT 명령 사용)
        // 현재는 간단한 구현
        DispatchQueue.main.async {
            self.connectionState = .error("패시브 모드 실패, 액티브 모드 지원 필요")
        }
    }
    
    // 디렉토리 목록 수신
    private func receiveDirectoryListingFully(completion: @escaping (String) -> Void) {
        guard let dataConnection else {
            completion("")
            return
        }
        
        var buffer = Data()
        
        func pump() {
            dataConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let error {
                    self?.setStatus("데이터 수신 오류: \(error.localizedDescription)")
                    completion(String(data: buffer, encoding: .utf8) ?? "")
                    return
                }
                if let data { buffer.append(data) }
                if isComplete {
                    self?.dataConnection?.cancel()
                    completion(String(data: buffer, encoding: .utf8) ?? "")
                    return
                }
                pump()
            }
        }
        
        pump()
    }
    
    // 디렉토리 목록 파싱
    private func parseDirectoryListing(_ listing: String) -> [FTPItem] {
        var items: [FTPItem] = []
        let lines = listing.components(separatedBy: .newlines)
        
        for line in lines {
            if line.isEmpty { continue }
            
            // 간단한 파싱 (실제로는 더 정교한 파싱이 필요)
            let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if components.count >= 9 {
                let permissions = components[0]
                let size = Int64(components[4]) ?? 0
                let name = components[8...].joined(separator: " ")
                let isDirectory = permissions.hasPrefix("d")
                
                let item = FTPItem(
                    name: name,
                    isDirectory: isDirectory,
                    size: size,
                    permissions: permissions
                )
                items.append(item)
            }
        }
        
        return items
    }
    
    // 디렉토리 변경
    func changeDirectory(_ path: String) {
        sendCommand("CWD \(path)") { [weak self] response in
            if response.hasPrefix("250") {
                DispatchQueue.main.async {
                    self?.currentDirectory = path
                    self?.listDirectory()
                }
            }
        }
    }
    
    // 상위 디렉토리로 이동
    func goToParentDirectory() {
        sendCommand("CDUP") { [weak self] response in
            if response.hasPrefix("250") {
                self?.listDirectory()
            }
        }
    }
    
    // 파일 업로드
    func uploadFile(localPath: String, remotePath: String) {
        let operation = FTPOperation(type: .upload, localPath: localPath, remotePath: remotePath)
        operations.append(operation)
        
        // 실제 업로드 구현은 여기에 추가
        // STOR 명령과 데이터 전송
    }
    
    // 파일 다운로드
    func downloadFile(remotePath: String, localPath: String) {
        let operation = FTPOperation(type: .download, localPath: localPath, remotePath: remotePath)
        operations.append(operation)
        
        // 실제 다운로드 구현은 여기에 추가
        // RETR 명령과 데이터 수신
    }
    
    // 파일/디렉토리 삭제
    func deleteItem(_ path: String, isDirectory: Bool) {
        let operation = FTPOperation(type: .delete, localPath: nil, remotePath: path)
        operations.append(operation)
        
        let command = isDirectory ? "RMD \(path)" : "DELE \(path)"
        sendCommand(command) { [weak self] response in
            if response.hasPrefix("250") || response.hasPrefix("200") {
                self?.listDirectory()
            }
        }
    }
    
    // 새 디렉토리 생성
    func createDirectory(_ name: String) {
        let operation = FTPOperation(type: .createDirectory, localPath: nil, remotePath: name)
        operations.append(operation)
        
        sendCommand("MKD \(name)") { [weak self] response in
            if response.hasPrefix("257") {
                self?.listDirectory()
            }
        }
    }
    
    // 연결 해제
    func disconnect() {
        sendCommand("QUIT") { [weak self] _ in
            self?.connection?.cancel()
            self?.dataConnection?.cancel()
            DispatchQueue.main.async {
                self?.connectionState = .disconnected
                self?.items = []
                self?.currentDirectory = "/"
            }
        }
    }
}
