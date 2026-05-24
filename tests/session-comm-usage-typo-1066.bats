#!/usr/bin/env bats
# session-comm-usage-typo-1066.bats
# Requirement: session-comm.sh のファイルヘッダ usage コメントに
#   [--wait SECONDS] が重複記載されている typo を修正 (issue-1066)
# Spec: issue-1066
# Coverage: --type=structural

setup() {
    PLUGIN_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$PLUGIN_ROOT/scripts/session-comm.sh"
}

# ===========================================================================
# AC1: ファイルヘッダ usage の inject-file 行に --wait SECONDS が1回のみ含まれる
# ===========================================================================

@test "session-comm-usage-typo[structural][RED]: ファイルヘッダ inject-file 行に --wait が重複しない" {
    local inject_file_line
    inject_file_line=$(grep 'inject-file.*--wait' "$SCRIPT" | head -1)

    local count
    count=$(echo "$inject_file_line" | grep -o '\-\-wait' | wc -l)
    [[ "$count" -eq 1 ]] || {
        echo "FAIL: inject-file usage 行に --wait が ${count} 回含まれている (expected: 1)" >&2
        echo "  line: $inject_file_line" >&2
        return 1
    }
}
