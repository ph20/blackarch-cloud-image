#!/usr/bin/env bash

function status_line() {
  if [ -n "${STATUS_FD_READY:-}" ]; then
    printf '%s\n' "${1}" >&3
  fi

  printf '%s\n' "${1}"
}

function log_step() {
  CURRENT_STEP="${1}"
  export CURRENT_STEP
  status_line "==> ${1}"
}

function format_command_line() {
  local formatted=''
  local argument=''

  for argument in "${@}"; do
    if [ -n "${formatted}" ]; then
      formatted+=" "
    fi

    formatted+="$(printf '%q' "${argument}")"
  done

  printf '%s\n' "${formatted}"
}

function log_command() {
  printf '+ %s\n' "$(format_command_line "${@}")" >&2
}

function log_command_line() {
  printf '+ %s\n' "${1}" >&2
}

function run_logged() {
  log_command "${@}"
  "${@}"
}
