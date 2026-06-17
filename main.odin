package gjallarhorn

import "core:crypto/legacy/md5"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

debug_logging_enabled : bool
indent_spaces         : string = "    "
g_project_root        : string   // set once by daemon_start; never mutated after that

// Filenames that, when found in a directory, identify it as the project root.
project_root_markers : = [3]string{".git", ".editorconfig", "gjallar.horn"}

// Directory names the recursive indexer never descends into.
// Directories whose names begin with '.' are also always skipped.
dirs_excluded_from_indexing :: []string{"vendor"}

// Socket path stored globally so the SIGTERM/SIGINT handler can unlink it.
g_socket_path_c : cstring

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

Struct_Field :: struct {
    name : string,
    type : string,
}

Struct_Definition :: struct {
    fields : [dynamic]Struct_Field,
}

Enum_Definition :: struct {
    values : [dynamic]string,
}

// Symbols loaded from a single imported package directory.
Package_Symbols :: struct {
    structs : map[string]Struct_Definition,
    enums   : map[string]Enum_Definition,
}

// Cache of already-loaded package directories → their exported symbols.
g_package_import_cache : map[string]Package_Symbols

// Cached result of `odin root` so we only run the subprocess once.
g_odin_root_cache : string

// Project_Index holds every symbol visible to the file currently being edited.
Project_Index :: struct {
    // Symbols defined in the project's own source files.
    own_structs   : map[string]Struct_Definition,
    own_enums     : map[string]Enum_Definition,
    own_variables : map[string]string,           // variable name → type name

    // Raw import statements found in the source: alias → package path.
    import_aliases : map[string]string,

    // Resolved import data keyed by the alias used in source code.
    // Values are stable indices into g_package_import_cache (string keys);
    // we store the package_dir key rather than a pointer so that a cache
    // rebuild cannot produce a dangling reference.
    imported_package_dirs : map[string]string,   // alias → package_dir key

    // Flattened union of all imported symbols (for unqualified lookup).
    all_imported_structs : map[string]Struct_Definition,
    all_imported_enums   : map[string]Enum_Definition,
}

// ---------------------------------------------------------------------------
// Project_Index lifecycle
// ---------------------------------------------------------------------------

project_index_destroy :: proc(idx: ^Project_Index) {
    for _, &s in idx.own_structs {
        for &f in s.fields { delete(f.name); delete(f.type) }
        delete(s.fields)
    }
    for k in idx.own_structs { delete(k) }
    delete(idx.own_structs)

    for _, &e in idx.own_enums {
        for v in e.values { delete(v) }
        delete(e.values)
    }
    for k in idx.own_enums { delete(k) }
    delete(idx.own_enums)

    for k, v in idx.own_variables    { delete(k); delete(v) }
    delete(idx.own_variables)

    for k, v in idx.import_aliases   { delete(k); delete(v) }
    delete(idx.import_aliases)

    // FIX: imported_package_dirs replaced the old ^Package_Symbols pointer map.
    // Keys are alias strings we cloned; values are package_dir strings we cloned.
    for k, v in idx.imported_package_dirs { delete(k); delete(v) }
    delete(idx.imported_package_dirs)

    // all_imported_* are shallow views into g_package_import_cache — do NOT
    // free the Struct_Definition / Enum_Definition values, only the map itself.
    delete(idx.all_imported_structs)
    delete(idx.all_imported_enums)
}

make_empty_project_index :: proc() -> Project_Index {
    return Project_Index{
        own_structs           = make(map[string]Struct_Definition),
        own_enums             = make(map[string]Enum_Definition),
        own_variables         = make(map[string]string),
        import_aliases        = make(map[string]string),
        imported_package_dirs = make(map[string]string),
        all_imported_structs  = make(map[string]Struct_Definition),
        all_imported_enums    = make(map[string]Enum_Definition),
    }
}

// ---------------------------------------------------------------------------
// Package_Symbols lifecycle
// ---------------------------------------------------------------------------

package_symbols_destroy :: proc(pkg: ^Package_Symbols) {
    for k, &s in pkg.structs {
        for &f in s.fields { delete(f.name); delete(f.type) }
        delete(s.fields)
        delete(k)
    }
    delete(pkg.structs)

    for k, &e in pkg.enums {
        for v in e.values { delete(v) }
        delete(e.values)
        delete(k)
    }
    delete(pkg.enums)
}

// FIX: properly destroy every Package_Symbols value before wiping the cache.
package_import_cache_destroy :: proc() {
    for k, &pkg in g_package_import_cache {
        package_symbols_destroy(&pkg)
        delete(k)
    }
    delete(g_package_import_cache)
}

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------

Token_Kind :: enum {
    EOF,
    Identifier,
    String_Literal,
    Double_Colon,  // ::
    Open_Brace,    // {
    Close_Brace,   // }
    Comma,         // ,
    Colon,         // :
    Other,
}

Token :: struct {
    kind : Token_Kind,
    text : string,
}

Lexer :: struct {
    src : string,
    pos : int,
}

lexer_make :: proc(src: string) -> Lexer {
    return Lexer{src = src, pos = 0}
}

lexer_skip_whitespace_and_comments :: proc(l: ^Lexer) {
    for l.pos < len(l.src) {
        c := l.src[l.pos]

        if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
            l.pos += 1
            continue
        }

        is_line_comment  := c == '/' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '/'
        is_block_comment := c == '/' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '*'

        if is_line_comment {
            for l.pos < len(l.src) && l.src[l.pos] != '\n' { l.pos += 1 }
            continue
        }

        if is_block_comment {
            l.pos += 2
            for l.pos + 1 < len(l.src) {
                if l.src[l.pos] == '*' && l.src[l.pos + 1] == '/' {
                    l.pos += 2
                    break
                }
                l.pos += 1
            }
            continue
        }

        break
    }
}

lexer_next :: proc(l: ^Lexer) -> Token {
    lexer_skip_whitespace_and_comments(l)
    if l.pos >= len(l.src) { return Token{kind = .EOF} }

    c := l.src[l.pos]

    // Identifier or keyword.
    if c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
        start := l.pos
        for l.pos < len(l.src) {
            b := l.src[l.pos]
            if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') {
                l.pos += 1
            } else {
                break
            }
        }
        return Token{kind = .Identifier, text = l.src[start:l.pos]}
    }

    // Colon or double-colon.
    if c == ':' {
        if l.pos + 1 < len(l.src) && l.src[l.pos + 1] == ':' {
            l.pos += 2
            return Token{kind = .Double_Colon, text = "::"}
        }
        l.pos += 1
        return Token{kind = .Colon, text = ":"}
    }

    // Quoted string.
    if c == '"' {
        l.pos += 1
        start := l.pos
        for l.pos < len(l.src) && l.src[l.pos] != '"' {
            if l.src[l.pos] == '\\' { l.pos += 1 }
            l.pos += 1
        }
        text := l.src[start:l.pos]
        if l.pos < len(l.src) { l.pos += 1 }
        return Token{kind = .String_Literal, text = text}
    }

    if c == '{' { l.pos += 1; return Token{kind = .Open_Brace,  text = "{"} }
    if c == '}' { l.pos += 1; return Token{kind = .Close_Brace, text = "}"} }
    if c == ',' { l.pos += 1; return Token{kind = .Comma,       text = ","} }

    // Any other unicode character.
    start := l.pos
    _, rune_width := utf8.decode_rune_in_string(l.src[l.pos:])
    l.pos += rune_width
    return Token{kind = .Other, text = l.src[start:l.pos]}
}

lexer_peek :: proc(l: ^Lexer) -> Token {
    saved_pos := l.pos
    tok       := lexer_next(l)
    l.pos      = saved_pos
    return tok
}

// ---------------------------------------------------------------------------
// Project root discovery
// ---------------------------------------------------------------------------

dir_contains_project_root_marker :: proc(dir_path: string) -> bool {
    entries, err := os.read_all_directory_by_path(dir_path, context.temp_allocator)
    if err != nil { return false }
    for entry in entries {
        for marker in project_root_markers {
            if entry.name == marker { return true }
        }
    }
    return false
}

// Walks up the directory tree from start_dir until it finds a directory
// containing a project root marker.  Falls back to start_dir if none is found.
find_project_root :: proc(start_dir: string, allocator := context.allocator) -> string {
    current := strings.clone(start_dir, context.temp_allocator)

    for {
        if dir_contains_project_root_marker(current) {
            return strings.clone(current, allocator)
        }

        // Strip trailing slashes, then find the last slash.
        trimmed_end := len(current) - 1
        for trimmed_end > 0 && current[trimmed_end] == '/' { trimmed_end -= 1 }

        last_slash := -1
        for i := trimmed_end; i >= 0; i -= 1 {
            if current[i] == '/' { last_slash = i; break }
        }

        if last_slash <= 0 { break }  // Reached the filesystem root.

        current = current[:last_slash]
    }

    return strings.clone(start_dir, allocator)
}

// ---------------------------------------------------------------------------
// Source parsing — produces a Project_Index from raw Odin source text
// ---------------------------------------------------------------------------

// derive_import_alias infers the default alias for an import path when the
// programmer did not write one explicitly.
// e.g.  "core:fmt"      → "fmt"
//       "../my/package" → "package"
derive_import_alias :: proc(import_path: string) -> string {
    last_separator := -1
    for i := 0; i < len(import_path); i += 1 {
        if import_path[i] == ':' || import_path[i] == '/' {
            last_separator = i
        }
    }
    if last_separator == -1 { return import_path }
    return import_path[last_separator + 1:]
}

// parse_dotted_type_name reads a possibly-qualified type name from the lexer,
// e.g.  "fmt.Formatter"  or just  "MyStruct".
// Returns the joined string using the temp allocator.
parse_dotted_type_name :: proc(l: ^Lexer, first_ident: string) -> string {
    parts := make([dynamic]string, context.temp_allocator)
    append(&parts, first_ident)
    for {
        pk := lexer_peek(l)
        if pk.kind == .Other && pk.text == "." {
            lexer_next(l)
            name_tok := lexer_next(l)
            if name_tok.kind == .Identifier {
                append(&parts, ".")
                append(&parts, name_tok.text)
            } else { break }
        } else { break }
    }
    return strings.join(parts[:], "")
}

parse_source_file :: proc(src: string) -> Project_Index {
    idx := make_empty_project_index()
    l   := lexer_make(src)

    for {
        tok := lexer_next(&l)
        if tok.kind == .EOF        { break }
        if tok.kind != .Identifier { continue }

        symbol_name := tok.text

        // Import statement.
        if symbol_name == "import" {
            peek := lexer_peek(&l)
            alias, path: string

            if peek.kind == .String_Literal {
                // import "core:fmt"  — alias is derived automatically.
                lexer_next(&l)
                path  = peek.text
                alias = derive_import_alias(path)
            } else if peek.kind == .Identifier || (peek.kind == .Other && peek.text == ".") {
                // import fmt "core:fmt"  or  import . "core:fmt"
                alias_tok := lexer_next(&l)
                alias = alias_tok.text
                path_tok := lexer_next(&l)
                if path_tok.kind == .String_Literal { path = path_tok.text }
            }

            if alias == "_" { continue }
            if alias != "" && path != "" {
                idx.import_aliases[strings.clone(alias)] = strings.clone(path)
            }
            continue
        }

        next_tok := lexer_peek(&l)

        // Top-level constant/type declaration:  Name :: ...
        if next_tok.kind == .Double_Colon {
            lexer_next(&l)  // consume ::
            after := lexer_peek(&l)
            if after.kind != .Identifier { continue }

            switch after.text {
            case "struct":
                lexer_next(&l)
                idx.own_structs[strings.clone(symbol_name)] = parse_struct_body(&l)
            case "enum":
                lexer_next(&l)
                idx.own_enums[strings.clone(symbol_name)] = parse_enum_body(&l)
            case:
                lexer_next(&l)
                type_name := parse_dotted_type_name(&l, after.text)
                idx.own_variables[strings.clone(symbol_name)] = strings.clone(type_name)
            }
            continue
        }

        // Variable declaration with explicit type:  name : TypeName
        if next_tok.kind == .Colon {
            lexer_next(&l)  // consume :
            type_tok := lexer_peek(&l)
            if type_tok.kind == .Identifier {
                lexer_next(&l)
                type_name := parse_dotted_type_name(&l, type_tok.text)
                idx.own_variables[strings.clone(symbol_name)] = strings.clone(type_name)
            }
            continue
        }
    }

    return idx
}

parse_struct_body :: proc(l: ^Lexer) -> Struct_Definition {
    defn := Struct_Definition{fields = make([dynamic]Struct_Field)}

    // Advance to the opening brace.
    brace_depth := 0
    for {
        tok := lexer_next(l)
        if tok.kind == .EOF        { return defn }
        if tok.kind == .Open_Brace { brace_depth = 1; break }
    }

    for brace_depth > 0 {
        tok := lexer_next(l)
        #partial switch tok.kind {
        case .EOF:
            return defn
        case .Open_Brace:
            brace_depth += 1
        case .Close_Brace:
            brace_depth -= 1
        case .Identifier:
            if brace_depth != 1 { continue }

            field_name := tok.text
            if lexer_peek(l).kind != .Colon { continue }
            lexer_next(l)  // consume :

            // Collect type tokens until the next field name, comma, or closing brace.
            type_parts := make([dynamic]string, context.temp_allocator)
            for {
                pk := lexer_peek(l)
                if pk.kind == .EOF || pk.kind == .Comma || pk.kind == .Close_Brace { break }
                // Stop if we're looking at the start of the next field (ident followed by colon).
                if pk.kind == .Identifier {
                    saved_pos := l.pos
                    lexer_next(l)
                    next_is_colon := lexer_peek(l).kind == .Colon
                    l.pos = saved_pos
                    if next_is_colon { break }
                }
                t := lexer_next(l)
                if t.text != "" { append(&type_parts, t.text) }
            }
            if lexer_peek(l).kind == .Comma { lexer_next(l) }

            // strings.join allocates on the default allocator; owned by the field.
            type_str := strings.join(type_parts[:], "")
            append(&defn.fields, Struct_Field{
                name = strings.clone(field_name),
                type = type_str,
            })
        case:
        }
    }
    return defn
}

parse_enum_body :: proc(l: ^Lexer) -> Enum_Definition {
    defn := Enum_Definition{values = make([dynamic]string)}

    for {
        tok := lexer_next(l)
        if tok.kind == .EOF        { return defn }
        if tok.kind == .Open_Brace { break }
    }

    for {
        tok := lexer_next(l)
        #partial switch tok.kind {
        case .EOF, .Close_Brace:
            return defn
        case .Identifier:
            append(&defn.values, strings.clone(tok.text))
            // Skip to the comma or closing brace.
            for {
                pk := lexer_peek(l)
                if pk.kind == .EOF || pk.kind == .Comma || pk.kind == .Close_Brace { break }
                lexer_next(l)
            }
            if lexer_peek(l).kind == .Comma { lexer_next(l) }
        case:
        }
    }
}

// ---------------------------------------------------------------------------
// Odin installation root
// ---------------------------------------------------------------------------

get_odin_root :: proc() -> (string, bool) {
    if g_odin_root_cache != "" { return g_odin_root_cache, true }

    env_val, env_found := os.lookup_env_alloc("ODIN_ROOT", context.allocator)
    if env_found && env_val != "" {
        root := env_val
        if root[len(root) - 1] == '/' { root = root[:len(root) - 1] }
        g_odin_root_cache = strings.clone(root)
        delete(env_val)
        return g_odin_root_cache, true
    }
    if env_found { delete(env_val) }

    proc_desc := os.Process_Desc{ command = {"odin", "root"} }
    state, stdout, stderr, err := os.process_exec(proc_desc, context.allocator)
    if err != nil || !state.success {
        delete(stdout); delete(stderr)
        return "", false
    }
    delete(stderr)

    root := strings.trim_space(string(stdout))
    if len(root) > 0 && root[len(root) - 1] == '/' { root = root[:len(root) - 1] }
    g_odin_root_cache = strings.clone(root)
    delete(stdout)
    return g_odin_root_cache, true
}

// Resolves an import path string to an absolute directory path.
// Collection paths like "core:fmt" are resolved relative to the Odin root.
// Relative paths like "../utils" are resolved relative to the source file's directory.
resolve_import_to_dir :: proc(import_path: string, source_file: string) -> (string, bool) {
    colon_pos := -1
    for i := 0; i < len(import_path); i += 1 {
        if import_path[i] == ':' { colon_pos = i; break }
    }

    if colon_pos != -1 {
        odin_root, ok := get_odin_root()
        if !ok { return "", false }
        collection := import_path[:colon_pos]
        pkg_name   := import_path[colon_pos + 1:]
        return strings.concatenate({odin_root, "/", collection, "/", pkg_name}), true
    }

    source_dir := path_parent_dir(source_file, context.temp_allocator)
    return strings.concatenate({source_dir, "/", import_path}), true
}

// ---------------------------------------------------------------------------
// Package symbol loading (imports)
// ---------------------------------------------------------------------------

// Loads and caches all exported symbols from a package directory.
// Resolves type aliases so that aliased names also appear in the result.
// Idempotent: returns immediately if the directory is already cached.
load_package_symbols :: proc(package_dir: string) {
    if package_dir in g_package_import_cache { return }

    pkg := Package_Symbols{
        structs = make(map[string]Struct_Definition),
        enums   = make(map[string]Enum_Definition),
    }

    // type_aliases collects  alias_name → target_type_name  from variable
    // declarations at package scope, which is how Odin re-exports types.
    type_aliases := make(map[string]string)
    defer {
        for k, v in type_aliases { delete(k); delete(v) }
        delete(type_aliases)
    }

    file_infos, err := os.read_all_directory_by_path(package_dir, context.allocator)
    if err != nil {
        g_package_import_cache[strings.clone(package_dir)] = pkg
        return
    }
    defer os.file_info_slice_delete(file_infos, context.allocator)

    for fi in file_infos {
        if fi.type == .Directory                       { continue }
        if !strings.has_suffix(fi.name, ".odin")      { continue }
        if  strings.has_suffix(fi.name, "_test.odin") { continue }

        full_path := strings.concatenate({package_dir, "/", fi.name}, context.temp_allocator)
        src_data, read_err := os.read_entire_file_from_path(full_path, context.allocator)
        if read_err != nil { continue }

        file_idx := parse_source_file(string(src_data))
        delete(src_data, context.allocator)

        // Move struct definitions into the package result.
        // The key string k and field strings are already heap-allocated by
        // parse_source_file; we transfer ownership to pkg.structs directly.
        for k, &s in file_idx.own_structs {
            if old, already := pkg.structs[k]; already {
                // Duplicate definition across files in the same package — free the old one.
                for &f in old.fields { delete(f.name); delete(f.type) }
                delete(old.fields)
                delete_key(&pkg.structs, k)    // key string stays; reused by the new entry below
            }
            pkg.structs[k] = s
            delete_key(&file_idx.own_structs, k)
        }
        delete(file_idx.own_structs)
        file_idx.own_structs = {}

        // Move enum definitions.
        for k, &e in file_idx.own_enums {
            if old, already := pkg.enums[k]; already {
                for v in old.values { delete(v) }
                delete(old.values)
                delete_key(&pkg.enums, k)
            }
            pkg.enums[k] = e
            delete_key(&file_idx.own_enums, k)
        }
        delete(file_idx.own_enums)
        file_idx.own_enums = {}

        // FIX: collect variable declarations as potential type aliases.
        // The original code cloned the keys into type_aliases but left the
        // originals owned by file_idx.own_variables, causing a double-free
        // when project_index_destroy was later called on the drained index.
        // We drain own_variables directly: transfer key + value ownership to
        // type_aliases and remove from file_idx so destroy sees nothing.
        for k, v in file_idx.own_variables {
            if old_v, has := type_aliases[k]; has {
                // Another file in this package already declared this name.
                // The key string k is shared with the map key in type_aliases;
                // we must free the old value but must NOT free k yet because
                // it is still the live key in type_aliases (and will be
                // overwritten by the assignment below, which reuses the same
                // key slot — the old key string remains in use).
                delete(old_v)
            } else {
                // First time we see this name: the key k comes from
                // file_idx.own_variables and will be transferred to
                // type_aliases, so we must not free it here.
                _ = k
            }
            type_aliases[k] = v
            delete_key(&file_idx.own_variables, k)
        }

        // import_aliases collected during package-file parsing are not needed
        // at this level (we don't recursively resolve package imports here).
        project_index_destroy(&file_idx)
    }

    // Walk alias chains and register aliased types under both names.
    follow_alias_chain :: proc(aliases: map[string]string, start: string) -> string {
        hops    := 0
        current := start
        for hops < 100 {
            if next, ok := aliases[current]; ok { current = next; hops += 1 } else { return current }
        }
        return current
    }

    for alias_name, target_name in type_aliases {
        resolved := follow_alias_chain(type_aliases, target_name)

        if entry, ok := pkg.structs[resolved]; ok {
            copy_entry := Struct_Definition{fields = make([dynamic]Struct_Field, len(entry.fields))}
            for &f, i in entry.fields {
                copy_entry.fields[i] = Struct_Field{
                    name = strings.clone(f.name),
                    type = strings.clone(f.type),
                }
            }
            pkg.structs[strings.clone(alias_name)] = copy_entry

        } else if entry, ok := pkg.enums[resolved]; ok {
            copy_entry := Enum_Definition{values = make([dynamic]string, len(entry.values))}
            for v, i in entry.values { copy_entry.values[i] = strings.clone(v) }
            pkg.enums[strings.clone(alias_name)] = copy_entry
        }
    }

    g_package_import_cache[strings.clone(package_dir)] = pkg
}

// Registers a loaded package into the index under its alias, and copies its
// symbols into the flat all_imported_* maps for unqualified lookup.
//
// FIX: we store the package_dir key string (not a pointer into the cache map)
// so that a later cache rebuild cannot produce a dangling ^Package_Symbols.
// Qualified lookups (completions_for_package_alias) resolve the key at query
// time, which is always safe because the cache is rebuilt atomically before
// the index is rebuilt.
register_package_into_index :: proc(idx: ^Project_Index, alias: string, package_dir: string) {
    cached, ok := g_package_import_cache[package_dir]
    if !ok { return }

    if alias != "." {
        idx.imported_package_dirs[strings.clone(alias)] = strings.clone(package_dir)
    }

    for name, defn in cached.structs { idx.all_imported_structs[name] = defn }
    for name, defn in cached.enums   { idx.all_imported_enums[name]   = defn }
}

// Resolves and loads every package imported by idx, populating
// imported_package_dirs and the flat all_imported_* maps.
// source_file is used to anchor relative import paths.
resolve_and_load_imports :: proc(idx: ^Project_Index, source_file: string) {
    for alias, import_path in idx.import_aliases {
        if alias == "_" { continue }
        package_dir, ok := resolve_import_to_dir(import_path, source_file)
        if !ok { continue }
        load_package_symbols(package_dir)
        register_package_into_index(idx, alias, package_dir)
        delete(package_dir)
    }
}

// ---------------------------------------------------------------------------
// Project-wide recursive indexing
// ---------------------------------------------------------------------------

dir_should_be_skipped :: proc(dir_name: string) -> bool {
    if len(dir_name) > 0 && dir_name[0] == '.' { return true }
    for excluded in dirs_excluded_from_indexing {
        if dir_name == excluded { return true }
    }
    return false
}

// Parses every non-test .odin file in dir_path and merges their symbols into idx.
// Runs import resolution once for the directory so relative paths resolve correctly.
// Returns true when at least one .odin file was processed.
index_package_directory :: proc(idx: ^Project_Index, dir_path: string) -> (found_odin_files: bool) {
    file_infos, err := os.read_all_directory_by_path(dir_path, context.temp_allocator)
    if err != nil { return false }

    found_any_odin_file := false

    for fi in file_infos {
        if fi.type == .Directory                       { continue }
        if !strings.has_suffix(fi.name, ".odin")      { continue }
        if  strings.has_suffix(fi.name, "_test.odin") { continue }

        full_path := strings.concatenate({dir_path, "/", fi.name}, context.temp_allocator)
        src_data, read_err := os.read_entire_file_from_path(full_path, context.allocator)
        if read_err != nil { continue }

        file_idx := parse_source_file(string(src_data))
        delete(src_data, context.allocator)

        merge_parsed_file_into_index(idx, &file_idx)
        found_any_odin_file = true
    }

    if found_any_odin_file {
        // Synthesise a sentinel path so that relative imports in this directory
        // resolve correctly regardless of which concrete filename we pick.
        sentinel_path := strings.concatenate({dir_path, "/_sentinel.odin"}, context.temp_allocator)
        resolve_and_load_imports(idx, sentinel_path)
    }

    return found_any_odin_file
}

// Recursively walks the project tree, indexing every subdirectory that is not
// hidden and not in the exclusion list.  Uses an explicit stack to avoid deep
// call-stack recursion on large projects.
//
// Returns the Project_Index and, in visited_package_dirs, the heap-allocated
// path of every directory that contained at least one .odin file.  The caller
// owns those strings and must delete them.
index_project :: proc(
    project_root:         string,
    visited_package_dirs: ^[dynamic]string,
) -> Project_Index {
    idx := make_empty_project_index()

    dir_stack := make([dynamic]string, context.temp_allocator)
    append(&dir_stack, strings.clone(project_root, context.temp_allocator))

    for len(dir_stack) > 0 {
        current_dir := dir_stack[len(dir_stack) - 1]
        pop(&dir_stack)

        if debug_logging_enabled { fmt.eprintfln("indexing: %s", current_dir) }

        had_odin_files := index_package_directory(&idx, current_dir)
        if had_odin_files {
            append(visited_package_dirs, strings.clone(current_dir))
        }

        sub_entries, sub_err := os.read_all_directory_by_path(current_dir, context.temp_allocator)
        if sub_err != nil { continue }

        for entry in sub_entries {
            if entry.type != .Directory          { continue }
            if dir_should_be_skipped(entry.name) { continue }
            sub_path := strings.concatenate({current_dir, "/", entry.name}, context.temp_allocator)
            append(&dir_stack, sub_path)
        }
    }

    return idx
}

// Drains all symbols from file_idx into idx, replacing any existing entries
// with the same name.  Frees the replaced entries.
merge_parsed_file_into_index :: proc(idx: ^Project_Index, file_idx: ^Project_Index) {
    for k, &s in file_idx.own_structs {
        if old, ok := idx.own_structs[k]; ok {
            for &f in old.fields { delete(f.name); delete(f.type) }
            delete(old.fields)
            // FIX: also free the old key string before overwriting the entry.
            // delete_key only removes the map entry; the heap string is separate.
            old_key := k  // k is a view into file_idx's key, not idx's
            for ik in idx.own_structs {
                if ik == k { old_key = ik; break }
            }
            delete(old_key)
            delete_key(&idx.own_structs, k)
        }
        idx.own_structs[k] = s
        delete_key(&file_idx.own_structs, k)
    }
    // Any entries left in file_idx.own_structs were not transferred (shouldn't
    // happen with drain loop above, but guard defensively).
    for _, &s in file_idx.own_structs {
        for &f in s.fields { delete(f.name); delete(f.type) }
        delete(s.fields)
    }
    for k in file_idx.own_structs { delete(k) }
    delete(file_idx.own_structs)
    file_idx.own_structs = {}

    for k, &e in file_idx.own_enums {
        if old, ok := idx.own_enums[k]; ok {
            for v in old.values { delete(v) }
            delete(old.values)
            for ik in idx.own_enums {
                if ik == k { delete(ik); break }
            }
            delete_key(&idx.own_enums, k)
        }
        idx.own_enums[k] = e
        delete_key(&file_idx.own_enums, k)
    }
    for _, &e in file_idx.own_enums {
        for v in e.values { delete(v) }
        delete(e.values)
    }
    for k in file_idx.own_enums { delete(k) }
    delete(file_idx.own_enums)
    file_idx.own_enums = {}

    for k, v in file_idx.own_variables {
        if old_v, ok := idx.own_variables[k]; ok {
            delete(old_v)
            // FIX: free the existing key in idx before overwriting.
            for ik in idx.own_variables {
                if ik == k { delete(ik); break }
            }
            delete_key(&idx.own_variables, k)
        }
        idx.own_variables[k] = v
        delete_key(&file_idx.own_variables, k)
    }
    // Remaining (shouldn't happen with drain) — free defensively.
    for k, v in file_idx.own_variables { delete(k); delete(v) }
    delete(file_idx.own_variables)
    file_idx.own_variables = {}

    for k, v in file_idx.import_aliases {
        if old_v, ok := idx.import_aliases[k]; ok {
            delete(old_v)
            for ik in idx.import_aliases {
                if ik == k { delete(ik); break }
            }
            delete_key(&idx.import_aliases, k)
        }
        idx.import_aliases[k] = v
        delete_key(&file_idx.import_aliases, k)
    }
    for k, v in file_idx.import_aliases { delete(k); delete(v) }
    delete(file_idx.import_aliases)
    file_idx.import_aliases = {}

    // imported_package_dirs / all_imported_* in file_idx are populated only
    // after resolve_and_load_imports, which is called on the merged idx — not
    // on each individual file_idx.  So these maps are always empty here.
    project_index_destroy(file_idx)
}

// ---------------------------------------------------------------------------
// Global index — the single live index the daemon serves queries against
// ---------------------------------------------------------------------------

g_project_index : Project_Index

path_parent_dir :: proc(file_path: string, allocator := context.allocator) -> string {
    for i := len(file_path) - 1; i >= 0; i -= 1 {
        if file_path[i] == '/' {
            if i == 0 { return strings.clone("/", allocator) }
            return strings.clone(file_path[:i], allocator)
        }
    }
    return strings.clone(".", allocator)
}

// Builds a fresh global index rooted at project_root.
//
// Steps:
//   1. FIX: Fully destroy the old package cache (keys + all Package_Symbols
//      contents) before rebuilding, so no memory is leaked across rebuilds.
//   2. Walk the entire project tree with index_project.
//   3. Eagerly load package symbols for each visited directory.
//   4. Swap the new index in and destroy the old one.
build_project_index :: proc(project_root: string, any_file_in_project: string) {
    fmt.eprintfln("index build begin  (root: %s)", project_root)
    if debug_logging_enabled { fmt.eprintfln("anchor file: %s", any_file_in_project) }

    // Step 1 — fully destroy the previous package cache before building.
    package_import_cache_destroy()
    g_package_import_cache = make(map[string]Package_Symbols)

    // Step 2 — walk the project tree.
    visited_package_dirs := make([dynamic]string)
    defer {
        for dir in visited_package_dirs { delete(dir) }
        delete(visited_package_dirs)
    }

    new_index := index_project(project_root, &visited_package_dirs)

    // Step 3 — eagerly load the package symbols for each visited directory.
    for dir in visited_package_dirs {
        load_package_symbols(dir)
    }

    // Step 4 — swap in the new index and destroy the old one.
    old_index       := g_project_index
    g_project_index  = new_index
    project_index_destroy(&old_index)

    fmt.eprintfln("index build complete (root: %s)", project_root)
}

rebuild_project_index :: proc(trigger_filepath: string) {
    fmt.eprintfln("index rebuild triggered by: %s", trigger_filepath)
    build_project_index(g_project_root, trigger_filepath)
}

// ---------------------------------------------------------------------------
// Completion logic
// ---------------------------------------------------------------------------

// Splits "alias.Name" into ("alias", "Name", true).
// Returns ("", "", false) if there is no dot.
split_at_first_dot :: proc(name: string) -> (before: string, after: string, found: bool) {
    for i := 0; i < len(name); i += 1 {
        if name[i] == '.' { return name[:i], name[i + 1:], true }
    }
    return "", "", false
}

// look_up_package_by_alias safely resolves an import alias to the cached
// Package_Symbols for that package.  Returns nil when the alias is unknown or
// the package dir is no longer in the cache (should not happen in practice
// because the cache is rebuilt before the index, but guard anyway).
//
// FIX: replaces the old pattern of storing ^Package_Symbols directly in the
// index, which produced dangling pointers after a cache rebuild.
look_up_package_by_alias :: proc(alias: string) -> ^Package_Symbols {
    package_dir, ok := g_project_index.imported_package_dirs[alias]
    if !ok { return nil }
    if pkg, found := &g_package_import_cache[package_dir]; found { return pkg }
    return nil
}

// Given the buffer text up to the cursor, produces tab-separated completion
// candidates in the format "word\tmenu" expected by Vim's completefunc.
completions_for_buffer :: proc(buffer: string) -> string {
    // Extract the word being completed (the prefix).
    word_end   := len(buffer)
    word_start := word_end
    for word_start > 0 {
        b := buffer[word_start - 1]
        if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') {
            word_start -= 1
        } else { break }
    }
    completion_prefix := buffer[word_start:word_end]

    // Is there a dot immediately before the prefix?
    dot_pos := word_start - 1
    if dot_pos < 0 || buffer[dot_pos] != '.' {
        return completions_unqualified(completion_prefix)
    }

    // Extract the full dot-separated chain before the final dot.
    chain_end   := dot_pos
    chain_start := chain_end
    for chain_start > 0 {
        b := buffer[chain_start - 1]
        if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') ||
           (b >= '0' && b <= '9') || b == '.' {
            chain_start -= 1
        } else { break }
    }
    dot_chain := buffer[chain_start:chain_end]
    if dot_chain == "" { return "" }

    segments      := strings.split(dot_chain, ".")
    defer delete(segments)
    current_type  := ""
    segment_start := 1

    // Determine the type of the first segment, handling import-alias prefixes.
    if _, is_import := g_project_index.imported_package_dirs[segments[0]]; is_import {
        if len(segments) == 1 {
            return completions_from_package_alias(segments[0], completion_prefix)
        }
        alias     := segments[0]
        type_name := segments[1]
        if pkg := look_up_package_by_alias(alias); pkg != nil {
            if _, is_struct := pkg.structs[type_name]; is_struct {
                current_type  = strings.concatenate({alias, ".", type_name}, context.temp_allocator)
                segment_start = 2
            } else if _, is_enum := pkg.enums[type_name]; is_enum {
                current_type  = strings.concatenate({alias, ".", type_name}, context.temp_allocator)
                segment_start = len(segments)
            }
        }
        if current_type == "" {
            current_type  = resolve_name_to_type(segments[0], buffer)
            segment_start = 1
        }
    } else {
        current_type = resolve_name_to_type(segments[0], buffer)
    }

    if current_type == "" { return "" }

    // Walk remaining segments to dereference field types.
    for i := segment_start; i < len(segments); i += 1 {
        field_name := segments[i]
        if field_name == "" { return "" }

        struct_defn, found := g_project_index.own_structs[current_type]
        if !found {
            if alias, name, has_dot := split_at_first_dot(current_type); has_dot {
                if pkg := look_up_package_by_alias(alias); pkg != nil {
                    struct_defn, found = pkg.structs[name]
                }
            }
            if !found {
                struct_defn, found = g_project_index.all_imported_structs[current_type]
            }
            if !found { return "" }
        }

        next_type := ""
        for f in struct_defn.fields {
            if f.name == field_name { next_type = f.type; break }
        }
        if next_type == "" { return "" }
        current_type = next_type
    }

    return completions_for_type(current_type, completion_prefix, buffer)
}

// Resolves a bare name to its type name by checking the index and local scope.
resolve_name_to_type :: proc(name: string, buffer: string) -> string {
    if name in g_project_index.own_structs          { return name }
    if name in g_project_index.own_enums            { return name }
    if name in g_project_index.all_imported_structs { return name }
    if name in g_project_index.all_imported_enums   { return name }
    if type_name, ok := g_project_index.own_variables[name]; ok { return type_name }
    if type_name, ok := resolve_local_variable_type(buffer, name); ok { return type_name }
    return ""
}

// Scans backward through buffer looking for a local declaration of var_name
// and returns its type if found.
resolve_local_variable_type :: proc(buffer: string, var_name: string) -> (string, bool) {
    is_ident_char :: proc(b: byte) -> bool {
        return b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
    }

    scan_pos := len(buffer)
    for scan_pos > 0 {
        line_end := scan_pos
        scan_pos -= 1
        for scan_pos > 0 && buffer[scan_pos - 1] != '\n' { scan_pos -= 1 }
        line := strings.trim_space(buffer[scan_pos:line_end])

        if !strings.has_prefix(line, var_name)                              { continue }
        if len(line) > len(var_name) && is_ident_char(line[len(var_name)]) { continue }
        rest := strings.trim_left(line[len(var_name):], " \t")

        // Explicit type:  name : TypeName
        if len(rest) > 0 && rest[0] == ':' && (len(rest) == 1 || rest[1] != '=') {
            after_colon := strings.trim_left(rest[1:], " \t")
            end := 0
            for end < len(after_colon) && is_ident_char(after_colon[end]) { end += 1 }
            for end < len(after_colon) && after_colon[end] == '.' {
                end += 1
                seg_start := end
                for end < len(after_colon) && is_ident_char(after_colon[end]) { end += 1 }
                if seg_start == end { break }
            }
            if end > 0 { return after_colon[:end], true }
        }

        // Inferred type from struct literal:  name := TypeName{
        if strings.has_prefix(rest, ":=") {
            after_assign := strings.trim_left(rest[2:], " \t")
            end := 0
            for end < len(after_assign) && is_ident_char(after_assign[end]) { end += 1 }
            for end < len(after_assign) && after_assign[end] == '.' {
                end += 1
                seg_start := end
                for end < len(after_assign) && is_ident_char(after_assign[end]) { end += 1 }
                if seg_start == end { break }
            }
            if end > 0 {
                remainder := strings.trim_left(after_assign[end:], " \t")
                if len(remainder) > 0 && remainder[0] == '{' {
                    return after_assign[:end], true
                }
            }
        }
    }
    return "", false
}

// ---------------------------------------------------------------------------
// Completion formatters
// ---------------------------------------------------------------------------

format_struct_hover :: proc(name: string, defn: Struct_Definition) -> string {
    sb := strings.builder_make()
    strings.write_string(&sb, "struct ")
    strings.write_string(&sb, name)
    strings.write_string(&sb, " {\n")
    for f in defn.fields {
        strings.write_string(&sb, indent_spaces)
        strings.write_string(&sb, f.name)
        strings.write_string(&sb, ": ")
        strings.write_string(&sb, f.type)
        strings.write_string(&sb, ",\n")
    }
    strings.write_string(&sb, "}")
    return strings.to_string(sb)
}

format_enum_hover :: proc(name: string, defn: Enum_Definition) -> string {
    sb := strings.builder_make()
    strings.write_string(&sb, "enum ")
    strings.write_string(&sb, name)
    strings.write_string(&sb, " {\n")
    for v in defn.values {
        strings.write_string(&sb, indent_spaces)
        strings.write_string(&sb, v)
        strings.write_string(&sb, ",\n")
    }
    strings.write_string(&sb, "}")
    return strings.to_string(sb)
}

hover_info_for_symbol :: proc(symbol: string) -> string {
    if defn, ok := g_project_index.own_structs[symbol];          ok { return format_struct_hover(symbol, defn) }
    if defn, ok := g_project_index.own_enums[symbol];            ok { return format_enum_hover(symbol, defn)   }
    if defn, ok := g_project_index.all_imported_structs[symbol]; ok { return format_struct_hover(symbol, defn) }
    if defn, ok := g_project_index.all_imported_enums[symbol];   ok { return format_enum_hover(symbol, defn)   }
    if type_name, ok := g_project_index.own_variables[symbol];   ok { return fmt.tprintf("%s: %s", symbol, type_name) }
    return ""
}

completions_from_package_alias :: proc(package_alias: string, prefix: string) -> string {
    pkg := look_up_package_by_alias(package_alias)
    if pkg == nil { return "" }

    sb := strings.builder_make()
    for name in pkg.structs {
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_byte(&sb, '\t')
            strings.write_string(&sb, package_alias)
            strings.write_byte(&sb, '\n')
        }
    }
    for name in pkg.enums {
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_byte(&sb, '\t')
            strings.write_string(&sb, package_alias)
            strings.write_byte(&sb, '\n')
        }
    }
    return strings.trim_right(strings.to_string(sb), "\n")
}

completions_unqualified :: proc(prefix: string) -> string {
    sb := strings.builder_make()

    for name in g_project_index.own_structs {
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_string(&sb, "\t\n")
        }
    }
    for name in g_project_index.own_enums {
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_string(&sb, "\t\n")
        }
    }
    for name in g_project_index.all_imported_structs {
        if name in g_project_index.own_structs { continue }
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_string(&sb, "\timport\n")
        }
    }
    for name in g_project_index.all_imported_enums {
        if name in g_project_index.own_enums { continue }
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_string(&sb, "\timport\n")
        }
    }
    for name, type_name in g_project_index.own_variables {
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_byte(&sb, '\t')
            strings.write_string(&sb, type_name)
            strings.write_byte(&sb, '\n')
        }
    }

    return strings.trim_right(strings.to_string(sb), "\n")
}

completions_for_type :: proc(type_name: string, prefix: string, buffer: string) -> string {
    // Qualified type from an imported package, e.g. "fmt.Formatter".
    if alias, name, has_dot := split_at_first_dot(type_name); has_dot {
        if pkg := look_up_package_by_alias(alias); pkg != nil {
            if defn, is_struct := pkg.structs[name]; is_struct {
                sb := strings.builder_make()
                for f in defn.fields {
                    if strings.has_prefix(f.name, prefix) {
                        strings.write_string(&sb, f.name)
                        strings.write_byte(&sb, '\t')
                        strings.write_string(&sb, f.type)
                        strings.write_byte(&sb, '\n')
                    }
                }
                return strings.trim_right(strings.to_string(sb), "\n")
            }
            if defn, is_enum := pkg.enums[name]; is_enum {
                sb := strings.builder_make()
                for v in defn.values {
                    if strings.has_prefix(v, prefix) {
                        strings.write_string(&sb, v)
                        strings.write_byte(&sb, '\t')
                        strings.write_string(&sb, type_name)
                        strings.write_byte(&sb, '\n')
                    }
                }
                return strings.trim_right(strings.to_string(sb), "\n")
            }
        }
    }

    sb := strings.builder_make()

    write_struct_field_completions :: proc(sb: ^strings.Builder, defn: Struct_Definition, prefix: string) {
        for f in defn.fields {
            if strings.has_prefix(f.name, prefix) {
                strings.write_string(sb, f.name)
                strings.write_byte(sb, '\t')
                strings.write_string(sb, f.type)
                strings.write_byte(sb, '\n')
            }
        }
    }
    write_enum_value_completions :: proc(sb: ^strings.Builder, defn: Enum_Definition, prefix: string, type_name: string) {
        for v in defn.values {
            if strings.has_prefix(v, prefix) {
                strings.write_string(sb, v)
                strings.write_byte(sb, '\t')
                strings.write_string(sb, type_name)
                strings.write_byte(sb, '\n')
            }
        }
    }

    if defn, ok := g_project_index.own_structs[type_name];          ok { write_struct_field_completions(&sb, defn, prefix)            } else
    if defn, ok := g_project_index.own_enums[type_name];            ok { write_enum_value_completions(&sb, defn, prefix, type_name)   } else
    if defn, ok := g_project_index.all_imported_structs[type_name]; ok { write_struct_field_completions(&sb, defn, prefix)            } else
    if defn, ok := g_project_index.all_imported_enums[type_name];   ok { write_enum_value_completions(&sb, defn, prefix, type_name)   }

    return strings.trim_right(strings.to_string(sb), "\n")
}

// ---------------------------------------------------------------------------
// Framing — 4-byte big-endian length prefix over a Unix socket
// ---------------------------------------------------------------------------

MAX_FRAME_BYTES :: 4 * 1024 * 1024

fd_read_exactly :: proc(fd: posix.FD, buf: []u8) -> bool {
    total := 0
    for total < len(buf) {
        n := posix.read(fd, &buf[total], uint(len(buf) - uint(total)))
        if n <= 0 { return false }
        total += n
    }
    return true
}

fd_write_all :: proc(fd: posix.FD, buf: []u8) -> bool {
    total := 0
    for total < len(buf) {
        n := posix.write(fd, &buf[total], uint(len(buf) - uint(total)))
        if n <= 0 { return false }
        total += n
    }
    return true
}

// write_framed_message sends a 4-byte big-endian length header followed by the
// message body.  Returns false if the write fails (e.g. the client closed the
// connection).  SIGPIPE is ignored at daemon startup so a broken-pipe write
// returns -1 instead of killing the process.
write_framed_message :: proc(fd: posix.FD, msg: string) -> bool {
    if debug_logging_enabled {
        preview := msg if len(msg) <= 64 else msg[:64]
        fmt.eprintfln("-> frame len=%d msg=%q", len(msg), preview)
    }
    body     := transmute([]u8)msg
    body_len := u32(len(body))
    header   := [4]u8{u8(body_len >> 24), u8(body_len >> 16), u8(body_len >> 8), u8(body_len)}
    if !fd_write_all(fd, header[:]) { return false }
    if !fd_write_all(fd, body)      { return false }
    return true
}

read_framed_message :: proc(fd: posix.FD, allocator := context.allocator) -> (string, bool) {
    header: [4]u8
    if !fd_read_exactly(fd, header[:]) { return "", false }

    body_len := u32(header[0]) << 24 | u32(header[1]) << 16 | u32(header[2]) << 8 | u32(header[3])
    if body_len > MAX_FRAME_BYTES { return "", false }
    if body_len == 0              { return "", true  }

    body := make([]u8, body_len, allocator)
    if !fd_read_exactly(fd, body) {
        delete(body, allocator)
        return "", false
    }

    msg := string(body)
    if debug_logging_enabled {
        preview := msg if len(msg) <= 80 else msg[:80]
        fmt.eprintfln("<- frame len=%d preview=%q", len(msg), preview)
    }
    return msg, true
}

// ---------------------------------------------------------------------------
// Unix socket helpers
// ---------------------------------------------------------------------------

SOCKET_DIR    :: "/tmp"
SOCKET_PREFIX :: "gjallarhorn_"

// Produces a unique socket path for a given project directory by hashing it.
socket_path_for_dir :: proc(project_dir: string, allocator := context.allocator) -> string {
    ctx: md5.Context
    md5.init(&ctx)
    md5.update(&ctx, transmute([]u8)project_dir)
    digest: [md5.DIGEST_SIZE]u8
    md5.final(&ctx, digest[:])

    hash_hex := hex.encode(digest[:], allocator)
    defer delete(hash_hex, allocator)

    return strings.join({SOCKET_DIR, "/", SOCKET_PREFIX, string(hash_hex), ".sock"}, "", allocator)
}

make_unix_socket_addr :: proc(socket_path: string) -> posix.sockaddr_un {
    addr: posix.sockaddr_un
    addr.sun_family = .UNIX
    when ODIN_OS == .Darwin {
        addr.sun_len = u8(size_of(addr))
    }
    copy(addr.sun_path[:], socket_path)
    return addr
}

daemon_is_reachable :: proc(socket_path: string) -> bool {
    fd := posix.socket(.UNIX, .STREAM)
    if int(fd) < 0 { return false }
    defer posix.close(fd)

    addr := make_unix_socket_addr(socket_path)
    if posix.connect(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr))) == .FAIL {
        return false
    }

    if !write_framed_message(fd, "__gh::hello__") { return false }
    response, ok := read_framed_message(fd, context.temp_allocator)
    if !ok { return false }

    if strings.has_prefix(response, "gjallarhorn/") {
        version := strings.trim_prefix(response, "gjallarhorn/")
        if version == "1" { return true }
    }
    fmt.eprintfln("gjallarhorn: handshake mismatch from daemon at %s", socket_path)
    return false
}

// ---------------------------------------------------------------------------
// Signal handling — clean shutdown on SIGTERM / SIGINT
// ---------------------------------------------------------------------------

// signal_shutdown_handler is installed for both SIGTERM and SIGINT.
// It unlinks the Unix socket so no stale socket file is left behind, then
// exits with code 0.  g_socket_path_c must be set before the handler is
// registered.
signal_shutdown_handler :: proc "c" (sig: posix.Signal) {
    if g_socket_path_c != nil {
        posix.unlink(g_socket_path_c)
    }
    posix.exit(0)
}

// install_signal_handlers sets up:
//   SIGPIPE  → SIG_IGN  (broken pipe on a client write must not kill the daemon)
//   SIGTERM  → signal_shutdown_handler
//   SIGINT   → signal_shutdown_handler
install_signal_handlers :: proc() {
    act: posix.sigaction_t
    act.sa_handler = auto_cast posix.SIG_IGN
    posix.sigaction(.SIGPIPE, &act, nil)

    act.sa_handler = signal_shutdown_handler
    posix.sigaction(.SIGTERM, &act, nil)
    posix.sigaction(.SIGINT,  &act, nil)
}

// ---------------------------------------------------------------------------
// Daemon — listens on the Unix socket and serves requests
// ---------------------------------------------------------------------------

daemon_start :: proc(initial_filepath: string) {
    install_signal_handlers()

    source_dir   := path_parent_dir(initial_filepath)
    defer delete(source_dir)

    project_root := find_project_root(source_dir)
    defer delete(project_root)

    socket_path := socket_path_for_dir(project_root)
    defer delete(socket_path)

    socket_path_c := strings.clone_to_cstring(socket_path)
    // Stored in the global so the signal handler can reach it.
    // Not deferred-deleted: the signal handler may fire at any point after this.
    g_socket_path_c = socket_path_c

    if daemon_is_reachable(socket_path) {
        fmt.eprintln("gjallarhorn: daemon already running")
        os.exit(1)
    }
    posix.unlink(socket_path_c)

    server_fd := posix.socket(.UNIX, .STREAM)
    if int(server_fd) < 0 {
        fmt.eprintfln("gjallarhorn: socket() failed: %v", posix.errno())
        os.exit(1)
    }

    addr := make_unix_socket_addr(socket_path)
    if posix.bind(server_fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr))) == .FAIL {
        fmt.eprintfln("gjallarhorn: bind() failed: %v", posix.errno())
        os.exit(1)
    }
    if posix.listen(server_fd, 8) == .FAIL {
        fmt.eprintfln("gjallarhorn: listen() failed: %v", posix.errno())
        os.exit(1)
    }

    if debug_logging_enabled { fmt.eprintfln("daemon listening on %s", socket_path) }

    // Build the initial index now that we know the project root.
    build_project_index(project_root, initial_filepath)

    // Store the project root globally so index rebuilds can use it.
    g_project_root = strings.clone(project_root)

    daemon_serve(server_fd)
}

// daemon_serve is the main accept loop.  It tolerates EINTR (delivered when a
// signal handler runs) by retrying rather than treating it as fatal.
daemon_serve :: proc(server_fd: posix.FD) {
    for {
        client_fd := posix.accept(server_fd, nil, nil)
        if int(client_fd) < 0 {
            err := posix.errno()
            if err == .EINTR {
                if debug_logging_enabled { fmt.eprintln("daemon_serve: accept interrupted by signal, retrying") }
                continue
            }
            fmt.eprintfln("gjallarhorn: accept() failed: %v", err)
            continue  // log and keep serving; don't tear down the whole daemon
        }
        handle_client_request(client_fd)
        posix.close(client_fd)
    }
}

handle_client_request :: proc(client_fd: posix.FD) {
    command, ok := read_framed_message(client_fd)
    if !ok {
        fmt.eprintln("gjallarhorn: protocol error: failed to read command frame")
        return
    }
    defer delete(command)

    if debug_logging_enabled { fmt.eprintfln("recv command: %s", command) }

    switch command {
    case "comp":
        buffer, buf_ok := read_framed_message(client_fd)
        if !buf_ok {
            fmt.eprintln("gjallarhorn: protocol error: failed to read buffer frame for comp")
            return
        }
        defer delete(buffer)
        result := completions_for_buffer(buffer)
        defer delete(result)
        if !write_framed_message(client_fd, result) {
            fmt.eprintln("gjallarhorn: write error sending comp response (client disconnected?)")
        }

    case "index":
        filepath, path_ok := read_framed_message(client_fd)
        if !path_ok {
            fmt.eprintln("gjallarhorn: protocol error: failed to read filepath frame for index")
            return
        }
        defer delete(filepath)
        rebuild_project_index(filepath)
        if !write_framed_message(client_fd, "") {
            fmt.eprintln("gjallarhorn: write error sending index ack (client disconnected?)")
        }

    case "hover":
        symbol, sym_ok := read_framed_message(client_fd)
        if !sym_ok {
            fmt.eprintln("gjallarhorn: protocol error: failed to read symbol frame for hover")
            return
        }
        defer delete(symbol)
        result := hover_info_for_symbol(symbol)
        defer delete(result)
        if !write_framed_message(client_fd, result) {
            fmt.eprintln("gjallarhorn: write error sending hover response (client disconnected?)")
        }

    case "__gh::hello__":
        if !write_framed_message(client_fd, "gjallarhorn/1") {
            fmt.eprintln("gjallarhorn: write error sending handshake response")
        }

    case:
        fmt.eprintfln("gjallarhorn: protocol error: unknown command: %q", command)
        if !write_framed_message(client_fd, "") {
            fmt.eprintln("gjallarhorn: write error sending error response (client disconnected?)")
        }
    }
}

// ---------------------------------------------------------------------------
// Client — connects to the daemon and dispatches a single request
// ---------------------------------------------------------------------------

// client_connect resolves the project root from source_filepath, hashes it to
// find the daemon's socket path, and returns an open connected file descriptor.
client_connect :: proc(source_filepath: string) -> (posix.FD, bool) {
    source_dir   := path_parent_dir(source_filepath)
    defer delete(source_dir)

    project_root := find_project_root(source_dir)
    defer delete(project_root)

    socket_path := socket_path_for_dir(project_root)
    defer delete(socket_path)

    fd := posix.socket(.UNIX, .STREAM)
    if int(fd) < 0 {
        fmt.eprintfln("gjallarhorn: socket() failed: %v", posix.errno())
        return 0, false
    }

    addr := make_unix_socket_addr(socket_path)
    if posix.connect(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr))) == .FAIL {
        fmt.eprintfln("gjallarhorn: could not connect to daemon at %s", socket_path)
        posix.close(fd)
        return 0, false
    }
    return fd, true
}

request_completions :: proc(source_filepath: string, buffer_text: string) {
    fd, ok := client_connect(source_filepath)
    if !ok { fmt.eprintln("gjallarhorn: cannot connect to daemon"); os.exit(2) }
    defer posix.close(fd)

    if !write_framed_message(fd, "comp") ||
       !write_framed_message(fd, buffer_text) {
        fmt.eprintln("gjallarhorn: failed to send comp request")
        os.exit(3)
    }

    response, resp_ok := read_framed_message(fd)
    if !resp_ok { fmt.eprintln("gjallarhorn: daemon returned invalid frame"); os.exit(3) }
    defer delete(response)

    if len(response) > 0 { fmt.print(response) }
}

request_index_rebuild :: proc(source_filepath: string) {
    fd, ok := client_connect(source_filepath)
    if !ok { fmt.eprintln("gjallarhorn: cannot connect to daemon"); os.exit(2) }
    defer posix.close(fd)

    if !write_framed_message(fd, "index") ||
       !write_framed_message(fd, source_filepath) {
        fmt.eprintln("gjallarhorn: failed to send index request")
        os.exit(3)
    }

    response, resp_ok := read_framed_message(fd)
    if !resp_ok { fmt.eprintln("gjallarhorn: index rebuild failed (no response from daemon)"); os.exit(3) }
    delete(response)
}

request_hover_info :: proc(source_filepath: string, symbol: string) {
    fd, ok := client_connect(source_filepath)
    if !ok { fmt.eprintln("gjallarhorn: cannot connect to daemon"); os.exit(2) }
    defer posix.close(fd)

    if !write_framed_message(fd, "hover") ||
       !write_framed_message(fd, symbol) {
        fmt.eprintln("gjallarhorn: failed to send hover request")
        os.exit(3)
    }

    response, resp_ok := read_framed_message(fd)
    if !resp_ok { fmt.eprintln("gjallarhorn: daemon returned invalid frame"); os.exit(3) }
    defer delete(response)

    fmt.print(response)
    fmt.print("\n")
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

main :: proc() {
    if len(os.args) < 3 { print_usage(); os.exit(1) }

    if env_val, env_ok := os.lookup_env_alloc("GJALLARHORN_DEBUG", context.allocator); env_ok {
        debug_logging_enabled = env_val == "1"
        delete(env_val, context.allocator)
    }

    switch os.args[1] {
    case "--daemon":
        daemon_start(os.args[2])

    case "--comp":
        if len(os.args) < 4 { print_usage(); os.exit(1) }
        request_completions(os.args[2], os.args[3])

    case "--hover":
        if len(os.args) < 4 { print_usage(); os.exit(1) }
        request_hover_info(os.args[2], os.args[3])

    case "--index":
        request_index_rebuild(os.args[2])

    case:
        print_usage()
        os.exit(1)
    }
}

print_usage :: proc() {
    fmt.eprintln("gjallarhorn — Odin completion daemon")
    fmt.eprintln("  gjallarhorn --daemon <absolute_filepath>")
    fmt.eprintln("  gjallarhorn --comp   <absolute_filepath> <buffer_text_up_to_cursor>")
    fmt.eprintln("  gjallarhorn --hover  <absolute_filepath> <symbol>")
    fmt.eprintln("  gjallarhorn --index  <absolute_filepath>")
}
