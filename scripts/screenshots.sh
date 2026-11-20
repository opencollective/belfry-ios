#!/usr/bin/env bash
# Boots an iPhone simulator, installs the built app and captures the main screens in demo mode
# (seeded data, nothing leaves the device). Usage: scripts/screenshots.sh <path to Belfry.app> <out dir>
set -euo pipefail
APP="$1"
OUT="$2"
BUNDLE=sh.belfry.app
mkdir -p "$OUT"

pick() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
names = ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone 16", "iPhone 15 Pro"]
for want in names:
    for rt, devs in sorted(d.items(), reverse=True):
        for x in devs:
            if x["name"] == want and "iOS" in rt:
                print(x["udid"]); sys.exit(0)
for rt, devs in d.items():
    for x in devs:
        if x["name"].startswith("iPhone") and "iOS" in rt:
            print(x["udid"]); sys.exit(0)
'
}
# UDID: a simulator the workflow booted already (while the app compiled); else one is picked here
UDID="${UDID:-$(pick)}"
echo "simulator $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b | tail -2
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"

# The screens: each `shot <name> <screen> <light|dark>` line below is only listed here; scripts/shots.py
# captures them after the list (one launch per screen, its dark picture without launching again,
# SHOTS = which screens, SHARD = i/n of parallel jobs).
LIST="$(mktemp)"
shot() { echo "$1 $2 $3" >> "$LIST"; }

# 2026-11-17 round 3: Home with the date and ☰, the drawer (Today, Members, categories with ＋,
# the gear), Settings → Channels, the channel header (subtitle, attention line) and its pull-down
# menu, the channel's pushed screens (Members with Invite, Settings, Pinned)
# 2026-11-18 round 7: a to-do's own screen (claim / assign / unassign, discussion), Assign to…,
# a belfry member link's own screen (no channel behind it)
shot 140-todos todos light
shot 141-todo todo light
shot 141b-todo-dark todo dark
shot 142-todo-assign todoassign light
shot 143-member-invite join-member light
shot 143b-member-invite-dark join-member dark
shot 130-home home light
shot 130b-home-dark home dark
shot 131-home-drawer homedrawer light
shot 131b-home-drawer-dark homedrawer dark
shot 131c-calendar-drawer calendardrawer light
shot 132-drawer-admin towndrawer light
shot 132b-drawer-member member-towndrawer light
shot 132c-drawer-member-dark member-towndrawer dark
shot 133-settings-channels settingschannels light
shot 133b-settings-channels-dark settingschannels dark
shot 133c-channel-delete channelend light
shot 133d-channel-delete-confirm channelendconfirm light
shot 133e-channel-archive channelarchive light
shot 133f-channel-delete-confirm-dark channelendconfirm dark
shot 134-header feed light
shot 134b-header-calm pullemptyclosed light
shot 135-pulldown-admin pulldown light
shot 135b-pulldown-member member-pulldown light
shot 135c-pulldown-dark pulldown dark
shot 136-channel-members members light
shot 136b-channel-members-invite membersinvitech light
shot 137-channel-settings chsettings light
# 2026-11-18 round 6: the Notifications sheet, "Who can read it" (+ the Public question), a closed
# channel (Ask to join as a member, the requests for its steward), the proposal at the top of its
# chat (half, folded, full), the e-mail thread's two modes (mailreply / mailcomment above)
shot 160-notify notify light
shot 160b-notify-dark notify dark
shot 161-visibility chvisibility light
shot 161b-visibility-dark chvisibility dark
shot 162-visibility-public chpublic light
shot 163-closed-ask member-closedask light
shot 163b-closed-requests closedrequests light
shot 164b-proposal-dark proposal dark
shot 165-proposal-folded proposalup light
shot 166-proposal-full proposalfull light
# 2026-11-17 round 5: buttons on messages (#website: to approve, an error, published), links,
# the channel settings (Save + Archive link) and a refused settings change (the mark, its alert)
shot 150-website-buttons website light
shot 150b-website-buttons-dark website dark
shot 151-settings-failed settingsfailed light
shot 152-settings-failed-alert settingsfailedalert light
shot 152b-settings-failed-alert-dark settingsfailedalert dark
shot 138-pinned pinned light
# 2026-11-16: the bottom bar (Home · Calendar · Create · Groups · Town), the charter, Add an agent, guests' places
# 2026-11-16 round 2: e-mail threads in a channel, a guest's request, the first minutes
shot 120-mail-feed mailfeed light
shot 120b-mail-feed-dark mailfeed dark
shot 121-mail-thread mailthread light
shot 121b-mail-thread-dark mailthread dark
shot 122-mail-reply mailreply light
shot 122b-mail-reply-dark mailreply dark
shot 122c-mail-comment mailcomment light
shot 122d-mail-comment-dark mailcomment dark
shot 123-full-mail fullmail light
shot 124-welcome welcome light
shot 124b-welcome-charter welcomecharter light
shot 124d-welcome-charter-dark welcomecharter dark
shot 125-guest-applied guest-applied light
shot 125b-guest-applied-dark guest-applied dark
shot 100-home home light
shot 100b-home-dark home dark
shot 101-calendar calendar light
shot 101b-calendar-dark calendar dark
shot 102-groups groups light
shot 102b-groups-all groupsall light
shot 102c-groups-dark groups dark
shot 103-create create light
shot 103b-create-dark create dark
shot 104-town town light
shot 104b-town-dark town dark
shot 105-town-drawer towndrawer light
shot 105b-town-drawer-dark towndrawer dark
shot 106-my-todos mytodos light
shot 107-charter charter light
shot 107b-charter-dark charter dark
shot 108-charter-who whoagreed light
shot 108b-agreement-form agreement light
shot 109-my-profile-agent myprofile light
shot 109b-add-agent addagent light
shot 109c-add-agent-dark addagent dark
shot 110-me meplace light
shot 111-guest-home guest-home light
shot 111b-guest-home-dark guest-home dark
shot 112-guest-calendar guest-calendar light
shot 113-guest-drawer guest-drawer light
shot 114-guest-apply guest-apply light
shot 42-composer composer light
shot 43-composer-dark composer dark
shot 44-drawer drawer light
shot 45-drawer-dark drawer dark
shot 46-pulldown-dark pulldown dark
shot 47-pulldown-full pullfull light
shot 47b-pulldown-full-dark pullfull dark
shot 47c-pulldown-empty pullempty light
shot 47d-pulldown-empty-dark pullempty dark
shot 48-invite-dark invite dark
shot 48b-invite-external-dark inviteexternal dark
shot 49-mentions mentions light
shot 54-group group light
shot 55-members-requests requests light
shot 56-log log light
shot 57-settings settings light
shot 58-members directory light
shot 58b-members-dark directory dark
shot 59-my-card mycard light
shot 59b-role-picker rolepicker light
shot 59c-profile-dark profile dark
shot 176-profile-guest guestprofile light
shot 176b-profile-guest-dark guestprofile dark
shot 177-profile-guest-agent guestagentprofile light
shot 62-accounts accounts light
shot 155-about about light
shot 155b-about-dark about dark
shot 60-meeting meeting light
shot 60b-meeting-people meetingpeople light
shot 61-meeting-form meetingform light
shot 63-event-dark event dark
shot 64-event-up eventup light
shot 65-event-full eventfull light
shot 65b-event-full-dark eventfull dark
shot 66-event-photos eventphotos light
shot 67-event-people eventpeople light
shot 67b-event-people-dark eventpeople dark
shot 68-my-ticket ticket light
shot 68b-my-ticket-dark ticket dark
shot 69-check-in checkin light
shot 69b-check-in-dark checkin dark
shot 70-check-in-card checkincard light
shot 71-profile-in-event eventrole light
shot 72-members-invite membersinvite light
shot 178-link-boxes linkboxes light
shot 178b-link-boxes-dark linkboxes dark
# 2026-11-20: end-to-end encrypted conversations (boards messages/encryption-*), demo data only
shot 180-enc-thread encthread light
shot 180b-enc-thread-dark encthread dark
shot 181-enc-devices encdevices light
shot 181b-enc-devices-dark encdevices dark
shot 182-enc-group encgroup light
shot 183-enc-mail encmail light
shot 184-enc-mail-devices encmaildevices light
shot 185-enc-new-device encnewdevice light
shot 185b-enc-new-device-dark encnewdevice dark
shot 185c-enc-locked-thread enclocked light
shot 185d-enc-locked-thread-dark enclocked dark
shot 186-enc-how enchow light
shot 187-enc-allow encallow light
shot 187b-enc-allow-dark encallow dark
shot 188-enc-linked enclinked light
shot 189-enc-share encshare light
shot 189b-enc-share-dark encshare dark
shot 190-enc-remove encremove light
shot 191-enc-shared encshared light
shot 191b-enc-shared-dark encshared dark
shot 192-enc-shared-why encsharedwhy light
shot 73-group-cards groupcards light
shot 73b-group-cards-dark groupcards dark
shot 74-group-deleted groupdeleted light
shot 75-group-archived grouparchived light
shot 75b-group-archived-dark grouparchived dark
shot 76-archived-list archivedlist light
shot 77-group-page group light
shot 01-sign-in signin light
shot 02-channels channels light
shot 03-feed feed light
shot 04-thread thread light
shot 05-details details light
shot 06-invite invite light
shot 42b-composer-mention composermention light
shot 42c-composer-mention-dark composermention dark
shot 06b-invite-search invitesearch light
shot 06c-invite-external inviteexternal light
shot 07-messages messages light
shot 08-conversation conversation light
shot 09-email mail light
shot 13-pulldown pulldown light
shot 14-message-menu menu light
shot 15-delete-confirm delete light
shot 16-edit edit light
shot 17-thread-screen threadscreen light
shot 18-channel-search chsearch light
shot 19-add-menu add light
shot 20-pod pod light
shot 21-proposal proposal light
shot 22-event event light
shot 23-profile profile light
shot 24-edit-profile editprofile light
shot 25-me me light
shot 26-members members light
shot 27-todos todos light
shot 28-files files light
shot 31-all-events events light
shot 32-event-host eventhost light
shot 33-event-form eventform light
shot 34-notifications notifications light
shot 11-feed-dark feed dark
shot 12-channels-dark channels dark
shot 30-guest-opening guest-opening light
shot 38-guest-mode guest-feed light
shot 39-guest-join guest-join light
shot 40-guest-code guest-code light
shot 41-guest-mode-dark guest-feed dark
shot 35-sign-in-code signin-code light
shot 36-sign-in-older-belfry signin-older light
shot 37-sign-in-code-dark signin-code dark
shot 150-welcome-belfry signin-welcome light
shot 150b-welcome-belfry-dark signin-welcome dark
shot 151-apply-form signin-apply light
shot 151b-apply-form-dark signin-apply dark
shot 152-apply-sent signin-sent light
shot 153-invite-code signin-invitecode light
shot 154-log-in signin-login light
shot 170-wayin-login signin-wayin-login light
shot 171-wayin-code signin-wayin-code light
shot 172-wayin-unknown signin-wayin-unknown light
shot 173-wayin-apply signin-wayin-apply light
shot 173b-wayin-apply-dark signin-wayin-apply dark
shot 174-wayin-pending signin-wayin-pending light
shot 174b-wayin-pending-dark signin-wayin-pending dark
shot 175-wayin-declined signin-wayin-declined light
python3 "$(dirname "$0")/shots.py" "$UDID" "$BUNDLE" "$OUT" "$LIST"

# native menus only a touch opens: UI tests (App/UITests) write their own PNGs.
# UITESTS: "all" (default), "none", or test names ("testAddMenu testTodoAssign"); UIMODES: "light dark".
UITESTS="${UITESTS:-all}"
ONLY=""
if [ "$UITESTS" != "all" ] && [ "$UITESTS" != "none" ]; then
  for t in $UITESTS; do ONLY="$ONLY -only-testing:BelfryUITests/MenuShots/$t"; done
fi
if [ "$UITESTS" != "none" ] && [ -n "${XCTESTRUN:-}" ] && [ -f "$XCTESTRUN" ]; then
  ABS="$(cd "$OUT" && pwd)"
  for mode in ${UIMODES:-light dark}; do
    xcrun simctl ui "$UDID" appearance "$mode" || true
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    # when the app's watchdog reports a stall, sample the app's threads (simulator apps are host
    # processes) to see where its main thread is busy
    ( xcrun simctl spawn "$UDID" log stream --style compact --predicate 'subsystem == "sh.belfry.app.watchdog"' 2>/dev/null \
        | grep --line-buffered "STALL main" | while read -r _; do
            pid=$(pgrep -n -f "Belfry.app/Belfry" || true)
            [ -n "$pid" ] && sample "$pid" 3 -file "$ABS/sample-$mode-$(date +%s).txt" >/dev/null 2>&1
          done ) &
    SAMPLER=$!
    set +e
    TEST_RUNNER_SHOTS_DIR="$ABS" TEST_RUNNER_SHOTS_SUFFIX="$mode" \
      xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID" $ONLY \
      -resultBundlePath "ui-$mode.xcresult" > "ui-$mode.log" 2>&1
    code=$?
    kill $SAMPLER 2>/dev/null; pkill -f "log stream --style compact --predicate subsystem" 2>/dev/null
    set -e
    grep -E "Test Case|error:" "ui-$mode.log" | tail -30 || true
    if [ $code -ne 0 ]; then UI_FAILED=1; echo "UI tests ($mode) failed"; fi
    # the app's watchdog (App/Sources/LoopWatch.swift): redraw loops and main-thread stalls
    xcrun simctl spawn "$UDID" log show --last 30m --style compact --predicate 'subsystem == "sh.belfry.app.watchdog"' 2>/dev/null | grep -E 'STALL|LOOP|MARK' | tail -200 | tee "$OUT/watchdog-$mode.txt" || true
  done
  xcrun simctl ui "$UDID" appearance light || true
  # a menu the tests could not open is a failure of the job (the shots would be missing)
  if [ "${UI_FAILED:-0}" = 1 ]; then exit 1; fi
fi
