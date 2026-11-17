# Belfry for iPhone: notes for agents

Native SwiftUI client for a community's belfry (self-hosted community server). The protocol is in
[SPEC.md](SPEC.md) (platform-neutral; section 19 = the additions since milestone 1, written by
the Android app and ported here). The web chat (`village-app`, branch `belfry-chat`; also
`commonshub/collective-belfry` branch `chat-source`) is the reference implementation: read it,
don't guess. The Android app (opencollective/belfry-android) is a second reading. What is done:
[PARITY.md](PARITY.md). What the server must add: [SERVER-NEEDS.md](SERVER-NEEDS.md).

`vectors/` is the contract shared with Android: keep both repos' files identical (copy, don't
edit one side). SPEC.md differs from Android's only in the paragraph that opens section 19 and the (iOS) notes
that end 19.19, 19.20 and 19.26, the iOS-only 19.28 and 19.29, 19.30 (deleted and archived groups, written here 2026-11-16: Android has not got it yet), 19.34 / 19.35 (categories; deleting an empty channel, 2026-11-17), and 19.31 / 19.32 / 19.33 (five places, names, roles; the charter; e-mail threads in a channel, written here 2026-11-16; `vectors/charter.json` and `vectors/mailthreads.json` are ours: copy them to Android) (Android's 19.21 to 19.25 and 19.27 copied 2026-11-15; what the iPhone app does of them is in PARITY.md). `vectors/guestmode.json` and `vectors/readstate.json` are Android's.

## Layout

- `SPEC.md`: what a correct Belfry chat client does. Update it when behaviour changes; mark
  unknowns as open questions (section 18).
- `vectors/*.json`: shared test cases. Generated from the web chat's own code:
  `VILLAGE=~/agents/belfry/work/village-app node tools/vectors/build.mjs` (needs the village-app
  checkout with node_modules; `tools/vectors/gen.ts` defines the cases, `stubs/` replace its
  IndexedDB/relay modules). `channel-refs.json` and `push.json` come from `tools/vectors/channel-refs.mjs` / `push.mjs`
  (Android's; the web's nostr-tools). `nip44.json` is the official NIP-44 file (sha256 269ed0f6…5040).
- `Package.swift` → `Sources/BelfryCore`: everything that is not UI.
  - `Crypto/`: hex, HMAC/HKDF, ChaCha20, NIP-44 v2, BIP-340 + ECDH via swift-secp256k1 (P256K,
    pinned 0.23.2; only `Keys.swift` imports it: P256K and CryptoKit both define SHA256), bech32.
  - `Nostr/`: events (canonical serialization, ids), `Signer` protocol, `LocalSigner`.
  - `Model/Derive.swift`: port of `src/core/model.ts`. `Derive` is a **final class snapshot** of
    the log + `WorldContext` (me, domain, community admins, groups key, groups relay, belfry.json
    `agents`, whois `kinds`, pending outbox ids, time zone); every view is computed on first use
    and cached (lazy vars / per-group dictionaries; not thread-safe, the app reads it on the main
    actor). Groups, messages (author's latest edit, specials, event refs), reactions, threads,
    feed + `feedRows`, guests, pins, to-dos, drop links, inbox state, labels, extras, search.
    Extensions: `Events.swift` (calendar, rule B, tickets, my state, lists), `Proposals.swift`,
    `ChannelLine.swift` (the one line, pod shapes), `ChannelRefs.swift` (naddr references),
    `Access.swift` (guest / agent / inChannel / invite text), `People.swift` (tags, places),
    `GroupRoles.swift` (SPEC 19.29: stewards and check-ins from the groups key's 1985 labels,
    event roles, event days, `TicketScan` for scanned texts and event / ticket links).
    `Actions.swift` + `Actions2.swift` (+ `EventActions`): the events each action queues.
    `Text.swift`: hashtags, mentions, JS-like regex helper (`Rx`, UTF-16 offsets).
  - `Mail/`: mail-thread keys, MIME read/write. `Markdown/`: the subset as a tree + e-mail HTML.
  - `Outbox/`: outbox items, error classes, one flush pass (pure, tested).
  - `Net/`: discovery + PKCE sign-in (belfry.json revalidated with ETag), `NativeSignIn.swift`
    (SPEC 19.20: `MemberAddress`, the two signed calls, `NativeSignInFlow` over a `Vault`), `Relay`
    (URLSessionWebSocketTask, NIP-42), `BunkerSigner` (NIP-46), `SyncEngine` (relays,
    subscriptions, outbox, watchdog, NWPathMonitor), `Api.swift` (`BelfryAPI`: the belfry's HTTP
    API, NIP-98, `ApiError` with fixed messages per `error` code; `InviteLink`), `EventsApi.swift`.
  - `Crypto/Nip19.swift`: naddr encode / decode.
  - `Store/Database.swift`: SQLite (events, outbox, kv). `DM/`: gift wraps, `DirectMessages`.
- `Tests/BelfryCoreTests`: XCTest against `vectors/` (found via `#filePath`).
- `App/Sources`: the SwiftUI app. `AppModel` (state + actions; `+People`: joining, profiles,
  agents, sessions, follows, drop links; `+Events`). Views: `RootView` (sidebar, routing of sheets
  by `model.openProfile / openEvent / showEvents / messageAuthor / pendingInvite`), `ChannelView`
  (+ `PullDown` line and sheet, `MessageRow` + cards, `MessageActions` menu / delete / edit /
  mail reply, `Composer` with @ and # pickers and the ＋ menu, `ThreadView` + `ChannelSearch`),
  `ChannelDetails` (tabs + invite sheet), `PeopleUI` (profile, edit, Me, devices, save account),
  `SignInView` (address → six code boxes, `CodeBoxes` also used by the Join sheet: no length
  limit, digits via `NativeSignIn.next`; a failed connection keeps the digits + "Try again", only
  wrong / expired codes clear them; the browser as a second row; `AppModel+SignIn`),
  `JoinUI` (guest links signed in), `GuestUI` + `AppModel+Guest` (guest mode, SPEC 19.26: the
  loading screen, the guest bar, the Join sheet), `EventScreen` (the event: three-level header,
  Chat · Photos · People; `ChannelView(embedded: true)` is its chat), `Tickets` (my ticket's QR,
  the check-in screen, the card a ticket link opens), `GroupRoles` (`PersonRow`, "In <group>"
  on a profile), `AppModel+Checkin` (viewer block per event, attendees, check-in, /group-roles),
  `EventsUI` (forms, tickets, RSVP pieces, All events), `Kit` (BusyButton, ActionRow, PodShape, ChannelGlyph,
  Chip, `openChannel` environment). `project.yml` is the XcodeGen spec; the `.xcodeproj`,
  `App/Info.plist` and `App/Belfry.entitlements` are generated, not committed.
- `SERVER-NEEDS.md`: changes the belfry must make for this app (redirect URI, push…). This repo
  never touches the servers.

## Building (no Mac here: CI only)

This Linux box has no Xcode. Push and let GitHub Actions build (`gh run watch`, `gh run view
--log`, `gh run download <id> -n screenshots`):

- `core`: `swift test` on macos-15 (Xcode 16.4, Swift 6.1). Core is Swift language mode 5.
- `app` (macos-26, Xcode 26): `xcodegen generate`, `xcodebuild … build-for-testing -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO
  -skipPackagePluginValidation build` (P256K uses a build-tool plugin), then
  `scripts/screenshots.sh` boots a simulator and captures the screens in demo mode → artifact
  `screenshots`; then the UI tests (`App/UITests/MenuShots.swift`, target `BelfryUITests`) tap
  what only a touch opens (the ＋ menu, a held message's menu, the drawer by swipe, typing) and
  write `50-…`–`53-…` PNGs in light and dark (`TEST_RUNNER_SHOTS_DIR`). Keep expressions small:
  Xcode 26 gives up type-checking long `+` chains of optional strings (move them into functions).
- `testflight`: runs on main only when these repository secrets exist (Xavier adds them):
  `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (App Store Connect API key with
  App Manager or Admin role; contents of the .p8). Signing is automatic through the API key
  (`-allowProvisioningUpdates`); the app record `sh.belfry.app` must exist in App Store Connect.

Demo mode: launch argument `-demo` (or "Try the demo" on the sign-in screen) seeds a made-up
community on the device (`App/Sources/Demo.swift`: edits, a pin, to-dos, a closed pod, a
proposal under vote, two Belfry events, a channel reference, an announcement, guests and an
agent), local-only. `-screen <name>` opens a screen for the screenshot job (`scripts/
screenshots.sh` lists them: feed, thread, details, invite, messages, conversation, mail, search,
channels, pulldown, menu, delete, edit, threadscreen, chsearch, add, pod, proposal, event,
profile, editprofile, me, members, todos, files, events, eventhost, eventform, and since
2026-11-15 composer, drawer, pullfull, mentions, group, requests, log, settings; and event (the
event screen at half), eventup, eventfull, eventphotos, eventpeople, ticket, checkin (with a
result card), checkincard (a ticket link opened), eventrole (a profile with "In Repair café"),
membersinvite; and since 2026-11-16 groupcards (the cards of a deleted and an archived group),
groupdeleted, grouparchived, archivedlist; and since 2026-11-16 home, calendar, groups, groupsall,
create, town, towndrawer, mytodos, charter, whoagreed, agreement, myprofile, addagent, meplace;
`-guest home|calendar|drawer|apply` for a guest's places; and since 2026-11-17 homedrawer,
settingschannels, chsettings, pinned, membersinvitech, pullemptyclosed, and `-member` (Sam is
not a belfry admin; the screenshot script's `member-<screen>`)). In the demo Sam is an admin of the belfry (settings, roles, requests show), and
the steward of today's Repair café (Dev hosts, Emma co-hosts; two ticket types; Sam holds a
Volunteer ticket; Ana and Ben checked in; photos drawn on the device by `DemoPictures`). `-join` (no
`-demo`) opens a demo guest link signed out (the loading screen, then guest mode). `-guest
opening|feed|join|code` shows guest mode's screens (the loading screen; #general read as a
guest; the Join sheet; its code step), demo code 123456. `-signin code` / `-signin older`
show the sign-in's code screen / the older-belfry state with made-up values (nothing is sent).

## Offline first (the owner, 2026-11-15: "cache everything locally… opening any channel should be instant")

- Every Nostr event is kept in SQLite (no cap today; if one is ever needed: the newest 5 000 per
  group, and always the replaceable / state events 0, 39000–39003, 9000–9009, 30078, 1985 still
  referenced, events and proposals; never outbox items or my unsent work). Decrypted DMs are
  stored once (`dm-items`, `dm-seen` saved every 20 as it goes): a known gift wrap never goes to
  the signer again (`OfflineFirstTests`).
- A channel, a thread, Messages and a conversation draw from the local log in the same frame as
  the tap: no spinner, no relay, signer, discovery or HTTP call on that path. Cold start reads
  belfry.json, roles, membership, read state from their stored copies and refreshes them in the
  background; it reopens the last screen (`belfry-last-screen`, per account).
- `Derive` caches per snapshot (feed rows, messages, reactions, threads…) and a new snapshot
  carries the untouched channels' views (`carry`, SPEC 19.22); regexes are compiled once (`Rx`).
  `PerformanceTests` (≈ 20 000 events) has the budgets and prints `perf:` lines (debug and
  release builds in CI): keep them passing.
- Pictures go through `CachedImage` (memory, then Caches/images, then the network once); sizes
  from imeta `dim` so nothing jumps. URLCache has 512 MB on disk.
- Subscriptions ask `since` the newest stored event (minus an hour); opening a channel never
  fetches.

## UI rules (the owner's, not negotiable)

- Every button locks the moment it is tapped and shows progress until its work is done: use
  `BusyButton` / `ActionButtonRow` (Kit.swift), never a bare `Button { Task { … } }` for work.
  A double tap never sends twice.
- Menus are lists with an icon per row. Since 2026-11-15 (the owner, after the first TestFlight:
  "compare with iMessage or WhatsApp… they don't feel native") they are the system's own: the
  composer's ＋ is a `Menu` of `Label`s, a held message opens `.contextMenu` (`MessageMenu`:
  quick reactions in a `ControlGroup`, then the web's message menu); the full sheet list
  (`MessageActions`) stays for "More reactions" and the delete confirmation. Sheets are
  `List`/`Form` sections with native rows; no hand-made pills (`.buttonStyle(.brand)` for the
  filled button, `.bordered`, `ShareLink`, `CopyRow`).
- Copy gives feedback (a checkmark + the success haptic, `CopyRow`). The keyboard goes down
  before any sheet opens (`hideKeyboard()`).
- No horizontal scrolling of a screen. A back button never pushes.
- Text fields ≥ 16 pt (`.font(.body)`).
- Never render text from a URL (a link gives only its domain and token / link); server errors →
  fixed messages by `error` code (`ApiError.message`).

## Decisions

- Bundle id `sh.belfry.app`, redirect `sh.belfry.app://connect`, client_id `belfry-ios`, client
  tag `["client","belfry-ios"]`.
- Push (collective-belfry `docs/push.md`, SPEC 19.19): target `NotificationService` (bundle
  `sh.belfry.app.notifications`, App/NotificationService) decrypts `b` with the device key K
  (BelfryCore `Push.open`, `PushKeyStore`); K lives in the keychain group
  `$(AppIdentifierPrefix)sh.belfry.app.shared` (Info.plist `BelfryKeychainGroup`; falls back to
  the app's own group on an unsigned build); App Group `group.sh.belfry.app`; `aps-environment`
  from `APS_ENVIRONMENT` (development / production). `AppDelegate` (in AppModel+Push) gets the
  token and the taps. The portal set-up Xavier must do is in SERVER-NEEDS 3.
- Sign-in (SPEC 19.20): native by default (`name@domain` → code by e-mail), the endpoint from
  belfry.json `sign_in.sessions.api`; the browser (`ASWebAuthenticationSession`, SPEC 2) is the
  second row and the fallback for a belfry without that key. The pending request (address,
  session key, later the bunker address) lives in the Keychain (service
  `sh.belfry.app.session.keys`, account `native-signin`) for at most 15 minutes. Never test it
  against a live belfry with a real member's name: it mails that person a code.
- Universal links: `applinks:chat.belfry.sh`, `chat.enspiral.eu`, `chat.belfry.brussels`, `chat.opensourcevillage.org` (2026-11-17; the staging host left) (project.yml
  entitlement) for `/join/<token>` and `/events/<link>`; the chat hosts must serve
  apple-app-site-association (SERVER-NEEDS 5). A guest's join session key lives in the Keychain
  (service `sh.belfry.app.session.keys`, account `join-<token>`) until the join works.
- Join sheet code step: after an attempt whose answer was lost (offline / failed), an expired /
  wrong_code / not_guest answer first checks the relay for the save (`GuestJoinSaved`, 6 s) and
  counts it as joined (web guestjoin.ts savedOnRelay).
- Guest mode (SPEC 19.26): `GuestModeGate` (BelfryCore) is the one check; `SyncEngine.guestMode`
  and `BelfryAPI(guestMode:)` carry it. Any new write path must go through the outbox or
  `BelfryAPI.signed` / `SyncEngine.signedRequest`, or check the gate itself. Automatic writes
  (seen marks, push registration) are skipped while reading, not refused (a refusal opens the
  Join sheet).
- iOS 17+, built with the iOS 26 SDK (Xcode 26 in CI): glass (`.glassEffect`, `safeAreaBar`)
  behind `#if compiler(>=6.2)` + `if #available(iOS 26, *)`, material before (`Theme.swift`:
  `glass(in:)`, `topBar`, `bottomBar`).
- iPhone layout (2026-11-16, the owner's canvas "One belfry, five places"): a bottom bar Home ·
  Calendar · Create (＋) · Groups · Town (`Tabs.swift`: `AppTab` in `model.tab`, `TabBar`,
  `tabBarInset()` on each place's ROOT so pushed screens cover it and it slides with the root;
  hidden with the keyboard). Each place is a `NavigationStack` (only the one on screen is built; its path stays in RootView) with
  `placeDestinations()` (profiles, events, group pages, `ChatRoute` chats, `PlaceRoute` screens,
  conversations); `RootView.push` appends to the place on screen, so `openProfile / openEvent /
  openGroup / messageAuthor` and `openChannel` (outside Town) push there. Home (`HomeView`),
  Calendar (`CalendarView`), Groups (`GroupsView`), Create (`CreateMenuSheet`, the forms open in
  the same sheet). Town = the old phone layout: the open channel with ☰ (unread town channels)
  and the drawer under it (`DrawerContainer` + `TownDrawer`: Today, the town's places, the
  categories, you → Me pushed, ⇅ → accounts). Home has the same ☰ and drawer (2026-11-17; a
  drawer row other than Today switches to Town). Guests: Home · Calendar · Town. No own face in
  any header. Calendar and Groups have the same ☰ and drawer (2026-11-17; the "Belfry ⌄" pill is
  gone: accounts are on the drawer's person row). iPad: the old
  sidebar (`ChannelDrawer.sidebar`) in a split view, no bar.
- Deleted and archived groups (SPEC 19.30, `Model/Archive.swift`, `ArchiveUI.swift`,
  `AppModel+Archive`): `Derive.groups()` = the listed ones (not archived, not deleted);
  `group(id)` / `allGroups()` include archived ones; `groupState(id)` = unknown / open /
  archived / deleted. Deleted by absence comes only from the relay's answer (`groupsAbsent`,
  stored as `groups-absent`; asked after the groups relay's EOSE and for unknown ids; #general
  is the proof of an answer; never as a guest). A group's page (`GroupRoute`) and an archived
  group (`ChannelRoute` → `ChannelScreen(pushed:)`) are pushed on the main stack; `ChannelScreen`
  is what any route to a channel shows (the channel, or `GroupGone`). Any new write in a channel
  must be hidden when `model.locked(id)`; `SyncEngine.setLocked` + `GroupLock` refuse it anyway.
  Every 9002 goes through `Actions.groupMeta` (keeps every setting and `archived`).
- Every row of the drawer opens an open screen (☰ top left, the row highlighted), never a
  sheet: Today (Home), channels, Members (requests on top), the Charter, Archived; the gear in
  its header opens Belfry settings; you (the last row) push Me. Home's tiles push Messages, @Mentions, My to-dos. Sheets are for short tasks started from
  a screen (invite, a new event, editing a profile).
- Layout that can freeze the main thread (the event-chat freeze, 2026-11-16, found with the
  watchdog `LoopWatch` + `sample` in the screenshot job): never write view state from
  onGeometryChange / onScrollGeometryChange / preferences on a hot path (use a plain reference such
  as `FeedPosition`); no GeometryReader around content that ignores the safe area (reach under
  the bar with a background decoration only); give the event screen's header, handle, tabs and
  panes frames fixed in BOTH width and height (a flexible child makes every stack around it measure
  the chat and the composer's text view at several sizes, multiplied level by level); the
  composer's field is `fixedSize(vertical)`; feeds scroll to their end by edge (`FeedScroll`,
  iOS 18 ScrollPosition), never by the id of a lazy row; an event's chat is a plain stack. The UI
  test `testEventChatTyping` focuses, types and dismisses three times and fails with "it hangs"
  when a query takes over 20 s; on a stall the job saves `sample-<mode>-*.txt` and `watchdog-*.txt`.
- Views inside animated containers stay in the tree (opacity / allowsHitTesting /
  accessibilityHidden), never inserted mid-animation (drawer shade fix 4c549e1, pull-down).
- An event is one screen, pushed on the stack (`model.openEvent` → `EventRoute`; an `ev-` group
  chosen in the drawer opens it as the root): the header at three levels (`EventLevel` up / half /
  full, the same handle drag as `PullDownPanel`), opening at half; Chat · Photos · People under it,
  all three kept in the tree. The cover runs under the navigation bar (`toolbarBackground(.hidden)`,
  the root ignores the top safe area and adds it back by hand).
- The feed's end is a 1 pt anchor with NO padding: the composer is the scroll view's safe-area
  inset, and scrollTo / defaultScrollAnchor(.bottom) stop above it (a pad of the composer's
  height showed as an empty band, fixed 2026-11-15).
- Names (SPEC 19.31): `WorldContext.placeNames` (true in the app) shows general as "Townsquare"
  while its own name is the default (`vectors/placenames.json`); since 2026-11-17 nothing else is
  renamed (Square / Fairground / Assembly / Scriptorium are gone). A belfry may have only #general:
  never assume #events / #proposals / #website exist; members+requests = "Members" (was "Gates" until 2026-11-17); roles Steward (admin) · Member · Guest; the check-in role
  `steward` reads "Door". Display only: never write these names back.
- The charter (SPEC 19.32, `Model/Charter.swift`, `CharterUI.swift`, `AppModel+Charter`): group
  `charter`, agreements = 2100 with `each`, ticks per author; only belfry admins' rules count.
- Add an agent (`AgentUI.swift`): on my own profile, a modal by the owner's request.
- Round 2 (2026-11-16, `AppModel+Apply`): a guest's request (`POST /applications {"apply"}`,
  `applyState` stored per account), the public charter (`publicCharter`, `charterRules` = the
  group's own or the public copy), guests' public events (`publicEventsRaw`), a new member's first
  minutes (`WelcomeUI.swift`, `welcomeDue` = the web's rule). E-mail threads (SPEC 19.33):
  `Model/MailInbox.swift` + `MailUI.swift`; `ThreadView` hands an e-mail's thread to
  `MailThreadView`; answers go out from `Derive.mailLocal` (the plain alias); "Full e-mail" =
  `model.fullMail` → `FullMailSheet`. Screens `mailfeed`, `mailthread`, `mailreply`, `fullmail`,
  `welcome`, `welcomecharter`, `welcomeprofile`, `-guest applied`.
- People lists of a channel / group / event: `PersonRow` (face, name, role there as secondary
  text), never a label icon; the profile opened from them gets the group (`ProfileKey.group`).
- The channel header (2026-11-17): the name, then the subtitle lock/globe · "N active" · photos ·
  groups (`ChannelSubtitle`); the line under it (`ChannelLineBar`) only while
  `Derive.attentionLine` returns one. The pull-down comes FROM THE TOP (`PullDownPanel`: one
  surface with the navigation bar; handle drag, tap outside): description, the address, the
  pinned message not hidden, then `PDRow`s that PUSH the channel's screens (`ChannelPlace` →
  `ChannelPlaceView` in `ChannelPlaces.swift`, via `navigationDestination(item:)` on ChannelView):
  Pinned, Events, To decide, To-dos, Photos, Files, Groups, Topics, Members (Invite inside),
  Notifications, Log, Settings (canAdmin). Never a sheet, never a list unfolded in place. Channel
  info (the tabbed sheet) is gone; its tab views (`MembersTab`, `TodosTab`, `FilesTab`,
  `LogTab`, `SettingsTab`, `FollowBell`) are the screens' contents. The header's right side is
  search only.
- Channel categories (SPEC 19.34, `Model/Categories.swift`): the drawer's categories are one
  `List` section with header rows (so `onMove` crosses categories; belfry admins only, header
  rows `moveDisabled`); every change publishes the order event at once
  (`AppModel.setChannelLayout`). Belfry settings → Channels (`ChannelsSettings`). Demo: Sam's
  (and, for `-member`, Ana's) order event puts the repair café in "Making & mending".
- Look: neutral like the web's Belfry theme (ink on white / near-white on black) unless
  belfry.json `branding.primary` is set; then that colour is the tint (`Theme`, `Color.brand`,
  `Theme.onAccent` for text on it, `Theme.toggle` for switches: system green when neutral).
- Composer: iMessage's shape (`Composer.height` 38 pt: the ＋ circle, the capsule field, Send
  inside it). Drafts per channel (`c:<id>`) and thread (`t:<group>:<root>`) and per form
  (`Drafts`, UserDefaults; cleared on sign-out).
- Several accounts (SPEC 19.24, 2026-11-15): `AccountList` (BelfryCore Model/Accounts.swift,
  core-tested) in UserDefaults `belfry-accounts`, no secrets. Per account a slot ("" then "a2",
  "a3"…, a numbered slot never given twice): Keychain session `session` / `session@<slot>`
  (`Keychain.slot` = the open one), SQLite `belfry-<domain>.sqlite` / `belfry-<domain>@<slot>.sqlite`,
  drafts prefix `belfry-draft:` / `belfry-draft@<slot>:`, per-account defaults via
  `AppModel.perAccount`. Slot "" keeps every earlier name, so a device of an earlier version
  migrates by writing the list only (`restoreAccounts`). One account live; `switchAccount` stops
  the engine and signer (`closeLive`) and opens the other. Sign out = the open account only, then
  the next. Add an account = `SignInView(onCancel:)` as a full-screen cover; `store(_:)` gives the
  slot (an identity already here keeps its own). The demo is not in the list and never touches a
  Keychain session. The shared attachments folder is emptied only with the last account.
- Push per account: K per slot (`PushKeyStore` account `device-key` / `device-key@<slot>`); each
  account registers the same APNs token with its own K when it is open (the belfry keeps one
  row per identity). The extension tries every K (`PushKeyStore.loadAll`, `Push.openAny`) and
  puts `account` = the slot in the notification; a tap switches to that account first. Signing
  out removes that account's row; the stored token goes only with the last account.
- Read state across devices (SPEC 19.27): `BelfryCore/Read` (`ReadState` = the web's readcore.ts,
  vectors/readstate.json; `ReadSync` = store, merge of my `belfry:read` events, publish through
  the outbox only after the community relay's EOSE, 3 s debounce / 10 s gap, flushed on
  background; local only for guests, guest mode and the demo). Marks: a channel on screen
  (`markChannelRead`), a thread, a conversation, @Mentions opened. Drawer rows bold + count,
  "N new" on thread lines, delivered notifications of a read channel removed.
- SQLite instead of SwiftData: plain tables, same shape as the web's IndexedDB, no schema magic.
- Relay events are signature-checked before storage; seals always.
- Never render text from a URL; server errors are mapped to fixed messages by their `error` code.

## Rules

- Push freely to `opencollective/belfry-ios`. Ask before: GitHub secrets, TestFlight/App Store
  submissions, other repos, anything on the Belfry servers. Never modify `village-app` or
  `collective-belfry` from here.
- Never print secrets. Commit messages end with the Co-Authored-By / Claude-Session lines.

## Known debt

- NSLock is used from async functions in `Net/` and `DM/` (warnings "unavailable from asynchronous
  contexts" in Swift 5 mode, errors in Swift 6). Move SyncEngine / DirectMessages / Relay state
  into actors before switching the package to Swift 6 language mode.
- A new `Derive` is built per change of the log (cached per `version`); some views (tasks, pins,
  proposals, calendar) scan the whole log. Fine for a community; index per group if logs grow
  past tens of thousands of events.
- Nothing has run on a device or against a real belfry (see PARITY.md). The UI has no XCTest
  (only the core); screenshots are the check.
- Day and time labels in the channel line are fixed English / 24 h (as Android).

## Notes

- 2026-11-17 round 3 (branch ios-r3, the owner's TestFlight remarks): Home = the date + ☰ + one
  layout; drawer Today / Members / categories with ＋ / gear / steward drag; Settings → Channels;
  categories on the wire (SPEC 19.34, vectors/categories.json: copy to Android, the web
  implements the same format); the channel header's subtitle, the attention-only line, the
  pull-down as a menu of pushed screens, Channel info removed, drop box link in the ＋ menu.
  UI tests `testDrawerDrag` (long press + drag, asserts the move) and `testHomeDrawer`.
- 2026-11-17 round 4 (branch ios-r4, web 44df470 + collective-belfry 784d1a4): only #general is
  renamed (Townsquare); a belfry may have only #general (Community life shows empty to members:
  `Categories.shown(admin:member:)`, vectors/categories.json gains `shown_guest`); Settings →
  Channels → a channel: Delete (empty, `POST /group-delete`) or Archive (SPEC 19.35,
  `ChannelEnd.swift`); ☰ + drawer on Calendar and Groups; `applinks:chat.opensourcevillage.org`;
  to-dos made from a message: "Open its thread". vectors/categories.json changed and
  vectors/placenames.json is new: copy both to Android. Screens `channelend`, `channelendconfirm`,
  `channelarchive`, `calendardrawer`; demo channel "Tool library" (`tools-2b8e`) has no messages.
