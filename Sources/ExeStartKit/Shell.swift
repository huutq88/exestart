import Foundation

public enum ExeStartError: LocalizedError {
    case commandFailed(String, Int32, String)
    case noRuntime
    case runtimeNotFound(String)
    case bottleExists(String)
    case bottleNotFound(String)
    case invalidName(String)
    case fileNotFound(String)
    case rosettaMissing
    case download(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(cmd, code, output):
            let tail = output.split(separator: "\n").suffix(15).joined(separator: "\n")
            return "Lệnh \(cmd) thoát với mã \(code).\n\(tail)"
        case .noRuntime:
            return "Chưa cài Wine runtime. Chạy: exestart runtime install"
        case let .runtimeNotFound(id):
            return "Không tìm thấy runtime '\(id)'. Xem danh sách: exestart runtime list"
        case let .bottleExists(name):
            return "Bottle '\(name)' đã tồn tại."
        case let .bottleNotFound(name):
            return "Không có bottle '\(name)'. Xem danh sách: exestart bottle list"
        case let .invalidName(name):
            return "Tên '\(name)' không hợp lệ. Chỉ dùng chữ, số, dấu cách, '-', '_' và '.'."
        case let .fileNotFound(path):
            return "Không tìm thấy file: \(path)"
        case .rosettaMissing:
            return "Wine cần Rosetta 2. Cài bằng: softwareupdate --install-rosetta --agree-to-license"
        case let .download(msg):
            return "Tải thất bại: \(msg)"
        }
    }
}

enum Shell {
    /// Chạy lệnh, chờ xong, trả về stdout+stderr. Ném lỗi nếu mã thoát khác 0.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String],
                    environment: [String: String]? = nil,
                    currentDirectory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ExeStartError.commandFailed(
                ([executable] + arguments).joined(separator: " "), process.terminationStatus, output)
        }
        return output
    }

    static var rosettaInstalled: Bool {
        // Máy Intel không cần Rosetta.
        #if arch(arm64)
        return FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        #else
        return true
        #endif
    }
}

/// Tên bottle/runtime: an toàn làm tên thư mục.
func validateName(_ name: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
    guard !name.isEmpty, name.count <= 64, !name.hasPrefix("."),
          name.unicodeScalars.allSatisfy(allowed.contains) else {
        throw ExeStartError.invalidName(name)
    }
}
