nnoremap <silent> <buffer> <space>r :call <SID>run_java()<CR>

" Run the current file with the single-file source launcher (`java Foo.java`)
function! s:run_java() abort
  if !executable('java')
    echoerr 'No java found on the system!'
    return
  endif
  update
  let src_dir = expand('%:p:h')
  let src_name = expand('%:t')
  set splitbelow
  new
  resize 15
  execute printf('lcd %s', fnameescape(src_dir))
  execute printf('term java %s', shellescape(src_name))
  startinsert
endfunction
