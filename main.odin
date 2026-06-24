package gjallarhorn

import "core:crypto/legacy/md5"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:mem"
import "core:unicode/utf8"

indent_spaces : string = "    "

g_project_root  : string
g_socket_path_c : cstring

project_root_markers        : = [3]string{".git", ".editorconfig", "gjallar.horn"}
dirs_excluded_from_indexing :: []string{"vendor"}

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

Package_Symbols :: struct {
    structs : map[string]Struct_Definition,
    enums   : map[string]Enum_Definition,
}

g_package_cache  : map[string]Package_Symbols
g_odin_root      : string

Project_Index :: struct {
    own_structs              : map[string]Struct_Definition,
    own_enums                : map[string]Enum_Definition,
    own_variables            : map[string]string,
    import_aliases           : map[string]string,
    imported_package_dirs    : map[string]string,
    all_imported_structs     : map[string]Struct_Definition,
    all_imported_enums       : map[string]Enum_Definition,
    imported_struct_sources  : map[string]string,
    imported_enum_sources    : map[string]string,
    imported_struct_conflicts: map[string][dynamic]string,
    imported_enum_conflicts  : map[string][dynamic]string,
}

g_persistent_allocator: mem.Allocator
g_index : Project_Index

make_project_index :: proc() -> Project_Index {
    return Project_Index{
        own_structs              = make(map[string]Struct_Definition),
        own_enums                = make(map[string]Enum_Definition),
        own_variables            = make(map[string]string),
        import_aliases           = make(map[string]string),
        imported_package_dirs    = make(map[string]string),
        all_imported_structs     = make(map[string]Struct_Definition),
        all_imported_enums       = make(map[string]Enum_Definition),
        imported_struct_sources  = make(map[string]string),
        imported_enum_sources    = make(map[string]string),
        imported_struct_conflicts= make(map[string][dynamic]string),
        imported_enum_conflicts  = make(map[string][dynamic]string),
    }
}

Token_Kind :: enum { EOF, Identifier, String_Literal, Double_Colon, Open_Brace, Close_Brace, Comma, Colon, Other }

Token :: struct { kind: Token_Kind, text: string }
Lexer :: struct { src:  string,     pos:  int    }

lexer_make :: proc(src: string) -> Lexer { return {src = src} }

lexer_skip_whitespace_and_comments :: proc(l: ^Lexer) {
    for l.pos < len(l.src) {
        c := l.src[l.pos]
        if c == ' ' || c == '\t' || c == '\r' || c == '\n' { l.pos += 1; continue }

        if c == '/' && l.pos + 1 < len(l.src) {
            if l.src[l.pos + 1] == '/' {
                for l.pos < len(l.src) && l.src[l.pos] != '\n' { l.pos += 1 }
                continue
            }
            if l.src[l.pos + 1] == '*' {
                l.pos += 2
                found_close := false
                for l.pos + 1 < len(l.src) {
                    if l.src[l.pos] == '*' && l.src[l.pos + 1] == '/' {
                        l.pos += 2
                        found_close = true
                        break
                    }
                    l.pos += 1
                }
                if !found_close {
                    l.pos = len(l.src)
                }
                continue
            }
        }
        break
    }
}

lexer_next :: proc(l: ^Lexer) -> Token {
    lexer_skip_whitespace_and_comments(l)
    if l.pos >= len(l.src) { return {kind = .EOF} }

    c := l.src[l.pos]

    if c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
        start := l.pos
        for l.pos < len(l.src) {
            b := l.src[l.pos]
            if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') {
                l.pos += 1
            } else { break }
        }
        return {kind = .Identifier, text = l.src[start:l.pos]}
    }

    if c == ':' {
        if l.pos + 1 < len(l.src) && l.src[l.pos + 1] == ':' { l.pos += 2; return {kind = .Double_Colon, text = "::"} }
        l.pos += 1
        return {kind = .Colon, text = ":"}
    }

    if c == '"' {
        l.pos += 1
        start := l.pos
        for l.pos < len(l.src) && l.src[l.pos] != '"' {
            if l.src[l.pos] == '\\' { l.pos += 1 }
            l.pos += 1
        }
        text := l.src[start:l.pos]
        if l.pos < len(l.src) { l.pos += 1 }
        return {kind = .String_Literal, text = text}
    }

    if c == '{' { l.pos += 1; return {kind = .Open_Brace,  text = "{"} }
    if c == '}' { l.pos += 1; return {kind = .Close_Brace, text = "}"} }
    if c == ',' { l.pos += 1; return {kind = .Comma,       text = ","} }

    start := l.pos
    _, w  := utf8.decode_rune_in_string(l.src[l.pos:])
    l.pos += w
    return {kind = .Other, text = l.src[start:l.pos]}
}

lexer_peek :: proc(l: ^Lexer) -> Token {
    saved := l.pos
    tok   := lexer_next(l)
    l.pos  = saved
    return tok
}

dir_contains_root_marker :: proc(dir: string) -> bool {
    entries, err := os.read_all_directory_by_path(dir, context.allocator)
    if err != nil { return false }
    defer os.file_info_slice_delete(entries, context.allocator)
    for e in entries {
        for m in project_root_markers { if e.name == m { return true } }
    }
    return false
}

find_project_root :: proc(start_dir: string, allocator := context.allocator) -> string {
    current := strings.clone(start_dir, context.allocator)
    for {
        if dir_contains_root_marker(current) { return strings.clone(current, allocator) }

        end := len(current) - 1
        for end > 0 && current[end] == '/' { end -= 1 }

        slash := -1
        for i := end; i >= 0; i -= 1 { if current[i] == '/' { slash = i; break } }
        if slash <= 0 { break }
        
        next := strings.clone(current[:slash], context.allocator)
        delete(current, context.allocator)
        current = next
    }
    return strings.clone(start_dir, allocator)
}

derive_import_alias :: proc(path: string) -> string {
    last := -1
    for i := 0; i < len(path); i += 1 {
        if path[i] == ':' || path[i] == '/' { last = i }
    }
    if last == -1 { return path }
    return path[last + 1:]
}

parse_dotted_type_name :: proc(l: ^Lexer, first: string) -> string {
    parts := make([dynamic]string, context.allocator)
    defer delete(parts)
    append(&parts, first)
    for {
        pk := lexer_peek(l)
        if pk.kind != .Other || pk.text != "." { break }
        lexer_next(l)
        name := lexer_next(l)
        if name.kind != .Identifier { break }
        append(&parts, ".")
        append(&parts, name.text)
    }
    return strings.join(parts[:], "")
}

parse_source_file :: proc(src: string) -> Project_Index {
    idx   := make_project_index()
    l     := lexer_make(src)
    depth := 0

    for {
        tok := lexer_next(&l)
        if tok.kind == .EOF { break }
        if tok.kind == .Other {
            if tok.text == "(" { depth += 1 }
            if tok.text == ")" && depth > 0 { depth -= 1 }
            continue
        }
        if tok.kind != .Identifier || depth > 0 { continue }

        name := tok.text

        if name == "import" {
            peek := lexer_peek(&l)
            alias, path: string
            if peek.kind == .String_Literal {
                lexer_next(&l); path = peek.text; alias = derive_import_alias(path)
            } else if peek.kind == .Identifier || (peek.kind == .Other && peek.text == ".") {
                a := lexer_next(&l); alias = a.text
                p := lexer_next(&l); if p.kind == .String_Literal { path = p.text }
            }
            if alias != "_" && alias != "" && path != "" {
                idx.import_aliases[strings.clone(alias)] = strings.clone(path)
            }
            continue
        }

        next := lexer_peek(&l)

        if next.kind == .Double_Colon {
            lexer_next(&l)
            after := lexer_peek(&l)
            if after.kind != .Identifier { continue }
            switch after.text {
            case "struct":
                lexer_next(&l)
                idx.own_structs[strings.clone(name)] = parse_struct_body(&l)
            case "enum":
                lexer_next(&l)
                idx.own_enums[strings.clone(name)] = parse_enum_body(&l)
            case:
                lexer_next(&l)
                idx.own_variables[strings.clone(name)] = parse_dotted_type_name(&l, after.text)
            }
            continue
        }

        if next.kind == .Colon {
            lexer_next(&l)
            type_tok := lexer_peek(&l)
            if type_tok.kind == .Identifier {
                lexer_next(&l)
                idx.own_variables[strings.clone(name)] = parse_dotted_type_name(&l, type_tok.text)
            }
        }
    }

    return idx
}

parse_struct_body :: proc(l: ^Lexer) -> Struct_Definition {
    defn  := Struct_Definition{fields = make([dynamic]Struct_Field)}
    depth := 0
    for { tok := lexer_next(l); if tok.kind == .EOF { return defn }; if tok.kind == .Open_Brace { depth = 1; break } }

    for depth > 0 {
        tok := lexer_next(l)
        #partial switch tok.kind {
        case .EOF:        return defn
        case .Open_Brace: depth += 1
        case .Close_Brace:depth -= 1
        case .Identifier:
            if depth != 1 { continue }
            field_name := tok.text
            if lexer_peek(l).kind != .Colon { continue }
            lexer_next(l)

            parts := make([dynamic]string, context.allocator)
            defer delete(parts)
            for {
                pk := lexer_peek(l)
                if pk.kind == .EOF || pk.kind == .Comma || pk.kind == .Close_Brace { break }
                if pk.kind == .Identifier {
                    saved := l.pos; lexer_next(l)
                    is_next_colon := lexer_peek(l).kind == .Colon
                    l.pos = saved
                    if is_next_colon { break }
                }
                t := lexer_next(l)
                if t.text != "" { append(&parts, t.text) }
            }
            if lexer_peek(l).kind == .Comma { lexer_next(l) }

            append(&defn.fields, Struct_Field{
                name = strings.clone(field_name),
                type = strings.join(parts[:], ""),
            })
        case:
        }
    }
    return defn
}

parse_enum_body :: proc(l: ^Lexer) -> Enum_Definition {
    defn := Enum_Definition{values = make([dynamic]string)}
    for { tok := lexer_next(l); if tok.kind == .EOF { return defn }; if tok.kind == .Open_Brace { break } }
    for {
        tok := lexer_next(l)
        #partial switch tok.kind {
        case .EOF, .Close_Brace: return defn
        case .Identifier:
            append(&defn.values, strings.clone(tok.text))
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

get_odin_root :: proc() -> (string, bool) {
    if g_odin_root != "" { return g_odin_root, true }

    saved := context.allocator
    context.allocator = g_persistent_allocator
    defer context.allocator = saved

    env, found := os.lookup_env_alloc("ODIN_ROOT", context.allocator)
    if found && env != "" {
        root := env
        if root[len(root) - 1] == '/' { root = root[:len(root) - 1] }
        g_odin_root = strings.clone(root)
        delete(env)
        return g_odin_root, true
    }
    if found { delete(env) }

    state, stdout, stderr, err := os.process_exec({command = {"odin", "root"}}, context.allocator)
    if err != nil || !state.success { delete(stdout); delete(stderr); return "", false }
    delete(stderr)

    root := strings.trim_space(string(stdout))
    if len(root) > 0 && root[len(root) - 1] == '/' { root = root[:len(root) - 1] }
    g_odin_root = strings.clone(root)
    delete(stdout)
    return g_odin_root, true
}

resolve_import_to_dir :: proc(import_path: string, source_file: string) -> (string, bool) {
    colon := -1
    for i := 0; i < len(import_path); i += 1 { if import_path[i] == ':' { colon = i; break } }

    if colon != -1 {
        root, ok := get_odin_root()
        if !ok { return "", false }
        return strings.concatenate({root, "/", import_path[:colon], "/", import_path[colon + 1:]}), true
    }

    source_dir := path_parent_dir(source_file, g_persistent_allocator)
    defer delete(source_dir, g_persistent_allocator)
    return strings.concatenate({source_dir, "/", import_path}), true
}

load_package_symbols :: proc(package_dir: string) {
    if package_dir in g_package_cache { return }

    pkg := Package_Symbols{
        structs = make(map[string]Struct_Definition),
        enums   = make(map[string]Enum_Definition),
    }

    type_aliases := make(map[string]string)

    file_infos, err := os.read_all_directory_by_path(package_dir, context.allocator)
    if err != nil { g_package_cache[package_dir] = pkg; return }
    defer os.file_info_slice_delete(file_infos, context.allocator)

    for fi in file_infos {
        if fi.type == .Directory                       { continue }
        if !strings.has_suffix(fi.name, ".odin")      { continue }
        if  strings.has_suffix(fi.name, "_test.odin") { continue }

        full_path := strings.concatenate({package_dir, "/", fi.name}, context.allocator)
        src_data, read_err := os.read_entire_file_from_path(full_path, context.allocator)
        delete(full_path, context.allocator)
        if read_err != nil { continue }

        file_idx := parse_source_file(string(src_data))
        delete(src_data, context.allocator)

        for k, &s in file_idx.own_structs {
            pkg.structs[k] = s
        }
        for k, &e in file_idx.own_enums {
            pkg.enums[k] = e
        }
        for k, v in file_idx.own_variables {
            type_aliases[k] = v
        }
    }

    follow_alias_chain :: proc(aliases: map[string]string, start: string) -> string {
        current := start
        for hops := 0; hops < 100; hops += 1 {
            next, ok := aliases[current]; if !ok { return current }; current = next
        }
        return current
    }

    for alias_name, target in type_aliases {
        if len(alias_name) == 0 || alias_name[0] < 'A' || alias_name[0] > 'Z' { continue }
        resolved := follow_alias_chain(type_aliases, target)

        if entry, ok := pkg.structs[resolved]; ok {
            copy := Struct_Definition{fields = make([dynamic]Struct_Field, len(entry.fields))}
            for &f, i in entry.fields { copy.fields[i] = {name = strings.clone(f.name), type = strings.clone(f.type)} }
            pkg.structs[strings.clone(alias_name)] = copy
        } else if entry, ok := pkg.enums[resolved]; ok {
            copy := Enum_Definition{values = make([dynamic]string, len(entry.values))}
            for v, i in entry.values { copy.values[i] = strings.clone(v) }
            pkg.enums[strings.clone(alias_name)] = copy
        }
    }

    g_package_cache[package_dir] = pkg
}

register_package_into_index :: proc(idx: ^Project_Index, alias: string, package_dir: string) {
    cached, ok := g_package_cache[package_dir]
    if !ok { return }
    if alias != "." { idx.imported_package_dirs[strings.clone(alias)] = strings.clone(package_dir) }
    for name, defn in cached.structs {
        if name not_in idx.own_structs {
            if name not_in idx.all_imported_structs {
                idx.all_imported_structs[name] = defn
                idx.imported_struct_sources[strings.clone(name)] = strings.clone(alias)
            } else {
                if name not_in idx.imported_struct_conflicts {
                    idx.imported_struct_conflicts[strings.clone(name)] = make([dynamic]string)
                    append(&idx.imported_struct_conflicts[name], strings.clone(idx.imported_struct_sources[name]))
                    append(&idx.imported_struct_conflicts[name], strings.clone(alias))
                } else {
                    append(&idx.imported_struct_conflicts[name], strings.clone(alias))
                }
            }
        }
    }
    for name, defn in cached.enums {
        if name not_in idx.own_enums {
            if name not_in idx.all_imported_enums {
                idx.all_imported_enums[name] = defn
                idx.imported_enum_sources[strings.clone(name)] = strings.clone(alias)
            } else {
                if name not_in idx.imported_enum_conflicts {
                    idx.imported_enum_conflicts[strings.clone(name)] = make([dynamic]string)
                    append(&idx.imported_enum_conflicts[name], strings.clone(idx.imported_enum_sources[name]))
                    append(&idx.imported_enum_conflicts[name], strings.clone(alias))
                } else {
                    append(&idx.imported_enum_conflicts[name], strings.clone(alias))
                }
            }
        }
    }
}

resolve_and_load_imports :: proc(idx: ^Project_Index, source_file: string) {
    for alias, import_path in idx.import_aliases {
        if alias == "_" { continue }
        package_dir, ok := resolve_import_to_dir(import_path, source_file)
        if !ok { continue }
        load_package_symbols(package_dir)
        register_package_into_index(idx, alias, package_dir)
    }
}

dir_should_be_skipped :: proc(name: string) -> bool {
    if len(name) > 0 && name[0] == '.' { return true }
    for excluded in dirs_excluded_from_indexing { if name == excluded { return true } }
    return false
}

index_directory :: proc(idx: ^Project_Index, dir_path: string) -> bool {
    file_infos, err := os.read_all_directory_by_path(dir_path, context.allocator)
    if err != nil { return false }
    defer os.file_info_slice_delete(file_infos, context.allocator)

    found := false
    for fi in file_infos {
        if fi.type == .Directory                       { continue }
        if !strings.has_suffix(fi.name, ".odin")      { continue }
        if  strings.has_suffix(fi.name, "_test.odin") { continue }

        full_path := strings.concatenate({dir_path, "/", fi.name}, context.allocator)
        src_data, read_err := os.read_entire_file_from_path(full_path, context.allocator)
        delete(full_path, context.allocator)
        if read_err != nil { continue }

        file_idx := parse_source_file(string(src_data))
        merge_file_into_index(idx, &file_idx)
        delete(src_data, context.allocator)
        found = true
    }

    return found
}

index_project_tree :: proc(project_root: string, visited_dirs: ^[dynamic]string) -> Project_Index {
    idx       := make_project_index()
    dir_stack := make([dynamic]string, context.allocator)
    append(&dir_stack, strings.clone(project_root, context.allocator))

    for len(dir_stack) > 0 {
        current := dir_stack[len(dir_stack) - 1]
        pop(&dir_stack)

        if index_directory(&idx, current) { append(visited_dirs, strings.clone(current, context.allocator)) }

        sub_entries, sub_err := os.read_all_directory_by_path(current, context.allocator)
        if sub_err != nil { continue }
        for e in sub_entries {
            if e.type != .Directory || dir_should_be_skipped(e.name) { continue }
            path := strings.concatenate({current, "/", e.name}, context.allocator)
            append(&dir_stack, path)
        }
        os.file_info_slice_delete(sub_entries, context.allocator)
    }

    for dir in visited_dirs^ {
        sentinel := strings.concatenate({dir, "/_sentinel.odin"}, context.allocator)
        resolve_and_load_imports(&idx, sentinel)
    }

    return idx
}

merge_file_into_index :: proc(idx: ^Project_Index, file_idx: ^Project_Index) {
    for k, &s in file_idx.own_structs {
        idx.own_structs[k] = s
    }

    for k, &e in file_idx.own_enums {
        idx.own_enums[k] = e
    }

    for k, v in file_idx.own_variables {
        idx.own_variables[k] = v
    }

    for k, v in file_idx.import_aliases {
        idx.import_aliases[k] = v
    }
}

path_parent_dir :: proc(file_path: string, allocator := context.allocator) -> string {
    for i := len(file_path) - 1; i >= 0; i -= 1 {
        if file_path[i] == '/' {
            if i == 0 { return strings.clone("/", allocator) }
            return strings.clone(file_path[:i], allocator)
        }
    }
    return strings.clone(".", allocator)
}

project_index_destroy :: proc(idx: ^Project_Index) {
    for k, &v in idx.own_structs {
        for &f in v.fields {
            delete(f.name)
            delete(f.type)
        }
        delete(v.fields)
        delete(k)
    }
    delete(idx.own_structs)

    for k, &v in idx.own_enums {
        for s in v.values {
            delete(s)
        }
        delete(v.values)
        delete(k)
    }
    delete(idx.own_enums)

    for k, v in idx.own_variables {
        delete(k)
        delete(v)
    }
    delete(idx.own_variables)

    for k, v in idx.import_aliases {
        delete(k)
        delete(v)
    }
    delete(idx.import_aliases)

    for k, v in idx.imported_package_dirs {
        delete(k)
        delete(v)
    }
    delete(idx.imported_package_dirs)

    for k, v in idx.imported_struct_sources {
        delete(k)
        delete(v)
    }
    delete(idx.imported_struct_sources)

    for k, v in idx.imported_enum_sources {
        delete(k)
        delete(v)
    }
    delete(idx.imported_enum_sources)

    for k, &v in idx.imported_struct_conflicts {
        for s in v {
            delete(s)
        }
        delete(v)
        delete(k)
    }
    delete(idx.imported_struct_conflicts)

    for k, &v in idx.imported_enum_conflicts {
        for s in v {
            delete(s)
        }
        delete(v)
        delete(k)
    }
    delete(idx.imported_enum_conflicts)

    for k in idx.all_imported_structs {
        delete(k)
    }
    delete(idx.all_imported_structs)

    for k in idx.all_imported_enums {
        delete(k)
    }
    delete(idx.all_imported_enums)
}

package_cache_destroy :: proc(cache: ^map[string]Package_Symbols) {
    for k, v in cache^ {
        for _, sd in v.structs {
            for f in sd.fields {
                delete(f.name)
                delete(f.type)
            }
            delete(sd.fields)
        }
        delete(v.structs)
        for _, ed in v.enums {
            for s in ed.values {
                delete(s)
            }
            delete(ed.values)
        }
        delete(v.enums)
        delete(k)
    }
    delete(cache^)
}

build_index :: proc(project_root: string, any_project_file: string) {
    fmt.eprintfln("index build begin  root=%s", project_root)

    g_persistent_allocator = context.allocator

    project_index_destroy(&g_index)
    package_cache_destroy(&g_package_cache)

    g_package_cache = make(map[string]Package_Symbols)

    visited_dirs := make([dynamic]string)

    new_index := index_project_tree(project_root, &visited_dirs)
    for dir in visited_dirs { load_package_symbols(dir) }

    g_index = new_index

    fmt.eprintfln("index build complete root=%s", project_root)
}

rebuild_index :: proc(trigger_file: string) {
    fmt.eprintfln("index rebuild trigger=%s", trigger_file)
    build_index(g_project_root, trigger_file)
}

split_at_dot :: proc(name: string) -> (before, after: string, found: bool) {
    for i := 0; i < len(name); i += 1 {
        if name[i] == '.' { return name[:i], name[i + 1:], true }
    }
    return "", "", false
}

package_by_alias :: proc(alias: string) -> ^Package_Symbols {
    dir, ok := g_index.imported_package_dirs[alias]
    if !ok { return nil }
    if pkg, found := &g_package_cache[dir]; found { return pkg }
    return nil
}

completions_for_buffer :: proc(buffer: string) -> string {
    word_end := len(buffer)
    word_start := word_end
    for word_start > 0 {
        b := buffer[word_start - 1]
        if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') {
            word_start -= 1
        } else { break }
    }
    prefix := buffer[word_start:word_end]

    dot_pos := word_start - 1
    if dot_pos < 0 || buffer[dot_pos] != '.' { return completions_unqualified(prefix) }

    chain_end   := dot_pos
    chain_start := chain_end
    for chain_start > 0 {
        b := buffer[chain_start - 1]
        if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') ||
           (b >= '0' && b <= '9') || b == '.' { chain_start -= 1 } else { break }
    }
    dot_chain := buffer[chain_start:chain_end]
    if dot_chain == "" { return "" }

    segments      := strings.split(dot_chain, ".")
    defer delete(segments)
    current_type  := ""
    segment_start := 1

    if _, is_import := g_index.imported_package_dirs[segments[0]]; is_import {
        if len(segments) == 1 { return completions_from_package(segments[0], prefix) }
        alias := segments[0]; type_name := segments[1]
        if pkg := package_by_alias(alias); pkg != nil {
            if _, ok := pkg.structs[type_name]; ok {
                current_type = strings.concatenate({alias, ".", type_name}, context.temp_allocator)
                segment_start = 2
            } else if _, ok := pkg.enums[type_name]; ok {
                current_type  = strings.concatenate({alias, ".", type_name}, context.temp_allocator)
                segment_start = len(segments)
            }
        }
        if current_type == "" { current_type = resolve_name_to_type(segments[0], buffer); segment_start = 1 }
    } else {
        current_type = resolve_name_to_type(segments[0], buffer)
    }

    if current_type == "" { return "" }

    for i := segment_start; i < len(segments); i += 1 {
        field_name := segments[i]
        if field_name == "" { return "" }

        struct_defn, found := g_index.own_structs[current_type]
        if !found {
            if alias, name, has_dot := split_at_dot(current_type); has_dot {
                if pkg := package_by_alias(alias); pkg != nil { struct_defn, found = pkg.structs[name] }
            }
            if !found { struct_defn, found = g_index.all_imported_structs[current_type] }
            if !found { return "" }
        }

        next_type := ""
        for f in struct_defn.fields { if f.name == field_name { next_type = f.type; break } }
        if next_type == "" { return "" }
        current_type = next_type
    }

    return completions_for_type(current_type, prefix, buffer)
}

resolve_name_to_type :: proc(name: string, buffer: string) -> string {
    if name in g_index.own_structs          { return name }
    if name in g_index.own_enums            { return name }
    if name in g_index.imported_struct_conflicts { return "" }
    if name in g_index.all_imported_structs { return name }
    if name in g_index.imported_enum_conflicts   { return "" }
    if name in g_index.all_imported_enums   { return name }
    if t, ok := g_index.own_variables[name]; ok { return t }
    if t, ok := resolve_local_var_type(buffer, name); ok { return t }
    return ""
}

resolve_local_var_type :: proc(buffer: string, var_name: string) -> (string, bool) {
    is_ident :: proc(b: byte) -> bool {
        return b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
    }

    scan_pos := len(buffer)
    for scan_pos > 0 {
        line_end := scan_pos; scan_pos -= 1
        for scan_pos > 0 && buffer[scan_pos - 1] != '\n' { scan_pos -= 1 }
        line := strings.trim_space(buffer[scan_pos:line_end])

        if !strings.has_prefix(line, var_name) { continue }
        if len(line) > len(var_name) && is_ident(line[len(var_name)]) { continue }
        rest := strings.trim_left(line[len(var_name):], " \t")

        if len(rest) > 0 && rest[0] == ':' && (len(rest) == 1 || rest[1] != '=') {
            after := strings.trim_left(rest[1:], " \t")
            end := 0
            for end < len(after) && is_ident(after[end]) { end += 1 }
            for end < len(after) && after[end] == '.' {
                end += 1; seg_start := end
                for end < len(after) && is_ident(after[end]) { end += 1 }
                if seg_start == end { break }
            }
            if end > 0 { return after[:end], true }
        }

        if strings.has_prefix(rest, ":=") {
            after := strings.trim_left(rest[2:], " \t")
            end := 0
            for end < len(after) && is_ident(after[end]) { end += 1 }
            for end < len(after) && after[end] == '.' {
                end += 1; seg_start := end
                for end < len(after) && is_ident(after[end]) { end += 1 }
                if seg_start == end { break }
            }
            if end > 0 {
                remainder := strings.trim_left(after[end:], " \t")
                if len(remainder) > 0 && remainder[0] == '{' { return after[:end], true }
            }
        }
    }
    return "", false
}

format_struct :: proc(name: string, defn: Struct_Definition) -> string {
    sb := strings.builder_make()
    strings.write_string(&sb, "struct "); strings.write_string(&sb, name); strings.write_string(&sb, " {\n")
    for f in defn.fields {
        strings.write_string(&sb, indent_spaces)
        strings.write_string(&sb, f.name); strings.write_string(&sb, ": ")
        strings.write_string(&sb, f.type); strings.write_string(&sb, ",\n")
    }
    strings.write_string(&sb, "}")
    return strings.to_string(sb)
}

format_enum :: proc(name: string, defn: Enum_Definition) -> string {
    sb := strings.builder_make()
    strings.write_string(&sb, "enum "); strings.write_string(&sb, name); strings.write_string(&sb, " {\n")
    for v in defn.values {
        strings.write_string(&sb, indent_spaces); strings.write_string(&sb, v); strings.write_string(&sb, ",\n")
    }
    strings.write_string(&sb, "}")
    return strings.to_string(sb)
}

hover_info :: proc(symbol: string) -> string {
    if d, ok := g_index.own_structs[symbol];          ok { return format_struct(symbol, d) }
    if d, ok := g_index.own_enums[symbol];            ok { return format_enum(symbol, d)   }
    if symbol in g_index.imported_struct_conflicts {
        return fmt.tprintf("%s: ambiguous (defined in %s)", symbol, strings.join(g_index.imported_struct_conflicts[symbol][:], ", "))
    }
    if symbol in g_index.imported_enum_conflicts {
        return fmt.tprintf("%s: ambiguous (defined in %s)", symbol, strings.join(g_index.imported_enum_conflicts[symbol][:], ", "))
    }
    if d, ok := g_index.all_imported_structs[symbol]; ok { return format_struct(symbol, d) }
    if d, ok := g_index.all_imported_enums[symbol];   ok { return format_enum(symbol, d)   }

    if type_name, ok := g_index.own_variables[symbol]; ok {
        if type_name in g_index.imported_struct_conflicts {
            return fmt.tprintf("%s: ambiguous (defined in %s)", symbol, strings.join(g_index.imported_struct_conflicts[type_name][:], ", "))
        }
        if type_name in g_index.imported_enum_conflicts {
            return fmt.tprintf("%s: ambiguous (defined in %s)", symbol, strings.join(g_index.imported_enum_conflicts[type_name][:], ", "))
        }
        if d, found := g_index.own_structs[type_name];          found { return format_struct(type_name, d) }
        if d, found := g_index.own_enums[type_name];            found { return format_enum(type_name, d)   }
        if d, found := g_index.all_imported_structs[type_name]; found { return format_struct(type_name, d) }
        if d, found := g_index.all_imported_enums[type_name];   found { return format_enum(type_name, d)   }
        return fmt.tprintf("%s: %s", symbol, type_name)
    }

    for _, defn in g_index.own_structs {
        for field in defn.fields {
            if field.name != symbol { continue }
            t := field.type
            if d, found := g_index.own_structs[t];          found { return format_struct(t, d) }
            if d, found := g_index.own_enums[t];            found { return format_enum(t, d)   }
            if d, found := g_index.all_imported_structs[t]; found { return format_struct(t, d) }
            if d, found := g_index.all_imported_enums[t];   found { return format_enum(t, d)   }
            return fmt.tprintf("%s: %s", symbol, t)
        }
    }
    return ""
}

completions_from_package :: proc(alias: string, prefix: string) -> string {
    pkg := package_by_alias(alias)
    if pkg == nil { return "" }
    sb := strings.builder_make()
    for name in pkg.structs {
        if strings.has_prefix(name, prefix) { strings.write_string(&sb, name); strings.write_byte(&sb, '\t'); strings.write_string(&sb, alias); strings.write_byte(&sb, '\n') }
    }
    for name in pkg.enums {
        if strings.has_prefix(name, prefix) { strings.write_string(&sb, name); strings.write_byte(&sb, '\t'); strings.write_string(&sb, alias); strings.write_byte(&sb, '\n') }
    }
    return strings.trim_right(strings.to_string(sb), "\n")
}

completions_unqualified :: proc(prefix: string) -> string {
    sb := strings.builder_make()
    for name in g_index.own_structs {
        if strings.has_prefix(name, prefix) { strings.write_string(&sb, name); strings.write_string(&sb, "\t\n") }
    }
    for name in g_index.own_enums {
        if strings.has_prefix(name, prefix) { strings.write_string(&sb, name); strings.write_string(&sb, "\t\n") }
    }
    for name in g_index.all_imported_structs {
        if name in g_index.own_structs { continue }
        if name in g_index.imported_struct_conflicts {
            if strings.has_prefix(name, prefix) {
                strings.write_string(&sb, name)
                strings.write_string(&sb, "\tambiguous: ")
                strings.write_string(&sb, strings.join(g_index.imported_struct_conflicts[name][:], ", "))
                strings.write_byte(&sb, '\n')
            }
        } else {
            if strings.has_prefix(name, prefix) { strings.write_string(&sb, name); strings.write_string(&sb, "\timport\n") }
        }
    }
    for name in g_index.all_imported_enums {
        if name in g_index.own_enums { continue }
        if name in g_index.imported_enum_conflicts {
            if strings.has_prefix(name, prefix) {
                strings.write_string(&sb, name)
                strings.write_string(&sb, "\tambiguous: ")
                strings.write_string(&sb, strings.join(g_index.imported_enum_conflicts[name][:], ", "))
                strings.write_byte(&sb, '\n')
            }
        } else {
            if strings.has_prefix(name, prefix) { strings.write_string(&sb, name); strings.write_string(&sb, "\timport\n") }
        }
    }
    for name, type_name in g_index.own_variables {
        if strings.has_prefix(name, prefix) { strings.write_string(&sb, name); strings.write_byte(&sb, '\t'); strings.write_string(&sb, type_name); strings.write_byte(&sb, '\n') }
    }
    return strings.trim_right(strings.to_string(sb), "\n")
}

completions_for_type :: proc(type_name: string, prefix: string, buffer: string) -> string {
    write_struct_fields :: proc(sb: ^strings.Builder, defn: Struct_Definition, prefix: string) {
        for f in defn.fields {
            if strings.has_prefix(f.name, prefix) { strings.write_string(sb, f.name); strings.write_byte(sb, '\t'); strings.write_string(sb, f.type); strings.write_byte(sb, '\n') }
        }
    }
    write_enum_values :: proc(sb: ^strings.Builder, defn: Enum_Definition, prefix: string, type_name: string) {
        for v in defn.values {
            if strings.has_prefix(v, prefix) { strings.write_string(sb, v); strings.write_byte(sb, '\t'); strings.write_string(sb, type_name); strings.write_byte(sb, '\n') }
        }
    }

    if alias, name, has_dot := split_at_dot(type_name); has_dot {
        if pkg := package_by_alias(alias); pkg != nil {
            sb := strings.builder_make()
            if d, ok := pkg.structs[name]; ok { write_struct_fields(&sb, d, prefix) } else
            if d, ok := pkg.enums[name];   ok { write_enum_values(&sb, d, prefix, type_name) }
            return strings.trim_right(strings.to_string(sb), "\n")
        }
    }

    sb := strings.builder_make()
    if d, ok := g_index.own_structs[type_name];          ok { write_struct_fields(&sb, d, prefix)            } else
    if d, ok := g_index.own_enums[type_name];            ok { write_enum_values(&sb, d, prefix, type_name)   } else
    if d, ok := g_index.all_imported_structs[type_name]; ok { write_struct_fields(&sb, d, prefix)            } else
    if d, ok := g_index.all_imported_enums[type_name];   ok { write_enum_values(&sb, d, prefix, type_name)   }
    return strings.trim_right(strings.to_string(sb), "\n")
}

MAX_FRAME_BYTES :: 4 * 1024 * 1024

fd_read_exactly :: proc(fd: posix.FD, buf: []u8) -> bool {
    total := 0
    for total < len(buf) {
        n := posix.read(fd, &buf[total], uint(len(buf)) - uint(total))
        if n <= 0 { return false }
        total += n
    }
    return true
}

fd_write_all :: proc(fd: posix.FD, buf: []u8) -> bool {
    total := 0
    for total < len(buf) {
        n := posix.write(fd, &buf[total], uint(len(buf)) - uint(total))
        if n <= 0 { return false }
        total += n
    }
    return true
}

write_frame :: proc(fd: posix.FD, msg: string) -> bool {
    body := transmute([]u8)msg
    n    := len(body)
    hdr_str := fmt.tprintf("%08x", n)
    hdr  := transmute([]u8)hdr_str
    return fd_write_all(fd, hdr) && fd_write_all(fd, body)
}

read_frame :: proc(fd: posix.FD, allocator := context.allocator) -> (string, bool) {
    hdr: [8]u8
    if !fd_read_exactly(fd, hdr[:]) { return "", false }
    
    n: int = 0
    for i := 0; i < 8; i += 1 {
        c := hdr[i]
        val: int = 0
        if c >= '0' && c <= '9' {
            val = int(c - '0')
        } else if c >= 'a' && c <= 'f' {
            val = int(c - 'a' + 10)
        } else if c >= 'A' && c <= 'F' {
            val = int(c - 'A' + 10)
        } else {
            return "", false
        }
        n = (n << 4) | val
    }
    
    if n > MAX_FRAME_BYTES { return "", false }
    if n == 0              { return "", true  }
    body := make([]u8, n, allocator)
    if !fd_read_exactly(fd, body) { delete(body, allocator); return "", false }
    return string(body), true
}

socket_path_for_root :: proc(project_root: string, allocator := context.allocator) -> string {
    ctx: md5.Context
    md5.init(&ctx)
    md5.update(&ctx, transmute([]u8)project_root)
    digest: [md5.DIGEST_SIZE]u8
    md5.final(&ctx, digest[:])
    hash := hex.encode(digest[:], allocator)
    defer delete(hash, allocator)
    return strings.join({"/tmp/gjallarhorn_", string(hash), ".sock"}, "", allocator)
}

make_sockaddr :: proc(socket_path: string) -> posix.sockaddr_un {
    addr: posix.sockaddr_un
    addr.sun_family = .UNIX
    when ODIN_OS == .Darwin { addr.sun_len = u8(size_of(addr)) }
    copy(addr.sun_path[:], socket_path)
    return addr
}

signal_handler :: proc "c" (sig: posix.Signal) {
    if g_socket_path_c != nil { posix.unlink(g_socket_path_c) }
    posix.exit(0)
}

install_signal_handlers :: proc() {
    ign_act: posix.sigaction_t
    ign_act.sa_handler = transmute(proc "c" (posix.Signal))posix.SIG_IGN
    posix.sigaction(.SIGPIPE, &ign_act, nil)

    sig_act: posix.sigaction_t
    sig_act.sa_handler = signal_handler
    posix.sigaction(.SIGTERM, &sig_act, nil)
    posix.sigaction(.SIGINT,  &sig_act, nil)
}

daemon_start :: proc(initial_file: string) {
    install_signal_handlers()

    source_dir   := path_parent_dir(initial_file);  defer delete(source_dir)
    project_root := find_project_root(source_dir);  defer delete(project_root)
    socket_path  := socket_path_for_root(project_root); defer delete(socket_path)

    socket_path_c   := strings.clone_to_cstring(socket_path)
    g_socket_path_c  = socket_path_c
    posix.unlink(socket_path_c)

    g_project_root = strings.clone(project_root)
    build_index(project_root, initial_file)

    server_fd := posix.socket(.UNIX, .STREAM)
    if int(server_fd) < 0 { fmt.eprintfln("socket() failed: %v", posix.errno()); os.exit(1) }

    addr := make_sockaddr(socket_path)
    if posix.bind(server_fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr))) == .FAIL {
        fmt.eprintfln("bind() failed: %v", posix.errno()); os.exit(1)
    }
    if posix.listen(server_fd, 8) == .FAIL {
        fmt.eprintfln("listen() failed: %v", posix.errno()); os.exit(1)
    }

    fmt.eprintfln("socket:%s", socket_path)

    daemon_accept_loop(server_fd)
}

daemon_accept_loop :: proc(server_fd: posix.FD) {
    for {
        client_fd := posix.accept(server_fd, nil, nil)
        if int(client_fd) < 0 {
            if posix.errno() == .EINTR { continue }
            fmt.eprintfln("accept() failed: %v", posix.errno())
            continue
        }
        handle_client(client_fd)
        posix.close(client_fd)
    }
}

handle_client :: proc(client_fd: posix.FD) {
    for {
        free_all(context.temp_allocator)

        cmd, ok := read_frame(client_fd, context.temp_allocator)
        if !ok { break }

        switch cmd {
        case "comp":
            buf, buf_ok := read_frame(client_fd, context.temp_allocator)
            if !buf_ok { return }
            
            context.allocator = context.temp_allocator
            result := completions_for_buffer(buf)
            write_frame(client_fd, result)

        case "hover":
            sym, sym_ok := read_frame(client_fd, context.temp_allocator)
            if !sym_ok { return }
            
            context.allocator = context.temp_allocator
            result := hover_info(sym)
            write_frame(client_fd, result)

        case "index":
            path, path_ok := read_frame(client_fd, context.temp_allocator)
            if !path_ok { return }
            rebuild_index(path)
            write_frame(client_fd, "")

        case:
            fmt.eprintfln("unknown cmd: %q", cmd)
            write_frame(client_fd, "")
            return
        }
    }
}

main :: proc() {
    daemon_mode := false
    filepath := ""
    
    for i := 1; i < len(os.args); i += 1 {
        arg := os.args[i]
        if arg == "--daemon" {
            daemon_mode = true
            if i + 1 < len(os.args) {
                filepath = os.args[i+1]
                i += 1
            }
        }
    }

    if !daemon_mode || filepath == "" {
        fmt.eprintfln("usage: gjallarhorn --daemon <absolute_filepath>")
        os.exit(1)
    }

    daemon_start(filepath)
}
