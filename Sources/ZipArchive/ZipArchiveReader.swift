//
// This source file is part of the swift-zip-archive project
// Copyright (c) 2025-2026 the swift-zip-archive project authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

import SystemPackage

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// ZipArchiveReader configuration
public struct ZipArchiveReaderConfiguration {
    /// Additional supported compression methods
    public var compressionMethods: [any ZipCompression]

    /// Initialize ZipArchiveReaderConfiguration
    /// - Parameter compressionMethods: Additional supported compression methods
    public init(compressionMethods: [any ZipCompression] = []) {
        self.compressionMethods = compressionMethods
    }
}

/// Zip archive reader type
public final class ZipArchiveReader<Storage: ZipReadableStorage> {
    let storage: Storage
    let endOfCentralDirectoryRecord: Zip.EndOfCentralDirectory
    let compressionMethods: ZipCompressionMethodsMap
    var parsingDirectory: Bool

    init(_ file: Storage, configuration: ZipArchiveReaderConfiguration) throws {
        self.storage = file
        self.endOfCentralDirectoryRecord = try Self.readEndOfCentralDirectory(file: file)

        let compressionKeyValuePairs = configuration.compressionMethods.map { (key: $0.method, value: $0) }
        self.compressionMethods = [
            Zip.FileCompressionMethod.noCompression: NoZipCompression(),
            Zip.FileCompressionMethod.deflate: ZlibDeflateCompression(),
        ].merging(compressionKeyValuePairs) { first, second in second }

        self.parsingDirectory = false
    }

    /// Initialize ZipArchiveReader to read from a memory buffer
    ///
    /// - Parameters:
    ///   - buffer: Buffer containing zip archive
    ///   - configuration: ZipArchiveReader configuration
    /// - Throws:
    convenience public init<Bytes: RangeReplaceableCollection>(
        buffer: Bytes,
        configuration: ZipArchiveReaderConfiguration = .init()
    ) throws where Bytes.Element == UInt8, Bytes.Index == Int, Storage == ZipMemoryStorage<Bytes> {
        try self.init(ZipMemoryStorage(buffer), configuration: configuration)
    }

    /// Read directory from zip archive into an array
    public func readDirectory() throws -> [Zip.FileHeader] {
        try storage.seek(numericCast(endOfCentralDirectoryRecord.offsetOfCentralDirectory))
        let bytes = try storage.read(numericCast(endOfCentralDirectoryRecord.centralDirectorySize))
        let memoryStorage = ZipMemoryStorage(bytes)
        return try readDirectory(memoryStorage)
    }

    /// Parse directory from zip file and run process on each entry
    ///
    /// Use this function if you don't want to load the whole of the zip file directory
    /// into memory
    ///
    /// WARNING: You cannot call `readFile` while parsing the directory
    public func parseDirectory(_ process: (Zip.FileHeader) throws -> Void) throws {
        self.parsingDirectory = true
        defer {
            self.parsingDirectory = false
        }
        try storage.seek(numericCast(endOfCentralDirectoryRecord.offsetOfCentralDirectory))
        for _ in 0..<endOfCentralDirectoryRecord.diskEntries {
            let fileHeader = try self.readFileHeader(from: storage)
            try process(fileHeader)
        }
    }

    /// Read file from zip file
    ///
    /// - Parameters:
    ///   - file: File header, from zip directory
    ///   - password: Password used to decrypt file
    /// - Returns: Buffer containing file
    public func readFile(_ file: Zip.FileHeader, password: String? = nil) throws -> [UInt8] {
        let preparedEntry = try prepareEntryForReading(file)
        guard let compressor = self.compressionMethods[preparedEntry.localHeader.compressionMethod] else {
            throw ZipArchiveReaderError.unsupportedCompressionMethod
        }
        var encryptionKeys: [UInt8]?
        var fileSize = preparedEntry.compressedSize
        // if encrypted read encryption header
        if preparedEntry.localHeader.flags.contains(.encrypted) {
            guard fileSize >= 12 else {
                throw ZipArchiveReaderError.invalidFileHeader
            }
            guard password != nil else {
                throw ZipArchiveReaderError.encryptedFilesRequirePassword
            }
            encryptionKeys = try self.storage.readBytes(length: 12)
            fileSize -= 12
        } else {
            encryptionKeys = nil
        }

        // Read bytes and uncompress
        guard
            let compressedByteCount = Int(exactly: fileSize),
            let uncompressedByteCount = Int(
                exactly: preparedEntry.uncompressedSize
            )
        else {
            throw ZipArchiveReaderError.entryTooLargeForBufferedRead
        }
        var fileBytes = try self.storage.readBytes(
            length: compressedByteCount
        )

        // if we have a password and encryption keys
        if let password, var encryptionKeys {
            var cryptKey = CryptKey(password: password)
            cryptKey.decryptBytes(&encryptionKeys)
            cryptKey.decryptBytes(&fileBytes)
        } else if encryptionKeys != nil {
            throw ZipArchiveReaderError.encryptedFilesRequirePassword
        }
        let uncompressedBytes = try compressor.inflate(
            from: fileBytes,
            uncompressedSize: uncompressedByteCount
        )
        guard uncompressedBytes.count == uncompressedByteCount else {
            throw ZipArchiveReaderError.uncompressedSizeMismatch
        }
        // Verify CRC32
        let crc = crc32(0, bytes: uncompressedBytes)
        guard crc == preparedEntry.expectedChecksum else {
            throw ZipArchiveReaderError.crc32FileValidationFailed
        }
        return uncompressedBytes
    }

    /// Reads a file incrementally without buffering the complete entry.
    ///
    /// The configured compression method must conform to
    /// ``ZipStreamingCompression``. The callback is invoked synchronously and
    /// receives chunks no larger than `bufferSize`.
    ///
    /// - Parameters:
    ///   - file: File header returned by ``readDirectory()``.
    ///   - password: Password used to decrypt the entry, when required.
    ///   - bufferSize: Maximum compressed or decompressed chunk size.
    ///   - onChunk: Callback that consumes one decompressed chunk.
    /// - Throws: ``ZipArchiveReaderError`` when the entry is malformed, its
    ///   compression method does not support streaming, or validation fails.
    public func readFile(
        _ file: Zip.FileHeader,
        password: String? = nil,
        bufferSize: Int,
        onChunk: (_ bytes: [UInt8]) throws -> Void
    ) throws {
        guard bufferSize > 0,
            UInt64(bufferSize) <= UInt64(UInt32.max)
        else {
            throw ZipArchiveReaderError.invalidBufferSize
        }
        let preparedEntry = try prepareEntryForReading(file)
        guard
            let compression = self.compressionMethods[
                preparedEntry.localHeader.compressionMethod
            ] as? any ZipStreamingCompression
        else {
            throw ZipArchiveReaderError.streamingUnsupportedCompressionMethod
        }

        var compressedSize = preparedEntry.compressedSize

        var cryptKey: CryptKey?
        if preparedEntry.localHeader.flags.contains(.encrypted) {
            guard compressedSize >= 12 else {
                throw ZipArchiveReaderError.invalidFileHeader
            }
            guard let password else {
                throw ZipArchiveReaderError.encryptedFilesRequirePassword
            }
            var key = CryptKey(password: password)
            var encryptionHeader = try self.storage.readBytes(length: 12)
            key.decryptBytes(&encryptionHeader)
            cryptKey = key
            compressedSize -= 12
        }

        var remainingCompressedSize = compressedSize
        var decompressedSize: Int64 = 0
        var checksum: UInt32 = 0
        try compression.inflate(
            bufferSize: bufferSize,
            read: { maximumByteCount in
                guard maximumByteCount > 0 else {
                    throw ZipArchiveReaderError.invalidBufferSize
                }
                guard remainingCompressedSize > 0 else {
                    return []
                }
                let requestedByteCount = min(maximumByteCount, bufferSize)
                let byteCount =
                    remainingCompressedSize < Int64(requestedByteCount)
                    ? Int(remainingCompressedSize)
                    : requestedByteCount
                var bytes = try self.storage.readBytes(length: byteCount)
                if var key = cryptKey {
                    key.decryptBytes(&bytes)
                    cryptKey = key
                }
                remainingCompressedSize -= Int64(byteCount)
                return bytes
            },
            write: { bytes in
                guard bytes.count <= bufferSize else {
                    throw ZipArchiveReaderError
                        .streamingChunkExceedsBufferSize
                }
                let (newSize, overflowed) =
                    decompressedSize
                    .addingReportingOverflow(Int64(bytes.count))
                guard
                    !overflowed,
                    newSize <= preparedEntry.uncompressedSize
                else {
                    throw ZipArchiveReaderError.uncompressedSizeMismatch
                }
                decompressedSize = newSize
                checksum = crc32(checksum, bytes: bytes)
                try onChunk(bytes)
            }
        )

        guard remainingCompressedSize == 0,
            decompressedSize == preparedEntry.uncompressedSize
        else {
            throw ZipArchiveReaderError.uncompressedSizeMismatch
        }
        guard checksum == preparedEntry.expectedChecksum else {
            throw ZipArchiveReaderError.crc32FileValidationFailed
        }
    }

    /// Reads and reconciles the local and central-directory metadata before
    /// either buffered or streaming decompression starts.
    private func prepareEntryForReading(
        _ file: Zip.FileHeader
    ) throws -> PreparedZipEntry {
        precondition(
            self.parsingDirectory == false,
            "Cannot read file while parsing the directory"
        )
        try self.storage.seek(numericCast(file.offsetOfLocalHeader))
        let localHeader = try readLocalFileHeader()
        guard localHeader.pathInArchive == file.pathInArchive,
            localHeader.filename == file.filename,
            localHeader.flags == file.flags,
            localHeader.compressionMethod == file.compressionMethod
        else {
            throw ZipArchiveReaderError.invalidFileHeader
        }
        if !file.flags.contains(.dataDescriptor) {
            guard localHeader.compressedSize == file.compressedSize,
                localHeader.uncompressedSize == file.uncompressedSize,
                localHeader.crc32 == file.crc32
            else {
                throw ZipArchiveReaderError.invalidFileHeader
            }
        }
        guard file.compressedSize >= 0, file.uncompressedSize >= 0 else {
            throw ZipArchiveReaderError.invalidFileHeader
        }

        return PreparedZipEntry(
            localHeader: localHeader,
            compressedSize: file.compressedSize,
            uncompressedSize: file.uncompressedSize,
            expectedChecksum: file.crc32
        )
    }

    /// Read directory from byffer
    func readDirectory(_ storage: some ZipReadableStorage) throws -> [Zip.FileHeader] {
        var directory: [Zip.FileHeader] = []
        for _ in 0..<endOfCentralDirectoryRecord.diskEntries {
            let fileHeader = try self.readFileHeader(from: storage)
            directory.append(fileHeader)
        }
        return directory
    }

    func readLocalFileHeader() throws -> Zip.LocalFileHeader {
        let (
            signature, versionNeeded, flags, compression, modTime, modDate, crc32, compressedSize, uncompressedSize, fileNameLength, extraFieldsLength
        ) =
            try storage.readIntegers(
                UInt32.self,
                UInt16.self,
                UInt16.self,
                UInt16.self,
                UInt16.self,
                UInt16.self,
                UInt32.self,
                UInt32.self,
                UInt32.self,
                UInt16.self,
                UInt16.self
            )
        guard signature == Zip.localFileHeaderSignature else { throw ZipArchiveReaderError.invalidFileHeader }
        let filename = try storage.readString(length: numericCast(fileNameLength))
        let extraFieldsBuffer = try storage.readBytes(length: numericCast(extraFieldsLength))
        let extraFields = try readExtraFields(extraFieldsBuffer)

        /// Extract ZIP64 extra field
        var uncompressedSize64: Int64 = numericCast(uncompressedSize)
        var compressedSize64: Int64 = numericCast(compressedSize)
        var fileModification = Date(msdosTime: modTime, msdosDate: modDate)
        for extraField in extraFields {
            switch extraField.header {
            case .zip64:
                var memoryBuffer = MemoryBuffer(extraField.data)
                if uncompressedSize == 0xffff_ffff {
                    uncompressedSize64 = try memoryBuffer.readInteger(as: Int64.self)
                }
                if compressedSize == 0xffff_ffff {
                    compressedSize64 = try memoryBuffer.readInteger(as: Int64.self)
                }

            case .extendedTimestamp:
                var memoryBuffer = MemoryBuffer(extraField.data)
                try memoryBuffer.seekOffset(1)
                let modifiedSince1970 = try memoryBuffer.readInteger(as: Int32.self)
                fileModification = Date(timeIntervalSince1970: Double(modifiedSince1970))

            default:
                break
            }
        }
        guard let compressionMethod = Zip.FileCompressionMethod(rawValue: compression) else {
            throw ZipArchiveReaderError.unsupportedCompressionMethod
        }
        return .init(
            versionNeeded: versionNeeded,
            flags: .init(rawValue: flags),
            compressionMethod: compressionMethod,
            fileModification: fileModification,
            crc32: crc32,
            compressedSize: compressedSize64,
            uncompressedSize: uncompressedSize64,
            pathInArchive: filename,
            filename: .init(filename),
            extraFields: extraFields
        )
    }

    func readFileHeader(from storage: some ZipReadableStorage) throws -> Zip.FileHeader {
        let (
            signature, versionMadeBy, versionNeeded, flags, compression, modTime, modDate, crc32, compressedSize, uncompressedSize, fileNameLength,
            extraFieldsLength, commentLength, diskStart, internalAttribute, externalAttribute, offsetOfLocalHeader
        ) =
            try storage.readIntegers(
                UInt32.self,
                UInt16.self,
                UInt16.self,
                UInt16.self,
                UInt16.self,
                UInt16.self,
                UInt16.self,
                UInt32.self,
                UInt32.self,
                UInt32.self,
                UInt16.self,
                UInt16.self,
                UInt16.self,
                UInt16.self,
                UInt16.self,
                UInt32.self,
                UInt32.self
            )
        guard signature == Zip.fileHeaderSignature else { throw ZipArchiveReaderError.invalidDirectory }

        let filename = try storage.readString(length: numericCast(fileNameLength))
        let extraFieldsBuffer = try storage.readBytes(length: numericCast(extraFieldsLength))
        let comment = try storage.readString(length: numericCast(commentLength))

        let extraFields = try readExtraFields(extraFieldsBuffer)

        /// Extract ZIP64 extra field
        var uncompressedSize64: Int64 = numericCast(uncompressedSize)
        var compressedSize64: Int64 = numericCast(compressedSize)
        var offsetOfLocalHeader64: Int64 = numericCast(offsetOfLocalHeader)
        var diskStart32: UInt32 = numericCast(diskStart)
        var fileModification = Date(msdosTime: modTime, msdosDate: modDate)
        for extraField in extraFields {
            switch extraField.header {
            case .zip64:
                var memoryBuffer = MemoryBuffer(extraField.data)
                if uncompressedSize == 0xffff_ffff {
                    uncompressedSize64 = try memoryBuffer.readInteger(as: Int64.self)
                }
                if compressedSize == 0xffff_ffff {
                    compressedSize64 = try memoryBuffer.readInteger(as: Int64.self)
                }
                if offsetOfLocalHeader == 0xffff_ffff {
                    offsetOfLocalHeader64 = try memoryBuffer.readInteger(as: Int64.self)
                }
                if diskStart == 0xffff {
                    diskStart32 = try memoryBuffer.readInteger(as: UInt32.self)
                }

            case .extendedTimestamp:
                var memoryBuffer = MemoryBuffer(extraField.data)
                try memoryBuffer.seekOffset(1)
                let modifiedSince1970 = try memoryBuffer.readInteger(as: Int32.self)
                fileModification = Date(timeIntervalSince1970: Double(modifiedSince1970))

            default:
                // ignore extra field
                break
            }
        }
        guard let compressionMethod = Zip.FileCompressionMethod(rawValue: compression) else {
            throw ZipArchiveReaderError.unsupportedCompressionMethod
        }
        return .init(
            versionMadeBy: .init(rawValue: versionMadeBy),
            versionNeeded: versionNeeded,
            flags: .init(rawValue: flags),
            compressionMethod: compressionMethod,
            fileModification: fileModification,
            crc32: crc32,
            compressedSize: compressedSize64,
            uncompressedSize: uncompressedSize64,
            pathInArchive: filename,
            filename: .init(filename),
            extraFields: extraFields,
            comment: comment,
            diskStart: diskStart32,
            internalAttribute: internalAttribute,
            externalAttributes: .init(rawValue: externalAttribute),
            offsetOfLocalHeader: offsetOfLocalHeader64
        )
    }

    func readExtraFields(_ buffer: [UInt8]) throws -> [Zip.ExtraField] {
        var extraFieldsBuffer = MemoryBuffer(buffer)
        var extraFields: [Zip.ExtraField] = []
        while extraFieldsBuffer.index < extraFieldsBuffer.length {
            let (header, size) = try extraFieldsBuffer.readIntegers(UInt16.self, UInt16.self)
            let data = try extraFieldsBuffer.read(numericCast(size))
            extraFields.append(.init(header: .init(rawValue: header), data: data))
        }
        return extraFields
    }

    static func readEndOfCentralDirectory(file: some ZipReadableStorage) throws -> Zip.EndOfCentralDirectory {
        _ = try searchForEndOfCentralDirectory(file: file)

        let zip64EndOfCentralLocator: Zip.Zip64EndOfCentralLocator?
        // verify we have space to read the zip64 end of central directory locator, before reading it
        if try file.seekOffset(0) > 20 {
            try file.seekOffset(-20)
            zip64EndOfCentralLocator = try Self.readZip64EndOfCentralLocator(file: file)
        } else {
            zip64EndOfCentralLocator = nil
        }

        let (
            signature, diskNumber, diskNumberCentralDirectoryStarts, diskEntries, totalEntries, centralDirectorySize, offsetOfCentralDirectory,
            commentLength
        ) = try file.readIntegers(
            UInt32.self,
            UInt16.self,
            UInt16.self,
            UInt16.self,
            UInt16.self,
            UInt32.self,
            UInt32.self,
            UInt16.self
        )

        guard signature == Zip.endOfCentralDirectorySignature else { throw ZipArchiveReaderError.internalError }

        let comment = try file.readString(length: numericCast(commentLength))

        // Zip64
        var diskNumber32: UInt32 = numericCast(diskNumber)
        var diskEntries64: Int64 = numericCast(diskEntries)
        var totalEntries64: Int64 = numericCast(totalEntries)
        var centralDirectorySize64: Int64 = numericCast(centralDirectorySize)
        var offsetOfCentralDirectory64: Int64 = numericCast(offsetOfCentralDirectory)
        var diskNumberCentralDirectoryStarts32: UInt32 = numericCast(diskNumberCentralDirectoryStarts)
        if let zip64EndOfCentralLocator {
            if diskNumberCentralDirectoryStarts == 0xffff {
                diskNumberCentralDirectoryStarts32 = zip64EndOfCentralLocator.diskNumberCentralDirectoryStarts
            }
            // jump to zip64 central directory
            //let offset = zip64EndOfCentralLocator.relativeOffsetEndOfCentralDirectory
            try file.seek(numericCast(zip64EndOfCentralLocator.relativeOffsetEndOfCentralDirectory))
            let zip64EndOfCentralDirectory = try Self.readZip64EndOfCentralDirectory(file: file)
            if diskNumber == 0xffff {
                diskNumber32 = zip64EndOfCentralDirectory.diskNumber
            }
            if diskEntries == 0xffff {
                diskEntries64 = zip64EndOfCentralDirectory.diskEntries
            }
            if totalEntries == 0xffff {
                totalEntries64 = zip64EndOfCentralDirectory.totalEntries
            }
            if centralDirectorySize == 0xffff_ffff {
                centralDirectorySize64 = zip64EndOfCentralDirectory.centralDirectorySize
            }
            if offsetOfCentralDirectory == 0xffff_ffff {
                offsetOfCentralDirectory64 = zip64EndOfCentralDirectory.offsetOfCentralDirectory
            }
            // do stuff
        }
        return .init(
            diskNumber: diskNumber32,
            diskNumberCentralDirectoryStarts: diskNumberCentralDirectoryStarts32,
            diskEntries: diskEntries64,
            totalEntries: totalEntries64,
            centralDirectorySize: centralDirectorySize64,
            offsetOfCentralDirectory: offsetOfCentralDirectory64,
            comment: comment
        )
    }

    static func readZip64EndOfCentralLocator(file: some ZipReadableStorage) throws -> Zip.Zip64EndOfCentralLocator? {
        let (signature, diskNumberCentralDirectoryStarts, relativeOffsetEndOfCentralDirectory, totalNumberOfDisks) = try file.readIntegers(
            UInt32.self,
            UInt32.self,
            Int64.self,
            UInt32.self
        )
        guard signature == Zip.zip64EndOfCentralLocatorSignature else { return nil }
        return .init(
            diskNumberCentralDirectoryStarts: diskNumberCentralDirectoryStarts,
            relativeOffsetEndOfCentralDirectory: relativeOffsetEndOfCentralDirectory,
            totalNumberOfDisks: totalNumberOfDisks
        )
    }

    static func readZip64EndOfCentralDirectory(file: some ZipReadableStorage) throws -> Zip.Zip64EndOfCentralDirectory {
        let (
            signature, _, versionNeeded, diskNumber, diskNumberCentralDirectoryStarts, diskEntries, totalEntries, centralDirectorySize,
            offsetOfCentralDirectory
        ) =
            try file.readIntegers(
                UInt32.self,
                UInt16.self,
                UInt16.self,
                UInt32.self,
                UInt32.self,
                Int64.self,
                Int64.self,
                Int64.self,
                Int64.self
            )
        guard signature == Zip.zip64EndOfCentralDirectorySignature else { throw ZipArchiveReaderError.invalidDirectory }
        return .init(
            versionNeeded: versionNeeded,
            diskNumber: diskNumber,
            diskNumberCentralDirectoryStarts: diskNumberCentralDirectoryStarts,
            diskEntries: diskEntries,
            totalEntries: totalEntries,
            centralDirectorySize: centralDirectorySize,
            offsetOfCentralDirectory: offsetOfCentralDirectory
        )
    }

    static func searchForEndOfCentralDirectory(file: some ZipReadableStorage) throws -> Int {
        let fileChunkLength: Int64 = 1024
        let fileSize = try file.seekEnd(0)

        var filePosition = fileSize - 18

        while filePosition > 0, filePosition + 0xffff > fileSize {
            let readSize = min(filePosition, fileChunkLength)
            filePosition -= readSize
            try file.seek(filePosition)
            let bytes = try file.read(numericCast(readSize))
            for index in (bytes.startIndex..<bytes.index(bytes.endIndex, offsetBy: -3)).reversed() {
                if bytes[index] == 0x50, bytes[index + 1] == 0x4b, bytes[index + 2] == 0x5, bytes[index + 3] == 0x6 {
                    let offset = try file.seekOffset(numericCast(index - bytes.startIndex) - readSize)
                    return numericCast(offset)
                }
            }
        }

        throw ZipArchiveReaderError.failedToFindCentralDirectory
    }
}

extension ZipArchiveReader where Storage == ZipFileStorage {
    /// Use ZipArchiveReader to load zip archive from disk and process it contents.
    ///
    /// Opens file, create ``ZipArchiveReader`` using file descriptor, run supplied closure with
    /// ``ZipArchiveReader`` and then close file.
    ///
    /// - Parameters:
    ///   - filename: Filename of zip archive
    ///   - configuration: ZipArchiveReader configuration
    ///   - process: Process to run with ZipArchiveReader
    /// - Returns: Value returned by process function
    public static func withFile<Value>(
        _ filename: String,
        configuration: ZipArchiveReaderConfiguration = .init(),
        process: (ZipArchiveReader) throws -> Value
    ) throws -> Value {
        let fileDescriptor = try FileDescriptor.open(
            .init(filename),
            .readOnly
        )
        return try fileDescriptor.closeAfter {
            let zipArchiveReader = try ZipArchiveReader(ZipFileStorage(fileDescriptor), configuration: configuration)
            return try process(zipArchiveReader)
        }
    }
}

private struct PreparedZipEntry {
    let localHeader: Zip.LocalFileHeader
    let compressedSize: Int64
    let uncompressedSize: Int64
    let expectedChecksum: UInt32
}

/// Errors received while reading zip archive
public struct ZipArchiveReaderError: Error, Equatable {
    internal enum Value {
        case invalidFileHeader
        case invalidDirectory
        case failedToFindCentralDirectory
        case internalError
        case compressionError
        case unsupportedCompressionMethod
        case failedToReadFromBuffer
        case crc32FileValidationFailed
        case encryptedFilesRequirePassword
        case invalidBufferSize
        case streamingUnsupportedCompressionMethod
        case streamingChunkExceedsBufferSize
        case entryTooLargeForBufferedRead
        case uncompressedSizeMismatch
        case unsafeExtractionPath
        case duplicateExtractionPath
        case symbolicLinkNotAllowed
        case invalidExtractionOptions
        case entryCountLimitExceeded
        case entryUncompressedSizeLimitExceeded
        case totalUncompressedSizeLimitExceeded
        case unsafeDestinationPath
        case conflictingExtractionPath
    }
    internal let value: Value

    /// Local file header was invalid
    public static var invalidFileHeader: Self { .init(value: .invalidFileHeader) }
    /// Directory entry was invalid
    public static var invalidDirectory: Self { .init(value: .invalidDirectory) }
    /// Failed to find the central directory
    public static var failedToFindCentralDirectory: Self { .init(value: .failedToFindCentralDirectory) }
    /// Internal error, should not be seen. If you receive this please add an issue
    /// to https://github.com/adam-fowler/swift-zip-archive
    public static var internalError: Self { .init(value: .internalError) }
    /// Received an error while trying to decompress data
    public static var compressionError: Self { .init(value: .compressionError) }
    /// Archive uses an unsupported compression method
    public static var unsupportedCompressionMethod: Self { .init(value: .unsupportedCompressionMethod) }
    /// CRC32 validation of file failed
    public static var crc32FileValidationFailed: Self { .init(value: .crc32FileValidationFailed) }
    /// File is encrypted and requires a password
    public static var encryptedFilesRequirePassword: Self { .init(value: .encryptedFilesRequirePassword) }
    /// Streaming reads require a positive buffer that zlib can represent.
    public static var invalidBufferSize: Self { .init(value: .invalidBufferSize) }
    /// The configured compression method does not support incremental reads.
    public static var streamingUnsupportedCompressionMethod: Self {
        .init(value: .streamingUnsupportedCompressionMethod)
    }
    /// A streaming compression callback produced a chunk larger than requested.
    public static var streamingChunkExceedsBufferSize: Self {
        .init(value: .streamingChunkExceedsBufferSize)
    }
    /// The entry cannot fit in memory on this platform; use streaming instead.
    public static var entryTooLargeForBufferedRead: Self {
        .init(value: .entryTooLargeForBufferedRead)
    }
    /// Decompressed bytes did not match the size declared by the archive.
    public static var uncompressedSizeMismatch: Self {
        .init(value: .uncompressedSizeMismatch)
    }
    /// An archive entry would escape or ambiguously address the destination.
    public static var unsafeExtractionPath: Self {
        .init(value: .unsafeExtractionPath)
    }
    /// Multiple archive entries resolve to the same destination path.
    public static var duplicateExtractionPath: Self {
        .init(value: .duplicateExtractionPath)
    }
    /// Extraction rejected a symbolic-link entry.
    public static var symbolicLinkNotAllowed: Self {
        .init(value: .symbolicLinkNotAllowed)
    }
    /// Extraction options contain an invalid buffer or negative limit.
    public static var invalidExtractionOptions: Self {
        .init(value: .invalidExtractionOptions)
    }
    /// The archive contains more entries than the configured limit.
    public static var entryCountLimitExceeded: Self {
        .init(value: .entryCountLimitExceeded)
    }
    /// An entry expands beyond the configured per-entry limit.
    public static var entryUncompressedSizeLimitExceeded: Self {
        .init(value: .entryUncompressedSizeLimitExceeded)
    }
    /// The archive expands beyond the configured aggregate limit.
    public static var totalUncompressedSizeLimitExceeded: Self {
        .init(value: .totalUncompressedSizeLimitExceeded)
    }
    /// A destination component is not a real directory beneath the root.
    public static var unsafeDestinationPath: Self {
        .init(value: .unsafeDestinationPath)
    }
    /// A file entry is also used as another entry's parent directory.
    public static var conflictingExtractionPath: Self {
        .init(value: .conflictingExtractionPath)
    }
}
