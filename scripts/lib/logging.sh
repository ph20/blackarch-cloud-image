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
