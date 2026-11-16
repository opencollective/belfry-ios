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
| Drawer content: the belfry's name (admins: opens Belfry settings) + logo + cover, search all channels, Requests, Upcoming events, @Mentions, Direct messages, Public channels / Members only (admins' order), groups nested under their channel, Your events, Create a channel, you at the bottom (→ Me) | done | Order: 30078 `belfry:channel-order` by a belfry admin (core-tested); public = the channel's web page on and `visibility: public` (core-tested). Admins reorder within each section (Order of the channels); moving across sections (a visibility change) is the web's. |
| @Mentions screen (web Mentions.tsx) | done | Messages and replies that tag me or name my npub, newest first; a tap opens the message (or its thread); opening marks them seen (the badge counts newer ones). Core-tested. |
| One summary line under the channel name + pull-down FROM THE TOP (Pinned, Coming up, To decide, To do, Groups, Topics, people; description first) | done | SPEC 19.13 priority and counts, core-tested. `PullDownPanel` over the feed under the line: short level (55 %) and full level, handle drag snaps (up past the short level closes), tap outside closes; the title's chevron and a drag down on the line open it. Day labels fixed English, 24 h. |
| Channel header: #name and its visibility line ("Public · <domain>/<slug>" / "Members only", globe / lock) | done | Two lines in the navigation bar's title. |
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
| Reactions (quick row in the menu, more, undo) | done | |
| Threads: "N replies" line (faces, last reply's time) → the thread's own screen; resurfaced threads open it too | done | Replies always open the thread (web 9cbb1cb): no unfolding in the channel any more. Reply in the menu opens it with its box focused. |
| Drafts (web f845d47, 5ccc71f) | done | Unsent text per channel (`c:<id>`) and thread (`t:<group>:<root>`) on the device; forms (new todo, group, proposal, thread) keep their fields until sent. Picked @mentions / #channels are not kept with a draft yet (the text is). |
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
| Composer (iMessage's shape, 2026-11-15) | done | A glass ＋ circle the height of the field, on its centre line (44 pt target); the field a capsule that grows to 6 lines with Send inside its trailing edge (filled when there is something to send); glass on iOS 26, bordered before; haptic on send; the feed scrolls to the bottom. Drafts per channel and thread on the device. |
| ＋ menu: Photo, Todo, Event, Proposal, Group, Announcement | done | A native `Menu` with icons (iMessage's). Drop box links are in channel info → Files. Meeting / Audio: see below. |
| Message menu | done | Held message → the native context menu: four quick reactions + More in a row, then Reply, Open thread, Edit, Copy text (checkmark haptic), Copy link, Message the author, Pin, Turn into a todo, Propose as the website, Delete (opens the confirmation showing the message). |
| Seen events (6 h) and "active this month" | done | |
| Search (this channel / all, accent-folded, marks, opens on the message with a flash) | done | |

## Channel info

| Web feature | Status | Notes |
|---|---|---|
| Tabs: About, Members, Todos, Files, Log; Settings behind a gear for the channel's admins | done | Segmented control in a sheet. |
| Log (SPEC 19.23) | done | Every event with the channel's `h`, newest first (1000), a section per day; the web's words per kind (core-tested); the relay's and the groups key's lines read as the community; a tap unfolds the detail, the full date and "Go there" (the message, the thread, Todos, Members). Not yet: day chips that jump, developer mode's "Inspect the Nostr event". |
| About: description, e-mail address, follow bell, active list, events, pods, proposals, join / leave | done | |
| Members: guests / agents / not saved, invited by, admin | done | Face, name, the role here as secondary text ("Admin", "Guest · invited by Ana"); no label icon (Xavier 2026-11-15); a tap pushes the profile with "In #channel". Members map (Leaflet on the web): not yet. |
| To-dos: add, tick, take / let go, comments, delete own | done | |
| Files: photos, files, drop box links (new: 1 day / 1 week / 1 month, anyone / signed in; QR, share, end) | done | |
| Settings (admins): name, description, group access + question, "E-mails from anyone" | done | The Posts / Visibility settings and moving a channel between Public and Members only are the web's. |
| Invite sheet, option C (web Invite.tsx, docs/roles.md) | done, never run live | The QR and the link at once, for a guest for a day. "Joins as": guest for a day / a week / a month; my own agent (when `POST /agents` gives a limit); for who may invite members (belfry admins, or any member when Membership says so, default role only) a member with a role for one month / one year / permanent (Edit roles… for admins). "Link": one person / up to 50 (an admin's or agent's link is for one), opened for 1 day / 1 week / 1 month. Copy link (checkmark + haptic) and Share… as native rows; a newer choice wins over an answer on its way; errors by code with Retry. Then someone who is here already, by name. Member links opened: they join through guest mode and the belfry makes them a member on verify (the join sheet doesn't name the role yet). |
| Follow bell (off / as they happen / monthly) | done, never run live | |
| Groups (was pods, web b43f9cf): "group" everywhere people read it | done | The protocol keeps `pod-…` ids and the `pod` tag; the card text this app posts is still "⬡ New pod: …" (core, shared vector `groups.json`; the web now writes "New group"). |
| Group page (web GroupPage.tsx): the card opens it | done | Description, "Group in #parent · by request / open to members", Follow (e-mail bell), who's in with admins, Join / Apply to join / Pending / You're in, Have a look; its requests for its admins. |
| Groups by vouches (docs/membership.md) | done, never run live | `vouches` on the 9002 (core-tested), vouch / withdraw labels 1985 `belfry/vouch`, "N of M vouches · names", then `POST /group-requests/check`. Setting the number on a group: not yet (the web's group settings). |
| Requests (web Requests.tsx `RequestSections`, 98c33fc): at the top of Members, only when something waits; the count on Members (first row of the drawer) and on ☰ | done, never run live | Agents asking to join (admins: Let it in as my agent / Decline), people asking to join the belfry (admins: Accept / Decline; members vouch while the belfry accepts by vouches), requests to every group I run or vouch in. Askers' words as plain text. Refreshed when the drawer shows and on pull. |
| Proposals: card, status, tally, vote, change status, new version (author) | done | |

## Belfry settings (admins)

| Web feature | Status | Notes |
|---|---|---|
| The belfry's name at the top of the drawer opens its settings (web Settings.tsx) | done | Branding, Roles, Membership, Order of the channels; the rest (mail, website, add-ons) is the console's. |
| Roles (docs/roles.md) | done, never run live | List with the default and how many have each; new / rename / describe / default / delete (Member and Admin built in); fixed words per error code. Role labels on profiles and in Members; a member's role from their profile (a native menu; a saved guest given a role becomes a member). |
| Membership (docs/membership.md) | done, never run live | Who invites members (admins / any member), how requests are accepted (admins / N vouches, 1–5). |
| Branding (web Branding.tsx) | done, never run live | Logo and cover (uploaded to the belfry's Blossom, ≤ 512 / 1600 px), primary and secondary colours (system colour picker), the description; `POST /branding`; the app takes the primary colour as its tint at once. |
| Website proposals (web 6d267c1) | done, never run live | "Propose as the website" on a message with an nsite link → a new proposal (in #website when there is one) with the version's `website` tag and a preview link; the proposal shows "Preview this version" and how it goes live (a belfry admin marks it Passed). Replaces "Make this the website". |

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

Not in the web chat or Android yet: the iPhone app leads here. Screenshots 80–94.

| Item | Status | Notes |
|---|---|---|
| Bottom bar Home · Calendar · Create (＋) · Groups · Town; a stack per place, the bar at each root (pushed chats cover it, the keyboard hides it), the selected place tapped again goes back to its root, the last place reopens | done | `Tabs.swift`. iPhone only: the iPad keeps the split view with the old sidebar. |
| Home: requests, a new agreement, To-dos · Mentions · Messages tiles (each pushes its list), Coming up (7 days, state in words, no buttons), Recent activity (unread channels and groups), calm state | done | `HomeView.swift`. "My to-dos" across channels is new (`MyTodosView`). The red dot on Home's icon = requests + mentions + DMs + to-dos on me + agreements to read. No search on Home yet (the drawer still searches everything). |
| Calendar: My calendar · Invited · Discover, week strip (Monday first, dots, back = that week's past events), Today / This week / Later, ＋ new event | done | `CalendarView.swift`. Rows push the event screen (RSVP / check-in stay there). |
| Groups: My groups · Active · All (Join / "by application"), Archived row, ＋ = Create with Group first | done | `GroupsView.swift`. |
| Create sheet: Where (a channel), Message (opens the channel with the keyboard), Event, Meeting, To-do, Group, Proposal (their existing forms in the same sheet) | done | `CreateMenu.swift`. The forms replace the list inside the sheet instead of pushing (they have their own navigation). |
| Town: the Square with ☰ = unread town channels; drawer = cover, mark, name, member count, ＋ channel, search, The town (Square, Gates, Charter) / Community life / Building together, Archived, Order (stewards), Belfry settings (stewards), you (tap → Me pushed, ⇅ → accounts) | done | `TownDrawer.swift`. Messages / mentions / events left the drawer (Home, Calendar). |
| Names: Square, Fairground, Assembly, Scriptorium (only while the default name stands), Gates; roles Steward · Member · Guest; the check-in role shown as Door | done | Core-tested (`CharterTests.testPlaceNames`). The role picker still lists Member first and Steward last (the board wants Steward · Member · Guest). The "turn the names on for an existing belfry" switch of the Names board is not built: the names apply to every belfry. |
| Charter: page, ticks, counts, "You agreed", stewards write / edit / reorder / remove, Agreed / Not yet, Home reminder, drawer row | done, never run live | SPEC 19.32, `vectors/charter.json`, `CharterTests`. Copy `charter.json` to Android. The new member's first minutes (Welcome → charter → profile → Getting started → notifications) are not built. |
| Add an agent (own profile, members): explanation, sheet with a one-line prompt + Copy / Share, my agent with Remove instead, stewards may add more | done, never run live | `AgentUI.swift`; `POST /channel-invites {"agent": true}` in `general`. |
| Guests: Home (Apply first, time left, invited channels, open to everyone), Calendar (Public events · Going), Town drawer (Apply, invited, open to everyone, own row), Apply sheet | partial | Apply sends nothing on a real belfry (SERVER-NEEDS 10); public events only from what the phone holds (11); the charter needs the relay (12). |
| Joining from the App Store ("Which belfry?", the belfry's card, Ask to join) | not yet | SERVER-NEEDS 13. |
