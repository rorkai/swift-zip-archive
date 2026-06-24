//
// This source file is part of the swift-zip-archive project
// Copyright (c) 2025-2026 the swift-zip-archive project authors
//
// See LICENSE for license information
// SPDX-License-Identifier: Apache-2.0
//

public import SystemPackage

#if os(Windows)
import Foundation
#endif

/// Policies applied while extracting an archive to the file system.
public struct ZipArchiveExtractionOptions: Sendable {
    /// Default compressed and decompressed chunk size.
    public static let defaultBufferSize = 64 * 1024

    /// Resource limits checked before and during extraction.
    public struct Limits: Sendable {
        /// Maximum number of central-directory entries, or `nil` for no limit.
        public var maximumEntryCount: Int?

        /// Maximum uncompressed bytes in one entry, or `nil` for no limit.
        public var maximumUncompressedSizePerEntry: Int64?

        /// Maximum uncompressed bytes across all entries, or `nil` for no
        /// limit.
        public var maximumTotalUncompressedSize: Int64?

        /// Creates extraction limits.
        ///
        /// - Parameters:
        ///   - maximumEntryCount: Maximum number of entries accepted.
        ///   - maximumUncompressedSizePerEntry: Maximum expanded size of one
        ///     entry.
        ///   - maximumTotalUncompressedSize: Maximum expanded size across the
        ///     archive.
        public init(
            maximumEntryCount: Int? = nil,
            maximumUncompressedSizePerEntry: Int64? = nil,
            maximumTotalUncompressedSize: Int64? = nil
        ) {
            self.maximumEntryCount = maximumEntryCount
            self.maximumUncompressedSizePerEntry =
                maximumUncompressedSizePerEntry
            self.maximumTotalUncompressedSize =
                maximumTotalUncompressedSize
        }
    }

    /// How symbolic-link entries are handled.
    public enum SymbolicLinkPolicy: Sendable {
        /// Reject the archive before writing any entries.
        case reject

        /// Write the stored link target as regular file contents.
        ///
        /// This preserves the package's historical behavior without creating
        /// a filesystem link that could escape the destination.
        case materializeAsFile
    }

    /// Maximum compressed or decompressed bytes held by one streaming step.
    public var bufferSize: Int

    /// Symbolic-link behavior used during extraction.
    public var symbolicLinkPolicy: SymbolicLinkPolicy

    /// Resource limits applied to the archive.
    public var limits: Limits

    /// Creates extraction options.
    ///
    /// - Parameters:
    ///   - bufferSize: Maximum compressed or decompressed chunk size.
    ///   - symbolicLinkPolicy: How symbolic-link entries are handled.
    ///   - limits: Resource limits applied before and during extraction.
    public init(
        bufferSize: Int = Self.defaultBufferSize,
        symbolicLinkPolicy: SymbolicLinkPolicy = .reject,
        limits: Limits = .init()
    ) {
        self.bufferSize = bufferSize
        self.symbolicLinkPolicy = symbolicLinkPolicy
        self.limits = limits
    }
}

extension ZipArchiveReader {
    /// Extracts the archive using secure default policies.
    ///
    /// - Parameters:
    ///   - rootFolder: Existing directory that receives the archive contents.
    ///   - password: Password used to decrypt encrypted entries.
    /// - Throws: ``ZipArchiveReaderError`` when archive validation fails, or a
    ///   file-system error when an entry cannot be created or written.
    public func extract(
        to rootFolder: FilePath,
        password: String? = nil
    ) throws {
        try extract(
            to: rootFolder,
            password: password,
            options: .init()
        )
    }

    /// Extracts the archive into an existing directory.
    ///
    /// Every archive path and configured resource limit is validated before
    /// the first entry is written. Extraction rejects path traversal,
    /// duplicate destinations, file-directory conflicts, and symbolic links
    /// by default. Existing destination files are never overwritten.
    ///
    /// - Parameters:
    ///   - rootFolder: Existing directory that receives the archive contents.
    ///   - password: Password used to decrypt encrypted entries.
    ///   - options: Streaming, symbolic-link, and resource-limit policies.
    /// - Throws: ``ZipArchiveReaderError`` when archive validation fails, or a
    ///   file-system error when an entry cannot be created or written.
    public func extract(
        to rootFolder: FilePath,
        password: String? = nil,
        options: ZipArchiveExtractionOptions = .init()
    ) throws {
        try validateExtractionOptions(options)
        let entries = try validatedExtractionEntries(options: options)
        for item in entries {
            let fullFilePath = rootFolder.appending(item.path.components)
            try ensureParentDirectories(
                of: item.path,
                in: rootFolder
            )
            if item.header.isDirectory {
                let permissions = item.header.externalAttributes.unixAttributes
                    .filePermissions.union([.ownerRead, .ownerExecute])
                try ensureDirectory(
                    at: fullFilePath,
                    permissions: permissions
                )
            } else {
                let permissions = item.header.externalAttributes.unixAttributes
                    .filePermissions.union([.ownerReadWrite])
                var openOptions: FileDescriptor.OpenOptions = [
                    .create,
                    .exclusiveCreate,
                ]
                #if !os(Windows)
                openOptions.insert(.noFollow)
                #endif

                let fileDescriptor = try FileDescriptor.open(
                    fullFilePath,
                    .writeOnly,
                    options: openOptions,
                    permissions: permissions
                )
                do {
                    try fileDescriptor.closeAfter {
                        try self.readFile(
                            item.header,
                            password: password,
                            bufferSize: options.bufferSize
                        ) { bytes in
                            try fileDescriptor.writeAll(bytes)
                        }
                    }
                } catch {
                    try? FileDescriptor.remove(fullFilePath)
                    throw error
                }
            }
        }
    }

    /// Creates missing parents and verifies that no archive-controlled
    /// component resolves through a symbolic link.
    private func ensureParentDirectories(
        of relativePath: FilePath,
        in rootFolder: FilePath
    ) throws {
        var directory = rootFolder
        for component in relativePath.components.dropLast() {
            directory.append(component)
            try ensureDirectory(
                at: directory,
                permissions: [
                    .ownerReadWriteExecute,
                    .groupReadExecute,
                    .otherReadExecute,
                ]
            )
        }
    }

    /// Ensures one archive-controlled path component is a real directory.
    private func ensureDirectory(
        at path: FilePath,
        permissions: FilePermissions
    ) throws {
        do {
            try DirectoryDescriptor.mkdir(
                path,
                options: .ignoreExistingDirectoryError,
                permissions: permissions
            )
            #if os(Windows)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: path.string
            )
            guard attributes[.type] as? FileAttributeType == .typeDirectory
            else {
                throw ZipArchiveReaderError.unsafeDestinationPath
            }
            #else
            let descriptor = try FileDescriptor.open(
                path,
                .readOnly,
                options: [.directory, .noFollow]
            )
            try descriptor.close()
            #endif
        } catch let error as ZipArchiveReaderError {
            throw error
        } catch {
            throw ZipArchiveReaderError.unsafeDestinationPath
        }
    }

    /// Resolves every archive path before extraction so an invalid late entry
    /// cannot leave earlier files outside the intended destination.
    private func validatedExtractionEntries(
        options: ZipArchiveExtractionOptions
    ) throws
        -> [ValidatedExtractionEntry]
    {
        guard endOfCentralDirectoryRecord.diskEntries >= 0 else {
            throw ZipArchiveReaderError.invalidDirectory
        }
        if let maximumEntryCount = options.limits.maximumEntryCount {
            guard
                endOfCentralDirectoryRecord.diskEntries
                    <= Int64(maximumEntryCount)
            else {
                throw ZipArchiveReaderError.entryCountLimitExceeded
            }
        }
        var directory: [Zip.FileHeader] = []
        if let entryCount = Int(
            exactly: endOfCentralDirectoryRecord.diskEntries
        ) {
            directory.reserveCapacity(entryCount)
        }
        try parseDirectory { entry in
            directory.append(entry)
        }

        var paths: Set<String> = []
        var totalUncompressedSize: Int64 = 0
        let entries = try directory.map { entry in
            guard entry.uncompressedSize >= 0 else {
                throw ZipArchiveReaderError.invalidDirectory
            }
            if let maximumSize =
                options.limits.maximumUncompressedSizePerEntry
            {
                guard entry.uncompressedSize <= maximumSize else {
                    throw ZipArchiveReaderError
                        .entryUncompressedSizeLimitExceeded
                }
            }
            if let maximumTotalSize =
                options.limits.maximumTotalUncompressedSize
            {
                let (newTotal, overflowed) =
                    totalUncompressedSize.addingReportingOverflow(
                        entry.uncompressedSize
                    )
                guard !overflowed, newTotal <= maximumTotalSize else {
                    throw ZipArchiveReaderError
                        .totalUncompressedSizeLimitExceeded
                }
                totalUncompressedSize = newTotal
            }
            guard
                !entry.isSymbolicLink
                    || options.symbolicLinkPolicy == .materializeAsFile
            else {
                throw ZipArchiveReaderError.symbolicLinkNotAllowed
            }
            let path = try validatedExtractionPath(entry.filename)
            guard paths.insert(path.string).inserted else {
                throw ZipArchiveReaderError.duplicateExtractionPath
            }
            return ValidatedExtractionEntry(header: entry, path: path)
        }

        let isDirectoryByPath = Dictionary(
            uniqueKeysWithValues: entries.map {
                ($0.path.string, $0.header.isDirectory)
            }
        )
        for item in entries {
            var parent = item.path.removingLastComponent()
            while !parent.isEmpty {
                if isDirectoryByPath[parent.string] == false {
                    throw ZipArchiveReaderError.conflictingExtractionPath
                }
                parent.removeLastComponent()
            }
        }
        return entries
    }

    /// ZIP uses `/` on every platform, so alternate separators must not become
    /// path components only after the destination file system interprets them.
    private func validatedExtractionPath(
        _ archivedPath: FilePath
    ) throws -> FilePath {
        guard archivedPath.root == nil,
            !archivedPath.string.contains("\\"),
            !archivedPath.string.utf8.contains(0)
        else {
            throw ZipArchiveReaderError.unsafeExtractionPath
        }

        var path = FilePath()
        for component in archivedPath.components {
            switch component.kind {
            case .currentDirectory:
                continue
            case .parentDirectory:
                throw ZipArchiveReaderError.unsafeExtractionPath
            case .regular:
                path.append(component)
            }
        }
        guard !path.isEmpty else {
            throw ZipArchiveReaderError.unsafeExtractionPath
        }
        return path
    }
}

private struct ValidatedExtractionEntry {
    let header: Zip.FileHeader
    let path: FilePath
}

private func validateExtractionOptions(
    _ options: ZipArchiveExtractionOptions
) throws {
    guard options.bufferSize > 0,
        UInt64(options.bufferSize) <= UInt64(UInt32.max),
        options.limits.maximumEntryCount.map({ $0 >= 0 }) ?? true,
        options.limits.maximumUncompressedSizePerEntry.map({ $0 >= 0 }) ?? true,
        options.limits.maximumTotalUncompressedSize.map({ $0 >= 0 }) ?? true
    else {
        throw ZipArchiveReaderError.invalidExtractionOptions
    }
}
