import Foundation
import Citadel
import NIOSSH
import NIOCore
import CryptoKit

actor SSHService {
    private var client: SSHClient?
    private var stdinWriter: TTYStdinWriter?
    private var sessionTask: Task<Void, Never>?
    private let allocator = ByteBufferAllocator()

    private var _onDataReceived: (([UInt8]) -> Void)?
    private var _onDisconnected: (() -> Void)?

    func setCallbacks(
        onDataReceived: @escaping @Sendable ([UInt8]) -> Void,
        onDisconnected: @escaping @Sendable () -> Void
    ) {
        _onDataReceived = onDataReceived
        _onDisconnected = onDisconnected
    }

    func connect(
        host: String,
        port: Int,
        username: String,
        privateKey: Curve25519.Signing.PrivateKey,
        cols: Int,
        rows: Int,
        expectedHostKey: String
    ) async throws {
        let sshKey = try NIOSSHPublicKey(openSSHPublicKey: expectedHostKey)
        let hostKeyValidator: SSHHostKeyValidator = .trustedKeys([sshKey])

        let client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .ed25519(username: username, privateKey: privateKey),
            hostKeyValidator: hostKeyValidator,
            reconnect: .never
        )
        self.client = client

        try Task.checkCancellation()

        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )

        // Bridge the writer out of the withPTY closure via AsyncStream
        let (writerStream, writerContinuation) = AsyncStream<TTYStdinWriter>.makeStream()
        let onData = _onDataReceived
        let onDisconnect = _onDisconnected

        sessionTask = Task.detached { [weak self] in
            do {
                try await client.withPTY(ptyRequest) { inbound, outbound in
                    writerContinuation.yield(outbound)
                    writerContinuation.finish()

                    for try await output in inbound {
                        let bytes: [UInt8]
                        switch output {
                        case .stdout(let buf): bytes = Array(buf.readableBytesView)
                        case .stderr(let buf): bytes = Array(buf.readableBytesView)
                        }
                        onData?(bytes)
                    }
                }
            } catch {
                writerContinuation.finish()
            }
            await self?.clearWriter()
            onDisconnect?()
        }

        // Wait for the PTY writer to become available
        for await writer in writerStream {
            self.stdinWriter = writer
            break
        }

        guard stdinWriter != nil else {
            throw SSHServiceError.ptyFailed
        }
    }

    func write(_ data: ArraySlice<UInt8>) async {
        guard let writer = stdinWriter else { return }
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        do {
            try await writer.write(buffer)
        } catch {
            _onDisconnected?()
        }
    }

    func resize(cols: Int, rows: Int) async {
        guard let writer = stdinWriter else { return }
        try? await writer.changeSize(
            cols: cols, rows: rows,
            pixelWidth: 0, pixelHeight: 0
        )
    }

    func disconnect() async {
        sessionTask?.cancel()
        sessionTask = nil
        stdinWriter = nil
        let client = self.client
        self.client = nil
        try? await client?.close()
    }

    private func clearWriter() {
        stdinWriter = nil
    }

    enum SSHServiceError: LocalizedError {
        case ptyFailed

        var errorDescription: String? {
            switch self {
            case .ptyFailed: "Failed to open PTY session"
            }
        }
    }
}
