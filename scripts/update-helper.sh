#!/bin/bash
# Update decision helpers for the Dragonwilds entrypoint.
#
# These are kept in their own file so the build-id parsing and verification
# logic can be regression-tested without running the container.
#
# Why verification matters: SteamCMD can exit 0, print "Success! App already
# up to date", and still leave the old build installed when its cached app
# info (PICS) is stale. Trusting the exit status alone makes the wrapper record
# the remote build as applied, restart the server, and repeat every
# UPDATE_TIME forever (upstream issue #17). We therefore always re-read the
# local app manifest and only consider an update applied when its buildid
# matches the remote branch buildid.

# Print the buildid from a Steam appmanifest_<appid>.acf file.
# Returns 1 when the file is missing or has no buildid.
parse_manifest_buildid() {
    local file="$1" value
    [ -f "$file" ] || return 1
    value=$(awk '
        /"buildid"/ {
            line = $0
            sub(/^[^"]*"buildid"[ \t]*"/, "", line)
            sub(/".*$/, "", line)
            if (line ~ /^[0-9]+$/) { print line; exit }
        }
    ' "$file")
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

# Print the buildid of a branch (default: public) from SteamCMD
# `app_info_print` output. Returns 1 when the branch/buildid is not present.
#
# app_info_print is Valve KeyValues text. The naive `grep '"buildid"' | head`
# approach can pick up a buildid from the wrong branch (or a future nested
# key), so walk the block structure and only accept a buildid whose enclosing
# path is <root> ... "branches" -> "<branch>".
parse_appinfo_buildid() {
    local file="$1" branch="${2:-public}"
    [ -f "$file" ] || return 1
    awk -v branch="$branch" '
        function trim(s) {
            sub(/^[ \t\r]+/, "", s)
            sub(/[ \t\r]+$/, "", s)
            return s
        }
        {
            line = trim($0)
            if (line == "" || line ~ /^\/\//) next

            # Value on the following line: "buildid" then "12345"
            if (want_value) {
                want_value = 0
                if (line ~ /^"[0-9]+"/) {
                    value = line
                    sub(/^"/, "", value)
                    sub(/".*$/, "", value)
                    found = 1
                    print value
                    exit
                }
            }

            # Block opener on the same line as its key: "key" {
            if (line ~ /^"[^"]+"[ \t]*\{[ \t]*$/) {
                key = line
                sub(/^"/, "", key)
                sub(/".*$/, "", key)
                depth++
                stack[depth] = key
                next
            }

            # Key on its own line. A following "{" opens its block; a
            # following quoted line is its value.
            if (line ~ /^"[^"]+"[ \t]*$/) {
                key = line
                sub(/^"/, "", key)
                sub(/".*$/, "", key)
                if (key == "buildid" && depth >= 2 &&
                    stack[depth - 1] == "branches" && stack[depth] == branch) {
                    want_value = 1
                } else {
                    pending = key
                }
                next
            }

            # Opening brace on its own line belongs to the pending key.
            if (line == "{") {
                depth++
                stack[depth] = pending
                pending = ""
                next
            }

            # Closing brace.
            if (line == "}") {
                if (depth > 0) depth--
                pending = ""
                next
            }

            # Key/value on the same line: "key" "value"
            if (line ~ /^"[^"]+"[ \t]+".*"$/) {
                key = line
                sub(/^"/, "", key)
                sub(/".*$/, "", key)
                value = line
                sub(/^"[^"]+"[ \t]+"/, "", value)
                sub(/".*$/, "", value)
                if (key == "buildid" && depth >= 2 &&
                    stack[depth - 1] == "branches" && stack[depth] == branch) {
                    found = 1
                    print value
                    exit
                }
            }
        }
        END { if (!found) exit 1 }
    ' "$file"
}

# Return 0 when the manifest's installed buildid equals the expected build.
build_matches() {
    local manifest="$1" expected="$2" actual
    [ -n "$expected" ] || return 1
    actual=$(parse_manifest_buildid "$manifest" 2>/dev/null) || return 1
    [ "$actual" = "$expected" ]
}

# Delay before the next update check after failed verification attempts.
#   failures: consecutive failures (1 = first failure)
#   base:     normal check interval
#   max:      cap
# Starts at 2 x base and doubles per failure, capped at max.
update_retry_delay() {
    local failures="${1:-1}" base="${2:-3600}" max="${3:-86400}" delay i=0
    delay=$base
    while [ "$i" -lt "$failures" ]; do
        delay=$((delay * 2))
        if [ "$delay" -ge "$max" ]; then
            echo "$max"
            return 0
        fi
        i=$((i + 1))
    done
    echo "$delay"
}
