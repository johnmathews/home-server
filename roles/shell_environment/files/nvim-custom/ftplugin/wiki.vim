"setlocal smarttab
"setlocal softtabstop=4
"setlocal noautoindent 			" if previous line is indented, don't make new line also indented
""
"filetype plugin indent on
"setlocal tabstop=4
"setlocal shiftwidth=2
"setlocal expandtab
"set linebreak 							" Wrap lines at convenient points, avoid wrapping a line in the middle of a word.
""
"setlocal wrap
"setlocal scrolloff=3							" The number of screen lines to keep above and below the cursor
"syntax enable
""
"setlocal textwidth=79
"setlocal colorcolumn=81
""
""" add text width to autoformat options
""" setlocal formatoptions+=t
""
"setlocal spell
"setlocal spelllang=en
"setlocal spellfile=$HOME/.dotfiles/vim/spell/en.utf-8.add
""
"setlocal filetype=markdown
""
"function! ToggleCalendar()
  "execute ":Calendar"
  "if exists("g:calendar_open")
    "if g:calendar_open == 1
      "execute "q"
      "unlet g:calendar_open
    "else
      "g:calendar_open = 1
    "end
  "else
    "let g:calendar_open = 1
  "end
"endfunction
""
"nnoremap <buffer> <leader>c :call ToggleCalendar() <CR>
""
"nmap <buffer> <Leader>wb <Plug>VimwikiGoBackLink
"nmap <buffer> <Leader>wd <Plug>VimwikiGoBackLink
""
"noremap <buffer> gl8 :VimwikiChangeSymbolTo *<CR>
"noremap <buffer> gL8 :VimwikiChangeSymbolInListTo *<CR>
"noremap <buffer> gl3 :VimwikiChangeSymbolTo #<CR>
"noremap <buffer> gL3 :VimwikiChangeSymbolInListTo #<CR>
""
"nnoremap <buffer> <leader>wh :VimwikiAll2HTML<CR>
"nnoremap <buffer> <leader>whh :VimwikiAll2HTML<CR> <bar> :Vimwiki2HTMLBrowse<CR>
""
""
"""Insert my journal template with the current date
"nnoremap <buffer> <silent><leader>dj :call NewJournal()<CR>
"function! NewJournal()
  """ pu=strftime('%c')
  "".-1read ~/projects/vimwiki/templates/decision\-journal
  "%s/date/\=strftime("%A %-d %B %Y")/
"endfunction
""
"autocmd BufNewFile,BufRead *.wiki setlocal filetype=markdown
