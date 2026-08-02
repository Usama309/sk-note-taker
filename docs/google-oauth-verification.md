# Google OAuth Verification — PENDING

Status: **Search Console verified + consent screen configured** (2026-08-01). Remaining: publish to
production, record the demo video, submit.

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

## Domain decision (2026-07-30)

`saqibkamran.com` is NOT usable: Usama has no DNS access to it, and the Vercel CLI here is signed
in as `vvostro43-6624`, which is not authorized on the `email-2742` account that hosts the original
deployment. Both halves of the old plan were blocked.

Resolved by hosting the verification site on a free Vercel subdomain instead. `vercel.app` is on the
Public Suffix List, so `sk-note-taker.vercel.app` counts as its own top private domain and is a valid
Google authorized domain. No DNS access and no cost.

**Live now (verified 200, on the account we control):**
- https://sk-note-taker.vercel.app
- https://sk-note-taker.vercel.app/privacy.html  (carries the required Google Limited Use disclosure)

Redeploy with: `cd website && vercel deploy --prod --yes`

### Phase 1 — site live
- [x] Site deployed to a domain we control (`sk-note-taker.vercel.app`), both pages public.

## Completed 2026-08-01

- [x] Site live on a domain we control: https://sk-note-taker.vercel.app (+ /privacy.html), both 200.
- [x] **Search Console ownership VERIFIED** for `https://sk-note-taker.vercel.app/` using the HTML
      file method. The file `googlee6d8500fa382d2ff.html` is committed in `website/` and deployed;
      Google re-checks it, so do NOT delete it.
- [x] Consent screen (console.cloud.google.com/auth/branding, project `notetaker-integrations`,
      account vvostro43@gmail.com):
      app name `SK Notetaker`, support email, home page, privacy policy link, developer contact,
      and **authorized domain `sk-note-taker.vercel.app`** (this is what needed Search Console).
- [x] **Scope registered** (Data Access): `.../auth/calendar.readonly`, listed as a sensitive scope.

### Still to do

- [ ] **[YOU] App logo (optional).** A ready 120x120 PNG is at
      `docs/google-oauth/consent-logo-120.png`. Browser automation could not complete Google's
      upload widget (it needs a real file-picker interaction), so drag that file in by hand on the
      Branding page. Uploading a logo is what forces verification, so it is only worth doing as part
      of submitting.
- [ ] **[YOU] Publish to production** (Audience page -> "Publish app"). While the app stays in
      Testing it is limited to 100 explicitly-added test users and refresh tokens expire about
      weekly. Publishing removes both; the unverified-app warning remains until Google reviews.
- [ ] **[YOU] Record a 1-2 min unlisted YouTube demo**: app -> Settings -> Connect Google Calendar ->
      the consent screen showing the app name and the calendar scope -> grant -> upcoming meetings
      appear on Home. Google requires seeing the scope actually used.
- [ ] **[YOU] Submit** (Verification Center) and paste the scope justification below.

### Phase 2 — verify domain ownership
- [ ] **[YOU] Google Search Console** (same Google account that owns the Cloud project): add
      `https://sk-note-taker.vercel.app/` as a **URL prefix** property. Choose the **HTML file upload**
      method and send Claude the `google*.html` filename it gives you (a TXT/DNS record is NOT possible
      here, since we do not own vercel.app).
- [ ] **[CLAUDE] Add that file to `website/` and redeploy**, then you click Verify.

### Phase 3 — OAuth consent screen (console.cloud.google.com/auth/branding)
- [ ] App name: `SK Note Taker`
- [ ] User support email: a real inbox you check
- [ ] App home page: `https://sk-note-taker.vercel.app`
- [ ] Privacy policy: `https://sk-note-taker.vercel.app/privacy.html`
- [ ] Authorized domain: `sk-note-taker.vercel.app`
      (If the console rejects it, that means Google is not honouring the Public Suffix List
      for vercel.app. Fallback: buy a cheap domain, or ask Saqib for one CNAME on saqibkamran.com.)
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
