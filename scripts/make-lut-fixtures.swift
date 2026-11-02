import Foundation
import CryptoKit

// Synthetic, harmless LUTs for a large-library UI test. Output belongs under .build/ only.
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("LUTs")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let cube = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
for index in 0..<240 {
    let data = Data(("# synthetic UI fixture \(index)\n" + cube).utf8)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let name = String(format: "合成 LUT %03d", index) + (index % 20 == 0 ? String(repeating: "长名称", count: 12) : "")
    try data.write(to: directory.appendingPathComponent(hash + ".cube"))
    try JSONSerialization.data(withJSONObject: ["id": hash, "name": name]).write(to: directory.appendingPathComponent(hash + ".json"))
}
print("Created 240 synthetic LUTs for isolated UI validation")
