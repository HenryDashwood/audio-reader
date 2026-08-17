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
/// Listening is still the first control on the page — but it now lives on the
/// tab bar rather than above the text. Two full-width buttons pinned over
/// every article cost a third of a phone screen on the one screen whose whole
/// job is to show as much prose as it can.
struct ArticleView: View {
    let episode: Episode
    @StateObject private var model = ArticleTextModel()
    /// Not read directly — it is here so a change of text size redraws the
    /// page, since the web view is sized in points we hand it rather than by
    /// anything that scales on its own.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        // The article runs to the top of the screen, under the back button
        // and the clock, rather than starting below a bar the width of the
        // phone. On a screen whose whole job is to hold prose, a strip of
        // empty chrome across the top is the most expensive thing on it.
        .ignoresSafeArea(edges: .top)
        // Which leaves the clock sitting on the first line of the article
        // once it has scrolled up. A band of the page's own colour, exactly as
        // tall as the status bar, keeps both readable without looking like a
        // second surface laid over the first.
        .overlay(alignment: .top) { statusBarScrim }
        // No title in the bar: it is the same sentence as the heading the
        // article opens with, a foot below it, and the article's own is the
        // one that belongs to the page.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // Listen and Original ride on the tab bar for as long as this screen
        // is up, and the back button gets out of the way when she scrolls.
        .background(ArticleChrome { ArticleControls(episode: episode) })
        .task { await model.load(episodeID: episode.id) }
    }

    private var statusBarScrim: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Color(.systemBackground))
                .frame(height: proxy.safeAreaInsets.top)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

    private func document(for article: ArticleTextModel.Article) -> String {
        ArticleDocument.page(
            body: ArticleDocument.header(
                title: episode.title, author: episode.author,
                publishedAt: episode.publishedAt) + article.body,
            pointSize: UIFont.preferredFont(forTextStyle: .body).pointSize)
    }
}

/// Whether the tab bar has shrunk out of the way of a scroll, and so whether
/// the controls sitting on it have room for their words.
///
/// A shared object rather than the environment because the controls hang off
/// the tab bar in UIKit, outside the SwiftUI tree that would otherwise carry
/// this down to them.
@MainActor
final class ArticleControlsModel: ObservableObject {
    static let shared = ArticleControlsModel()

    @Published var isInline = false
}

/// The two pieces of this screen's furniture that SwiftUI has no word for.
///
/// **Listen and Original ride on the tab bar.** SwiftUI's own
/// `tabViewBottomAccessory` puts them there, but it can only ever be given
/// different content — never taken away. Emptying it leaves the pill behind,
/// blank, floating over the episode list for the rest of the session, and
/// nothing said in SwiftUI takes it down: not an empty view, not a view of no
/// height, and removing the modifier rebuilds the whole tab view, which
/// destroys the navigation that opened the article in the first place.
///
/// So the accessory is hung and taken down here instead. It is a
/// `UITabBarController` underneath either way, and `bottomAccessory` is a
/// property that accepts nothing as readily as something: set on the way in,
/// cleared on the way out, every time, with no state in between to get stuck.
///
/// **The back button gets out of the way.** `hidesBarsOnSwipe` is the
/// system's own reading gesture — swipe up and the bar goes, swipe down and
/// it comes back — the same bargain the tab bar strikes at the other end of
/// the screen, and one every reading app on the phone has already taught her.
/// Off under VoiceOver, where it is driven by a pan of the finger that
/// VoiceOver never sends: the bar would go once and never come back.
private struct ArticleChrome<Content: View>: UIViewControllerRepresentable {
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> Chrome<Content> {
        Chrome(controls: content())
    }

    func updateUIViewController(_ chrome: Chrome<Content>, context: Context) {
        // Play/pause changes as the player ticks; the accessory is a live view
        // of it rather than a snapshot taken when the article opened.
        chrome.controls.rootView = content()
    }
}

private final class Chrome<Content: View>: UIViewController {
    let controls: UIHostingController<Content>
    private weak var tabs: UITabBarController?

    init(controls rootView: Content) {
        controls = UIHostingController(rootView: rootView)
        // The accessory sizes itself to what it holds, and paints no
        // background of its own — the pill behind it is the system's.
        controls.sizingOptions = [.intrinsicContentSize]
        controls.view.backgroundColor = .clear
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.hidesBarsOnSwipe = !UIAccessibility.isVoiceOverRunning
        guard let bar = tabBarController else { return }
        tabs = bar
        // Only while an article is open. Scrolling a page of prose is reading,
        // and the bar getting out of the way is welcome; scrolling a list of
        // episodes is looking for one, and having the way out of the list
        // shrink to a pill while she does it is not.
        bar.tabBarMinimizeBehavior = .onScrollDown
        // Whether the bar has shrunk to a pill is a UIKit trait rather than
        // anything SwiftUI publishes to a view it does not own, so it is read
        // from here and handed to the controls to lay themselves out by.
        controls.registerForTraitChanges([UITraitTabAccessoryEnvironment.self]) {
            (hosted: UIViewController, _) in
            ArticleControlsModel.shared.isInline =
                hosted.traitCollection.tabAccessoryEnvironment == .inline
        }
        bar.addChild(controls)
        bar.setBottomAccessory(UITabAccessory(contentView: controls.view), animated: true)
        controls.didMove(toParent: bar)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // All of it undone: every other screen in the app wants its navigation
        // bar where it left it, and none of them want these two buttons.
        navigationController?.hidesBarsOnSwipe = false
        navigationController?.setNavigationBarHidden(false, animated: animated)
        controls.willMove(toParent: nil)
        tabs?.tabBarMinimizeBehavior = .never
        tabs?.setBottomAccessory(nil, animated: true)
        controls.removeFromParent()
        tabs = nil
    }
}

/// Listen and Original, riding above the three tabs.
///
/// They were two large buttons above the text, which is a lot of screen to
/// give permanently to controls used once each. Down here they are always
/// within thumb's reach without costing the article anything — the same trade
/// the system's own accessory makes for the Music app's player.
///
/// The pill shrinks when the tab bar does, so this has two forms: the full one
/// with words on it, and a compact one of nothing but glyphs for when the tab
/// bar has collapsed out of the way of a scroll.
struct ArticleControls: View {
    let episode: Episode
    @ObservedObject private var player = PlaybackCoordinator.shared
    @ObservedObject private var chrome = ArticleControlsModel.shared

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if isCurrent {
                    player.toggle()
                } else {
                    try? player.play(episode)
                }
            } label: {
                if chrome.isInline {
                    // Half the pill each, rather than two glyphs huddled in
                    // the middle of it: the target is what she is aiming at,
                    // and there is no reason for it to be smaller than the
                    // space going spare.
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    Label(
                        isPlaying ? "Pause" : "Listen",
                        systemImage: isPlaying ? "pause.fill" : "play.fill"
                    )
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Listen")
            .accessibilityHint(
                isPlaying
                    ? "Stops reading this article aloud"
                    : "Reads this article aloud")

            if let link = episode.link {
                Link(destination: link) {
                    if chrome.isInline {
                        Image(systemName: "safari")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        // Half the bar each, so the two sit at the centre of
                        // their halves rather than one filling the bar and the
                        // other hanging off the end of it.
                        Label("Original", systemImage: "safari")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .accessibilityLabel("Open the original")
                .accessibilityHint("Opens the article's own page in your browser")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    private var isCurrent: Bool { player.currentEpisode?.id == episode.id }
    private var isPlaying: Bool { isCurrent && player.isPlaying }
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
    /// Everything above the first paragraph: the article's title, then who
    /// wrote it and when.
    ///
    /// Title and byline live in the document rather than in the bar above it,
    /// so they scroll away like the top of any article instead of sitting
    /// over it for the whole read — and so the title is said once rather than
    /// twice, an inch apart, which is what the navigation bar made of it.
    ///
    /// The byline used to end with how long the article would take to hear.
    /// That is a fact about the app rather than about the piece, and the
    /// scrubber says it the moment she starts listening anyway.
    static func header(title: String, author: String?, publishedAt: Date?) -> String {
        var header = "<h1>\(ArticleTextModel.escaped(title))</h1>"
        var meta: [String] = []
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            meta.append(ArticleTextModel.escaped(author))
        }
        // Most feeds name nobody, and a good few name nothing at all; the line
        // is then the half that exists, or is not there.
        if let publishedAt {
            meta.append(
                ArticleTextModel.escaped(
                    publishedAt.formatted(.dateTime.day().month(.wide).year())))
        }
        if !meta.isEmpty {
            header += "<p class=\"meta\">\(meta.joined(separator: " · "))</p>"
        }
        return header
    }

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

        init(text: String, html: String?) {
            body = html?.isEmpty == false ? html! : Self.wrapped(text)
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
