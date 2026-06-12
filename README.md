# gjallarhorn

Odin completion for [Vim](https://github.com/vim/vim).

## Requirements

- [Odin](https://odin-lang.org) compiler (to build)
- A POSIX system

## Install

```sh
mkdir -p ~/.vim/pack/plugins/start
git clone https://github.com/Solver42/gjallarhorn ~/.vim/pack/plugins/start/gjallarhorn
sh ~/.vim/pack/plugins/start/gjallarhorn/install.sh
```

## Usage

Open an `.odin` file, type a name followed by a dot, press `Ctrl+X Ctrl+U`.
Use `Ctrl+N` / `Ctrl+P` to cycle.

Completions for struct fields, enum values, type aliases, imported library
symbols, and chained member access (`a.b.c.`). Re-indexes on save.

## Configuration

Set `g:gjallarhorn_bin` in your `.vimrc` to customize the binary path:

```vim
let g:gjallarhorn_bin = expand('~/.local/bin/gjallarhorn')
```

Defaults to `~/.local/bin/gjallarhorn`.

## License

[MIT](LICENSE)
