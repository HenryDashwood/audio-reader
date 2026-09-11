// Safari runs this only for the page explicitly shared by the user.
// Bundled with pinned Mozilla Readability by build_safari_capture.py.
var ExtensionPreprocessingJS = {
    run: function (arguments) {
        var fallback = { url: document.URL, title: document.title, html: '', preview: '' };
        try {
            function identity(value) {
                var url = new URL(value, document.baseURI);
                url.hash = '';
                Array.from(url.searchParams.keys()).forEach(function (key) {
                    if (/^utm_|^(fbclid|gclid)$/.test(key)) url.searchParams.delete(key);
                });
                return url.href;
            }
            function archiveSnapshotMatches(canonical) {
                var current = new URL(document.URL);
                var snapshot = new URL(canonical.href);
                // Archive snapshots declare a timestamped canonical and a short
                // og:url. Require that explicit short identity, not just the host:
                // a stale snapshot must not be captured under another short link.
                var hosts = ['archive.is', 'archive.today', 'archive.ph', 'archive.li',
                    'archive.vn', 'archive.fo', 'archive.md'];
                var declared = document.head.querySelectorAll('meta[property="og:url"]');
                var path = snapshot.pathname.match(/^\/(?:\d{4}\.\d{2}\.\d{2}-\d{6}|\d{14})\/(https?:\/\/.+)$/);
                if (!hosts.includes(current.hostname) || !/^https?:$/.test(current.protocol)
                    || current.username || current.password || current.port
                    || snapshot.origin !== current.origin || snapshot.username || snapshot.password
                    || !/^\/[A-Za-z0-9]{5}$/.test(current.pathname) || !path
                    || declared.length !== 1 || identity(declared[0].content) !== identity(document.URL)) return false;
                var original = new URL(path[1]);
                return Boolean(original.hostname) && !original.username && !original.password;
            }
            var canonical = document.querySelector('link[rel="canonical"]');
            // An in-page navigation can update the address before its body arrives.
            if (canonical && identity(canonical.href) !== identity(document.URL)
                && !archiveSnapshotMatches(canonical)) {
                arguments.completionFunction(fallback);
                return;
            }
            var page = document.cloneNode(true);
            var live = document.querySelectorAll('*');
            var clones = page.querySelectorAll('*');
            if (live.length > 50000) throw new Error('Page too complex');
            live.forEach(function (node, index) {
                var style = window.getComputedStyle(node);
                if (node.hidden || node.getAttribute('aria-hidden') === 'true'
                    || style.display === 'none' || style.visibility === 'hidden'
                    || style.visibility === 'collapse' || style.contentVisibility === 'hidden') {
                    // Check the live tree before discarding styles. Do not use viewport
                    // intersection: paragraphs below the fold still belong to the article.
                    clones[index].remove();
                }
            });
            page.querySelectorAll('script, style, form, input, textarea, select, iframe, nav, aside').forEach(function (node) { node.remove(); });

            // Publishers may split one story's heading/body/bio into separate articles
            // with a common ID (IEEE does this). Never choose solely by body length.
            var groups = new Map();
            page.querySelectorAll('article').forEach(function (node, index) {
                if (node.parentElement.closest('article')) return;
                var key = node.getAttribute('elid') || node.getAttribute('itemid')
                    || node.getAttribute('data-article-id') || 'node-' + index;
                if (!groups.has(key)) groups.set(key, []);
                groups.get(key).push(node);
            });
            function prose(nodes) {
                return nodes.reduce(function (sum, node) {
                    return sum + Array.from(node.querySelectorAll('p')).reduce(function (count, p) { return count + p.textContent.trim().length; }, 0);
                }, 0);
            }
            var candidates = Array.from(groups.values()).filter(function (nodes) { return prose(nodes) >= 350; });
            if (candidates.length > 1) {
                var words = function (text) { return text.toLowerCase().match(/[\p{L}\p{N}]+/gu) || []; };
                var hints = [document.title];
                var og = document.querySelector('meta[property="og:title"]');
                if (og) hints.push(og.content);
                var matches = candidates.filter(function (nodes) {
                    return nodes.some(function (node) {
                        return Array.from(node.querySelectorAll('h1')).some(function (heading) {
                            var tokens = words(heading.textContent);
                            return tokens.length >= 3 && hints.some(function (hint) {
                                var other = new Set(words(hint));
                                return tokens.filter(function (word) { return other.has(word); }).length / tokens.length >= 0.75;
                            });
                        });
                    });
                });
                if (matches.length !== 1) throw new Error('Multiple possible articles');
                candidates = matches;
            }
            var headline;
            if (candidates.length === 1) {
                var chosen = candidates[0];
                var heading = chosen.flatMap(function (node) { return Array.from(node.querySelectorAll('h1')); })[0];
                headline = heading && heading.textContent.trim();
                groups.forEach(function (nodes) {
                    if (nodes !== chosen) nodes.forEach(function (node) { node.remove(); });
                });
            }
            // Resolve URLs before parsing; a cloned document may lose its base URI.
            page.querySelectorAll('[href], [src], [srcset]').forEach(function (node) {
                ['href', 'src'].forEach(function (attribute) {
                    if (node.hasAttribute(attribute)) {
                        try { node.setAttribute(attribute, new URL(node.getAttribute(attribute), document.baseURI).href); } catch (_) {}
                    }
                });
                node.removeAttribute('srcset');
            });
            var article = new Readability(page, { maxElemsToParse: 50000, charThreshold: 350, disableJSONLD: true }).parse();
            if (!article || article.length < 350) throw new Error('No article');
            var title = (headline || article.title || document.title).slice(0, 500);
            // A single envelope carries identity, title and body together. The backend
            // sanitizes it without running a second competing extraction algorithm.
            var output = document.implementation.createHTMLDocument(title);
            var link = output.createElement('link');
            link.rel = 'canonical';
            link.href = document.URL;
            output.head.appendChild(link);
            var body = output.createElement('article');
            body.innerHTML = article.content;
            body.querySelectorAll('article').forEach(function (nested) {
                var section = output.createElement('div');
                while (nested.firstChild) section.appendChild(nested.firstChild);
                nested.replaceWith(section);
            });
            output.body.appendChild(body);
            var html = output.documentElement.outerHTML;
            if (html.length > 500000) throw new Error('Article too large');
            var paragraph = body.querySelector('p');
            var preview = (paragraph ? paragraph.textContent : article.textContent).replace(/\s+/g, ' ').trim().slice(0, 600);
            arguments.completionFunction({ url: document.URL, title: title, html: html, preview: preview, contentFormat: 'article' });
        } catch (_) {
            // An uncertain extraction keeps a link, never a truncated or competing body.
            arguments.completionFunction(fallback);
        }
    }
};
