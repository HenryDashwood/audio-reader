// Safari runs this only for the page explicitly shared by the user.
var ExtensionPreprocessingJS = {
    run: function (arguments) {
        var page = document.documentElement.cloneNode(true);
        page.querySelectorAll('script, style, form, input, textarea, select, [hidden]').forEach(function (node) { node.remove(); });
        page.querySelectorAll('[href], [src]').forEach(function (node) {
            ['href', 'src'].forEach(function (attribute) {
                if (node.hasAttribute(attribute)) {
                    try { node.setAttribute(attribute, new URL(node.getAttribute(attribute), document.baseURI).href); } catch (_) {}
                }
            });
        });
        var html = page.outerHTML;
        // A large page still saves its link; never truncate it into a false full copy.
        arguments.completionFunction({ url: document.URL, title: document.title, html: html.length <= 500000 ? html : '' });
    }
};
