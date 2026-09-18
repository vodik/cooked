# cooked's completion capture for fish: answers OSC 51;C requests with what fish's
# own completion would have offered.
#
# Source it from ~/.config/fish/config.fish, after cooked.fish:
#
#     test "$TERM_PROGRAM" = cooked; and begin
#         source /path/to/cooked.fish
#         source /path/to/cooked-completion.fish
#     end
#
# cooked's own children need neither line: it generates a `vendor_conf.d' snippet
# that sources both.  The guard is here for a fish that picks the files up by hand.
#
# The easiest of the three shells, and by some distance.  zsh has no `compgen' and
# completes only inside ZLE, so its half shadows `compadd' and drives a widget; bash
# has to be told which spec to run and how.  fish has `complete --do-complete', which
# takes a line as a string, completes it from any context, and prints each candidate
# with its description -- exactly the two fields the wire carries.  What is left here
# is reading the request and framing the answer.
#
# The protocol is the one zsh and bash speak, so the Emacs half is unchanged:
#
#   shell  ESC ] 51 ; C H ; 2 ; NONCE ; REPLIES ST     at every prompt
#   Emacs  ESC [ > 99 u NONCE ; SERIAL ; POINT ; LINE LF
#   shell  ESC ] 51 ; C R ; SERIAL ; PREFIX ; SUFFIX ; TRUNCATED ; BASE64 ST

if status is-interactive
    and begin
        test "$TERM_PROGRAM" = cooked
        or begin
            test "$TERM_PROGRAM" = tmux; and set -q TMUX; and set -q COOKED_SHELL_INTEGRATION_FEATURES
        end
    end
    and set -q COOKED_INTEGRATION_LOADED
    and not set -q COOKED_COMPLETION_LOADED
    # The core has to be in place: the announcement, the nonce it carries and the OSC
    # framing all live there, and answering a request nobody was invited to send would
    # be answering with the wrong nonce into an unwrapped sequence.
    set -g COOKED_COMPLETION_LOADED 1

    # The reply is framed with base64; without it there is nothing to answer with, and
    # saying so is better than announcing a capability we would fail to honour.  The
    # core still announces, so the editable line is unaffected.
    if command -q base64

        # How many candidates are worth sending.  An empty line completes to every
        # command on PATH, and past a certain point the list is something to filter
        # rather than to read -- which Emacs is doing anyway, on a prefix the shell has
        # already applied.  Set from `cooked-completion-limit' through the environment,
        # and overridable from your config by assigning the variable before sourcing
        # this file, which is why what is already there wins over both.
        if not set -q __cooked_complete_limit
            if string match -qr '^[1-9][0-9]*$' -- "$COOKED_COMPLETE_LIMIT"
                set -g __cooked_complete_limit $COOKED_COMPLETE_LIMIT
            else
                set -g __cooked_complete_limit 1000
            end
        end

        # The request, read a character at a time off the terminal.
        #
        # `--null' is doing the load-bearing work, and not for its delimiter: it is the
        # one documented way to take fish's `read' out of interactive mode.  Without it
        # `read' hands the job to fish's own line editor, which draws a `read>' prompt
        # over the screen Emacs is rendering and interprets the request's bytes as key
        # bindings.  With it, and `--nchars 1', each call is one character and nothing
        # is drawn -- zsh's `read -k 1' and bash's `read -N 1' by another spelling.  The
        # NUL the flag names never arrives, which is fine: `--nchars' ends the read
        # first, every time.
        #
        # Reading from a `bind' function rather than forking a `head' or an `sh' to do
        # it: fish has already drained the terminal into its own input queue by the time
        # the binding runs, so a child reading fd 0 gets nothing and the request is lost.
        #
        # There is no timeout here, and the other two shells have one (`read -t 2').
        # fish's `read' offers none, so a request that arrives truncated -- which means
        # Emacs died mid-write, since it sends the whole thing in one go -- would leave
        # this waiting.  The length cap is the only bound there is.
        function __cooked_complete_request
            set -l request ""
            set -l c
            while read --null --nchars 1 --local c
                test "$c" = \n; and break
                test "$c" = \r; and break
                set request "$request$c"
                if test (string length -- "$request") -gt 65536
                    return 1
                end
            end
            echo -- $request
        end

        # Every byte of the line is percent-encoded, which `string unescape' undoes in
        # one call.  `string collect' keeps a decoded newline from splitting the result
        # into two elements, which is what a command line submitted with `cooked-newline'
        # would otherwise do.
        function __cooked_complete_decode --argument-names field
            string unescape --style=url -- "$field" | string collect --allow-empty
        end

        function __cooked_complete
            set -l request (__cooked_complete_request)
            or return

            set -l fields (string split ';' -- $request)
            test (count $fields) -eq 4; or return
            # The nonce is this prompt's.  A request built against an older one raced the
            # line it was completing and is answering a question that no longer exists.
            test -n "$__cooked_complete_nonce"; or return
            test "$fields[1]" = "$__cooked_complete_nonce"; or return

            set -l serial $fields[2]
            set -l point $fields[3]
            set -l line (__cooked_complete_decode $fields[4])
            # Emacs replaces only up to the cursor, so only what is behind it is
            # completed; the tail goes back on the line untouched.
            set -l head (string sub --length $point -- "$line" | string collect --allow-empty)

            # The span the candidates replace.  fish returns whole tokens -- `complete
            # -C "cat shell-integration/coo"' answers `shell-integration/cooked.fish',
            # directory and all -- so the span is the last unquoted run of non-space,
            # which is also the split bash's half makes and the one Emacs can agree
            # with.  A quoted argument containing a space is where that is too coarse,
            # and it is the same place the bash half is too coarse.
            set -l word (string match -r '[^ \t\n]*$' -- "$head" | string collect --allow-empty)

            set -l candidates (complete --do-complete="$head" 2>/dev/null)
            set -l truncated 0
            if test (count $candidates) -gt $__cooked_complete_limit
                set candidates $candidates[1..$__cooked_complete_limit]
                set truncated 1
            end

            # MATCH, DISPLAY and GROUP, unit-separated, record-separated.  fish has
            # descriptions but no completion groups -- those are compsys's alone -- so
            # the third field is empty, and the second is spelled the way compsys spells
            # a display string, `MATCH -- DESCRIPTION', which is what the Emacs side
            # already knows how to take a description out of.  A candidate with no
            # description repeats the match, as bash's half does.
            set -l blob ""
            for candidate in $candidates
                set -l parts (string split --max 1 \t -- $candidate)
                set -l match $parts[1]
                set -l display $match
                if test (count $parts) -gt 1; and test -n "$parts[2]"
                    set display "$match -- $parts[2]"
                end
                set blob "$blob$match"\x1f"$display"\x1f\x1e
            end

            # base64 because a description is arbitrary text and a single control byte in
            # one would end the sequence carrying it.  Framed by the core, which knows
            # whether tmux is in the way.
            set -l encoded (printf '%s' "$blob" | base64 | tr -d '\n')
            __cooked_osc "51;CR;$serial;"(string length -- "$word")";0;$truncated;$encoded"

            # No repaint, and the asymmetry with zsh is the point.  zsh's capture has to
            # redisplay because compsys draws -- it refreshes the screen on its way to a
            # message or a beep, from a BUFFER holding the line Emacs is editing.
            # Nothing here draws at all: `read --null' is not the line editor, `complete'
            # writes into a command substitution, and the reply is an OSC that occupies
            # no columns.  `commandline -f repaint' would not be free either: it
            # re-executes `fish_prompt', which on a fish that is marking its own prompts
            # puts a second `A' and `B' on the wire for every completion request.
        end

        # A private sequence: no keyboard sends it, and no terminfo entry names it.
        bind \e\[\>99u __cooked_complete
        bind -M insert \e\[\>99u __cooked_complete 2>/dev/null
        bind -M default \e\[\>99u __cooked_complete 2>/dev/null

        # Everything above is in place, so requests can now be answered.  Announced from
        # here rather than assumed by the core: the core is what a remote host is told to
        # source, and it must not claim a capability that lives in this file.
        set -g __cooked_complete_replies 1
    end
end
