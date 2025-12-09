" the jinja plugin that loads the vim syntax highlighting loads ftpluin/jinja.vim, but :set filetype? returns jinja.html

" word wrap without line breaks
" https://vim.fandom.com/wiki/Word_wrap_without_line_breaks
set nolist  " list disables linebreak
set nowrap " wrap visually (don't change text in the buffer
set linebreak " only wrap at a char in the `breakat` list (not mid-word)
set textwidth=0 " don't insert linebreaks in newly entered text

setlocal autoindent
setlocal cindent
setlocal tabstop=2
setlocal shiftwidth=2
setlocal softtabstop=2
setlocal expandtab

setlocal colorcolumn=0
highlight ColorColumn ctermbg=red ctermfg=red guifg=red guibg=blue

" jump to matching tag when cursor is within angle brackets
runtime macros/matchit.vim
