import AVFoundation
import Foundation
import OSLog

enum Vault {
    static let coursesFolder = "Courses"
    static let modelsFolder = "Models"

    static func documents() throws -> URL {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw VaultError.missingDocuments
        }
        return url
    }

    static func courseDirectory(id: UUID) throws -> URL {
        let url = try documents().appendingPathComponent(coursesFolder, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func modelsDirectory() throws -> URL {
        let url = try documents().appendingPathComponent(modelsFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func removeCourseDirectory(id: UUID) throws {
        let url = try documents().appendingPathComponent(coursesFolder, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Copies one file into this course. The stored name is unique. The display name stays the original.
    static func importCourseFile(courseID: UUID, from source: URL) throws -> (relativePath: String, displayName: String) {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let displayName = source.lastPathComponent
        let ext = source.pathExtension
        return try writeCourseFile(
            courseID: courseID,
            from: source,
            fileExtension: ext,
            displayName: displayName.isEmpty ? UUID().uuidString : displayName
        )
    }

    /// Writes bytes the student picked from Photos, such as a screenshot.
    static func writeCourseData(courseID: UUID, data: Data, fileExtension: String, displayName: String) throws -> String {
        let folder = try filesDirectory(courseID: courseID)
        let stored = storedName(fileExtension: fileExtension)
        let destination = folder.appendingPathComponent(stored)
        try data.write(to: destination, options: .atomic)
        return relativeFilePath(courseID: courseID, storedName: stored)
    }

    /// Writes an edited copy over a file the app already keeps. Drawing, typed text, and the other edits travel with the file. The path stays the same, so the course still opens it.
    /// Called from the preview delegate before that method returns, so it stays off the main actor.
    nonisolated static func replaceStoredFile(at stored: URL, with edited: URL) throws {
        guard edited.standardizedFileURL != stored.standardizedFileURL else { return }
        let accessed = edited.startAccessingSecurityScopedResource()
        defer { if accessed { edited.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: edited)
        guard !data.isEmpty else { throw VaultError.copyFailed }
        try data.write(to: stored, options: .atomic)
    }

    /// Copies an audio file the student already has into the course, next to recordings made here.
    /// The stored name keeps the original extension so the file can still be read. An empty or unreadable file is not kept.
    static func importLectureAudio(
        courseID: UUID,
        startedAt: Date,
        from source: URL
    ) throws -> (relativePath: String, seconds: Int) {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedName = ext.isEmpty
            ? "\(startedAt.timeIntervalSince1970)"
            : "\(startedAt.timeIntervalSince1970).\(ext)"
        let folder = try courseDirectory(id: courseID)
        let destination = folder.appendingPathComponent(storedName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            let audio = try AVAudioFile(forReading: destination)
            let rate = audio.processingFormat.sampleRate
            guard rate > 0, audio.length > 0 else { throw VaultError.copyFailed }
            let seconds = max(1, Int((Double(audio.length) / rate).rounded()))
            let root = try documents()
            let relative = destination.path.replacingOccurrences(of: root.path + "/", with: "")
            return (relative, seconds)
        } catch let readError {
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {
                Logger(subsystem: "app.bellnote", category: "capture").error(
                    "Unreadable import could not be removed: \(error.localizedDescription, privacy: .public)"
                )
            }
            throw readError
        }
    }

    static func removeStoredFile(relativePath: String) throws {
        let url = try documents().appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func writeCourseFile(
        courseID: UUID,
        from source: URL,
        fileExtension: String,
        displayName: String
    ) throws -> (relativePath: String, displayName: String) {
        let folder = try filesDirectory(courseID: courseID)
        let destination = folder.appendingPathComponent(storedName(fileExtension: fileExtension))
        try FileManager.default.copyItem(at: source, to: destination)
        let stored = destination.lastPathComponent
        return (relativeFilePath(courseID: courseID, storedName: stored), displayName)
    }

    private static func filesDirectory(courseID: UUID) throws -> URL {
        let folder = try courseDirectory(id: courseID).appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func storedName(fileExtension: String) -> String {
        let token = UUID().uuidString
        let ext = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return ext.isEmpty ? token : "\(token).\(ext)"
    }

    private static func relativeFilePath(courseID: UUID, storedName: String) -> String {
        "\(coursesFolder)/\(courseID.uuidString)/files/\(storedName)"
    }
}

enum VaultError: Error {
    case missingDocuments
    case copyFailed
}
