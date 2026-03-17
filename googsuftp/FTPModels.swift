import Foundation
import Network

// FTP 서버 연결 정보
struct FTPServer {
    let host: String
    let port: Int
    let username: String
    let password: String
    let useSSL: Bool
    
    init(host: String, port: Int = 21, username: String = "", password: String = "", useSSL: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useSSL = useSSL
    }
}

// FTP 파일/디렉토리 정보
struct FTPItem {
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
