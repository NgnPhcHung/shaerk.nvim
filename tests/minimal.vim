set noswapfile
set nomore
let s:root = expand('<sfile>:p:h:h')
execute 'set rtp+=' . s:root
let s:plenary = empty($PLENARY_PATH) ? expand('~/.local/share/nvim/lazy/plenary.nvim') : $PLENARY_PATH
execute 'set rtp+=' . s:plenary
runtime! plugin/plenary.vim
