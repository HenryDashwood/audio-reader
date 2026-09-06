# Combining publication sources

Subscribe to both sources in Library, open the publication whose name and
artwork you want to keep, tap the **…** menu beside its title, and choose
**Manage sources**. Select the other subscription to combine it. The choice
applies only to your account. A source can be separated again from that screen
without unsubscribing.

All sources continue refreshing independently. Articles with matching URLs
appear once, using the copy with the most text. Read, dismissed and playback
state follows the article across its copies, including copies imported later.
Separating sources preserves their shared state. Existing Latest cutoffs are
retained; combining sources does not refill Latest with their archives.

Short posts and paywalled previews remain visible. There are no publisher
specific rules or automatic merges based on publication names. URL matching
ignores fragments, common tracking parameters and trailing slashes, while
preserving content-identifying query parameters. Different URLs are not
treated as duplicates merely because their titles match. Existing automatic
email/RSS companion pairs retain their previous tracking-link handling.

Unsubscribing from the displayed publication removes all its explicitly
combined subscriptions. To keep a source, separate it first. Blocking an email
sender through the newsletter controls instead releases the other sources
back into Library.

## Implementation and rollout

Migration `b615c209d842` adds a nullable `subscriptions.group_feed_id`. Each
source keeps its feed, episodes, subscription and Latest cursor. Group roots
are subscriptions belonging to the same user; API operations validate and
serialize group changes. No existing subscriptions are grouped by migration.

The API adds `sources` to library feed payloads and these authenticated routes:

- `GET /feeds/{feed_id}/sources` lists the explicitly subscribed sources.
- `PUT /feeds/{feed_id}/sources/{source_id}` combines two existing subscriptions
  and any sources already grouped under the second one.
- `DELETE /feeds/{feed_id}/sources/{source_id}` separates a secondary source.

The Swift client accepts older payloads without `sources`. Deploy the backend
and migration before distributing the updated app. No production database
changes are needed beyond the migration; grouping is a listener action.
