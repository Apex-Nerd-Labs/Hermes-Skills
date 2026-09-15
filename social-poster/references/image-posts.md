# Image posts — verified per-platform upload recipes (2026-09-15)

`post.py` is text-only. `scripts/post_with_image.py` adds one image to the same
five platforms that can actually publish, reading the same `vault.json` /
`config.json` and the same OAuth1 code path as `post.py`.

```bash
python3 scripts/post_with_image.py --platforms linkedin,x,mastodon,discord \
    --dir <dir-of-<platform>.md> --image <card.jpg> [--dry-run]
```

Per-platform text is read from `<dir>/<platform>.md` (so each platform gets its
own length-appropriate copy). Lines starting `# CHARACTER COUNT` are stripped.

## LinkedIn — use the legacy assets + ugcPosts flow

- `/rest/posts` returns **HTTP 500 for every active LinkedIn-Version** on this app
  (202601 through 202608 all 500 on 2026-09-15), with a valid `openid profile
  w_member_social` token and a minimal text-only payload. Do not burn time on it.
- A `urn:li:image:...` URN from `/rest/images?action=initializeUpload` inside a
  ugcPost fails with **400 "One or more of the contents is not owned by the
  author"**, even though the image was uploaded against the same person URN.
- Working recipe: `POST /v2/assets?action=registerUpload`
  (`recipes: ["urn:li:digitalmediaRecipe:feedshare-image"]`, owner `urn:li:person:<sub>`,
  serviceRelationship OWNER/`urn:li:userGeneratedContent`), PUT the bytes to the
  returned `uploadUrl` (expect **201**), then
  `POST /v2/ugcPosts` with `shareMediaCategory: "IMAGE"` and
  `media: [{"status":"READY","media": <asset>,
  "title":{"text":...}, "description":{"text":...}}]`.
- Company mention (`shareCommentary.attributes`) still works in this flow, but the
  annotated span must exist: **400 "share commentary is invalid" with
  `FIELD_VALUE_INVALID` is what you get when `text.find("Coffee and Bytes")`
  returned -1** and you sent `start: -1`. Editing the copy so the org name is no
  longer present is the usual cause. Assert on `find() < 0` and fail loudly.
- Active `LinkedIn-Version` on 2026-09-15: **202601…202608**; 202509 is retired
  (426 NONEXISTENT_VERSION). Only matters for `/rest/*` calls.
- Read-back: the share id is the creation confirmation (write-only scope blocks
  GET), but the public URL `https://www.linkedin.com/feed/update/<urn>/` returns
  200 anonymously with `og:image` pointing at the uploaded feedshare image — a
  real external verification of text + media.

## X — media upload works, posting is billing-gated

- v1.1 `https://upload.twitter.com/1.1/media/upload.json`, multipart field `media`,
  OAuth 1.0a header signed **without** form fields (multipart body is not part of
  the signature base string) → returns `media_id_string`. Verified working.
- Tweet: `POST https://api.twitter.com/2/tweets` with
  `{"text": ..., "media": {"media_ids": ["<id>"]}}` and `oauth_body_hash` on the
  JSON body (same as `post.py`).
- **HTTP 402 `{"detail":"credits depleted"}`** = X's Pay-Per-Use balance is zero.
  The request is correct; a GET `/2/users/me` and media upload both succeed with
  the same credentials. Only a top-up at console.x.com (Billing) fixes it. Report
  it, do not retry in a loop.
- Diagnostic order when X fails: GET `/2/users/me` (auth) → media upload (write
  scope) → POST `/2/tweets` (billing). 402 at the last step means code is fine.

## Bluesky — resolve the PDS, and watch for revoked app passwords

- The account may not live on `bsky.social`: resolve the handle, read the DID doc
  at `https://plc.directory/<did>` and use the `#atproto_pds`
  `serviceEndpoint` (e.g. `mottlegill.us-west.host.bsky.network`). `post.py`
  already does this via `_resolve_pds`.
- `401 Invalid identifier or password` on **both** `bsky.social` and the real PDS
  means the app password itself is dead (revoked, or the account was migrated) —
  requesting a new app password is the only fix. Not a code problem.
- Upload the blob first: `com.atproto.repo.uploadBlob` (Content-Type `image/jpeg`,
  Bearer accessJwt) → embed as `app.bsky.embed.images` with `alt` text.

## Mastodon — two calls, poll the media

- `POST /api/v2/media` (multipart, field `file`, optional `description` for alt
  text, Bearer token) → media `id`. A 200 with `url` means processed; a 206 needs
  polling `GET /api/v1/media/<id>` until `url` appears.
- `POST /api/v1/statuses` with `urlencode({'status': text, 'media_ids[]': id})`.

## Discord — multipart webhook

- `POST <webhook_url>` as multipart with `payload_json={"content": ...}` and
  `files[0]` = the image. Markdown in `content` renders (bold, links).

## Promo card recipe (thumbnail + headline banner)

Reusable pattern for promoting an episode from its own YouTube thumbnail:

- Base: `https://i.ytimg.com/vi/<id>/maxresdefault.jpg` resized to **1200x675**
  (16:9, uncropped in X/LinkedIn/Bluesky timelines). Do not make the card taller
  than 16:9 — X centre-crops taller previews and would cut a bottom text band.
- Banner from y=474: 60px alpha fade-in over the artwork, then solid `#090D1E`
  at ~230/255 alpha, a 4px cyan rule, then three text lines (46pt bold headline
  with the key number in red, 27pt cyan qualifier, 21pt mono episode slug).
- Fonts that exist on this box: `LiberationSans-Bold.ttf`, `DejaVuSans-Bold.ttf`,
  `FiraCodeNerdFont-Bold.ttf` (mono, for slug lines).
- Check the render with vision before posting: confirm all text is inside the
  frame and the banner covers nothing load-bearing (the host avatar and the
  existing title stay visible).

## Read-back verification after posting

- Mastodon: `GET https://<instance>/api/v1/statuses/<id>` (public) → text + media.
- Discord: with a bot token, `GET /channels/<id>/messages?limit=N` shows content
  and attachment filenames.
- LinkedIn: public feed URL → `og:image` + hashtags in `<title>`.
- X: the returned tweet id is the only confirmation available from here.
