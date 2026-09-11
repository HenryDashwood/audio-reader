package com.henrydashwood.magpie.data

/** Original, bundled example of the same HTML/MathML representation supplied by the backend. */
object RichArticleSample {
    val item = LibraryItem(
        id = "rich-reading", source = "Field notes", title = "Reading beyond plain text",
        description = "A small field guide to pictures, quotations, code and equations.",
        kind = ContentKind.Article, durationLabel = "2 min read",
        text = """An article can carry more than words. A picture, a quotation or a small equation can make an idea easier to understand.

            |A closer look

            |The Magpie mark has a cream outline and a bright blue tail. Its caption belongs with the image.

            |Words worth keeping

            |Leave enough room in the day to notice something new.

            |Small instructions

            |Read a little. Pause to think. Keep what matters.

            |A little code

            |The example defines a greeting function and returns the words Hello, reader. Code keeps its indentation and can scroll sideways.

            |Thinking in symbols

            |An inline equation says that x squared plus y squared equals z squared. The displayed equation defines the average as the sum of n values divided by n.

            |A simple comparison

            |Pictures help us notice. Quotations help us remember. Equations help us describe a relationship precisely.

            |The end of the field guide. You can find words in this page or listen to its separate spoken text.""".trimMargin(),
        html = """
            <p>An article can carry <strong>more than words</strong>. A picture, a quotation or a small equation can make an idea <em>easier to understand</em>.</p>
            <h2>A closer look</h2>
            <figure><img src="https://magpie.invalid/assets/magpie.png" width="240" alt="A magpie with a cream outline and a bright blue tail">
            <figcaption>The Magpie mark, with its bright blue tail.</figcaption></figure>
            <h2>Words worth keeping</h2>
            <blockquote><p>Leave enough room in the day to notice something new.</p></blockquote>
            <h2>Small instructions</h2>
            <ol><li>Read a little.</li><li>Pause to think.</li><li>Keep what matters.</li></ol>
            <h2>A little code</h2>
            <p>Inline code, such as <code>greet("reader")</code>, stays distinct from prose.</p>
            <pre><code>fun greet(name: String): String {
                return "Hello, ${'$'}name. Leave enough room in the day to notice something new."
            }</code></pre>
            <h2>Thinking in symbols</h2>
            <p>An inline equation: <math xmlns="http://www.w3.org/1998/Math/MathML"><msup><mi>x</mi><mn>2</mn></msup><mo>+</mo><msup><mi>y</mi><mn>2</mn></msup><mo>=</mo><msup><mi>z</mi><mn>2</mn></msup></math>.</p>
            <math xmlns="http://www.w3.org/1998/Math/MathML" display="block"><mrow><mover><mi>x</mi><mo>¯</mo></mover><mo>=</mo><mfrac><mn>1</mn><mi>n</mi></mfrac><munderover><mo>∑</mo><mrow><mi>i</mi><mo>=</mo><mn>1</mn></mrow><mi>n</mi></munderover><msub><mi>x</mi><mi>i</mi></msub></mrow></math>
            <h2>A simple comparison</h2>
            <table><caption>Ways to explain an idea</caption><thead><tr><th scope="col">Format</th><th scope="col">What it helps us do</th></tr></thead>
            <tbody><tr><th scope="row">Pictures</th><td>Notice a detail</td></tr><tr><th scope="row">Quotations</th><td>Remember a thought</td></tr><tr><th scope="row">Equations</th><td>Describe a relationship precisely</td></tr></tbody></table>
            <hr><p>The end of the field guide. You can find words in this page or listen to its separate spoken text.</p>
        """.trimIndent(),
    )
}
