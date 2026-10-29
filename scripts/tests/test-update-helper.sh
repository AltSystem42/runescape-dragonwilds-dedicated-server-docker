#!/bin/bash
# Regression tests for scripts/update-helper.sh
#
# Run from anywhere: bash scripts/tests/test-update-helper.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../update-helper.sh"

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# shellcheck source=../update-helper.sh
source "$HELPER"

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1"; failures=$((failures + 1)); }

assert_eq() { # description expected actual
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1 (expected [$2], got [$3])"
    fi
}

assert_fails() { # description command...
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        fail "$desc (expected failure, got success)"
    else
        pass "$desc"
    fi
}

# ---------------------------------------------------------------------------
# Manifest parsing
# ---------------------------------------------------------------------------
cat > "$TEST_TMP/appmanifest.acf" <<'EOF'
"AppState"
{
	"appid"		"4019830"
	"Universe"		"1"
	"name"		"Dragonwilds Dedicated Server"
	"StateFlags"		"4"
	"installdir"		"RSDragonwilds"
	"buildid"		"25805654"
	"LastUpdated"		"1791500000"
}
EOF
assert_eq "manifest: parses buildid" "25805654" "$(parse_manifest_buildid "$TEST_TMP/appmanifest.acf")"

printf '"AppState"\n{\n\t"appid"\t"4019830"\n}\n' > "$TEST_TMP/no-buildid.acf"
assert_fails "manifest: missing buildid fails" parse_manifest_buildid "$TEST_TMP/no-buildid.acf"
assert_fails "manifest: missing file fails" parse_manifest_buildid "$TEST_TMP/does-not-exist.acf"

# ---------------------------------------------------------------------------
# app_info_print parsing: branch ordering and decoy "public"/"buildid" blocks
# ---------------------------------------------------------------------------
cat > "$TEST_TMP/appinfo.txt" <<'EOF'
"4019830"
{
	"common"
	{
		"name"		"Dragonwilds Dedicated Server"
	}
	"depots"
	{
		"3501791"
		{
			"manifests"
			{
				"public"
				{
					"gid"		"1991230221118269239"
					"size"		"5515935989"
				}
			}
		}
		"branches"
		{
			"beta"
			{
				"buildid"		"99999999"
				"description"	"beta"
			}
			"public"
			{
				"buildid"		"26161880"
				"timeupdated"		"1792782740"
			}
		}
		"privatebranches"		"1"
	}
}
EOF
assert_eq "appinfo: public branch buildid with beta listed first" "26161880" \
    "$(parse_appinfo_buildid "$TEST_TMP/appinfo.txt" public)"
assert_eq "appinfo: explicit non-public branch" "99999999" \
    "$(parse_appinfo_buildid "$TEST_TMP/appinfo.txt" beta)"
assert_fails "appinfo: unknown branch fails" parse_appinfo_buildid "$TEST_TMP/appinfo.txt" experimental

# A "public" key also exists under depots.*.manifests; it must not be used,
# and a decoy buildid elsewhere must not win over branches.public.
cat > "$TEST_TMP/appinfo-decoy.txt" <<'EOF'
"4019830"
{
	"buildid"		"11111111"
	"depots"
	{
		"3501791"
		{
			"manifests"
			{
				"public"
				{
					"gid"		"2222222222222222222"
					"buildid"		"33333333"
				}
			}
		}
		"branches"
		{
			"public"
			{
				"buildid"		"44444444"
			}
			"beta"
			{
				"buildid"		"55555555"
			}
		}
	}
}
EOF
assert_eq "appinfo: ignores decoy buildids outside branches.public" "44444444" \
    "$(parse_appinfo_buildid "$TEST_TMP/appinfo-decoy.txt" public)"

# Value on the line after the key.
cat > "$TEST_TMP/appinfo-nextline.txt" <<'EOF'
"4019830"
{
	"depots"
	{
		"branches"
		{
			"public"
			{
				"buildid"
				"77777777"
			}
		}
	}
}
EOF
assert_eq "appinfo: buildid value on the next line" "77777777" \
    "$(parse_appinfo_buildid "$TEST_TMP/appinfo-nextline.txt" public)"

# No branches block at all.
cat > "$TEST_TMP/appinfo-nobranches.txt" <<'EOF'
"4019830"
{
	"depots"
	{
		"3501791"
		{
			"manifests"
			{
				"public"
				{
					"gid"		"2222222222222222222"
				}
			}
		}
	}
}
EOF
assert_fails "appinfo: no branches block fails" parse_appinfo_buildid "$TEST_TMP/appinfo-nobranches.txt" public
assert_fails "appinfo: missing file fails" parse_appinfo_buildid "$TEST_TMP/does-not-exist.txt" public

# ---------------------------------------------------------------------------
# The issue #17 regression: SteamCMD exits 0 but the build did not change
# ---------------------------------------------------------------------------
cat > "$TEST_TMP/stale.acf" <<'EOF'
"AppState"
{
	"appid"		"4019830"
	"buildid"		"25805654"
}
EOF
assert_fails "verify: stale manifest does not count as updated" \
    build_matches "$TEST_TMP/stale.acf" "25808123"
assert_eq "verify: matching manifest counts as updated" "0" \
    "$(build_matches "$TEST_TMP/stale.acf" "25805654"; echo $?)"
assert_fails "verify: empty expected build fails" build_matches "$TEST_TMP/stale.acf" ""
assert_fails "verify: missing manifest fails" build_matches "$TEST_TMP/nope.acf" "25808123"

# ---------------------------------------------------------------------------
# Update backoff
# ---------------------------------------------------------------------------
assert_eq "backoff: first failure doubles the interval" "7200" \
    "$(update_retry_delay 1 3600 86400)"
assert_eq "backoff: second failure quadruples" "14400" \
    "$(update_retry_delay 2 3600 86400)"
assert_eq "backoff: third failure" "28800" \
    "$(update_retry_delay 3 3600 86400)"
assert_eq "backoff: capped at max" "86400" \
    "$(update_retry_delay 20 3600 86400)"
assert_eq "backoff: no failures uses base interval" "3600" \
    "$(update_retry_delay 0 3600 86400)"
assert_eq "backoff: custom base" "200" \
    "$(update_retry_delay 1 100 86400)"

# ---------------------------------------------------------------------------
if [ "$failures" -eq 0 ]; then
    printf '\nAll update-helper tests passed.\n'
    exit 0
fi

printf '\n%d update-helper test(s) failed.\n' "$failures"
exit 1
