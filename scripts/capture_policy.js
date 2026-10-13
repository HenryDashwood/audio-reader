// One policy for Safari and Android. Platform exceptions require page evidence;
// individual publication domains never participate in access or URL decisions.
var MagpieCapturePolicy = {
    profiles: [
        {
            name: 'substack',
            matches: function (doc, url) {
                return url.hostname === 'substack.com' || url.hostname.endsWith('.substack.com')
                    || Array.from(doc.querySelectorAll('script[src]')).some(function (script) {
                        try {
                            var source = new URL(script.src, doc.baseURI);
                            return source.origin === 'https://substackcdn.com' && !source.username && !source.password
                                && source.pathname.startsWith('/bundle/static/js/');
                        } catch (_) { return false; }
                    });
            },
            navigationFlags: [['open', 'false'], ['triedRedirect', 'true']],
            articlePath: /^\/p\//,
            gates: '.paywall, .paywall-content, .subscription-widget-wrap[data-paywall]'
        },
        {
            name: 'ghost',
            matches: function (doc) {
                var generator = doc.querySelector('meta[name="generator"]');
                return Boolean(generator && /^Ghost(?:\s|$)/i.test(generator.content));
            },
            gates: '.gh-post-upgrade-cta, .single-content .single-cta'
        }
    ],
    profile: function (doc) {
        var url = new URL(doc.URL);
        return this.profiles.find(function (profile) { return profile.matches(doc, url); }) || null;
    },
    mediaWikiBody: function (doc) {
        var generator = doc.querySelector('meta[name="generator"]');
        if (!generator || !/^MediaWiki(?:\s|$)/i.test(generator.content)) return null;
        var bodies = doc.querySelectorAll('#mw-content-text.mw-parser-output, #mw-content-text .mw-parser-output');
        var headings = doc.querySelectorAll('h1');
        if (bodies.length !== 1 || headings.length !== 1) return null;
        var normalize = function (text) { return text.replace(/\s+/g, ' ').trim().toLowerCase(); };
        var heading = normalize(headings[0].textContent);
        var hints = [doc.title, (doc.querySelector('meta[property="og:title"]') || {}).content || ''];
        return heading && hints.some(function (hint) { return normalize(hint).includes(heading); }) ? bodies[0] : null;
    },
    expandableArticleSections: function (doc) {
        // MediaWiki's mobile section bodies are public disclosures. These
        // relationships distinguish them from hidden templates and menus.
        var body = this.mediaWikiBody(doc), sections = new Set();
        if (!body) return sections;
        body.querySelectorAll('.mw-heading').forEach(function (heading) {
            var section = heading.nextElementSibling;
            if (heading.querySelector('h2, h3, h4, h5, h6') && section
                && section.classList.contains('mf-collapsible-content')) {
                var control = heading.querySelector('.mf-collapsible-toggle[aria-controls]');
                if (!control || control.getAttribute('aria-controls') === section.id) sections.add(section);
            }
        });
        body.querySelectorAll('[id^="mf-section-"]').forEach(function (section) {
            var heading = section.previousElementSibling;
            if (/^mf-section-[1-9][0-9]*$/.test(section.id) && heading
                && /^H[2-6]$/.test(heading.tagName) && heading.classList.contains('section-heading')) sections.add(section);
        });
        return sections;
    },
    visible: function (node) {
        for (; node; node = node.parentElement) {
            var style = window.getComputedStyle(node);
            if (node.hidden || node.getAttribute('aria-hidden') === 'true' || style.display === 'none'
                || style.visibility === 'hidden' || style.visibility === 'collapse'
                || style.contentVisibility === 'hidden') return false;
        }
        return true;
    },
    identity: function (value, doc) {
        var url = new URL(value, doc.baseURI), current = new URL(doc.URL), profile = this.profile(doc);
        url.hash = '';
        Array.from(url.searchParams.keys()).forEach(function (key) {
            if (/^utm_|^(fbclid|gclid)$/.test(key)) url.searchParams.delete(key);
        });
        if (profile && profile.navigationFlags && url.origin === current.origin && profile.articlePath.test(url.pathname)) {
            profile.navigationFlags.forEach(function (flag) {
                var values = url.searchParams.getAll(flag[0]);
                if (values.length && values.every(function (value) { return value === flag[1]; })) url.searchParams.delete(flag[0]);
            });
        }
        return url.href;
    },
    // Only repair a rejected request after the server explicitly identifies this
    // exact repeated parameter. Never rewrite an unknown site's working URL.
    navigationRetry: function (doc, status) {
        if (status !== 400) return null;
        try {
            var url = new URL(doc.URL);
            if (url.protocol !== 'https:' || url.username || url.password) return null;
            var result = JSON.parse(doc.body.textContent);
            if (!Array.isArray(result.errors) || result.errors.length !== 1) return null;
            var error = result.errors[0], values = url.searchParams.getAll('open');
            if (error.location !== 'query' || error.param !== 'open' || error.msg !== 'Invalid value'
                || values.length < 2 || !values.every(function (value) { return value === 'false'; })
                || !Array.isArray(error.value) || error.value.length !== values.length
                || !error.value.every(function (value) { return value === 'false'; })) return null;
            var parts = url.search.slice(1).split('&'), kept = false;
            // Do not alter percent-encoded parameters or any signed value.
            if (parts.filter(function (part) { return part === 'open=false'; }).length !== values.length) return null;
            var query = parts.filter(function (part) {
                if (part !== 'open=false') return true;
                if (kept) return false;
                kept = true; return true;
            }).join('&');
            return doc.URL.split('?')[0] + '?' + query + url.hash;
        } catch (_) { return null; }
    },
    accessRequired: function (doc) {
        var self = this, profile = this.profile(doc);
        var action = 'a[href], button, input[type="email"], [data-portal]';
        if (profile && Array.from(doc.querySelectorAll(profile.gates)).some(function (gate) {
            return self.visible(gate) && Array.from(gate.querySelectorAll(action)).some(self.visible);
        })) return true;
        // Publisher-independent evidence: a visible access instruction plus an
        // action, inside article content or a blocking dialog. A footer's general
        // newsletter invitation and paid-article metadata alone are not gates.
        var scopes = 'article, main, [role="main"], [role="dialog"], [aria-modal="true"], [class*="paywall"], [data-testid*="paywall"]';
        // An explicit unlock action beneath the page's own heading is access
        // evidence even without semantic article/paragraph markup. Stop at the
        // next section heading so locked recommendations do not gate a readable
        // story. Headings inside links can be author/byline labels, not sections.
        var normalize = function (text) { return text.replace(/\s+/g, ' ').trim().toLowerCase(); };
        var hints = [doc.title, (doc.querySelector('meta[property="og:title"]') || {}).content || ''].map(normalize);
        var primary = false;
        if (Array.from(doc.querySelectorAll('h1, h2, h3, a[href], button')).some(function (node) {
            if (!self.visible(node) || node.closest('nav, aside, footer, blockquote, pre, code')) return false;
            var text = normalize(node.textContent);
            if (/^H[1-3]$/.test(node.tagName)) {
                if (node.closest('a[href]')) return false;
                primary = node.tagName === 'H1' && text.length >= 8 && hints.some(function (hint) { return hint.includes(text); });
                return false;
            }
            return primary && Boolean(node.closest(scopes))
                && /^(?:(?:join|subscribe|sign in|log in) to unlock(?: (?:this|the) (?:post|article))?|unlock (?:this (?:post|article)|with (?:a )?membership))$/.test(text);
        })) return true;
        var restriction = /(?:this (?:post|article|content) is (?:only )?for (?:paid |premium )?(?:subscribers|members)|(?:sign in|log in|subscribe|become a member|subscription required).{0,60}(?:to (?:continue reading|read (?:the (?:full|rest of)|this)|unlock)|full (?:article|access))|(?:continue reading|read the (?:full|rest of)).{0,60}(?:sign in|log in|subscrib))/i;
        return Array.from(doc.querySelectorAll('h1, h2, h3, p, [role="heading"]')).some(function (label) {
            var text = label.textContent.replace(/\s+/g, ' ').trim();
            if (text.length > 350 || !restriction.test(text) || !self.visible(label)
                || !label.closest(scopes) || label.closest('nav, aside, footer, blockquote, pre, code')) return false;
            var box = label.parentElement;
            if (!box || box.textContent.length > 2500) return false;
            return Array.from(box.querySelectorAll(action)).some(function (node) {
                return self.visible(node) && /sign.?in|log.?in|subscrib|membership|unlock/i.test(
                    node.textContent + ' ' + (node.getAttribute('href') || '') + ' ' + (node.getAttribute('data-portal') || ''));
            });
        });
    },
    archiveSnapshotMatches: function (document, canonical) {
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
            || declared.length !== 1 || this.identity(declared[0].content, document) !== this.identity(document.URL, document)) return false;
        var original = new URL(path[1]);
        return Boolean(original.hostname) && !original.username && !original.password;
    },
    socialAuthor: function (address) {
        var url = new URL(address), match = url.pathname.match(/^\/([A-Za-z0-9_]{1,15})\/status\/[0-9]+\/?$/);
        return ['x.com', 'www.x.com', 'twitter.com', 'www.twitter.com', 'mobile.twitter.com'].includes(url.hostname) && match ? match[1] : null;
    },
    // Bounded layout adapters are optional extraction overrides, separate from
    // access/identity policy. Unknown publishers always use general extraction.
    layout: function (address) {
        var url = new URL(address);
        if (['canarymedia.com', 'www.canarymedia.com'].includes(url.hostname) && url.pathname.startsWith('/articles/')) return 'split-prose';
        if (url.hostname === 'simonwillison.net' && /^\/\d{4}\/[A-Za-z]{3}\/\d{1,2}\/sighting-[0-9]+\/$/.test(url.pathname)) return 'illustrated-note';
        return null;
    }
};
