// ltm-boot: writes a LightTouchDevice headless config (HelperLaunch.Mode.headless) for a prepared base, with the
// PreparedDeviceBoot and BootRecipe calls the sessions harness's session-driver makes, so a device booted from it
// runs as the app runs it. tools/headless/ltdev calls it; see tools/headless/README.md.
//
//     ltm-boot --helper PATH --base DIR --run DIR --files DIR --usb SOCKET --control SOCKET --out FILE
//              [--board n81] [--boot-args ARGS]
import Foundation
import HostRuntime

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("ltm-boot: \(message)\n".utf8))
    exit(code)
}

let usage = """
    usage: ltm-boot --helper PATH --base DIR --run DIR --files DIR --usb SOCKET --control SOCKET --out FILE
                    [--board BOARD] [--boot-args ARGS]
    """
let options: [String: String] = {
    var options: [String: String] = [:]
    var rest = Array(CommandLine.arguments.dropFirst())
    while !rest.isEmpty {
        let name = rest.removeFirst()
        guard name.hasPrefix("--"), !rest.isEmpty else { fail(usage, code: 64) }
        options[String(name.dropFirst(2))] = rest.removeFirst()
    }
    return options
}()
func option(_ name: String) -> String {
    guard let value = options[name] else { fail("missing --\(name)\n\(usage)", code: 64) }
    return value
}

let boardName = options["board"] ?? Board.n81.rawValue
guard let board = Board(rawValue: boardName) else { fail("unknown board \(boardName)", code: 64) }
let helper = URL(fileURLWithPath: option("helper"))
let base = URL(fileURLWithPath: option("base"))
let run = URL(fileURLWithPath: option("run"))
let out = URL(fileURLWithPath: option("out"))

do {
    guard let hardware = try DeviceInfo.list(helper: helper).first(where: { $0.board == board.rawValue }) else {
        fail("\(helper.path) runs no \(board.rawValue)")
    }
    let fm = FileManager.default
    try fm.createDirectory(at: run, withIntermediateDirectories: true)
    // As session-driver: a writable NOR beside the overlay only when the base has one.
    let nor =
        fm.fileExists(atPath: base.appendingPathComponent("nor.bin").path) ? run.appendingPathComponent("nor.bin") : nil
    let prepared = try PreparedDeviceBoot.prepare(
        board: board,
        base: base,
        overlay: run.appendingPathComponent("overlay"),
        writableNOR: nor,
        storageKey: nil,
        bootrom: BootRecipe.bootrom(board.bootrom, filesRoot: option("files"))
    )
    let boot = try prepared.configuration(
        hardware: hardware,
        bootArgs: options["boot-args"] ?? "amfi_allow_any_signature=1 cs_enforcement_disable=1",
        usbAddress: option("usb"),
        wifi: true,
        guestPackage: nil,
        serial: "file:" + run.appendingPathComponent("serial.log").path,
        audio: ["-audio", "driver=none"],
        netdev: nil
    )
    // The helper's HeadlessConfig: no scripted actions, and no time limit for a device the control socket drives.
    struct Headless: Encodable {
        var boot: BootConfig
        var actions: [String] = []
        var dumpDir: String
        var litFraction = 0.01
        var maxSeconds = 1e9
        var control: String
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(Headless(boot: boot, dumpDir: run.path, control: option("control"))).write(to: out)
    print(out.path)
} catch {
    fail("\(error)")
}
