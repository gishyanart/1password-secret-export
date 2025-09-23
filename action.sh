#!/usr/bin/env bash

set -eE -o pipefail -o functrace

trap 'error_handler $LINENO' ERR

error_handler() {
    local line_number=$1
    echo "Error Details:"
    echo "  Line: $line_number"
    echo "  Command: $BASH_COMMAND"
    exit 1
}

setup() {

  command -v op >/dev/null 2>&1 || { echo "op CLI not found in PATH"; exit 1; }
  command -v yq >/dev/null 2>&1 || { echo "yq not found in PATH"; exit 1; }

  : "${OP_VAULT:?OP_VAULT is required}"
  : "${OP_ITEM:?OP_ITEM is required}"
  : "${OP_SERVICE_ACCOUNT_TOKEN:?OP_SERVICE_ACCOUNT_TOKEN is required}"
  : "${OP_SECTIONS:-''}"
  : "${EXPORT_VARIABLES:-true}"
  : "${EXPORT_TO_FILE:-''}"

  declare -gA ALLOWED_CATEGORIES

  ALLOWED_CATEGORIES=(
    ["SECURE_NOTE"]=1
  )
}

check() {
  local category
  category="$(op item get --vault "${OP_VAULT}" "${OP_ITEM}" --format=json | yq -r '.category')"
  if [ "${ALLOWED_CATEGORIES[${category}]}" != "1" ]; then
    echo "category \`${category}\` is not allowed"
    exit 1
  fi
}

merge() {
  local result
  result='{}'
  for i in "$@"; do
    result="$(yq -o json "$result * ." < <(printf "%s" "$i"))"
  done
  echo "$result"
}

from_sections() {
  local sections value result
  if [ -z "${OP_SECTIONS}" ]; then
    echo '{}'
    return
  fi
  readarray -t -d',' sections < <(printf "%s" "${OP_SECTIONS}")
  result='{}'
  for section in "${sections[@]}"; do
    export OP_SECTION_NAME="${section}"
    # shellcheck disable=SC2016
    value="$(op item get --vault "${OP_VAULT}" "${OP_ITEM}" --format=json | yq -o json '.fields[] | select(.section.label == env(OP_SECTION_NAME) and .label != "notesPlain") | {.label: .value} | . as $item ireduce ({}; . * $item )')"
    result="$(merge "$result" "$value")"
  done
  echo "$result"
}

from_root() {
  # shellcheck disable=SC2016
  op item get --vault "${OP_VAULT}" "${OP_ITEM}" --format=json | yq -o json '.fields[] | select(.section.id == "add more" and .label != "notesPlain") | {.label: .value} | . as $item ireduce ({}; . * $item )'
}

export_to_file() {
	local file_dir
	file_dir="$(dirname "${EXPORT_TO_FILE}")"
	mkdir -p "${file_dir}"
	yq . -o shell < <(printf "%s" "${1}") >> "${EXPORT_TO_FILE}"
}

write_github_env() {
  local key value json tmp
  json="$1"
  if [ -z "${GITHUB_ENV:-}" ]; then
    echo "GITHUB_ENV is not set; skipping env export" >&2
    return 0
  fi
  tmp="$(mktemp)"
  yq -o shell < <(printf "%s" "${json}") > "${tmp}"
  set -a
  # shellcheck disable=SC1090
  source "${tmp}"
  set +a
  rm "${tmp}"
  while read -r key; do
    {
      printf '%s<<__OP_EOF__\n' "$key"
      printf '%s\n' "${!key}"
      printf '__OP_EOF__\n'
    } >> "${GITHUB_ENV}"
    printf '::add-mask::%s\n' "$key"
  done < <(yq 'keys|.[]' < <(printf "%s" "${json}"))
}

main() {
  local from_root from_sections result
  from_root="$(from_root)"
  from_sections="$(from_sections)"
  result="$(merge "${from_root}" "${from_sections}")"
  if [ "${EXPORT_VARIABLES}" == "true" ]; then
    write_github_env "${result}"
  fi
  if [ "${EXPORT_TO_FILE}" ]; then
    export_to_file "${result}"
  fi
}

setup
check
main
