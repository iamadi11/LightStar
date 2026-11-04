#!/bin/bash
# Keeps the sideloaded iPhone app alive. A free Apple developer team signs for
# 7 days, so this rebuilds main and reinstalls a day before the install
# expires, retrying until the phone is in range (USB or the same Wi-Fi).
# A launchd agent runs it every 30 minutes and at login; launchd also runs a
# missed check when the Mac wakes, so a Mac that was off just catches up.
#
#   scripts/iphone-reinstall.sh --install-agent --team TEAMID   set up (once)
#   scripts/iphone-reinstall.sh                 check; reinstall if due
#   scripts/iphone-reinstall.sh --force         reinstall now
#   scripts/iphone-reinstall.sh --dry-run       say what it would do
#   scripts/iphone-reinstall.sh --status
#   scripts/iphone-reinstall.sh --remove-agent
#
# Device ids and the team are personal, so they live outside the repo in
# ~/Library/Application Support/LightStar/iphone-reinstall.conf, written by
# --install-agent from the paired iPhone. The team must be an account signed
# in to Xcode (Settings → Accounts).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LABEL=com.adityaraj.lightstar.iphone-reinstall
BUNDLE=com.adityaraj.LightStar.ios
SUPPORT="$HOME/Library/Application Support/LightStar"
CONF="$SUPPORT/iphone-reinstall.conf"
STATE="$SUPPORT/iphone-reinstall.state"   # EXPIRY=<epoch the installed copy stops launching>
SRC="$SUPPORT/iphone-reinstall-src"        # its own clone of main, never the working copy
BUILD="$SUPPORT/iphone-reinstall-build"
LOCK="$SUPPORT/iphone-reinstall.lock"
AGENT_SCRIPT="$SUPPORT/iphone-reinstall.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/LightStar-iphone-reinstall.log"
BUILD_LOG="$SUPPORT/iphone-reinstall-build.log"   # last build's full output
APP="$BUILD/Build/Products/Debug-iphoneos/LightStariOS.app"
RENEW_BEFORE=$((24 * 3600))

mkdir -p "$SUPPORT" "$(dirname "$LOG")"

log() {
    echo "$(date '+%F %T') $*" >> "$LOG"
    [ -t 1 ] && echo "$*"
    return 0
}

notify() {
    osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

# Epoch when an app's embedded profile expires; 0 if unreadable.
profile_expiry() {
    local raw
    raw=$(security cms -D -i "$1/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null) || { echo 0; return; }
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$raw" +%s 2>/dev/null || echo 0
}

human() { date -r "$1" '+%a %d %b %H:%M'; }

read_state() {
    EXPIRY=0
    # shellcheck disable=SC1090
    [ -f "$STATE" ] && . "$STATE"
}

load_conf() {
    [ -f "$CONF" ] || { log "No config at $CONF. Run: $0 --install-agent --team TEAMID"; exit 1; }
    # shellcheck disable=SC1090
    . "$CONF"
}

# Phone reachable over USB or Wi-Fi. Listing apps answers within seconds even
# when the phone is locked; `info details` times out while it's locked.
reachable() {
    xcrun devicectl device info apps --device "$DEVICE" --bundle-id "$BUNDLE" --timeout 30 >/dev/null 2>&1
}

# Build latest main from its own clone. A generic iOS build doesn't need the
# phone nearby, so the app is ready the moment the phone turns up.
# CODE_SIGN_ENTITLEMENTS is cleared because a free team can't hold the App
# Group the widget uses; the app runs, the widget just can't see live state.
build() {
    : > "$BUILD_LOG"
    if [ ! -d "$SRC/.git" ]; then
        git clone -q "$REPO" "$SRC" >> "$BUILD_LOG" 2>&1 || return 1
    fi
    git -C "$SRC" fetch -q origin main >> "$BUILD_LOG" 2>&1 && git -C "$SRC" reset -q --hard origin/main >> "$BUILD_LOG" 2>&1 || return 1
    (cd "$SRC" && xcodegen generate >> "$BUILD_LOG" 2>&1) || return 1
    log "Building $(git -C "$SRC" rev-parse --short HEAD) for the iPhone"
    if ! xcodebuild build -project "$SRC/LightStar.xcodeproj" -scheme LightStariOS -configuration Debug \
        -destination 'generic/platform=iOS' -derivedDataPath "$BUILD" \
        DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_ENTITLEMENTS= -allowProvisioningUpdates >> "$BUILD_LOG" 2>&1; then
        grep -E 'error:' "$BUILD_LOG" | sort -u | head -5 >> "$LOG"
        return 1
    fi
}

check() {
    load_conf
    read_state
    local now; now=$(date +%s)
    if [ "$FORCE" = 0 ] && [ "$now" -lt $((EXPIRY - RENEW_BEFORE)) ]; then
        [ -t 1 ] && echo "Not due: installed copy good until $(human "$EXPIRY"); renews from $(human $((EXPIRY - RENEW_BEFORE)))."
        return 0
    fi

    # One run at a time; a build takes minutes and runs are 30 min apart.
    if ! mkdir "$LOCK" 2>/dev/null; then
        if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then rm -rf "$LOCK"; mkdir "$LOCK" || return 0
        else return 0; fi
    fi
    trap 'rm -rf "$LOCK"' EXIT

    local cached; cached=$(profile_expiry "$APP")
    if [ "$cached" -le $((now + RENEW_BEFORE + 3600)) ] || [ "$FORCE" = 1 ]; then
        if [ "$DRY_RUN" = 1 ]; then log "[dry run] would build main"
        elif ! build; then
            log "Build failed (errors above; full output in $BUILD_LOG). Will retry."
            [ "$now" -gt "$EXPIRY" ] && notify "LightStar" "iPhone app has expired and the rebuild failed. Check Xcode is signed in."
            return 1
        fi
        cached=$(profile_expiry "$APP")
    fi

    if ! reachable; then
        log "iPhone not in range; built copy ready (good until $(human "$cached")). Will retry."
        if [ "$now" -gt "$EXPIRY" ] && [ "$EXPIRY" -gt 0 ]; then
            local flag="$SUPPORT/.expired-notified-$(date +%F)"
            [ -f "$flag" ] || { notify "LightStar" "iPhone app has expired. It reinstalls when your iPhone is near this Mac."; touch "$flag"; }
        fi
        return 0
    fi

    if [ "$DRY_RUN" = 1 ]; then log "[dry run] iPhone in range; would install a copy good until $(human "$cached")"; return 0; fi
    if xcrun devicectl device install app --device "$DEVICE" "$APP" --timeout 180 >> "$BUILD_LOG" 2>&1; then
        echo "EXPIRY=$cached" > "$STATE"
        log "Installed on iPhone; good until $(human "$cached")."
        notify "LightStar" "Reinstalled on your iPhone. Good until $(human "$cached")."
    else
        log "Install failed (phone locked or busy?). Will retry."
        return 1
    fi
}

install_agent() {
    [ -n "$TEAM_ARG" ] || { echo "Pass the Xcode team: $0 --install-agent --team TEAMID"; exit 1; }
    local json=/tmp/lightstar-devices.$$.json ids
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1
    ids=$(python3 -I -c "
import json,sys
d=json.load(open(sys.argv[1]))['result']['devices']
p=[x for x in d if x['hardwareProperties'].get('platform')=='iOS' and x['connectionProperties'].get('pairingState')=='paired']
print(p[0]['identifier'], p[0]['hardwareProperties']['udid']) if p else sys.exit(1)
" "$json") || { echo "No paired iPhone found. Connect it once with a cable and trust this Mac."; rm -f "$json"; exit 1; }
    rm -f "$json"
    local repo; repo=$(git -C "$(dirname "$0")/.." remote get-url origin)
    printf 'DEVICE=%s\nUDID=%s\nTEAM=%s\nREPO=%s\n' ${ids% *} ${ids#* } "$TEAM_ARG" "$repo" > "$CONF"
    # The agent runs its own copy, so switching branches here can't change it.
    cp "$0" "$AGENT_SCRIPT" && chmod +x "$AGENT_SCRIPT"
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>$AGENT_SCRIPT</string></array>
    <key>StartInterval</key><integer>1800</integer>
    <key>RunAtLoad</key><true/>
    <key>LowPriorityIO</key><true/>
    <key>StandardOutPath</key><string>/dev/null</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$PLIST" && echo "Agent installed: checks every 30 min, at login and after wake. Log: $LOG"
}

remove_agent() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    rm -f "$PLIST" "$AGENT_SCRIPT"
    echo "Agent removed. Config and state kept in $SUPPORT."
}

status() {
    read_state
    [ -f "$CONF" ] && sed 's/^/  /' "$CONF" || echo "  (no config)"
    if [ "$EXPIRY" -gt 0 ]; then echo "Installed copy good until $(human "$EXPIRY"); renews from $(human $((EXPIRY - RENEW_BEFORE)))."
    else echo "No install recorded yet."; fi
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "Agent: loaded" || echo "Agent: not loaded"
    [ -f "$LOG" ] && { echo "Last log lines:"; tail -5 "$LOG" | sed 's/^/  /'; }
}

FORCE=0; DRY_RUN=0; TEAM_ARG=""; ACTION=check
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --team) TEAM_ARG="${2:-}"; shift ;;
        --install-agent) ACTION=install_agent ;;
        --remove-agent) ACTION=remove_agent ;;
        --status) ACTION=status ;;
        *) echo "Unknown option $1"; exit 2 ;;
    esac
    shift
done
$ACTION
