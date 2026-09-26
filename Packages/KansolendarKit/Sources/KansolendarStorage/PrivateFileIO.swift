import Darwin
import Foundation

internal enum PrivateFileError: Error, Equatable, Sendable {
    case invalidSource
    case destinationExists
    case filesystemFailure(Int32)
}

internal enum PrivateFileReader {
    static func read(_ path: String, maximumBytes: Int) throws -> Data {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw PrivateFileError.invalidSource
        }
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw PrivateFileError.filesystemFailure(errno) }
        defer { close(descriptor) }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes + 1))
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw PrivateFileError.filesystemFailure(errno) }
            if count == 0 { return data }
            guard data.count + count <= maximumBytes else { throw PrivateFileError.invalidSource }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

internal enum PrivateFileWriter {
    static func write(_ data: Data, to path: String) throws {
        let descriptor = path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw PrivateFileError.destinationExists }
            throw PrivateFileError.filesystemFailure(errno)
        }
        var completed = false
        defer {
            close(descriptor)
            if !completed { unlink(path) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw PrivateFileError.filesystemFailure(errno) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw PrivateFileError.filesystemFailure(errno) }
        completed = true
    }
}

internal enum PrivateFileCopier {
    static func copyNewFile(from sourcePath: String, to destinationPath: String) throws {
        let source = sourcePath.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard source >= 0 else { throw PrivateFileError.filesystemFailure(errno) }
        defer { close(source) }

        let destination = destinationPath.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        }
        guard destination >= 0 else {
            if errno == EEXIST { throw PrivateFileError.destinationExists }
            throw PrivateFileError.filesystemFailure(errno)
        }
        var completed = false
        defer {
            close(destination)
            if !completed { unlink(destinationPath) }
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(source, bytes.baseAddress, bytes.count)
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount >= 0 else { throw PrivateFileError.filesystemFailure(errno) }
            if readCount == 0 { break }
            var offset = 0
            while offset < readCount {
                let writeCount = buffer.withUnsafeBytes { bytes in
                    Darwin.write(destination, bytes.baseAddress?.advanced(by: offset), readCount - offset)
                }
                if writeCount < 0, errno == EINTR { continue }
                guard writeCount > 0 else { throw PrivateFileError.filesystemFailure(errno) }
                offset += writeCount
            }
        }
        guard fsync(destination) == 0 else { throw PrivateFileError.filesystemFailure(errno) }
        completed = true
    }
}
