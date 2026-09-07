import WebKit

/// Reconciles the reader's header with a headline already in captured HTML.
/// Runs in our isolated world, including for cached copies, with publisher
/// JavaScript disabled. The captured headline stays on the speech timeline.
@MainActor
enum ArticleHeadlineScript {
    static func add(to configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: source, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true, in: ArticleReadingMarkerScript.world))
    }

    private static let source = #"""
        (() => {
          const page = document.getElementById("hearful-page");
          const body = document.getElementById("hearful-article-body");
          const header = page?.querySelector(":scope > h1");
          const headline = body?.querySelector("h1, h2");
          if (!header || !headline) return;

          // Only the opening headline can replace the generated title. A
          // matching section heading later in the article must stay a section.
          const before = document.createRange();
          before.setStart(body, 0);
          before.setEndBefore(headline);
          if (before.cloneContents().textContent.trim()) return;

          const normalized = value => value.normalize("NFKC")
            .replace(/[\u2018\u2019]/g, "'")
            .replace(/[\u201C\u201D]/g, '"')
            .replace(/\s+/g, " ").trim().toLowerCase();
          const title = normalized(header.textContent);
          const heading = normalized(headline.textContent);
          if (!heading) return;
          // Browser document titles often append a publisher, e.g.
          // "Research acceleration: The view inside OpenAI | OpenAI".
          const suffix = title.slice(heading.length);
          const matches = title === heading ||
            (title.startsWith(heading) && /^\s+\|\s+\S/.test(suffix));
          if (!matches) return;

          let displayedHeadline = headline;
          if (headline.tagName !== "H1") {
            displayedHeadline = document.createElement("h1");
            for (const attribute of headline.attributes) {
              displayedHeadline.setAttribute(attribute.name, attribute.value);
            }
            while (headline.firstChild) displayedHeadline.append(headline.firstChild);
            headline.replaceWith(displayedHeadline);
          }
          const metadata = header.nextElementSibling;
          if (metadata?.matches("p.meta")) {
            // This line is reader metadata, not words in the captured speech.
            metadata.setAttribute("data-hearful-metadata", "");
            displayedHeadline.after(metadata);
          }
          header.remove();
        })();
        """#
}
