# cooked's core shell integration for bash: OSC 133 semantic prompts and OSC 7
# directory reporting.
#
# Source it from ~/.bashrc:
#
#     [[ $TERM_PROGRAM == cooked ]] && source /path/to/cooked.bash
#
# cooked also injects this file into the bash shells it starts, so on a local session
# the line is redundant -- and worth having anyway.  Injection reaches exactly the
# shell cooked spawned; `exec bash', `sudo -i', `docker exec' and the far end of every
# ssh land outside it, and the line crosses all of them.  Sourcing twice is a no-op.
# Getting TERM_PROGRAM there is `SendEnv'/`AcceptEnv', and is yours to configure.
#
# What is turned on comes from COOKED_SHELL_INTEGRATION_FEATURES -- see __cooked_want below,
# and `cooked-shell-integration-features' on the Emacs side.
#
# The completion capture is its own file, cooked-completion.bash; the announcement
# below is here because it is not about completion. See the comment on it.

[[ $TERM_PROGRAM == cooked ]] || return
[[ -n "${COOKED_INTEGRATION_LOADED-}" ]] && return
COOKED_INTEGRATION_LOADED=1
[[ $- == *i* ]] || return

# The feature list, taken verbatim from the environment so that a shell cooked
# injected into and one that sourced this by hand agree about what is on.  Unset
# means cooked did not start this shell -- an ssh that does not forward the variable,
# a container -- and the fallback is the same default the Emacs option carries.
__cooked_features="${COOKED_SHELL_INTEGRATION_FEATURES-marks input-mark cwd announce completion title}"

# A feature is on if it is named and not un-named.  The `no-NAME' form lets a prompt
# that already does one of these jobs stand cooked's half down without giving up the
# rest; subtraction wins, so an rc appending ` no-marks' is always the last word.
__cooked_want() {
  case " $__cooked_features " in
    *" no-$1 "*) return 1 ;;
    *" $1 "*)    return 0 ;;
    *)           return 1 ;;
  esac
}

__cooked_osc() { printf '\033]%s\007' "$1"; }

# The DEBUG trap fires before *every* command, including each one in PROMPT_COMMAND,
# so it needs to know when it is looking at a command the user actually typed.
#
# Comparing $BASH_COMMAND against $PROMPT_COMMAND cannot do it: PROMPT_COMMAND holds
# several commands separated by `;' and BASH_COMMAND is one of them, so the test
# never fires and every prompt emits a spurious `C'.  Latch instead -- the last entry
# in PROMPT_COMMAND arms the trap, and the first command after the prompt disarms it.
# Anything running inside PROMPT_COMMAND, ours or a theme's, is therefore skipped.
__cooked_armed=

__cooked_ready() { __cooked_armed=1; }

__cooked_preexec() {
  # Completion runs commands too, and none of them are the user's.
  [[ -n "${COMP_LINE-}" ]] && return 0
  # Nor is anything of ours.  The completion capture answers a request from a
  # `bind -x' keybinding, which is a command like any other as far as this trap is
  # concerned -- and marking it as one is not merely untidy: a `C' says a command
  # started, which clears the announcement nonce in Emacs, so the *next* completion
  # request on the same prompt would arrive unlicensed and be refused.
  case "$BASH_COMMAND" in __cooked_*) return 0 ;; esac
  [[ -z "$__cooked_armed" ]] && return 0
  __cooked_armed=
  __cooked_want marks && __cooked_osc "133;C"
  return 0
}

__cooked_precmd() {
  local status=$?
  __cooked_want marks && __cooked_osc "133;D;$status"
  __cooked_want cwd   && __cooked_osc "7;file://${HOSTNAME}${PWD}"
  return 0
}

# The B mark says "the shell is now reading input", which is what hands the keyboard
# to Emacs. Setting PS1 once here is not enough: starship, oh-my-bash and friends
# rebuild PS1 from PROMPT_COMMAND, silently dropping the mark. Re-append each prompt.
#
# A and B are appended independently: `A' is part of the marks, while `B' is the one
# mark that changes who owns the keyboard and is its own feature.  Each is tested for
# on its own, so a theme that rebuilt PS1 gets a fresh append and one that left it
# alone does not accumulate copies.
__cooked_prompt() {
  # \[ \] keep the markers out of readline's width calculation.  The tests below look
  # for the literal backslash escapes, which is what PS1 holds -- bash expands them
  # when it draws the prompt, so a test for a real ESC byte would never match and the
  # marks would be appended afresh every prompt until PS1 was mostly marks.
  if __cooked_want marks; then
    case "$PS1" in
      *'\033]133;A\007'*) ;;
      *) PS1='\[\033]133;A\007\]'"${PS1}" ;;
    esac
  fi
  if __cooked_want input-mark; then
    case "$PS1" in
      *'\033]133;B\007'*) ;;
      *) PS1="${PS1}"'\[\033]133;B\007\]' ;;
    esac
    # PS2, the continuation prompt.  Without a `B' here every line after the first of
    # `for x in 1 2; do' falls out of Emacs' hands back to readline, so you compose
    # the first line in Emacs and the rest in bash's own line editor.
    #
    # `A;k=s' rather than a bare `A': `k=s' says this prompt *continues* the previous
    # one, which is what lets Emacs leave the prompt marker where the construct began
    # instead of restarting the command record at the last continuation line.  Both
    # halves are appended together and tested for as one -- an `A' with no `B' here
    # would be a mark with nothing to buy -- so this is under `input-mark' rather
    # than split across the two features the way PS1 is.
    case "$PS2" in
      *'\033]133;B\007'*) ;;
      *) PS2='\[\033]133;A;k=s\007\]'"${PS2}"'\[\033]133;B\007\]' ;;
    esac
  fi
}

# The completion announcement.
#
# `OSC 51;CH;<version>;<nonce>;<replies>', emitted at every prompt.  It is in the core
# rather than with the completion capture because Emacs reads it as two different
# things and only one of them is about completion: to the completion layer it is the
# token a request must carry, and to everything else it is a *license to own the input
# line* -- the shell asserting, for this prompt, that a line editor is bound and
# reading.  That is the one signal both byte-transparent (so it survives an ssh, where
# termios does not) and self-corroborating.
#
# The last field says whether a request can be *answered*, which cooked-completion.bash
# turns on.  Announcing regardless is the point: staying quiet because the optional
# half is not loaded would cost the editable line for an unrelated reason.
#
# From PROMPT_COMMAND rather than from readline, which is the one place bash is weaker
# than zsh here: zsh announces from `zle-line-init', after ZLE has taken the terminal,
# so a request answering it cannot arrive while the line discipline is still echoing.
# bash offers no such hook.  In practice the gap closes before it matters -- Emacs
# sends nothing until the user asks to complete, which is long after the prompt is
# drawn -- but it is a gap rather than an impossibility, and worth writing down.
__cooked_complete_nonce=
__cooked_complete_replies=0

__cooked_complete_announce() {
  __cooked_complete_nonce=${RANDOM}${RANDOM}
  printf '\033]51;CH;2;%s;%s\033\\' "$__cooked_complete_nonce" "$__cooked_complete_replies"
}

# Deferred setup.  Nothing above is registered until the first prompt, which is what
# gives a .bashrc somewhere to stand: it runs before this does, so it can append to
# COOKED_SHELL_INTEGRATION_FEATURES and be heard.  It also puts our hooks after every theme's.
__cooked_deferred_init() {
  __cooked_features="${COOKED_SHELL_INTEGRATION_FEATURES-$__cooked_features}"

  # __cooked_precmd stays first, because it reads $? and anything running before it
  # would overwrite that with its own status.  __cooked_prompt goes last, so it
  # re-appends after whichever theme rebuilt PS1.
  local user=${PROMPT_COMMAND-}
  user=${user%__cooked_deferred_init}
  user=${user%;}
  PROMPT_COMMAND="__cooked_precmd${user:+;$user};__cooked_prompt"
  __cooked_want announce && PROMPT_COMMAND="${PROMPT_COMMAND};__cooked_complete_announce"
  # Last, so that everything else in the prompt -- ours and the user's -- has run
  # before the trap starts treating commands as typed ones.
  PROMPT_COMMAND="${PROMPT_COMMAND};__cooked_ready"

  unset -f __cooked_deferred_init
  __cooked_prompt
  __cooked_want cwd && __cooked_osc "7;file://${HOSTNAME}${PWD}"
  # We are running as the *first* entry of the old PROMPT_COMMAND, so everything
  # appended above belongs to the next prompt rather than this one.  Run the two
  # that the first prompt would otherwise go without: the announcement, which is
  # what licenses the editable line, and arming the trap, without which the first
  # command typed is the one command that goes unmarked.
  __cooked_want announce && __cooked_complete_announce

  # The DEBUG trap goes in last, and nothing may follow it here: it fires before
  # every simple command, so a `return' on the next line would be reported as the
  # first command of the session and the prompt would open with a stray `C'.
  if __cooked_want marks; then
    __cooked_ready
    trap '__cooked_preexec' DEBUG
  fi
}
# Appended rather than prepended, so that on the very first prompt we run *after*
# whatever the user's rc registered.  A theme that rebuilds PS1 would otherwise do so
# after we had already appended the `B' mark to it, and the first prompt -- the one a
# session opens on -- would be the single prompt that never handed Emacs the line.
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}__cooked_deferred_init"
