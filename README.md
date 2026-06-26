# gjallarhorn

A lightweight Vim plugin that provides autocomplete, view definition and go to definition for the Odin language.

## Requirements

- [Odin](https://odin-lang.org) compiler to build
- A POSIX system
- [Vim](https://github.com/vim/vim) 8.2+

## Install

Create the pack directory if it doesn't exist:
```sh
mkdir -p ~/.vim/pack/plugins/start
```

Clone the repository:
```sh
git clone https://github.com/Solver42/gjallarhorn ~/.vim/pack/plugins/start/gjallarhorn
```

Compile the `gjallarhorn` binary and install it under `~/.local/bin`:
```sh
sh ~/.vim/pack/plugins/start/gjallarhorn/install.sh
```

## Update

Change directory
```sh
cd ~/.vim/pack/plugins/start/gjallarhorn
```
Get the latest version
```sh
git pull
```
Install the new version
```sh
sh install.sh
```

## Usage

Type a name followed by a dot, press `Ctrl+X Ctrl+U` for autocomplete, use `Ctrl+N` / `Ctrl+P` to cycle<br>
Completions for struct fields, enum values, type aliases, imported library symbols, and chained member access `a.b.c.`<br>
Press `K` on any symbol to view its definition in a popup window<br>
Press `gd` on any symbol to jump to its definition<br>

## How it works

It indexes the project on startup and re-indexes on save<br>
When you open an `.odin` file, gjallarhorn searches for a project root by
walking up the directory tree until it finds a marker file `.git`, `.editorconfig`, or `gjallar.horn`<br>
The directory containing the marker
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

To customize which filenames are treated as root markers, edit the
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
