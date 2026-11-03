# shellcheck shell=bash
# Installs Anysola Code into ~/.anysola/bin and sets ANYSOLA_BIN. Sourced
# by main.sh. ANYSOLA_CODE_BIN points at a binary already on the machine
# instead (the action's own tests).

if [ -n "${ANYSOLA_CODE_BIN:-}" ]; then
  ANYSOLA_BIN=$ANYSOLA_CODE_BIN
else
  install_args=(--no-modify-path)
  if [ "$INPUT_VERSION" != latest ]; then
    install_args+=(--version "${INPUT_VERSION#v}")
  fi
  # pipefail (main.sh) makes a failed download fail the install too.
  curl -fsSL --retry 3 https://www.anysola.com/install | sh -s -- "${install_args[@]}" >&2 ||
    fail "Installing Anysola Code ${INPUT_VERSION} from www.anysola.com/install failed."
  install_dir=${ANYSOLA_INSTALL_DIR:-$HOME/.anysola/bin}
  ANYSOLA_BIN=$install_dir/anysola
  # Later steps of the job can call it too.
  if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$install_dir" >>"$GITHUB_PATH"
  fi
fi

[ -x "$ANYSOLA_BIN" ] || fail "Anysola Code is not at $ANYSOLA_BIN after installing."
log "Using $("$ANYSOLA_BIN" --version 2>/dev/null || echo "$ANYSOLA_BIN")"
