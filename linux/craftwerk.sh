#!/usr/bin/env bash
# CraftWerk for Linux: install, update, roll back and remove the open-source Craft apps from their
# GitHub releases. Needs only bash, curl, tar and sha256sum.
#
#   craftwerk.sh                  menu
#   craftwerk.sh list             what's installed and what's available
#   craftwerk.sh install APP...   install apps (or: all). APP@1.2.3 installs that exact version.
#   craftwerk.sh check            report updates without installing
#   craftwerk.sh update [APP...]  update installed apps (default: all of them)
#   craftwerk.sh remove APP...    remove apps; settings in ~/.config are never touched
#   craftwerk.sh rollback APP...  go back to the previous version
#   craftwerk.sh verify           compare what's installed with the official release
#   craftwerk.sh schedule on|off|status   weekly updates (systemd user timer, or cron)
#
# Options: --system installs for everyone in /usr/local (run as root). Otherwise it installs for
# you in ~/.local. CRAFTWERK_PREFIX overrides the folder.
#
# Each release's tarball is a ready-made install prefix (bin/, share/applications, share/mime,
# share/icons), so unpacking it into the prefix is the whole install. What was unpacked is recorded,
# so removing or rolling back deletes exactly those files.

VERSION="0.2.0"
OWNER="storytold"
set -uo pipefail

# id|name|what it opens
CATALOG='cadcraft|CadCraft|CAD drawings (.dxf, .dwg)
deckcraft|DeckCraft|Presentations (.pptx)
designcraft|DesignCraft|Page layout (.idml)
effectcraft|EffectCraft|Motion graphics and animation
filmcraft|FilmCraft|Video editing
gridcraft|GridCraft|Spreadsheets (.xlsx, .csv)
lightcraft|LightCraft|Photo library and camera RAW developing
pdfcraft|PdfCraft|PDF viewing and editing
photocraft|PhotoCraft|Image editing (.psd, .png, .jpg)
soundcraft|SoundCraft|Audio editing (.wav, .mp3, .mid)
vectorcraft|VectorCraft|Vector illustration (.svg, .ai)
wordcraft|WordCraft|Documents (.docx, .odt, .rtf)'

LOGIN_DELAY=600     # seconds a scheduled run waits first, so it doesn't compete with login
RETRY_AFTER=2h      # one retry if there was no internet

# ---- setup -------------------------------------------------------------------------------------
if [ "${EUID:-$(id -u)}" -eq 0 ]; then PREFIX_DEFAULT=/usr/local; else PREFIX_DEFAULT="$HOME/.local"; fi
PREFIX="${CRAFTWERK_PREFIX:-$PREFIX_DEFAULT}"
SCHEDULED=0; IS_RETRY=0; FORCE=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --system)    PREFIX=/usr/local ;;
        --scheduled) SCHEDULED=1 ;;
        --retry)     IS_RETRY=1 ;;
        --force)     FORCE=1 ;;
        *)           ARGS+=("$a") ;;
    esac
done

STATE="$PREFIX/share/craftwerk"
PKGS="$STATE/packages"      # the tarball each installed app came from
PREV="$STATE/previous"      # and the one before it, for rollback
LOG="$STATE/update.log"
TMP=""

case "$(uname -m)" in
    x86_64|amd64)  ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) echo "There is no Linux build of the Craft apps for $(uname -m)." >&2; exit 1 ;;
esac

log() {
    mkdir -p "$STATE" 2>/dev/null
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}
die() { echo "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "This needs '$1', which isn't installed."; }
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

known() { printf '%s\n' "$CATALOG" | cut -d'|' -f1 | grep -qx "$1"; }
field() { printf '%s\n' "$CATALOG" | awk -F'|' -v id="$1" -v n="$2" '$1==id {print $n}'; }
ids()   { printf '%s\n' "$CATALOG" | cut -d'|' -f1; }

installed_version() { cat "$STATE/$1.version" 2>/dev/null; }
installed_ids()     { local id; for id in $(ids); do [ -n "$(installed_version "$id")" ] && echo "$id"; done; }

# true if $1 is newer than $2
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }

# ---- talking to GitHub -----------------------------------------------------------------------------
# The latest release's tag, read from the redirect on the plain release page. Unlike GitHub's API
# there's no rate limit to run into on a shared network, and no JSON to parse.
latest_tag() {
    local url
    url=$(curl -fsS -o /dev/null -w '%{redirect_url}' --max-time 20 "https://github.com/$OWNER/$1/releases/latest") || return 1
    [ -n "$url" ] || return 1
    printf '%s\n' "${url##*/}"
}

online() { curl -fsS -o /dev/null --max-time 20 https://github.com 2>/dev/null; }

# Downloads app's tarball for a tag and checks it against the release's SHA256SUMS.txt.
# Sets PKG to the verified file. A failed check installs nothing.
fetch_verified() {
    local app=$1 tag=$2 ver=${2#v} name base expected actual
    name="$app-$ver-linux-$ARCH.tar.gz"
    base="https://github.com/$OWNER/$app/releases/download/$tag"
    cleanup; TMP=$(mktemp -d) || return 1
    curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/$name" "$base/$name" || { log "$app $ver: download failed ($name)"; return 1; }
    curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/SHA256SUMS.txt" "$base/SHA256SUMS.txt" || { log "$app $ver: no SHA256SUMS.txt. Skipped (won't install unverified)."; return 1; }
    expected=$(awk -v n="$name" '{f=$2; sub(/^\*/, "", f); if (f==n) {print tolower($1); exit}}' "$TMP/SHA256SUMS.txt")
    [ -n "$expected" ] || { log "$app $ver: $name not listed in SHA256SUMS.txt. Skipped."; return 1; }
    actual=$(sha256sum "$TMP/$name" | awk '{print tolower($1)}')
    [ "$expected" = "$actual" ] || { log "$app $ver: CHECKSUM MISMATCH (expected $expected, got $actual). Skipped."; return 1; }
    log "$app $ver: checksum OK"
    PKG="$TMP/$name"
}

# ---- installing --------------------------------------------------------------------------------------
# tar reads the archive from stdin throughout: given a name like C:/x or a:b it would treat the part
# before the colon as a remote host.

# Paths of the files in a tarball, relative to the prefix (its top-level folder stripped).
tar_files() { tar tzf - < "$1" | sed 's#^[^/]*/##' | grep -v -e '^$' -e '/$'; }

# Unpacks into a scratch folder first, so a bad archive can't leave the real install half changed.
stage() { mkdir -p "$2" && tar xzf - -C "$2" --strip-components=1 --no-same-owner < "$1"; }

place() { cp -a "$1/." "$PREFIX/"; }

remove_files() {   # a manifest file: delete what it lists, then any folders that became empty
    local manifest=$1 f d
    [ -f "$manifest" ] || return 0
    while IFS= read -r f; do rm -f "$PREFIX/$f"; done < "$manifest"
    while IFS= read -r f; do
        d=$(dirname "$PREFIX/$f")
        # climb while the folder is empty, but never remove the prefix's own bin/ or share/
        while [ "$d" != "$PREFIX" ] && [ "$d" != "$PREFIX/bin" ] && [ "$d" != "$PREFIX/share" ] && rmdir "$d" 2>/dev/null; do d=$(dirname "$d"); done
    done < "$manifest"
    return 0
}

is_running() {   # is this app running from our prefix? Matches the path, not just the name.
    command -v pgrep >/dev/null 2>&1 || return 1
    local pid exe
    for pid in $(pgrep -x "$1" 2>/dev/null) $(pgrep -x "$1-cli" 2>/dev/null); do
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
        case "$exe" in "$PREFIX"/bin/*) return 0 ;; esac
    done
    return 1
}

refresh_desktop() {   # tell the desktop about new menu entries, file types and icons
    [ -d "$PREFIX/share/applications" ] && command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$PREFIX/share/applications" 2>/dev/null
    [ -d "$PREFIX/share/mime" ]         && command -v update-mime-database >/dev/null 2>&1    && update-mime-database "$PREFIX/share/mime" 2>/dev/null
    [ -d "$PREFIX/share/icons/hicolor" ] && command -v gtk-update-icon-cache >/dev/null 2>&1  && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" 2>/dev/null
    return 0
}

# The shipped menu entries run a bare "photocraft", which only works if $PREFIX/bin is on the desktop's
# PATH. Point them at the real path so double-clicking a file always works.
fix_desktop_files() {
    local app=$1 f
    while IFS= read -r f; do
        case "$f" in share/applications/*.desktop)
            sed -i "s#^\(Exec=\)$app\( \|\$\)#\1$PREFIX/bin/$app\2#; s#^\(TryExec=\)$app\$#\1$PREFIX/bin/$app#" "$PREFIX/$f" ;;
        esac
    done < "$STATE/$app.files"
}

# Programs link against system libraries; say plainly which ones this machine is missing.
check_libs() {
    local app=$1 missing
    command -v ldd >/dev/null 2>&1 || return 0
    missing=$(ldd "$PREFIX/bin/$app" 2>/dev/null | awk '/not found/ {print $1}' | sort -u | tr '\n' ' ')
    if [ -n "$missing" ]; then
        log "$app: installed, but this system is missing libraries it needs: $missing"
        log "$app: install them with your package manager, then run it again."
    fi
}

install_version() {   # install_version APP TAG
    local app=$1 tag=$2 ver=${2#v} old oldpkg="" had=0
    old=$(installed_version "$app")
    [ -n "$old" ] && had=1
    fetch_verified "$app" "$tag" || return 1
    local new="$PKG"
    if tar tzf - < "$new" | grep -qE '(^/|(^|/)\.\.(/|$))'; then log "$app: the archive has unsafe paths. Refusing."; return 1; fi
    mkdir -p "$STATE" "$PKGS" "$PREV" "$PREFIX"
    [ "$had" = 1 ] && oldpkg="$PKGS/$app.tar.gz"

    stage "$new" "$TMP/stage" || { log "$app: couldn't unpack the download. Nothing was changed."; return 1; }
    tar_files "$new" > "$TMP/new.files"
    [ "$had" = 1 ] && remove_files "$STATE/$app.files"
    if ! place "$TMP/stage"; then
        # half old and half new is worse than not updated: put back what was there
        remove_files "$TMP/new.files"
        if [ "$had" = 1 ] && [ -f "$oldpkg" ] && stage "$oldpkg" "$TMP/restore" && place "$TMP/restore"; then log "$app: install failed. Restored $old."
        else log "$app: install failed and the old version couldn't be restored. Run: craftwerk.sh install $app --force"; fi
        return 1
    fi

    cp "$TMP/new.files" "$STATE/$app.files"
    # same version again (a forced reinstall): leave the saved previous version as it was
    if [ "$had" = 1 ] && [ "$old" != "$ver" ] && [ -f "$oldpkg" ]; then
        mv -f "$oldpkg" "$PREV/$app.tar.gz"; printf '%s\n' "$old" > "$PREV/$app.version"
    fi
    cp -f "$new" "$PKGS/$app.tar.gz"
    printf '%s\n' "$ver" > "$STATE/$app.version"
    fix_desktop_files "$app"
    refresh_desktop
    if [ "$had" = 1 ] && [ "$old" != "$ver" ]; then log "$app: $old -> $ver installed ($old kept for rollback)"
    elif [ "$had" = 1 ]; then log "$app: $ver reinstalled"
    else log "$app: $ver installed in $PREFIX"; fi
    check_libs "$app"
    cleanup; TMP=""
}

remove_app() {
    local app=$1
    [ -n "$(installed_version "$app")" ] || { log "remove $app: not installed"; return 1; }
    is_running "$app" && { log "$app: running, close it and try again. Skipped."; return 1; }
    remove_files "$STATE/$app.files"
    rm -f "$STATE/$app.files" "$STATE/$app.version" "$PKGS/$app.tar.gz" "$PREV/$app.tar.gz" "$PREV/$app.version"
    refresh_desktop
    log "$app: removed (settings in your home folder were left alone)"
}

rollback_app() {
    local app=$1 cur prev
    cur=$(installed_version "$app"); prev=$(cat "$PREV/$app.version" 2>/dev/null)
    [ -n "$cur" ] || { log "rollback $app: not installed"; return 1; }
    [ -n "$prev" ] && [ -f "$PREV/$app.tar.gz" ] || { log "rollback $app: no previous version saved"; return 1; }
    is_running "$app" && { log "$app: running, close it and try again. Skipped."; return 1; }
    cleanup; TMP=$(mktemp -d)
    stage "$PREV/$app.tar.gz" "$TMP/stage" || { log "rollback $app: couldn't unpack the saved version. Nothing was changed."; return 1; }
    tar_files "$PREV/$app.tar.gz" > "$TMP/prev.files"
    remove_files "$STATE/$app.files"
    if ! place "$TMP/stage"; then
        remove_files "$TMP/prev.files"
        if stage "$PKGS/$app.tar.gz" "$TMP/restore" && place "$TMP/restore"; then log "rollback $app: failed. Restored $cur."
        else log "rollback $app: failed and $cur couldn't be restored. Run: craftwerk.sh install $app --force"; fi
        return 1
    fi
    cp "$TMP/prev.files" "$STATE/$app.files"
    # swap, so rolling back again goes forward
    mv "$PKGS/$app.tar.gz" "$TMP/cur.tar.gz"
    mv "$PREV/$app.tar.gz" "$PKGS/$app.tar.gz"; mv "$TMP/cur.tar.gz" "$PREV/$app.tar.gz"
    printf '%s\n' "$prev" > "$STATE/$app.version"; printf '%s\n' "$cur" > "$PREV/$app.version"
    fix_desktop_files "$app"; refresh_desktop
    log "rollback $app: $cur -> $prev (the $cur files are now the saved previous version)"
    cleanup; TMP=""
}

# ---- commands --------------------------------------------------------------------------------------------
cmd_list() {
    local id v t
    printf '%-12s %-34s %s\n' App Status Opens
    for id in $(ids); do
        v=$(installed_version "$id")
        if [ -z "$v" ]; then s="Not installed"
        else
            t=$(latest_tag "$id" 2>/dev/null); t=${t#v}
            if [ -z "$t" ]; then s="Installed $v (couldn't check for updates)"
            elif ver_gt "$t" "$v"; then s="Update available: $v -> $t"
            else s="Installed $v (up to date)"; fi
        fi
        printf '%-12s %-34s %s\n' "$(field "$id" 2)" "$s" "$(field "$id" 3)"
    done
}

cmd_install() {
    local id tag
    [ $# -gt 0 ] || die "Say which apps: craftwerk.sh install photocraft wordcraft   (or: all)"
    [ "$1" = all ] && set -- $(ids)
    for id in "$@"; do
        tag=""
        case "$id" in *@*) tag="v${id#*@}"; tag="v${tag#v}"; id=${id%@*} ;; esac    # app@1.2.3 installs that version
        known "$id" || { log "install $id: not one of the Craft apps (try: craftwerk.sh list)"; continue; }
        [ -n "$(installed_version "$id")" ] && [ "$FORCE" = 0 ] && { log "install $id: already installed. Use update."; continue; }
        [ -n "$tag" ] || tag=$(latest_tag "$id") || { log "$id: couldn't find the latest release (no internet?)"; continue; }
        install_version "$id" "$tag"
    done
    case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) echo "Note: $PREFIX/bin isn't on your PATH. To run the apps from a terminal, add this to ~/.profile:  export PATH=\"$PREFIX/bin:\$PATH\"" ;; esac
}

cmd_update() {   # $1=apply|check, then optional app ids
    local mode=$1 id v tag t; shift
    local targets=("$@"); [ ${#targets[@]} -eq 0 ] && targets=($(installed_ids))
    [ ${#targets[@]} -eq 0 ] && { echo "Nothing installed yet."; return 0; }
    if [ "$SCHEDULED" = 1 ]; then
        [ "$IS_RETRY" = 0 ] && command -v systemctl >/dev/null 2>&1 && systemctl --user stop craftwerk-retry.timer 2>/dev/null
        log "--- update run ($([ "$IS_RETRY" = 1 ] && echo retry || echo scheduled)) ---"
        sleep "$LOGIN_DELAY"
    fi
    if ! online; then
        if [ "$SCHEDULED" = 1 ] && [ "$IS_RETRY" = 0 ] && command -v systemd-run >/dev/null 2>&1; then
            systemd-run --user --quiet --unit=craftwerk-retry --on-active="$RETRY_AFTER" "$(readlink -f "$0")" update --scheduled --retry >/dev/null 2>&1
            log "can't reach GitHub (no internet?). Trying again in $RETRY_AFTER."
        elif [ "$IS_RETRY" = 1 ]; then log "still can't reach GitHub. Skipping until the next weekly run."
        else log "can't reach GitHub (no internet?). Nothing checked."; fi
        return 1
    fi
    for id in "${targets[@]}"; do
        known "$id" || { log "$id: not one of the Craft apps"; continue; }
        v=$(installed_version "$id"); [ -n "$v" ] || { log "$id: not installed"; continue; }
        tag=$(latest_tag "$id") || { log "$id: couldn't check for updates"; continue; }
        t=${tag#v}
        if [ "$FORCE" = 0 ] && ! ver_gt "$t" "$v"; then log "$id $v: up to date"; continue; fi
        if [ "$mode" = check ]; then log "$id: $v -> $t available"; continue; fi
        is_running "$id" && { log "$id: running, close it and run again. Skipped."; continue; }
        install_version "$id" "$tag"
    done
}

cmd_verify() {   # does what's installed match the official release? (re-downloads each one)
    local id v tmpdir f bad
    for id in $(installed_ids); do
        v=$(installed_version "$id")
        fetch_verified "$id" "v$v" || continue
        tmpdir="$TMP/x"; stage "$PKG" "$tmpdir" || { log "$id $v: couldn't unpack the download to compare"; continue; }
        bad=""
        for f in "$tmpdir"/bin/*; do cmp -s "$f" "$PREFIX/bin/$(basename "$f")" || bad="$bad $(basename "$f")"; done
        if [ -n "$bad" ]; then log "$id $v: DIFFERS from the official release:$bad"; else log "$id $v: matches the official release"; fi
        cleanup; TMP=""
    done
}

# ---- weekly updates ---------------------------------------------------------------------------------------
self_install() {   # keep a copy the schedule can run, wherever this was downloaded to
    mkdir -p "$STATE" "$PREFIX/bin"
    [ -f "$0" ] || die "Download craftwerk.sh to a file first (the schedule needs a copy to run)."
    [ "$(readlink -f "$0")" = "$STATE/craftwerk.sh" ] || cp -f "$0" "$STATE/craftwerk.sh"
    chmod +x "$STATE/craftwerk.sh"; ln -sf "$STATE/craftwerk.sh" "$PREFIX/bin/craftwerk"
}

systemd_ok() { command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; }

cmd_schedule() {
    local unitdir="$HOME/.config/systemd/user" self="$STATE/craftwerk.sh"
    case "${1:-status}" in
    on)
        self_install
        if systemd_ok; then
            mkdir -p "$unitdir"
            cat > "$unitdir/craftwerk-update.service" <<EOF
[Unit]
Description=Update the Craft apps

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $self update --scheduled
Environment=CRAFTWERK_PREFIX=$PREFIX
EOF
            cat > "$unitdir/craftwerk-update.timer" <<'EOF'
[Unit]
Description=Weekly update of the Craft apps

[Timer]
OnCalendar=Sun *-*-* 10:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
            systemctl --user daemon-reload && systemctl --user enable --now craftwerk-update.timer >/dev/null 2>&1
            log "weekly updates on (systemd timer, Sundays 10:00; a missed run happens at your next login)"
            echo "Tip: 'loginctl enable-linger $USER' lets it run even when you're logged out."
        else
            need crontab
            ( crontab -l 2>/dev/null | grep -v 'craftwerk.sh update --scheduled'; echo "0 10 * * 0 CRAFTWERK_PREFIX=$PREFIX /usr/bin/env bash $self update --scheduled" ) | crontab -
            log "weekly updates on (cron, Sundays 10:00; cron doesn't catch up a missed run)"
        fi ;;
    off)
        if systemd_ok; then systemctl --user disable --now craftwerk-update.timer >/dev/null 2>&1; rm -f "$unitdir"/craftwerk-update.{service,timer}; systemctl --user daemon-reload; fi
        command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -v 'craftwerk.sh update --scheduled' | crontab - 2>/dev/null
        log "weekly updates off" ;;
    status)
        if systemd_ok && systemctl --user is-enabled craftwerk-update.timer >/dev/null 2>&1; then echo "Weekly updates: on (systemd timer)"
        elif command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'craftwerk.sh update --scheduled'; then echo "Weekly updates: on (cron)"
        else echo "Weekly updates: off"; fi ;;
    *) die "Use: craftwerk.sh schedule on|off|status" ;;
    esac
}

# ---- menu --------------------------------------------------------------------------------------------------
# whiptail or dialog if there is one; otherwise numbered questions.
picker() {   # picker TITLE ID... -> prints the chosen ids. Each id shows "Name - status".
    local title=$1; shift
    local ui; ui=$(command -v whiptail || command -v dialog || true)
    local id v items=() n=0 chosen
    if [ -n "$ui" ]; then
        for id in "$@"; do v=$(installed_version "$id"); items+=("$id" "$(field "$id" 2)  ${v:+(installed $v)}" OFF); done
        chosen=$("$ui" --title "$title" --checklist "Space to tick, Enter to continue" 22 70 12 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
        printf '%s\n' $chosen | tr -d '"'
    else
        echo "$title"; for id in "$@"; do n=$((n+1)); v=$(installed_version "$id"); printf '  %2d) %-12s %s\n' "$n" "$(field "$id" 2)" "${v:+installed $v}"; done
        read -r -p "Numbers, separated by spaces (blank to cancel): " chosen </dev/tty || return 1
        for n in $chosen; do [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "$#" ] && eval "echo \${$n}"; done
    fi
}

cmd_menu() {
    local choice picked
    while true; do
        echo; echo "CraftWerk $VERSION  (installing to $PREFIX)"
        echo "  1) Install or update apps"; echo "  2) Remove apps"; echo "  3) Roll back apps"
        echo "  4) Show what's installed"; echo "  5) Weekly updates: $(cmd_schedule status | sed 's/Weekly updates: //')  (toggle)"; echo "  6) Quit"
        read -r -p "Choose: " choice </dev/tty || return 0
        case "$choice" in
        1) picked=$(picker "Install or update" $(ids)) || continue
           for id in $picked; do if [ -n "$(installed_version "$id")" ]; then FORCE=0 cmd_update apply "$id"; else cmd_install "$id"; fi; done ;;
        2) picked=$(picker "Remove" $(installed_ids)) || continue; for id in $picked; do remove_app "$id"; done ;;
        3) picked=$(picker "Roll back" $(installed_ids)) || continue; for id in $picked; do rollback_app "$id"; done ;;
        4) cmd_list ;;
        5) if cmd_schedule status | grep -q ': on'; then cmd_schedule off; else cmd_schedule on; fi ;;
        6|q|"") return 0 ;;
        esac
    done
}

# ---- go -------------------------------------------------------------------------------------------------------------
set -- ${ARGS[@]+"${ARGS[@]}"}
case "${1:-menu}" in -h|--help|help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac    # before anything is created

need curl; need tar; need sha256sum
mkdir -p "$STATE" 2>/dev/null || die "Can't write to $PREFIX. Use a folder you own, or run as root with --system."

case "${1:-menu}" in
    menu)     cmd_menu ;;
    list)     cmd_list ;;
    install)  shift; cmd_install "$@" ;;
    check)    shift; cmd_update check "$@" ;;
    update)   shift; cmd_update apply "$@" ;;
    remove)   shift; for a in "$@"; do remove_app "$a"; done ;;
    rollback) shift; for a in "$@"; do rollback_app "$a"; done ;;
    verify)   cmd_verify ;;
    schedule) shift; cmd_schedule "${1:-status}" ;;
    *) die "Unknown command '$1'. Try: craftwerk.sh help" ;;
esac
