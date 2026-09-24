// Capture policy shared in behavior with backend page_capture.py/images.py.
// This runs on a clone; publisher scripts are never copied into saved articles.
var MagpieCapture = {
    webImage: function (value, base) {
        if (!value || !value.trim()) return null;
        try {
            var url = new URL(value.trim(), base);
            return /^https?:$/.test(url.protocol) && !url.username && !url.password ? url.href : null;
        } catch (_) { return null; }
    },
    srcsetImage: function (value, base) {
        var best = null, score = -1;
        var pattern = /(?:^|,\s*)(\S+)\s+(\d+(?:\.\d+)?)([wx])(?=\s*(?:,|$))/g;
        var match;
        while ((match = pattern.exec(value))) {
            var url = this.webImage(match[1], base);
            if (url && Number(match[2]) > score) { best = url; score = Number(match[2]); }
        }
        return best || (!/[\s,]/.test(value) ? this.webImage(value, base) : null);
    },
    normalizeImage: function (live, clone, base) {
        var self = this;
        var lazy = ['data-src', 'data-original', 'data-lazy-src'].map(function (key) {
            return self.webImage(live.getAttribute(key), base);
        }).find(Boolean);
        var source = this.webImage(live.currentSrc, base);
        // A loaded responsive source is authoritative, unless it is still a
        // one-pixel placeholder with an explicit lazy replacement.
        if (lazy && source === this.webImage(live.getAttribute('src'), base)
            && (!live.complete || live.naturalWidth <= 1)) source = null;
        source = source || lazy || this.srcsetImage(live.getAttribute('data-srcset') || '', base)
            || this.srcsetImage(live.getAttribute('srcset') || '', base);
        if (!source && live.parentElement.tagName === 'PICTURE') {
            Array.from(live.parentElement.querySelectorAll('source')).some(function (candidate) {
                if (candidate.media && !window.matchMedia(candidate.media).matches) return false;
                if (candidate.type && !/^image\/(avif|webp|png|jpeg|gif|svg\+xml)$/.test(candidate.type)) return false;
                source = self.srcsetImage(candidate.getAttribute('srcset') || candidate.getAttribute('data-srcset') || '', base);
                return Boolean(source);
            });
        }
        source = source || this.webImage(live.getAttribute('src'), base);
        if (source) clone.setAttribute('src', source);
        ['srcset', 'sizes', 'data-srcset', 'data-src', 'data-original', 'data-lazy-src', 'loading'].forEach(function (key) {
            clone.removeAttribute(key);
        });
    },
    publisherBody: function (page, address) {
        var url = new URL(address), body = page.createElement('article');
        if (['canarymedia.com', 'www.canarymedia.com'].includes(url.hostname) && url.pathname.startsWith('/articles/')) {
            var mains = page.querySelectorAll('main'), headings = page.querySelectorAll('main h1');
            if (mains.length !== 1 || headings.length !== 1) throw new Error('Uncertain publisher layout');
            var excluded = function (node) { return Boolean(node.closest('aside, nav, form, footer, article, .prose-sans')); };
            var prose = Array.from(mains[0].querySelectorAll('div.prose')).filter(function (node) {
                return !excluded(node) && node.querySelector('p, h2, h3, ul, ol, blockquote, pre, table');
            });
            var columns = new Set(prose.map(function (node) { return node.parentElement; }));
            if (!columns.size) throw new Error('Missing publisher body');
            body.appendChild(headings[0].cloneNode(true));
            var selected = new Set();
            mains[0].querySelectorAll('.prose, figure, img').forEach(function (node) {
                if (!['FIGURE', 'IMG'].includes(node.tagName) && !prose.includes(node)) return;
                var ancestors = [], parent = node.parentElement;
                while (parent) { ancestors.push(parent); parent = parent.parentElement; }
                if (!ancestors.some(function (a) { return columns.has(a); }) || excluded(node)
                    || ancestors.some(function (a) { return selected.has(a); })) return;
                if (node.tagName === 'FIGURE' && !node.querySelector('img, svg')) return;
                selected.add(node);
                var captured = node.cloneNode(true);
                if (node.tagName === 'IMG') {
                    var caption = node.parentElement.nextElementSibling;
                    if (caption && caption.tagName === 'DIV' && !caption.querySelector('p, img, svg, script, form')
                        && caption.textContent.trim().length > 0 && caption.textContent.trim().length <= 500) {
                        var figure = page.createElement('figure'), label = page.createElement('figcaption');
                        label.textContent = caption.textContent.trim();
                        figure.appendChild(captured); figure.appendChild(label); captured = figure;
                    }
                }
                body.appendChild(captured);
            });
            if (Array.from(body.querySelectorAll('p')).reduce(function (count, p) { return count + p.textContent.trim().length; }, 0) < 350) {
                throw new Error('Incomplete publisher body');
            }
        } else if (url.hostname === 'simonwillison.net' && /^\/\d{4}\/[A-Za-z]{3}\/\d{1,2}\/sighting-[0-9]+\/$/.test(url.pathname)) {
            var entries = page.querySelectorAll('div.entry.entryPage');
            if (entries.length !== 1) throw new Error('Uncertain sighting');
            var contents = entries[0].querySelectorAll('div.beat-content');
            if (contents.length !== 1) throw new Error('Missing sighting body');
            Array.from(contents[0].children).forEach(function (node) {
                if (node.localName === 'captioned-image-gallery' || node.classList.contains('beat-note')) body.appendChild(node.cloneNode(true));
            });
            if (!body.querySelector('img') || !Array.from(body.querySelectorAll('p')).some(function (p) { return p.textContent.trim(); })) {
                throw new Error('Incomplete sighting');
            }
        } else { return null; }
        body.querySelectorAll('script, style, form, nav, aside, footer, article, .prose-sans').forEach(function (node) { node.remove(); });
        if (['canarymedia.com', 'www.canarymedia.com'].includes(url.hostname)
            && Array.from(body.querySelectorAll('p')).reduce(function (count, p) { return count + p.textContent.trim().length; }, 0) < 350) {
            throw new Error('Incomplete publisher body');
        }
        return body;
    },
    socialAuthor: function (address) {
        var url = new URL(address);
        var match = url.pathname.match(/^\/([A-Za-z0-9_]{1,15})\/status\/[0-9]+\/?$/);
        return ['x.com', 'www.x.com', 'twitter.com', 'www.twitter.com', 'mobile.twitter.com'].includes(url.hostname) && match ? match[1] : null;
    },
    socialTitle: function (address, title, text, headline) {
        var author = this.socialAuthor(address);
        if (!author) return title;
        if (headline && !['post', 'thread', 'home', 'x', 'twitter'].includes(headline.trim().toLowerCase())) return headline.trim().slice(0, 500);
        var prefix = '@' + author + ': ';
        if (title.startsWith(prefix) && Array.from(title).length <= 100) return title;
        var quoted = title.match(/ on (?:X|Twitter):\s*["“]([\s\S]*)/);
        var opening = (quoted ? quoted[1] : text).replace(/https?:\/\/\S+/g, '').trim().split(/\n|(?<=[.!?])\s/)[0];
        opening = opening.replace(/\s+/g, ' ').replace(/^[ "“”]+|[ "“”]+$/g, '')
            .replace(/["”]\s*\/\s*(?:X|Twitter)$/, '').replace(/^[ "“”]+|[ "“”]+$/g, '');
        if (!opening) return 'Post by @' + author;
        var limit = 100 - prefix.length, characters = Array.from(opening);
        if (characters.length > limit) {
            var end = characters.slice(0, limit - 1).join('');
            if (!/\s/.test(characters[limit - 1]) && end.includes(' ')) end = end.slice(0, end.lastIndexOf(' '));
            opening = end.trimEnd() + '…';
        }
        return prefix + opening;
    },
    proseText: function (node) {
        var copy = node.cloneNode(true);
        copy.querySelectorAll('script, style, svg, iframe').forEach(function (media) { media.remove(); });
        return copy.textContent.replace(/\s+/g, ' ').trim();
    },
    paragraphs: function (nodes) {
        var self = this;
        var result = [];
        nodes.forEach(function (root) {
            root.querySelectorAll('p').forEach(function (p) {
                var parent = p;
                while (parent) {
                    if (['ASIDE', 'NAV', 'FORM', 'FOOTER'].includes(parent.tagName)
                        || /related|newsletter|comment|social|share|promo|author|footer/i.test((parent.getAttribute('class') || '') + ' ' + parent.id)
                        || /(?:^|\s)(?:sidebar(?:[-_]\S+)?|td-(?:ss-)?main-sidebar)(?:\s|$)/i.test((parent.getAttribute('class') || '') + ' ' + parent.id)) return;
                    parent = parent.parentElement;
                }
                var text = self.proseText(p);
                var linked = Array.from(p.querySelectorAll('a')).reduce(function (count, a) { return count + a.textContent.length; }, 0);
                if (text.length >= 80 && linked < text.length / 2) result.push(text);
            });
        });
        return result;
    },
    missingProse: function (paragraphs, body) {
        var text = this.proseText(body);
        var missing = paragraphs.filter(function (p) { return !text.includes(p); });
        return missing.length >= 2 || missing.some(function (p) { return p.length >= 160; });
    }
};
