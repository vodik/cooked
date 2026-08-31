# cooked's core shell integration for zsh: OSC 133 semantic prompts, OSC 7 directory
# reporting, and the per-prompt completion announcement.
#
# Source it from ~/.zshrc:
#
#     [[ $TERM_PROGRAM == cooked ]] && source /path/to/cooked.zsh
#
# cooked also injects this file into the shells it starts itself, so on a local
# session the line is redundant -- and worth having anyway.  Injection reaches
# exactly the shell cooked spawned: `exec zsh', `sudo -i', `docker exec', a nested
# `zsh -f' and the far end of every `ssh' all land outside it.  The line crosses all
# of them.  Sourcing twice is a no-op, so the two arrangements compose rather than
# conflict.  Getting TERM_PROGRAM to the far end is `SendEnv'/`AcceptEnv', and is
# yours to configure.
#
# What is turned on comes from COOKED_SHELL_INTEGRATION_FEATURES -- see __cooked_want below,
# and `cooked-shell-integration-features' on the Emacs side.
#
# The completion capture is its own file, cooked-completion.zsh, because it is a
# wire protocol rather than a preference; source it after this one.

[[ $TERM_PROGRAM == cooked ]] || return

[[ -n "${COOKED_INTEGRATION_LOADED-}" ]] && return
COOKED_INTEGRATION_LOADED=1
[[ -o interactive ]] || return

autoload -Uz add-zsh-hook

# A writable file descriptor onto the terminal, so that a mark still reaches it from a
# hook whose stdout has been redirected -- which happens whenever a precmd hook is
# invoked from inside a `$(...)' or a plugin that captures output.  Every line of this
# is load-bearing, and the reasoning is kitty's, arrived at over several bug reports:
#
# - `exec {fd}>&1' would do it, but zsh gives out a descriptor without O_CLOEXEC, so
#   it leaks into every child process.  A fixed `exec {3}>&1' does not leak into
#   children but survives an `exec', and takes fd 3 away from the user besides.
# - zsh exposes no dup3, so `sysopen' is the only way to get O_CLOEXEC at all.
# - Both `zmodload' and `sysopen' can write to stderr while failing, even where the
#   tty is writable, so the whole block is redirected -- once, because redirections
#   are not free and this is startup.
# - It is opened *here* rather than in the deferred init because there are plugins
#   that run `exec {fd}< <(cmd)' and then close the descriptor twice with errors
#   suppressed, which would take ours with it if ours were opened later.
#
# Falling back to fd 1 is not a defeat: it is exactly what printing normally does, and
# the redirected-stdout case is rare enough to be worth having rather than requiring.
typeset -gi __cooked_fd
{
  builtin zmodload zsh/system && (( $+builtins[sysopen] )) && {
    { [[ -w     $TTY ]] && builtin sysopen -o cloexec -wu __cooked_fd --     $TTY } ||
    { [[ -w /dev/tty ]] && builtin sysopen -o cloexec -wu __cooked_fd -- /dev/tty }
  }
} 2>/dev/null || (( __cooked_fd = 1 ))

# The feature list, taken verbatim from the environment so that a shell cooked
# injected into and one that sourced this by hand agree about what is on.
#
# Unset means cooked did not start this shell -- an ssh that does not forward the
# variable, a container, a shell started before Emacs was.  The fallback is the same
# default `cooked-shell-integration-features' carries, rather than "everything":
# arriving somewhere unconfigured is not a reason to start writing window titles.
typeset -g __cooked_features="${COOKED_SHELL_INTEGRATION_FEATURES-marks input-mark cwd announce completion title}"

# A feature is on if it is named and not un-named.  The `no-NAME' form exists so
# that a prompt which already does one of these jobs can stand cooked's half down
# without giving up the rest -- a theme that emits its own OSC 133 appends
# ` no-marks' and keeps the editable line, the directory tracking and completion.
# Subtraction wins over naming, so the append is always the last word.
__cooked_want() {
  [[ " $__cooked_features " == *" no-$1 "* ]] && return 1
  [[ " $__cooked_features " == *" $1 "* ]]
}

__cooked_osc() { builtin print -nu $__cooked_fd -- "\e]$1\a" }

#
# Percent-encoding, for OSC 7 and for the command line on the `C' mark.
#
# Both are URIs on the wire and Emacs decodes them as URIs, so a path that is not
# encoded here does not merely look wrong at the far end -- it decodes to a *different*
# path.  `cd /tmp/100%20cake' reported raw arrives in Emacs as `/tmp/100 cake', a
# directory that does not exist, and directory tracking stops without a word.  A fish 4
# doing its own reporting encodes the same way, so there is one encoding on the wire and
# one decoding at the far end.
#
# `LC_ALL=C' so that the loop counts bytes rather than characters and each byte of a
# multi-byte character is encoded on its own, which is what a URI wants.  `emulate -L
# zsh' is what makes `${1[i]}' one-based; under a user's KSH_ARRAYS every path would
# come out shifted by one and nobody would see why.
#
# The answer is left in __cooked_encoded rather than printed, so that callers can have
# it without a `$(...)' -- which is a fork, on a path that runs once per command and
# once per directory change.  kitty and Ghostty both fork here; there is no need to.
typeset -g __cooked_encoded=

__cooked_encode() {
  builtin emulate -L zsh
  local LC_ALL=C
  local out= i c n
  n=${#1}
  for (( i = 1; i <= n; i++ )); do
    c=${1[i]}
    # RFC 3986's unreserved set, plus `/', which is a path separator here rather than
    # data and must survive as one.
    if [[ $c == [-_.~/a-zA-Z0-9] ]]; then
      out+=$c
    else
      builtin printf -v c '%%%02X' "'$c"
      out+=$c
    fi
  done
  typeset -g __cooked_encoded=$out
}

# Reported only when it changed.  A prompt is drawn far more often than a directory is
# entered -- every `reset-prompt', every empty return, every asynchronous segment a
# theme refreshes -- and the encoding above is a loop over the bytes of the path, so
# the test is worth more than it costs.
typeset -g __cooked_last_cwd=

__cooked_report_cwd() {
  [[ $PWD == $__cooked_last_cwd ]] && return 0
  __cooked_last_cwd=$PWD
  __cooked_encode "$PWD"
  __cooked_osc "7;file://${HOST}${__cooked_encoded}"
}

#
# The marks.
#
# `A' where the prompt begins, `B' where the shell starts reading input, `C' where the
# command's output begins, `D' with the exit status.  Between them Emacs knows where
# every command started and ended and how it went, which is what the per-command
# records, `next-error', rerun and the fringe decorations are all built on.
#
# Which of them have been written is tracked, because "close the last command" and
# "there was no last command" are different things and the wrong one is a lie:
#
#   0  nothing has been marked yet -- the first prompt of the session, which has no
#      command behind it to close.
#   1  a `C' is open: a command is running and its `D' is owed, with a status.
#   2  a prompt was marked but no command ran -- the user pressed Return on an empty
#      line -- so what is owed is a bare `D' that closes the prompt and reports no
#      status, because there is no status to report.
#
# cooked's Emacs side already ignores a `D' that closes nothing, so none of this is
# needed to keep it correct.  It is here because a mark that says something untrue is
# a bad thing to put on a wire that other terminals also read, and because "no command
# ran" is a fact Emacs may one day want.
typeset -gi __cooked_state=0

__cooked_precmd() {
  # First line, before `emulate' or anything else can overwrite it.  Not `status':
  # that name is read-only in zsh, where it aliases $?.
  builtin local -i exit_status=$?
  builtin emulate -L zsh -o no_warn_create_global -o no_aliases

  # Plugins refresh the prompt by calling the precmd hooks from inside a ZLE widget --
  # zsh-autosuggestions and powerlevel10k both do it, and so does anything that
  # redraws on `cd'.  The cursor is in the middle of the input line when that happens,
  # so a `D' written here would close a command that is still being typed and land the
  # mark in the middle of the user's text.  Both kitty and Ghostty carry this test
  # with the same reasoning.
  if ! builtin zle; then
    if __cooked_want marks; then
      if (( __cooked_state == 1 )); then
        __cooked_osc "133;D;${exit_status}"
      elif (( __cooked_state == 2 )); then
        __cooked_osc "133;D"
      fi
    fi
    (( __cooked_state = 2 ))
    __cooked_want cwd && __cooked_report_cwd
  fi
  return 0
}

# The command line arrives as $1, unexpanded and exactly as typed, which is the whole
# of why zsh needs none of the `history 1' archaeology bash does for the same mark.
__cooked_preexec() {
  builtin emulate -L zsh -o no_warn_create_global -o no_aliases
  if __cooked_want marks; then
    # `cmdline_url=' rather than kitty's `cmdline=', which is `printf %q' output and so
    # is quoted in a way only that shell can undo -- `ls -la' arrives as `ls\ -la', and
    # an Emacs that guessed at unquoting it would be putting its guess in the command
    # record.  Percent-encoding has one reading.
    if [[ -n $1 ]]; then
      __cooked_encode "$1"
      __cooked_osc "133;C;cmdline_url=${__cooked_encoded}"
    else
      __cooked_osc "133;C"
    fi
    (( __cooked_state = 1 ))
  fi
  return 0
}

# We are sourced after the user's .zshrc, so a theme's precmd is already registered
# and ours would otherwise run last -- by which point $? is that hook's status and
# not the command's, and every exit code we report is wrong.  Stay first.
#
# This is why the marks are split across two precmd hooks rather than gathered into
# one, which is the shape kitty and Ghostty both use: their single hook forces itself
# *last*, so that its edits to PS1 stick, and pays for it by reading a `$?' that the
# hook before it has already overwritten.  The two jobs want opposite ends of the
# list, so they get one hook each.
__cooked_first_precmd() {
  if [[ ${precmd_functions[1]} != __cooked_precmd ]]; then
    precmd_functions=(__cooked_precmd ${precmd_functions:#__cooked_precmd})
  fi
}

#
# The prompt marks, in PS1 and PS2.
#
# `A' opens the prompt and `B' says the shell is now reading input, which is what hands
# the keyboard to Emacs.  `B' is a feature of its own, separately from the other three
# marks, because it is the only one that changes who owns the keyboard: without it you
# keep the extents, the exit codes and `next-error', and the shell keeps its own line
# editor.
#
# Both live in the prompt rather than being printed from a hook, and that is not a
# stylistic choice.  zsh redraws the prompt far more often than it runs precmd -- every
# `zle reset-prompt', which powerlevel10k does for each asynchronous segment it fills
# in, every SIGWINCH, every Ctrl-L -- and a mark printed from precmd is not there on any
# of those.  Printing `A' from precmd while `B' rode in PS1, which is what this file did
# before, meant every one of those redraws sent Emacs a `B' with no `A' in front of it.
#
# It is spelled `A', with no `k=' at all, since absent means `k=i'.  The proposal also
# spells this mark `P', and Ghostty changed its own prompts to that spelling because
# `A' is defined to imply a fresh line, which a terminal honouring it would act on at
# every redraw.  cooked implements no fresh-line behaviour for either spelling, so `P'
# would be the same mark to it and these snippets would be the only thing anywhere
# emitting it; `A' is what fish 4 sends unprompted, so one spelling covers every
# emitter cooked can hear.
#
# Appending to PS1 once at source time is not enough: powerlevel10k, starship and most
# oh-my-zsh themes rebuild PS1 from their own precmd, silently dropping whatever we put
# there.  So the marks are re-applied every prompt, from the clean text.
#
# "The clean text" is the part worth being careful about.  Searching PS1 for our own
# markers and appending if absent -- which is what this file used to do, and what kitty
# still does -- has a false positive and a false negative, both of kitty's own
# documenting: `PS1="%(?.$mark.)"' contains the mark without ever emitting it, and a PS1
# built under `prompt_subst' may emit it without containing it.  Keeping the two
# versions instead is exact.  If PS1 is byte-for-byte what we last wrote, nobody has
# touched it and our copy of the clean text still stands; if it is anything else, a
# theme rebuilt it and *that* is the new clean text.  No pattern matching, no
# accumulation, and correct under both options.
typeset -g __cooked_ps1_clean=
typeset -g __cooked_ps1_marked=
typeset -g __cooked_ps2_clean=
typeset -g __cooked_ps2_marked=

# A prompt ending in an odd number of `%' would swallow the `%{' that follows it: the
# run pairs off into literal percent signs from the left, and the one left over
# combines with our brace instead of opening our escape.  Append one more to make the
# run even, and count the run rather than testing its last two characters -- Ghostty's
# `*[^%]%' test sees `%%' at the end of `%%%' and leaves it alone, which is the case
# that is actually broken.
__cooked_pad_percent() {
  local trailing=${1##*[^%]}
  if (( ${#trailing} % 2 )); then
    typeset -g __cooked_padded="$1%"
  else
    typeset -g __cooked_padded="$1"
  fi
}

__cooked_prompt_precmd() {
  builtin emulate -L zsh -o no_warn_create_global -o no_aliases

  # Keep ourselves last, so that we run after whichever theme rebuilt PS1.
  if [[ ${precmd_functions[-1]} != __cooked_prompt_precmd ]]; then
    precmd_functions=(${precmd_functions:#__cooked_prompt_precmd} __cooked_prompt_precmd)
  fi

  # `%{...%}' is how a prompt says "this occupies no columns", and it is `prompt_percent'
  # that gives `%' that meaning at all.  With the option off there is no way to put an
  # invisible mark in a prompt, so the `A' half is printed instead -- once, from here,
  # losing the redraw stability but keeping the mark.  The `B' half has no fallback: it
  # must sit at the end of the prompt text, and precmd runs before the prompt is drawn.
  if ! [[ -o prompt_percent ]]; then
    __cooked_want marks && ! builtin zle && __cooked_osc "133;A"
    return 0
  fi

  local a= b= a2=
  __cooked_want marks      && a=$'%{\e]133;A\a%}' && a2=$'%{\e]133;A;k=s\a%}'
  __cooked_want input-mark && b=$'%{\e]133;B\a%}'
  [[ -z $a && -z $b ]] && return 0

  [[ $PS1 == $__cooked_ps1_marked ]] || __cooked_ps1_clean=$PS1
  __cooked_pad_percent "$__cooked_ps1_clean"
  PS1="${a}${__cooked_padded}${b}"
  # A multi-line prompt, which is what powerlevel10k and starship both draw by default.
  # zsh redraws the whole thing, but Emacs needs to know that the second line is still
  # prompt rather than a fresh one, or the input region lands on the wrong row after
  # every redraw.  `k=s' says these continue the prompt that began above rather than
  # starting one -- the same thing PS2 says, which is what they are.
  [[ -n $a && $PS1 == *$'\n'* ]] && PS1=${PS1//$'\n'/$'\n'${a2}}
  __cooked_ps1_marked=$PS1

  # PS2, the continuation prompt, and the same reasoning throughout -- without a `B'
  # here every line after the first of `for x in 1 2; do' falls out of Emacs' hands
  # back to ZLE, so you compose the first line in Emacs and the rest in the shell's
  # line editor.  `k=s' is what lets Emacs leave the prompt marker where the construct
  # began; a bare initial mark would restart the command record at the last
  # continuation line.
  #
  # PS2 is touched only under `input-mark', and the continuation mark inside that is
  # `marks'' half.  The nesting is the whole rule: Emacs taking the continuation line is
  # the point of marking it at all, so a shell that keeps its own line editor gets no
  # PS2 marks of any kind -- and gating both halves on `input-mark' alone would emit a
  # continuation whose prompt start was never announced, which is a claim about a
  # command Emacs has no record of.  The bash half is spelled the same way.
  if [[ -n $b ]]; then
    [[ $PS2 == $__cooked_ps2_marked ]] || __cooked_ps2_clean=$PS2
    __cooked_pad_percent "$__cooked_ps2_clean"
    PS2="${a2}${__cooked_padded}${b}"
    __cooked_ps2_marked=$PS2
  fi
  return 0
}

#
# The completion announcement.
#
# `OSC 51;CH;<version>;<nonce>;<replies>', emitted afresh at every ZLE line.  It is
# in the core rather than with the completion capture because Emacs reads it as two
# different things and only one of them is about completion.
#
# To the completion layer it is the token a request must carry.  To everything else
# it is a *license to own the input line*: the shell asserting, for this line, that a
# line editor is bound and reading.  That is the one signal that is both byte-
# transparent -- so it survives an ssh, where termios does not -- and self-
# corroborating, because the shell states its own condition rather than being
# inferred about.  Without it a remote prompt keeps its own line, which is correct
# but strictly less than this shell can offer.
#
# The last field says whether a request can be *answered*: that needs the capture in
# cooked-completion.zsh, which sets it, and a reply needs base64 to frame it.
# Announcing anyway is the point -- staying quiet for want of an encoder, or because
# the optional half is not loaded, would cost the editable line for an unrelated
# reason and cost it silently.
typeset -g __cooked_complete_nonce=
typeset -g __cooked_complete_replies=0

__cooked_complete_announce() {
  __cooked_complete_nonce=${RANDOM}${RANDOM}
  # An OSC occupies no columns and moves no cursor, so ZLE's idea of the screen
  # survives being written to from inside a widget.
  builtin print -nu $__cooked_fd -- \
    "\e]51;CH;2;${__cooked_complete_nonce};${__cooked_complete_replies}\e\\"
}

# Announced from `zle-line-init' rather than a precmd hook, and the difference is not
# cosmetic: precmd runs before ZLE has taken the terminal, so a request answering it
# arrives while the line discipline is still echoing, and every byte of it is printed
# on the screen before the widget ever sees it.  By line-init the keyboard is ZLE's,
# which is exactly the condition the announcement is claiming.  It also means each
# fresh line rotates the nonce, so a request built against the previous one is refused.
#
# Whoever already owns `zle-line-init' -- zsh-autosuggestions, a vi-mode plugin, a
# theme -- keeps working: their widget is aliased aside and called from ours.
__cooked_install_announce() {
  [[ -n ${widgets[zle-line-init]-} ]] && zle -A zle-line-init __cooked_saved_line_init
  __cooked_line_init() {
    __cooked_complete_announce
    (( $+widgets[__cooked_saved_line_init] )) && zle __cooked_saved_line_init
  }
  zle -N zle-line-init __cooked_line_init
}

#
# The title.
#
# cooked shows this in the mode line, and `cooked-buffer-name-follows-title' can put it
# in the buffer name.  A prompt that already writes OSC 2 makes this a redundant write
# rather than a conflict -- last one wins, and ours is registered later, so it does.
# Append ` no-title' to keep your own wording.
#
__cooked_title_preexec() {
  # `local_options' keeps both of these to this function.  EXTENDED_GLOB is what makes
  # `^(...)' a negation rather than a literal caret, and without it the subscript
  # matches nothing and every title comes out empty -- silently, which is how this
  # survived being copied out of an rc that happened to set the option globally.
  # NO_NOMATCH stops a command whose first word looks like a failed glob from erroring
  # here rather than running.
  setopt local_options extended_glob no_nomatch
  builtin print -Pnu $__cooked_fd -- "\e]2;${1[(wr)^(*=*|sudo|command|builtin|-*)]:gs/%/%%}\a"
}
__cooked_title_precmd() { builtin print -Pnu $__cooked_fd -- '\e]2;%~\a' }

#
# Talking back to Emacs, over OSC 51;E.
#
# Off unless asked for, and turning it on here is only half: the Emacs side does
# nothing with any of this until `cooked-osc-eval' is loaded, so these are inert
# rather than dangerous in a session that never asked for them.  That split is the
# point -- the terminal is a channel anything can write to, so what a verb may do is
# settled where the user can see it and not by whatever printed the bytes.
#
# The verbs below are a closed set on the Emacs side: each is cooked's own code and
# checks its own argument.  That is why they are safe to define for you, and why
# there is no shipped helper for anything outside the set.
# Installed from the deferred init, which runs *after* your .zshrc -- so these win over
# a definition of the same name made there.  That is deliberate, and it is the same
# bargain kitty makes when it aliases `sudo': asking for a feature is asking for its
# names, and the way to decline is the feature list rather than a race to define first.
# Leave `eval-helpers' out, or append ` no-eval-helpers', and none of this exists.
#
# What we still never do is `unfunction' a name we did not write.  Filling a gap when
# asked and taking away something you wrote are different acts, and only the second
# cannot be undone by turning the feature back off.
__cooked_install_helpers() {
  __cooked_verb() { builtin printf '\e]51;E1;%s;%s\e\\' "$1" "${2-}" }

  find_file()              { __cooked_verb F "${${1:-.}:a}" }
  find_file_other_window() { __cooked_verb O "${${1:-.}:a}" }
  dired()                  { __cooked_verb D "${${1:-.}:a}" }

  # OSC 52 -- reaches Emacs' kill ring even from the far end of an ssh.
  osc_copy() {
    local text="${1:-$(</dev/stdin)}"
    (( $+commands[base64] )) || return
    builtin printf '\e]52;c;%s\a' "$(builtin print -rn -- "$text" | base64 | tr -d '\n')"
  }

  # The escape hatch, and the one place quoting lives, because it is the only form
  # that takes more than one argument.  `!' names a command Emacs looks up in
  # `cooked-eval-commands', which is empty until you fill it -- so this is refused by
  # default and stays refused for every name you did not choose.
  #
  # There is deliberately no shipped alias built on this.  Which commands are worth
  # reaching, and under what name, is yours:
  #
  #     alias magit='cooked_send magit-status'
  #
  # and the matching (add-to-list 'cooked-eval-commands '("magit-status" . magit-status)).
  # An alias that shadows a real command reads very differently as something you wrote
  # than as something cooked put in your shell.
  cooked_send() {
    builtin printf '\e]51;E1;!;'
    local arg
    for arg in "$@"; do
      arg="${arg//\\/\\\\}"
      arg="${arg//\"/\\\"}"
      builtin printf '"%s" ' "$arg"
    done
    builtin printf '\e\\'
  }
}

#
# Deferred setup.
#
# Everything above only defines things; nothing is registered until the first prompt.
# That is what gives a .zshrc somewhere to stand: it is sourced before this runs, so
# it can append to COOKED_SHELL_INTEGRATION_FEATURES and be heard.  It also means we register
# after every theme and plugin has, which is the position both hook orderings above
# are trying to reach anyway.
__cooked_deferred_init() {
  precmd_functions=(${precmd_functions:#__cooked_deferred_init})
  unfunction __cooked_deferred_init

  __cooked_features="${COOKED_SHELL_INTEGRATION_FEATURES-$__cooked_features}"

  # One hook covers both, and each line inside it is gated on its own feature:
  # directory reporting is not part of the marks and outlives them being turned off.
  if __cooked_want marks || __cooked_want cwd; then
    add-zsh-hook precmd __cooked_precmd
    __cooked_first_precmd
  fi
  __cooked_want marks && add-zsh-hook preexec __cooked_preexec
  if __cooked_want marks || __cooked_want input-mark; then
    add-zsh-hook precmd __cooked_prompt_precmd
    __cooked_prompt_precmd
  fi
  __cooked_want announce && __cooked_install_announce
  # Defined only when asked for, never removed when not: these are ordinary names a
  # user may already have bound to something of their own, and a snippet that
  # `unfunction'd them would delete a definition it did not write.
  __cooked_want eval-helpers && __cooked_install_helpers
  if __cooked_want title; then
    add-zsh-hook preexec __cooked_title_preexec
    add-zsh-hook precmd __cooked_title_precmd
  fi

  # The first prompt is already being drawn, so the hooks registered above have missed
  # it -- but PS1 has not been expanded yet, so the marks that ride in it are already
  # taken care of and only the directory needs saying by hand.  No `D' here: nothing
  # has run to close, which is what state 0 records.
  __cooked_want cwd && __cooked_report_cwd
  (( __cooked_state = 2 ))
  return 0
}
add-zsh-hook precmd __cooked_deferred_init
