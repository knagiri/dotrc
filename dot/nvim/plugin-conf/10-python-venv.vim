" Python plugins in Nvim if ! has('nvim')
if ! has('nvim')
    finish
endif

" check python3
if strlen(system('type python3')) != 0
  let s:python3_dir = stdpath('data') . '/python3'
  if ! isdirectory(s:python3_dir)
    echo 'Python venv not found!'
    echo 'Create venv in ' . s:python3_dir
    call system('python3 -m venv ' . s:python3_dir)
    let s:packages = 'neovim pynvim jedi-language-server'
    echo 'Install packages ( ' . s:packages . ' )'
    call system(s:python3_dir . '/bin/python3 -m ' . 
                    \'pip install --no-cache-dir -U ' . s:packages)
  endif
  let g:python3_host_prog = s:python3_dir . '/bin/python'
  let $PATH = s:python3_dir . '/bin:' . $PATH
endif
