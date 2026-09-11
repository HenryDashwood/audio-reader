import WebKit

/// Player scripts run only in remote frames; the article's CSP blocks publisher
/// scripts. The isolated app script adds an accessible escape if a video cannot
/// be embedded (offline, private, age restricted, or embedding disabled).
@MainActor
enum ArticleVideoScript {
    static var readerURL: URL {
        URL(string: "https://\(Bundle.main.bundleIdentifier ?? "com.henrydashwood.hearful")/reader/")!
    }

    static func add(to configuration: WKWebViewConfiguration) {
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: #"""
                    (() => {
                      document.querySelectorAll('iframe').forEach(frame => {
                        const fallback = document.createElement('p');
                        fallback.setAttribute('data-hearful-metadata', '');
                        const link = document.createElement('a');
                        const embed = new URL(frame.src);
                        const id = embed.pathname.split('/').pop();
                        if (embed.hostname === 'www.youtube-nocookie.com') {
                          link.href = 'https://www.youtube.com/watch?v=' + id;
                          const start = embed.searchParams.get('start');
                          if (start) link.href += '&t=' + start + 's';
                        } else if (embed.hostname === 'player.vimeo.com') {
                          link.href = 'https://vimeo.com/' + id;
                          const token = embed.searchParams.get('h');
                          if (token) link.href += '/' + token;
                        } else { return; }
                        link.textContent = 'Open video in browser';
                        fallback.append(link);
                        frame.after(fallback);
                      });
                    })();
                    """#,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                in: ArticleReadingMarkerScript.world))
    }
}
