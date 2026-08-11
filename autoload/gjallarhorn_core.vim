vim9script

var daemons: dict<any>     = {}
var hover_popup_id: number = -1
var buffers: dict<string>  = {}

def FindProjectRoot(dir: string): string
    var cur = dir
    while true
        for m in g:gjallarhorn_root_markers
            if filereadable(cur .. '/' .. m) || isdirectory(cur .. '/' .. m)
                return cur
            endif
        endfor
        var parent = fnamemodify(cur, ':h')
        if parent ==# cur
            return dir
        endif
        cur = parent
    endwhile
    return dir
enddef

def EncodeFrame(msg: string): string
    return printf('%08x', len(msg)) .. msg
enddef

def ChannelReadN(ch: channel, n: number): string
    var key = string(ch)
    if !buffers->has_key(key)
        buffers[key] = ''
    endif
    while len(buffers[key]) < n
        var chunk = ch_read(ch, {timeout: g:gjallarhorn_request_timeout})
        if type(chunk) != v:t_string || chunk ==# ''
            break
        endif
        buffers[key] ..= chunk
    endwhile
    if len(buffers[key]) < n
        return ''
    endif
    var result = strpart(buffers[key], 0, n)
    buffers[key] = strpart(buffers[key], n)
    return result
enddef

def ReadFrame(ch: channel): string
    var hdr = ChannelReadN(ch, 8)
    if len(hdr) != 8
        return ''
    endif
    var n = str2nr(hdr, 16)
    if n == 0
        return ''
    endif
    return ChannelReadN(ch, n)
enddef

def OnDaemonStderr(root: string, ch: channel, msg: string)
    if !daemons->has_key(root)
        return
    endif
    if msg =~# '^socket:'
        var path = substitute(matchstr(msg, '^socket:\zs.*'), '[\r\n\t ]\+$', '', '')
        daemons[root].socket_path = path
        var open_ch = ch_open('unix:' .. path, {mode: 'raw', timeout: g:gjallarhorn_request_timeout})
        daemons[root].channel = open_ch
    endif
enddef

def DaemonChannel(filepath: string): any
    var root = FindProjectRoot(fnamemodify(filepath, ':h'))
    if !daemons->has_key(root)
        return v:null
    endif

    if daemons[root]->has_key('job') && job_status(daemons[root].job) !=# 'run'
        return v:null
    endif

    if !daemons[root]->has_key('channel') || ch_status(daemons[root].channel) !=# 'open'
        if daemons[root]->has_key('socket_path')
            var open_ch = ch_open('unix:' .. daemons[root].socket_path,
                {mode: 'raw', timeout: g:gjallarhorn_request_timeout})
            if ch_status(open_ch) ==# 'open'
                daemons[root].channel = open_ch
            endif
        endif
    endif

    if !daemons[root]->has_key('channel') || ch_status(daemons[root].channel) !=# 'open'
        return v:null
    endif
    return daemons[root].channel
enddef

def WarnIfDaemonNotStarted(root: string, _timer_id: number)
    if daemons->has_key(root) && !daemons[root]->has_key('channel')
        echom 'gjallarhorn: daemon channel did not open'
    endif
enddef

export def EnsureDaemon(filepath: string)
    if !executable(g:gjallarhorn_bin)
        echom 'gjallarhorn: binary not found at ' .. g:gjallarhorn_bin
        return
    endif

    var root = FindProjectRoot(fnamemodify(filepath, ':h'))

    if daemons->has_key(root)
        if !daemons[root]->has_key('job') || job_status(daemons[root].job) ==# 'run'
            return
        endif
        remove(daemons, root)
    endif

    daemons[root] = {}
    var job = job_start(
        [g:gjallarhorn_bin, '--daemon', filepath] + g:gjallarhorn_root_markers,
        {err_cb: (ch, msg) => OnDaemonStderr(root, ch, msg), stoponexit: 'term'})

    if job_status(job) ==# 'fail'
        remove(daemons, root)
        echom 'gjallarhorn: failed to start daemon'
        return
    endif

    daemons[root].job = job
    timer_start(g:gjallarhorn_startup_timeout, (t) => WarnIfDaemonNotStarted(root, t))
enddef

def Request(filepath: string, frames: list<string>): string
    var ch = DaemonChannel(filepath)
    if ch ==# v:null
        return ''
    endif
    for frame in frames
        ch_sendraw(ch, EncodeFrame(frame))
    endfor
    return ReadFrame(ch)
enddef

def SendAsync(filepath: string, frames: list<string>)
    var ch = DaemonChannel(filepath)
    if ch ==# v:null
        return
    endif
    for frame in frames
        ch_sendraw(ch, EncodeFrame(frame))
    endfor
    ch_read(ch, {timeout: 0})
enddef

def CompContext(): list<string>
    var col_idx = col('.') - 1
    var text    = getline('.')
    var prefix  = matchstr(text[: col_idx - 1], '\w*$')
    var before  = text[: col_idx - len(prefix) - 1]
    var chain   = substitute(matchstr(before, '[a-zA-Z0-9_.]\+\.$'), '\.$', '', '')
    return [prefix, chain]
enddef

def LocalCtx(): list<any>
    var cur        = line('.')
    var start_line = cur
    if getline(cur) !~# '^\S.*::\s*proc\>'
        while start_line > 1
            if getline(start_line - 1) =~# '^\S.*::\s*proc\>'
                start_line -= 1
                break
            endif
            start_line -= 1
        endwhile
    endif
    var depth    = 0
    var end_line = start_line
    var last     = line('$')
    while end_line <= last
        var ch = 0
        for c in split(getline(end_line), '\zs')
            if c ==# '{' | depth += 1 | elseif c ==# '}' | depth -= 1 | endif
        endfor
        if depth <= 0 && end_line > start_line
            break
        endif
        end_line += 1
    endwhile
    return [start_line, getline(start_line, end_line)->join("\n")]
enddef

export def IndexAsync(filepath: string)
    SendAsync(filepath, ['index', filepath])
enddef

export def IndexBufAsync(filepath: string)
    SendAsync(filepath, ['index_buf', filepath, getline(1, '$')->join("\n")])
enddef

export def Completion(findstart: number, base: string): any
    if findstart
        var col_idx = col('.') - 1
        var text    = getline('.')
        while col_idx > 0 && text[col_idx - 1] =~# '\w'
            col_idx -= 1
        endwhile
        return col_idx
    endif
    var [_prefix, chain] = CompContext()
    var [_start,  ctx]   = LocalCtx()
    var frames = &modified
        ? ['comp_buf', expand('%:p'), base, chain, getline(1, '$')->join("\n"), ctx]
        : ['comp',     expand('%:p'), base, chain, ctx]
    var raw = Request(expand('%:p'), frames)
    if raw ==# ''
        return []
    endif
    var candidates: list<dict<string>> = []
    for entry in raw->split("\n")
        if entry ==# ''
            continue
        endif
        var parts = entry->split("\t")
        candidates->add({word: parts[0], menu: get(parts, 1, '')})
    endfor
    return candidates
enddef

export def ToggleHover()
    if hover_popup_id != -1
        if !popup_getpos(hover_popup_id)->empty()
            popup_close(hover_popup_id)
            hover_popup_id = -1
            return
        endif
    endif
    var word = expand('<cword>')
    if word->empty()
        return
    endif
    if (substitute(strpart(getline('.'), 0, col('.') - 1), '[^"]', '', 'g')->len() % 2) == 1
        return
    endif
    var [_start, ctx] = LocalCtx()
    var response = Request(expand('%:p'), ['hover', word, ctx])
    if response =~# '^\s*$'
        return
    endif
    var lines = trim(response)->split('\n')
    if lines->empty()
        return
    endif
    hover_popup_id = popup_atcursor(lines, {
        border:      [1, 1, 1, 1],
        borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
        close:       'click',
        moved:       'any',
    })
enddef

export def GotoDefinition()
    var word = expand('<cword>')
    if word->empty()
        return
    endif
    var fp = expand('%:p')
    Request(fp, ['index_buf', fp, getline(1, '$')->join("\n")])
    var [_start, ctx] = LocalCtx()
    var resp = Request(fp, ['goto', word, ctx])
    if resp ==# ''
        silent! normal! gd
        return
    endif
    var parts = resp->split("\x00")
    if len(parts) < 3
        return
    endif
    normal! m'
    if resolve(parts[0]) !=# resolve(fp)
        execute 'hide edit' fnameescape(parts[0])
    endif
    cursor(str2nr(parts[1]), str2nr(parts[2]))
enddef

export def SetupOdinBuffer()
    EnsureDaemon(expand('<afile>:p'))
    setlocal omnifunc=gjallarhorn_core#Completion
    IndexAsync(expand('<afile>:p'))
    nnoremap <buffer> <silent> K  <cmd>call gjallarhorn_core#ToggleHover()<CR>
    nnoremap <buffer> <silent> gd <cmd>call gjallarhorn_core#GotoDefinition()<CR>
enddef

