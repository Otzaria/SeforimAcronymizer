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
    # Books moved from the previous release to data/unmatched.tsv (no matching library title)
    # are parked, not lost, so they count as still present.
    UNMATCHED="${UNMATCHED:-$(dirname "$0")/../data/unmatched.tsv}"
    moved() { # SQL over table u(title, alias) restricted to titles that left the release now
      [ -f "$UNMATCHED" ] || { echo 0; return; }
      # not .import: in tab mode a leading " is CSV quoting, and some aliases start with one
      local rows
      rows=$(sed '1d' "$UNMATCHED" | tr -d '\r' | sed "s/'/''/g; s/^/INSERT INTO u VALUES('/; s/\t/','/; s/\$/');/")
      sqlite3 -noheader -batch :memory: <<SQL | tr -d '\r'
CREATE TABLE u(title TEXT, alias TEXT);
$rows
ATTACH '$OLD' AS old; ATTACH '$NEW' AS new;
CREATE TEMP VIEW m AS SELECT * FROM u WHERE title IN (SELECT title FROM old.Books)
  AND title NOT IN (SELECT title FROM new.Books);
$1
SQL
    }
    moved_books="SELECT COUNT(DISTINCT title) FROM m;"
    moved_aliases="SELECT COUNT(*) FROM (SELECT DISTINCT title, $(norm alias) FROM m WHERE $(norm alias) <> $(norm title));"
    labels=("Books" "BookAcronyms (distinct normalized)")
    counts=("SELECT COUNT(*) FROM Books;" "$distinct_aliases")
    moves=("$moved_books" "$moved_aliases")
    for i in 0 1; do
      label=${labels[$i]}
      before=$(q "$OLD" "${counts[$i]}")
      after=$(( $(q "$NEW" "${counts[$i]}") + $(moved "${moves[$i]}") ))
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
