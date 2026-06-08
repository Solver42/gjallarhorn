" plugin/gjallarhorn.vim
" Glue between Vim and the gjallarhorn completion daemon.

if exists('g:loaded_gjallarhorn') | finish | endif
let g:loaded_gjallarhorn = 1

" ---------------------------------------------------------------------------
" Configuration
" ---------------------------------------------------------------------------

let g:gjallarhorn_bin = get(g:, 'gjallarhorn_bin', expand('~/.local/bin/gjallarhorn'))

" ---------------------------------------------------------------------------
" Internal state
" ---------------------------------------------------------------------------

let s:daemon_started = {}

" ---------------------------------------------------------------------------
" Daemon management
" ---------------------------------------------------------------------------

function! gjallarhorn#start_daemon(filepath) abort
    if !executable(g:gjallarhorn_bin)
        echom 'gjallarhorn: binary not found at ' . g:gjallarhorn_bin
        return
    endif

    if has_key(s:daemon_started, a:filepath)
        return
    endif

    let l:output = system(g:gjallarhorn_bin . ' --start ' . shellescape(a:filepath))
    let s:daemon_started[a:filepath] = 1
    echom 'gjallarhorn: daemon started for ' . a:filepath . ' (socket: ' . trim(l:output) . ')'
endfunction

" ---------------------------------------------------------------------------
" Index — send the full file source to the daemon on save
" ---------------------------------------------------------------------------

function! gjallarhorn#index_file(filepath) abort
    if !executable(g:gjallarhorn_bin) | return | endif
    if !has_key(s:daemon_started, a:filepath) | return | endif

    " Daemon reads the file from disk — no need to pipe source through the shell.
    call system(g:gjallarhorn_bin . ' --index ' . shellescape(a:filepath))
endfunction

" ---------------------------------------------------------------------------
" Completion — hooked into Vim's completefunc mechanism
"
" Vim calls completefunc twice:
"   Pass 1: findstart=1  → return the column where the current word starts
"   Pass 2: findstart=0  → return the list of completion candidates
"
" The daemon returns one candidate per line (empty string = no completions).
" ---------------------------------------------------------------------------

function! gjallarhorn#completefunc(findstart, base) abort
    if a:findstart
        " Find the start of the word before the cursor.
        let l:line  = getline('.')
        let l:start = col('.') - 1
        while l:start > 0 && l:line[l:start - 1] =~ '\w'
            let l:start -= 1
        endwhile
        return l:start
    endif

    " Build buffer text up to the cursor and ask the daemon.
    let l:lines_above = join(getline(1, line('.') - 1), "\n")
    let l:prefix      = line('.') > 1 ? "\n" : ""
    let l:cursor_line = strpart(getline('.'), 0, col('.') - 1)
    let l:buffer      = l:lines_above . l:prefix . l:cursor_line

    let l:filepath = expand('%:p')
    let l:raw = system(
        \ g:gjallarhorn_bin . ' --comp ' .
        \ shellescape(l:filepath) . ' ' .
        \ shellescape(l:buffer))

    " Each line is "word\ttype". Build dicts so Vim shows the type as a menu hint.
    let l:candidates = []
    for l:line in split(trim(l:raw), "\n")
        if l:line == '' | continue | endif
        let l:parts = split(l:line, "\t")
        let l:word  = l:parts[0]
        let l:menu  = len(l:parts) > 1 ? l:parts[1] : ''
        call add(l:candidates, {'word': l:word, 'menu': l:menu})
    endfor
    return l:candidates
endfunction

" ---------------------------------------------------------------------------
" Autocommands
" ---------------------------------------------------------------------------

augroup gjallarhorn
    autocmd!
    " Open: start the daemon, register completefunc, and index immediately.
    autocmd BufReadPost,BufNewFile *.odin
        \ call gjallarhorn#start_daemon(expand('<afile>:p')) |
        \ setlocal completefunc=gjallarhorn#completefunc |
        \ call gjallarhorn#index_file(expand('<afile>:p'))
    " Save: re-index so completions reflect the latest source.
    autocmd BufWritePost *.odin
        \ call gjallarhorn#index_file(expand('<afile>:p'))
augroup END

" ---------------------------------------------------------------------------
" Key mapping — Ctrl+X Ctrl+U triggers completefunc in insert mode
" ---------------------------------------------------------------------------

inoremap <silent> <C-x><C-u> <C-x><C-u>
