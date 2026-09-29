vim9script

var g_daemon_handle_by_project_root: dict<any>    = {}
var hover_popup_id:                  number       = -1
var g_channel_read_buffers_by_channel_key: dict<string> = {}
var g_top_level_proc_ranges_by_buffer: dict<any> = {}

def FindProjectRoot(dir: string): string
    var current_dir = dir
    while true
        for marker in g:gjallarhorn_root_markers
            if filereadable(current_dir .. '/' .. marker) || isdirectory(current_dir .. '/' .. marker)
                return current_dir
            endif
        endfor
        var parent_dir = fnamemodify(current_dir, ':h')
        if parent_dir ==# current_dir
            return dir
        endif
        current_dir = parent_dir
    endwhile
    return dir
enddef

def EncodeLengthPrefixedFrame(message: string): string
    return printf('%08x', len(message)) .. message
enddef

def ReadExactlyNBytes(channel: channel, byte_count: number): string
    var channel_key = string(channel)
    if !g_channel_read_buffers_by_channel_key->has_key(channel_key)
        g_channel_read_buffers_by_channel_key[channel_key] = ''
    endif
    while len(g_channel_read_buffers_by_channel_key[channel_key]) < byte_count
        var chunk = ch_read(channel, {timeout: g:gjallarhorn_request_timeout})
        if type(chunk) != v:t_string || chunk ==# ''
            break
        endif
        g_channel_read_buffers_by_channel_key[channel_key] ..= chunk
    endwhile
    if len(g_channel_read_buffers_by_channel_key[channel_key]) < byte_count
        return ''
    endif
    var result = strpart(g_channel_read_buffers_by_channel_key[channel_key], 0, byte_count)
    g_channel_read_buffers_by_channel_key[channel_key] = strpart(g_channel_read_buffers_by_channel_key[channel_key], byte_count)
    return result
enddef

def ReadLengthPrefixedFrame(channel: channel): string
    var length_header = ReadExactlyNBytes(channel, 8)
    if len(length_header) != 8
        return ''
    endif
    var frame_length = str2nr(length_header, 16)
    if frame_length == 0
        return ''
    endif
    return ReadExactlyNBytes(channel, frame_length)
enddef

def OnDaemonStderrLine(project_root: string, channel: channel, message: string)
    if !g_daemon_handle_by_project_root->has_key(project_root)
        return
    endif
    if message =~# '^socket:'
        var socket_path = substitute(matchstr(message, '^socket:\zs.*'), '[\r\n\t ]\+$', '', '')
        g_daemon_handle_by_project_root[project_root].socket_path = socket_path
        var initial_channel = ch_open('unix:' .. socket_path, {mode: 'raw', timeout: g:gjallarhorn_request_timeout})
        g_daemon_handle_by_project_root[project_root].channel = initial_channel
    endif
enddef

def WarnIfDaemonChannelNotOpen(project_root: string, _timer_id: number)
    if g_daemon_handle_by_project_root->has_key(project_root) && !g_daemon_handle_by_project_root[project_root]->has_key('channel')
        echom 'gjallarhorn: daemon channel did not open'
    endif
enddef

def ChannelForProjectRoot(project_root: string): any
    if !g_daemon_handle_by_project_root->has_key(project_root)
        return v:null
    endif
    if g_daemon_handle_by_project_root[project_root]->has_key('job') && job_status(g_daemon_handle_by_project_root[project_root].job) !=# 'run'
        return v:null
    endif
    if !g_daemon_handle_by_project_root[project_root]->has_key('channel') || ch_status(g_daemon_handle_by_project_root[project_root].channel) !=# 'open'
        if g_daemon_handle_by_project_root[project_root]->has_key('socket_path')
            var reconnected_channel = ch_open('unix:' .. g_daemon_handle_by_project_root[project_root].socket_path,
                {mode: 'raw', timeout: g:gjallarhorn_request_timeout})
            if ch_status(reconnected_channel) ==# 'open'
                g_daemon_handle_by_project_root[project_root].channel = reconnected_channel
            endif
        endif
    endif
    if !g_daemon_handle_by_project_root[project_root]->has_key('channel') || ch_status(g_daemon_handle_by_project_root[project_root].channel) !=# 'open'
        return v:null
    endif
    return g_daemon_handle_by_project_root[project_root].channel
enddef

def SendRequestForProjectRoot(project_root: string, frames: list<string>, wait_for_response: bool = true): string
    var daemon_channel = ChannelForProjectRoot(project_root)
    if daemon_channel ==# v:null
        return ''
    endif
    for frame in frames
        ch_sendraw(daemon_channel, EncodeLengthPrefixedFrame(frame))
    endfor
    if !wait_for_response
        ch_read(daemon_channel, {timeout: 0})
        return ''
    endif
    return ReadLengthPrefixedFrame(daemon_channel)
enddef

def SendRequest(file_path: string, frames: list<string>, wait_for_response: bool = true): string
    return SendRequestForProjectRoot(FindProjectRoot(fnamemodify(file_path, ':h')), frames, wait_for_response)
enddef

export def EnsureDaemon(file_path: string)
    if !executable(g:gjallarhorn_bin)
        echom 'gjallarhorn: binary not found at ' .. g:gjallarhorn_bin
        return
    endif

    var project_root = FindProjectRoot(fnamemodify(file_path, ':h'))

    if g_daemon_handle_by_project_root->has_key(project_root)
        if !g_daemon_handle_by_project_root[project_root]->has_key('job') || job_status(g_daemon_handle_by_project_root[project_root].job) ==# 'run'
            return
        endif
        remove(g_daemon_handle_by_project_root, project_root)
    endif

    for existing_root in g_daemon_handle_by_project_root->keys()
        if !g_daemon_handle_by_project_root[existing_root]->has_key('job') || job_status(g_daemon_handle_by_project_root[existing_root].job) !=# 'run'
            continue
        endif
        var indexes_directory_response = SendRequestForProjectRoot(existing_root, ['indexes_directory', file_path])
        if indexes_directory_response !=# ''
            g_daemon_handle_by_project_root[project_root] = g_daemon_handle_by_project_root[existing_root]
            return
        endif
    endfor

    g_daemon_handle_by_project_root[project_root] = {}
    var daemon_job = job_start(
        [g:gjallarhorn_bin, '--daemon', file_path] + g:gjallarhorn_root_markers,
        {err_cb: (ch, msg) => OnDaemonStderrLine(project_root, ch, msg), stoponexit: 'term'})

    if job_status(daemon_job) ==# 'fail'
        remove(g_daemon_handle_by_project_root, project_root)
        echom 'gjallarhorn: failed to start daemon'
        return
    endif

    g_daemon_handle_by_project_root[project_root].job = daemon_job
    timer_start(g:gjallarhorn_startup_timeout, (timer_id) => WarnIfDaemonChannelNotOpen(project_root, timer_id))
enddef

def SkipBackwardOverBracketGroup(line_text: string, end_index: number): number
    if end_index <= 0
        return end_index
    endif
    var close_character = line_text[end_index - 1]
    if close_character !=# ')' && close_character !=# ']'
        return end_index
    endif
    var open_character = close_character ==# ')' ? '(' : '['
    var depth  = 1
    var cursor = end_index - 1
    while cursor > 0
        cursor -= 1
        if line_text[cursor] ==# close_character
            depth += 1
        elseif line_text[cursor] ==# open_character
            depth -= 1
            if depth == 0
                return cursor
            endif
        endif
    endwhile
    return end_index
enddef

def SkipBackwardOverChainSegment(line_text: string, end_index: number): number
    var cursor = SkipBackwardOverBracketGroup(line_text, end_index)
    while cursor > 0 && line_text[cursor - 1] =~# '\w'
        cursor -= 1
    endwhile
    return cursor
enddef

def ExtractDotChainBeforeIndex(line_text: string, start_index: number): string
    if start_index <= 0 || line_text[start_index - 1] !=# '.'
        return ''
    endif
    var last_dot_index = start_index - 1
    var column_index   = SkipBackwardOverChainSegment(line_text, last_dot_index)
    if column_index == last_dot_index
        return ''
    endif
    while column_index > 0 && line_text[column_index - 1] ==# '.'
        var next_dot_index = column_index - 1
        var segment_start  = SkipBackwardOverChainSegment(line_text, next_dot_index)
        if segment_start == next_dot_index
            break
        endif
        column_index = segment_start
    endwhile
    return line_text[column_index : last_dot_index - 1]
enddef

def CompletionContext(): list<string>
    var column_index   = col('.') - 1
    var line_text      = getline('.')
    var typed_prefix   = matchstr(line_text[: column_index - 1], '\w*$')
    var text_before    = line_text[: column_index - len(typed_prefix) - 1]
    var dot_chain      = ExtractDotChainBeforeIndex(line_text, len(text_before))
    return [typed_prefix, dot_chain]
enddef

def StartOfCurrentWordColumn(): number
    var column_index = col('.') - 1
    var line_text    = getline('.')
    while column_index > 0 && line_text[column_index - 1] =~# '\w'
        column_index -= 1
    endwhile
    return column_index
enddef

def DotChainBeforeCursorWord(): string
    return ExtractDotChainBeforeIndex(getline('.'), StartOfCurrentWordColumn())
enddef

def RebuildTopLevelProcRangesIfStale()
    var buffer_number = bufnr('%')
    var cached = get(g_top_level_proc_ranges_by_buffer, buffer_number, {})
    if get(cached, 'changedtick', -1) == b:changedtick
        return
    endif

    var ranges: list<list<number>> = []
    var brace_depth              = 0
    var pending_start_line       = 0
    var last_line                = line('$')
    var scan_line                = 1
    while scan_line <= last_line
        var line_text = getline(scan_line)
        if brace_depth == 0 && pending_start_line == 0 && line_text =~# '::\s*proc\>'
            pending_start_line = scan_line
        endif
        for character in split(line_text, '\zs')
            if character ==# '{'
                brace_depth += 1
            elseif character ==# '}'
                brace_depth -= 1
                if brace_depth == 0 && pending_start_line != 0
                    ranges->add([pending_start_line, scan_line])
                    pending_start_line = 0
                endif
            endif
        endfor
        scan_line += 1
    endwhile

    g_top_level_proc_ranges_by_buffer[buffer_number] = {changedtick: b:changedtick, ranges: ranges}
enddef

def FindEnclosingProcedureStartAndSource(): list<any>
    RebuildTopLevelProcRangesIfStale()
    var current_line = line('.')
    var ranges       = g_top_level_proc_ranges_by_buffer[bufnr('%')].ranges

    var proc_start = current_line
    var proc_end   = current_line
    for range_pair in ranges
        if current_line >= range_pair[0] && current_line <= range_pair[1]
            proc_start = range_pair[0]
            proc_end   = range_pair[1]
            break
        endif
        if current_line < range_pair[0]
            break
        endif
    endfor

    if current_line > proc_end
        return [proc_start, '', 0]
    endif
    return [proc_start, getline(proc_start, proc_end)->join("\n"), current_line - proc_start]
enddef

export def IndexFileOnDisk(file_path: string)
    SendRequest(file_path, ['index', file_path], false)
enddef

export def IndexUnsavedBuffer(file_path: string)
    SendRequest(file_path, ['index_unsaved', file_path, getline(1, '$')->join("\n")], false)
enddef

export def Completion(findstart: number, base: string): any
    if findstart
        return StartOfCurrentWordColumn()
    endif
    var [_prefix, dot_chain] = CompletionContext()
    var [_proc_start, enclosing_procedure_source, cursor_line_offset] = FindEnclosingProcedureStartAndSource()
    var frames = &modified
        ? ['complete_unsaved', expand('%:p'), base, dot_chain, enclosing_procedure_source, string(cursor_line_offset), getline(1, '$')->join("\n")]
        : ['complete',         expand('%:p'), base, dot_chain, enclosing_procedure_source, string(cursor_line_offset)]
    var raw_response = SendRequest(expand('%:p'), frames)
    if raw_response ==# ''
        return []
    endif
    var candidates: list<dict<string>> = []
    for entry in raw_response->split("\n")
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
    var symbol = expand('<cword>')
    if symbol->empty()
        return
    endif
    if (substitute(strpart(getline('.'), 0, col('.') - 1), '[^"]', '', 'g')->len() % 2) == 1
        return
    endif
    var dot_chain = DotChainBeforeCursorWord()
    var [_start, enclosing_procedure_source, cursor_line_offset] = FindEnclosingProcedureStartAndSource()
    var response = SendRequest(expand('%:p'), ['hover', symbol, dot_chain, enclosing_procedure_source, string(cursor_line_offset)])
    if response =~# '^\s*$'
        return
    endif
    var hover_lines = trim(response)->split('\n')
    if hover_lines->empty()
        return
    endif
    hover_popup_id = popup_atcursor(hover_lines, {
        border:      [1, 1, 1, 1],
        borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
        close:       'click',
        moved:       'any',
    })
enddef

export def GotoDefinition()
    var symbol = expand('<cword>')
    if symbol->empty()
        return
    endif
    var current_file_path = expand('%:p')
    SendRequest(current_file_path, ['index_unsaved', current_file_path, getline(1, '$')->join("\n")])
    var dot_chain = DotChainBeforeCursorWord()
    var [proc_start, enclosing_procedure_source, cursor_line_offset] = FindEnclosingProcedureStartAndSource()
    var goto_response = SendRequest(current_file_path, ['goto', symbol, dot_chain, enclosing_procedure_source, current_file_path, string(cursor_line_offset), string(proc_start)])
    if goto_response ==# ''
        silent! normal! gd
        return
    endif
    var parts = goto_response->split("\x00")
    if len(parts) < 3
        return
    endif
    normal! m'
    if resolve(parts[0]) !=# resolve(current_file_path)
        execute 'hide edit' fnameescape(parts[0])
    endif
    cursor(str2nr(parts[1]), str2nr(parts[2]))
enddef

export def SetupOdinBuffer()
    EnsureDaemon(expand('<afile>:p'))
    setlocal omnifunc=heimdall#Completion
    IndexFileOnDisk(expand('<afile>:p'))
    nnoremap <buffer> <silent> K  <cmd>call heimdall#ToggleHover()<CR>
    nnoremap <buffer> <silent> gd <cmd>call heimdall#GotoDefinition()<CR>
enddef
