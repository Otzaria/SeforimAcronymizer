#!/usr/bin/env bash
# Gate a built acronymizer DB before it is released: SeforimLibrary downloads
# the latest release on every build, so a release that breaks this contract
# ships a library with no acronyms.
# Usage: scripts/validate-db.sh <new.db> [previous-release.db]
set -euo pipefail

NEW="${1:?usage: validate-db.sh <new.db> [previous-release.db]}"
OLD="${2:-}"
MAX_DROP_PERCENT=2
# Titles whose acronyms SeforimLibrary is known to import.
SAMPLE_TITLES=("ספר הזהר" "בראשית" "ברכות")

failures=0
fail() { echo "::error::$1"; failures=$((failures + 1)); }
q() { sqlite3 -noheader -batch "$1" "$2" | tr -d '\r'; }

# --- schema: the tables and columns the SeforimLibrary generator reads ---
require_columns() { # table, columns...
  local table="$1"; shift
  local have; have=$(q "$NEW" "SELECT name FROM pragma_table_info('$table');")
  [ -n "$have" ] || { fail "missing table $table"; return; }
  for col in "$@"; do
    grep -qx "$col" <<<"$have" || fail "table $table is missing column $col"
  done
}
require_columns Books id title
require_columns Acronyms id acronym
require_columns BookAcronyms book_id acronym_id

if [ "$failures" -eq 0 ]; then
  # --- the generator's exact lookup (Generator.fetchAcronymsForTitle) ---
  for title in "${SAMPLE_TITLES[@]}"; do
    escaped=${title//\'/\'\'}
    n=$(q "$NEW" "SELECT COUNT(a.acronym) FROM Books b
      JOIN BookAcronyms ba ON b.id = ba.book_id
      JOIN Acronyms a ON ba.acronym_id = a.id
      WHERE b.title = '$escaped';")
    [ "$n" -gt 0 ] || fail "generator lookup returns no acronyms for '$title'"
  done

  # --- integrity ---
  broken=$(q "$NEW" "PRAGMA foreign_key_check;" | wc -l)
  [ "$broken" -eq 0 ] || fail "$broken BookAcronyms rows point to a missing book or acronym"
  orphans=$(q "$NEW" "SELECT COUNT(*) FROM Acronyms WHERE id NOT IN (SELECT acronym_id FROM BookAcronyms);")
  [ "$orphans" -eq 0 ] || fail "$orphans acronyms are linked to no book"
  blank_titles=$(q "$NEW" "SELECT COUNT(*) FROM Books WHERE trim(title) = '';")
  [ "$blank_titles" -eq 0 ] || fail "$blank_titles books have a blank title"
  blank_acronyms=$(q "$NEW" "SELECT COUNT(*) FROM Acronyms WHERE trim(acronym) = '';")
  [ "$blank_acronyms" -eq 0 ] || fail "$blank_acronyms acronyms are blank"

  # --- regression against the previous release ---
  if [ -n "$OLD" ]; then
    # BookAcronyms is measured in distinct aliases as the app matches them, so removing
    # variants that differ only in quotes or punctuation (or repeat the title) is not a drop.
    norm() { # SQL expression: column -> key close to the app's normalizeForFindRefMatch
      local e="lower($1)"
      for ch in '"' "''" '״' '׳' '“' '”' '‘' '’'; do e="replace($e, '$ch', '')"; done
      for ch in '-' '־' ',' '.' ':' ';' '(' ')' '|'; do e="replace($e, '$ch', ' ')"; done
      for _ in 1 2 3; do e="replace($e, '  ', ' ')"; done
      echo "trim($e)"
    }
    distinct_aliases="SELECT COUNT(*) FROM (SELECT DISTINCT ba.book_id, $(norm a.acronym) AS k
      FROM BookAcronyms ba JOIN Acronyms a ON a.id = ba.acronym_id JOIN Books b ON b.id = ba.book_id
      WHERE $(norm a.acronym) <> $(norm b.title));"
    for check in "Books|SELECT COUNT(*) FROM Books;" "BookAcronyms (distinct normalized)|$distinct_aliases"; do
      label=${check%%|*}; sql=${check#*|}
      before=$(q "$OLD" "$sql")
      after=$(q "$NEW" "$sql")
      if [ "$before" -gt 0 ] && [ $(( (before - after) * 100 )) -gt $(( before * MAX_DROP_PERCENT )) ]; then
        fail "$label dropped from $before to $after (more than ${MAX_DROP_PERCENT}%)"
      fi
      echo "$label: $before -> $after"
    done
  fi
fi

if [ "$failures" -gt 0 ]; then
  echo "validation failed: $failures problem(s)"
  exit 1
fi
echo "validation passed"
