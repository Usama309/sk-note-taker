# Google OAuth Verification — PENDING

Status: **paused, to resume later** (noted 2026-07-24).

Goal: remove the "Google hasn't verified this app" warning so any user can connect Google
Calendar in SK Note Taker with a clean consent screen (and no 7-day token expiry). Required
because `calendar.readonly` is a Google "sensitive" scope. Sensitive scope needs verification but
NOT the third-party security assessment (that is only for "restricted" scopes like Gmail/Drive).

## Current state (done)
- In-app Google sign-in built and working (loopback + PKCE OAuth; tokens in macOS Keychain).
- **Built-in OAuth client (2026-07-30):** the app now ships with its own Google Desktop client
  (baked into Info.plist at build time from the git-ignored `app/oauth-config.env`), so a new user
  connects with ONE click and never pastes credentials. The "paste your own client" fields moved
  under an Advanced disclosure. Connect screen now warns about the interim "unverified" notice.
- **Consent-screen logo + copy-paste console values produced:** `docs/google-oauth/consent-logo-120.png`
  and `docs/google-oauth/CONSOLE-VALUES.md`.
- Verification website built and deployed to Vercel.
  - Vercel account: `email-2742`, project: `website`.
  - Live now: https://website-chi-gray-77.vercel.app and `/privacy.html`.
  - Source: `website/index.html`, `website/privacy.html` (privacy policy includes the required
    Google "Limited Use" disclosure).
- App also hardened: connect flow times out after 3 min and has a Cancel button.

## Blocking next step
Everything below is blocked on getting the site onto the custom domain, which starts with ONE
Cloudflare DNS record.

## The checklist

### Phase 1 — make the subdomain live
- [ ] **[YOU] Add CNAME in Cloudflare** (dash.cloudflare.com -> saqibkamran.com -> DNS -> Records -> Add record):
  - Type: `CNAME`  |  Name: `sknotetaker`  |  Target: `cname.vercel-dns.com`  |  Proxy: **DNS only** (grey cloud)
- [ ] **[CLAUDE] Attach domain on Vercel + issue SSL**, then confirm `https://sknotetaker.saqibkamran.com` and `/privacy.html` load.
      (Command once DNS resolves: `cd website && vercel domains add sknotetaker.saqibkamran.com`.)

### Phase 2 — verify domain ownership
- [ ] **[YOU] Google Search Console** (same Google account that owns the Cloud project): add `saqibkamran.com`
      as a **Domain** property, add the TXT record it gives you in Cloudflare, then Verify. (Skip if already verified.)

### Phase 3 — OAuth consent screen (console.cloud.google.com/auth/branding)
- [ ] App name: `SK Note Taker`
- [ ] User support email: a real inbox you check
- [ ] App home page: `https://sknotetaker.saqibkamran.com`
- [ ] Privacy policy: `https://sknotetaker.saqibkamran.com/privacy.html`
- [ ] Authorized domain: `saqibkamran.com`
- [ ] Developer contact email set
- [x] App logo produced: `docs/google-oauth/consent-logo-120.png` (upload it here)
- [ ] Scope present (console.cloud.google.com/auth/scopes): `https://www.googleapis.com/auth/calendar.readonly`

### Phase 4 — submit
- [ ] **[YOU] Record a 1 to 2 min unlisted YouTube demo:** app -> Settings -> Connect Google Calendar ->
      consent screen showing "SK Note Taker" + calendar.readonly -> grant -> upcoming meetings appear on home.
- [ ] **[YOU] Publish + submit** (console.cloud.google.com/auth/audience -> In production -> Prepare for verification).
      Paste the scope justification below.
- [ ] Wait ~2 to 6 weeks for Google review; keep using via test users meanwhile.

## Scope justification (paste at submission)
> SK Note Taker is a macOS meeting-notes app. It uses calendar.readonly to read the title, time,
> location, and conferencing link of the user's upcoming primary-calendar events and shows them on
> the app's home screen so the user can start recording notes for a meeting in one click. The app
> only reads events; it never creates, modifies, or deletes them. Calendar data is used solely on
> the user's device to render this upcoming-meetings list, is never transmitted to or stored on any
> server we operate, and is never shared with third parties. Read-only is the minimum scope that
> exposes the event details needed to display upcoming meetings.

## Interim (works today, no verification)
Keep the OAuth consent screen in **Testing** and add each user's Google address as a **Test user**.
They get the bypassable "Google hasn't verified this app" screen (Advanced -> Go to SK Notetaker)
and re-auth about every 7 days.
