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
UDID=$(pick)
echo "simulator $UDID"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"

shot() { # name screen appearance
  xcrun simctl ui "$UDID" appearance "$3" || true
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  if [ "$2" = "signin" ]; then
    xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  elif [ "$2" = "signin-code" ] || [ "$2" = "signin-older" ]; then
    xcrun simctl launch "$UDID" "$BUNDLE" -signin "${2#signin-}" >/dev/null
  elif [ "${2#guest-}" != "$2" ]; then
    xcrun simctl launch "$UDID" "$BUNDLE" -guest "${2#guest-}" >/dev/null
  elif [ "$2" = "join" ]; then
    xcrun simctl launch "$UDID" "$BUNDLE" -join >/dev/null
  else
    xcrun simctl launch "$UDID" "$BUNDLE" -demo -screen "$2" >/dev/null
  fi
  sleep "${WAIT:-6}"
  xcrun simctl io "$UDID" screenshot "$OUT/$1.png"
  echo "captured $1"
}

# 2026-11-16: the bottom bar (Home · Calendar · Create · Groups · Town), the charter, Add an agent, guests' places
shot 80-home home light
shot 80b-home-dark home dark
shot 81-calendar calendar light
shot 81b-calendar-dark calendar dark
shot 82-groups groups light
shot 82b-groups-all groupsall light
shot 82c-groups-dark groups dark
shot 83-create create light
shot 83b-create-dark create dark
shot 84-town town light
shot 84b-town-dark town dark
shot 85-town-drawer towndrawer light
shot 85b-town-drawer-dark towndrawer dark
shot 86-my-todos mytodos light
shot 87-charter charter light
shot 87b-charter-dark charter dark
shot 88-charter-who whoagreed light
shot 88b-agreement-form agreement light
shot 89-my-profile-agent myprofile light
shot 89b-add-agent addagent light
shot 89c-add-agent-dark addagent dark
shot 90-me meplace light
shot 91-guest-home guest-home light
shot 91b-guest-home-dark guest-home dark
shot 92-guest-calendar guest-calendar light
shot 93-guest-drawer guest-drawer light
shot 94-guest-apply guest-apply light
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
shot 62-accounts accounts light
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
shot 07-messages messages light
shot 08-conversation conversation light
shot 09-email mail light
shot 10-search search light
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
xcrun simctl ui "$UDID" appearance light || true

# native menus only a touch opens: UI tests (App/UITests) write their own PNGs, light and dark
if [ -n "${XCTESTRUN:-}" ] && [ -f "$XCTESTRUN" ]; then
  ABS="$(cd "$OUT" && pwd)"
  for mode in light dark; do
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
      xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID" \
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
