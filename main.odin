package gjallarhorn

import "core:crypto/legacy/md5"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

debug: bool

tab_spaces: string = "    "

Field_Entry :: struct {
    name : string,
    type : string,
}

Struct_Entry :: struct {
    fields : [dynamic]Field_Entry,
}

Enum_Entry :: struct {
    values : [dynamic]string,
}

Import_Result :: struct {
    structs : map[string]Struct_Entry,
    enums   : map[string]Enum_Entry,
}

import_cache : map[string]Import_Result

cached_odin_root: string

Index :: struct {
    structs        : map[string]Struct_Entry,
    enums          : map[string]Enum_Entry,
    variables      : map[string]string,
    imports        : map[string]string,
    imports_data   : map[string]^Import_Result,
    all_structs    : map[string]Struct_Entry,
    all_enums      : map[string]Enum_Entry,
}

index_destroy :: proc(idx: ^Index) {
    for _, &s in idx.structs {
        for &f in s.fields { delete(f.name); delete(f.type) }
        delete(s.fields)
    }
    for k in idx.structs { delete(k) }
    delete(idx.structs)

    for _, &e in idx.enums {
        for v in e.values { delete(v) }
        delete(e.values)
    }
    for k in idx.enums { delete(k) }
    delete(idx.enums)

    for k, v in idx.variables { delete(k); delete(v) }
    delete(idx.variables)

    for k, v in idx.imports { delete(k); delete(v) }
    delete(idx.imports)

    for k in idx.imports_data { delete(k) }
    delete(idx.imports_data)

    delete(idx.all_structs)
    delete(idx.all_enums)
}

Token_Kind :: enum {
    EOF,
    Ident,
    String,
    Double_Colon,   // ::
    Open_Brace,     // {
    Close_Brace,    // }
    Comma,          // ,
    Colon,          // :
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

lexer_skip_whitespace :: proc(l: ^Lexer) {
    for l.pos < len(l.src) {
        c := l.src[l.pos]
        if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
            l.pos += 1
            continue
        }
        if c == '/' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '/' {
            for l.pos < len(l.src) && l.src[l.pos] != '\n' { l.pos += 1 }
            continue
        }
        if c == '/' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '*' {
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
    lexer_skip_whitespace(l)
    if l.pos >= len(l.src) { return Token{kind = .EOF} }

    c := l.src[l.pos]

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
        return Token{kind = .Ident, text = l.src[start:l.pos]}
    }

    if c == ':' {
        if l.pos + 1 < len(l.src) && l.src[l.pos + 1] == ':' {
            l.pos += 2
            return Token{kind = .Double_Colon, text = "::"}
        }
        l.pos += 1
        return Token{kind = .Colon, text = ":"}
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
        return Token{kind = .String, text = text}
    }

    if c == '{' { l.pos += 1; return Token{kind = .Open_Brace,  text = "{"} }
    if c == '}' { l.pos += 1; return Token{kind = .Close_Brace, text = "}"} }
    if c == ',' { l.pos += 1; return Token{kind = .Comma,       text = ","} }

    start := l.pos
    _, rune_width := utf8.decode_rune_in_string(l.src[l.pos:])
    l.pos += rune_width
    return Token{kind = .Other, text = l.src[start:l.pos]}
}

lexer_peek :: proc(l: ^Lexer) -> Token {
    saved := l.pos
    tok   := lexer_next(l)
    l.pos  = saved
    return tok
}

derive_alias :: proc(raw_path: string) -> string {
    last := -1
    for i := 0; i < len(raw_path); i += 1 {
        if raw_path[i] == ':' || raw_path[i] == '/' {
            last = i
        }
    }
    if last == -1 { return raw_path }
    return raw_path[last+1:]
}

parse_source :: proc(src: string) -> Index {
    idx := Index{
        structs        = make(map[string]Struct_Entry),
        enums          = make(map[string]Enum_Entry),
        variables      = make(map[string]string),
        imports        = make(map[string]string),
        imports_data   = make(map[string]^Import_Result),
        all_structs    = make(map[string]Struct_Entry),
        all_enums      = make(map[string]Enum_Entry),
    }
    l := lexer_make(src)

    for {
        tok := lexer_next(&l)
        if tok.kind == .EOF { break }
        if tok.kind != .Ident { continue }

        name := tok.text

        if name == "import" {
            peek := lexer_peek(&l)
            alias: string
            path: string
            if peek.kind == .String {
                lexer_next(&l)
                path = peek.text
                alias = derive_alias(path)
            } else if peek.kind == .Ident || (peek.kind == .Other && peek.text == ".") {
                alias_tok := lexer_next(&l)
                alias = alias_tok.text
                path_tok := lexer_next(&l)
                if path_tok.kind == .String {
                    path = path_tok.text
                }
            }
            if alias == "_" { continue }
            if alias != "" && path != "" {
                idx.imports[strings.clone(alias)] = strings.clone(path)
            }
            continue
        }

        next := lexer_peek(&l)

        if next.kind == .Double_Colon {
            lexer_next(&l) // consume ::
            after := lexer_peek(&l)
            if after.kind != .Ident { continue }
            switch after.text {
            case "struct":
                lexer_next(&l)
                idx.structs[strings.clone(name)] = parse_struct_body(&l)
            case "enum":
                lexer_next(&l)
                idx.enums[strings.clone(name)] = parse_enum_body(&l)
            case:
                lexer_next(&l)
                type_parts := make([dynamic]string, context.temp_allocator)
                append(&type_parts, after.text)
                for {
                    pk := lexer_peek(&l)
                    if pk.kind == .Other && pk.text == "." {
                        lexer_next(&l)
                        name_tok := lexer_next(&l)
                        if name_tok.kind == .Ident {
                            append(&type_parts, ".")
                            append(&type_parts, name_tok.text)
                        } else { break }
                    } else { break }
                }
                type_str := strings.join(type_parts[:], "")
                idx.variables[strings.clone(name)] = strings.clone(type_str)
            }
            continue
        }

        if next.kind == .Colon {
            lexer_next(&l) // consume :
            type_tok := lexer_peek(&l)
            if type_tok.kind == .Ident {
                lexer_next(&l)
                type_parts := make([dynamic]string, context.temp_allocator)
                append(&type_parts, type_tok.text)
                for {
                    pk := lexer_peek(&l)
                    if pk.kind == .Other && pk.text == "." {
                        lexer_next(&l)
                        name_tok := lexer_next(&l)
                        if name_tok.kind == .Ident {
                            append(&type_parts, ".")
                            append(&type_parts, name_tok.text)
                        } else { break }
                    } else { break }
                }
                type_str := strings.join(type_parts[:], "")
                idx.variables[strings.clone(name)] = strings.clone(type_str)
            }
            continue
        }
    }

    return idx
}

parse_struct_body :: proc(l: ^Lexer) -> Struct_Entry {
    entry := Struct_Entry{fields = make([dynamic]Field_Entry)}

    depth := 0
    for {
        tok := lexer_next(l)
        if tok.kind == .EOF { return entry }
        if tok.kind == .Open_Brace { depth = 1; break }
    }

    for depth > 0 {
        tok := lexer_next(l)
        #partial switch tok.kind {
        case .EOF:
            return entry
        case .Open_Brace:
            depth += 1
        case .Close_Brace:
            depth -= 1
        case .Ident:
            if depth != 1 { continue }
            field_name := tok.text
            if lexer_peek(l).kind != .Colon { continue }
            lexer_next(l) // consume :
            type_parts := make([dynamic]string, context.temp_allocator)
            for {
                pk := lexer_peek(l)
                if pk.kind == .EOF || pk.kind == .Comma || pk.kind == .Close_Brace { break }
                if pk.kind == .Ident {
                    saved := l.pos
                    lexer_next(l)
                    if lexer_peek(l).kind == .Colon {
                        l.pos = saved
                        break
                    }
                    l.pos = saved
                }
                t := lexer_next(l)
                if t.text != "" { append(&type_parts, t.text) }
            }
            if lexer_peek(l).kind == .Comma { lexer_next(l) }
            type_str := strings.join(type_parts[:], "")
            append(&entry.fields, Field_Entry{
                name = strings.clone(field_name),
                type = type_str,
            })
        case:
        }
    }
    return entry
}

parse_enum_body :: proc(l: ^Lexer) -> Enum_Entry {
    entry := Enum_Entry{values = make([dynamic]string)}

    for {
        tok := lexer_next(l)
        if tok.kind == .EOF { return entry }
        if tok.kind == .Open_Brace { break }
    }

    for {
        tok := lexer_next(l)
        #partial switch tok.kind {
        case .EOF, .Close_Brace:
            return entry
        case .Ident:
            append(&entry.values, strings.clone(tok.text))
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
    if cached_odin_root != "" {
        return cached_odin_root, true
    }

    root_val, found := os.lookup_env_alloc("ODIN_ROOT", context.allocator)
    if found && root_val != "" {
        if root_val[len(root_val)-1] == '/' {
            root_val = root_val[:len(root_val)-1]
        }
        cached_odin_root = strings.clone(root_val)
        delete(root_val)
        return cached_odin_root, true
    }
    if found { delete(root_val) }

    desc := os.Process_Desc{
        command = {"odin", "root"},
    }
    state, stdout, stderr, err := os.process_exec(desc, context.allocator)
    if err != nil || !state.success {
        delete(stdout)
        delete(stderr)
        return "", false
    }
    delete(stderr)

    root := strings.trim_space(string(stdout))
    if len(root) > 0 && root[len(root)-1] == '/' {
        root = root[:len(root)-1]
    }
    cached_odin_root = strings.clone(root)
    delete(stdout)
    return cached_odin_root, true
}

resolve_package_path :: proc(raw_path: string, source_file: string) -> (string, bool) {
    colon_idx := -1
    for i := 0; i < len(raw_path); i += 1 {
        if raw_path[i] == ':' {
            colon_idx = i
            break
        }
    }
    if colon_idx != -1 {
        root_val, ok := get_odin_root()
        if !ok { return "", false }
        collection := raw_path[:colon_idx]
        name := raw_path[colon_idx+1:]
        result := strings.concatenate({root_val, "/", collection, "/", name})
        return result, true
    }

    dir := source_file
    last_slash := -1
    for i := len(dir) - 1; i >= 0; i -= 1 {
        if dir[i] == '/' {
            last_slash = i
            break
        }
    }
    if last_slash != -1 {
        dir = dir[:last_slash]
    } else {
        dir = "."
    }

    result := strings.concatenate({dir, "/", raw_path})
    return result, true
}

load_import_types :: proc(dir_path: string) {
    if dir_path in import_cache { return }

    result := Import_Result{
        structs = make(map[string]Struct_Entry),
        enums   = make(map[string]Enum_Entry),
    }

    aliases := make(map[string]string)
    defer {
        for k, v in aliases { delete(k); delete(v) }
        delete(aliases)
    }

    file_infos, err := os.read_all_directory_by_path(dir_path, context.allocator)
    if err != nil {
        import_cache[strings.clone(dir_path)] = result
        return
    }
    defer os.file_info_slice_delete(file_infos, context.allocator)

    for fi in file_infos {
        if fi.type == .Directory { continue }
        name := fi.name
        if !strings.has_suffix(name, ".odin") { continue }
        if strings.has_suffix(name, "_test.odin") { continue }

        full_path_b := strings.builder_make(context.temp_allocator)
        strings.write_string(&full_path_b, dir_path)
        strings.write_byte(&full_path_b, '/')
        strings.write_string(&full_path_b, name)
        full_path := strings.to_string(full_path_b)

        src_data, err2 := os.read_entire_file_from_path(full_path, context.allocator)
        if err2 != nil { continue }
        src := string(src_data)
        temp_idx := parse_source(src)

        for k, &s in temp_idx.structs {
            entry := Struct_Entry{fields = make([dynamic]Field_Entry)}
            for &f in s.fields {
                append(&entry.fields, Field_Entry{name = f.name, type = f.type})
            }
            delete(s.fields)
            result.structs[k] = entry
            delete_key(&temp_idx.structs, k)
        }
        delete(temp_idx.structs)
        temp_idx.structs = {}

        for k, &e in temp_idx.enums {
            entry := Enum_Entry{values = make([dynamic]string)}
            for v in e.values {
                append(&entry.values, v)
            }
            delete(e.values)
            result.enums[k] = entry
            delete_key(&temp_idx.enums, k)
        }
        delete(temp_idx.enums)
        temp_idx.enums = {}

        for k, v in temp_idx.variables {
            aliases[strings.clone(k)] = strings.clone(v)
            delete_key(&temp_idx.variables, k)
        }

        index_destroy(&temp_idx)
        delete(src_data, context.allocator)
    }

    resolve_final :: proc(aliases: map[string]string, name: string) -> string {
        visited := 0
        current := name
        for visited < 100 {
            if next, ok := aliases[current]; ok {
                current = next
                visited += 1
            } else { return current }
        }
        return current
    }

    for alias_name, target_name in aliases {
        final := resolve_final(aliases, target_name)

        if entry, ok := result.structs[final]; ok {
            new_entry := Struct_Entry{
                fields = make([dynamic]Field_Entry, len(entry.fields)),
            }
            for &f, i in entry.fields {
                new_entry.fields[i] = Field_Entry{
                    name = strings.clone(f.name),
                    type = strings.clone(f.type),
                }
            }
            result.structs[strings.clone(alias_name)] = new_entry
        } else if entry, ok := result.enums[final]; ok {
            new_entry := Enum_Entry{
                values = make([dynamic]string, len(entry.values)),
            }
            for v, i in entry.values {
                new_entry.values[i] = strings.clone(v)
            }
            result.enums[strings.clone(alias_name)] = new_entry
        }
    }

    import_cache[strings.clone(dir_path)] = result
}

merge_into_idx :: proc(idx: ^Index, alias: string, dir_path: string) {
    cached, ok := import_cache[dir_path]
    if !ok { return }

    if alias != "." {
        idx.imports_data[strings.clone(alias)] = &import_cache[dir_path]
    }

    for name, entry in cached.structs {
        idx.all_structs[name] = entry
    }
    for name, entry in cached.enums {
        idx.all_enums[name] = entry
    }
}

index_imports :: proc(idx: ^Index, source_file: string) {
    for alias, raw_path in idx.imports {
        if alias == "_" { continue }
        dir_path, ok := resolve_package_path(raw_path, source_file)
        if !ok { continue }
        load_import_types(dir_path)
        merge_into_idx(idx, alias, dir_path)
        delete(dir_path)
    }
}

index_directory :: proc(dir_path: string, source_file: string) -> Index {
    idx := Index{
        structs        = make(map[string]Struct_Entry),
        enums          = make(map[string]Enum_Entry),
        variables      = make(map[string]string),
        imports        = make(map[string]string),
        imports_data   = make(map[string]^Import_Result),
        all_structs    = make(map[string]Struct_Entry),
        all_enums      = make(map[string]Enum_Entry),
    }

    file_infos, err := os.read_all_directory_by_path(dir_path, context.temp_allocator)
    if err != nil { return idx }

    for fi in file_infos {
        if fi.type == .Directory { continue }
        name := fi.name
        if !strings.has_suffix(name, ".odin") { continue }
        if strings.has_suffix(name, "_test.odin") { continue }

        full_path := strings.concatenate({dir_path, "/", name}, context.temp_allocator)
        src_data, read_err := os.read_entire_file_from_path(full_path, context.allocator)
        if read_err != nil { continue }
        src := string(src_data)
        temp_idx := parse_source(src)

        for k, &s in temp_idx.structs {
            if old, ok := idx.structs[k]; ok {
                for &f in old.fields { delete(f.name); delete(f.type) }
                delete(old.fields)
                delete_key(&idx.structs, k)
            }
            idx.structs[k] = s
            delete_key(&temp_idx.structs, k)
        }
        for _, &s in temp_idx.structs {
            for &f in s.fields { delete(f.name); delete(f.type) }
            delete(s.fields)
        }
        delete(temp_idx.structs)
        temp_idx.structs = {}

        for k, &e in temp_idx.enums {
            if old, ok := idx.enums[k]; ok {
                for v in old.values { delete(v) }
                delete(old.values)
                delete_key(&idx.enums, k)
            }
            idx.enums[k] = e
            delete_key(&temp_idx.enums, k)
        }
        for _, &e in temp_idx.enums {
            for v in e.values { delete(v) }
            delete(e.values)
        }
        delete(temp_idx.enums)
        temp_idx.enums = {}

        for k, v in temp_idx.variables {
            if old, ok := idx.variables[k]; ok { delete(old); delete_key(&idx.variables, k) }
            idx.variables[k] = v
            delete_key(&temp_idx.variables, k)
        }

        for k, v in temp_idx.imports {
            if old, ok := idx.imports[k]; ok { delete(old); delete_key(&idx.imports, k) }
            idx.imports[k] = v
            delete_key(&temp_idx.imports, k)
        }

        index_destroy(&temp_idx)
        delete(src_data, context.allocator)
    }

    index_imports(&idx, source_file)
    return idx
}

g_index: Index

extract_parent_dir :: proc(filepath: string, allocator := context.allocator) -> string {
    for i := len(filepath) - 1; i >= 0; i -= 1 {
        if filepath[i] == '/' {
            if i == 0 { return strings.clone("/", allocator) }
            return strings.clone(filepath[:i], allocator)
        }
    }
    return strings.clone(".", allocator)
}

daemon_init_index :: proc(filepath: string) {
    fmt.eprintfln("index rebuild begin: %s", filepath)
    dir := extract_parent_dir(filepath)
    defer delete(dir)

    new_index := index_directory(dir, filepath)

    old := g_index
    g_index = new_index
    index_destroy(&old)

    delete(import_cache)
    import_cache = make(map[string]Import_Result)

    fmt.eprintfln("index rebuild complete: %s", filepath)
}

split_qualified_name :: proc(name: string) -> (string, string, bool) {
    for i := 0; i < len(name); i += 1 {
        if name[i] == '.' {
            return name[:i], name[i+1:], true
        }
    }
    return "", "", false
}

respond_to_buffer :: proc(buffer: string) -> string {
    word_end   := len(buffer)
    word_start := word_end
    for word_start > 0 {
        b := buffer[word_start - 1]
        if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') {
            word_start -= 1
        } else {
            break
        }
    }
    prefix := buffer[word_start:word_end]

    dot_pos := word_start - 1
    if dot_pos < 0 || buffer[dot_pos] != '.' {
        return completions_unqualified(prefix)
    }

    chain_end   := dot_pos
    chain_start := chain_end
    for chain_start > 0 {
        b := buffer[chain_start - 1]
        if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '.' {
            chain_start -= 1
        } else {
            break
        }
    }
    chain := buffer[chain_start:chain_end]
    if chain == "" { return "" }

    segments := strings.split(chain, ".")
    defer delete(segments)

    current_type := ""
    i_start := 1

    if segments[0] in g_index.imports_data {
        if len(segments) == 1 {
            return completions_from_import(segments[0], prefix)
        }
        alias := segments[0]
        name := segments[1]
        if cached, ok := g_index.imports_data[alias]; ok {
            if _, ok2 := cached.structs[name]; ok2 {
                b_tmp := strings.builder_make(context.temp_allocator)
                strings.write_string(&b_tmp, alias)
                strings.write_byte(&b_tmp, '.')
                strings.write_string(&b_tmp, name)
                current_type = strings.to_string(b_tmp)
                i_start = 2
            }
        }
        if current_type == "" {
            if cached, ok := g_index.imports_data[alias]; ok {
                if _, ok2 := cached.enums[name]; ok2 {
                    b_tmp := strings.builder_make(context.temp_allocator)
                    strings.write_string(&b_tmp, alias)
                    strings.write_byte(&b_tmp, '.')
                    strings.write_string(&b_tmp, name)
                    current_type = strings.to_string(b_tmp)
                    i_start = len(segments)
                }
            }
        }
        if current_type == "" {
            current_type = resolve_to_type(segments[0], buffer)
            i_start = 1
        }
    } else {
        current_type = resolve_to_type(segments[0], buffer)
    }

    if current_type == "" { return "" }

    for i := i_start; i < len(segments); i += 1 {
        field_name := segments[i]
        if field_name == "" { return "" }

        se, ok := g_index.structs[current_type]
        if !ok {
            if alias2, name2, found := split_qualified_name(current_type); found {
                if cached, ok2 := g_index.imports_data[alias2]; ok2 {
                    se, ok = cached.structs[name2]
                }
            }
            if !ok {
                if se2, ok2 := g_index.all_structs[current_type]; ok2 {
                    se = se2
                    ok = true
                }
            }
            if !ok { return "" }
        }

        next_type := ""
        for f in se.fields {
            if f.name == field_name {
                next_type = f.type
                break
            }
        }
        if next_type == "" { return "" }
        current_type = next_type
    }

    return completions_for_type(current_type, prefix, buffer)
}

resolve_to_type :: proc(name: string, buffer: string) -> string {
    if name in g_index.structs || name in g_index.enums {
        return name
    }
    if name in g_index.all_structs || name in g_index.all_enums {
        return name
    }
    if type_name, ok := g_index.variables[name]; ok {
        return type_name
    }
    if type_name, ok := resolve_local_type(buffer, name); ok {
        return type_name
    }
    return ""
}

resolve_local_type :: proc(buffer: string, var_name: string) -> (string, bool) {
    is_ident_char :: proc(b: byte) -> bool {
        return b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
    }

    i := len(buffer)
    for i > 0 {
        line_end := i
        i -= 1
        for i > 0 && buffer[i - 1] != '\n' { i -= 1 }
        line := strings.trim_space(buffer[i:line_end])

        if !strings.has_prefix(line, var_name) { continue }
        if len(line) > len(var_name) && is_ident_char(line[len(var_name)]) { continue }
        rest := strings.trim_left(line[len(var_name):], " \t")

        if len(rest) > 0 && rest[0] == ':' && (len(rest) == 1 || rest[1] != '=') {
            after_colon := strings.trim_left(rest[1:], " \t")
            end := 0
            for end < len(after_colon) && is_ident_char(after_colon[end]) { end += 1 }
            for end < len(after_colon) && after_colon[end] == '.' {
                end += 1
                start := end
                for end < len(after_colon) && is_ident_char(after_colon[end]) { end += 1 }
                if start == end { break }
            }
            if end > 0 { return after_colon[:end], true }
        }

        if strings.has_prefix(rest, ":=") {
            after_assign := strings.trim_left(rest[2:], " \t")
            end := 0
            for end < len(after_assign) && is_ident_char(after_assign[end]) { end += 1 }
            for end < len(after_assign) && after_assign[end] == '.' {
                end += 1
                start := end
                for end < len(after_assign) && is_ident_char(after_assign[end]) { end += 1 }
                if start == end { break }
            }
            if end > 0 {
                after_ident := strings.trim_left(after_assign[end:], " \t")
                if len(after_ident) > 0 && after_ident[0] == '{' {
                    return after_assign[:end], true
                }
            }
        }
    }
    return "", false
}

format_struct_info :: proc(name: string, entry: Struct_Entry) -> string {
    sb := strings.builder_make()
    strings.write_string(&sb, "struct ")
    strings.write_string(&sb, name)
    strings.write_string(&sb, " {\n")
    for f in entry.fields {
        strings.write_string(&sb, tab_spaces)
        strings.write_string(&sb, f.name)
        strings.write_string(&sb, ": ")
        strings.write_string(&sb, f.type)
        strings.write_string(&sb, ",\n")
    }
    strings.write_string(&sb, "}")
    return strings.to_string(sb)
}

format_enum_info :: proc(name: string, entry: Enum_Entry) -> string {
    sb := strings.builder_make()
    strings.write_string(&sb, "enum ")
    strings.write_string(&sb, name)
    strings.write_string(&sb, " {\n")
    for v in entry.values {
        strings.write_string(&sb, tab_spaces)
        strings.write_string(&sb, v)
        strings.write_string(&sb, ",\n")
    }
    strings.write_string(&sb, "}")
    return strings.to_string(sb)
}

hover_lookup :: proc(symbol: string) -> string {
    if entry, ok := g_index.structs[symbol]; ok {
        return format_struct_info(symbol, entry)
    }
    if entry, ok := g_index.enums[symbol]; ok {
        return format_enum_info(symbol, entry)
    }
    if entry, ok := g_index.all_structs[symbol]; ok {
        return format_struct_info(symbol, entry)
    }
    if entry, ok := g_index.all_enums[symbol]; ok {
        return format_enum_info(symbol, entry)
    }
    if type_name, ok := g_index.variables[symbol]; ok {
        return fmt.tprintf("%s: %s", symbol, type_name)
    }
    return ""
}

completions_from_import :: proc(alias: string, prefix: string) -> string {
    sb := strings.builder_make()

    if cached, ok := g_index.imports_data[alias]; ok {
        for name, _ in cached.structs {
            if strings.has_prefix(name, prefix) {
                strings.write_string(&sb, name)
                strings.write_byte(&sb, '\t')
                strings.write_string(&sb, alias)
                strings.write_byte(&sb, '\n')
            }
        }
        for name, _ in cached.enums {
            if strings.has_prefix(name, prefix) {
                strings.write_string(&sb, name)
                strings.write_byte(&sb, '\t')
                strings.write_string(&sb, alias)
                strings.write_byte(&sb, '\n')
            }
        }
    }

    result := strings.to_string(sb)
    return strings.trim_right(result, "\n")
}

completions_unqualified :: proc(prefix: string) -> string {
    sb := strings.builder_make()

    for name, _ in g_index.structs {
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_byte(&sb, '\t')
            strings.write_byte(&sb, '\n')
        }
    }

    for name, _ in g_index.enums {
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_byte(&sb, '\t')
            strings.write_byte(&sb, '\n')
        }
    }

    for name, _ in g_index.all_structs {
        if name in g_index.structs { continue }
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_string(&sb, "\timport\n")
        }
    }

    for name, _ in g_index.all_enums {
        if name in g_index.enums { continue }
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_string(&sb, "\timport\n")
        }
    }

    for name, type_name in g_index.variables {
        if strings.has_prefix(name, prefix) {
            strings.write_string(&sb, name)
            strings.write_byte(&sb, '\t')
            strings.write_string(&sb, type_name)
            strings.write_byte(&sb, '\n')
        }
    }

    result := strings.to_string(sb)
    return strings.trim_right(result, "\n")
}

completions_for_type :: proc(type_name: string, prefix: string, buffer: string) -> string {
    if alias, name, found := split_qualified_name(type_name); found {
        if cached, ok := g_index.imports_data[alias]; ok {
            if entry, ok2 := cached.structs[name]; ok2 {
                sb := strings.builder_make()
                for f in entry.fields {
                    if strings.has_prefix(f.name, prefix) {
                        strings.write_string(&sb, f.name)
                        strings.write_byte(&sb, '\t')
                        strings.write_string(&sb, f.type)
                        strings.write_byte(&sb, '\n')
                    }
                }
                result := strings.to_string(sb)
                return strings.trim_right(result, "\n")
            }
        }
        if cached, ok := g_index.imports_data[alias]; ok {
            if entry, ok2 := cached.enums[name]; ok2 {
                sb := strings.builder_make()
                for v in entry.values {
                    if strings.has_prefix(v, prefix) {
                        strings.write_string(&sb, v)
                        strings.write_byte(&sb, '\t')
                        strings.write_string(&sb, type_name)
                        strings.write_byte(&sb, '\n')
                    }
                }
                result := strings.to_string(sb)
                return strings.trim_right(result, "\n")
            }
        }
    }

    sb := strings.builder_make()

    if entry, ok := g_index.structs[type_name]; ok {
        for f in entry.fields {
            if strings.has_prefix(f.name, prefix) {
                strings.write_string(&sb, f.name)
                strings.write_byte(&sb, '\t')
                strings.write_string(&sb, f.type)
                strings.write_byte(&sb, '\n')
            }
        }
    } else if entry, ok := g_index.enums[type_name]; ok {
        for v in entry.values {
            if strings.has_prefix(v, prefix) {
                strings.write_string(&sb, v)
                strings.write_byte(&sb, '\t')
                strings.write_string(&sb, type_name)
                strings.write_byte(&sb, '\n')
            }
        }
    } else if entry, ok := g_index.all_structs[type_name]; ok {
        for f in entry.fields {
            if strings.has_prefix(f.name, prefix) {
                strings.write_string(&sb, f.name)
                strings.write_byte(&sb, '\t')
                strings.write_string(&sb, f.type)
                strings.write_byte(&sb, '\n')
            }
        }
    } else if entry, ok := g_index.all_enums[type_name]; ok {
        for v in entry.values {
            if strings.has_prefix(v, prefix) {
                strings.write_string(&sb, v)
                strings.write_byte(&sb, '\t')
                strings.write_string(&sb, type_name)
                strings.write_byte(&sb, '\n')
            }
        }
    }

    result := strings.to_string(sb)
    return strings.trim_right(result, "\n")
}

MAX_MESSAGE_BYTES :: 4 * 1024 * 1024

fd_read_exactly :: proc(fd: posix.FD, buf: []u8) -> bool {
    total := 0
    for total < len(buf) {
        n := posix.read(fd, &buf[total], uint(len(buf[total:])))
        if n <= 0 { return false }
        total += n
    }
    return true
}

fd_write_all :: proc(fd: posix.FD, buf: []u8) {
    total := 0
    for total < len(buf) {
        n := posix.write(fd, &buf[total], uint(len(buf[total:])))
        if n <= 0 { return }
        total += n
    }
}

frame_write :: proc(fd: posix.FD, msg: string) {
    if debug {
        if len(msg) <= 64 {
            fmt.eprintfln("-> frame len=%d msg=%q", len(msg), msg)
        } else {
            fmt.eprintfln("-> frame len=%d (truncated)", len(msg))
        }
    }
    body    := transmute([]u8)msg
    msg_len := u32(len(body))
    header: [4]u8 = {u8(msg_len >> 24), u8(msg_len >> 16), u8(msg_len >> 8), u8(msg_len)}
    fd_write_all(fd, header[:])
    fd_write_all(fd, body)
}

frame_read :: proc(fd: posix.FD, allocator := context.allocator) -> (string, bool) {
    header: [4]u8
    if !fd_read_exactly(fd, header[:]) { return "", false }
    msg_len := u32(header[0]) << 24 | u32(header[1]) << 16 | u32(header[2]) << 8 | u32(header[3])
    if msg_len > MAX_MESSAGE_BYTES { return "", false }
    if msg_len == 0 { return "", true }

    body := make([]u8, msg_len, allocator)
    if !fd_read_exactly(fd, body) {
        delete(body, allocator)
        return "", false
    }
    msg := string(body); if debug { preview := msg; if len(preview) > 80 { preview = preview[:80] }; fmt.eprintfln("<- frame len=%d preview=%q", len(msg), preview) }; return msg, true
}

SOCKET_DIR    :: "/tmp"
SOCKET_PREFIX :: "gjallarhorn_"

socket_path_for_dir :: proc(dirpath: string, allocator := context.allocator) -> string {
    ctx: md5.Context
    md5.init(&ctx)
    md5.update(&ctx, transmute([]u8)dirpath)
    digest: [md5.DIGEST_SIZE]u8
    md5.final(&ctx, digest[:])

    hash_hex := hex.encode(digest[:], allocator)
    defer delete(hash_hex, allocator)

    return strings.join({SOCKET_DIR, "/", SOCKET_PREFIX, string(hash_hex), ".sock"}, "", allocator)
}

daemon_is_alive :: proc(sock_path: string) -> bool {
    fd := posix.socket(.UNIX, .STREAM)
    if int(fd) < 0 { return false }
    defer posix.close(fd)

    addr := make_sockaddr_un(sock_path)
    if posix.connect(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr))) == .FAIL {
        return false
    }

    frame_write(fd, "__gh::hello__")
    response, ok := frame_read(fd, context.temp_allocator)
    if !ok { return false }

    if strings.has_prefix(response, "gjallarhorn/") {
        rest := strings.trim_prefix(response, "gjallarhorn/")
        if rest == "1" { return true }
    }
    fmt.eprintfln("gjallarhorn: handshake mismatch from daemon at %s", sock_path)
    return false
}

make_sockaddr_un :: proc(sock_path: string) -> posix.sockaddr_un {
    addr: posix.sockaddr_un
    addr.sun_family = .UNIX
    when ODIN_OS == .Darwin {
        addr.sun_len = u8(size_of(addr))
    }
    copy(addr.sun_path[:], sock_path)
    return addr
}

daemon_start :: proc(filepath: string) {
    dir := extract_parent_dir(filepath)
    defer delete(dir)

    sock_path := socket_path_for_dir(dir)
    defer delete(sock_path)

    sock_path_c := strings.clone_to_cstring(sock_path)
    defer delete(sock_path_c)

    if daemon_is_alive(sock_path) {
        fmt.eprintln("gjallarhorn: daemon already running")
        os.exit(1)
    }
    posix.unlink(sock_path_c)

    server_fd := posix.socket(.UNIX, .STREAM)
    if int(server_fd) < 0 {
        fmt.eprintfln("gjallarhorn: socket() failed: %v", posix.errno())
        os.exit(1)
    }

    addr := make_sockaddr_un(sock_path)

    if posix.bind(server_fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr))) == .FAIL {
        fmt.eprintfln("gjallarhorn: bind() failed: %v", posix.errno())
        os.exit(1)
    }
    if posix.listen(server_fd, 8) == .FAIL {
        fmt.eprintfln("gjallarhorn: listen() failed: %v", posix.errno())
        os.exit(1)
    }

    if debug { fmt.eprintfln("daemon listening: %s", sock_path) }

    defer posix.unlink(sock_path_c)

    daemon_init_index(filepath)
    daemon_serve(server_fd)
}

daemon_serve :: proc(server_fd: posix.FD) {
    for {
        client_fd := posix.accept(server_fd, nil, nil)
        if int(client_fd) < 0 { continue }
        handle_client(client_fd)
        posix.close(client_fd)
    }
}

handle_client :: proc(client_fd: posix.FD) {
    cmd, ok := frame_read(client_fd)
    if !ok {
        fmt.eprintln("gjallarhorn: protocol error: failed to read command frame")
        return
    }
    defer delete(cmd)

    if debug { fmt.eprintfln("recv cmd: %s", cmd) }

    switch cmd {
    case "comp":
        buffer, buf_ok := frame_read(client_fd)
        if !buf_ok { return }
        defer delete(buffer)
        response := respond_to_buffer(buffer)
        defer delete(response)
        frame_write(client_fd, response)

    case "index":
        filepath, path_ok := frame_read(client_fd)
        if !path_ok {
            fmt.eprintln("gjallarhorn: protocol error: bad frame for index command")
            return
        }
        defer delete(filepath)
        daemon_init_index(filepath)
        frame_write(client_fd, "")

    case "hover":
        symbol, sym_ok := frame_read(client_fd)
        if !sym_ok { return }
        defer delete(symbol)
        result := hover_lookup(symbol)
        defer delete(result)
        frame_write(client_fd, result)

    case "__gh::hello__":
        frame_write(client_fd, "gjallarhorn/1")

    case:
        fmt.eprintfln("gjallarhorn: protocol error: unknown command: %s", cmd)
        frame_write(client_fd, "")
    }
}

client_connect :: proc(filepath: string) -> (posix.FD, bool) {
    dir := extract_parent_dir(filepath)
    defer delete(dir)
    sock_path := socket_path_for_dir(dir)
    defer delete(sock_path)

    fd := posix.socket(.UNIX, .STREAM)
    if int(fd) < 0 {
        fmt.eprintfln("gjallarhorn: socket() failed: %v", posix.errno())
        return 0, false
    }

    addr := make_sockaddr_un(sock_path)

    if posix.connect(fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr))) == .FAIL {
        fmt.eprintfln("gjallarhorn: could not connect to daemon at %s", sock_path)
        posix.close(fd)
        return 0, false
    }
    return fd, true
}

client_comp :: proc(filepath: string, buffer: string) {
    fd, ok := client_connect(filepath)
    if !ok { fmt.eprintln("gjallarhorn: cannot connect to daemon"); os.exit(2) }
    defer posix.close(fd)

    frame_write(fd, "comp")
    frame_write(fd, buffer)

    response, resp_ok := frame_read(fd)
    if !resp_ok {
        fmt.eprintln("gjallarhorn: daemon returned invalid frame")
        os.exit(3)
    }
    defer delete(response)

    if len(response) > 0 {
        fmt.print(response)
    }
}

client_index :: proc(filepath: string) {
    fd, ok := client_connect(filepath)
    if !ok { fmt.eprintln("gjallarhorn: cannot connect to daemon"); os.exit(2) }
    defer posix.close(fd)

    frame_write(fd, "index")
    frame_write(fd, filepath)

    response, resp_ok := frame_read(fd)
    if !resp_ok {
        fmt.eprintln("gjallarhorn: index failed (daemon did not respond)")
        os.exit(3)
    }
    delete(response)
}

client_hover :: proc(filepath: string, symbol: string) {
    fd, ok := client_connect(filepath)
    if !ok { fmt.eprintln("gjallarhorn: cannot connect to daemon"); os.exit(2) }
    defer posix.close(fd)

    frame_write(fd, "hover")
    frame_write(fd, symbol)

    response, resp_ok := frame_read(fd)
    if !resp_ok {
        fmt.eprintln("gjallarhorn: daemon returned invalid frame")
        os.exit(3)
    }
    defer delete(response)

    fmt.print(response)
    fmt.print("\n")
}

main :: proc() {
    if len(os.args) < 3 {
        usage()
        os.exit(1)
    }

    if v, ok := os.lookup_env_alloc("GJALLARHORN_DEBUG", context.allocator); ok { debug = v == "1"; delete(v, context.allocator) }

    switch os.args[1] {
    case "--comp":
        if len(os.args) < 4 { usage(); os.exit(1) }
        client_comp(os.args[2], os.args[3])

    case "--index":
        client_index(os.args[2])

    case "--hover":
        if len(os.args) < 4 { usage(); os.exit(1) }
        client_hover(os.args[2], os.args[3])

    case "--daemon":
        daemon_start(os.args[2])

    case:
        usage()
        os.exit(1)
    }
}

usage :: proc() {
    fmt.eprintln("gjallarhorn — Odin completion daemon")
    fmt.eprintln("  gjallarhorn --daemon <absolute_filepath>")
    fmt.eprintln("  gjallarhorn --comp   <absolute_filepath> <buffer_until_cursor>")
    fmt.eprintln("  gjallarhorn --hover  <absolute_filepath> <symbol>")
    fmt.eprintln("  gjallarhorn --index  <absolute_filepath>")
}
