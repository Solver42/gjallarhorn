if exists('g:loaded_gjallarhorn') | finish | endif
let g:loaded_gjallarhorn = 1

" Path to the compiled binary.  Override in your vimrc if needed.
let g:gjallarhorn_bin = get(g:, 'gjallarhorn_bin', expand('~/.local/bin/gjallarhorn'))

" How long (ms) to wait for the daemon socket to appear after job_start.
let g:gjallarhorn_startup_timeout_ms = get(g:, 'gjallarhorn_startup_timeout_ms', 5000)

" Running daemons keyed by project root.  Each entry: { job, socket_ready }.
let s:running_daemons = {}

" ID of the currently open hover popup (v:none when closed).
let s:hover_popup_id = v:none

" Project-root markers, mirroring find_project_root in main.odin.
let s:project_root_markers = ['.git', '.editorconfig', 'gjallar.horn']

" ---------------------------------------------------------------------------
" Internal helpers
" ---------------------------------------------------------------------------

function! s:find_project_root(dir) abort
    let l:current = a:dir
    while 1
        for l:marker in s:project_root_markers
            if filereadable(l:current . '/' . l:marker) ||
             \ isdirectory(l:current . '/' . l:marker)
                return l:current
            endif
        endfor
        let l:parent = fnamemodify(l:current, ':h')
        if l:parent ==# l:current
            return a:dir
        endif
        let l:current = l:parent
    endwhile
endfunction

" Wait until the daemon socket file appears (or the binary exited early).
" Returns 1 if the socket is ready, 0 on timeout.
function! s:wait_for_daemon_socket(project_root) abort
    if !has_key(s:running_daemons, a:project_root) | return 0 | endif
    let l:entry = s:running_daemons[a:project_root]

    " Already confirmed ready in a prior call.
    if get(l:entry, 'socket_ready', 0) | return 1 | endif

    " Derive the socket path the same way the binary does:
    " /tmp/gjallarhorn_<md5hex(project_root)>.sock
    " We poll for the file's existence rather than replicating the MD5 in
    " VimScript — glob is fast and reliable enough for a startup wait.
    let l:socket_glob = '/tmp/gjallarhorn_*.sock'
    let l:deadline_ms = g:gjallarhorn_startup_timeout_ms
    let l:waited_ms   = 0
    let l:step_ms     = 50

    while l:waited_ms < l:deadline_ms
        " Bail out early if the job already died (bad binary path, etc.).
        if job_status(l:entry.job) !=# 'run' | return 0 | endif

        " The daemon prints "index build complete" to stderr before accepting
        " connections, so the socket file appearing is a reliable ready signal.
        if !empty(glob(l:socket_glob, 1, 1)) | break | endif

        execute 'sleep ' . l:step_ms . 'm'
        let l:waited_ms += l:step_ms
    endwhile

    if empty(glob(l:socket_glob, 1, 1)) | return 0 | endif

    let l:entry.socket_ready = 1
    let s:running_daemons[a:project_root] = l:entry
    return 1
endfunction

" ---------------------------------------------------------------------------
" Daemon management
" ---------------------------------------------------------------------------

function! gjallarhorn#ensure_daemon(filepath) abort
    if !executable(g:gjallarhorn_bin)
        echom 'gjallarhorn: binary not found at ' . g:gjallarhorn_bin
        return
    endif

    let l:project_root = s:find_project_root(fnamemodify(a:filepath, ':h'))

    if has_key(s:running_daemons, l:project_root)
        let l:entry = s:running_daemons[l:project_root]
        " Daemon is still running — nothing to do.
        if job_status(l:entry.job) ==# 'run'
            return
        endif
        " Stale entry — remove and restart below.
        call remove(s:running_daemons, l:project_root)
    endif

    " FIX: pass the full filepath so the daemon anchors its project-root search
    " from the correct directory and builds its index before any client arrives.
    let l:job = job_start(
        \ [g:gjallarhorn_bin, '--daemon', a:filepath],
        \ {'stoponexit': 'term'})

    if l:job is v:null
        echom 'gjallarhorn: failed to start daemon for ' . l:project_root
        return
    endif

    let s:running_daemons[l:project_root] = {'job': l:job, 'socket_ready': 0}

    " FIX: wait for the daemon to be ready before returning so that the
    " immediately-following index_file call (in the BufReadPost autocmd) does
    " not race against a daemon that hasn't bound its socket yet.
    if !s:wait_for_daemon_socket(l:project_root)
        echom 'gjallarhorn: daemon did not become ready in time for ' . l:project_root
    endif
endfunction

" ---------------------------------------------------------------------------
" Index
" ---------------------------------------------------------------------------

" Ask the running daemon to re-index the project.
" FIX: run asynchronously with job_start so that saving a file does not block
" Vim while the daemon walks and re-parses the entire project tree.
function! gjallarhorn#index_file(filepath) abort
    if !executable(g:gjallarhorn_bin) | return | endif

    let l:project_root = s:find_project_root(fnamemodify(a:filepath, ':h'))
    if !has_key(s:running_daemons, l:project_root) | return | endif
    if job_status(s:running_daemons[l:project_root].job) !=# 'run' | return | endif

    " Run the --index client invocation in the background; we don't need its
    " output.  Errors are logged to stderr by the binary itself.
    call job_start(
        \ [g:gjallarhorn_bin, '--index', a:filepath],
        \ {'err_io': 'null', 'out_io': 'null'})
endfunction

" ---------------------------------------------------------------------------
" Completion
" ---------------------------------------------------------------------------

function! gjallarhorn#completefunc(findstart, base) abort
    if a:findstart
        " Find the start column of the word under the cursor.
        let l:line = getline('.')
        let l:col  = col('.') - 1
        while l:col > 0 && l:line[l:col - 1] =~# '\w'
            let l:col -= 1
        endwhile
        return l:col
    endif

    " Build the buffer text up to (but not including) the cursor.
    " FIX: the buffer text is sent through the already-open daemon socket via
    " the binary's framed protocol, so it is not subject to shell ARG_MAX.
    " The binary handles arbitrarily large buffers via the 4-byte length frame.
    let l:lines_above = join(getline(1, line('.') - 1), "\n")
    let l:line_prefix = strpart(getline('.'), 0, col('.') - 1)
    let l:buffer_text = (line('.') > 1 ? l:lines_above . "\n" : '') . l:line_prefix

    let l:raw_output = system(
        \ g:gjallarhorn_bin . ' --comp ' .
        \ shellescape(expand('%:p')) . ' ' .
        \ shellescape(l:buffer_text))

    if v:shell_error != 0
        echom 'gjallarhorn: completion failed (exit ' . v:shell_error . ')'
        return []
    endif

    let l:candidates = []
    for l:raw_line in split(trim(l:raw_output), "\n")
        if l:raw_line ==# '' | continue | endif
        let l:parts = split(l:raw_line, "\t")
        let l:word  = l:parts[0]
        let l:menu  = len(l:parts) > 1 ? l:parts[1] : ''
        call add(l:candidates, {'word': l:word, 'menu': l:menu})
    endfor
    return l:candidates
endfunction

" ---------------------------------------------------------------------------
" Hover
" ---------------------------------------------------------------------------

function! gjallarhorn#show_hover() abort
    " Toggle: close if already open.
    if s:hover_popup_id isnot v:none && !empty(popup_getpos(s:hover_popup_id))
        call popup_close(s:hover_popup_id)
        let s:hover_popup_id = v:none
        return
    endif

    let l:symbol   = expand('<cword>')
    let l:response = system(
        \ g:gjallarhorn_bin . ' --hover ' .
        \ shellescape(expand('%:p')) . ' ' .
        \ shellescape(l:symbol))

    if l:response =~# '^\s*$' | return | endif

    let l:popup_lines = split(trim(l:response), '\n')
    if empty(l:popup_lines) | return | endif

    let s:hover_popup_id = popup_atcursor(l:popup_lines, #{
        \ border:      [1, 1, 1, 1],
        \ borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
        \ close:       'click',
        \ moved:       'any',
        \ })
endfunction

" ---------------------------------------------------------------------------
" Autocommands
" ---------------------------------------------------------------------------

augroup gjallarhorn
    autocmd!

    " Opening an Odin file: start the daemon (and wait for it to be ready),
    " register completefunc, then request an index of the file just opened.
    autocmd BufReadPost,BufNewFile *.odin
        \ call gjallarhorn#ensure_daemon(expand('<afile>:p')) |
        \ setlocal completefunc=gjallarhorn#completefunc     |
        \ call gjallarhorn#index_file(expand('<afile>:p'))   |
        \ nnoremap <buffer> <silent> K :call gjallarhorn#show_hover()<CR>

    " Saving: re-index asynchronously so completions stay fresh.
    autocmd BufWritePost *.odin
        \ call gjallarhorn#index_file(expand('<afile>:p'))

augroup END
