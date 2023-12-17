" Vim-Plug
" See `https://github.com/junegunn/vim-plug/wiki/tips#automatic-installation`
let data_dir = has('nvim') ? stdpath('data') . '/site' : '~/.vim'
if empty(glob(data_dir . '/autoload/plug.vim'))
  silent execute '!curl -fLo '.data_dir.'/autoload/plug.vim --create-dirs  https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
  autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
endif

" Plugins will be downloaded under the specified directory.
call plug#begin(has('nvim') ? stdpath('data') . '/plugged' : '~/.vim/plugged')

" Declare the list of plugins.

" Language Server Protocol
Plug 'neovim/nvim-lspconfig'
Plug 'williamboman/mason.nvim'
Plug 'williamboman/mason-lspconfig.nvim'

" GitHub Copilot
Plug 'github/copilot.vim', { 'branch': 'release' }

" Syntax hilighting
Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}  " We recommend updating the parsers on update
" Colorscheme `nightfox` (See https://github.com/edeneast/nightfox.nvim)
Plug 'EdenEast/nightfox.nvim', { 'tag': 'v1.0.0' }

" Utilities
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'

Plug 'mattn/emmet-vim'

" List ends here. Plugins become visible to Vim after this call.
call plug#end()

runtime! plugin-conf/**/*

" Some servers have issues with backup files, see #649.
set nobackup
set nowritebackup

" Give more space for displaying messages.
set cmdheight=2
"
" Having longer updatetime (default is 4000 ms = 4 s) leads to noticeable
" delays and poor user experience.
set updatetime=300

" sign-column with number-column
set signcolumn=number

" No mouse control
set mouse=

" display row number and current cursor line
set number
set cursorline

" notify whether )}] matched
set showmatch
" enable to move empty-character point
set virtualedit=onemore

" tab settings
" See https://yu8mada.com/2018/08/26/i-ll-explain-vim-s-5-tab-and-space-related-somewhat-complicated-options-as-simply-as-possible/
set tabstop=4
set shiftwidth=4
set expandtab
set smartindent
set smarttab

nnoremap j gj
nnoremap k gk
