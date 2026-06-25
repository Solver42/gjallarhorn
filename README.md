# gjallarhorn

Odin tool for [Vim](https://github.com/vim/vim)

## Requirements

- [Odin](https://odin-lang.org) compiler (to build)
- A POSIX system
- Vim 8.2+

## Install

```sh
mkdir -p ~/.vim/pack/plugins/start
git clone https://github.com/Solver42/gjallarhorn ~/.vim/pack/plugins/start/gjallarhorn
sh ~/.vim/pack/plugins/start/gjallarhorn/install.sh
```

## Usage

Open an `.odin` file, type a name followed by a dot, press `Ctrl+X Ctrl+U`
Use `Ctrl+N` / `Ctrl+P` to cycle

Completions for struct fields, enum values, type aliases, imported library
symbols, and chained member access (`a.b.c.`). Re-indexes on save

Press `K` on any symbol to view its definition in a popup window

## How it works

When you open an `.odin` file, gjallarhorn searches for a project root by
walking up the directory tree until it finds a marker file (`.git`,
`.editorconfig`, or `gjallar.horn`). The directory containing the marker
becomes the project root

A simple way to mark the project root is to create a `gjallar.horn` file:

```sh
touch gjallar.horn
```

## Configuration

If you want the binary in a custom path, set `g:gjallarhorn_bin` in your `.vimrc`:

```vim
let g:gjallarhorn_bin = expand('~/.local/bin/gjallarhorn')
```

Defaults to `~/.local/bin/gjallarhorn`

To customize which filenames are treated as markers, edit the
`project_root_markers` array in `main.odin`:

```odin
project_root_markers := [1]string{"main.odin"}
```

and `root_markers` array in `plugin/gjallarhorn.vim`:

```vimscript
let s:root_markers = ['main.odin']
```

and rebuild:

```sh
sh ~/.vim/pack/plugins/start/gjallarhorn/install.sh
```

## License

[MIT](LICENSE)
