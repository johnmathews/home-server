" ################################################
" this file is loaded when an ansible yaml file is opened, even though this 
" file is _NOT_ opened when :e ~/.vim/ftplugin/<C-R>=&filetype<CR>.vim<CR> is called
" #################################################

set ts=2
set sts=2
set sw=2
set expandtab

let g:indentLine_char_list = ['|', '¦', '┆', '┊', '⦙']
let g:indentLine_setColors = 0

let g:indentLine_color_term = '#55FF33'
let g:indentLine_bgcolor_term ='#000000' 
let g:indentLine_bgcolor_gui = '#000000'

set foldlevelstart=20

let g:ale_echo_msg_format = '[%linter%] %s [%severity%]'
let g:ale_sign_error = '✘'
let g:ale_sign_warning = '⚠'
let g:ale_lint_on_text_changed = 'never'

let b:ale_linters = ['spectral', 'swaglint', 'yamllint', 'ansible_lint']
let b:ale_fixers = ['remove_trailing_lines', 'trim_whitespace', 'yamlfix']
let b:ale_warn_about_trailing_whitespace = 1

function CustomYaml()
    hi clear yamlBool
    hi yamlBool guifg=red ctermfg=red

    hi clear yamlInteger
    hi yamlInteger guifg=green ctermfg=green
endfunction

call CustomYaml()
