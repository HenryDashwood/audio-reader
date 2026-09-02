import Combine
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
    /// Hands the newly available length back to whichever list opened the
    /// article. Its row otherwise keeps the older episode snapshot whose
    /// count was unknown before extraction.
    let learnedWordCount: (Int) -> Void
    @StateObject private var model = ArticleTextModel()
    /// The article's own scrolling, handed to the bars so they know what to
    /// get out of the way of. UIKit will hunt for a scroll view to track when
    /// it is not told, and it does not find this one: it belongs to a web
    /// view, three layers inside a representable, rather than to the screen.
    @State private var articleWebView: WKWebView?
    /// The feed page opened from the linked publication name in the byline.
    @State private var openFeed: PodcastResult?
    /// Not read directly — it is here so a change of text size redraws the
    /// page, since the web view is sized in points we hand it rather than by
    /// anything that scales on its own.
    @Environment(\.dynamicTypeSize) private var typeSize

    init(episode: Episode, learnedWordCount: @escaping (Int) -> Void = { _ in }) {
        self.episode = episode
        self.learnedWordCount = learnedWordCount
    }

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
        // No title in the bar: it is the same sentence as the heading the
        // article opens with, a foot below it, and the article's own is the
        // one that belongs to the page.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // Everything this page can do, in the corner it shares with the back
        // button — so it all leaves and returns together when she scrolls,
        // and the foot of the screen is left to the tab bar and whatever is
        // playing. Ordered outwards from the page's own business: listening
        // to it, leaving for it, looking through it, then asking for
        // something else entirely.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ArticlePlaybackButton(episode: episode)
            }
            if let link = episode.link {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: link) { Image(systemName: "safari") }
                        .accessibilityLabel("Open the original")
                        .accessibilityHint("Opens this page in your browser")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // WebKit's own find bar: it knows where the words are, and
                    // it highlights and steps through them without the page
                    // being handed any script of ours.
                    articleWebView?.findInteraction?.presentFindNavigator(showingReplace: false)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(articleWebView == nil)
                .accessibilityLabel("Find in this page")
                .accessibilityHint("Searches the words on this page")
            }
            ToolbarItem(placement: .topBarTrailing) { MicToolbarButton() }
        }
        // Both bars get out of the way when she scrolls, and the capsule with
        // them. Their views stay in the layout and fade rather than being
        // removed: changing the web view's automatic insets in the middle of
        // a drag is visible as a jump in the article.
        .background(ArticleChrome(tracking: articleWebView?.scrollView))
        .navigationDestination(item: $openFeed) { PodcastPreviewView(podcast: $0) }
        .task {
            if let wordCount = await model.load(episodeID: episode.id) {
                learnedWordCount(wordCount)
            }
        }
    }

    /// The gap between one piece of floating furniture and the next.
    static let gap: CGFloat = 10

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            Spacer()
            ProgressView("Loading the article…")
            Spacer()
        case .failed(let message):
            // A podcast episode usually has no article behind it, but it does
            // have the blurb the feed carries, and that is what she opened the
            // page to read. An error here would be the app reporting that the
            // episode is not the kind of thing it happens to be.
            if let blurb = episode.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                !blurb.isEmpty
            {
                ArticleWebView(
                    document: ArticleDocument.page(
                        body: ArticleDocument.header(
                            title: episode.title, feedTitle: episode.feedTitle,
                            feedURL: episode.feedURL,
                            publishedAt: episode.publishedAt)
                            + ArticleDocument.paragraphs(blurb),
                        pointSize: UIFont.preferredFont(forTextStyle: .body).pointSize),
                    baseURL: episode.link,
                    episodeID: episode.id,
                    speechText: nil,
                    openFeed: openContainingFeed,
                    ready: { articleWebView = $0 })
            } else {
                // The same sentence the player would have read out, shown
                // instead.
                ContentUnavailableView(
                    "Nothing to show for this episode", systemImage: "doc.questionmark",
                    description: Text(message))
            }
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
                    episodeID: episode.id,
                    speechText: article.text,
                    openFeed: openContainingFeed,
                    ready: { articleWebView = $0 })
            }
        }
    }

    private func document(for article: ArticleTextModel.Article) -> String {
        ArticleDocument.page(
            body: ArticleDocument.header(
                title: episode.title, feedTitle: episode.feedTitle,
                feedURL: episode.feedURL,
                publishedAt: episode.publishedAt)
                + ArticleDocument.articleBody(article.body),
            pointSize: UIFont.preferredFont(forTextStyle: .body).pointSize)
    }

    private func openContainingFeed() {
        guard let title = episode.feedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty,
            let feedURL = episode.feedURL
        else { return }
        openFeed = PodcastResult(
            title: title,
            feedURL: feedURL,
            publisher: nil,
            episodeCount: nil,
            artworkURL: episode.imageURL)
    }
}

/// Keeps the playback clock's frequent updates inside the one control that
/// needs them. The article and its web view do not redraw every time a podcast
/// advances, which matters most while the reader is under a moving finger.
private struct ArticlePlaybackButton: View {
    let episode: Episode
    @ObservedObject private var player = PlaybackCoordinator.shared

    private var isPlayingThis: Bool {
        player.currentEpisode?.id == episode.id && player.isPlaying
    }

    var body: some View {
        Button {
            if isPlayingThis { player.toggle() } else { player.playReportingFailure(episode) }
        } label: {
            Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
        }
        .accessibilityLabel(isPlayingThis ? "Pause" : "Listen")
        .accessibilityHint(isPlayingThis ? "Stops reading this aloud" : "Reads this aloud")
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

    /// True while she is reading down the page, when the controls go the way
    /// of the two system bars.
    @Published var hidden = false
}

/// Turns one finger gesture into at most one visibility change in each
/// direction. Tracking the gesture rather than `contentOffset` matters at the
/// ends of a page: a scroll view's rubber-band rebound changes its offset even
/// though the user has not reversed direction.
nonisolated struct ArticleChromeScrollTracker {
    private static let hideThreshold: CGFloat = 8
    /// Bringing controls back takes a more deliberate reversal than hiding
    /// them. A thumb wobbling during a long upward drag should not flash the
    /// furniture over the page again.
    private static let showThreshold: CGFloat = 24
    private static let topThreshold: CGFloat = 32

    private var directionAnchorY: CGFloat?
    private var hidden = false

    mutating func began(translationY: CGFloat, hidden: Bool) {
        directionAnchorY = translationY
        self.hidden = hidden
    }

    /// Returns a new hidden state only when the gesture actually crosses from
    /// one state to the other. Repeated callbacks in the same direction are
    /// deliberately silent, so SwiftUI does not restart the transition.
    mutating func changed(translationY: CGFloat, contentOffsetY: CGFloat) -> Bool? {
        guard let anchor = directionAnchorY else {
            directionAnchorY = translationY
            return nil
        }

        // Near the top, keep the controls available regardless of gesture
        // direction. Resetting the anchor here means the next downward read
        // is measured from where the article actually left its top.
        if contentOffsetY <= Self.topThreshold {
            directionAnchorY = translationY
            guard hidden else { return nil }
            hidden = false
            return false
        }

        let travelled = translationY - anchor
        if hidden {
            // Continuing to read down moves the anchor with the finger. Only a
            // genuine upward-scroll reversal can accumulate enough distance
            // to restore the controls.
            if travelled < 0 {
                directionAnchorY = translationY
                return nil
            }
            guard travelled >= Self.showThreshold else { return nil }
            hidden = false
            directionAnchorY = translationY
            return false
        }

        // The mirror while controls are visible: a downward finger movement
        // becomes the new high-water mark, so the upward reading distance is
        // measured from there rather than from the gesture's beginning.
        if travelled > 0 {
            directionAnchorY = translationY
            return nil
        }
        guard travelled <= -Self.hideThreshold else { return nil }
        hidden = true
        directionAnchorY = translationY
        return true
    }

    mutating func ended() {
        directionAnchorY = nil
    }
}

/// The shape of the tab bar, for the things that float above it.
///
/// Both the reader's controls and the mini player are capsules sitting over
/// the tab bar, and both want to be exactly as wide as it is. UIKit will not
/// say: `tabBar.frame` is the full width of the screen, and the capsule she
/// can actually see is the platter inside it. So it is measured, once, by
/// whichever screen is up.
@MainActor
final class TabBarMetrics: ObservableObject {
    static let shared = TabBarMetrics()

    /// The visible capsule's width. Nil when it could not be measured, which
    /// callers answer with a width of their own.
    @Published var pillWidth: CGFloat?
    /// Where the top of that capsule is, in the window's own terms.
    ///
    /// An absolute position rather than a gap, because the thing that needs it
    /// sits outside the tab bar's content and there is no reliable telling in
    /// advance where its own bottom edge falls — not the screen's edge, not
    /// the safe area's. Given both this and its own position it can work out
    /// the difference itself, which is the one sum that cannot be wrong.
    @Published var pillTop: CGFloat?

    /// Only used if the tab bar could not be measured, which would mean UIKit
    /// had rearranged itself under us. Furniture of roughly the right size
    /// beats furniture in the wrong place.
    static let fallbackWidth: CGFloat = 274

    /// A measurement that fails leaves the last good one standing.
    ///
    /// Nothing here is ever better off with no answer than with a slightly
    /// stale one: the tab bar does not move except on rotation, and a nil
    /// drops the mini player onto it. This used to happen on the way out of an
    /// article, when a last layout pass measured a tab bar the screen had
    /// already let go of and wrote the emptiness down.
    func measure(from tabBar: UITabBar?) {
        guard let tabBar, let platter = tabBar.subviews.first, tabBar.window != nil else {
            return
        }
        // A sanity check on a view we did not put there: anything that is not
        // plausibly the capsule is ignored, rather than moving the furniture
        // somewhere absurd.
        let frame = platter.frame
        guard frame.width > 120, frame.width <= tabBar.bounds.width, frame.height > 20 else {
            return
        }
        pillWidth = frame.width
        pillTop = tabBar.convert(frame, to: nil).minY
    }
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

    func makeUIViewController(context: Context) -> ArticleChromeController {
        ArticleChromeController()
    }

    func updateUIViewController(_ chrome: ArticleChromeController, context: Context) {
        chrome.track(tracking)
    }
}

final class ArticleChromeController: UIViewController {
    private weak var tabs: UITabBarController?
    private weak var navigation: UINavigationController?
    private weak var tracked: UIScrollView?
    private var named = false
    private weak var panGesture: UIPanGestureRecognizer?
    private var scrollTracker = ArticleChromeScrollTracker()

    /// Name the article's scroll view to the bars at both ends of it, and
    /// watch it ourselves for the one thing UIKit will not do for us: taking
    /// our own capsule away while she is reading down the page.
    ///
    /// Called both when the scroll view turns up and when this screen does,
    /// since either can be second, and said once rather than on every redraw.
    func track(_ scrollView: UIScrollView?) {
        if let scrollView, scrollView !== tracked {
            stopWatching()
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
        tabs = tabBarController ?? Self.findTabBarController(near: view)
        navigation = navigationController ?? Self.findNavigationController(containing: view)
        // Nothing of UIKit's own: neither the tab bar shrinking to a pill on
        // its reckoning of the scroll, nor `hidesBarsOnSwipe` on the
        // navigation bar. Both are good behaviour on their own and wrong
        // together, because each keeps its own time — so all three pieces of
        // furniture move on the one signal from `watch` below instead.
        tabs?.tabBarMinimizeBehavior = .never
        named = false
        track(nil)
        ArticleControlsModel.shared.hidden = false
        setBarsHidden(false, animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // All of it undone: every other screen in the app wants its navigation
        // bar where it left it, and none of them want these two buttons.
        setBarsHidden(false, animated: false)
        parent?.setContentScrollView(nil, for: .all)
        stopWatching()
        tracked = nil
        named = false
        tabs?.tabBarMinimizeBehavior = .never
        tabs = nil
        navigation = nil
        ArticleControlsModel.shared.hidden = false
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
        let gesture = scrollView.panGestureRecognizer
        gesture.addTarget(self, action: #selector(scrollGestureChanged(_:)))
        panGesture = gesture
    }

    private func stopWatching() {
        panGesture?.removeTarget(self, action: #selector(scrollGestureChanged(_:)))
        panGesture = nil
        scrollTracker.ended()
    }

    @objc private func scrollGestureChanged(_ gesture: UIPanGestureRecognizer) {
        guard let scrollView = tracked else { return }
        // The scroll view's bounds move under the finger, so measuring in its
        // coordinate space makes a steady drag look stationary or reversed.
        // The window does not move and gives the gesture a stable direction.
        let translationY = gesture.translation(in: scrollView.window).y
        switch gesture.state {
        case .began:
            scrollTracker.began(
                translationY: translationY,
                hidden: ArticleControlsModel.shared.hidden
            )
        case .changed:
            guard let hidden = scrollTracker.changed(
                translationY: translationY,
                contentOffsetY: scrollView.contentOffset.y
            ) else { return }
            setBarsHidden(hidden, animated: true)
            withAnimation(.easeOut(duration: 0.25)) {
                ArticleControlsModel.shared.hidden = hidden
            }
        default:
            // Deceleration and the rubber-band rebound happen after the pan
            // ends. Neither is a new request to replay the chrome animation.
            scrollTracker.ended()
        }
    }

    /// Fade the system bars without removing them from the hierarchy. Their
    /// safe-area contribution and the web view's adjusted content inset stay
    /// constant, so the words remain under the finger throughout the drag.
    func setBarsHidden(_ hidden: Bool, animated: Bool) {
        let bars: [UIView] = [navigation?.navigationBar, tabs?.tabBar].compactMap { $0 }
        for bar in bars {
            // Do not carry a second, independent hidden state in hit testing.
            // UIKit already excludes a view once its alpha is effectively
            // zero. Leaving interaction enabled means a control remains
            // tappable for as long as it remains visible during the fade —
            // and, crucially, cannot be redrawn visible while still disabled.
            bar.accessibilityElementsHidden = hidden
        }
        let changes = {
            for bar in bars { bar.alpha = hidden ? 0 : 1 }
        }
        guard animated else {
            changes()
            return
        }
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
            animations: changes)
    }

    /// Background representables are not always parented directly inside the
    /// tab/navigation controller, so the convenience properties can be nil.
    /// Resolve the visible containers through the window as a fallback.
    private static func findTabBarController(near view: UIView) -> UITabBarController? {
        guard let root = view.window?.rootViewController else { return nil }
        return findTabBarController(in: root)
    }

    private static func findTabBarController(
        in controller: UIViewController
    ) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let found = findTabBarController(in: child) { return found }
        }
        if let presented = controller.presentedViewController {
            return findTabBarController(in: presented)
        }
        return nil
    }

    private static func findNavigationController(
        containing view: UIView
    ) -> UINavigationController? {
        guard let root = view.window?.rootViewController else { return nil }
        return findNavigationController(in: root, containing: view)
    }

    private static func findNavigationController(
        in controller: UIViewController, containing view: UIView
    ) -> UINavigationController? {
        if let navigation = controller as? UINavigationController,
            view.isDescendant(of: navigation.view)
        {
            return navigation
        }
        for child in controller.children {
            if let found = findNavigationController(in: child, containing: view) { return found }
        }
        if let presented = controller.presentedViewController {
            return findNavigationController(in: presented, containing: view)
        }
        return nil
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
    let episodeID: Int
    /// The exact plain text handed to AVSpeechSynthesizer. Nil for a fallback
    /// blurb that is visible but is not this article player's script.
    let speechText: String?
    /// Opens the containing podcast or blog inside Magpie. All other links
    /// still leave for Safari.
    let openFeed: @MainActor () -> Void
    /// Handed out so the bars can be told what to track, and so the toolbar
    /// has something to ask for a find bar.
    let ready: (WKWebView) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // Article images still come from their publishers, but cookies and
        // other website data must not become a lasting browsing profile inside
        // a podcast app.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // The page paints no background of its own, so the app's shows
        // through and the article is the right colour in both appearances
        // without the web view having to be told which one it is in.
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        // WKWebView locks a drag to its initially detected axis; SwiftUI's
        // lists do not. An article is vertically scrollable too, so keeping
        // that lock only adds a small hesitation before the page follows a
        // changing finger direction.
        view.scrollView.isDirectionalLockEnabled = false
        configureScrollIndicator(
            on: view.scrollView,
            colorScheme: context.environment.colorScheme)
        // The page sits behind both bars, so its own content has to start and
        // stop clear of them — otherwise the first line is under the clock and
        // the last is under the tab bar for good.
        view.scrollView.contentInsetAdjustmentBehavior = .always
        // Out of the update pass: this is a value the enclosing view keeps,
        // and handing it over while that view is being built is a write in the
        // middle of a read.
        // WebKit's own find bar, which needs no script from us.
        view.isFindInteractionEnabled = true
        context.coordinator.attach(to: view, episodeID: episodeID, speechText: speechText)
        DispatchQueue.main.async { ready(view) }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        updateScrollIndicatorStyle(
            on: view.scrollView,
            colorScheme: context.environment.colorScheme)
        let documentChanged = context.coordinator.loaded != document
        context.coordinator.update(
            episodeID: episodeID,
            speechText: speechText,
            pageWillReload: documentChanged)
        // Reloading throws away the scroll position, so only when the page
        // has actually changed — which it does on a text-size change, and
        // otherwise on every redraw the player causes by ticking.
        guard documentChanged else { return }
        context.coordinator.loaded = document
        view.loadHTMLString(document, baseURL: baseURL)
    }

    /// WKWebView's default indicator is dark even when its transparent page
    /// sits over the app's dark background. Match SwiftUI lists by keeping the
    /// native indicator enabled and choosing a contrasting style explicitly.
    ///
    /// The article content still follows the safe areas, but the indicator
    /// has one fixed track. If UIKit adjusts that track for the floating bars,
    /// its thumb jumps whenever their controls fade in or out even though the
    /// content offset has not moved.
    private func configureScrollIndicator(on scrollView: UIScrollView, colorScheme: ColorScheme) {
        scrollView.showsVerticalScrollIndicator = true
        scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(
            top: 8, left: 0, bottom: 8, right: 2)
        updateScrollIndicatorStyle(on: scrollView, colorScheme: colorScheme)
    }

    /// Appearance can change while this view is alive. The indicator's
    /// geometry cannot: writing its insets again while a chrome transition
    /// redraws the representable makes the thumb recalculate in mid-drag.
    private func updateScrollIndicatorStyle(
        on scrollView: UIScrollView,
        colorScheme: ColorScheme
    ) {
        let style: UIScrollView.IndicatorStyle = colorScheme == .dark ? .white : .black
        guard scrollView.indicatorStyle != style else { return }
        scrollView.indicatorStyle = style
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.detach(from: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(openFeed: openFeed) }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        let openFeed: @MainActor () -> Void
        private weak var webView: WKWebView?
        private var spokenLocation: ArticleSpokenLocation?
        private var markerSubscription: AnyCancellable?
        private var episodeID = 0
        private var speechText: String?
        private var pageIsReady = false
        private var navigationGeneration = 0
        private var followState = ArticleReadingFollowState()
        private let marker = ArticleReadingMarkerView()
        private let followButton = ArticleReadingFollowButton()
        private var followBottomConstraint: NSLayoutConstraint?
        private var chromeSubscription: AnyCancellable?

        init(openFeed: @escaping @MainActor () -> Void) {
            self.openFeed = openFeed
        }

        func attach(to view: WKWebView, episodeID: Int, speechText: String?) {
            webView = view
            self.episodeID = episodeID
            self.speechText = speechText
            marker.alpha = 0
            view.scrollView.addSubview(marker)
            followButton.translatesAutoresizingMaskIntoConstraints = false
            followButton.isHidden = true
            view.addSubview(followButton)
            let followBottomConstraint = followButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: ArticleReadingFollowLayout.bottomConstraintConstant(
                    chromeHidden: ArticleControlsModel.shared.hidden,
                    miniPlayerHeight: MiniPlayer.height,
                    gap: ArticleView.gap))
            self.followBottomConstraint = followBottomConstraint
            NSLayoutConstraint.activate([
                followButton.trailingAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                    constant: -12),
                followBottomConstraint,
            ])
            followButton.addTarget(
                self, action: #selector(resumeFollowing), for: .touchUpInside)
            view.scrollView.panGestureRecognizer.addTarget(
                self, action: #selector(scrollGestureChanged(_:)))
            markerSubscription = ArticlePlayer.shared.$spokenLocation
                .removeDuplicates()
                .sink { [weak self] location in self?.receive(location) }
            chromeSubscription = ArticleControlsModel.shared.$hidden
                .removeDuplicates()
                .sink { [weak self] hidden in
                    self?.positionFollowButton(chromeHidden: hidden, animated: true)
                }
        }

        func update(episodeID: Int, speechText: String?, pageWillReload: Bool) {
            let episodeChanged = self.episodeID != episodeID
            let contentChanged = episodeChanged || self.speechText != speechText
            self.episodeID = episodeID
            self.speechText = speechText
            if episodeChanged {
                followState.reset()
                followButton.isHidden = true
            }
            if pageWillReload {
                navigationGeneration += 1
                pageIsReady = false
                marker.alpha = 0
                followButton.isHidden = true
                return
            }
            guard contentChanged else { return }
            marker.alpha = 0
            if pageIsReady { configureMarker() }
        }

        func detach(from view: WKWebView) {
            view.scrollView.panGestureRecognizer.removeTarget(
                self, action: #selector(scrollGestureChanged(_:)))
            markerSubscription = nil
            chromeSubscription = nil
            marker.removeFromSuperview()
            followButton.removeTarget(
                self, action: #selector(resumeFollowing), for: .touchUpInside)
            followButton.removeFromSuperview()
            followBottomConstraint = nil
            webView = nil
        }

        private func positionFollowButton(chromeHidden: Bool, animated: Bool) {
            guard let webView, let followBottomConstraint else { return }
            let constant = ArticleReadingFollowLayout.bottomConstraintConstant(
                chromeHidden: chromeHidden,
                miniPlayerHeight: MiniPlayer.height,
                gap: ArticleView.gap)
            guard followBottomConstraint.constant != constant else { return }
            webView.layoutIfNeeded()
            followBottomConstraint.constant = constant
            let changes = { webView.layoutIfNeeded() }
            guard animated, !UIAccessibility.isReduceMotionEnabled else {
                changes()
                return
            }
            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
                animations: changes)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageIsReady = true
            // Reveal the affordance once when an article opens; after that it
            // behaves like every native list indicator and appears on scroll.
            webView.scrollView.flashScrollIndicators()
            configureMarker()
        }

        private func configureMarker() {
            guard pageIsReady, let webView, let speechText else { return }
            let generation = navigationGeneration
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    // The page remains unable to run scripts. This app-owned
                    // bridge is explicitly installed in an isolated world.
                    try await ArticleReadingMarkerScript.install(in: webView)
                    guard self.pageIsReady, self.navigationGeneration == generation else { return }
                    _ = try await webView.callAsyncJavaScript(
                        "return globalThis.hearfulArticleMarker.configure(text);",
                        arguments: ["text": speechText],
                        in: nil,
                        contentWorld: ArticleReadingMarkerScript.world)
                    guard self.pageIsReady, self.navigationGeneration == generation else { return }
                    show(self.spokenLocation)
                } catch {
                    // A visual aid must never make the readable article fail.
                    if self.navigationGeneration == generation { marker.alpha = 0 }
                }
            }
        }

        private func receive(_ location: ArticleSpokenLocation?) {
            spokenLocation = location
            show(location)
        }

        private func show(
            _ location: ArticleSpokenLocation?,
            forceFollow: Bool = false
        ) {
            guard pageIsReady, location?.episodeID == episodeID,
                let location, let webView, speechText != nil
            else {
                marker.alpha = 0
                followButton.isHidden = true
                return
            }
            let range = location.rangeInArticle
            let generation = navigationGeneration
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    let result = try await webView.callAsyncJavaScript(
                        "return globalThis.hearfulArticleMarker.rectForRange(location, length);",
                        arguments: ["location": range.location, "length": range.length],
                        in: nil,
                        contentWorld: ArticleReadingMarkerScript.world)
                    guard location == self.spokenLocation,
                        self.pageIsReady, self.navigationGeneration == generation
                    else { return }
                    guard let values = result as? [String: Any],
                        let top = (values["top"] as? NSNumber)?.doubleValue,
                        let height = (values["height"] as? NSNumber)?.doubleValue
                    else {
                        self.marker.alpha = 0
                        return
                    }
                    self.placeMarker(
                        top: CGFloat(top),
                        height: CGFloat(height),
                        forceFollow: forceFollow,
                        in: webView)
                } catch {
                    if self.navigationGeneration == generation { marker.alpha = 0 }
                }
            }
        }

        private func placeMarker(
            top: CGFloat,
            height: CGFloat,
            forceFollow: Bool,
            in webView: WKWebView
        ) {
            let scrollView = webView.scrollView
            scrollView.bringSubviewToFront(marker)
            webView.bringSubviewToFront(followButton)
            marker.backgroundColor = webView.tintColor
            let visibleTop = ArticleReadingMarkerLayout.visibleTop(
                domTop: top,
                adjustedContentInset: scrollView.adjustedContentInset)
            let frame = ArticleReadingMarkerLayout.frame(
                domTop: top,
                height: height,
                contentOffset: scrollView.contentOffset,
                adjustedContentInset: scrollView.adjustedContentInset)
            let changes = {
                self.marker.frame = frame
                self.marker.layer.cornerRadius = 2
                self.marker.alpha = 1
            }
            if UIAccessibility.isReduceMotionEnabled {
                changes()
            } else {
                UIView.animate(
                    withDuration: 0.2,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
                    animations: changes)
            }

            followButton.isHidden = followState.isFollowing

            guard (forceFollow || followState.isFollowing),
                (forceFollow || !UIAccessibility.isVoiceOverRunning),
                (forceFollow || (!scrollView.isDragging && !scrollView.isDecelerating))
            else { return }
            let upperBand = max(webView.safeAreaInsets.top + 64, webView.bounds.height * 0.2)
            let lowerBand = webView.bounds.height * 0.72
            guard forceFollow || visibleTop < upperBand || visibleTop + height > lowerBand
            else { return }
            let minimumY = -scrollView.adjustedContentInset.top
            let maximumY = max(
                minimumY,
                scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom)
            let wordY = scrollView.contentOffset.y + visibleTop
            let targetY = min(max(wordY - webView.bounds.height * 0.34, minimumY), maximumY)
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: targetY),
                animated: !UIAccessibility.isReduceMotionEnabled)
        }

        @objc private func scrollGestureChanged(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .changed,
                abs(gesture.translation(in: gesture.view).y) >= 8,
                !UIAccessibility.isVoiceOverRunning,
                spokenLocation?.episodeID == episodeID,
                marker.alpha > 0
            else { return }
            // A deliberate scroll stays detached. Nothing silently starts
            // pulling the page again after an arbitrary timeout.
            followState.userDidScroll(whileReading: true)
            followButton.isHidden = false
            webView?.bringSubviewToFront(followButton)
        }

        @objc private func resumeFollowing() {
            followState.resume()
            followButton.isHidden = true
            show(spokenLocation, forceFollow: true)
        }

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
            if url.scheme == "hearful", url.host() == "feed" {
                openFeed()
            } else {
                UIApplication.shared.open(url)
            }
        }
    }
}

/// The page the article is rendered into.
enum ArticleDocument {
    /// Everything above the first paragraph: the article's title, then the
    /// podcast or publication it belongs to and when it was published.
    ///
    /// Title and byline live in the document rather than in the bar above it,
    /// so they scroll away like the top of any article instead of sitting
    /// over it for the whole read — and so the title is said once rather than
    /// twice, an inch apart, which is what the navigation bar made of it.
    ///
    /// The byline used to end with how long the article would take to hear.
    /// That is a fact about the app rather than about the piece, and the
    /// scrubber says it the moment she starts listening anyway.
    static func header(
        title: String, feedTitle: String?, feedURL: URL?, publishedAt: Date?
    ) -> String {
        var header = "<h1>\(ArticleTextModel.escaped(title))</h1>"
        var meta: [String] = []
        if let feedTitle = feedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !feedTitle.isEmpty
        {
            let name = ArticleTextModel.escaped(feedTitle)
            meta.append(feedURL == nil ? name : "<a href=\"hearful://feed\">\(name)</a>")
        }
        // Cached items from an older backend may not name their feed; the line
        // is then the date alone, or is not there.
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

    /// Plain text as paragraphs — a feed's blurb, which arrives as prose
    /// rather than markup.
    static func paragraphs(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "<p>\(ArticleTextModel.escaped($0))</p>" }
            .joined()
    }

    /// Separates prose that is actually spoken from the title and byline above
    /// it. The marker bridge never has to guess whether those extra visible
    /// words belong to the speech timeline.
    static func articleBody(_ body: String) -> String {
        "<main id=\"hearful-article-body\">\(body)</main>"
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
          /* Whatever an article turns out to contain, the page itself never
             scrolls sideways. Code, tables and formulas scroll inside their
             own boxes below; anything else too wide for the phone is cut off
             at the edge, which loses the end of one line rather than letting
             every paragraph slide about under the thumb. A box of its own
             rather than a rule on the body, because iOS WebKit pans the page
             regardless of what the body says about its overflow. */
          #hearful-page { overflow-x: clip; }
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
        <body><div id="hearful-page">\(body)</div></body>
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
        /// The exact companion used for speech and for locating the native
        /// reading marker among the HTML's visible words.
        let text: String

        init(text: String, html: String?) {
            self.text = text
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
        api: HearfulAPIProtocol = HearfulAPI(),
        cache: OfflineCache = .shared
    ) {
        self.api = api
        self.cache = cache
    }

    @discardableResult
    func load(episodeID: Int) async -> Int? {
        do {
            let article = try await api.articleText(episodeID: episodeID)
            cache.save(article, for: .articleText(episodeID: episodeID))
            isOffline = false
            state = .loaded(Article(text: article.text, html: article.html))
            return article.wordCount
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
                return cached.wordCount
            } else {
                isOffline = false
                state = .failed(message)
                return nil
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
