setlocal autoindent " Copy indent from current line when starting a new line (typing <CR> in Insert mode or when using the "o" or "O" command)
setlocal cindent " Get the amount of indent for line {lnum} according the C indenting rules, as with 'cindent'. The indent is counted in spaces, the value of 'tabstop' is relevant.
setlocal tabstop=2 " number of spaces that a tab is equal to
setlocal softtabstop=2 " number of spaces that a tab is equal to while performing editing operations "
setlocal shiftwidth=2
setlocal expandtab " In Insert mode: Use the appropriate number of spaces to insert a <Tab>.  Spaces are used in indents with the '>' and '<' commands and when 'autoindent' is on.
setlocal smarttab " When on, a <Tab> in front of a line inserts blanks according to 'shiftwidth'.

setlocal textwidth=79
setlocal autoindent
setlocal fileformat=unix
setlocal nowrap

" ==== console.log() something =====
vnoremap <buffer> <localleader>p y<esc>oconsole.log('--- debug <esc>gpa: ', <esc>gpa);<ESC>
nnoremap <buffer> <Localleader>p <esc>oconsole.log(`--- debug <esc>gpa: ${<esc>gpa}`);<ESC>
