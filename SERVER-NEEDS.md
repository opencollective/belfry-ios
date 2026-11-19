# What the iOS app needs from the belfry (server side)

Changes in `collective-belfry` (services/onboarding/belfry_onboarding/) that this app depends on.
This repo does not touch the servers; each item says exactly what to change.

## 1. Accept the app's redirect URI in `/connect` — DONE (Belfry after 36ff214, 2026-11-09)

`apps.NATIVE_APPS = {"sh.belfry.app://connect": …}`, approved by default; sessions are named by
`client_id` ("Belfry for iPhone" / "Belfry for Android").
Kept below for the record.

The app signs in with `ASWebAuthenticationSession` and the return address
**`sh.belfry.app://connect`** (`client_id=belfry-ios`, PKCE S256, as the web chat).

Today `apps.app_uri()` (apps.py) raises for anything but `https://` (or `http://localhost`):

```python
if u.scheme != "https" and not (u.scheme == "http" and local):
    raise ValueError("an app's address must be https://")
```

and `is_approved()` only passes the belfry's own web apps (`own_app`) and admin-approved
addresses. Needed:

1. `app_uri()`: also accept the exact URI `sh.belfry.app://connect` (no other custom schemes, no
   query/fragment), returning it unchanged as the app's identity.
2. `is_approved()` / `own_app()`: treat `sh.belfry.app://connect` as one of the belfry's own apps
   (approved by default on every belfry, like `https://<domain>/chat/`), or let admins approve it
   in the Apps tab like any other app. Default-approved is what makes "type your domain, sign in"
   work on a fresh belfry.
3. `address()` / `display_name()`: show it as **"Belfry for iPhone"** (a fixed name chosen by the
   server for this exact URI; never a name from the URL).
4. `back_to()` works as is (`sh.belfry.app://connect?code=…&state=…`).
5. `/connect/logout?return_to=sh.belfry.app://connect`: same allow-list (optional; the app does
   not call it today).
6. The token endpoint needs no CORS for the app (native requests).

Security note: any iOS app can claim a custom scheme. PKCE protects the code (only the app that
made the verifier can redeem it), which is the standard for native apps (RFC 8252 section 8.1).
A universal link (`https://belfry.sh/app/connect` with an apple-app-site-association file) would
be stronger but only works for one domain, not for every community's own domain.

## 2. Publish `api.base` in belfry.json — DONE (both live documents publish `api.base`, `api.channel_invites`, `api.follows`)

`discovery.py` computes `base` from `console_url`, but the live documents (belfry.sh, enspiral.eu)
have no `api.base` and no `api.channel_invites`, and their `api.*` entries point at
`pass.<domain>/api`. The app falls back to `https://belfry.<domain>/api/v1` like the web chat.
Publishing `api.base` (and `api.channel_invites`) removes the guess. NIP-98: `holder_invites.authenticate`
already accepts both the `pass.` and `belfry.<domain>/api/v1` URLs.

## 3. Push notifications — the app side is built against collective-belfry `docs/push.md`

The protocol is `docs/push.md` (gateway at push.belfry.sh, `/api/v1/push/devices`,
`/api/v1/notifications`); this app does not change it. What Xavier must do in the Apple
developer portal before TestFlight can carry push:

1. App ID `sh.belfry.app`: enable **Push Notifications** and **App Groups** (group
   `group.sh.belfry.app`).
2. A second App ID **`sh.belfry.app.notifications`** (the Notification Service Extension), with
   **App Groups** (`group.sh.belfry.app`).
3. Both share the keychain access group `<TEAM_ID>.sh.belfry.app.shared` (declared in the
   entitlements; no portal switch needed beyond the same team).
4. An **APNs auth key** (.p8, Keys → Apple Push Notifications service) for the gateway: its key
   id, the team id and the .p8 go into the gateway's secrets (`apns_key.p8`, `APNS_KEY_ID`,
   `APNS_TEAM_ID`), never into this repo.
5. With automatic signing (`-allowProvisioningUpdates` and the App Store Connect API key), the
   profiles for both targets are made by the TestFlight job; the entitlements are
   `aps-environment` = development (Debug) / production (Release), the App Group and the keychain
   group (project.yml). CI's simulator build is unsigned, so these only matter for TestFlight.

Questions on the contract, raised here rather than changed:
- (Settled, built) `env` picks the APNs host: Debug builds send `sandbox`, TestFlight / release
  `production`. The gateway answers 503 `not_configured` until the APNs key exists.
- A background own-echo DM (NIP-17 self-copy) can only be made silent, not dropped, without
  Apple's `com.apple.developer.usernotifications.filtering` entitlement (granted on request).
- The DM payload has `title` = the belfry's name: fine for one community per phone; with
  several communities later, the extension shows it as is.
- No badge count is in the payload; the app sets none.

## 4. Session lifetime and revocation (question)

The token answer has no refresh token or expiry. How long does a Keycast bunker session live,
and what does the signer answer once it is removed on the account page (an error string the app
can recognise, so it can ask the person to sign in again instead of retrying)?

## 4b. Native sign-in (`POST <sign_in.sessions.api>`, `/verify`) — built in the app 2026-11-12, not run live

The app follows sessions.py's docstring (SPEC 19.20). Nothing blocks; notes for the belfry:

- **Telling an older belfry apart** (Android's ask) is settled for this app: it reads the
  endpoint from belfry.json `sign_in.sessions.api` and offers the browser when the key is
  missing. One gap: a belfry between 2026-11-05 and 639b39b publishes that key (the HTTP API for
  web apps existed) but refuses `app` = `sh.belfry.app://connect`, most likely with 422
  `invalid` / `app_address`, which this app shows as "Type your address like name@belfry.sh."
  Both live belfries are past that commit. A capability flag (e.g. `sign_in.sessions.native:
  true`) would close it.
- **503 `signer`** (60c82bf) is handled: "Send a new code" unlocks at once. Thank you.
- **`unknown` means two things** (no such member; the belfry answers for another domain): one
  message covers both.
- **`tries_left: 0`**: the app says "Ask for a new one." and assumes the code is dead; `expired`
  on the next try is handled too.
- **Enumeration**: `POST /session` tells `unknown` from `code_sent` to anyone with a key; a rate
  limit per key / IP for unknown names is the belfry's to decide.
- The session is named by `client` = `belfry-ios`; sign-out revokes it as before (item 4).
- The calls use a NIP-98 `created_at` that only grows (`max(last + 1, now)`), so a resend in the
  same second is never the same event (section 6's replay note).

## 5. `apple-app-site-association` so guest links and event addresses open in the app

The app claims `https://chat.belfry.sh` and `https://chat.enspiral.eu` (entitlement
`com.apple.developer.associated-domains`, `applinks:chat.<domain>` in `project.yml`) for:

- guest links `https://chat.<domain>/join/<token>` (SPEC 19.4), and
- event addresses `https://chat.<domain>/events/<link>` (SPEC 19.18; the belfry 302s these to
  `/#/events/<link>` today).

iOS only opens them in the app once each chat host serves this file, **as JSON, over HTTPS,
without a redirect**, at `https://chat.<domain>/.well-known/apple-app-site-association` (no
file extension, `Content-Type: application/json`), next to the `assetlinks.json` already served
for Android:

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["<TEAM_ID>.sh.belfry.app"],
        "components": [
          { "/": "/join/*", "comment": "guest links" },
          { "/": "/events/*", "comment": "event addresses" }
        ]
      }
    ]
  }
}
```

`<TEAM_ID>` is the Apple Developer Team ID that will sign the app (the `APPLE_TEAM_ID` secret of
the TestFlight job; not known in this repo). Apple's CDN caches the file: after changing it, a
fresh install picks it up within a day. Until it is served, the links open the web chat (which
handles them), so nothing breaks. Another community's chat host needs the same file and one more
`applinks:` line in `project.yml` (or a per-community build).

## 6. Small things seen while porting (2026-11-11)

- NIP-98 same-second replay (Android SERVER-NEEDS 5) applies here too: two identical signed GETs
  in one second share an event id and the second gets 401. A nonce tag would remove it.
- `POST /admins` returning the new admin list would save the belfry.json re-read after the admin
  switch (Android SERVER-NEEDS 6).
- Push notifications (section 3) are still the main missing piece for a phone app.

## 7. Guest mode (docs/guests.md, 2026-11-12) — built in the app, not run live

Nothing blocks; notes for the belfry:

- **Telling an older belfry apart**: the app sends `{}` to `/channel-invites/<token>/join`. A
  belfry from before guest mode answers 422 `name_needed`; the app then says "This belfry is
  being updated. Try again in a few minutes." and does not fall back to asking a name. A
  capability flag in belfry.json (e.g. `guests.reading: true`) would let a client pick the flow.
- **The `saved` / `member` label** is read per group (`h` of the 1985), as the web does. If the
  belfry ever labels a joined guest in one channel only while their reading 9000s stand in
  others, those others keep hiding them until a 9000 without `reading` lands there too.
- **Read-only is client-side** (as the doc says): a modified client could post as a nameless
  guest. A relay-side refusal of writes from keys whose latest 9000 carries `reading` would make
  "reading" true for everyone.
- `/whois` is allowed while reading (it is a read sent as a POST). Push registration
  (`/push/devices`) waits until the guest has joined.

## 8. Tickets, check-in, roles per group (the contract of 2026-11-15) — built in the app, not run live

The app codes against the contract (SPEC 19.29). For the belfry:

- **Universal links for tickets**: the app opens `https://chat.<domain>/events/<link>/t/<code>`.
  The chat hosts' `apple-app-site-association` (Caddyfile, `"/": "/events/*"`) already covers it:
  in the `components` form `*` matches across `/`, so no change is needed. The Caddy rewrite of
  `/events/<link>/t/<code>` to `/#/events/<link>/t/<code>` (contract §2) is still needed for
  browsers and for phones without the app.
- **The viewer block**: the app reads `viewer` and `me` (events v1) and merges them, `viewer`
  winning; `ticket_url` is used only when it is https and ends with `/t/<ticket_code>`.
- **Peek** (`"peek": true` on /checkin, live since 2026-11-16) is used for the card a ticket link
  opens; `/group-meta` for edits by admins by role; `"role": "removed"` for removal.
- **Admins by role** (the server's change 3) are read as the web's `checkin` branch does: latest
  39001 ∪ creator ∪ the latest 9000 / 9001 per person. The app does not check who signed the
  9000 (neither does the web); the relay only accepts them from the groups key and admins.
- **An older belfry** answers 404 (or 405) without one of the contract's codes: the app shows
  "This belfry needs an update." and hides the ticket button (no `ticket_code`) and "Check people
  in" (no `may_check_in`, unless the relay's roles say so: then the list comes from the relay and
  checking in fails with that message).

## 9. Deleted and archived groups (the contract of 2026-11-16) — built in the app, not run live

- **`POST /group-meta` with `archived`** (boolean): used only by admins by role (the relay's own
  admins publish the 9002 themselves, with `["archived","1"|"0"]` and every other setting kept).
  The app shows fixed messages for 409 `archived` and `always_open`. **Ask**: answer with
  `"archived": true|false` in the body. A belfry from before this answers 200 and changes
  nothing; without that field the app can only watch the relay for 5 s before saying "This
  belfry can't archive yet: it needs an update."
- **The 9002 the belfry publishes** must carry `["archived","1"]` while the group is archived
  (any later 9002 without the tag leaves it archived for this app: the latest one that says
  anything wins), and `["archived","0"]` to unarchive.
- **Does the groups relay answer `{"kinds":[39000],"#d":[…]}` for every channel and group a
  member may see, closed groups they are not in included?** The app calls a group deleted when
  that answer names `general` and not the group. If zooid hides a closed group's 39000 from
  non-members, their cards would read "This group has been deleted" for them: tell us and the
  app will ask the belfry instead (a `POST /whois`-like "which of these groups exist").
- **A deleted group's leftovers**: zooid drops everything of a deleted group, the 9008 too, so a
  phone that was away never hears of it; the question above is how the app finds out. Nothing
  to do unless the relay could keep (or re-serve) the 9008.
- **Notifications** of an archived group: the app does not filter pushes; the belfry should not
  send them.


## 10. A guest applies to become a member (2026-11-16, board Join-Apply) — DONE (Belfry 9d03d4a, guestapply.py; the app sends it since round 2)

The guest's Home leads with "Apply to become a member" (the owner's ask). Today a request to
join exists only as the web form `pass.<domain>/apply` (apply.py), which makes a new person from
a name and an e-mail; a guest already has an account, a saved e-mail and a key, and should stay
that person. **Ask**: `POST /api/v1/applications {"apply": {"answer": "<text ≤ 2000>"}}`, NIP-98
by the guest's key (an active guest pass with a saved e-mail; 409 `guest_not_saved` otherwise),
making a `belfry.application` linked to the guest's contact (`kind` = `guest`, the channel(s) and
inviter for the stewards' card), answering `{"application": {"id","state","vouches","needed"}}`
and 409 `pending` with the same body when one is open. Then: `{"apply": "status"}` (or the same
call with `{}`) for the guest's Home ("1 of 2 vouches · Dev Patel vouched for you"); on
acceptance, `guests.became_member` on the same key (no invite mail: they are signed in), the
guest passes closed, the role Member. The guest's days must not run out while a request is open
(the board says so). Until then the app sends nothing and says: "<belfry> can't take a guest's
request from the app yet. Ask the person who invited you, or a steward." (the demo pretends it
was sent). Also needed for the request card in the Gates: `kind: "guest"` and the inviter in the
list answer.

## 11. Public events for guests (2026-11-16, board Join-Guest 5) — DONE (`GET /api/v1/events?visibility=public&from=`, docs/checkin.md; the app caches the answer)

A guest's Calendar shows "Public events · Going": events with `visibility` public plus those of
the channels they were let into. A guest reads only their channels on the groups relay and not
the community relay where the calendar events live, so on a real belfry the list holds little
more than the events they opened by link (`GET /api/v1/events/<link>`). **Ask**: `GET
/api/v1/events?visibility=public&from=<unix>` (no auth, the same JSON per event as
`/events/<link>`, newest 100), or let guests read kinds 31922 / 31923 with `visibility` public
on the community relay. The app would merge it into the guest's list unchanged.

## 12. The charter for guests and people applying (2026-11-16, SPEC 19.32) — DONE except (1) (`GET /api/v1/charter`, belfry.json `charter`, `agreed` on a guest's request, ticks signed for the new member: docs/charter.md)

The charter is the group `charter` on the groups relay (a fixed id; agreements = 2100 with
`["each","1"]`; ticks = each person's own 2101 `done`). Members read it like any open group.
**Ask**: (1) zooid: let guests (patch 0002) and applicants (patch 0004) **read** the group
`charter` and **write** only their own 2101 with `["each","1"]` in it (no 2100, no edit, no
delete); (2) belfry.json `charter: true|false` (the group exists and has at least one
agreement) so a phone that can't read it yet knows whether the joining step exists; (3) when a
person applies from outside (`/apply`, later the app's Ask to join), the request carries the ids
of the agreements they ticked (`"agreed": [<2100 id>…]`), and on acceptance the belfry publishes
nothing for them (their first ticks are theirs to sign once they are in; or the app re-ticks
from the stored list after the first sign-in). (4) Only belfry admins' 2100 / edits / removals
count (the app checks against belfry.json `admins`); a belfry that wants the relay to enforce
it can refuse 2100 with `["h","charter"]` from anyone else. Until then a guest's Home and drawer
show the Charter row only if the phone holds the group (normally never for a guest).

## 13. Asking to join from the app (2026-11-16, board Join-Outside) — not built

The boards' "Which belfry?" / the belfry's card / "Ask to join" need a JSON form of
`pass.<domain>/apply` (`POST /api/v1/apply {"name","email","answer","agreed"?}`, no auth, the
same limits as the web form) and belfry.json `membership.accept` (`admins` | `vouches`) and
`membership.question` so the card can say how one gets in. Not built on iOS: the app still
starts on the sign-in screen (name@domain, or a guest link).

Round 2 (2026-11-16): 10, 11 and 12 are done on the belfry; what stays open of 12 is (1), zooid
letting guests and applicants read the `charter` group (the public read stands in for it). 13 is
still open: the app still starts on sign-in or a guest link.

## 14. Small things seen while building round 2

- **E-mail threads**: the app joins a shared inbox's e-mails into threads itself (SPEC 19.33) and
  trusts `belfry-mail` / `belfry-mail-out` posts only from `_groups@<domain>`'s key. Push for a
  follow-up e-mail names the e-mail's own event id; the app opens its thread from any of its ids.
- **First minutes**: the app shows them only after it saw the account's guest become a member on
  this phone (the web's rule). A member made directly by a member link on another device gets none.

## 15. Round 6 (2026-11-18): closed channels, web settings by stewards — not built

- **ANSWERED 2026-11-19** (`POST /api/v1/group-requests/decide`, docs/membership.md; iOS uses it
  for every admin, SPEC 19.52). ~~A steward by role can't let people in.~~ A closed channel's (or group's) requests are 9021s;
  Accept / Decline is a 9000 / 9001 the relay takes only from the group's 39001 (its creator, the
  belfry's admins). `POST /api/v1/group-roles` refuses someone not in the group yet
  (`409 not_in_group`), so an admin by role (SPEC 19.29) has no way to answer. The app shows them
  the requests with "Its creator or a belfry admin lets people in." **Ask**: `POST
  /api/v1/group-requests {"channel", "pubkey", "approve": bool}` by any admin of the group (39001,
  creator, by role, belfry admins), the belfry publishing the 9000 / 9001 as the groups key.
- **A channel's web settings (public / members only) by a steward by role.** The 30078
  `belfry:web:<id>` counts only from the group's admins as the client sees them (39001 + creator +
  by role) or the relay's key; the server's webthreads / website code should use the same rule
  (or offer `POST /api/v1/group-web {"channel", "visibility"}` acting as the groups key, like
  `/group-meta`). Not checked against the server.
