#!/usr/bin/env bash

# Emit literal path/replacement pairs, including the form used by log_command.
function public_log_path_entry() {
  local path="${1%/}"
  local replacement="${2}"

  [ -n "${path}" ] || return 0
  printf '%s\n%s\n' "${path}" "${replacement}"
  printf '%s\n%s\n' "$(printf '%q' "${path}")" "${replacement}"
}

function public_log_unescape_path() {
  local path="${1}"
  local decoded=''
  local character=''
  local i=0

  # Decode printf %q backslash quoting without evaluating log content as shell.
  for ((i = 0; i < ${#path}; i++)); do
    character="${path:i:1}"
    if [ "${character}" = "\\" ] && [ "$((i + 1))" -lt "${#path}" ]; then
      i=$((i + 1))
      character="${path:i:1}"
    fi
    decoded+="${character}"
  done
  printf '%s\n' "${decoded}"
}

function public_log_path_entries() {
  local source="${1}"
  local line=''
  local path=''

  public_log_path_entry "${PROJECT_ROOT}" '[repo]'

  # Existing artifacts may have been built in a different checkout. Read their
  # script locations instead of relying only on the publishing host.
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    case "${line}" in
      '+ bash '/*/scripts/build-rootfs.sh\ * | '+ bash '/*/scripts/assemble-image.sh\ * | '+ bash '/*/scripts/export-image.sh\ *)
        path="${line#+ bash }"
        path="${path%/scripts/*}"
        public_log_path_entry "${path}" '[repo]'
        public_log_path_entry "$(public_log_unescape_path "${path}")" '[repo]'
        ;;
      'Running profile hook '*" from /"*)
        path="${line#* from }"
        public_log_path_entry "${path%/*}" '[profile-hooks]'
        ;;
    esac
  done <"${source}"
}

function sanitize_public_build_log() {
  local source="${1}"
  local destination="${2}"

  # Use literal string matching: paths can contain regex/sed metacharacters.
  # At each position prefer the longest prefix and never rescan replacements.
  LC_ALL=C awk '
    function path_position(text, path, start, position, before, after) {
      while ((position = index(substr(text, start), path))) {
        position += start - 1
        before = position > 1 ? substr(text, position - 1, 1) : ""
        after = substr(text, position + length(path), 1)
        if (before !~ /[[:alnum:]_.\/+\055]/ && after !~ /[[:alnum:]_.+\055]/)
          return position
        start = position + 1
      }
      return 0
    }
    NR == FNR {
      path = $0
      if ((getline replacement) <= 0) exit 1
      if (!(path in seen)) {
        seen[path] = 1
        paths[++count] = path
        replacements[count] = replacement
      }
      next
    }
    {
      cursor = 1
      result = ""
      while (cursor <= length($0)) {
        first = 0
        chosen = 0
        for (i = 1; i <= count; i++) {
          position = path_position($0, paths[i], cursor)
          if (position && (!first || position < first ||
              (position == first && length(paths[i]) > length(paths[chosen])))) {
            first = position
            chosen = i
          }
        }
        if (!first) break
        result = result substr($0, cursor, first - cursor) replacements[chosen]
        cursor = first + length(paths[chosen])
      }
      print result substr($0, cursor)
    }
  ' <(public_log_path_entries "${source}") "${source}" >"${destination}"
}
