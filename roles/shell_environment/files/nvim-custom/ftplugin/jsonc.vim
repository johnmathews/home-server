setlocal tabstop=2
setlocal softtabstop=2
setlocal expandtab
setlocal shiftwidth=2
setlocal smarttab

" format .JSON files by using the previously installed jq cli tool
com! JQ %!jq
nnoremap <buffer>  <c-f> :call JsonBeautify()<cr>

syntax match Comment +\/\/.\+$+
