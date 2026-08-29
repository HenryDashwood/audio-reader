import UIKit
import WebKit

/// The visible part of the reading position. It is a native view laid over
/// WebKit's scroll view, moves with the line it belongs to, and contributes
/// nothing extra to VoiceOver's element order.
@MainActor
final class ArticleReadingMarkerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// A small, native way back to the spoken word after the reader has chosen to
/// inspect another part of the article. It stays outside the scroll view, so
/// it remains available even when the marker itself is off screen.
@MainActor
final class ArticleReadingFollowButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        var appearance = UIButton.Configuration.filled()
        appearance.title = "Follow reading"
        appearance.image = UIImage(systemName: "scope")
        appearance.imagePadding = 8
        appearance.contentInsets = NSDirectionalEdgeInsets(
            top: 12, leading: 16, bottom: 12, trailing: 16)
        appearance.cornerStyle = .capsule
        configuration = appearance
        titleLabel?.adjustsFontForContentSizeCategory = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        accessibilityIdentifier = "article-follow-reading"
        accessibilityLabel = "Follow the reading position"
        accessibilityHint = "Returns to the current word and keeps it on screen"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// Keeps the return-to-reading control clear of the playback capsule while
/// the article chrome is visible. When the chrome leaves during a downward
/// read, the button settles back to the ordinary edge inset instead of
/// leaving a player-sized hole beneath it.
enum ArticleReadingFollowLayout {
    static let edgeInset: CGFloat = 12
    static let miniPlayerClearance: CGFloat = 12

    static func bottomConstraintConstant(
        chromeHidden: Bool,
        miniPlayerHeight: CGFloat,
        gap: CGFloat
    ) -> CGFloat {
        let obstruction = chromeHidden
            ? 0
            : miniPlayerHeight + gap + miniPlayerClearance
        return -(edgeInset + obstruction)
    }
}

/// Manual scrolling is an explicit choice to stop following. There is no
/// timeout: only the reader's next explicit Follow action changes it back.
struct ArticleReadingFollowState {
    private(set) var isFollowing = true

    mutating func userDidScroll(whileReading: Bool) {
        guard whileReading else { return }
        isFollowing = false
    }

    mutating func resume() {
        isFollowing = true
    }

    mutating func reset() {
        isFollowing = true
    }
}

/// Converts the rectangle returned by WebKit into the coordinate system of
/// the native marker added directly to the web view's scroll view.
///
/// DOM client rectangles do not include the scroll view's adjusted inset.
/// The article does: it begins below the floating navigation bar even though
/// the web view itself extends behind that bar. Omitting the inset therefore
/// draws the marker about one navigation bar above the word being spoken.
enum ArticleReadingMarkerLayout {
    static func visibleTop(
        domTop: CGFloat,
        adjustedContentInset: UIEdgeInsets
    ) -> CGFloat {
        domTop + adjustedContentInset.top
    }

    static func frame(
        domTop: CGFloat,
        height: CGFloat,
        contentOffset: CGPoint,
        adjustedContentInset: UIEdgeInsets
    ) -> CGRect {
        let lineHeight = max(height, 12)
        return CGRect(
            x: contentOffset.x + adjustedContentInset.left + 6,
            y: contentOffset.y
                + visibleTop(
                    domTop: domTop,
                    adjustedContentInset: adjustedContentInset)
                + (height - lineHeight) / 2,
            width: 4,
            height: lineHeight)
    }
}

/// An isolated, app-owned bridge between the exact plain text spoken by
/// AVSpeechSynthesizer and the same prose laid out as sanitised HTML.
///
/// The backend removes raw URLs from speech and turns formulae into MathML for
/// display, so character offsets cannot simply be applied to `body.textContent`.
/// The bridge tokenises both forms, aligns their common word runs in order,
/// and returns the DOM rectangle for a spoken UTF-16 range. Unmatched formula
/// words are allowed to have no marker; the next prose run resynchronises.
enum ArticleReadingMarkerScript {
    static let world = WKContentWorld.world(name: "HearfulArticleReadingMarker")

    /// Installs after navigation rather than as a WKUserScript: page scripting
    /// is disabled, while explicit app code in this isolated world remains
    /// available. Reinstalling on each navigation is intentional because a
    /// content world's variables belong to that one page.
    @MainActor
    static func install(in webView: WKWebView) async throws {
        _ = try await webView.evaluateJavaScript(source, in: nil, contentWorld: world)
    }

    static let source = #"""
        globalThis.hearfulArticleMarker = (() => {
          const wordSource = String.raw`[\p{L}\p{N}][\p{L}\p{N}\p{M}'’\u2010-\u2015-]*`;
          const words = () => new RegExp(wordSource, "gu");
          const segmenter = globalThis.Intl && Intl.Segmenter
            ? new Intl.Segmenter(undefined, { granularity: "word" })
            : null;

          const segments = text => {
            if (segmenter) {
              return Array.from(segmenter.segment(text))
                .filter(part => part.isWordLike)
                .map(part => ({ value: part.segment, index: part.index }));
            }
            return Array.from(text.matchAll(words()))
              .map(match => ({ value: match[0], index: match.index }));
          };

          const key = value => value
            .normalize("NFKD")
            .toLocaleLowerCase()
            .replace(/\p{M}/gu, "")
            .replace(/[’]/g, "'")
            .replace(/[\u2010-\u2015]/g, "-");

          const tokensInString = text => {
            const result = [];
            for (const part of segments(text)) {
              result.push({
                key: key(part.value),
                start: part.index,
                end: part.index + part.value.length
              });
            }
            return result;
          };

          const tokensInDocument = () => {
            const root = document.getElementById("hearful-article-body");
            if (!root) return [];
            const result = [];
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) {
              const parent = node.parentElement;
              if (!parent || parent.closest("script, style, math")) continue;
              const urlRanges = [];
              for (const url of node.data.matchAll(/https?:\/\/\S+/giu)) {
                urlRanges.push({ start: url.index, end: url.index + url[0].length });
              }
              for (const part of segments(node.data)) {
                if (urlRanges.some(url => part.index >= url.start && part.index < url.end)) continue;
                result.push({
                  key: key(part.value),
                  node,
                  start: part.index,
                  end: part.index + part.value.length
                });
              }
            }
            return result;
          };

          let speech = [];
          let visible = [];
          let mapping = [];

          const anchor = (speechIndex, visibleIndex) => {
            let best = null;
            const speechEnd = Math.min(speech.length, speechIndex + 64);
            const visibleEnd = Math.min(visible.length, visibleIndex + 256);
            for (let s = speechIndex; s < speechEnd; s += 1) {
              for (let v = visibleIndex; v < visibleEnd; v += 1) {
                if (speech[s].key !== visible[v].key) continue;
                let run = 1;
                while (run < 4 && s + run < speech.length && v + run < visible.length
                    && speech[s + run].key === visible[v + run].key) {
                  run += 1;
                }
                const candidate = { s, v, run, distance: s - speechIndex + v - visibleIndex };
                if (!best || candidate.run > best.run
                    || (candidate.run === best.run && candidate.distance < best.distance)) {
                  best = candidate;
                }
              }
            }
            return best;
          };

          const align = () => {
            mapping = new Array(speech.length).fill(null);
            let s = 0;
            let v = 0;
            while (s < speech.length && v < visible.length) {
              if (speech[s].key === visible[v].key) {
                mapping[s] = visible[v];
                s += 1;
                v += 1;
                continue;
              }
              const next = anchor(s, v);
              if (!next) {
                s += 1;
                continue;
              }
              s = next.s;
              v = next.v;
            }
          };

          const configure = text => {
            speech = tokensInString(text || "");
            visible = tokensInDocument();
            align();
            return mapping.reduce((count, token) => count + (token ? 1 : 0), 0);
          };

          const tokenForRange = (location, length) => {
            const end = location + Math.max(length, 1);
            let index = speech.findIndex(token => token.start < end && token.end > location);
            if (index < 0) index = speech.findIndex(token => token.start >= location);
            if (index < 0) index = speech.length - 1;
            if (index < 0) return null;
            if (mapping[index]) return mapping[index];
            for (let distance = 1; distance <= 12; distance += 1) {
              if (index - distance >= 0 && mapping[index - distance]) return mapping[index - distance];
              if (index + distance < mapping.length && mapping[index + distance]) return mapping[index + distance];
            }
            return null;
          };

          const rectForRange = (location, length) => {
            const token = tokenForRange(location, length);
            if (!token) return null;
            const range = document.createRange();
            range.setStart(token.node, token.start);
            range.setEnd(token.node, token.end);
            const rect = range.getClientRects()[0] || range.getBoundingClientRect();
            if (!rect || !Number.isFinite(rect.top)) return null;
            return { top: rect.top, height: rect.height };
          };

          return { configure, rectForRange };
        })();
        """#
}
