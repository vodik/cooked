# cooked's completion capture for zsh: answers OSC 51;C requests with what compsys
# would have offered.
#
# Source it from ~/.zshrc, after cooked.zsh:
#
#     [[ $TERM_PROGRAM == cooked ]] && {
#         source /path/to/cooked.zsh
#         source /path/to/cooked-completion.zsh
#     }
#
# Separate from the core because of what it costs, not because of what it is worth:
# everything below is a `compadd' shadow that every completion in this shell then
# runs through, a widget, and three bindkeys, and zsh has no tidy way to take any of
# them back.  That is a thing to opt into.  Nothing here is a preference, though --
# it is the shell half of a wire protocol whose Emacs half is
# `(require \'cooked-shell-completion)' -- which is why it ships as a file to source
# rather than as an example to paste.
#
# The line being edited lives in Emacs, so ZLE's buffer is empty and forwarding TAB
# would complete against nothing.  Emacs instead sends the line here on a key nobody
# types, and the widget below runs the real completion system over it with `compadd'
# shadowed to capture what it would have offered, then answers with OSC 51;C.
#
# Emacs only sends a request after seeing an announcement carrying `replies=1', which
# is what the last line of this file turns on.  That matters: without a widget bound
# to the trigger, the sequence and the line after it would be read as literal input.
# A shell that announces `replies=0' -- the core alone, a nested `zsh -f', bash, the
# far end of an ssh -- keeps its editable line and is simply never asked.

[[ -n "${COOKED_COMPLETION_LOADED-}" ]] && return
COOKED_COMPLETION_LOADED=1
[[ $TERM_PROGRAM == cooked ]] || return
[[ -o interactive ]] || return

# The reply is framed with base64; without it there is nothing to answer with, and
# saying so is better than announcing a capability we would fail to honour.  The core
# still announces, so the editable line is unaffected.
(( $+commands[base64] )) || return

typeset -g __cooked_capturing=
typeset -g __cooked_prefix=0 __cooked_suffix=0 __cooked_truncated=0
# The text of the span the matches are relative to, kept rather than only its length
# because re-basing a match onto it needs the characters; see `compadd' below.
# `__cooked_span' says a span has been captured at all, which its length cannot.
typeset -g __cooked_prefix_text= __cooked_span=
typeset -ga __cooked_matches __cooked_display __cooked_groups

# How many candidates are worth sending.  An empty line completes to every command on
# PATH, and past a certain point the list is something to filter rather than to read --
# which Emacs is doing anyway, on a prefix the shell has already applied.
#
# Whether the cap was reached goes back with the answer, and Emacs spends it: a
# complete list is filtered there as the word grows, and only a truncated one is worth
# another round trip.
typeset -g __cooked_complete_limit=1000

# `compadd' is shadowed for the duration of one capture only; every other caller in
# the session — a user's own completion function, a plugin — reaches the builtin
# unchanged.  The real add happens first and its status is what we return, because
# completers branch on whether matches landed: swallowing them would change which
# completer runs and quietly turn off _approximate, _correct and friends.
compadd() {
  [[ -n $__cooked_capturing ]] || { builtin compadd "$@"; return }

  builtin compadd "$@"
  local status_=$?

  if (( ${#__cooked_matches} >= __cooked_complete_limit )); then
    __cooked_truncated=1
    return $status_
  fi

  # Pull out the display strings and the group name.  Options cluster, and an option
  # that takes an argument has to come last in its cluster — `-ld array' is how
  # `_describe' passes descriptions — so it is the final letter that decides whether
  # the next word is a value or the next option.  Skipping by name matters: a value
  # that happens to look like an option would otherwise be read as one.
  local -a display=()
  local group= arg= dspec= probe= apre= hpre=
  local -i i=1
  while (( i <= $# )); do
    arg=${@[i]}
    case $arg in
      --) break ;;
      -*)
        case ${arg[-1]} in
          d) dspec=${@[i+1]}; (( i++ )) ;;
          # A match is assembled from more than its body: -P contributes a visible
          # prefix and -p a hidden one, which is how `_path_files' offers `cooked.zsh'
          # for a line reading `shell-integration/coo' -- the directory is on the match
          # without being in it.  Both are part of what lands on the line.
          P) apre=${@[i+1]}; (( i++ )) ;;
          p) hpre=${@[i+1]}; (( i++ )) ;;
          # -X is the human-readable explanation ("branch", "remote name"); -J and -V
          # are the internal group names.  Prefer the former, fall back to the latter.
          X) group=${@[i+1]}; (( i++ )) ;;
          J|V) [[ -n $group ]] || group=${@[i+1]}; (( i++ )) ;;
          [FSsiIWxrRDOAEM]) (( i++ )) ;;
          o) [[ ${@[i+1]} == -* ]] || (( i++ )) ;;
        esac
        # -O, -A and -D all mean the caller is asking what *would* match rather than
        # offering it -- `_git' probes that way before deciding what to add.  Capturing
        # a probe is how the same candidates arrive twice.
        [[ ${arg#-} == *[ODA]* ]] && probe=1
        ;;
      *) break ;;
    esac
    (( i++ ))
  done

  [[ -n $probe ]] && return $status_

  if [[ -n $dspec ]]; then
    # -d takes either an array's name or a literal parenthesised list.
    if [[ $dspec == \(*\) ]]; then
      display=( ${(Q)${(z)dspec[2,-2]}} )
    else
      display=( "${(@P)dspec}" )
    fi
  fi

  # -O collects the matches that survive matching against what is already typed, and
  # -D prunes a parallel array in step with them, which is the only way to keep each
  # description next to the candidate it belongs to.
  local -a caught=() kept=("${display[@]}")
  builtin compadd -O caught -D kept "$@"

  (( ${#caught} )) || return $status_

  # The span the candidates replace, which is not the whitespace-delimited word Emacs
  # would guess.  PREFIX only: IPREFIX is the part compsys has already decided stays
  # on the line -- the directory components `_files' walked past, the `--opt=' that
  # `_arguments' stripped -- and the candidates it hands back are relative to what is
  # left.  Replacing IPREFIX too would swallow the directory and offer `cooked.zsh'
  # for `shell-integration/coo'.
  #
  # Read from the first call that actually produced a match, not merely the first
  # call: a completer that offered nothing has no bounds worth having.  An explicit
  # flag rather than `(( ! __cooked_prefix ))', which does not say that: zero is a
  # legitimate PREFIX (`ls <TAB>' completes an empty word), so that test reads as
  # "keep overwriting until one of them is non-empty" and lets a later, unrelated
  # completer's span win.
  if [[ -z $__cooked_span ]]; then
    __cooked_span=1
    __cooked_prefix_text=$PREFIX
    # SUFFIX is recorded here and nowhere else.  Emacs replaces only up to the
    # cursor and ignores it entirely, so there is nothing for a per-call value to be
    # right *about*; it stays in the protocol as the first matched call's answer.
    __cooked_suffix=${#SUFFIX}
  fi

  # One reply carries one span, and the calls that fill it need not agree on it:
  # compsys moves text from PREFIX to IPREFIX as it descends -- `compset -P', the
  # `--opt=' `_arguments' strips, the directory components `_path_files' walks --
  # so a later completer in the same completion legitimately answers relative to
  # less of the word.  IPREFIX+PREFIX is what stays constant across those calls, so
  # a shorter PREFIX is a *suffix* of the widest one and the difference is a literal
  # head that can be glued back onto the match.  Which is what happens: every match
  # is re-based onto the widest span seen, and if this call is the one that widens
  # it, the matches already collected are re-based forward instead.  The alternative
  # -- send the span per record and let Emacs sort it out -- buys nothing here,
  # since `completion-in-region' gets exactly one span to replace and something has
  # to pick it.
  local head=
  if (( ${#PREFIX} < ${#__cooked_prefix_text} )); then
    head=${__cooked_prefix_text[1,${#__cooked_prefix_text} - ${#PREFIX}]}
  elif (( ${#PREFIX} > ${#__cooked_prefix_text} )); then
    local grew=${PREFIX[1,${#PREFIX} - ${#__cooked_prefix_text}]}
    __cooked_matches=( "${(@)__cooked_matches/#/$grew}" )
    __cooked_prefix_text=$PREFIX
  fi

  local -i n=1
  for arg in "${caught[@]}"; do
    __cooked_matches+=( "$head$apre$hpre$arg" )
    __cooked_display+=( "${kept[n]-}" )
    __cooked_groups+=( "$group" )
    (( n++ ))
    if (( ${#__cooked_matches} >= __cooked_complete_limit )); then
      __cooked_truncated=1
      break
    fi
  done

  return $status_
}

# A completion widget: created with `zle -C' so that calling it sets up the completion
# special variables and lets `_main_complete' run exactly as TAB would.
__cooked_complete_capture() {
  __cooked_matches=() __cooked_display=() __cooked_groups=()
  __cooked_prefix=0 __cooked_suffix=0 __cooked_truncated=0
  __cooked_prefix_text= __cooked_span=
  __cooked_capturing=1
  # Descriptions are formatted to fit the screen, and truncated to it: at 80 columns
  # `--dired' loses the second half of its sentence.  Nothing is being listed here, so
  # widen the imaginary screen and let Emacs decide how much of it to show.
  local COLUMNS=300
  # A completer that prints — and some do, when the command they ask goes wrong —
  # would otherwise write over the screen Emacs is drawing.
  { _main_complete } >/dev/null 2>&1
  __cooked_capturing=
  # Nothing is inserted and nothing is listed: this run exists only for its matches.
  # After `_main_complete', not before -- it writes both keys itself on the way out,
  # and a `menu select' style left standing here starts an interactive menu the
  # moment the widget returns, which eats the next request and answers nothing.
  compstate[insert]=''
  compstate[list]=''
  # Derived rather than assigned alongside the text, so the two cannot disagree.
  __cooked_prefix=${#__cooked_prefix_text}
}
zle -C __cooked_complete_capture .complete-word __cooked_complete_capture

# Every byte is percent-encoded, including the ones that would survive as themselves.
# Selective encoding would leave a hex digit able to follow an escape and be swallowed
# by it: `%41BC' is \x41BC, not \x41 then BC.
__cooked_complete_decode() {
  printf -v REPLY '%b' "${1//\%/\\x}"
}

__cooked_complete() {
  local request= c=
  # -s or the request is echoed onto the screen a character at a time; -t so a request
  # that arrives truncated ends the widget rather than leaving ZLE blocked on a
  # newline that is never coming.
  while read -k 1 -s -t 2 c; do
    [[ $c == $'\n' || $c == $'\r' ]] && break
    request+=$c
    (( ${#request} > 65536 )) && return
  done

  # Quoted, or an empty line to complete -- the request's last field -- is dropped by
  # the split and the request looks malformed.
  local -a fields=( "${(@s.;.)request}" )
  (( ${#fields} == 4 )) || return
  # The nonce is this prompt's.  A request built against an older one raced the line
  # it was completing and is answering a question that no longer exists.
  [[ -n $__cooked_complete_nonce && $fields[1] == $__cooked_complete_nonce ]] || return

  local REPLY=
  __cooked_complete_decode $fields[4]

  # ZLE redraws from BUFFER when the widget returns, so both are put back exactly as
  # they were: the line is identical, the redraw is a no-op, and nothing flickers.
  local save_buffer=$BUFFER
  local -i save_cursor=$CURSOR
  BUFFER=$REPLY
  CURSOR=$fields[3]
  zle __cooked_complete_capture
  BUFFER=$save_buffer
  CURSOR=$save_cursor
  # The capture can put the line on the screen despite listing nothing.  compsys
  # refreshes the display itself on the way to a message or a beep -- `git commit
  # -am <TAB>' with no matches is the everyday case -- and that refresh draws
  # BUFFER, which for the duration of the capture is the line Emacs is holding.
  # Here the shell's own line is empty, so what is drawn is a second copy of the
  # command, sitting exactly where the completion would have gone.
  #
  # Restoring BUFFER does not take it back: the refresh at the end of the widget
  # compares against what ZLE last recorded, which the capture's own refresh
  # already updated, so it finds nothing to erase and leaves the copy on screen.
  # `redisplay' rebuilds the line unconditionally, which is what erases it.  Run
  # for every request rather than only the ones that dirtied the screen: there is
  # no flag saying which those were, and a redraw of an undisturbed prompt costs
  # a repaint of one row that Emacs renders identically.
  #
  # `zle -R' after it for the ordering, not for the redraw: ZLE holds its output
  # until the widget returns, so on its own the repair would arrive *after* the
  # reply below -- and Emacs, unblocked by the reply, can redisplay in between and
  # show the copy for as long as a drain interval.  `-R' flushes it now, which
  # puts the repair ahead of the reply in the byte stream and leaves no drain that
  # can see one without the other.
  zle redisplay
  zle -R

  local blob= i=
  for (( i = 1; i <= ${#__cooked_matches}; i++ )); do
    blob+="${__cooked_matches[i]}"$'\x1f'"${__cooked_display[i]}"$'\x1f'"${__cooked_groups[i]}"$'\x1e'
  done
  # base64 because a description is arbitrary text — compsys puts colour in some of
  # them — and a single control byte would end the sequence carrying it.
  printf '\e]51;CR;%s;%d;%d;%d;%s\e\\' \
    $fields[2] $__cooked_prefix $__cooked_suffix $__cooked_truncated \
    "$(print -rn -- $blob | base64 | tr -d '\n')"
}
zle -N __cooked_complete

# A private sequence: no keyboard sends it, and no terminfo entry names it.
bindkey -M emacs $'\e[>99u' __cooked_complete
bindkey -M viins $'\e[>99u' __cooked_complete
bindkey -M vicmd $'\e[>99u' __cooked_complete

# Everything above is in place, so requests can now be answered.  Announced from here
# rather than assumed by the core: the core is what a remote host is told to source,
# and it must not claim a capability that lives in this file.
typeset -g __cooked_complete_replies=1
