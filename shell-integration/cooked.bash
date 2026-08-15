# OSC 133 semantic prompts for bash, plus OSC 7 directory reporting.
# Source from ~/.bashrc, or let cooked inject it with a generated rcfile.

[[ -n "${COOKED_INTEGRATION_LOADED-}" ]] && return
COOKED_INTEGRATION_LOADED=1
[[ $- == *i* ]] || return

__cooked_osc() { printf '\033]%s\007' "$1"; }

__cooked_preexec() {
  # Skip completion and the prompt command itself; neither is a user command.
  [[ -n "${COMP_LINE-}" ]] && return
  [[ "$BASH_COMMAND" == "${PROMPT_COMMAND-}" ]] && return
  [[ -n "${__cooked_running-}" ]] && return
  __cooked_running=1
  __cooked_osc "133;C"
}

__cooked_precmd() {
  local status=$?
  __cooked_osc "133;D;$status"
  __cooked_osc "7;file://${HOSTNAME}${PWD}"
  unset __cooked_running
}

# The B mark says "the shell is now reading input", which is what hands the keyboard
# to Emacs. Setting PS1 once here is not enough: starship, oh-my-bash and friends
# rebuild PS1 from PROMPT_COMMAND, silently dropping the mark. Re-append each prompt.
__cooked_prompt() {
  # \[ \] keep the markers out of readline's width calculation.
  case "$PS1" in
    *$'\033]133;B\007'*) ;;
    *) PS1='\[\033]133;A\007\]'"${PS1}"'\[\033]133;B\007\]' ;;
  esac
}

trap '__cooked_preexec' DEBUG
# __cooked_precmd stays first, because it reads $? and anything running before it
# would overwrite that with its own status. __cooked_prompt goes last, so it re-appends
# after whichever theme rebuilt PS1.
PROMPT_COMMAND="__cooked_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND};__cooked_prompt"
__cooked_prompt
