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

# Aliases are expanded when a function body is *parsed*, not when it runs, and this
# file is sourced after the user's rc -- so an `alias printf='printf --'' in .bashrc
# would be baked into every function below and there would be no way to see it from
# in here.  Turning expansion off for the length of the file is the only thing that
# reaches that, because by the time any of this code executes the damage is done.
#
# Every command below is *also* spelled `builtin' or `command', which is what kitty
# and Ghostty rely on alone.  The two guards cover different holes: the shopt covers
# aliases, and the prefixes cover shell *functions* named `printf' or `history',
# which no shopt can turn off.  Restored at the very bottom of the file.
__cooked_had_aliases=
shopt -q expand_aliases && __cooked_had_aliases=1
shopt -u expand_aliases

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

__cooked_osc() { builtin printf '\033]%s\007' "$1"; }

#
# Percent-encoding, for OSC 7 and for the command line on the `C' mark.
#
# Both of those are URIs on the wire and Emacs decodes them as URIs, so a path that
# is not encoded here does not merely look wrong at the far end -- it decodes to a
# *different* path.  `cd /tmp/100%20cake' reported raw arrives in Emacs as
# `/tmp/100 cake', a directory that does not exist, and directory tracking stops
# without a word.  A fish 4 doing its own reporting encodes the same way, so there is
# one encoding on the wire and one decoding at the far end.
#
# Written out by hand rather than shelled out to, because it runs on the prompt path
# and a fork there is felt.  `LC_ALL=C' on its own line, not folded into the `local'
# below it: assignments in one `local' take effect left to right but the locale change
# does not reach the `${#1}' beside it, so the length came out in characters while the
# indexing came out in bytes, and every path with a non-ASCII character in it lost its
# last byte.  Two statements, and both halves agree that they are counting bytes.
#
# The answer is left in __cooked_encoded rather than printed, so that callers can have
# it without a `$(...)' -- which is a fork, on a path that runs once per command and
# once per directory change.  kitty and Ghostty both fork here; there is no need to.
__cooked_encoded=

__cooked_encode() {
  local LC_ALL=C
  local out= i c n
  n=${#1}
  for (( i = 0; i < n; i++ )); do
    c=${1:i:1}
    case $c in
      # RFC 3986's unreserved set, plus `/', which is a path separator here rather
      # than data and must survive as one.
      [-_.~/a-zA-Z0-9]) out+=$c ;;
      *) builtin printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  __cooked_encoded=$out
}

# Reported only when it changed.  A prompt is drawn far more often than a directory
# is entered -- every `reset-prompt', every empty return -- and the encoding above is
# a loop over the bytes of the path, so the test is worth more than it costs.  It also
# keeps the terminal's idea of the directory from being rewritten by prompts that are
# not about it at all.
__cooked_last_cwd=

__cooked_report_cwd() {
  [[ $PWD == "$__cooked_last_cwd" ]] && return 0
  __cooked_last_cwd=$PWD
  __cooked_encode "$PWD"
  __cooked_osc "7;file://${HOSTNAME}${__cooked_encoded}"
}

#
# The `C' mark, from PS0.
#
# PS0 is expanded and printed after a command line is read and before it runs, exactly
# once, which is the definition of the `C' mark -- so the mark is a string in a prompt
# variable rather than a hook that has to work out whether it is looking at the user's
# command.  This replaces a DEBUG trap, and the trap was wrong twice over: it fires
# before *every* simple command, so it needed a latch to tell the user's commands from
# the ones inside PROMPT_COMMAND, and `trap ... DEBUG' silently replaces whatever was
# installed before it.  Since we register at the first prompt, after everything else,
# the thing we replaced was usually bash-preexec -- so loading cooked quietly turned
# off every `preexec_functions' hook the user had.  PS0 shares nothing and displaces
# nothing.  kitty and Ghostty both moved to PS0 for the same reasons.
#
# It cannot carry `\[' and `\]'.  Those are readline's "zero width from here" markers
# and readline is not involved in PS0: bash expands them to the raw SOH and STX bytes
# and writes them to the terminal.  kitty ships that -- `\[\e]133;C\a\]' in PS0 -- and
# gets away with it because a terminal ignores stray C0 controls.  They are still two
# bytes of noise per command that mean nothing, so they are not here.
#
# `cmdline_url=' rather than kitty's `cmdline=', which is `printf %q' output and so is
# quoted in a way only that shell can undo -- `ls -la' arrives as `ls\ -la', and an
# Emacs that guessed at unquoting it would be putting its guess in the command record.
# Percent-encoding has one reading.
__cooked_preexec() {
  local entry number cmdline=

  # `history 1' is the only way bash will tell a hook what was typed.  It is also a
  # liar under `HISTCONTROL=ignorespace', where the line that is about to run was
  # never recorded and `history 1' answers with the *previous* command -- which kitty
  # and Ghostty both report as the running one.  The history number settles it:
  # __cooked_hist is what bash said the next command would be numbered, taken at the
  # prompt, so an entry carrying that number is this command and an entry carrying an
  # older one is the last command wearing its name.  When they disagree we say
  # nothing, which is the only honest answer: Emacs still has the text it submitted.
  #
  # HISTTIMEFORMAT is cleared so the entry is `NUMBER  TEXT' and nothing else, and
  # LC_ALL=C so that the digits are digits.
  entry=$(LC_ALL=C HISTTIMEFORMAT= builtin history 1 2>/dev/null)
  # Leading blanks, then the number, then the `*' bash marks a modified entry with.
  entry=${entry#"${entry%%[![:space:]]*}"}
  number=${entry%%[^0-9]*}
  if [[ -n $number && $number == "${__cooked_hist-}" ]]; then
    cmdline=${entry#"$number"}
    cmdline=${cmdline#\*}
    cmdline=${cmdline#"${cmdline%%[![:space:]]*}"}
  fi

  if __cooked_want marks; then
    if [[ -n $cmdline ]]; then
      __cooked_encode "$cmdline"
      __cooked_osc "133;C;cmdline_url=${__cooked_encoded}"
    else
      __cooked_osc "133;C"
    fi
  fi

  # The title, which is the same text and the same moment.  Control characters are
  # dropped rather than encoded: this one is for a human to read in a mode line.
  # Gated on its own feature, and reached whether or not the marks are on -- the two
  # share a hook because they share an instant, not because either needs the other.
  __cooked_want title && [[ -n $cmdline ]] &&
    builtin printf '\033]2;%s\007' "${cmdline//[[:cntrl:]]/}"
  return 0
}

# `$?' has to be read on the first line of the first thing PROMPT_COMMAND runs, which
# is what this is: anything ahead of it -- a theme's hook, an `__theme' that returns 0 --
# overwrites the status with its own and every exit code we report is that hook's.  That
# is why the prompt work is a second entry at the *other* end of PROMPT_COMMAND rather
# than folded in here; see __cooked_prompt_hook.
#
# `D' closes a command, so the first prompt of a session has nothing to close and must
# not send one.  __cooked_hist is unset exactly there and set at every prompt after,
# which makes it the test.  kitty and Ghostty carry a three-state machine here that
# also tells an empty return -- prompt, Enter, prompt, no command -- from a real one,
# and emit a bare `D' for it.  bash cannot join them honestly: the only place it will
# say a command started is PS0, which is a subshell before 5.3 and so cannot record
# that it ran, and the one signal that survives, HISTCMD, does not advance for a
# command suppressed by HISTCONTROL -- so a state machine built on it would trade a
# harmless extra `D' for a missing exit code, which is the worse of the two.  Emacs
# ignores a `D' that closes nothing; see `cooked--mark-command-end'.
__cooked_precmd() {
  local status=$?
  __cooked_want marks && [[ -n ${__cooked_hist-} ]] && __cooked_osc "133;D;$status"
  __cooked_want cwd   && __cooked_report_cwd
  # What bash will number the next command, read where it is still true.  See
  # __cooked_preexec, which is a subshell on bash before 5.3 and so can read this but
  # never write it -- which is why the comparison is arranged to need no writing.
  __cooked_hist=${HISTCMD-}
  return 0
}

#
# The prompt marks.
#
# The opening mark and `B', which closes the prompt and hands the keyboard to Emacs.
# Both live in PS1 rather than being printed from a hook, so that they are re-emitted
# whenever bash redraws the prompt -- on Ctrl-L, on a resize, on a vi-mode switch, on
# any readline redisplay -- instead of only when a hook happened to run.
#
# The opening mark is spelled `A', with no `k=' at all, since absent means `k=i'.  The
# proposal also spells this mark `P', and Ghostty sends that one from its own PS1
# because `A' is defined to imply a fresh line and a mark re-emitted on every readline
# repaint must not carry that.  cooked implements no fresh-line behaviour for either
# spelling, so `P' would buy nothing here and would leave these snippets as the only
# thing on the wire emitting it; `A' is what fish 4 sends unprompted, so it is the one
# spelling every emitter cooked can actually hear from uses.
#
# Setting PS1 once at startup is not enough either: starship, oh-my-bash and friends
# rebuild PS1 from PROMPT_COMMAND, silently dropping whatever we put there.  So the
# marks are re-applied every prompt, from the clean text.
#
# "The clean text" is the part worth being careful about.  Searching PS1 for our own
# markers and appending if absent -- which is what this used to do, and what kitty
# still does -- has a false positive and a false negative, both of kitty's own
# documenting: `PS1="%(?.$mark.)"' contains the mark without emitting it, and a PS1
# built with prompt substitution may emit it without containing it.  Keeping the two
# versions instead is exact.  If PS1 is byte-for-byte what we last wrote, nobody has
# touched it and the clean copy still stands; if it is anything else, a theme rebuilt
# it and *that* is the new clean copy.  No pattern matching, no accumulation.
__cooked_ps1_clean=
__cooked_ps1_marked=
__cooked_ps2_clean=
__cooked_ps2_marked=
__cooked_ps0_clean=
__cooked_ps0_marked=

__cooked_prompt() {
  local a= b=

  __cooked_want marks      && a='\[\033]133;A\007\]'
  __cooked_want input-mark && b='\[\033]133;B\007\]'

  if [[ -n $a || -n $b ]]; then
    [[ $PS1 == "$__cooked_ps1_marked" ]] || __cooked_ps1_clean=$PS1
    PS1="${a}${__cooked_ps1_clean}${b}"
    # A multi-line prompt, which is what starship and most bash themes draw.  bash
    # redraws only the *last* line of one, so without a mark opening each of the
    # others Emacs reads the whole block as one prompt line and puts the input region
    # in the wrong place after every redraw.  `k=s' says these continue the prompt
    # that began above rather than starting one, which is the same thing PS2 says.
    #
    # Only the `\n' escape is rewritten, never a literal newline: a literal one can be
    # inside a `$(...)' in the prompt, where an escape sequence would be shell syntax
    # rather than prompt text.  Ghostty draws the same line for the same reason.
    if [[ -n $a && $PS1 == *'\n'* ]]; then
      PS1=${PS1//'\n'/'\n\[\033]133;A;k=s\007\]'}
    fi
    __cooked_ps1_marked=$PS1
  fi

  # PS2, the continuation prompt.  Without a `B' here every line after the first of
  # `for x in 1 2; do' falls out of Emacs' hands back to readline, so you compose the
  # first line in Emacs and the rest in bash's own line editor.
  #
  # `k=s' says this prompt *continues* the previous one, which is what lets Emacs leave
  # the prompt marker where the construct began instead of restarting the command
  # record at the last continuation line.
  #
  # PS2 is touched only under `input-mark', and the continuation mark inside that is
  # `marks'' half.  The nesting is the whole rule: Emacs taking the continuation line is
  # the point of marking it at all, so a shell that keeps its own editor gets no PS2
  # marks of any kind -- and gating both halves on `input-mark' alone would emit a
  # continuation whose prompt start was never announced, which is a claim about a
  # command Emacs has no record of.
  if [[ -n $b ]]; then
    local a2=
    [[ -n $a ]] && a2='\[\033]133;A;k=s\007\]'
    [[ $PS2 == "$__cooked_ps2_marked" ]] || __cooked_ps2_clean=$PS2
    PS2="${a2}${__cooked_ps2_clean}${b}"
    __cooked_ps2_marked=$PS2
  fi

  # PS0 carries the `C' mark, via the hook above.  Bash 5.3 has a function
  # substitution, `${ cmd; }', which runs in the current shell and expands to what the
  # command wrote -- so the hook's output becomes the prompt text and is printed with
  # it.  Older bash has only `$(...)', a subshell, whose output would be captured and
  # then printed all the same -- except that a subshell cannot see a redirected stdout
  # back to the terminal, so it writes to /dev/tty and expands to nothing.  Both spell
  # the same thing; the first forks less.
  if __cooked_want marks || __cooked_want title; then
    local hook
    if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
      hook='${ __cooked_preexec; }'
    else
      hook='$(__cooked_preexec >/dev/tty)'
    fi
    [[ ${PS0-} == "$__cooked_ps0_marked" ]] || __cooked_ps0_clean=${PS0-}
    PS0="${__cooked_ps0_clean}${hook}"
    __cooked_ps0_marked=$PS0
  fi
}

# The directory in the title, when no command is running.  Spelled `\w' and handed to
# bash's own prompt expansion through `${...@P}', rather than abbreviated here with a
# `${PWD/#$HOME/~}': that pattern takes $HOME as a glob, so a home directory with a
# `[' in it abbreviates to something else or to nothing.  `\w' is also exactly what the
# user already sees in their prompt, which is the point of choosing it.  zsh's half
# writes `%~' for the same reason.
__cooked_title() {
  local w='\w'
  builtin printf '\033]2;%s\007' "${w@P}"
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
  builtin printf '\033]51;CH;2;%s;%s\033\\' \
    "$__cooked_complete_nonce" "$__cooked_complete_replies"
}

# The other end of PROMPT_COMMAND, and everything that wants to run *after* the user's
# own hooks rather than before them.  Marking the prompt has to be last, because a theme
# that rebuilds PS1 must be rebuilt over; the title and the announcement come along
# because neither cares and one entry is cheaper than three.
#
# So the two halves sit at opposite ends of PROMPT_COMMAND: `$?' is only true at the
# front and PS1 is only settled at the back, and there is no single position that is
# both.  zsh has the same problem and the same answer, in two precmd hooks; kitty and
# Ghostty use one hook in each shell and take the wrong `$?' for it.
__cooked_prompt_hook() {
  __cooked_want title && __cooked_title
  __cooked_prompt
  __cooked_want announce && __cooked_complete_announce
  return 0
}

# Deferred setup.  Nothing above is registered until the first prompt, which is what
# gives a .bashrc somewhere to stand: it runs before this does, so it can append to
# COOKED_SHELL_INTEGRATION_FEATURES and be heard.  It also puts our hook after every
# theme's.
__cooked_deferred_init() {
  __cooked_features="${COOKED_SHELL_INTEGRATION_FEATURES-$__cooked_features}"

  # PROMPT_COMMAND has been an array since bash 5.1, and ble.sh and a few frameworks
  # use it that way.  Treating it as a string there does not fail loudly: `$PROMPT_COMMAND'
  # reads element 0 only, and assigning a string back writes element 0 only, so the
  # rest of the user's array survives -- and now runs *after* everything we appended.
  # Under the DEBUG trap this file used to carry, that meant the first of those
  # commands was reported as a command the user had typed, and every prompt emitted a
  # spurious `C'.  Branch on the actual type, as kitty and Ghostty both do.
  if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
    local -a kept=()
    local element
    for element in "${PROMPT_COMMAND[@]}"; do
      [[ $element == '__cooked_deferred_init' ]] || kept+=("$element")
    done
    PROMPT_COMMAND=('__cooked_precmd' "${kept[@]}" '__cooked_prompt_hook')
  else
    local user=${PROMPT_COMMAND-}
    user=${user%__cooked_deferred_init}
    user=${user%;}
    PROMPT_COMMAND="__cooked_precmd${user:+;$user};__cooked_prompt_hook"
  fi

  unset -f __cooked_deferred_init

  # We are running as part of the prompt that is already being drawn, so everything
  # registered above belongs to the *next* one.  Run it by hand for this one, or the
  # session opens on the single prompt that has no marks, no directory and -- worse --
  # no announcement, which is what licenses the editable line.  Not __cooked_precmd,
  # though: there is no command behind this prompt to close, and the `$?' it would read
  # here is our own bookkeeping's rather than anything the user ran.
  __cooked_hist=${HISTCMD-}
  __cooked_want cwd && __cooked_report_cwd
  __cooked_prompt_hook
}
# Appended rather than prepended, so that on the very first prompt we run *after*
# whatever the user's rc registered.  A theme that rebuilds PS1 would otherwise do so
# after we had already marked it, and the first prompt -- the one a session opens on --
# would be the single prompt that never handed Emacs the line.
if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
  PROMPT_COMMAND+=('__cooked_deferred_init')
else
  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}__cooked_deferred_init"
fi

[[ -n $__cooked_had_aliases ]] && shopt -s expand_aliases
unset __cooked_had_aliases
