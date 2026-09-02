# Newsletter email for Magpie

Each Magpie user has a private address, `<token>@<inbound domain>`. Newsletters
are subscribed to that address, Cloudflare receives the mail, this Worker
hands each message to the backend, and the backend turns it into an item in a
private feed once the user has approved the sender.

This Worker is the only piece that lives at Cloudflare. It signs the raw
message with a shared secret and POSTs it to `/inbound/email`; the backend
does everything else.

## One-time setup

1. Put the inbound domain on Cloudflare DNS. Either a dedicated domain used
   for nothing else, or a subdomain of a zone that is already there — Email
   Routing supports both, and a subdomain is enabled under
   *Email Routing → Settings → Subdomains* on the apex zone.
2. Enable Email Routing on that domain and let Cloudflare add its MX records.
3. Deploy this Worker:

   ```bash
   cd cloudflare/email-worker
   npm install
   npm run check
   npx wrangler secret put WEBHOOK_SECRET   # a long random string
   npm run deploy
   ```

4. In *Email Routing → Routing rules*, set the **catch-all** action to
   *Send to a Worker* and pick `magpie-email-inbound`. Every local part is a
   possible user address, so nothing is registered ahead of time.
5. On the backend (Railway variables), set:

   - `AUDIOREADER_INBOUND_EMAIL_DOMAIN` — the inbound domain, e.g. `in.example.com`
   - `AUDIOREADER_INBOUND_EMAIL_SECRET` — the same value as `WEBHOOK_SECRET`

   Until both are set, the backend hands out no addresses and refuses every
   inbound message, so the Worker can be deployed first without effect.

## Checking it works

Send any email to `<anything>@<inbound domain>`. With no such user it should
bounce with "No such address", and `npm run tail` shows the exchange. Ask the
app for an address (`GET /newsletters/address`), send to it, and the sender
appears under `GET /newsletters/pending`.

## Failure behaviour

If the backend is down the Worker throws. Confirm on the deployed domain what
Cloudflare then reports to the sending server — the documentation does not
say — before relying on senders' retries; the backend stores every message it
accepts before parsing it, so the window that matters is only between
Cloudflare and the webhook.
