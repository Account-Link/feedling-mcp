import Foundation

enum FeedlingAPI {
    static let baseURL: String =
        ProcessInfo.processInfo.environment["FEEDLING_API_URL"] ?? "http://54.209.126.4:5001"
}
