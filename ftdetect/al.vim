" Force filetype=al for *.al and *.dal, overriding Vim's built-in Perl detection.
" (Vim maps *.al to Perl Abstract Library files; 'set' overrides, 'setfiletype' would not.)
autocmd BufRead,BufNewFile *.al  set filetype=al
autocmd BufRead,BufNewFile *.dal set filetype=al
