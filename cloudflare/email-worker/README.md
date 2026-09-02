# Newsletter email for Magpie

Each Magpie user has a private address, `<token>@magpieinbox.com`. Newsletters
are subscribed to that address, Cloudflare receives the mail, this Worker
hands each message to the backend, and the backend turns it into an item in a
private feed once the user has approved the sender.

This Worker is the only piece that lives at Cloudflare. It signs the raw
message with a shared secret and POSTs it to `/inbound/email`; the backend
does everything else.

## One-time setup

1. The inbound domain is `magpieinbox.com`, bought through Cloudflare
   Registrar so its DNS is already at Cloudflare. It is used for nothing
   else: no website, no outbound mail.
2. Enable Email Routing on the `magpieinbox.com` zone and let Cloudflare add
   its MX and SPF records.
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

   - `AUDIOREADER_INBOUND_EMAIL_DOMAIN` — `magpieinbox.com`
   - `AUDIOREADER_INBOUND_EMAIL_SECRET` — the same value as `WEBHOOK_SECRET`

   Until both are set, the backend hands out no addresses and refuses every
   inbound message, so the Worker can be deployed first without effect.

## Checking it works

Send any email to `<anything>@magpieinbox.com`. With no such user it should
bounce with "No such address", and `npm run tail` shows the exchange. Ask the
app for an address (`GET /newsletters/address`), send to it, and the sender
appears under `GET /newsletters/pending`.

## Failure behaviour

If the backend is down the Worker throws. Confirm on the deployed domain what
Cloudflare then reports to the sending server — the documentation does not
say — before relying on senders' retries; the backend stores every message it
accepts before parsing it, so the window that matters is only between
Cloudflare and the webhook.
