if exists('g:loaded_gjallarhorn') | finish | endif
let g:loaded_gjallarhorn = 1

let g:gjallarhorn_bin             = get(g:, 'gjallarhorn_bin',             expand('~/.local/bin/gjallarhorn'))
let g:gjallarhorn_startup_timeout = get(g:, 'gjallarhorn_startup_timeout', 5000)
let g:gjallarhorn_request_timeout = get(g:, 'gjallarhorn_request_timeout', 3000)
" Number of lines before cursor sent for local variable type inference.
" Matches LOCAL_CTX_LINES in the daemon. Raise both together if needed.
let g:gjallarhorn_ctx_lines    = get(g:, 'gjallarhorn_ctx_lines',       150)
let g:gjallarhorn_root_markers = get(g:, 'gjallarhorn_root_markers', ['.git', '.editorconfig', 'gjallar.horn'])

let s:daemons        = {}
let s:hover_popup_id = v:none
let s:buffers        = {}

function! s:find_project_root(dir) abort
    let l:cur = a:dir
    while 1
        for l:m in g:gjallarhorn_root_markers
            if filereadable(l:cur . '/' . l:m) || isdirectory(l:cur . '/' . l:m)
                return l:cur
            endif
        endfor
        let l:parent = fnamemodify(l:cur, ':h')
        if l:parent ==# l:cur | return a:dir | endif
        let l:cur = l:parent
    endwhile
endfunction

function! s:encode_frame(msg) abort
    return printf('%08x', len(a:msg)) . a:msg
endfunction

function! s:channel_read_n(ch, n) abort
    let l:ch_key = string(a:ch)
    if !has_key(s:buffers, l:ch_key)
        let s:buffers[l:ch_key] = ''
    endif

    while len(s:buffers[l:ch_key]) < a:n
        let l:chunk = ch_read(a:ch, {'timeout': g:gjallarhorn_request_timeout})
        if type(l:chunk) != v:t_string || l:chunk ==# ''
            break
        endif
        let s:buffers[l:ch_key] .= l:chunk
    endwhile

    if len(s:buffers[l:ch_key]) < a:n
        return ''
    endif

    let l:result = strpart(s:buffers[l:ch_key], 0, a:n)
    let s:buffers[l:ch_key] = strpart(s:buffers[l:ch_key], a:n)
    return l:result
endfunction

function! s:read_frame(ch) abort
    let l:hdr = s:channel_read_n(a:ch, 8)
    if len(l:hdr) != 8
        return ''
    endif
    let l:n = str2nr(l:hdr, 16)
    if l:n == 0
        return ''
    endif
    return s:channel_read_n(a:ch, l:n)
endfunction

function! s:on_daemon_stderr(root, ch, msg) abort
    if !has_key(s:daemons, a:root) | return | endif
    if a:msg =~# '^socket:'
        let l:path = substitute(matchstr(a:msg, '^socket:\zs.*'), '[\r\n\t ]\+$', '', '')
        let s:daemons[a:root].socket_path = l:path
        let l:ch   = ch_open('unix:' . l:path, {
            \ 'mode': 'raw',
            \ 'timeout': g:gjallarhorn_request_timeout
            \ })
        let s:daemons[a:root].channel = l:ch
    endif
endfunction

function! s:daemon_channel(filepath) abort
    let l:root = s:find_project_root(fnamemodify(a:filepath, ':h'))
    if !has_key(s:daemons, l:root) | return v:null | endif
    let l:entry = s:daemons[l:root]
    if !has_key(l:entry, 'job') || job_status(l:entry.job) !=# 'run' | return v:null | endif

    if !has_key(l:entry, 'channel') || ch_status(l:entry.channel) !=# 'open'
        if has_key(l:entry, 'socket_path')
            let l:ch = ch_open('unix:' . l:entry.socket_path, {
                \ 'mode': 'raw',
                \ 'timeout': g:gjallarhorn_request_timeout
                \ })
            if ch_status(l:ch) ==# 'open'
                let l:entry.channel = l:ch
            endif
        endif
    endif

    if !has_key(l:entry, 'channel') || ch_status(l:entry.channel) !=# 'open' | return v:null | endif
    return l:entry.channel
endfunction

function! s:warn_if_daemon_not_started(root, timer_id) abort
    if has_key(s:daemons, a:root) && !has_key(s:daemons[a:root], 'channel')
        echom 'gjallarhorn: daemon channel did not open'
    endif
endfunction

function! gjallarhorn#ensure_daemon(filepath) abort
    if !executable(g:gjallarhorn_bin)
        echom 'gjallarhorn: binary not found at ' . g:gjallarhorn_bin
        return
    endif

    let l:root = s:find_project_root(fnamemodify(a:filepath, ':h'))

    if has_key(s:daemons, l:root)
        if job_status(s:daemons[l:root].job) ==# 'run'
            return
        endif
        call remove(s:daemons, l:root)
    endif

    let s:daemons[l:root] = {}

    let l:job = job_start(
        \ [g:gjallarhorn_bin, '--daemon', a:filepath] + g:gjallarhorn_root_markers,
        \ {
        \   'err_cb':     function('s:on_daemon_stderr', [l:root]),
        \   'stoponexit': 'term',
        \ })

    if l:job is v:null
        call remove(s:daemons, l:root)
        echom 'gjallarhorn: failed to start daemon'
        return
    endif

    let s:daemons[l:root].job = l:job
    " Daemon builds its index and opens the socket in the background (s:on_daemon_stderr
    " picks it up); don't block the UI waiting for it. Just warn if it never shows up.
    call timer_start(g:gjallarhorn_startup_timeout, function('s:warn_if_daemon_not_started', [l:root]))
endfunction

function! s:request(filepath, frames) abort
    let l:ch = s:daemon_channel(a:filepath)
    if l:ch is v:null | return '' | endif
    for l:frame in a:frames
        call ch_sendraw(l:ch, s:encode_frame(l:frame))
    endfor
    return s:read_frame(l:ch)
endfunction

function! gjallarhorn#index_async(filepath) abort
    let l:ch = s:daemon_channel(a:filepath)
    if l:ch is v:null | return | endif
    call ch_sendraw(l:ch, s:encode_frame('index'))
    call ch_sendraw(l:ch, s:encode_frame(a:filepath))
    call ch_read(l:ch, {'timeout': 0})
endfunction

" Extract the dot-chain and prefix from the current cursor position.
" Returns [prefix, dot_chain] where dot_chain is '' for unqualified completions.
function! s:comp_context() abort
    let l:line   = getline('.')
    let l:col    = col('.') - 1
    let l:prefix = matchstr(l:line[:l:col - 1], '\w*$')
    let l:before = l:line[:l:col - len(l:prefix) - 1]

    " Walk the dot-chain immediately left of the prefix.
    let l:chain = matchstr(l:before, '[a-zA-Z0-9_.]\+\.$')
    " Strip the trailing dot.
    let l:chain = substitute(l:chain, '\.$', '', '')

    return [l:prefix, l:chain]
endfunction

" Return the last N lines above cursor joined by newline — for local var inference.
function! s:local_ctx() abort
    let l:cur  = line('.')
    let l:from = max([1, l:cur - g:gjallarhorn_ctx_lines])
    " Include partial current line up to cursor so ':=' on the same line works.
    let l:lines = getline(l:from, l:cur)
    return join(l:lines, "\n")
endfunction

function! gjallarhorn#completefunc(findstart, base) abort
    if a:findstart
        let l:line = getline('.')
        let l:col  = col('.') - 1
        while l:col > 0 && l:line[l:col - 1] =~# '\w'
            let l:col -= 1
        endwhile
        return l:col
    endif

    let [l:_prefix, l:chain] = s:comp_context()
    let l:ctx                = s:local_ctx()
    let l:raw = s:request(expand('%:p'), ['comp', a:base, l:chain, l:ctx])
    if l:raw ==# '' | return [] | endif

    let l:candidates = []
    for l:line in split(l:raw, "\n")
        if l:line ==# '' | continue | endif
        let l:parts = split(l:line, "\t")
        call add(l:candidates, {'word': l:parts[0], 'menu': get(l:parts, 1, '')})
    endfor
    return l:candidates
endfunction

function! gjallarhorn#toggle_hover() abort
    if s:hover_popup_id isnot v:none
        if exists('*popup_getpos') && !empty(popup_getpos(s:hover_popup_id))
            call popup_close(s:hover_popup_id)
            let s:hover_popup_id = v:none
            return
        endif
    endif

    let l:word = expand('<cword>')
    if empty(l:word) | return | endif
    let l:line_to_cursor = strpart(getline('.'), 0, col('.') - 1)
    if (len(substitute(l:line_to_cursor, '[^\"]', '', 'g')) % 2) == 1 | return | endif

    let l:response = s:request(expand('%:p'), ['hover', l:word, s:local_ctx()])
    if l:response =~# '^\s*$' | return | endif

    let l:lines = split(trim(l:response), '\n')
    if empty(l:lines) | return | endif

    if exists('*popup_atcursor')
        let s:hover_popup_id = popup_atcursor(l:lines, #{
            \ border:      [1, 1, 1, 1],
            \ borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
            \ close:       'click',
            \ moved:       'any',
            \ })
    else
        echo join(l:lines, "\n")
    endif
endfunction

function! gjallarhorn#goto_definition() abort
    let l:word = expand('<cword>')
    if empty(l:word) | return | endif
    let l:resp = s:request(expand('%:p'), ['goto', l:word])
    if l:resp ==# ''
        silent! normal! gd
        return
    endif
    let l:parts = split(l:resp, "\x00")
    if len(l:parts) < 3 | return | endif
    execute 'hide edit' fnameescape(l:parts[0])
    call cursor(l:parts[1], l:parts[2])
endfunction

augroup gjallarhorn
    autocmd!
    autocmd BufReadPost,BufNewFile *.odin
        \ call gjallarhorn#ensure_daemon(expand('<afile>:p'))|
        \ setlocal completefunc=gjallarhorn#completefunc|
        \ call gjallarhorn#index_async(expand('<afile>:p'))|
        \ nnoremap <buffer> <silent> K :call gjallarhorn#toggle_hover()<CR>|
        \ nnoremap <buffer> <silent> gd :call gjallarhorn#goto_definition()<CR>

    autocmd BufWritePost *.odin
        \ call gjallarhorn#index_async(expand('<afile>:p'))

augroup END
