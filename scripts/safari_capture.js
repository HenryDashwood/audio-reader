// Safari runs this only for the page explicitly shared by the user.
// Bundled with pinned Mozilla Readability by build_safari_capture.py.
var ExtensionPreprocessingJS = {
    run: function (arguments) {
        var fallback = { url: document.URL, title: MagpieCapture.socialTitle(document.URL, document.title, '', null), html: '', preview: '' };
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
                if (node.tagName === 'IMG') MagpieCapture.normalizeImage(node, clones[index], document.baseURI);
                var style = window.getComputedStyle(node);
                if (node.hidden || node.getAttribute('aria-hidden') === 'true'
                    || style.display === 'none' || style.visibility === 'hidden'
                    || style.visibility === 'collapse' || style.contentVisibility === 'hidden') {
                    // Check the live tree before discarding styles. Do not use viewport
                    // intersection: paragraphs below the fold still belong to the article.
                    clones[index].remove();
                }
            });
            page.querySelectorAll('script, style, form, input, textarea, select, nav, aside').forEach(function (node) { node.remove(); });

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
            var articleTitles = page.querySelectorAll('[data-testid="twitterArticleTitle"]');
            var socialHeadline = articleTitles.length === 1 ? articleTitles[0].textContent.trim() : null;
            page.querySelectorAll('[href], [src], [srcset]').forEach(function (node) {
                ['href', 'src'].forEach(function (attribute) {
                    if (node.hasAttribute(attribute)) {
                        try { node.setAttribute(attribute, new URL(node.getAttribute(attribute), document.baseURI).href); } catch (_) {}
                    }
                });
                node.removeAttribute('srcset');
            });
            var publisher = MagpieCapture.publisherBody(page, document.URL);
            var evidence = MagpieCapture.paragraphs(candidates.length === 1 ? candidates[0] : []);
            var shortScopes = Array.from(page.querySelectorAll('article')).filter(function (node) {
                return !node.parentElement.closest('article') && prose([node]) >= 40;
            });
            var declaredArticle = document.querySelector('meta[property="og:type"][content="article"]');
            var shortIdentified = Boolean(canonical && declaredArticle && shortScopes.length === 1);
            if (!publisher && candidates.length === 0 && shortScopes.length > 1) throw new Error('Competing short articles');
            var shortProse = shortIdentified ? Array.from(shortScopes[0].querySelectorAll('p')).map(function (p) {
                return p.textContent.replace(/\s+/g, ' ').trim();
            }) : [];
            // Once a short illustrated body has explicit identity, preserve it:
            // prose scoring can discard its photo-only figure even at low limits.
            var selectedBody = publisher || (shortIdentified && prose(shortScopes) < 350
                && shortScopes[0].querySelector('img') ? shortScopes[0].cloneNode(true) : null);
            if (selectedBody) selectedBody.querySelectorAll('footer').forEach(function (node) { node.remove(); });
            var article = selectedBody ? { content: selectedBody.innerHTML, textContent: selectedBody.textContent,
                length: selectedBody.textContent.trim().length, title: document.title }
                : new Readability(page, { maxElemsToParse: 50000, charThreshold: 350, disableJSONLD: true }).parse();
            if (!article || (!publisher && article.length < 350 && !shortIdentified)) throw new Error('No article');
            var extracted = document.createElement('div');
            extracted.innerHTML = article.content;
            if (!extracted.textContent.trim() || (!publisher && MagpieCapture.missingProse(evidence, extracted))) throw new Error('Incomplete article');
            if (!publisher && shortIdentified) {
                var retained = extracted.textContent.replace(/\s+/g, ' ').trim();
                if (shortProse.some(function (p) { return p.length >= 40 && !retained.includes(p); })) throw new Error('Missing short article');
            }
            if (!publisher && article.length < 350 && (!extracted.querySelector('p')
                || extracted.textContent.trim().length < 40 || !extracted.querySelector('img, h1'))) throw new Error('Uncertain short article');
            var headings = extracted.querySelectorAll('h1');
            if (headings.length === 1) headline = headings[0].textContent.trim();
            var titleSource = MagpieCapture.socialAuthor(document.URL) ? document.title : (headline || article.title || document.title);
            var title = MagpieCapture.socialTitle(document.URL, titleSource.slice(0, 500),
                (extracted.querySelector('p') || extracted).textContent, socialHeadline || headline);
            // A single envelope carries identity, title and body together. The backend
            // sanitizes it without running a second competing extraction algorithm.
            var output = document.implementation.createHTMLDocument(title);
            var link = output.createElement('link');
            link.rel = 'canonical';
            link.href = document.URL;
            output.head.appendChild(link);
            // Readability strips the head. Carry only artwork declarations from the
            // original page, resolving relative URLs while its base URI is known.
            // The backend chooses and validates the image for this private snapshot.
            Array.from(document.head.querySelectorAll('meta, link')).filter(function (node) {
                var key = (node.getAttribute('property') || node.getAttribute('name') || '').toLowerCase();
                var rels = (node.getAttribute('rel') || '').toLowerCase().split(/\s+/);
                return node.tagName === 'META'
                    ? ['og:image', 'og:image:url', 'og:image:secure_url', 'twitter:image', 'twitter:image:src'].includes(key)
                    : rels.some(function (rel) { return rel === 'icon' || rel.startsWith('apple-touch-icon'); });
            }).slice(0, 32).forEach(function (node) {
                try {
                    var attribute = node.tagName === 'META' ? 'content' : 'href';
                    var value = node.getAttribute(attribute);
                    if (!value || value.length > 8192) return;
                    var image = new URL(value, document.baseURI);
                    if (!/^https?:$/.test(image.protocol) || image.username || image.password) return;
                    var metadata = output.createElement(node.tagName.toLowerCase());
                    ['property', 'name', 'rel', 'type', 'sizes'].forEach(function (name) {
                        if (node.hasAttribute(name)) metadata.setAttribute(name, node.getAttribute(name));
                    });
                    metadata.setAttribute(attribute, image.href);
                    output.head.appendChild(metadata);
                } catch (_) {}
            });
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
