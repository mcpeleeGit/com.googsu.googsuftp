//
//  ContentView.swift
//  googsuftp
//
//  Created by dongha lee on 8/23/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var ftpManager = FTPManager()
    @State private var selectedTab = 0
    @State private var selectedFileItem: FTPItem?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 상단 상태바
                statusBar
                
                // 탭 뷰
                TabView(selection: $selectedTab) {
                    // 연결 탭
                    ConnectionView(ftpManager: ftpManager)
                        .tabItem {
                            Image(systemName: "link")
                            Text("연결")
                        }
                        .tag(0)
                    
                    // 파일 브라우저 탭
                    FileBrowserView(ftpManager: ftpManager)
                        .tabItem {
                            Image(systemName: "folder")
                            Text("파일")
                        }
                        .tag(1)
                        .disabled(ftpManager.connectionState != .connected)
                    
                    // 파일 전송 탭
                    FileTransferView(ftpManager: ftpManager)
                        .tabItem {
                            Image(systemName: "arrow.up.arrow.down")
                            Text("전송")
                        }
                        .tag(2)
                        .disabled(ftpManager.connectionState != .connected)
                }
                .onAppear {
                    // 연결 탭은 항상 활성화
                }
            }
            .navigationTitle("GoogsuFTP")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: refreshConnection) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(ftpManager.connectionState != .connected)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
    
    private var statusBar: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: 8, height: 8)
                
                Text(connectionStatusText)
                    .font(.caption)
                    .foregroundColor(connectionStatusColor)
            }
            
            Spacer()
            
            if ftpManager.connectionState == .connected {
                Text("현재 경로: \(ftpManager.currentDirectory)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            if !ftpManager.operations.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption)
                    Text("\(ftpManager.operations.count)개 작업")
                        .font(.caption)
                }
                .foregroundColor(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var connectionStatusColor: Color {
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
    
    private var connectionStatusText: String {
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
    
    private func refreshConnection() {
        if ftpManager.connectionState == .connected {
            ftpManager.listDirectory()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
