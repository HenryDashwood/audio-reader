package com.henrydashwood.magpie.data

/** What one item in this feed is called, as on iOS: a newsletter carries issues, a blog posts, a podcast episodes. */
fun LibraryFeed.itemNoun(): String = if (newsletter) "issue" else if (articles) "post" else "episode"

/** "1 post", "12 episodes". */
fun LibraryFeed.countLabel(): String = "$count ${itemNoun()}${if (count == 1) "" else "s"}"

/** The show page's section title: "Issues", "Posts" or "Episodes". */
fun LibraryFeed.sectionTitle(): String = itemNoun().replaceFirstChar { it.uppercase() } + "s"
