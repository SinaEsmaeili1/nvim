nnoremap <silent> <buffer> <space>r :call <SID>toggle_run_java()<CR>

" The terminal buffer of the last run (one run at a time, shared by all Java buffers)
let s:run_buf = get(s:, 'run_buf', -1)

" <space>r runs the current file; while a run is going, <space>r stops it instead
function! s:toggle_run_java() abort
  if s:running_job()
    call s:stop_run()
  else
    call s:run_java()
  endif
endfunction

" The job id of the run if it is still going, else 0
function! s:running_job() abort
  if !bufexists(s:run_buf)
    return 0
  endif
  let job = getbufvar(s:run_buf, 'terminal_job_id', 0)
  return job > 0 && jobwait([job], 0)[0] == -1 ? job : 0
endfunction

" Stop the run; its output stays on screen
function! s:stop_run() abort
  let job = s:running_job()
  if job
    call jobstop(job)
  endif
endfunction

" Run the current file with the single-file source launcher (`java Foo.java`)
function! s:run_java() abort
  if !executable('java')
    echoerr 'No java found on the system!'
    return
  endif
  update
  let src_dir = expand('%:p:h')
  let src_name = expand('%:t')
  " the output of the previous (finished) run makes room for the new one
  if bufexists(s:run_buf)
    execute 'bwipeout!' s:run_buf
  endif
  set splitbelow
  new
  resize 15
  execute printf('lcd %s', fnameescape(src_dir))
  execute printf('term java %s', shellescape(src_name))
  let s:run_buf = bufnr('%')
  " <space>r stops the run from inside its terminal too, while typing or not
  tnoremap <silent> <buffer> <space>r <Cmd>call <SID>stop_run()<CR>
  nnoremap <silent> <buffer> <space>r <Cmd>call <SID>stop_run()<CR>
  startinsert
endfunction
