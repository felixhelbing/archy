# .bashrc

[ -f /etc/bashrc ] && . /etc/bashrc

PS1='\[\e[32m\]\u · \h · \D{%Y-%m-%d} · \D{%H:%M} \w\n» \[\e[0m\]'

alias gitdotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'
alias q=nvim
alias w='clear && eza -lhA --group-directories-first'
alias c=clear

# environment

export EDITOR=nvim
export VISUAL=nvim
export TERMINAL=ghostty
