# Google Cloud Console — exact values to paste

Everything you need for the OAuth consent screen + verification submission, in copy-paste form.
The app now ships with a **built-in Google OAuth client** (baked into the .app at build time from
the git-ignored `app/oauth-config.env`), so end users connect with one click and never paste
credentials. This doc is only for **you** (the developer) to finish Google's review.

Logo to upload (produced for you): `docs/google-oauth/consent-logo-120.png` (120x120, Google's
required size). A crisp 512 version is at `consent-logo-512.png` if the console wants larger.

---

## OAuth consent screen → Branding
(console.cloud.google.com/auth/branding)

| Field | Value |
|---|---|
| App name | `SK Note Taker` |
| User support email | `email@saqibkamran.com` *(must be an inbox you actually monitor, or a Google Group you own)* |
| App logo | upload `docs/google-oauth/consent-logo-120.png` |
| App home page | `https://sknotetaker.saqibkamran.com` |
| Privacy policy URL | `https://sknotetaker.saqibkamran.com/privacy.html` |
| Terms of service URL | *(optional — leave blank unless you add one)* |
| Authorized domain | `saqibkamran.com` |
| Developer contact email | `email@saqibkamran.com` |

## OAuth consent screen → Audience
(console.cloud.google.com/auth/audience)

| Field | Value |
|---|---|
| User type | `External` |
| Publishing status | `Testing` for now → switch to `In production` to submit for verification |
| Test users (interim) | add each tester's Google address while in Testing |

## Scopes
(console.cloud.google.com/auth/scopes)

| Scope | Type | Why |
|---|---|---|
| `https://www.googleapis.com/auth/calendar.readonly` | **Sensitive** (needs verification) | read upcoming events to show on Home |
| `openid` | non-sensitive | sign-in |
| `email` | non-sensitive | show which account is connected |

Only `calendar.readonly` triggers verification. It is a *sensitive* (not *restricted*) scope, so it
needs Google's brand/verification review but **not** the paid third-party security assessment.

## OAuth client (already created — do not change)
(console.cloud.google.com/apis/credentials)

| Field | Value |
|---|---|
| Type | `Desktop app` |
| Redirect URIs | none to configure — the app uses a loopback (`http://127.0.0.1:<random-port>`) + PKCE |
| Client ID / secret | your existing Desktop client, now baked into the app via `oauth-config.env` |

Note: for a Desktop client the secret is non-confidential by Google's design (installed-app model),
which is why it is safe to embed in the shipped app. It is kept out of git.

---

## Scope justification (paste at submission)

> SK Note Taker is a macOS meeting-notes app. It uses calendar.readonly to read the title, time,
> location, and conferencing link of the user's upcoming primary-calendar events and shows them on
> the app's home screen so the user can start recording notes for a meeting in one click. The app
> only reads events; it never creates, modifies, or deletes them. Calendar data is used solely on
> the user's device to render this upcoming-meetings list, is never transmitted to or stored on any
> server we operate, and is never shared with third parties. Read-only is the minimum scope that
> exposes the event details needed to display upcoming meetings.

## Demo video script (1-2 min, unlisted YouTube — required at submission)

1. Open SK Note Taker → Settings → Calendar.
2. Click **Connect Google Calendar**. Show the browser opening Google's real consent screen with
   the app name **SK Note Taker** and the **calendar.readonly** permission.
3. Grant access. Show the app's Home now listing upcoming meetings.
4. Say in voiceover: read-only, shown only on-device, never sent to a server.

---

## What is still blocked on you (two one-time actions)

1. **Cloudflare CNAME** so the domain goes live:
   `dash.cloudflare.com → saqibkamran.com → DNS → Add record` →
   Type `CNAME`, Name `sknotetaker`, Target `cname.vercel-dns.com`, Proxy **DNS only** (grey cloud).
   Then tell me, and I run `cd website && vercel domains add sknotetaker.saqibkamran.com` + confirm
   `https://sknotetaker.saqibkamran.com` and `/privacy.html` load.
2. **Google Search Console** domain ownership: add `saqibkamran.com` as a Domain property (same
   Google account that owns the Cloud project), add its TXT record in Cloudflare, Verify.

Until verification is granted, testers see a bypassable "Google hasn't verified this app" screen
(Advanced → Go to SK Note Taker). The app now tells them exactly this on the connect screen.
