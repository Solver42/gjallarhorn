" plugin/gjallarhorn.vim
" Glue between Vim and the gjallarhorn completion daemon.

if exists('g:loaded_gjallarhorn') | finish | endif
let g:loaded_gjallarhorn = 1

let g:gjallarhorn_bin = get(g:, 'gjallarhorn_bin', expand('~/.local/bin/gjallarhorn'))

let s:daemons = {}
let s:popup_id = v:none

function! gjallarhorn#start_daemon(filepath) abort
    if !executable(g:gjallarhorn_bin)
        echom 'gjallarhorn: binary not found at ' . g:gjallarhorn_bin
        return
    endif

    let l:dir = fnamemodify(a:filepath, ':h')

    if has_key(s:daemons, l:dir)
        let l:entry = s:daemons[l:dir]
        if job_status(l:entry.job) == 'run'
            return
        endif
        call remove(s:daemons, l:dir)
    endif

    let l:job = job_start([g:gjallarhorn_bin, '--daemon', a:filepath], {'stoponexit': 'term'})
    if l:job is v:null
        echom 'gjallarhorn: failed to start daemon for ' . l:dir
        return
    endif

    let s:daemons[l:dir] = {'job': l:job}
endfunction

function! gjallarhorn#index_file(filepath) abort
    if !executable(g:gjallarhorn_bin) | return | endif
    let l:dir = fnamemodify(a:filepath, ':h')
    if !has_key(s:daemons, l:dir) | return | endif

    " Daemon re-scans the entire directory from disk.
    call system(g:gjallarhorn_bin . ' --index ' . shellescape(a:filepath))
    if v:shell_error != 0 | echom 'gjallarhorn: index failed (exit ' . v:shell_error . ')' | endif
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
        let l:line  = getline('.')
        let l:start = col('.') - 1
        while l:start > 0 && l:line[l:start - 1] =~ '\w'
            let l:start -= 1
        endwhile
        return l:start
    endif

    let l:lines_above = join(getline(1, line('.') - 1), "\n")
    let l:prefix      = line('.') > 1 ? "\n" : ""
    let l:cursor_line = strpart(getline('.'), 0, col('.') - 1)
    let l:buffer      = l:lines_above . l:prefix . l:cursor_line

    let l:filepath = expand('%:p')
    let l:raw = system(
        \ g:gjallarhorn_bin . ' --comp ' .
        \ shellescape(l:filepath) . ' ' .
        \ shellescape(l:buffer))

    if v:shell_error != 0 | echom 'gjallarhorn: completion failed (exit ' . v:shell_error . ')' | return [] | endif

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

function! gjallarhorn#show_hello() abort
    if s:popup_id isnot v:none && !empty(popup_getpos(s:popup_id))
        call popup_close(s:popup_id)
        let s:popup_id = v:none
        return
    endif
    let l:resp = system(g:gjallarhorn_bin . ' --hover '
        \ . shellescape(expand('%:p')) . ' '
        \ . shellescape(expand('<cword>')))
    if l:resp !~# '^\s*$'
        let l:lines = split(trim(l:resp), '\n')
        if len(l:lines) > 0
            let s:popup_id = popup_atcursor(l:lines, #{
                \ border: [1, 1, 1, 1],
                \ borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
                \ close: 'click',
                \ moved: 'any',
                \ })
        endif
    endif
endfunction

augroup gjallarhorn
    autocmd!
    " Open: start the daemon, register completefunc, and index immediately.
    autocmd BufReadPost,BufNewFile *.odin
        \ call gjallarhorn#start_daemon(expand('<afile>:p')) |
        \ setlocal completefunc=gjallarhorn#completefunc |
        \ call gjallarhorn#index_file(expand('<afile>:p')) |
        \ nnoremap <buffer> <silent> K :call gjallarhorn#show_hello()<CR>
    " Save: re-index so completions reflect the latest source.
    autocmd BufWritePost *.odin
        \ call gjallarhorn#index_file(expand('<afile>:p'))
augroup END
