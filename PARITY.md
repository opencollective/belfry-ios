# Parity with the web chat

Reference: `village-app`, branch `belfry-chat`, at commit ef9e1cc (2026-11-10), Belfry theme,
plus `commonshub/collective-belfry` `chat-source` 85ede89 (Reply opens the thread's own view),
plus guest mode from village-app b2e968b (2026-11-12); since 2026-11-15 also b43f9cf (groups,
requests, roles), 8f0ccb8 / 98c33fc (Members), aa778e2 (read state) and Android 90f0762.
Second reading: the Android app (opencollective/belfry-android 2ce8be8, its PARITY.md). Same
shape as Android's file. Status words: **done** (built, compiled in CI, rendered in demo mode by
the screenshot job, and covered by a core test where noted), **partial** (what is missing is
named), **not yet**.

Read this first: since 2026-11-15 the owner runs TestFlight builds on his iPhone (iOS 26), and
sent a message from one; beyond that, **no feature here was checked on a phone or against a real
belfry by whoever built it**. No Mac
here: the app is only compiled and screenshotted in the iOS simulator by CI (demo mode, seeded
community, no network). "Done" means the code follows the protocol contract (SPEC.md + the
shared vectors, which the core passes), compiles, and its screen renders with the demo data.
Sign-in, the signer (NIP-46), relays, uploads, the photo picker, universal links, the keyboard
and gestures are untested in the real world. XCTest covers the core (BelfryCore), not the UI.

## Protocol core (`Sources/BelfryCore`, `swift test`)

| Area | Status | Notes |
|---|---|---|
| Events, ids, BIP-340, bech32, NIP-44 v2, NIP-59 | done | `events.json`, `nip44.json`. |
| Channels, messages, reactions, threads, mentions, actions, active members, admin rights | done | Every case of the shared vectors. |
| Markdown subset, MIME, mail threads, outbox pass | done | `outbox.json` includes refused uploads (4xx but 401/408/429 permanent, SPEC 19.17). |
| Channel references (NIP-19 naddr of kind 39000) | done | `channel-refs.json` (encode / decode / previews) + picker test. |
| Edits (1010, only the author's latest), delete preview, pins (1985 `belfry/pin`, admins only), to-dos (2100-2103, `q`), member labels, drop links, inbox card state | done | `AdditionsTests`. |
| Guests: `agent`, `unsaved`, `saved` / `member` labels, cleaned-up joins, whois overrules events, members' own agents (belfry.json `agents`) | done | `GuestsTests`. |
| Belfry events (rule B, hosts, tickets, applications, holders, my state, lists, cards from URLs), proposals, the channel line | done | `EventsTests`, `LineAndLinksTests`, `EventsApiTests` (the API's answer). |
| Profiles: tags and places (30078 `belfry:profile`) | done | Parse / write test; subscription filter on the community relay. |
| belfry.json revalidated (`Cache-Control: no-cache`, `If-None-Match`, 304 keeps the copy) | done | At start, on a profile / members list (30 s), after admin / agent changes. No test against a server. |
| HTTP API (guest links, channel guests, whois, agents, invites, join, guest save, places, admins, follows, username, sessions, website, events) | done, never run live | `Net/Api.swift`, `Net/EventsApi.swift`; fixed messages by `error` code. |
| Relay, NIP-46, sync engine, DMs, e-mail | done (milestone 1) | Engine tests against fakes. |

## Sign-in and joining

| Web feature | Status | Notes |
|---|---|---|
| Native sign-in (iOS / Android only; the web has none): `name@domain` → 6-digit code by e-mail → session, no browser | done, never run live | SPEC 19.20, the belfry's session endpoint (belfry.json `sign_in.sessions.api`) + `/verify`, signed (NIP-98) by this phone's session key. The default. Fixed messages per `error` key (503 `signer` → a new code at once); the masked address is shown only when well-formed; the signer's key must be the one the belfry named; the pending request and, after a right code, the bunker address survive the app being killed (Keychain). Six boxes over one numeric field with the one-time-code hint. Core-tested against a stub belfry and a fake signer (`NativeSignInTests`); screens as screenshots (35–37) with made-up values. No code was ever mailed to this app; the keyboard, paste, the Mail code suggestion and the real NIP-46 connection after the code are unverified. |
| Six code boxes after a failure (web village-app 8cd92ac, Android 2385da4; #issues 2026-11-13), in the sign-in and the Join sheet | done, never run live | The field has no length limit; `NativeSignIn.next(old:raw:)` picks the digits: "123 456" / "Code: 123456" fill all six, a whole code pasted over a full row replaces it, a seventh digit typed changes nothing (core-tested with Android's cases). A failed connection (offline, timeout, 5xx, 429) keeps the digits and shows "Try again"; only `wrong_code` / `expired` clear them (sign-in: `expired` still goes back to the address, "Send a new code"). Join sheet only: after an attempt whose answer was lost, an `expired` / `wrong_code` / `not_guest` first looks on the relay for up to 6 s for this key's save since that attempt (1985 `belfry/guest` saved / member, or a 9000 with a name and no `reading`: `GuestJoinSaved`, core-tested) and counts it as joined. The web also retries the call up to 4 times and again when the page comes back to the front; this app does neither (Try again is manual). No whois fallback (a saved guest is still a guest there). |
| Sign in with e-mail + code (`/connect`, PKCE → bunker) | done, never run live | Now the second way: the row "Sign in with the browser instead" (domain from the address typed, or a bare domain), and the main button on a belfry without `sign_in.sessions.api`. `ASWebAuthenticationSession` → `sh.belfry.app://connect` (approved server-side). |
| Guest link `https://chat.<domain>/join/<token>` signed out: guest mode, no name screen (web b2e968b, SPEC 19.26) | done, never run live | `{}` signed by a new session key (one per invite in the Keychain; `session_taken` → once more with a new key); one loading screen "Opening # name…" until the groups relay's EOSE / refusal / 10 s, nothing else drawn; a link that can't be used gets its own screen. Universal link entitlement for `chat.belfry.sh`, `chat.enspiral.eu`; the server serves no `apple-app-site-association` yet (SERVER-NEEDS 5), so links open the web chat until then. Screenshots 30 (loading) and 38 / 41 (the channel in guest mode) in demo mode. |
| Guest mode: read only, "Guest mode · You're reading #channel as a guest." + Join; nothing sent (messages, replies, reactions, RSVPs, votes, seen marks, uploads, DMs, push registration) | done | One check, `GuestModeGate`, in the outbox, signed HTTP calls, uploads and DM sends (core-tested: nothing reaches the outbox, each refusal asks to join); holding a message opens the Join sheet. A write refused inside another sheet (channel details, event page) shows the Join sheet only after that sheet closes. |
| Join sheet: name + e-mail → "Check your e-mail" (six boxes, Send a new code 30 s, Use another address) → joined; `taken` → Sign in instead (then the channel) | done, never run live | `/guest/save` + `/guest/save/verify` with `name`; fixed messages by code (core-tested against a stub belfry: `moved`, `tries_left` → "N tries left.", `nip05` → prefills the sign-in's address). Screenshots 39 / 40. Sign in instead ends the guest session unless `moved`, wipes the phone and shows the sign-in; the channel opens after it. No code was ever mailed to this app. |
| Others' reading guests: no join line, out of members / counts / active / mentions; "N guests are reading" in Members | done | `Group.reading` (core-tested, incl. a held meeting guest who stays visible; Android's `vectors/guestmode.json` passes); demo #general has two readers (screenshot 26). |
| Guest link opened by an account: joins as itself | done, never run live | Sheet "Join with your account"; another community's link → fixed message. |
| Pending invite kept through sign-in | done | Only domain + token kept (UserDefaults). |
| Closed / expired / unknown link | done | Fixed messages by `state` / 404. |
| Save your account (guest by name: e-mail + code) | done, never run live | Bar above the composer after my first message, and a card on Me; both open the Join sheet with the e-mail only. |
| Sign out ends the session | done, never run live | `POST /me/sessions/revoke {bunker_pubkey}` (best effort, 3 s), then the device is wiped. |
| Signed-in devices: list, this device, end one | done, never run live | |
| Demo mode | done | "Try the demo"; `-demo -screen …` for screenshots. |

## Layout and navigation

| Web feature | Status | Notes |
|---|---|---|
| Phone layout: ☰ with a count (unread DMs + new @mentions + requests) → the channel drawer from the LEFT (web Phone.tsx / drawer.ts) | done (2026-11-15) | `DrawerContainer`: the page slides right (snappy 250 / 200 ms), shade, tap or drag left to close, edge swipe from the left at the stack's root (not over a pushed thread, where the swipe is the system's back). iPad keeps a split view with the same list as its sidebar. The finger-following feel is untested on a device. |
| Drawer content: the belfry's name (admins: opens Belfry settings) + logo + cover (no search field since 2026-11-18, the owner: search is each channel's magnifier), Requests, Upcoming events, @Mentions, Direct messages, Public channels / Members only (admins' order), groups nested under their channel, Your events, Create a channel, you at the bottom (→ Me) | done | Order: 30078 `belfry:channel-order` by a belfry admin (core-tested); public = the channel's web page on and `visibility: public` (core-tested). Admins reorder within each section (Order of the channels); moving across sections (a visibility change) is the web's. |
| @Mentions screen (web Mentions.tsx) | done | Messages and replies that tag me or name my npub, newest first; a tap opens the message (or its thread); opening marks them seen (the badge counts newer ones). Core-tested. |
| Channel header and pull-down (the owner, 2026-11-17): subtitle lock/globe · "N active" · photos · groups; the line under it only for attention (topic filter, my vote, applications, unanswered event, pinned message, to-dos on me / free); pull-down = description, address, pin not hidden, then rows pushing screens (Pinned, Events, To decide, To-dos, Photos, Files, Groups, Topics, Members, Notifications, Log, Settings) | done, never run on a device | SPEC 19.13 (iOS note), `Derive.attentionLine`, `ChannelPlaces.swift`, `PullDown.swift`. The web still shows its line; this is ahead of it. The header never had a bell on iOS (Notifications is a row). |
| Channel header: #name (or the place's name) and the subtitle above | done | The visibility line ("Public · <domain>/<slug>") left the header; the lock / globe stays. |
| Pod marks (polygon, one side per member; circle from 13) | done | Sidebar, header, cards, pull-down. |
| Back buttons never push | done | NavigationStack pops only. |
| Large screens: thread in a third column | not yet | Threads open as a pushed screen on iPad too. |

## Channel feed

| Web feature | Status | Notes |
|---|---|---|
| Messages, day separators (year for other years), blocks, Markdown, links | done | Layout rules of SPEC 19.7 from the core (`feedRows`). |
| Mentions (@ picker marks "not in this channel"; tap → profile) | done | Note above the field for a picked person who can't read the channel, with Invite / Add as a guest. |
| #channel references (# picker → `nostr:naddr…`, "#name" opens the channel) | done | Unknown channel "#channel", other naddr "Nostr address" (never raw). Edit shows them as "#name" again. |
| #topics (chips for topics not spelled, tap filters the channel) | done | Pin / unpin in the pull-down's Topics. |
| Photos in messages, lightbox (web dabedd9, SPEC 19.23) | done | A tap opens the message's photos full screen: swipe through them, pinch 1×–5×, double tap 2.5× and back, drag down to close (the black fades), ✕. Other files as attachments: not yet (photos only; audio below). |
| Audio in messages (web 59c4b10) | done | A player per `audio/*` attachment: play / pause, position / length, a slider while playing, one at a time (AVPlayer), nothing fetched before play. The web's Safari recordings (AAC/MP4) play; Chrome's Opus-in-WebM can't on iOS: "This recording can’t play on this phone." |
| Audio recording (web Recorder.tsx, SPEC 19.25) | partial, never run on a device | ＋ → Audio recording: Start (microphone asked then; not under 50 MB free), pause / resume, a call or alarm pauses and resumes it unless paused by hand, Stop → Post / Discard. AAC 32 kHz mono 48 kbit/s into a CAF on the device; Post makes an .m4a without re-encoding and sends "🎙 Recording · m:ss" + the file through the outbox. **Background mode `audio` added** so it records with the screen locked. Not yet: 30-minute parts, "Which event or meeting was it?", offering an unfinished recording after a crash. |
| Reactions (quick row in the menu, more, undo) | done | Since 2026-11-18 also on a reply in a thread (the owner): the same quick row and "More reactions" when a reply is held, the reactions under the reply; the kind 7 carries `k` = 1111 (NIP-25). The held row is lifted on a ground of its own (it was drawn over its neighbours in a thread). Never run on a device. |
| Threads: "N replies" line (faces, last reply's time) → the thread's own screen; resurfaced threads open it too | done | Replies always open the thread (web 9cbb1cb): no unfolding in the channel any more. Reply in the menu opens it with its box focused. |
| Drafts (web f845d47, 5ccc71f) | done | Unsent text per channel (`c:<id>`) and thread (`t:<group>:<root>`) on the device; forms (new todo, group, proposal, thread) keep their fields until sent. Picked @mentions and #channels are kept with the draft (2026-11-18). |
| Agents marked where they write (web 683c974) | done | "<member>'s agent" / "Your agent" / "Agent" next to the name, in the feed and in threads. |
| A channel that takes one type of post (web 193557f, a325118) | done | Its "Posts" setting (`posts` in the channel's web settings): threads only → "New thread" (title + details, posted as the web's bold title + `subject`), proposals only → "New proposal", events only → "New event" (its card posted at once) instead of the message box. Choosing the setting is the web's (channel settings). |
| Todo wording, no todo mark on messages (SPEC 19.23) | done | "Todo" / "Todos" everywhere; the to-do mark is gone from messages. |
| A todo being worked on: the ring (web d6cfae1, SPEC 19.21) | done | 2101 `working` heartbeats per assignee, fresh 5 min; the ring fills with the minutes of the current stretch ("1h"… inside past an hour). Core-tested. |
| DM reactions (web 9641996: NIP-17 kind 7 in gift wraps, kind 5 to take one back) | not yet | Came to the web after this pass started; their read state never counts them. |
| Read state across devices (SPEC 19.27, web readcore.ts aa778e2, Android 90f0762) | done, never run live | One NIP-44 (to myself) kind 30078 `belfry:read` on the community relay, max-merge (vectors/readstate.json in the core tests), published through the outbox only after the relay's EOSE, debounced, flushed on background; guests / guest mode / demo keep it on the phone. Channels read on screen; threads, conversations, @Mentions; unread counts in the drawer (bold + count), "N new" on a thread's line, the DM list and ☰; delivered notifications of a channel read elsewhere are removed. |
| Members directory (web Directory.tsx 8f0ccb8 / 98c33fc, `POST /whois {"directory": true}`) | done, never run live | Invite button top right (`person.badge.plus`, Xavier 2026-11-15) for who may invite members: the invite sheet preset to a member with the default role on #general (else the first public channel). Members is the drawer's first row (not for guests; "N requests waiting for you" + count). At its top the request sections (agents, people asking to join the belfry: any member vouches, admins accept / decline; my groups' requests), then every member with their agents under them, search, role badges. No separate Requests screen (a link to requests opens Members). |
| Edit my message, "edited" mark | done | Edit sheet; core test. |
| Delete with an in-app confirmation showing the message | done | Inside the menu sheet. |
| Message menu as a list (reactions, Reply, Open thread, Edit, Copy text, Copy link, Message the author, Pin, Turn into a to-do, Make this the website, Delete) | done | Sheet with grouped rows and line icons. "Copy link" copies the channel's link (no per-message link on the web either). |
| Pin / unpin (admins), pinned mark | done | |
| Turn into a to-do; the mark ticks it off | done | |
| Outbox states: Sending… / Waiting… / Not sent · Retry, Discard | done | Retry / Discard lock while they run. |
| Announcements (admins), marked | done | |
| Join lines (guest / agent / member's agent, invited by, not saved; hidden when removed without writing) | done | |
| "Created a pod / a proposal / an event" + cards | done | Pod, proposal, event, member e-mail, inbox card, sent-as-channel. |
| Composer (iMessage's shape, 2026-11-15) | done | A glass ＋ circle the height of the field, on its centre line (44 pt target); the field a capsule that grows to 6 lines with Send inside its trailing edge (filled when there is something to send); glass on iOS 26, bordered before; haptic on send; the feed scrolls to the bottom. Drafts per channel and thread on the device. Since 2026-11-18 the field is the system text view (`MessageField`): each picked @name and #channel is marked in the text as it is typed (semibold on a soft tint), names with spaces included; a name edited so it no longer matches loses its mark and is sent as plain text. Never run on a device. |
| ＋ menu: Photo, Todo, Event, Meeting, Proposal, Group, Audio, Drop box link, Announcement | done | A native `Menu` with icons (iMessage's). |
| Message menu | done | Held message → the native context menu: four quick reactions + More in a row, then Reply, Open thread, Edit, Copy text (checkmark haptic), Copy link, Message the author, Pin, Turn into a todo, Propose as the website, Delete (opens the confirmation showing the message). |
| Seen events (6 h) and "active this month" | done | |
| Search (this channel / all, accent-folded, marks, opens on the message with a flash) | done | |

## Channel info

| Web feature | Status | Notes |
|---|---|---|
| Channel info (tabs in a sheet) | replaced (2026-11-17) | Every tab is now a screen pushed from the pull-down; About's parts: the description and the address at the top of the pull-down, the follow bell → Notifications, the active list and Join / Leave → Members, events / groups / proposals → their rows. |
| Log (SPEC 19.23) | done | Every event with the channel's `h`, newest first (1000), a section per day; the web's words per kind (core-tested); the relay's and the groups key's lines read as the community; a tap unfolds the detail, the full date and "Go there" (the message, the thread, Todos, Members). Not yet: day chips that jump, developer mode's "Inspect the Nostr event". |
| About: description, e-mail address, follow bell, active list, events, pods, proposals, join / leave | done (moved) | See the row above. |
| Members: guests / agents / not saved, invited by, admin | done | Face, name, the role here as secondary text ("Admin", "Guest · invited by Ana"); no label icon (Xavier 2026-11-15); a tap pushes the profile with "In #channel". Members map (Leaflet on the web): not yet. |
| To-dos: add, tick, take / let go, comments, delete own | done | Since round 7 (2026-11-18): rows open the to-do's own screen (SPEC 19.41); comments and delete live there. |
| Photos (grid, lightbox) and Files (drop box links: new 1 day / 1 week / 1 month, anyone / signed in; QR, share, end; other files) | done | Two rows of the pull-down; a drop box link is also made from the composer's ＋ menu ("Drop box link"). |
| Settings (admins): name, description, group access + question, "E-mails from anyone" | done | The Posts / Visibility settings and moving a channel between Public and Members only are the web's. |
| Invite sheet (web Invite.tsx 076dea1, canvas inviting/sheet-from-channel, sheet-external, sheet-from-members, 2026-11-18) | done, never run live | From a channel, event or proposal: "Invite someone already in the community" first (a name → Send the link / Invite / Add as a guest, a direct message with the link), then the folded row "Or invite an external person" (no link is made until it is opened): the QR and the link, "Joins as" (guest for a day / a week / a month; my own agent; for who may invite members a member with a role for one month / one year / permanent, Edit roles… for admins), "Link" (one person / up to 50, opened for 1 day / 1 week / 1 month; a Steward's or an agent's link is for one person, said under the choice), Copy link / Share…. From Members: "Invite to <community>", no name search, the link at once, preset to a member with the default role, permanent. A newer choice wins over an answer on its way; errors by code with Retry. |
| Follow bell (off / as they happen / monthly) | done, never run live | |
| Groups (was pods, web b43f9cf): "group" everywhere people read it | done | The protocol keeps `pod-…` ids and the `pod` tag; the card text this app posts is still "⬡ New pod: …" (core, shared vector `groups.json`; the web now writes "New group"). |
| Group page (web GroupPage.tsx): the card opens it | done | Description, "Group in #parent · by request / open to members", Follow (e-mail bell), who's in with admins, Join / Apply to join / Pending / You're in, Have a look; its requests for its admins. |
| Groups by vouches (docs/membership.md) | done, never run live | `vouches` on the 9002 (core-tested), vouch / withdraw labels 1985 `belfry/vouch`, "N of M vouches · names", then `POST /group-requests/check`. Setting the number on a group: not yet (the web's group settings). |
| Requests (web Requests.tsx `RequestSections`, 98c33fc): at the top of Members, only when something waits; the count on Members (first row of the drawer) and on ☰ | done, never run live | Agents asking to join (admins: Let it in as my agent / Decline), people asking to join the belfry (admins: Accept / Decline; members vouch while the belfry accepts by vouches), requests to every group I run or vouch in. Askers' words as plain text. Refreshed when the drawer shows and on pull. |
| Proposals: card, status, tally, vote, change status, new version (author) | done | |

## Belfry settings (admins)

| Web feature | Status | Notes |
|---|---|---|
| Belfry settings: the gear at the top of the drawer (2026-11-17) | done | Branding, Roles, Membership, Channels (categories, SPEC 19.34); the rest (mail, website, add-ons) is the console's. |
| Roles (docs/roles.md) | done, never run live | List with the default and how many have each; new / rename / describe / default / delete (Member and Admin built in); fixed words per error code. Role labels on profiles and in Members; a member's role from their profile (a native menu; a saved guest given a role becomes a member). |
| Membership (docs/membership.md) | done, never run live | Who invites members (admins / any member), how requests are accepted (admins / N vouches, 1–5). |
| Branding (web Branding.tsx) | done, never run live | Logo and cover (uploaded to the belfry's Blossom, ≤ 512 / 1600 px), primary and secondary colours (system colour picker), the description; `POST /branding`; the app takes the primary colour as its tint at once. |
| Website proposals (web 6d267c1) | done, never run live | "Propose as the website" on a message with an nsite link → a new proposal (in #website when there is one) with the version's `website` tag and a preview link; the proposal shows "Preview this version" and how it goes live (a belfry admin marks it Passed). Replaces "Make this the website". A version for part of the site (`path` tags, SPEC 19.44) keeps them on every new version and says which part goes live; the publish button asks about that part only. The web does not read `path` yet. |

## E-mail

| Web feature | Status | Notes |
|---|---|---|
| Member's e-mail as their message ("via e-mail", subject) | done | |
| Inbox cards: sender, verified, subject, Open / Answered / Closed, take / let go, close / reopen | done | |
| Reply by e-mail as the channel, 8 s Undo | done, never run live | Admins only. "Full e-mail" (original from Blossom): not yet. |
| DMs, e-mail threads | done (milestone 1) | |

## People

| Web feature | Status | Notes |
|---|---|---|
| Profile: picture, name, address, about, tags, place, chips, shared channels, Message | done | A contact card pushed on the stack (Contacts; inside a sheet, on that sheet's stack): Message / E-mail / Share, About, Tags, Place, Role, Owner / Agents, channels in common; Edit on my own. |
| Agents: "agent of …", Make it my agent, Remove this agent… (confirmation), error codes | done, never run live | |
| Edit profile: name, username (`POST /username`), about, picture (≤ 512 px), tags with suggestions, place (city search, add a place, country only, nothing) | done, never run live | Never device GPS. |
| Role instead of "Admin of the belfry" | done, never run live | Role section: Member / Admin / a custom role with its line; Guest / Agent of X. Belfry admins open the role picker (Admin through /admins with its error codes, others /member-roles; locks while saving) and Edit roles…. |
| Me: card, address, key copy, devices, outbox count, save account, sign out | done | |

## Belfry events (SPEC 19.18)

| Web feature | Status | Notes |
|---|---|---|
| Model: `ev-<d>`, rule B, status, versions, visibility, slug, cover, channels | done | Core tests. |
| Cards from `https://<domain>/events/<link>` (sent with the `a` tag) | done | Up to three per message. |
| All events (Upcoming / Mine / Hosting / Past), New event | done | An open screen from the drawer (☰, ＋), the picker under the bar, events edge to edge; an event's page is pushed. A time whose end is its start shows the start alone. |
| "Your events" in the sidebar | done | |
| Event screen (SPEC 19.29; Xavier 2026-11-15; not in the web chat yet) | done | Pushed from Events, a card, a universal link, Your events (an `ev-` group opens as it). Header at three levels with the pull-down's handle: half (opens there: cover under the bar, title, when, where → Maps, my status as the main control, faces + "12 going · 3 maybe"), up (the bar says title · date · my state; typing in the chat goes up), full (hosted by, asking with Approve / Decline, going, maybe, description, address with Copy / Share, hosts' tools: edit, tickets, invite a co-host, cancel / reopen, delete). Chat · Photos · People (segmented; all kept in the tree): the group's feed + composer; photos newest first, three to a row, Add photos (≤ 20, one message through the outbox), the lightbox; hosts (Host / Co-host / Steward) / going / maybe with a message button, a tap pushes the profile. Without access (no ticket, a guest reading through the API): the header and the description only. Replaces the event page sheet. Screenshots 22, 63–67, 80–82 (UI test drags the handle). |
| Tickets: Get tickets / Show my ticket (SPEC 19.29) | done, never run live | Get tickets = the ticket types (take / apply / waitlist). Show my ticket = full screen: the QR (CoreImage, no interpolation, white quiet zone in dark mode too), name, ticket, event, time, "Checked in at …"; brightness to full while shown, back after (and when the app leaves the front). Code + address kept per event on the phone. Needs `viewer.ticket_code` (an older belfry: no button). Brightness never seen on a device. |
| Check-in (SPEC 19.29) | done, never run live | "Check people in" on the header on the event's days for host / co-host / steward, always in the ⋯ menu and the People tab. Camera on top (VisionKit DataScanner, as the invitation scanner; scans without a tap, same text ignored 3 s), result card 2 s green / amber / red + haptics, "12 of 40 checked in", search, tap to check in (locks with progress), tap a checked one → "Undo check-in?". List only when the camera is refused (a row opens Settings) or missing. List seeded from the stored answer + the groups key's `belfry/ticket` labels, refreshed by `/attendees`. The camera, the haptics and the live API were never exercised (the simulator has no camera: the demo shows a placeholder where it goes). |
| Ticket link `chat.<domain>/events/<link>/t/<code>` | done, never run live | Opens the event; for who may check in, a card: name, ticket and state from `peek` (nothing recorded by opening the link), then Check in → "Checked in at …" / "Already checked in at …" + Undo. |
| Roles per channel / group / event (SPEC 19.29) | done, never run live | Stewards and check-ins from the groups key's labels; a group's admins = latest 39001 ∪ creator ∪ admins by role (latest 9000 `p … admin` / `role member` / 9001 per person), as the web's `checkin` branch (core-tested). "Remove from" = `/group-roles` `removed`, 9001 on an older belfry; `always_admin` and the web's words for every code. People lists without the label icon (face, name, role as secondary text); the profile from a list shows "In <group>": a picker for that group's admins and belfry admins (Member / Admin; Attendee / Co-host / Steward), `POST /group-roles` with fixed messages, "Remove from <group>" (9001). The old per-member labels editor is gone. |
| Hosts: asking (approve / decline, one lock), co-hosts and stewards from a profile's "In <event>", tickets sheet, co-host link, cancel (with a line) / reopen, delete (creator) | done, never run live | In the header's full level. Guest co-hosts decide through `POST /events/<d>/decide`. "Make co-host" moved to the profile's role picker; "Take the place back" is "Remove from <event>". |
| Create / edit: title, cover upload, all day, start / end, where (suggestions), online + Jitsi, description, who sees it, who can come (application + question), URL checked as typed | done, never run live | Times in the device's zone (no zone picker). Made from a channel's ＋: the URL goes into that composer. |
| Events read through the API (guests) | done, never run live | Cached a minute; `members_only` / `not_found` → fixed messages. |
| Opening `https://chat.<domain>/events/<link>` from outside | done, never run live | Universal link (same entitlement as guest links); needs SERVER-NEEDS 5. |
| Meetings (web core/meetings.ts, ui/Meeting.tsx; SPEC 19.23) | done, never run live | ＋ → Meeting (not for guests): topic (≤ 200), a grid of faces (the channel's most recently active, then its parent's, then members; tap picks), + adds someone here by name or someone new by name / e-mail, when (the next full hour), how long (30 / 45 / 60 / 90 / 120), where (my last meeting's place; the last five as rows; a Jitsi video link). A members-only Belfry event with `t meeting`, `channel`, `p … invited`; closed chat with each member invited put in it; every later version keeps those tags (the event form too); its URL goes into the channel's message box. People not on the belfry: `POST /meeting-guests` (retried up to 6 times, 1–5 s apart, on no_channel / not_host / signer / no connection), then one new version with their tags. The page: "Meeting · members only", "People · N · M there" with each person's state (There / Going / Maybe / Can't go / Host / Invited, "· account held by you"); hosts Confirm / Check in (an hour before) / ✓ There (1985 belfry/attendance), Add someone, Hand over (`/meeting-guests/transfer`, swipe or hold the row). Rows and cards say "Meeting" and "N people"; Your events include meetings I'm invited to. Core-tested (`MeetingsTests`, a stub belfry for the retries). |
| Signed-out event page (RSVP with a name) | not yet | Sign in first. |
| Co-host link used by someone new (e-mail first, then the link again) | done, never run live | `email_needed` → save-account card says why; after the code, the link is used with the account. |
| Prices, payments | not in v1 | Neither on the web. |

## Deleted and archived groups (SPEC 19.30, the contract of 2026-11-16)

| Item | Status | Notes |
|---|---|---|
| Deleted: by a 9008, or by the relay's answer about the group's metadata; "unknown" before that | done, never run live | Core-tested (`ArchiveTests`). The question to the relay (`39000` with `#d`, #general as the proof of an answer) was never sent to a real relay: whether zooid answers it for every channel and closed group a member is not in is unverified. Not for guests. |
| A deleted group's card: name from the card, "This group has been deleted", greyed, not a button | done | Screenshot 73. |
| A route to a deleted group: "This group has been deleted" | done | The channel (drawer, link, notification, search, `#` reference) and the group's page. Screenshot 74. |
| Archived: `["archived","1"]` on the latest 9002 that says so; in no list; read only | done, never run live | Banner "Archived · read only" + Unarchive; no composer (a line where it was), no menus, reactions, inline replies, thread composer, to-do changes, drop links, invite, follow, roles, settings. The outbox refuses anything else for it (`GroupLock`). Screenshot 75. Notifications of an archived group are the belfry's to stop. |
| Archive (settings, with the confirmation) / Unarchive | done, never run live | Own 9002 keeping every setting for admins the relay knows; `POST /group-meta {"archived"}` for admins by role, with fixed messages (`archived`, `always_open`, "This belfry can't archive yet: it needs an update."). The iPhone app has no Delete: Archive sits at the end of the settings. |
| "Archived" at the bottom of the channel list → a screen | done | Screenshot 76. |
| The group's page is a pushed screen, not a sheet | done | Screenshot 77. |

## Several accounts (SPEC 19.24; not in the web chat)

| Item | Status | Notes |
|---|---|---|
| Accounts per identity and belfry, slots, migration of the one session of earlier versions | done, never run on a device | Core-tested (`AccountsTests`). Slot "" keeps the earlier Keychain item, database and defaults names: the migration writes the list only. |
| Switcher behind "you" at the drawer's bottom: accounts (face, name, address or "Guest · community", a check), Add an account, Me | done | A sheet list (screenshot 62); switching stops the open session and opens the other from its store. |
| Add an account | done, never run live | The sign-in (address + code, browser, scan) over the app with Cancel; the open account runs until the new one is in. Opening a guest link while adding uses the open account (Android asks "which account"): not yet. |
| Sign out of the open account only, then the next | done | Sign-in screen only when none is left. |
| Push per account | done, never run on a device | One K per account; each registers the same token when open; the extension finds the account whose K opens the payload and a tap opens that account first. Android's "the notification names the account" and the per-account dot in the switcher: not yet. A non-open account's outbox waits until it is opened (as Android). |

## Not in the web chat, or out of scope

| Item | Status | Notes |
|---|---|---|
| Notifications (APNs, docs/push.md; SPEC 19.19) | done, never run live | Notification Service Extension `sh.belfry.app.notifications` decrypts `b` with K (core-tested with sample payloads), sets title / body / thread / url; K in the keychain group shared through the App Group; registers on every start once allowed (`/push/devices`), removed on sign-out before the revoke; asked from a "Get notified" row in a channel or Me → Notifications (never at launch); settings (four switches, a level per channel; the channel bell shows its push level); a tap opens the channel at the message (a thread reply: its thread) after checking `domain` and `chat.<domain>`; `vectors/push.json` (the server's payloads) in the core tests; own DM echoes within 30 s are silent, and none show in the foreground while a conversation or that channel is open. Needs the Apple portal set-up (SERVER-NEEDS 3) and the gateway; the web chat has none. |
| OSV access grants | n/a | Hidden in the Belfry theme. |
| Web changes after this pass started (village-app 46ce39c, 0612cd3, 7e14fdb, 9641996) | not yet | Channel header shows the address alone and the pull-down says who reads and who can post; admins pick plain addresses (channel, event URL, page); Me → Sign-in methods (e-mail code, passkeys); DM reactions. |
| TestFlight | waiting | The job runs when Xavier adds the four App Store Connect secrets. |

## Five places, the charter, Add an agent (iOS first, 2026-11-16; the owner's canvas, SPEC 19.31 / 19.32)

Not in the web chat or Android yet: the iPhone app leads here. Screenshots 100–114.

| Item | Status | Notes |
|---|---|---|
| Bottom bar Home · Calendar · Create (＋) · Groups · Town; a stack per place (only the open one is built, its path kept), the bar at each root (pushed chats cover it, the keyboard hides it), the selected place tapped again goes back to its root, the last place reopens | done | `Tabs.swift`. iPhone only: the iPad keeps the split view with the old sidebar. |
| Home (2026-11-17): the date as the big title, ☰ (the Town drawer) top left; To-dos · Mentions · Messages tiles always ("Nothing new" when calm, still a shortcut); requests, a new agreement, Recent activity, then Coming up (7 days; else the next on my calendar) | done | `HomeView.swift`. No "all caught up" card any more; the belfry pill left Home (accounts: the drawer's person row). Calendar and Groups have the same ☰ and drawer since 2026-11-17 (no pill anywhere). "My to-dos" across channels (`MyTodosView`). Red dot on Home = requests + mentions + DMs + to-dos on me + agreements. |
| Calendar: My calendar · Invited · Discover, week strip (Monday first, dots, back = that week's past events), Today / This week / Later, ＋ new event | done | `CalendarView.swift`. Rows push the event screen (RSVP / check-in stay there). |
| Groups: My groups · Active · All (Join / "by application"), Archived row, ＋ = Create with Group first | done | `GroupsView.swift`. |
| Create sheet: Where (a channel), Message (opens the channel with the keyboard), Event, Meeting, To-do, Group, Proposal (their existing forms in the same sheet) | done | `CreateMenu.swift`. The forms replace the list inside the sheet instead of pushing (they have their own navigation). |
| Town: the Townsquare with ☰ = unread town channels; drawer (also from Home) = cover, mark, name, member count, gear (stewards: Belfry settings), search, Today, The town (Townsquare, Members, Charter), the categories each with ＋ (SPEC 19.34; Community life shows empty to every member, so the first channel can be made), Archived, you (tap → Me pushed, ⇅ → accounts); stewards long-press and drag channels within and across categories | done, drag never run on a device | `TownDrawer.swift`. "Create a channel", "Order of the channels" and the "Belfry settings" row left the drawer. |
| Names: #general reads Townsquare (only while the default name stands; Square, Fairground, Assembly, Scriptorium dropped 2026-11-17: events / proposals / website show their own names), Members (was Gates until 2026-11-17); roles Steward · Member · Guest; the check-in role shown as Door | done | Core-tested (`CharterTests.testPlaceNames`, `testPlaceNamesVectors` on `vectors/placenames.json`). The "turn the names on for an existing belfry" switch of the Names board is not built. |
| Charter: page, ticks, counts, "You agreed", stewards write / edit / reorder / remove, Agreed / Not yet, Home reminder, drawer row | done, never run live | SPEC 19.32, `vectors/charter.json`, `CharterTests`. Copy `charter.json` and `mailthreads.json` to Android. |
| Add an agent (own profile, members): explanation, sheet with a one-line prompt + Copy / Share, my agent with Remove instead, stewards may add more | done, never run live | `AgentUI.swift`; `POST /channel-invites {"agent": true}` in `general`. |
| Guests: Home (Apply first, time left, invited channels, open to everyone), Calendar (Public events · Going), Town drawer (Apply, invited, open to everyone, own row), Apply sheet | done, never run live | Round 2: `POST /applications {"apply"}` / `{"apply": "status"}` (state in words: "1 of 2 vouches", who vouched, "Not this time", Ask again), guest_not_saved → the save-your-account step in the sheet, the charter's agreements ticked one by one and sent as `agreed`, `GET /charter` for guests, `GET /events?visibility=public` merged into a guest's Calendar; all stored per account. Screenshots 114, 125. |
| Stewards' Members: a guest's request ("Guest in #general since …, invited by Ana", face) | done, never run live | Accepting makes them a member on the same key (no invite mail). |
| A new member's first minutes (Welcome → charter ticks "4 of 6 agreed" → name and photo, Skip) | done, never run live | The web's rule (`welcomeDue`); screenshots 124. Getting started on Home and the notifications ask are not built. |
| E-mail threads in a channel (SPEC 19.33): one row per thread in the feed, the thread with frames and replies, one composer with the line, Reply by e-mail from the plain alias with References, 8 s Undo; a member's mail with "via e-mail" by the time and "Full e-mail" in its menu | done, never run live | `MailInbox.swift` (core, `vectors/mailthreads.json`), `MailUI.swift`. The old e-mail sheet is gone. Screenshots 120–123. |
| Role picker Steward · Member · Guest, custom roles under them; "Townsquare" (no #) in the header of #general; calm Home with Mentions and Messages | done | |
| Channel categories (SPEC 19.34, `vectors/categories.json`): read / write in the order event, Belfry settings → Channels (rename, add, delete, reorder categories; move channels), ＋ on a category header | done, never run live | Core-tested (`CategoriesTests`). The web implements the same format in parallel. |
| A belfry with only #general (2026-11-17, collective-belfry 784d1a4): Create posts in the channel on screen or #general, Calendar / Home read every group, a website proposal goes to #website if it exists else the channel it came from | done | Nothing looks for #events / #proposals / #website by id. |
| Belfry settings → Channels: tap a channel → "Delete the channel" (nobody wrote in it) or "Archive the channel", confirmed in the sheet, button locks while it runs (SPEC 19.35, `POST /group-delete`) | done, never run live | `ChannelEnd.swift`, `AppModel.channelIsEmpty / deleteChannel`; UI test `testDeleteEmptyChannel` (demo); screenshots 133c–133f. |
| A to-do made from a message: "Open its thread" in the channel's To-dos | done | Web 2026-11-17. |
| Joining from the App Store ("Which belfry?", the belfry's card, Ask to join) | not yet | SERVER-NEEDS 13. |

## Round 5 (iOS first, 2026-11-17; SPEC 19.36 / 19.37)

| Item | Status | Notes |
|---|---|---|
| Buttons on messages (collective-belfry docs/actions.md): parse, press (1985, published at once), trusted answers (author; belfry key / groups key from belfry.json, `_groups` fallback), closed for everyone, my ok / error line, 20 s "No answer yet.", unknown `belfry:` action disabled, confirmations with the app's own text, Join sheet for a reading guest | done, never run live | `vectors/message-actions.json` (= docs/actions-vectors.json, copy to Android under this name), `ButtonsTests`. Demo #website, screenshots 150. The web has none yet. |
| Links always look and act like links (underlined in the tint), this belfry's chat links open in the app | done, never run on a device | `Links` (core, `LinksTests`); `ThreadActivity` no longer takes the taps on links. |
| Channel settings: prominent Save, Archive as a centred link, save applied at once and back to the channel; through the outbox (own 9002, or a queued `POST /group-meta` signed at send time); error mark by the name with Try again / Discard | done, never run live | SPEC 19.37, `SettingsQueueTests`, screenshots 151–152. |

## Round 6 (iOS, 2026-11-18; the owner's mock-ups Notif-C, Settings-A/B, Mail-A/B, Proposal-A/B; SPEC 19.38–19.40)

| Item | Status | Notes |
|---|---|---|
| A channel's Notifications = one sheet (Everything / When it's for me / Nothing, applied at once with a haptic, "(the default here)"; "Also e-mail me its announcements") | done, never run on a device | `NotifySheet.swift`, `NotifyChoice` (core). The one pull-down row that opens a sheet (the owner's choice). The middle line says what `default` really sends (web 8d31c30). |
| Settings → "Who can read it" (channels and groups; a group's question and vouch rule under Closed): Members only / Public (asks first) / Closed (never #general); public / members as web periods, closed as the 9002 flag; saved through the outbox | done, never run live | SPEC 19.38, `vectors/visibility.json` (ours: copy to Android), `VisibilityTests`. |
| Closed channels: read only + "Ask to join" / "Pending" for someone outside; "Asking to join" at the top of the channel's Members for its stewards | done, never run live | Stewards by role can't accept (relay + server: SERVER-NEEDS 15). Demo #Board. |
| E-mail thread: every entry a message row with "guest, by e-mail" / "sent as hello@" / "team only"; Reply to <name> (default, blue) / Comment (yellow) with the line under them; feed row shaped like a message | done, never run live | SPEC 19.33 (round 6 bullet). Screenshots 120–122d. |
| A proposal at the top of its chat (three levels, votes with the poll's own options and counts, turnout, folded bar with Vote) | done, never run live | SPEC 19.39, `ProposalScreen.swift`. Chat · Versions (once a version 2 exists) · Votes (once someone voted), as web 763910e. |
| A new profile picture everywhere at once | done | SPEC 19.40: the cause was `CachedImage` keeping the old picture when the new address was already cached; `PictureSlot` (core-tested). |

## Round 7 (iOS, 2026-11-18; the owner's remarks from phones; SPEC 19.41–19.43)

| Item | Status | Notes |
|---|---|---|
| To-dos: Claim / Take it over, Assign to… (people who can read the channel, search, Nobody), Unassign / Let it go; rows = tick box (own 44 pt target) + the rest opens the to-do's screen with a chevron; comments, delete (⋯, author, confirmed) and "Open its thread" on that screen; no per-row Comment / Delete | done, never run on a device | SPEC 19.41, `vectors/todo-assign.json` (ours: copy to Android), `TodoAssignTests`, `TodoScreen.swift`. New wire actions `assign` / `unassign` (+ `p`), Android SPEC 19.40's format: the web doesn't read it yet; claim / unclaim are still what is sent for oneself. No title edit (none on the wire). |
| Member links: no channel preview, "You're invited to join <community> as a <role>" with Sign up / Log in; the link is read first and used only on Sign up (Log in keeps it for the signed-in account) | done, never run live | SPEC 19.43, `MemberInviteScreen`, `-join member` (screenshots 143). Differs from the web, which uses the link on opening. |
| `/guest/save/verify` `member: true` (and a saved guest's join `member: true`): a member at once (kinds stored, session out of guest mode, apply state / co-host token / invite gone, full resubscribe, belfry.json + whois again, the channel opens); `not_guest` from the apply form or the verify = whois → member already, no error; the form closes for a member | done, never run live | SPEC 19.43, `AppModel+MemberLink.swift`, `MemberLinkTests`. |
| A member reads every open channel (not only those whose 39002 has them); metadata always asked whole; a channel's name before its metadata = id without its random ending | done | SPEC 19.42, `ChannelNamesTests`. The subscription was never limited by group; the gap was `since` (metadata older than the window never came after a guest became a member). Push settings list every channel I can read. |
