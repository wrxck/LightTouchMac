// The headless mode's control socket (HeadlessConfig.control): input, frames and the guest agent for a device that
// no app shows, driven by tools/headless/ltdev or any client of the wire below.
//
// One request per connection: the client writes it, shuts down its write side and reads the reply until the helper
// closes. A request starting with "!" is a helper command:
//
//     !status                      "ready=R agent=A sleeping=S exited=E width=W height=H serial=N"
//     !touch SLOT PHASE X Y        X, Y 0...1 of the portrait screen; PHASE 0 down, 1 move, 2 up
//     !tap X Y                     a down and an up 80 ms apart
//     !drag X0 Y0 X1 Y1 [SECONDS]  down, 30 moves over SECONDS (0.4), up
//     !button N | !buttondown N | !buttonup N
//                                  N as LinkCommand.button (0 home, 1 lock); !button holds 150 ms
//     !key CODE DOWN               a Mac virtual key code, DOWN 0 or 1
//     !paste TEXT                  the guest pasteboard
//     !hwkbd 0|1 | !netlan 0|1 | !netrestrict 0|1
//     !frame                       "W H\n" then W * H * 4 bytes of BGRA, the newest published frame
//     !png PATH                    the newest frame as a PNG at PATH: "ok W H"
//     !halt                        "halting", then the halt the app's stop runs
//
// Any other request is the guest agent's wire ("ID OP ARGS\n<base64 body>", contrib/agent in qemu-ios), answered
// with the agent's reply ("ID STATUS\n<base64 body>"), or a line starting "!" when it failed. The wire is the one
// ltqemu (the loader used before this mode worked) served, so its clients keep working.
import DeviceRuntime
import Foundation
import IOSurface
import os

final class HeadlessControl: @unchecked Sendable {
    private let host: DeviceHost
    private let front: @Sendable () -> IOSurface?
    private let listener: Int32
    /// Concurrent: an agent request may wait up to its deadline, and input must not queue behind it.
    private let queue = DispatchQueue(label: "LightTouch.control", attributes: .concurrent)
    /// The agent's deadline for one request, in seconds.
    static let agentDeadline = 120.0

    /// Binds `path` (replacing a stale socket there); nil when it cannot.
    init?(path: String, host: DeviceHost, front: @escaping @Sendable () -> IOSurface?) {
        self.host = host
        self.front = front
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            helperLog("control: socket path too long: \(path)")
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes + [0]) }
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listener >= 0, bound == 0, listen(listener, 8) == 0 else {
            helperLog("control: cannot listen on \(path): \(String(cString: strerror(errno)))")
            if listener >= 0 { close(listener) }
            return nil
        }
        helperLog("control at \(path)")
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    helperLog("control: accept: \(String(cString: strerror(errno)))")
                    return
                }
                // A client that never shuts down its write side must not hold a thread forever.
                var timeout = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var one: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                queue.async { [self] in
                    let request = Self.readAll(connection)
                    Self.writeAll(connection, reply(to: request))
                    close(connection)
                    if request.starts(with: Data("!halt".utf8)) { host.halt(reason: "control") }
                }
            }
        }
    }

    // MARK: - Requests

    func reply(to request: Data) -> Data {
        guard request.first == UInt8(ascii: "!") else { return agent(request) }
        let text = String(decoding: request.dropFirst(), as: UTF8.self)
        let command = String(text.prefix { $0 != " " && $0 != "\n" })
        let rest = text.dropFirst(command.count).drop { $0 == " " }
        let words = rest.split(separator: " ").map(String.init)
        let numbers = words.compactMap(Double.init)
        func need(_ count: Int) -> Bool { numbers.count >= count && numbers.prefix(count).allSatisfy(\.isFinite) }
        let ok = Data("ok\n".utf8)
        let usage = Data("! bad arguments for \(command)\n".utf8)
        switch command {
        case "status":
            let s = host.status.snapshot()
            return Data(
                ("ready=\(s.uiReady ? 1 : 0) agent=\(s.agentStatus) sleeping=\(s.displaySleeping ? 1 : 0) "
                    + "exited=\(host.hasExited ? 1 : 0) width=\(s.width) height=\(s.height) serial=\(s.frameSerial)\n")
                    .utf8
            )
        case "touch":
            guard need(4) else { return usage }
            host.perform(.touch(slot: Int(numbers[0]), phase: Int(numbers[1]), x: numbers[2], y: numbers[3]))
            return ok
        case "tap":
            guard need(2) else { return usage }
            host.perform(.touch(slot: 0, phase: 0, x: numbers[0], y: numbers[1]))
            usleep(80_000)
            host.perform(.touch(slot: 0, phase: 2, x: numbers[0], y: numbers[1]))
            return ok
        case "drag":
            guard need(4) else { return usage }
            let seconds = numbers.count > 4 && numbers[4].isFinite ? min(max(numbers[4], 0.05), 30) : 0.4
            let (x0, y0, x1, y1) = (numbers[0], numbers[1], numbers[2], numbers[3])
            host.perform(.touch(slot: 0, phase: 0, x: x0, y: y0))
            usleep(100_000)
            for i in 1...30 {
                let f = Double(i) / 30
                host.perform(.touch(slot: 0, phase: 1, x: x0 + (x1 - x0) * f, y: y0 + (y1 - y0) * f))
                usleep(UInt32(seconds / 30 * 1e6))
            }
            usleep(100_000)
            host.perform(.touch(slot: 0, phase: 2, x: x1, y: y1))
            return ok
        case "button", "buttondown", "buttonup":
            guard need(1) else { return usage }
            let button = Int(numbers[0])
            if command != "buttonup" { host.perform(.button(button, down: true)) }
            if command == "button" { usleep(150_000) }
            if command != "buttondown" { host.perform(.button(button, down: false)) }
            return ok
        case "key":
            guard need(2) else { return usage }
            host.perform(.key(macKeyCode: Int(numbers[0]), down: numbers[1] != 0))
            return ok
        case "paste":
            host.perform(.paste(String(rest)))
            return ok
        case "hwkbd":
            guard need(1) else { return usage }
            let attached = self.request(.hardwareKeyboard(numbers[0] != 0)) == .ok(true)
            return Data("\(attached ? 1 : 0)\n".utf8)
        case "netlan":
            guard need(1) else { return usage }
            host.perform(.netLocalNetwork(numbers[0] != 0))
            return ok
        case "netrestrict":
            guard need(1) else { return usage }
            host.perform(.netRestrict(numbers[0] != 0))
            return ok
        case "frame":
            guard let surface = front() else { return Data("0 0\n".utf8) }
            return Data("\(surface.width) \(surface.height)\n".utf8) + FrameTools.packedBGRA(surface)
        case "png":
            guard !rest.isEmpty else { return usage }
            guard let surface = front() else { return Data("! no frame yet\n".utf8) }
            guard FrameTools.writePNG(surface, to: URL(fileURLWithPath: String(rest))) else {
                return Data("! cannot write \(rest)\n".utf8)
            }
            return Data("ok \(surface.width) \(surface.height)\n".utf8)
        case "halt":
            return Data("halting\n".utf8)
        default:
            return Data("! unknown command \(command)\n".utf8)
        }
    }

    private func agent(_ request: Data) -> Data {
        let wire = String(decoding: request, as: UTF8.self)
        switch self.request(.agent(request: wire, deadline: Self.agentDeadline), timeout: Self.agentDeadline + 10) {
        case .agent(let reply?): return Data(reply.utf8)
        case .agent(nil): return Data("! timed out\n".utf8)
        case .failure(let message): return Data("! \(message)\n".utf8)
        case nil: return Data("! no reply\n".utf8)
        default: return Data("! unexpected reply\n".utf8)
        }
    }

    /// One DeviceHost request, waited for.
    private func request(_ request: LinkRequest, timeout: Double = 10) -> LinkReply? {
        let answer = OSAllocatedUnfairLock<LinkReply?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        host.handle(request) { reply in
            answer.withLock { $0 = reply }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return answer.withLock { $0 }
    }

    // MARK: - Socket

    static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return }
                offset += n
            }
        }
    }
}
