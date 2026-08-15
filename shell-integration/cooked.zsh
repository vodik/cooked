# OSC 133 semantic prompts for zsh, plus OSC 7 directory reporting.
# Source from ~/.zshrc, or let cooked inject it with a generated ZDOTDIR.

[[ -n "${COOKED_INTEGRATION_LOADED-}" ]] && return
COOKED_INTEGRATION_LOADED=1
[[ -o interactive ]] || return

autoload -Uz add-zsh-hook

__cooked_precmd() {
  # Not `status`: that name is read-only in zsh (it aliases $?).
  local exit_status=$?
  print -n "\e]133;D;${exit_status}\a"
  print -n "\e]7;file://${HOST}${PWD}\a"
  print -n "\e]133;A\a"
}

__cooked_preexec() { print -n "\e]133;C\a" }

add-zsh-hook precmd __cooked_precmd
add-zsh-hook preexec __cooked_preexec

# We are sourced after the user's .zshrc, so a theme's precmd is already registered
# and ours would otherwise run last -- by which point $? is that hook's status and
# not the command's, and every exit code we report is wrong.  Stay first.
__cooked_first_precmd() {
  if [[ ${precmd_functions[1]} != __cooked_precmd ]]; then
    precmd_functions=(__cooked_precmd ${precmd_functions:#__cooked_precmd})
  fi
}
__cooked_first_precmd

# The B mark says "the shell is now reading input", which is what hands the keyboard
# to Emacs -- so losing it costs the whole feature.  Appending to PS1 once at source
# time is not enough: powerlevel10k, starship and most oh-my-zsh themes rebuild PS1
# from their own precmd, silently dropping it.  Re-append every prompt instead, from
# a hook that keeps itself last so it runs after whoever rebuilt it.
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
  [[ $PS1 == *$'\e]133;B\a'* ]] || PS1="${PS1}"$'%{\e]133;B\a%}'
}
add-zsh-hook precmd __cooked_prompt_precmd
__cooked_prompt_precmd

#
# Talking back to Emacs.
#
# osc_emacs_eval names a command from `cooked-eval-commands'.  Anything absent
# from that list is refused, so defining a helper here is not enough on its own —
# which is the point: the terminal is a channel anyone's output can write to.

osc_title()    { print -Pn "\e]2;${1}\a" }
osc_annotate() { printf '\e]51;A%s\e\\' "${1:-}" }

osc_emacs_eval() {
    printf '\e]51;E'
    local arg
    for arg in "$@"; do
        arg="${arg//\\/\\\\}"
        arg="${arg//\"/\\\"}"
        printf '"%s" ' "$arg"
    done
    printf '\e\\'
}

# OSC 52 — reaches Emacs' kill ring even from the far end of an ssh session.
osc_copy() {
    local text="${1:-$(</dev/stdin)}"
    (( $+commands[base64] )) || return
    printf '\e]52;c;%s\a' "$(print -rn -- "$text" | base64 | tr -d '\n')"
}

find_file()              { osc_emacs_eval find-file "${${1:-.}:a}" }
find_file_other_window() { osc_emacs_eval find-file-other-window "${${1:-.}:a}" }
magit()                  { osc_emacs_eval magit-status "${${1:-.}:a}" }

# Note the absence of a `clear' override.  Shadowing a standard command to reach
# into the editor is surprising and breaks scripts that call it; the scrollback
# belongs to Emacs, so clear it from Emacs with \\[cooked-clear-scrollback].
# `clear-scrollback' stays in `cooked-eval-commands' for anyone who disagrees.

# Title tracking: show the command that is running, minus the words that hide it.
__cooked_title_preexec() {
    osc_title "${1[(wr)^(*=*|sudo|command|builtin|-*)]:gs/%/%%}"
}
__cooked_title_precmd()  { osc_title "%~" }
__cooked_annotate()      { osc_annotate "$(print -Pn '%n@%m:%~')" }

add-zsh-hook preexec __cooked_title_preexec
add-zsh-hook precmd __cooked_title_precmd
add-zsh-hook precmd __cooked_annotate
