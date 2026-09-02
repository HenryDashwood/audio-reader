// Secrets are set with `wrangler secret put` and never appear in
// wrangler.jsonc, so `wrangler types` cannot know about them. This is the one
// binding declared by hand; everything else comes from the generated file.
interface Env {
  WEBHOOK_SECRET: string;
}
