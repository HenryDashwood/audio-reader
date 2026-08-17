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
    /// The article's own scrolling, handed to the bars so they know what to
    /// get out of the way of. UIKit will hunt for a scroll view to track when
    /// it is not told, and it does not find this one: it belongs to a web
    /// view, three layers inside a representable, rather than to the screen.
    @State private var articleScroll: UIScrollView?
    @ObservedObject private var chrome = ArticleControlsModel.shared
    /// Not read directly — it is here so a change of text size redraws the
    /// page, since the web view is sized in points we hand it rather than by
    /// anything that scales on its own.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        // The article runs the whole height of the screen, under the back
        // button and the clock at one end and under the tab bar at the other,
        // rather than stopping dead against them. Prose that ends in a hard
        // line an inch above the bottom of the screen looks like a page torn
        // off; prose that slides under a pane of glass looks like a page.
        //
        // It is also what the bars themselves are waiting for. They shrink out
        // of the way of a scroll only while something is scrolling underneath
        // them, so this is the difference between bars that get out of the way
        // and bars that sit there.
        .ignoresSafeArea()
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
        // Listen and Original, in a capsule of their own directly above the
        // tab bar and exactly as wide, so the bar itself is the same on this
        // screen as on every other.
        .overlay(alignment: .bottom) { controlsCapsule }
        // The tab bar leaves and returns on the same word as the capsule above
        // it. It used to shrink to a pill on UIKit's own reckoning of the
        // scroll while the capsule went on ours, and two clocks meant two
        // answers: the capsule back and the bar still a pill, sitting over the
        // words underneath.
        .toolbarVisibility(chrome.hidden ? .hidden : .visible, for: .tabBar)
        // Both bars get out of the way when she scrolls, and the capsule with
        // them; and both are told what to watch, which is the web view.
        .background(ArticleChrome(tracking: articleScroll))
        .task { await model.load(episodeID: episode.id) }
    }

    /// Listen and Original, in a capsule the same length as the tab bar and
    /// sitting just above it — so the bar itself never changes shape, on this
    /// screen or any other.
    ///
    /// Bottom-aligned rather than placed at a measured height: this overlay's
    /// own bottom edge already stops at the top of the tab bar, so all that is
    /// needed is the gap between them. Only the width has to be measured.
    @ViewBuilder
    private var controlsCapsule: some View {
        if !chrome.hidden {
            ArticleControls(episode: episode)
                .frame(width: chrome.pillWidth ?? Self.fallbackWidth, height: Self.capsuleHeight)
                .glassEffect(in: .capsule)
                .padding(.bottom, Self.gap)
                // Sliding down and out rather than blinking away: the same
                // movement the tab bar underneath makes, at the same moment.
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private static let capsuleHeight: CGFloat = 52
    /// The space between the two capsules.
    private static let gap: CGFloat = 10
    /// Only used if the tab bar could not be measured, which would mean UIKit
    /// had rearranged itself under us. Controls of roughly the right size beat
    /// no controls at all.
    private static let fallbackWidth: CGFloat = 274

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
                    baseURL: episode.link,
                    scrolling: { articleScroll = $0 })
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

/// Where the reader's own controls should sit, and whether they should be
/// there at all.
///
/// A shared object rather than plain view state because both answers come from
/// UIKit — the tab bar's measurements and the web view's scrolling — which is
/// outside the SwiftUI tree that would otherwise carry them down.
@MainActor
final class ArticleControlsModel: ObservableObject {
    static let shared = ArticleControlsModel()

    /// How wide the tab bar's visible capsule is, so the controls above it can
    /// be cut to the same length. Nil when it could not be measured, which the
    /// reader answers with a width of its own.
    @Published var pillWidth: CGFloat?
    /// True while she is reading down the page, when the controls go the way
    /// of the two system bars.
    @Published var hidden = false
}

/// The bits of this screen's furniture that SwiftUI has no word for.
///
/// **All the furniture gets out of the way when she reads, together.** The
/// system will do a version of this on its own — `hidesBarsOnSwipe` for the
/// navigation bar, `tabBarMinimizeBehavior` for the tab bar — but each keeps
/// its own count of the scroll, and the capsule below keeps a third, so they
/// came and went at different moments: the controls back while the tab bar
/// was still a pill sitting over the words. So none of the system's versions
/// are used, and one reading of the scroll moves all three.
///
/// **The bars need telling what to watch.** UIKit hunts for a scroll view to
/// track when it is not told which one, and the one here is inside a web view
/// inside a representable, far enough off the path that the hunt comes back
/// empty — which is why the bars used to sit still through a whole article.
/// Naming it also hands UIKit the job of insetting the page clear of the bars
/// it now sits behind.
///
/// **And the controls need to know where the tab bar is.** Listen and Original
/// used to hang off the tab bar as a `UITabAccessory`, which meant the bar
/// grew wider on this screen than on every other — the system's own layout for
/// a bar carrying an accessory, and not ours to overrule. So they are drawn as
/// a capsule of our own instead, and this measures the bar underneath so the
/// two line up. `tabBar.frame` is the full width of the screen and would put
/// them off both ends; the visible capsule is the platter inside it.
private struct ArticleChrome: UIViewControllerRepresentable {
    /// The article's scrolling. Arrives a moment after the screen does, since
    /// the web view has to exist first.
    let tracking: UIScrollView?

    func makeUIViewController(context: Context) -> Chrome { Chrome() }

    func updateUIViewController(_ chrome: Chrome, context: Context) {
        chrome.track(tracking)
    }
}

private final class Chrome: UIViewController {
    private weak var tabs: UITabBarController?
    private weak var tracked: UIScrollView?
    private var named = false
    private var scrolling: NSKeyValueObservation?
    private var lastOffset: CGFloat = 0

    /// Name the article's scroll view to the bars at both ends of it, and
    /// watch it ourselves for the one thing UIKit will not do for us: taking
    /// our own capsule away while she is reading down the page.
    ///
    /// Called both when the scroll view turns up and when this screen does,
    /// since either can be second, and said once rather than on every redraw.
    func track(_ scrollView: UIScrollView?) {
        if let scrollView, scrollView !== tracked {
            tracked = scrollView
            named = false
            watch(scrollView)
        }
        guard !named, let tracked, let parent else { return }
        parent.setContentScrollView(tracked, for: .all)
        named = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let bar = tabBarController else { return }
        tabs = bar
        // Nothing of UIKit's own: neither the tab bar shrinking to a pill on
        // its reckoning of the scroll, nor `hidesBarsOnSwipe` on the
        // navigation bar. Both are good behaviour on their own and wrong
        // together, because each keeps its own time — so all three pieces of
        // furniture move on the one signal from `watch` below instead.
        bar.tabBarMinimizeBehavior = .never
        named = false
        track(nil)
        ArticleControlsModel.shared.hidden = false
        measureTabBar()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        measureTabBar()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // All of it undone: every other screen in the app wants its navigation
        // bar where it left it, and none of them want these two buttons.
        navigationController?.setNavigationBarHidden(false, animated: animated)
        parent?.setContentScrollView(nil, for: .all)
        scrolling = nil
        tracked = nil
        named = false
        tabs?.tabBarMinimizeBehavior = .never
        tabs = nil
        ArticleControlsModel.shared.pillWidth = nil
        ArticleControlsModel.shared.hidden = false
    }

    /// How wide the tab bar's visible capsule is, so the controls can be cut
    /// to the same length.
    private func measureTabBar() {
        guard let tabBar = tabs?.tabBar, let platter = tabBar.subviews.first else {
            ArticleControlsModel.shared.pillWidth = nil
            return
        }
        // A sanity check on a view we did not put there: anything that is not
        // plausibly the capsule leaves the controls to their own fallback,
        // rather than drawing them somewhere absurd.
        let frame = platter.frame
        guard frame.width > 120, frame.width <= tabBar.bounds.width, frame.height > 20 else {
            ArticleControlsModel.shared.pillWidth = nil
            return
        }
        ArticleControlsModel.shared.pillWidth = frame.width
    }

    /// The one signal the whole screen's furniture moves on: away while she
    /// reads down the page, back when she scrolls up. The navigation bar is
    /// told here, the tab bar and the capsule read it from the model, and so
    /// all three leave and return in the same moment.
    ///
    /// Nothing hides under VoiceOver. The gesture that brings the bars back is
    /// a scroll she has no reason to make when she is moving by element, and a
    /// back button that has gone with no obvious way to return it is worse
    /// than a screen with less room on it.
    private func watch(_ scrollView: UIScrollView) {
        guard !UIAccessibility.isVoiceOverRunning else { return }
        lastOffset = scrollView.contentOffset.y
        scrolling = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let offset = view.contentOffset.y
                let travelled = offset - self.lastOffset
                // Enough movement to be a scroll rather than a wobble, and far
                // enough down that the top of the article is not flickering.
                guard abs(travelled) > 6 else { return }
                self.lastOffset = offset
                let away = travelled > 0 && offset > 32
                guard ArticleControlsModel.shared.hidden != away else { return }
                self.navigationController?.setNavigationBarHidden(away, animated: true)
                withAnimation(.easeOut(duration: 0.25)) {
                    ArticleControlsModel.shared.hidden = away
                }
            }
        }
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

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if isCurrent {
                    player.toggle()
                } else {
                    try? player.play(episode)
                }
            } label: {
                // Half the capsule each, so the two sit at the centre of
                // their halves and the target is as big as the space allows.
                Label(
                    isPlaying ? "Pause" : "Listen",
                    systemImage: isPlaying ? "pause.fill" : "play.fill"
                )
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Listen")
            .accessibilityHint(
                isPlaying
                    ? "Stops reading this article aloud"
                    : "Reads this article aloud")

            if let link = episode.link {
                Link(destination: link) {
                    Label("Original", systemImage: "safari")
                        .frame(maxWidth: .infinity, minHeight: 44)
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
    /// Handed out so the bars above and below can be told what to track.
    let scrolling: (UIScrollView) -> Void

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
        // The page sits behind both bars, so its own content has to start and
        // stop clear of them — otherwise the first line is under the clock and
        // the last is under the tab bar for good.
        view.scrollView.contentInsetAdjustmentBehavior = .always
        // Out of the update pass: this is a value the enclosing view keeps,
        // and handing it over while that view is being built is a write in the
        // middle of a read.
        DispatchQueue.main.async { scrolling(view.scrollView) }
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
          /* Code, tables and formulas scroll inside themselves rather than
             making the whole article scroll sideways. */
          pre { overflow-x: auto; font-size: 0.9em; }
          /* Maths arrives as MathML, which WebKit sets itself in the article's
             own font. An equation on its own line comes in a box of its own,
             because WebKit will not scroll a <math> element however it is
             styled — it widens the article instead, and then every paragraph
             of it slides about under the thumb. */
          .formula {
            display: block;
            overflow-x: auto;
            overflow-y: hidden;
            margin: 1.2em 0;
          }
          /* Centred where it fits, and hard against the left edge where it
             does not, so a long equation is read from its beginning. */
          .formula > math { width: max-content; margin: 0 auto; }
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
