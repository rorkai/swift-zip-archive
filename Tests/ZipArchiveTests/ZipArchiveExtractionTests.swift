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
    func rejectsSymbolicLinksByDefault() throws {
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
            try reader.extract(to: destination)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appending("Current").string
            )
        )
    }

    @Test
    func materializesSymbolicLinksWhenRequested() throws {
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

        try reader.extract(
            to: destination,
            options: .init(symbolicLinkPolicy: .materializeAsFile)
        )

        let contents = try Data(
            contentsOf: URL(
                fileURLWithPath: destination.appending("Current").string
            )
        )
        #expect(String(decoding: contents, as: UTF8.self) == "Versions/A")
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
        #expect(String(decoding: contents, as: UTF8.self) == "streamed contents")
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
            filename: #"folder\file.txt"#,
            contents: [1]
        )
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
        #expect(String(decoding: contents, as: UTF8.self) == "original")
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
