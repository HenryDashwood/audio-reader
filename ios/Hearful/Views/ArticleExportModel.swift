import Combine
import Foundation

@MainActor
final class ArticleExportModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var file: ArticlePDFFile?
    @Published private(set) var error: String?
    private var generation = 0

    func clear() {
        generation += 1
        busy = false
        file = nil
        error = nil
        // Shared files remain in the private cache for a day: a receiving app
        // can still be copying the file after the share pane closes.
    }

    func prepare(episode: Episode, contentID: Int?, textVersion: String?, api: any ArticleExportAPI,
                 validSession: @escaping () async -> Bool = { true }) async {
        guard !busy else { return }
        let ticket = generation
        busy = true
        error = nil
        file = nil
        defer { if generation == ticket { busy = false } }
        let initialSessionIsValid = await validSession()
        guard ticket == generation, !Task.isCancelled else { return }
        guard initialSessionIsValid else {
            error = "Your account changed. Reopen the article to export it."
            return
        }
        do {
            let result = try await api.export(episodeID: episode.id, contentID: contentID,
                                              textVersion: textVersion, title: episode.title)
            let valid = await validSession()
            guard ticket == generation, !Task.isCancelled, valid else {
                await ArticleExportClient.discard(result)
                if ticket == generation && !valid { error = "Your account changed. Reopen the article to export it." }
                return
            }
            file = result
        } catch {
            guard ticket == generation, !Task.isCancelled else { return }
            let valid = await validSession()
            guard ticket == generation, !Task.isCancelled else { return }
            guard valid else {
                self.error = "Your account changed. Reopen the article to export it."
                return
            }
            self.error = (error as? APIError)?.spokenResponse ?? "The PDF couldn’t be prepared. Please try again."
        }
    }
}
