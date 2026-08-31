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

#
# The marks.
#
# `A' where the prompt begins, `C' where its command's output begins, `D' with the
# exit status.  Between them Emacs knows where every command started and ended and
# how it went, which is what the per-command records, `next-error', rerun and the
# fringe decorations are all built on.
#
__cooked_precmd() {
  # Not `status`: that name is read-only in zsh (it aliases $?).
  local exit_status=$?
  __cooked_want marks && print -n "\e]133;D;${exit_status}\a"
  __cooked_want cwd   && print -n "\e]7;file://${HOST}${PWD}\a"
  __cooked_want marks && print -n "\e]133;A\a"
  return 0
}

__cooked_preexec() { __cooked_want marks && print -n "\e]133;C\a"; return 0 }

# We are sourced after the user's .zshrc, so a theme's precmd is already registered
# and ours would otherwise run last -- by which point $? is that hook's status and
# not the command's, and every exit code we report is wrong.  Stay first.
__cooked_first_precmd() {
  if [[ ${precmd_functions[1]} != __cooked_precmd ]]; then
    precmd_functions=(__cooked_precmd ${precmd_functions:#__cooked_precmd})
  fi
}

# The `B' mark says "the shell is now reading input", which is what hands the
# keyboard to Emacs -- so losing it costs the whole feature.  It is a feature of its
# own, separately from the other three marks, because it is the only one that
# changes who owns the keyboard: without it you keep the extents, the exit codes and
# `next-error', and the shell keeps its own line editor.
#
# Appending to PS1 once at source time is not enough: powerlevel10k, starship and
# most oh-my-zsh themes rebuild PS1 from their own precmd, silently dropping it.
# Re-append every prompt instead, from a hook that keeps itself last so it runs after
# whoever rebuilt it.
#
# It has to be in PS1 rather than printed from precmd: precmd runs *before* the
# prompt is drawn, so a printed mark would land ahead of the prompt text and Emacs
# would take the prompt itself for input.
__cooked_prompt_precmd() {
  if [[ ${precmd_functions[-1]} != __cooked_prompt_precmd ]]; then
    precmd_functions=(${precmd_functions:#__cooked_prompt_precmd} __cooked_prompt_precmd)
  fi
  # Test for the marker itself, not a flag: a theme that rebuilt PS1 needs a fresh
  # append, and one that left it alone must not accumulate copies.
  # %{...%} tells ZLE the marker occupies no columns.
  #
  # A PS1 ending in a bare `%' would combine with our `%{' into a prompt escape and
  # eat the mark, so a prompt that ends that way gets a `%%' first.
  if [[ $PS1 != *$'\e]133;B\a'* ]]; then
    [[ $PS1 == *'%' && $PS1 != *'%%' ]] && PS1="${PS1}%"
    PS1="${PS1}"$'%{\e]133;B\a%}'
  fi
  # PS2, the continuation prompt, and the same reasoning throughout -- without a `B'
  # here every line after the first of `for x in 1 2; do' falls out of Emacs' hands
  # back to ZLE, so you compose the first line in Emacs and the rest in the shell's
  # line editor.
  #
  # `A;k=s' rather than a bare `A': `k=s' is what says this prompt *continues* the
  # previous one, and Emacs uses it to leave the prompt marker where the construct
  # began.  A bare `A' would restart the command record at the last continuation
  # line.  Both halves go in together and are tested for as one, because the `A'
  # without the `B' would be a mark with nothing to buy.
  #
  # Prepended rather than printed from precmd, which is where PS2 differs from PS1:
  # there is no hook that runs before a continuation prompt is drawn, so the mark
  # has to travel inside the prompt itself.  The trailing-`%' guard is the PS1 one
  # for the same reason.
  if [[ $PS2 != *$'\e]133;B\a'* ]]; then
    [[ $PS2 == *'%' && $PS2 != *'%%' ]] && PS2="${PS2}%"
    PS2="${PS2}"$'%{\e]133;B\a%}'
    __cooked_want marks && PS2=$'%{\e]133;A;k=s\a%}'"${PS2}"
  fi
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
  printf '\e]51;CH;2;%s;%s\e\\' $__cooked_complete_nonce $__cooked_complete_replies
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
  print -Pn "\e]2;${1[(wr)^(*=*|sudo|command|builtin|-*)]:gs/%/%%}\a"
}
__cooked_title_precmd() { print -Pn '\e]2;%~\a' }

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
  __cooked_verb() { printf '\e]51;E1;%s;%s\e\\' "$1" "${2-}" }

  find_file()              { __cooked_verb F "${${1:-.}:a}" }
  find_file_other_window() { __cooked_verb O "${${1:-.}:a}" }
  dired()                  { __cooked_verb D "${${1:-.}:a}" }

  # OSC 52 -- reaches Emacs' kill ring even from the far end of an ssh.
  osc_copy() {
    local text="${1:-$(</dev/stdin)}"
    (( $+commands[base64] )) || return
    printf '\e]52;c;%s\a' "$(print -rn -- "$text" | base64 | tr -d '\n')"
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
    printf '\e]51;E1;!;'
    local arg
    for arg in "$@"; do
      arg="${arg//\\/\\\\}"
      arg="${arg//\"/\\\"}"
      printf '"%s" ' "$arg"
    done
    printf '\e\\'
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
  if __cooked_want input-mark; then
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

  # The first prompt is already being drawn, so the hooks registered above have
  # missed it.  Mark it by hand rather than let the session open unmarked.
  __cooked_want cwd   && print -n "\e]7;file://${HOST}${PWD}\a"
  __cooked_want marks && print -n "\e]133;A\a"
  return 0
}
add-zsh-hook precmd __cooked_deferred_init
