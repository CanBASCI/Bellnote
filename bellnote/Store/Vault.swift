import Foundation

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
}

enum VaultError: Error {
    case missingDocuments
    case copyFailed
}
