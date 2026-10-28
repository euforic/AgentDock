import Darwin
import Foundation

enum BoundedFileReader {
    static func data(at url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else {
            throw BoundedFileReaderError.invalidLimit
        }

        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw BoundedFileReaderError.unsafeFile(url.path)
        }
        defer { Darwin.close(descriptor) }

        var status = Darwin.stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= off_t(maximumBytes)
        else {
            throw BoundedFileReaderError.unsafeFile(url.path)
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw BoundedFileReaderError.readFailed(url.path)
            }
            guard count > 0 else { break }
            guard data.count <= maximumBytes - count else {
                throw BoundedFileReaderError.tooLarge(url.path, maximumBytes)
            }
            data.append(buffer, count: count)
        }
        return data
    }

    static func string(
        at url: URL,
        maximumBytes: Int,
        encoding: String.Encoding = .utf8
    ) throws -> String {
        let data = try data(at: url, maximumBytes: maximumBytes)
        guard let value = String(data: data, encoding: encoding) else {
            throw BoundedFileReaderError.invalidEncoding(url.path)
        }
        return value
    }
}

enum BoundedFileReaderError: Error, LocalizedError, Equatable {
    case invalidLimit
    case unsafeFile(String)
    case tooLarge(String, Int)
    case readFailed(String)
    case invalidEncoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            "The local file read limit is invalid."
        case let .unsafeFile(path):
            "The local file is not a safe regular file: \(path)"
        case let .tooLarge(path, maximumBytes):
            "The local file exceeds the \(maximumBytes)-byte safety limit: \(path)"
        case let .readFailed(path):
            "The local file could not be read safely: \(path)"
        case let .invalidEncoding(path):
            "The local file is not valid text: \(path)"
        }
    }
}

enum LocalControlFileLimit {
    static let profiles = 8 * 1_024 * 1_024
    static let journal = 4 * 1_024 * 1_024
    static let ownershipMarker = 64 * 1_024
    static let providerConfiguration = 1 * 1_024 * 1_024
    static let shortcutConfiguration = 256 * 1_024
    static let providerCredentialState = 4 * 1_024 * 1_024
    static let propertyList = 1 * 1_024 * 1_024
    static let customIcon = 10 * 1_024 * 1_024
    static let chatIndex = 8 * 1_024 * 1_024
}
