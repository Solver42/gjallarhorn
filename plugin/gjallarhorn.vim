vim9script

if exists('g:loaded_gjallarhorn')
    finish
endif
g:loaded_gjallarhorn = 1

set hidden

g:gjallarhorn_bin             = get(g:, 'gjallarhorn_bin', expand('~/.local/bin/gjallarhorn'))
g:gjallarhorn_startup_timeout = get(g:, 'gjallarhorn_startup_timeout', 5000)
g:gjallarhorn_request_timeout = get(g:, 'gjallarhorn_request_timeout', 3000)
g:gjallarhorn_root_markers    = get(g:, 'gjallarhorn_root_markers', ['.git', '.editorconfig', 'gjallar.horn'])

augroup Gjallarhorn
    autocmd!
    autocmd BufReadPost,BufNewFile,BufWritePost *.odin heimdall#SetupOdinBuffer()
    autocmd BufWritePost                        *.odin heimdall#IndexAsync(expand('<afile>:p'))
    autocmd CursorHold,CursorHoldI              *.odin heimdall#IndexBufAsync(expand('%:p'))
augroup END
