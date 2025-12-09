setlocal smarttab
setlocal expandtab
setlocal list lcs=tab:\|\ 
setlocal tabstop=2
setlocal softtabstop=2
setlocal shiftwidth=2

setlocal textwidth=180
setlocal colorcolumn=181

vnoremap <buffer> <localleader>p y<esc>oprint("*** <esc>gpa = ", <esc>gpa)<ESC>
