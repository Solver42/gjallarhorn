# Gjallarhorn

A lightweight Vim plugin that provides autocomplete, hover definitions, and go to definition for the Odin language<br>

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

Press `Ctrl+X Ctrl+U` for autocomplete, then use `Ctrl+N` / `Ctrl+P` to cycle<br>
Completions appear for struct fields, enum values, type aliases, imported library symbols, and chained member access (`a.b.c.`)<br>
Press `K` on any symbol to view its definition in a popup window<br>
Press `gd` on any symbol to jump to its definition<br>

## OLS vs Gjallarhorn

Why use Gjallarhorn when [OLS](https://github.com/DanielGavin/ols) gives you rename, code actions, diagnostics, refactoring, higher accuracy, and works in most editors?<br>
**Speed** Binary frames over a Unix socket, no JSON, protocol overhead or abstractions, a custom lexer tuned for completion and definition, not a full AST<br>
**Noise** You're writing code, not satisfying an editor, Gjallarhorn provides navigation and completion, the compiler handles diagnostics<br>
**Setup** No vim-lsp, asyncomplete-lsp and configuration needed, just run `install.sh` and you're done<br>

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

To add more root markers (e.g. `main.odin`), edit both `project_root_markers` in `main.odin` and `s:root_markers` in `plugin/gjallarhorn.vim`, then rebuild:

```odin
project_root_markers := [4]string{".git", ".editorconfig", "gjallar.horn", "main.odin"}
```

```vimscript
let s:root_markers = ['.git', '.editorconfig', 'gjallar.horn', 'main.odin']
```

```sh
sh ~/.vim/pack/plugins/start/gjallarhorn/install.sh
```

## License

[MIT](LICENSE)
