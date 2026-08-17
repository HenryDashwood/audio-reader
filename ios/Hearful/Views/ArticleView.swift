import SwiftUI
import WebKit

/// An article's content, on screen.
///
/// Reading articles aloud is the point of the app, but text that can only be
/// heard cannot be skimmed, re-read, or looked at over someone's shoulder —
/// and a written episode was, until this screen, the one thing in the library
/// with no page of its own.
///
/// The article is rendered as HTML rather than as stripped paragraphs, because
/// stripping is exactly what makes an article unlike itself: a post whose point
/// is a chart is not the same post with the chart taken out, and a link that
/// has become plain words is a reference nobody can follow. Speech has to do
/// without all of that; a screen does not.
///
/// Listening is still the first control on the page. This is a way into an
/// article, not a replacement for hearing it.
struct ArticleView: View {
    let episode: Episode
    @StateObject private var model = ArticleTextModel()
    @ObservedObject private var player = PlaybackCoordinator.shared
    /// Not read directly — it is here so a change of text size redraws the
    /// page, since the web view is sized in points we hand it rather than by
    /// anything that scales on its own.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .navigationTitle(episode.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(episodeID: episode.id) }
    }

    /// Pinned above the article rather than scrolling with it: both of these
    /// are ways to leave this screen for the thing it is about, and having to
    /// scroll back to the top to reach them is a tax on long pieces — which
    /// is to say on exactly the articles worth listening to instead.
    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                if isCurrent {
                    player.toggle()
                } else {
                    try? player.play(episode)
                }
            } label: {
                Label(
                    isCurrent && player.isPlaying ? "Pause" : "Listen",
                    systemImage: isCurrent && player.isPlaying ? "pause.fill" : "play.fill"
                )
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(
                isCurrent && player.isPlaying
                    ? "Stops reading this article aloud"
                    : "Reads this article aloud")

            if let link = episode.link {
                Link(destination: link) {
                    Label("Original", systemImage: "safari")
                        .frame(minHeight: 30)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open the original")
                .accessibilityHint("Opens the article's own page in your browser")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            Spacer()
            ProgressView("Loading the article…")
            Spacer()
        case .failed(let message):
            // The same sentence the player would have read out, shown instead.
            ContentUnavailableView(
                "Could not load this article", systemImage: "doc.questionmark",
                description: Text(message))
        case .loaded(let article):
            VStack(spacing: 0) {
                if model.isOffline {
                    Label(
                        "Offline — showing the saved copy, without its pictures",
                        systemImage: "wifi.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                ArticleWebView(
                    document: document(for: article),
                    // Feeds write their pictures and links relative to the
                    // site they came from, so without the article's own
                    // address every image is a broken one.
                    baseURL: episode.link)
            }
        }
    }

    private var isCurrent: Bool { player.currentEpisode?.id == episode.id }

    /// Title and byline live in the document rather than above it, so they
    /// scroll away like the top of any article instead of holding a third of
    /// a phone screen for the whole read.
    private func document(for article: ArticleTextModel.Article) -> String {
        var header = "<h1>\(ArticleTextModel.escaped(episode.title))</h1>"
        var meta: [String] = []
        if let published = episode.publishedAt {
            meta.append(
                ArticleTextModel.escaped(
                    published.formatted(.dateTime.day().month(.wide).year())))
        }
        // The player's own estimate, not a separate reading-speed guess: two
        // different numbers for one article, here and on the scrubber, would
        // be worse than no number at all.
        if let length = formatLength(seconds: Int(article.spokenDuration)) {
            meta.append("\(length) to listen")
        }
        if !meta.isEmpty {
            header += "<p class=\"meta\">\(meta.joined(separator: " · "))</p>"
        }
        return ArticleDocument.page(
            body: header + article.body,
            pointSize: UIFont.preferredFont(forTextStyle: .body).pointSize)
    }
}

/// The article itself. A web view because the content is HTML from somewhere
/// on the internet, and because nothing else on iOS lays out a real article —
/// headings, block quotes, code, tables, pictures — without reimplementing a
/// browser badly.
///
/// Scripting is off. The backend already reduces the markup to an allowlist of
/// structure and prose, and this is the second lock on that door.
private struct ArticleWebView: UIViewRepresentable {
    let document: String
    let baseURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // The page paints no background of its own, so the app's shows
        // through and the article is the right colour in both appearances
        // without the web view having to be told which one it is in.
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        // Reloading throws away the scroll position, so only when the page
        // has actually changed — which it does on a text-size change, and
        // otherwise on every redraw the player causes by ticking.
        guard context.coordinator.loaded != document else { return }
        context.coordinator.loaded = document
        view.loadHTMLString(document, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        /// Links leave for Safari rather than navigating in place. A web view
        /// with no address bar, no back button and no way out is a trap, and
        /// this one is a reader, not a browser.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                let url = navigationAction.request.url
            else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        }
    }
}

/// The page the article is rendered into.
enum ArticleDocument {
    /// Wraps an article's body in a stylesheet built for reading.
    ///
    /// The body size is passed in rather than left to the web view's default,
    /// which is a fixed sixteen pixels and ignores the text size set on the
    /// phone — the one setting a person who is losing their sight has almost
    /// certainly already turned up.
    static func page(body: String, pointSize: CGFloat) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; --ink: #000; --quiet: #6c6c70; --rule: #d1d1d6; }
          @media (prefers-color-scheme: dark) {
            :root { --ink: #fff; --quiet: #98989f; --rule: #38383a; }
          }
          body {
            margin: 0 16px 48px;
            padding-top: 4px;
            background: transparent;
            color: var(--ink);
            font: \(pointSize)px/1.55 -apple-system, system-ui, sans-serif;
            -webkit-text-size-adjust: none;
            overflow-wrap: break-word;
          }
          h1 { font-size: 1.5em; line-height: 1.25; margin: 0.4em 0 0.2em; }
          h2, h3, h4 { line-height: 1.3; margin: 1.4em 0 0.4em; }
          h2 { font-size: 1.25em; }
          h3, h4 { font-size: 1.1em; }
          p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
          p.meta { color: var(--quiet); font-size: 0.9em; margin-bottom: 1.4em; }
          /* Pictures are the reason this is a web view; letting one push the
             page sideways would undo that. */
          img { max-width: 100%; height: auto; display: block; margin: 1em auto; }
          figure { margin: 1em 0; }
          figcaption { color: var(--quiet); font-size: 0.88em; text-align: center; }
          blockquote {
            margin-left: 0; padding-left: 1em;
            border-left: 3px solid var(--rule); color: var(--quiet);
          }
          /* Code and tables scroll inside themselves rather than making the
             whole article scroll sideways. */
          pre { overflow-x: auto; font-size: 0.9em; }
          table { display: block; overflow-x: auto; border-collapse: collapse; }
          th, td { border: 1px solid var(--rule); padding: 0.4em 0.6em; text-align: left; }
          hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
          a { color: -apple-system-blue; }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}

@MainActor
final class ArticleTextModel: ObservableObject {
    /// An article ready to be shown.
    struct Article: Equatable {
        /// The article's own markup, or its paragraphs wrapped in some when
        /// only plain text could be recovered. One renderer either way: a
        /// second code path for the degraded case is a second thing to get
        /// wrong, in the case nobody looks at.
        let body: String
        /// How long the player will take to read it aloud, from the player's
        /// own estimate so the two never disagree.
        let spokenDuration: TimeInterval

        init(text: String, html: String?) {
            body = html?.isEmpty == false ? html! : Self.wrapped(text)
            spokenDuration = ArticleScript(text: text).duration
        }

        /// Plain paragraphs as the simplest possible article.
        private static func wrapped(_ text: String) -> String {
            text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "<p>\(escaped($0))</p>" }
                .joined()
        }
    }

    enum State {
        case loading
        case loaded(Article)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    /// True when the article on screen came from the cache rather than the
    /// network, so the view can say so — and warn that its pictures, which
    /// are still fetched from the web, will not be there.
    @Published private(set) var isOffline = false
    private let api: HearfulAPIProtocol
    private let cache: OfflineCache

    init(
        api: HearfulAPIProtocol = HearfulAPI(baseURL: AppConfiguration.apiBaseURL),
        cache: OfflineCache = .shared
    ) {
        self.api = api
        self.cache = cache
    }

    func load(episodeID: Int) async {
        do {
            let article = try await api.articleText(episodeID: episodeID)
            cache.save(article, for: .articleText(episodeID: episodeID))
            isOffline = false
            state = .loaded(Article(text: article.text, html: article.html))
        } catch {
            let message = (error as? APIError)?.spokenResponse ?? "Something went wrong."
            // Same rule as everywhere else: an expired session is the one
            // failure the cache must not paper over.
            if (error as? APIError)?.isAuthFailure != true,
                let cached = cache.load(EpisodeText.self, for: .articleText(episodeID: episodeID)),
                !cached.text.isEmpty
            {
                isOffline = true
                state = .loaded(Article(text: cached.text, html: cached.html))
            } else {
                isOffline = false
                state = .failed(message)
            }
        }
    }

    /// Text on its way into a document, so an article about `<script>` reads
    /// as one rather than becoming one.
    nonisolated static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
