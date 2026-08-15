# cooked's completion capture for bash: answers OSC 51;C requests with what bash's
# own programmable completion would have offered.
#
# Source it from ~/.bashrc, after cooked.bash:
#
#     [[ $TERM_PROGRAM == cooked ]] && {
#         source /path/to/cooked.bash
#         source /path/to/cooked-completion.bash
#     }
#
# Much the easier of the two shells, and the reason bash should not stay the largest
# population without shell completion for long.  zsh has no `compgen': completion only
# runs inside ZLE, so the zsh half has to shadow `compadd' and drive a widget to
# collect what it would have displayed.  bash's model is introspectable by design --
# `complete -p CMD' names the registered function, and it can be invoked directly by
# setting the environment it documents -- so there is nothing here but bookkeeping.
#
# The protocol is the same one zsh speaks, so the Emacs half is unchanged:
#
#   shell  ESC ] 51 ; C H ; 2 ; NONCE ; REPLIES ST     at every prompt
#   Emacs  ESC [ > 99 u NONCE ; SERIAL ; POINT ; LINE LF
#   shell  ESC ] 51 ; C R ; SERIAL ; PREFIX ; SUFFIX ; TRUNCATED ; BASE64 ST

[[ $TERM_PROGRAM == cooked ]] || return
[[ -n "${COOKED_COMPLETION_LOADED-}" ]] && return
COOKED_COMPLETION_LOADED=1
[[ $- == *i* ]] || return

# The reply is framed with base64; without it there is nothing to answer with, and
# saying so is better than announcing a capability we would fail to honour.  The core
# still announces, so the editable line is unaffected.
type -P base64 >/dev/null || return

# How many candidates are worth sending.  An empty line completes to every command on
# PATH, and past a certain point the list is something to filter rather than to read --
# which Emacs is doing anyway, on a prefix the shell has already applied.
__cooked_complete_limit=1000

__cooked_complete_decode() {
  local out= i= c=
  for (( i = 0; i < ${#1}; i++ )); do
    c=${1:i:1}
    if [[ $c == % ]]; then
      printf -v c '\\x%s' "${1:i+1:2}"
      out+=$(printf "$c")
      (( i += 2 ))
    else
      out+=$c
    fi
  done
  printf '%s' "$out"
}

# The word under the cursor, and everything before it, the way bash's own completion
# splits a line.  COMP_WORDBREAKS is deliberately not honoured: it would split `a=b'
# and `host:path' the way readline does, and Emacs is given the *length* of what the
# matches replace, so a split finer than the one the matches are relative to would
# make the two disagree.  Whitespace is what both ends can agree on.
__cooked_complete_split() {
  local line=$1 point=$2
  local head=${line:0:point}
  # `read -a' rather than an unquoted expansion: no globbing, no IFS surprises.
  read -r -a COMP_WORDS <<<"$line"
  local -a head_words
  read -r -a head_words <<<"$head"
  # A line ending in a space starts a fresh, empty word.
  if [[ -z $head || $head == *[[:space:]] ]]; then
    head_words+=("")
    COMP_WORDS=("${head_words[@]}" "${COMP_WORDS[@]:${#head_words[@]}-1}")
  fi
  COMP_CWORD=$(( ${#head_words[@]} - 1 ))
  __cooked_complete_word=${head_words[COMP_CWORD]}
}

# What `complete -p' registered for this command, invoked the way it expects.  Three
# outcomes, in the order bash itself would take them: a registered function, a
# registered set of `compgen' options, or nothing registered at all.
__cooked_complete_run() {
  local cmd=${COMP_WORDS[0]} word=$__cooked_complete_word
  local -a spec
  COMPREPLY=()

  # `complete -p' prints a command that would re-register the spec, quoted by bash's
  # own rules -- so `eval' is how it is meant to be read back, and splitting on
  # whitespace instead would tear `-W 'red green blue'' into four words.  What is
  # evaluated is bash's output about a name we passed in quoted, not anything off the
  # line being completed.
  local -a spec=()
  if eval "spec=( $(complete -p "$cmd" 2>/dev/null) )" 2>/dev/null && (( ${#spec[@]} > 1 )); then
    local i= func=
    for (( i = 1; i < ${#spec[@]} - 1; i++ )); do
      [[ ${spec[i]} == -F ]] && func=${spec[i+1]}
    done
    if [[ -n $func ]] && declare -F "$func" >/dev/null; then
      # The contract these functions are written against: the command, the word being
      # completed, and the word before it, with COMP_* already set.
      "$func" "$cmd" "$word" "${COMP_WORDS[COMP_CWORD-1]:-}" 2>/dev/null
      return
    fi
    # No function, but options: hand them to compgen unchanged, minus the leading
    # `complete', the trailing command name, and the flags that register a spec
    # rather than describe candidates.
    local -a opts=()
    for (( i = 1; i < ${#spec[@]} - 1; i++ )); do
      case ${spec[i]} in
        -F|-C) (( i++ )) ;;
        -p|-r|-D|-E|-I) ;;
        *) opts+=("${spec[i]}") ;;
      esac
    done
    if (( ${#opts[@]} )); then
      mapfile -t COMPREPLY < <(compgen "${opts[@]}" -- "$word" 2>/dev/null)
      return
    fi
  fi

  # Nothing registered.  The first word is a command, everything after it is a file
  # name far more often than not -- the same split the Emacs-side table makes.
  if (( COMP_CWORD == 0 )); then
    mapfile -t COMPREPLY < <(compgen -c -- "$word" 2>/dev/null)
  else
    mapfile -t COMPREPLY < <(compgen -f -- "$word" 2>/dev/null)
  fi
}

__cooked_complete() {
  local request= c=
  # -N 1 reads exactly one character and no delimiter; -s keeps it off the screen,
  # -t so a truncated request ends this rather than leaving readline blocked on a
  # newline that is never coming.
  while read -r -N 1 -s -t 2 c; do
    [[ $c == $'\n' || $c == $'\r' ]] && break
    request+=$c
    (( ${#request} > 65536 )) && return
  done

  local -a fields
  IFS=';' read -r -a fields <<<"$request"
  (( ${#fields[@]} == 4 )) || return
  # The nonce is this prompt's.  A request built against an older one raced the line
  # it was completing and is answering a question that no longer exists.
  [[ -n $__cooked_complete_nonce && ${fields[0]} == "$__cooked_complete_nonce" ]] || return

  local line point serial
  serial=${fields[1]}
  point=${fields[2]}
  line=$(__cooked_complete_decode "${fields[3]}")

  local COMP_LINE=$line COMP_POINT=$point COMP_TYPE=9 COMP_KEY=9
  local -a COMP_WORDS=() COMPREPLY=()
  local COMP_CWORD=0 __cooked_complete_word=
  __cooked_complete_split "$line" "$point"
  __cooked_complete_run

  local truncated=0
  if (( ${#COMPREPLY[@]} > __cooked_complete_limit )); then
    COMPREPLY=("${COMPREPLY[@]:0:__cooked_complete_limit}")
    truncated=1
  fi

  # MATCH, DISPLAY and GROUP, unit-separated, record-separated.  bash has no
  # descriptions and no completion groups -- that is compsys's alone -- so the second
  # field repeats the match and the third is empty.  Sent rather than collapsed so
  # that one Emacs-side parser reads both shells.
  local blob= m=
  for m in "${COMPREPLY[@]}"; do
    blob+=$m$'\x1f'$m$'\x1f'$'\x1e'
  done

  # base64 because a candidate is arbitrary text and a single control byte in one
  # would end the sequence carrying it.
  printf '\e]51;CR;%s;%d;%d;%d;%s\e\\' \
    "$serial" "${#__cooked_complete_word}" 0 "$truncated" \
    "$(printf '%s' "$blob" | base64 | tr -d '\n')"

  # readline drew the prompt and the (empty) line before this ran, and printing over
  # it leaves its idea of the screen stale.  Ask for a redraw so the row Emacs renders
  # and the row readline believes in are the same one.
  READLINE_LINE=${READLINE_LINE-}
}

# A private sequence: no keyboard sends it, and no terminfo entry names it.
bind -x '"\e[>99u": __cooked_complete' 2>/dev/null

# Everything above is in place, so requests can now be answered.  Announced from here
# rather than assumed by the core: the core is what a remote host is told to source,
# and it must not claim a capability that lives in this file.
__cooked_complete_replies=1
