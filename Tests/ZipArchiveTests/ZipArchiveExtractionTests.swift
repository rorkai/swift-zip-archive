//
// This source file is part of the swift-zip-archive project
// Copyright (c) 2025-2026 the swift-zip-archive project authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import SystemPackage
import Testing

@testable import ZipArchive

struct ZipArchiveExtractionTests {
    @Test
    func streamsDeflatedFileInBoundedChunks() throws {
        let contents = Array(repeating: Array("streaming-data".utf8), count: 1_000)
            .flatMap { $0 }
        let writer = ZipArchiveWriter()
        try writer.writeFile(filename: "large.bin", contents: contents)
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())
        let entry = try #require(try reader.readDirectory().first)
        var received: [UInt8] = []
        var chunkSizes: [Int] = []

        try reader.readFile(entry, bufferSize: 257) { chunk in
            chunkSizes.append(chunk.count)
            received.append(contentsOf: chunk)
        }

        #expect(received == contents)
        #expect(chunkSizes.count > 1)
        #expect(chunkSizes.allSatisfy { $0 <= 257 })
    }

    @Test(arguments: [1, 2, 3, 7, 64])
    func streamsDeflatedFileWithTinyBuffers(bufferSize: Int) throws {
        let contents = (0..<8_192).map {
            UInt8(truncatingIfNeeded: $0 &* 31)
        }
        let writer = ZipArchiveWriter()
        try writer.writeFile(filename: "large.bin", contents: contents)
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())
        let entry = try #require(try reader.readDirectory().first)
        var received: [UInt8] = []

        try reader.readFile(entry, bufferSize: bufferSize) { chunk in
            #expect(chunk.count <= bufferSize)
            received.append(contentsOf: chunk)
        }

        #expect(received == contents)
    }

    @Test
    func bufferedReadRejectsStoredSizeMismatch() throws {
        let contents: [UInt8] = [1, 2, 3, 4]
        let writer = ZipArchiveWriter(
            configuration: .init(compression: .noCompression)
        )
        try writer.writeFile(filename: "stored.bin", contents: contents)
        writer.newDirectoryEntries[0].uncompressedSize = 5
        var archive = Array(try writer.finalizeBuffer())

        // Corrupt both size declarations while retaining the payload CRC so
        // the test isolates decompressed-size validation.
        replaceLittleEndianUInt32(5, at: 22, in: &archive)

        let reader = try ZipArchiveReader(buffer: archive)
        let entry = try #require(try reader.readDirectory().first)

        #expect(throws: ZipArchiveReaderError.uncompressedSizeMismatch) {
            _ = try reader.readFile(entry)
        }
    }

    @Test
    func bufferedReadRejectsMissingPasswordBeforePayloadRead() throws {
        let contents = [UInt8](repeating: 0x61, count: 4_096)
        let writer = ZipArchiveWriter(
            configuration: .init(compression: .noCompression)
        )
        try writer.writeFile(
            filename: "encrypted.bin",
            contents: contents,
            password: "secret"
        )
        let storage = ReadTrackingStorage(
            Array(try writer.finalizeBuffer())
        )
        let reader = try ZipArchiveReader(
            storage,
            configuration: .init()
        )
        let entry = try #require(try reader.readDirectory().first)
        storage.bytesRead = 0

        #expect(
            throws: ZipArchiveReaderError.encryptedFilesRequirePassword
        ) {
            _ = try reader.readFile(entry)
        }
        #expect(storage.bytesRead < contents.count)
    }

    @Test
    func streamingReadRejectsTruncatedEncryptionHeader() throws {
        let writer = ZipArchiveWriter(
            configuration: .init(compression: .noCompression)
        )
        try writer.writeFile(
            filename: "encrypted.bin",
            contents: [1],
            password: "secret"
        )
        writer.newDirectoryEntries[0].compressedSize = 11
        var archive = Array(try writer.finalizeBuffer())
        replaceLittleEndianUInt32(11, at: 18, in: &archive)

        let reader = try ZipArchiveReader(buffer: archive)
        let entry = try #require(try reader.readDirectory().first)

        #expect(throws: ZipArchiveReaderError.invalidFileHeader) {
            try reader.readFile(
                entry,
                password: "secret",
                bufferSize: 4
            ) { _ in }
        }
    }

    @Test
    func streamingDeflateRejectsTrailingCompressedBytes() throws {
        let compression = ZlibDeflateCompression()
        let compressed =
            try compression.deflate(
                from: Array("contents".utf8)
            ) + [0xff]
        var hasReadInput = false

        #expect(throws: ZipArchiveReaderError.compressionError) {
            try compression.inflate(
                bufferSize: compressed.count,
                read: { _ in
                    guard !hasReadInput else {
                        return []
                    }
                    hasReadInput = true
                    return compressed
                },
                write: { _ in }
            )
        }
    }

    @Test
    func writerPreservesPortableArchivePathSyntax() throws {
        let writer = ZipArchiveWriter()
        try writer.writeFile(
            filename: "folder/file.txt",
            contents: [1]
        )
        let reader = try ZipArchiveReader(
            buffer: writer.finalizeBuffer()
        )
        let entry = try #require(
            try reader.readDirectory().first { !$0.isDirectory }
        )

        #expect(entry.pathInArchive == "folder/file.txt")
    }

    @Test
    func rejectsParentTraversalBeforeWriting() throws {
        let identifier = UUID().uuidString
        let destination = FilePath("Extraction-\(identifier)")
        let escapedFile = FilePath("escaped-\(identifier).txt")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
            try? FileDescriptor.remove(escapedFile)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(
            filename: "../\(escapedFile)",
            contents: Array("outside".utf8)
        )
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(throws: ZipArchiveReaderError.unsafeExtractionPath) {
            try reader.extract(to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: escapedFile.string))
    }

    @Test
    func rejectsAbsolutePathsBeforeWriting() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(filename: "safe.txt", contents: [1])
        writer.newDirectoryEntries[0].filename = "/absolute.txt"
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(throws: ZipArchiveReaderError.unsafeExtractionPath) {
            try reader.extract(to: destination)
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: destination.string
            ).isEmpty
        )
    }

    @Test
    func createsImplicitParentDirectories() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.addFolder("parent/child")
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        try reader.extract(to: destination)

        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appending("parent/child").string,
                isDirectory: &isDirectory
            )
        )
        #expect(isDirectory.boolValue)
    }

    @Test
    func rejectsSymbolicLinksWhenRequested() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(
            filename: "Current",
            contents: Array("Versions/A".utf8),
            metadata: .init(
                externalAttributes: .unix([
                    .isSymbolicLink,
                    .permissions([.ownerReadWrite]),
                ])
            )
        )
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(throws: ZipArchiveReaderError.symbolicLinkNotAllowed) {
            try reader.extract(
                to: destination,
                options: .init(symbolicLinkPolicy: .reject)
            )
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appending("Current").string
            )
        )
    }

    @Test
    func rejectsDarwinSymbolicLinksWhenRequested() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(
            filename: "Current",
            contents: Array("Versions/A".utf8),
            metadata: .init(
                externalAttributes: .unix([
                    .isSymbolicLink,
                    .permissions([.ownerReadWrite]),
                ])
            )
        )
        var archive = Array(try writer.finalizeBuffer())
        let centralDirectoryOffset = Int(
            writer.endOfCentralDirectoryRecord.offsetOfCentralDirectory
        )
        // PKWARE host system 19 marks OS X (Darwin), whose external attributes
        // use the same Unix file-type bits as host system 3.
        replaceLittleEndianUInt16(
            0x131e,
            at: centralDirectoryOffset + 4,
            in: &archive
        )
        let reader = try ZipArchiveReader(buffer: archive)

        #expect(throws: ZipArchiveReaderError.symbolicLinkNotAllowed) {
            try reader.extract(
                to: destination,
                options: .init(symbolicLinkPolicy: .reject)
            )
        }
    }

    @Test
    func materializesSymbolicLinksByDefault() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(
            filename: "Current",
            contents: Array("Versions/A".utf8),
            metadata: .init(
                externalAttributes: .unix([
                    .isSymbolicLink,
                    .permissions([.ownerReadWrite]),
                ])
            )
        )
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        try reader.extract(to: destination)

        let contents = try Data(
            contentsOf: URL(
                fileURLWithPath: destination.appending("Current").string
            )
        )
        #expect(String(bytes: contents, encoding: .utf8) == "Versions/A")
    }

    @Test
    func rejectsArchiveBeyondEntryCountLimit() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(filename: "one.txt", contents: [1])
        try writer.writeFile(filename: "two.txt", contents: [2])
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(throws: ZipArchiveReaderError.entryCountLimitExceeded) {
            try reader.extract(
                to: destination,
                options: .init(
                    limits: .init(maximumEntryCount: 1)
                )
            )
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: destination.string
            ).isEmpty
        )
    }

    @Test
    func rejectsEntryBeyondUncompressedSizeLimit() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(filename: "large.bin", contents: [1, 2, 3, 4])
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(
            throws: ZipArchiveReaderError.entryUncompressedSizeLimitExceeded
        ) {
            try reader.extract(
                to: destination,
                options: .init(
                    limits: .init(maximumUncompressedSizePerEntry: 3)
                )
            )
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: destination.string
            ).isEmpty
        )
    }

    @Test
    func rejectsLocalHeadersThatBypassCentralDirectoryLimits() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(
            filename: "large.bin",
            contents: [1, 2, 3, 4]
        )
        writer.newDirectoryEntries[0].uncompressedSize = 1
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(throws: ZipArchiveReaderError.invalidFileHeader) {
            try reader.extract(
                to: destination,
                options: .init(
                    limits: .init(maximumUncompressedSizePerEntry: 1)
                )
            )
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appending("large.bin").string
            )
        )
    }

    @Test
    func rejectsArchiveBeyondTotalUncompressedSizeLimit() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(filename: "one.bin", contents: [1, 2, 3])
        try writer.writeFile(filename: "two.bin", contents: [4, 5, 6])
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(
            throws: ZipArchiveReaderError.totalUncompressedSizeLimitExceeded
        ) {
            try reader.extract(
                to: destination,
                options: .init(
                    limits: .init(maximumTotalUncompressedSize: 5)
                )
            )
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: destination.string
            ).isEmpty
        )
    }

    @Test
    func extractionUsesStreamingCompression() throws {
        struct StreamingOnlyCompression: ZipStreamingCompression {
            let method = Zip.FileCompressionMethod.reserved1

            func inflate(
                from: [UInt8],
                uncompressedSize: Int
            ) throws -> [UInt8] {
                throw ZipArchiveReaderError.internalError
            }

            func deflate(from: [UInt8]) throws -> [UInt8] {
                from
            }

            func inflate(
                bufferSize: Int,
                read: (Int) throws -> [UInt8],
                write: ([UInt8]) throws -> Void
            ) throws {
                while true {
                    let bytes = try read(bufferSize)
                    guard !bytes.isEmpty else {
                        return
                    }
                    try write(bytes)
                }
            }
        }

        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let compression = StreamingOnlyCompression()
        let writer = ZipArchiveWriter(
            configuration: .init(compression: compression)
        )
        try writer.writeFile(
            filename: "streamed.bin",
            contents: Array("streamed contents".utf8)
        )
        let reader = try ZipArchiveReader(
            buffer: writer.finalizeBuffer(),
            configuration: .init(compressionMethods: [compression])
        )

        try reader.extract(
            to: destination,
            options: .init(bufferSize: 3)
        )

        let contents = try Data(
            contentsOf: URL(
                fileURLWithPath: destination.appending("streamed.bin").string
            )
        )
        #expect(
            String(bytes: contents, encoding: .utf8)
                == "streamed contents"
        )
    }

    #if !os(Windows)
    @Test
    func rejectsExistingDestinationDirectorySymlink() throws {
        let identifier = UUID().uuidString
        let destination = FilePath("Extraction-\(identifier)")
        let outsideDirectory = FilePath("Outside-\(identifier)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        try DirectoryDescriptor.mkdir(
            outsideDirectory,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
            try? DirectoryDescriptor.recursiveDelete(outsideDirectory)
        }
        try FileManager.default.createSymbolicLink(
            atPath: destination.appending("redirect").string,
            withDestinationPath: URL(
                fileURLWithPath: outsideDirectory.string
            ).standardizedFileURL.path
        )

        let writer = ZipArchiveWriter()
        try writer.writeFile(
            filename: "redirect/escaped.txt",
            contents: Array("outside".utf8)
        )
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(throws: ZipArchiveReaderError.unsafeDestinationPath) {
            try reader.extract(to: destination)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: outsideDirectory.appending("escaped.txt").string
            )
        )
    }
    #endif

    @Test
    func rejectsCanonicalDuplicatePaths() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(filename: "folder/file.txt", contents: [1])
        try writer.writeFile(filename: "folder/./file.txt", contents: [2])
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(throws: ZipArchiveReaderError.duplicateExtractionPath) {
            try reader.extract(to: destination)
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: destination.string
            ).isEmpty
        )
    }

    @Test
    func rejectsBackslashPathsAcrossPlatforms() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(
            filename: "folder/file.txt",
            contents: [1]
        )
        let fileEntryIndex = writer.newDirectoryEntries.index(
            before: writer.newDirectoryEntries.endIndex
        )
        writer.newDirectoryEntries[fileEntryIndex].pathInArchive =
            #"folder\file.txt"#
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(throws: ZipArchiveReaderError.unsafeExtractionPath) {
            try reader.extract(to: destination)
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: destination.string
            ).isEmpty
        )
    }

    @Test
    func rejectsFileAndDirectoryPathConflictsBeforeWriting() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(filename: "parent", contents: [1])
        try writer.writeFile(filename: "other/child.txt", contents: [2])
        writer.newDirectoryEntries[2].filename = "parent/child.txt"
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(throws: ZipArchiveReaderError.conflictingExtractionPath) {
            try reader.extract(to: destination)
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: destination.string
            ).isEmpty
        )
    }

    @Test
    func preservesPreexistingDestinationFiles() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }
        let existingFile = destination.appending("existing.txt")
        let descriptor = try FileDescriptor.open(
            existingFile,
            .writeOnly,
            options: [.create, .exclusiveCreate],
            permissions: [.ownerReadWrite]
        )
        _ = try descriptor.closeAfter {
            try descriptor.writeAll("original".utf8)
        }

        let writer = ZipArchiveWriter()
        try writer.writeFile(
            filename: "existing.txt",
            contents: Array("replacement".utf8)
        )
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())

        #expect(throws: (any Error).self) {
            try reader.extract(to: destination)
        }
        let contents = try Data(
            contentsOf: URL(fileURLWithPath: existingFile.string)
        )
        #expect(String(bytes: contents, encoding: .utf8) == "original")
    }

    @Test
    func rejectsNegativeLimitsForEmptyArchive() throws {
        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let reader = try ZipArchiveReader(
            buffer: ZipArchiveWriter().finalizeBuffer()
        )

        #expect(throws: ZipArchiveReaderError.invalidExtractionOptions) {
            try reader.extract(
                to: destination,
                options: .init(
                    limits: .init(maximumTotalUncompressedSize: -1)
                )
            )
        }
    }

    @Test
    func streamsStoredFileInBoundedChunks() throws {
        let contents = Array("stored streaming contents".utf8)
        let writer = ZipArchiveWriter(
            configuration: .init(compression: .noCompression)
        )
        try writer.writeFile(filename: "stored.bin", contents: contents)
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())
        let entry = try #require(try reader.readDirectory().first)
        var received: [UInt8] = []
        var chunkSizes: [Int] = []

        try reader.readFile(entry, bufferSize: 3) { chunk in
            chunkSizes.append(chunk.count)
            received.append(contentsOf: chunk)
        }

        #expect(received == contents)
        #expect(chunkSizes.count > 1)
        #expect(chunkSizes.allSatisfy { $0 <= 3 })
    }

    @Test
    func streamsEncryptedFile() throws {
        let contents = Array("encrypted streaming contents".utf8)
        let writer = ZipArchiveWriter()
        try writer.writeFile(
            filename: "encrypted.bin",
            contents: contents,
            password: "secret"
        )
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())
        let entry = try #require(try reader.readDirectory().first)
        var received: [UInt8] = []

        try reader.readFile(
            entry,
            password: "secret",
            bufferSize: 5
        ) { chunk in
            received.append(contentsOf: chunk)
        }

        #expect(received == contents)
    }

    @Test
    func rejectsStreamingForNonstreamingCompression() throws {
        struct NonstreamingCompression: ZipCompression {
            let method = Zip.FileCompressionMethod.reserved1

            func inflate(
                from: [UInt8],
                uncompressedSize: Int
            ) throws -> [UInt8] {
                from
            }

            func deflate(from: [UInt8]) throws -> [UInt8] {
                from
            }
        }

        let compression = NonstreamingCompression()
        let writer = ZipArchiveWriter(
            configuration: .init(compression: compression)
        )
        try writer.writeFile(filename: "custom.bin", contents: [1, 2, 3])
        let reader = try ZipArchiveReader(
            buffer: writer.finalizeBuffer(),
            configuration: .init(compressionMethods: [compression])
        )
        let entry = try #require(try reader.readDirectory().first)

        #expect(
            throws: ZipArchiveReaderError
                .streamingUnsupportedCompressionMethod
        ) {
            try reader.readFile(entry, bufferSize: 2) { _ in }
        }
    }

    @Test
    func rejectsInvalidStreamingBufferSize() throws {
        let writer = ZipArchiveWriter()
        try writer.writeFile(filename: "file.bin", contents: [1])
        let reader = try ZipArchiveReader(buffer: writer.finalizeBuffer())
        let entry = try #require(try reader.readDirectory().first)

        #expect(throws: ZipArchiveReaderError.invalidBufferSize) {
            try reader.readFile(entry, bufferSize: 0) { _ in }
        }
    }

    @Test
    func removesPartiallyExtractedFilesAfterStreamingFailure() throws {
        struct FailingStreamingCompression: ZipStreamingCompression {
            let method = Zip.FileCompressionMethod.reserved1

            func inflate(
                from: [UInt8],
                uncompressedSize: Int
            ) throws -> [UInt8] {
                from
            }

            func deflate(from: [UInt8]) throws -> [UInt8] {
                from
            }

            func inflate(
                bufferSize: Int,
                read: (Int) throws -> [UInt8],
                write: ([UInt8]) throws -> Void
            ) throws {
                let bytes = try read(bufferSize)
                try write(bytes)
                throw ZipArchiveReaderError.compressionError
            }
        }

        let destination = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            destination,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(destination)
        }

        let compression = FailingStreamingCompression()
        let writer = ZipArchiveWriter(
            configuration: .init(compression: compression)
        )
        try writer.writeFile(filename: "partial.bin", contents: [1, 2, 3])
        let reader = try ZipArchiveReader(
            buffer: writer.finalizeBuffer(),
            configuration: .init(compressionMethods: [compression])
        )

        #expect(throws: ZipArchiveReaderError.compressionError) {
            try reader.extract(to: destination)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appending("partial.bin").string
            )
        )
    }

    @Test
    func fileOnlyCleanupDoesNotRemoveDirectories() throws {
        let directory = FilePath("Extraction-\(UUID().uuidString)")
        try DirectoryDescriptor.mkdir(
            directory,
            options: .ignoreExistingDirectoryError,
            permissions: [.ownerReadWriteExecute]
        )
        defer {
            try? DirectoryDescriptor.recursiveDelete(directory)
        }

        #expect(throws: (any Error).self) {
            try FileDescriptor.removeFile(directory)
        }
        #expect(FileManager.default.fileExists(atPath: directory.string))
    }

    @Test
    func rejectsOversizedChunksFromStreamingCompression() throws {
        struct OversizedStreamingCompression: ZipStreamingCompression {
            let method = Zip.FileCompressionMethod.reserved1

            func inflate(
                from: [UInt8],
                uncompressedSize: Int
            ) throws -> [UInt8] {
                from
            }

            func deflate(from: [UInt8]) throws -> [UInt8] {
                from
            }

            func inflate(
                bufferSize: Int,
                read: (Int) throws -> [UInt8],
                write: ([UInt8]) throws -> Void
            ) throws {
                _ = try read(bufferSize)
                try write([1, 2, 3])
            }
        }

        let compression = OversizedStreamingCompression()
        let writer = ZipArchiveWriter(
            configuration: .init(compression: compression)
        )
        try writer.writeFile(filename: "custom.bin", contents: [1, 2])
        let reader = try ZipArchiveReader(
            buffer: writer.finalizeBuffer(),
            configuration: .init(compressionMethods: [compression])
        )
        let entry = try #require(try reader.readDirectory().first)

        #expect(
            throws: ZipArchiveReaderError.streamingChunkExceedsBufferSize
        ) {
            try reader.readFile(entry, bufferSize: 2) { _ in }
        }
    }

    @Test
    func rejectsNonpositiveReadRequestsFromStreamingCompression() throws {
        struct InvalidStreamingCompression: ZipStreamingCompression {
            let method = Zip.FileCompressionMethod.reserved1

            func inflate(
                from: [UInt8],
                uncompressedSize: Int
            ) throws -> [UInt8] {
                from
            }

            func deflate(from: [UInt8]) throws -> [UInt8] {
                from
            }

            func inflate(
                bufferSize: Int,
                read: (Int) throws -> [UInt8],
                write: ([UInt8]) throws -> Void
            ) throws {
                _ = try read(0)
            }
        }

        let compression = InvalidStreamingCompression()
        let writer = ZipArchiveWriter(
            configuration: .init(compression: compression)
        )
        try writer.writeFile(filename: "custom.bin", contents: [1])
        let reader = try ZipArchiveReader(
            buffer: writer.finalizeBuffer(),
            configuration: .init(compressionMethods: [compression])
        )
        let entry = try #require(try reader.readDirectory().first)

        #expect(throws: ZipArchiveReaderError.invalidBufferSize) {
            try reader.readFile(entry, bufferSize: 2) { _ in }
        }
    }

    @Test
    func builtInStreamingCompressionRejectsOversizedInputChunks() {
        #expect(
            throws: ZipArchiveReaderError.streamingChunkExceedsBufferSize
        ) {
            try NoZipCompression().inflate(
                bufferSize: 2,
                read: { _ in [1, 2, 3] },
                write: { _ in }
            )
        }
        #expect(
            throws: ZipArchiveReaderError.streamingChunkExceedsBufferSize
        ) {
            try ZlibDeflateCompression().inflate(
                bufferSize: 2,
                read: { _ in [1, 2, 3] },
                write: { _ in }
            )
        }
    }
}

private final class ReadTrackingStorage: ZipReadableStorage {
    typealias OutputBuffer = ArraySlice<UInt8>

    private let storage: ZipMemoryStorage<[UInt8]>
    var bytesRead = 0

    init(_ bytes: [UInt8]) {
        self.storage = ZipMemoryStorage(bytes)
    }

    func read(_ count: Int) throws(ZipStorageError) -> ArraySlice<UInt8> {
        let bytes = try storage.read(count)
        bytesRead += bytes.count
        return bytes
    }

    @discardableResult
    func seek(_ index: Int64) throws(ZipStorageError) -> Int64 {
        try storage.seek(index)
    }

    @discardableResult
    func seekOffset(_ offset: Int64) throws(ZipStorageError) -> Int64 {
        try storage.seekOffset(offset)
    }

    @discardableResult
    func seekEnd(_ offset: Int64) throws(ZipStorageError) -> Int64 {
        try storage.seekEnd(offset)
    }
}

private func replaceLittleEndianUInt32(
    _ value: UInt32,
    at offset: Int,
    in bytes: inout [UInt8]
) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) {
        bytes.replaceSubrange(offset..<(offset + $0.count), with: $0)
    }
}

private func replaceLittleEndianUInt16(
    _ value: UInt16,
    at offset: Int,
    in bytes: inout [UInt8]
) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) {
        bytes.replaceSubrange(offset..<(offset + $0.count), with: $0)
    }
}
