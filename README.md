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

Open an `.odin` file in Vim. In insert mode, type a struct or enum name followed
by a dot, then press `Ctrl+X Ctrl+U` to get completions. Use `Ctrl+N` / `Ctrl+P`
to cycle through candidates.

Completions work for:

- Enum values, struct fields, and type aliases
- Chained member access (e.g. `a.b.c.`)

The daemon automatically re-indexes your file when you save (`:w`).

## Configuration

By default the plugin looks for the binary at `~/.local/bin/gjallarhorn`. If you
installed it elsewhere, set `g:gjallarhorn_bin` in your `.vimrc`:

```vim
let g:gjallarhorn_bin = expand('~/.local/bin/gjallarhorn')
```

## License

[MIT](LICENSE)
