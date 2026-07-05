# Gjallarhorn

A lightweight Vim plugin that provides 3 features for Odin language: autocomplete, hover definitions, and go to definition.
It stays out of your way until you need it. If you want an IDE experience with rename, refactoring, diagnostics, code actions, and LSP support across many editors, [OLS](https://github.com/DanielGavin/ols) is the right choice.

Why use Gjallarhorn then?

- **Speed** - A hand-written lexer over a binary Unix socket protocol. Purpose-built for completion and definitions with no AST or JSON overhead.
- **Focus** - No diagnostics, no squiggly underlines, no editor trying to fix your code while you're still writing it. The compiler is the source of truth.
- **Simplicity** - Run the install script, open vim, edit code. No dependencies, no package manager.

## Requirements

- [Odin](https://odin-lang.org) compiler to build
- A POSIX system
- [Vim](https://github.com/vim/vim) 8.2+

## Install

Clone the repository:
```sh
git clone https://github.com/Solver42/gjallarhorn ~/.vim/pack/plugins/start/gjallarhorn
```

Compile the `gjallarhorn` binary and install it under `~/.local/bin`:
```sh
sh ~/.vim/pack/plugins/start/gjallarhorn/install.sh
```

## Update

```sh
cd ~/.vim/pack/plugins/start/gjallarhorn && git pull && sh install.sh
```

## Usage

Press `Ctrl+X Ctrl+U` for autocomplete, then use `Ctrl+N` / `Ctrl+P` to cycle.
Completions appear for struct fields, enum values, type aliases, imported library symbols, and chained member access (`a.b.c.`).
Press `K` on any symbol to view its definition in a popup window.
Press `gd` on any symbol to jump to its definition.

## How it works

It indexes the project on startup and re-indexes on save. When you open an `.odin` file, Gjallarhorn searches for a project root by walking up the directory tree until it finds a marker file (`.git`, `.editorconfig`, or `gjallar.horn`). The directory containing the marker becomes the project root. A simple way to mark the project root is to create an empty `gjallar.horn` file:

```sh
touch gjallar.horn
```

## Configuration

If you want the binary in a custom path, set `g:gjallarhorn_bin` in your `.vimrc`:

```vim
let g:gjallarhorn_bin = expand('~/.local/bin/gjallarhorn')
```

To change which files/directories mark a project root, set `g:gjallarhorn_root_markers`
in your `.vimrc`:

```vim
let g:gjallarhorn_root_markers = ['.git', 'main.odin']
```

## License

[MIT](LICENSE)
