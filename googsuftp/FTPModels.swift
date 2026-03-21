import Foundation
import Network

enum FTPEncryptionMode: String, CaseIterable, Identifiable, Codable {
    case plain
    case explicitTLS
    case implicitTLS
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .plain:
            return "평문 FTP"
        case .explicitTLS:
            return "TLS를 통한 명시적 FTP"
        case .implicitTLS:
            return "TLS를 통한 암시적 FTP"
        }
    }
}

enum FTPLogonType: String, CaseIterable, Identifiable, Codable {
    case anonymous
    case normal
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .anonymous:
            return "익명"
        case .normal:
            return "일반"
        }
    }
}

enum FTPDataConnectionMode: String, CaseIterable, Identifiable, Codable {
    case automatic
    case epsvOnly
    case pasvOnly
    case preferPasv
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .automatic:
            return "자동 (EPSV 후 PASV)"
        case .epsvOnly:
            return "EPSV만"
        case .pasvOnly:
            return "PASV만"
        case .preferPasv:
            return "PASV 우선"
        }
    }
}

enum FTPListingMode: String, CaseIterable, Identifiable, Codable {
    case automatic
    case listOnly
    case mlsdOnly
    case nlstOnly
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .automatic:
            return "자동 (MLSD/LIST/NLST)"
        case .listOnly:
            return "LIST만"
        case .mlsdOnly:
            return "MLSD만"
        case .nlstOnly:
            return "NLST만"
        }
    }
}

enum FTPPassiveHostMode: String, CaseIterable, Identifiable, Codable {
    case automatic
    case useControlHost
    case useServerAddress
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .automatic:
            return "자동"
        case .useControlHost:
            return "항상 접속 호스트 사용"
        case .useServerAddress:
            return "PASV 응답 주소 강제 사용"
        }
    }
}

struct FTPConnectionOptions: Codable, Equatable {
    var dataConnectionMode: FTPDataConnectionMode = .automatic
    var listingMode: FTPListingMode = .automatic
    var passiveHostMode: FTPPassiveHostMode = .automatic
    var initialPath: String = ""
    var timeoutSeconds: Int = 10
    
    static let `default` = FTPConnectionOptions()
}

// FTP 서버 연결 정보
struct FTPServer {
    let host: String
    let port: Int
    let username: String
    let password: String
    let encryptionMode: FTPEncryptionMode
    let logonType: FTPLogonType
    let connectionName: String
    let options: FTPConnectionOptions
    
    init(
        host: String,
        port: Int = 21,
        username: String = "",
        password: String = "",
        encryptionMode: FTPEncryptionMode = .plain,
        logonType: FTPLogonType = .normal,
        connectionName: String = "",
        options: FTPConnectionOptions = .default
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.encryptionMode = encryptionMode
        self.logonType = logonType
        self.connectionName = connectionName
        self.options = options
    }
}

// FTP 파일/디렉토리 정보
struct FTPItem: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?
    let permissions: String?
    
    init(name: String, isDirectory: Bool = false, size: Int64 = 0, modifiedDate: Date? = nil, permissions: String? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
        self.permissions = permissions
    }
}

// FTP 연결 상태
enum FTPConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

// FTP 작업 상태
enum FTPOperationState: Equatable {
    case idle
    case uploading
    case downloading
    case deleting
    case creating
    case error(String)
}

// FTP 작업 정보
struct FTPOperation {
    let id = UUID()
    let type: FTPOperationType
    let localPath: String?
    let remotePath: String
    var progress: Double = 0.0
    var state: FTPOperationState = .idle
    var errorMessage: String?
}

enum FTPOperationType {
    case upload
    case download
    case delete
    case createDirectory
    case rename
}

struct FTPDirectorySnapshot {
    let path: String
    let items: [FTPItem]
    let fetchedAt: Date
    let source: Source
    
    enum Source {
        case cache
        case remote
    }
}

enum FTPDiagnosticLevel {
    case info
    case warning
    case error
}

struct FTPDiagnostic: Identifiable {
    let id = UUID()
    let level: FTPDiagnosticLevel
    let title: String
    let message: String
    let suggestions: [String]
}

struct FTPRecentConnection: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let username: String
    let password: String
    let encryptionMode: FTPEncryptionMode
    let logonType: FTPLogonType
    let options: FTPConnectionOptions
    let lastUsedAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        username: String,
        password: String,
        encryptionMode: FTPEncryptionMode,
        logonType: FTPLogonType,
        options: FTPConnectionOptions,
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.encryptionMode = encryptionMode
        self.logonType = logonType
        self.options = options
        self.lastUsedAt = lastUsedAt
    }
    
    init(server: FTPServer, lastUsedAt: Date = Date()) {
        self.init(
            name: server.connectionName.isEmpty ? FTPRecentConnection.makeDefaultName(host: server.host, port: server.port, username: server.username, logonType: server.logonType) : server.connectionName,
            host: server.host,
            port: server.port,
            username: server.username,
            password: server.password,
            encryptionMode: server.encryptionMode,
            logonType: server.logonType,
            options: server.options,
            lastUsedAt: lastUsedAt
        )
    }
    
    var displayName: String {
        name
    }
    
    func asServer() -> FTPServer {
        FTPServer(
            host: host,
            port: port,
            username: username,
            password: password,
            encryptionMode: encryptionMode,
            logonType: logonType,
            connectionName: name,
            options: options
        )
    }
    
    static func makeDefaultName(host: String, port: Int, username: String, logonType: FTPLogonType) -> String {
        if username.isEmpty || logonType == .anonymous {
            return "\(host):\(port)"
        }
        return "\(host):\(port) (\(username))"
    }
}

struct FTPSavedConnection: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let username: String
    let password: String
    let encryptionMode: FTPEncryptionMode
    let logonType: FTPLogonType
    let options: FTPConnectionOptions
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        username: String,
        password: String,
        encryptionMode: FTPEncryptionMode,
        logonType: FTPLogonType,
        options: FTPConnectionOptions,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.encryptionMode = encryptionMode
        self.logonType = logonType
        self.options = options
        self.updatedAt = updatedAt
    }

    init(id: UUID = UUID(), server: FTPServer, updatedAt: Date = Date()) {
        self.init(
            id: id,
            name: server.connectionName.isEmpty ? FTPRecentConnection.makeDefaultName(host: server.host, port: server.port, username: server.username, logonType: server.logonType) : server.connectionName,
            host: server.host,
            port: server.port,
            username: server.username,
            password: server.password,
            encryptionMode: server.encryptionMode,
            logonType: server.logonType,
            options: server.options,
            updatedAt: updatedAt
        )
    }

    var displayName: String {
        name
    }

    func asServer() -> FTPServer {
        FTPServer(
            host: host,
            port: port,
            username: username,
            password: password,
            encryptionMode: encryptionMode,
            logonType: logonType,
            connectionName: name,
            options: options
        )
    }
}
