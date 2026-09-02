/**
 * Receives newsletter email for Magpie and hands each message to the backend.
 *
 * Deliberately dumb. The backend owns parsing, the reader's address book and
 * every decision about what to do with a message; this Worker only proves to
 * it that the bytes came from here. Kept small because the Workers free plan
 * caps CPU time per invocation, and because the less that runs at the edge,
 * the less there is to keep in step with the Python side.
 *
 * Status codes from the backend are instructions:
 *   202  ours now — never retry, whatever became of it
 *   404  no such address — bounce, so the sender learns the address is wrong
 *   413  too large — bounce
 *   else something is wrong on our side — throw, and let the sending server
 *        try again later rather than lose the message
 */

const encoder = new TextEncoder();

async function sign(secret: string, body: ArrayBuffer): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, body));
  let hex = "";
  for (const byte of digest) {
    hex += byte.toString(16).padStart(2, "0");
  }
  return `sha256=${hex}`;
}

export default {
  async email(message, env, _ctx): Promise<void> {
    const maxBytes = Number(env.MAX_BYTES);
    if (Number.isFinite(maxBytes) && maxBytes > 0 && message.rawSize > maxBytes) {
      console.warn(JSON.stringify({ event: "rejected", reason: "too large", to: message.to, size: message.rawSize }));
      message.setReject("Message too large");
      return;
    }

    // Buffered rather than streamed: the size is already bounded above, and
    // the signature has to cover every byte before the request can start.
    const body = await new Response(message.raw).arrayBuffer();
    const signature = await sign(env.WEBHOOK_SECRET, body);

    let response: Response;
    try {
      response = await fetch(env.WEBHOOK_URL, {
        method: "POST",
        headers: {
          "Content-Type": "message/rfc822",
          "X-Magpie-Signature": signature,
          "X-Magpie-Recipient": message.to,
          "X-Magpie-Sender": message.from,
        },
        body,
      });
    } catch (error) {
      console.error(JSON.stringify({ event: "backend unreachable", to: message.to, error: String(error) }));
      throw error;
    }

    if (response.status === 404) {
      message.setReject("No such address");
      return;
    }
    if (response.status === 413) {
      message.setReject("Message too large");
      return;
    }
    if (!response.ok) {
      const detail = (await response.text()).slice(0, 500);
      console.error(JSON.stringify({ event: "backend refused", to: message.to, status: response.status, detail }));
      throw new Error(`backend returned ${response.status}`);
    }

    const receipt = (await response.json()) as { status?: string };
    console.log(JSON.stringify({ event: "delivered", to: message.to, status: receipt.status ?? "unknown" }));
  },
} satisfies ExportedHandler<Env>;
