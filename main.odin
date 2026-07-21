package gjallarhorn

import "core:hash/xxhash"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:mem"
import "core:mem/virtual"
import "core:unicode/utf8"

indent_spaces : string = "    "

g_project_root  : string
g_socket_path_c : cstring

project_root_markers        : []string
dirs_excluded_from_indexing :: []string{"vendor"}

Struct_Field :: struct {
    name : string,
    type : string,
}

Struct_Definition :: struct {
    fields   : [dynamic]Struct_Field,
    location : Symbol_Ref,
}

Enum_Definition :: struct {
    values   : [dynamic]string,
    location : Symbol_Ref,
}

Proc_Definition :: struct {
    params   : [dynamic]string,
    returns  : [dynamic]string,
    location : Symbol_Ref,
}

Symbol_Ref :: struct {
    file : string,
    line : int,
    col  : int,
}

Package_Symbols :: struct {
    structs   : map[string]Struct_Definition,
    enums     : map[string]Enum_Definition,
    procs     : map[string]Proc_Definition,
    variables : map[string]string,
}

g_package_cache : map[string]Package_Symbols
g_package_arena : virtual.Arena
g_odin_root     : string

Project_Index :: struct {
    own_structs              : map[string]Struct_Definition,
    own_enums                : map[string]Enum_Definition,
    own_procs                : map[string]Proc_Definition,
    own_variables            : map[string]string,
    own_constants            : map[string]string,
    import_aliases           : map[string]string,
    imported_package_dirs    : map[string]string,
    all_imported_structs     : map[string]Struct_Definition,
    all_imported_enums       : map[string]Enum_Definition,
    imported_struct_sources  : map[string]string,
    imported_enum_sources    : map[string]string,
    imported_struct_conflicts: map[string][dynamic]string,
    imported_enum_conflicts  : map[string][dynamic]string,
}

g_persistent_allocator : mem.Allocator
g_index                : Project_Index

g_file_hash_cache : map[string]u64

File_Symbol_Names :: struct {
    struct_names   : [dynamic]string,
    enum_names     : [dynamic]string,
    proc_names     : [dynamic]string,
    variable_names : [dynamic]string,
    import_aliases : map[string]string,
}
g_file_symbols : map[string]File_Symbol_Names

g_file_arenas : map[string]virtual.Arena

arena_reset :: proc(arena: ^virtual.Arena) {
    if arena.curr_block == nil {
        if err := virtual.arena_init_growing(arena); err != nil {
            fmt.eprintfln("gjallarhorn: arena init failed: %v", err)
        }
        return
    }
    virtual.arena_free_all(arena)
}

file_arena :: proc(path: string) -> ^virtual.Arena {
    if arena, ok := &g_file_arenas[path]; ok { return arena }
    g_file_arenas[path] = virtual.Arena{}
    return &g_file_arenas[path]
}

make_project_index :: proc() -> Project_Index {
    return Project_Index{
        own_structs               = make(map[string]Struct_Definition),
        own_enums                 = make(map[string]Enum_Definition),
        own_procs                 = make(map[string]Proc_Definition),
        own_variables             = make(map[string]string),
        own_constants             = make(map[string]string),
        import_aliases            = make(map[string]string),
        imported_package_dirs     = make(map[string]string),
        all_imported_structs      = make(map[string]Struct_Definition),
        all_imported_enums        = make(map[string]Enum_Definition),
        imported_struct_sources   = make(map[string]string),
        imported_enum_sources     = make(map[string]string),
        imported_struct_conflicts = make(map[string][dynamic]string),
        imported_enum_conflicts   = make(map[string][dynamic]string),
    }
}

Token_Kind :: enum { EOF, Identifier, String_Literal, Double_Colon, Open_Brace, Close_Brace, Comma, Colon, Other }

Token : : struct { kind: Token_Kind, text: string, line: int, col: int }

Lexer_Mode :: enum { Normal, In_String, In_Block_Comment }
Lexer :: struct { src: string, pos: int, line: int, col: int, mode: Lexer_Mode }

lexer_make :: proc(src: string) -> Lexer { return {src = src, line = 1, col = 1} }

advance_pos :: proc(l: ^Lexer) {
    c := l.src[l.pos]
    l.pos += 1
    if c == '\n' { l.line += 1; l.col = 1 } else { l.col += 1 }
}

lexer_skip_whitespace_and_comments :: proc(l: ^Lexer) {
    block_comment_depth := 0
    for l.pos < len(l.src) {
        c := l.src[l.pos]

        if l.mode == .In_Block_Comment {
            if c == '*' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '/' {
                l.pos += 2; l.col += 2
                block_comment_depth -= 1
                if block_comment_depth == 0 { l.mode = .Normal }
                continue
            }
            if c == '/' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '*' {
                l.pos += 2; l.col += 2; block_comment_depth += 1; continue
            }
            if c == '\n' { l.pos += 1; l.line += 1; l.col = 1 } else { l.pos += 1; l.col += 1 }
            continue
        }

        if c == ' ' || c == '\t' || c == '\r' { l.pos += 1; l.col  += 1; continue }
        if c == '\n'                           { l.pos += 1; l.line += 1; l.col = 1; continue }

        if c == '/' && l.pos + 1 < len(l.src) {
            if l.src[l.pos + 1] == '/' {
                for l.pos < len(l.src) && l.src[l.pos] != '\n' { l.pos += 1 }
                continue
            }
            if l.src[l.pos + 1] == '*' {
                l.pos += 2; l.col += 2
                l.mode = .In_Block_Comment
                block_comment_depth = 1
                continue
            }
        }
        break
    }
}

lexer_next :: proc(l: ^Lexer) -> Token {
    if l.mode == .Normal { lexer_skip_whitespace_and_comments(l) }
    if l.pos >= len(l.src) { return {kind = .EOF} }

    start_line := l.line
    start_col  := l.col
    c := l.src[l.pos]

    if c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
        start := l.pos
        for l.pos < len(l.src) {
            b := l.src[l.pos]
            if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') {
                l.pos += 1; l.col += 1
            } else { break }
        }
        return {kind = .Identifier, text = l.src[start:l.pos], line = start_line, col = start_col}
    }

    if c == ':' {
        if l.pos + 1 < len(l.src) && l.src[l.pos + 1] == ':' { advance_pos(l); advance_pos(l); return {kind = .Double_Colon, text = "::", line = start_line, col = start_col} }
        advance_pos(l)
        return {kind = .Colon, text = ":", line = start_line, col = start_col}
    }

    if c == '"' {
        advance_pos(l)
        l.mode = .In_String
        start := l.pos
        for l.pos < len(l.src) && l.src[l.pos] != '"' {
            if l.src[l.pos] == '\\' { l.pos += 1; l.col += 1 }
            advance_pos(l)
        }
        text := l.src[start:l.pos]
        if l.pos < len(l.src) { advance_pos(l) }
        l.mode = .Normal
        return {kind = .String_Literal, text = text, line = start_line, col = start_col}
    }

    if c == '\'' {
        start := l.pos
        advance_pos(l)
        for l.pos < len(l.src) && l.src[l.pos] != '\'' {
            if l.src[l.pos] == '\\' { l.pos += 1; l.col += 1 }
            advance_pos(l)
        }
        if l.pos < len(l.src) { advance_pos(l) }
        return {kind = .Other, text = l.src[start:l.pos], line = start_line, col = start_col}
    }

    if c == '{' { advance_pos(l); return {kind = .Open_Brace,  text = "{", line = start_line, col = start_col} }
    if c == '}' { advance_pos(l); return {kind = .Close_Brace, text = "}", line = start_line, col = start_col} }
    if c == ',' { advance_pos(l); return {kind = .Comma,       text = ",", line = start_line, col = start_col} }

    start := l.pos
    _, w  := utf8.decode_rune_in_string(l.src[l.pos:])
    l.pos += w
    l.col += 1
    return {kind = .Other, text = l.src[start:l.pos], line = start_line, col = start_col}
}

lexer_peek :: proc(l: ^Lexer) -> Token {
    saved      := l.pos
    saved_line := l.line
    saved_col  := l.col
    saved_mode := l.mode
    tok        := lexer_next(l)
    l.pos       = saved
    l.line      = saved_line
    l.col       = saved_col
    l.mode      = saved_mode
    return tok
}

dir_contains_root_marker :: proc(dir: string) -> bool {
    for m in project_root_markers {
        path := strings.concatenate({dir, "/", m}, context.temp_allocator)
        if _, err := os.stat(path, context.temp_allocator); err == nil { return true }
    }
    return false
}

find_project_root :: proc(start_dir: string, allocator := context.allocator) -> string {
    cur := start_dir
    for {
        if dir_contains_root_marker(cur) { return strings.clone(cur, allocator) }
        slash := strings.last_index_byte(cur, '/')
        if slash <= 0 { break }
        cur = cur[:slash]
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

is_keyword :: proc(word: string) -> bool {
    switch word {
    case "case", "switch", "if", "else", "for", "when", "where", "return", "defer", "break", "continue":
        return true
    }
    return false
}

skip_to_next_statement :: proc(l: ^Lexer) {
    start_line := l.line
    for {
        tok := lexer_peek(l)
        if tok.kind == .EOF || tok.line > start_line { return }
        lexer_next(l)
    }
}

parse_type_until :: proc(l: ^Lexer, stop_check: proc(Token_Kind, string) -> bool, max_line := max(int)) -> string {
    parts := make([dynamic]string, context.allocator)
    defer delete(parts)
    for {
        pk := lexer_peek(l)
        if pk.line > max_line { break }
        if stop_check(pk.kind, pk.text) { break }
        if pk.kind == .Identifier && (len(parts) == 0 || parts[len(parts)-1] != ".") {
            saved_pos, saved_line, saved_col, saved_mode := l.pos, l.line, l.col, l.mode
            lexer_next(l)
            next_kind := lexer_peek(l).kind
            l.pos, l.line, l.col, l.mode = saved_pos, saved_line, saved_col, saved_mode
            if next_kind == .Colon || next_kind == .Double_Colon { break }
        }
        t := lexer_next(l)
        if t.text != "" { append(&parts, t.text) }
    }
    return strings.join(parts[:], "")
}

peek_rhs_type :: proc(l: ^Lexer) -> string {
    tok := lexer_peek(l)
    if tok.kind == .String_Literal { skip_to_next_statement(l); return "string" }
    if tok.kind == .Other && len(tok.text) > 0 && tok.text[0] >= '0' && tok.text[0] <= '9' { skip_to_next_statement(l); return "int" }
    if tok.kind == .Identifier {
        switch tok.text {
        case "true", "false": skip_to_next_statement(l); return "bool"
        case "nil":           skip_to_next_statement(l); return ""
        }
    }
    type_str := parse_type_until(l, proc(k: Token_Kind, t: string) -> bool {
        return k == .EOF || k == .Open_Brace || k == .Colon ||
               (k == .Other && (t == "=" || t == "("))
    }, tok.line)
    skip_to_next_statement(l)
    return type_str
}

File_Parse_Result :: struct {
    file_path      : string,
    own_structs    : map[string]Struct_Definition,
    own_enums      : map[string]Enum_Definition,
    own_procs      : map[string]Proc_Definition,
    own_variables  : map[string]string,
    own_constants  : map[string]string,
    import_aliases : map[string]string,
}

parse_source_file :: proc(file_path: string, src: string) -> File_Parse_Result {
    result := File_Parse_Result{
        file_path      = strings.clone(file_path),
        own_structs    = make(map[string]Struct_Definition),
        own_enums      = make(map[string]Enum_Definition),
        own_procs      = make(map[string]Proc_Definition),
        own_variables  = make(map[string]string),
        own_constants  = make(map[string]string),
        import_aliases = make(map[string]string),
    }
    l           := lexer_make(src)
    paren_depth := 0
    brace_depth := 0

    loc := Symbol_Ref{file = result.file_path}

    for {
        tok := lexer_next(&l)
        if tok.kind == .EOF { break }
        if tok.kind == .Open_Brace  { brace_depth += 1; continue }
        if tok.kind == .Close_Brace { if brace_depth > 0 { brace_depth -= 1 }; continue }
        if tok.kind == .Other {
            if tok.text == "(" { paren_depth += 1 }
            if tok.text == ")" && paren_depth > 0 { paren_depth -= 1 }
            continue
        }
        if tok.kind != .Identifier || paren_depth > 0 || brace_depth > 0 { continue }

        name := tok.text
        loc.line = tok.line
        loc.col  = tok.col

        if is_keyword(name) { continue }

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
                result.import_aliases[strings.clone(alias)] = strings.clone(path)
            }
            continue
        }

        next := lexer_peek(&l)

        if next.kind == .Double_Colon {
            lexer_next(&l)
            after := lexer_peek(&l)
            if after.kind == .Identifier {
                switch after.text {
                case "struct":
                    lexer_next(&l)
                    s := parse_struct_body(&l)
                    s.location = loc
                    result.own_structs[strings.clone(name)] = s
                case "enum":
                    lexer_next(&l)
                    e := parse_enum_body(&l)
                    e.location = loc
                    result.own_enums[strings.clone(name)] = e
                case "proc":
                    lexer_next(&l)
                    p := parse_proc_signature(&l)
                    p.location = loc
                    result.own_procs[strings.clone(name)] = p
                case:
                    type_str := parse_type_until(&l, proc(k: Token_Kind, t: string) -> bool {
                        return k == .EOF || k == .Comma || k == .Open_Brace
                    })
                    if type_str != "" { result.own_variables[strings.clone(name)] = type_str }
                }
            } else if after.kind == .String_Literal || after.kind == .Other {
                rhs_start := l.pos
                type_str  := peek_rhs_type(&l)
                if type_str != "" {
                    result.own_variables[strings.clone(name)] = type_str
                    raw_val := after.text if after.kind == .String_Literal else strings.trim_right(l.src[rhs_start:l.pos], " \t\r\n")
                    if raw_val != "" { result.own_constants[strings.clone(name)] = strings.clone(raw_val) }
                }
            }
            continue
        }

        if next.kind == .Colon {
            lexer_next(&l)
            type_tok := lexer_peek(&l)

            if type_tok.kind == .Other && type_tok.text == "=" {
                lexer_next(&l)
                type_str := peek_rhs_type(&l)
                if type_str != "" { result.own_variables[strings.clone(name)] = type_str }
                continue
            }

            if type_tok.kind == .Colon {
                lexer_next(&l)
                after := lexer_peek(&l)
                if after.kind == .Identifier {
                    switch after.text {
                    case "struct":
                        lexer_next(&l)
                        s := parse_struct_body(&l)
                        s.location = loc
                        result.own_structs[strings.clone(name)] = s
                    case "enum":
                        lexer_next(&l)
                        e := parse_enum_body(&l)
                        e.location = loc
                        result.own_enums[strings.clone(name)] = e
                    case "proc":
                        lexer_next(&l)
                        p := parse_proc_signature(&l)
                        p.location = loc
                        result.own_procs[strings.clone(name)] = p
                    case:
                        type_str := parse_type_until(&l, proc(k: Token_Kind, t: string) -> bool {
                            return k == .EOF || k == .Comma || k == .Open_Brace
                        })
                        if type_str != "" { result.own_variables[strings.clone(name)] = type_str }
                    }
                } else if after.kind == .String_Literal || after.kind == .Other {
                    rhs_start := l.pos
                    type_str  := peek_rhs_type(&l)
                    if type_str != "" {
                        result.own_variables[strings.clone(name)] = type_str
                        raw_val := after.text if after.kind == .String_Literal else strings.trim_right(l.src[rhs_start:l.pos], " \t\r\n")
                        if nl := strings.index_byte(raw_val, '\n'); nl >= 0 { raw_val = strings.trim_right(raw_val[:nl], " \t\r") }
                        if raw_val != "" { result.own_constants[strings.clone(name)] = strings.clone(raw_val) }
                    }
                }
                continue
            }

            type_parts  := make([dynamic]string, context.temp_allocator)
            start_line  := type_tok.line
            depth := 0
            for {
                pk := lexer_peek(&l)
                if pk.kind == .EOF || pk.line > start_line { break }
                if pk.kind == .Colon && depth == 0 { break }
                if pk.kind == .Other && pk.text == "=" && depth == 0 { break }
                if pk.kind == .Open_Brace { break }
                if pk.kind == .Other && pk.text == "(" { depth += 1 }
                if pk.kind == .Other && pk.text == ")" && depth > 0 { depth -= 1 }
                t := lexer_next(&l)
                if t.text != "" { append(&type_parts, t.text) }
            }
            type_str := strings.join(type_parts[:], "")

            if type_str != "" && !is_keyword(type_str) {
                result.own_variables[strings.clone(name)] = type_str
                if lexer_peek(&l).kind == .Colon {
                    lexer_next(&l)
                    val_tok := lexer_peek(&l)
                    raw_val := val_tok.text if val_tok.kind == .String_Literal else strings.trim_right(l.src[l.pos:], " \t\r\n")
                    if nl := strings.index_byte(raw_val, '\n'); nl >= 0 { raw_val = strings.trim_right(raw_val[:nl], " \t\r") }
                    if raw_val != "" { result.own_constants[strings.clone(name)] = strings.clone(raw_val) }
                    skip_to_next_statement(&l)
                }
            }
        }
    }

    return result
}

parse_struct_body :: proc(l: ^Lexer) -> Struct_Definition {
    defn  := Struct_Definition{fields = make([dynamic]Struct_Field)}
    depth := 0
    for { tok := lexer_next(l); if tok.kind == .EOF { return defn }; if tok.kind == .Open_Brace { depth = 1; break } }

    for depth > 0 {
        tok := lexer_next(l)
        #partial switch tok.kind {
        case .EOF:         return defn
        case .Open_Brace:  depth += 1
        case .Close_Brace: depth -= 1
        case .Identifier:
            if depth != 1 { continue }
            field_name := tok.text
            if lexer_peek(l).kind != .Colon { continue }
            lexer_next(l)

            field_type := parse_type_until(l, proc(k: Token_Kind, t: string) -> bool {
                return k == .EOF || k == .Comma || k == .Close_Brace
            })
            if lexer_peek(l).kind == .Comma { lexer_next(l) }

            append(&defn.fields, Struct_Field{
                name = strings.clone(field_name),
                type = field_type,
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

type_list_is_named :: proc(l: ^Lexer) -> bool {
    saved_pos, saved_line, saved_col, saved_mode := l.pos, l.line, l.col, l.mode
    defer { l.pos = saved_pos; l.line = saved_line; l.col = saved_col; l.mode = saved_mode }

    depth := 0
    for {
        tok := lexer_next(l)
        if tok.kind == .EOF { return false }
        if tok.kind == .Colon { return true }
        if tok.kind == .Other && tok.text == "(" { depth += 1 }
        if tok.kind == .Other && tok.text == ")" {
            if depth == 0 { return false }
            depth -= 1
        }
    }
}

parse_bare_type_list :: proc(l: ^Lexer) -> [dynamic]string {
    types := make([dynamic]string)
    for {
        parts := make([dynamic]string, context.allocator)
        defer delete(parts)
        depth := 0
        for {
            pk := lexer_peek(l)
            if pk.kind == .EOF { break }
            if pk.kind == .Other && pk.text == "(" { depth += 1 }
            if pk.kind == .Other && pk.text == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0 && pk.kind == .Comma { break }
            append(&parts, lexer_next(l).text)
        }
        if joined := strings.join(parts[:], ""); joined != "" { append(&types, joined) }
        if lexer_peek(l).kind == .Comma { lexer_next(l); continue }
        return types
    }
}

parse_type_list :: proc(l: ^Lexer) -> [dynamic]string {
    if !type_list_is_named(l) { return parse_bare_type_list(l) }

    types := make([dynamic]string)
    for {
        for {
            pk := lexer_peek(l)
            if pk.kind == .EOF { return types }
            if pk.kind == .Other && pk.text == ")" { return types }
            if pk.kind == .Colon { break }
            lexer_next(l)
        }
        lexer_next(l)

        parts := make([dynamic]string, context.allocator)
        defer delete(parts)
        for {
            pk := lexer_peek(l)
            if pk.kind == .EOF { break }
            if pk.kind == .Other && (pk.text == ")" || pk.text == "=") { break }
            if pk.kind == .Comma { break }
            append(&parts, lexer_next(l).text)
        }
        if joined := strings.join(parts[:], ""); joined != "" { append(&types, joined) }

        if lexer_peek(l).kind == .Comma { lexer_next(l) }
    }
}

parse_proc_signature :: proc(l: ^Lexer) -> Proc_Definition {
    defn := Proc_Definition{params = make([dynamic]string), returns = make([dynamic]string)}

    if lexer_peek(l).kind == .String_Literal { lexer_next(l) }
    open := lexer_next(l)
    if open.kind != .Other || open.text != "(" { return defn }

    defn.params = parse_type_list(l)
    if lexer_peek(l).kind == .Other && lexer_peek(l).text == ")" { lexer_next(l) }

    if lexer_peek(l).kind == .Other && lexer_peek(l).text == "-" {
        lexer_next(l)
        if lexer_peek(l).kind == .Other && lexer_peek(l).text == ">" { lexer_next(l) }

        if lexer_peek(l).kind == .Other && lexer_peek(l).text == "(" {
            lexer_next(l)
            defn.returns = parse_type_list(l)
            if lexer_peek(l).kind == .Other && lexer_peek(l).text == ")" { lexer_next(l) }
        } else {
            parts := make([dynamic]string, context.allocator)
            defer delete(parts)
            for {
                pk := lexer_peek(l)
                if pk.kind == .EOF || pk.kind == .Open_Brace { break }
                if pk.kind == .Other && (pk.text == "-" || pk.text == "#") { break }
                append(&parts, lexer_next(l).text)
            }
            if joined := strings.join(parts[:], ""); joined != "" { append(&defn.returns, joined) }
        }
    }

    return defn
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

resolve_import_to_dir :: proc(import_path: string, source_dir: string) -> (string, bool) {
    colon := -1
    for i := 0; i < len(import_path); i += 1 { if import_path[i] == ':' { colon = i; break } }

    if colon != -1 {
        root, ok := get_odin_root()
        if !ok { return "", false }
        return strings.concatenate({root, "/", import_path[:colon], "/", import_path[colon + 1:]}), true
    }

    return strings.concatenate({source_dir, "/", import_path}), true
}

load_package_symbols :: proc(package_dir: string) {
    if package_dir in g_package_cache { return }

    outer := context.allocator
    context.allocator = virtual.arena_allocator(&g_package_arena)

    pkg := Package_Symbols{
        structs   = make(map[string]Struct_Definition),
        enums     = make(map[string]Enum_Definition),
        procs     = make(map[string]Proc_Definition),
        variables = make(map[string]string),
    }

    type_aliases := make(map[string]string)

    file_infos, err := os.read_all_directory_by_path(package_dir, context.allocator)
    if err != nil {
        context.allocator = outer
        g_package_cache[package_dir] = pkg
        return
    }
    defer os.file_info_slice_delete(file_infos, context.allocator)

    for fi in file_infos {
        if fi.type == .Directory                       { continue }
        if !strings.has_suffix(fi.name, ".odin")      { continue }
        if  strings.has_suffix(fi.name, "_test.odin") { continue }

        full_path := strings.concatenate({package_dir, "/", fi.name}, context.allocator)
        src_data, read_err := os.read_entire_file_from_path(full_path, context.allocator)
        if read_err != nil { delete(full_path, context.allocator); continue }

        file_result := parse_source_file(full_path, string(src_data))
        delete(full_path, context.allocator)
        delete(src_data, context.allocator)

        for k, &s in file_result.own_structs   { pkg.structs[k]  = s }
        for k, &e in file_result.own_enums     { pkg.enums[k]    = e }
        for k, &p in file_result.own_procs     { pkg.procs[k]    = p }
        for k,  v in file_result.own_variables { type_aliases[k] = v }
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
        } else {
            pkg.variables[strings.clone(alias_name)] = strings.clone(resolved)
        }
    }

    context.allocator = outer
    g_package_cache[package_dir] = pkg
}

register_package_into_index :: proc(idx: ^Project_Index, alias: string, package_dir: string) {
    cached, ok := g_package_cache[package_dir]
    if !ok { return }
    if alias != "." {
        if existing, already := idx.imported_package_dirs[alias]; already && existing == package_dir { return }
        idx.imported_package_dirs[strings.clone(alias)] = strings.clone(package_dir)
    }
    for name, defn in cached.structs {
        if name in idx.own_structs { continue }
        if name not_in idx.all_imported_structs {
            idx.all_imported_structs[name] = defn
            idx.imported_struct_sources[strings.clone(name)] = strings.clone(alias)
        } else {
            existing_source := idx.imported_struct_sources[name]
            existing_dir, ok := idx.imported_package_dirs[existing_source]
            if ok && existing_dir == package_dir { continue }
            if name not_in idx.imported_struct_conflicts {
                idx.imported_struct_conflicts[strings.clone(name)] = make([dynamic]string)
                append(&idx.imported_struct_conflicts[name], strings.clone(existing_source))
                append(&idx.imported_struct_conflicts[name], strings.clone(alias))
            } else {
                found := false
                for existing in idx.imported_struct_conflicts[name] {
                    if existing == alias { found = true; break }
                }
                if !found { append(&idx.imported_struct_conflicts[name], strings.clone(alias)) }
            }
        }
    }
    for name, defn in cached.enums {
        if name in idx.own_enums { continue }
        if name not_in idx.all_imported_enums {
            idx.all_imported_enums[name] = defn
            idx.imported_enum_sources[strings.clone(name)] = strings.clone(alias)
        } else {
            existing_source := idx.imported_enum_sources[name]
            existing_dir, ok := idx.imported_package_dirs[existing_source]
            if ok && existing_dir == package_dir { continue }
            if name not_in idx.imported_enum_conflicts {
                idx.imported_enum_conflicts[strings.clone(name)] = make([dynamic]string)
                append(&idx.imported_enum_conflicts[name], strings.clone(existing_source))
                append(&idx.imported_enum_conflicts[name], strings.clone(alias))
            } else {
                found := false
                for existing in idx.imported_enum_conflicts[name] {
                    if existing == alias { found = true; break }
                }
                if !found { append(&idx.imported_enum_conflicts[name], strings.clone(alias)) }
            }
        }
    }
}

resolve_and_load_imports :: proc(idx: ^Project_Index, source_dir: string) {
    for alias, import_path in idx.import_aliases {
        if alias == "_" { continue }
        package_dir, ok := resolve_import_to_dir(import_path, source_dir)
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

index_one_file :: proc(path: string, src: string) -> File_Parse_Result {
    arena := file_arena(path)
    arena_reset(arena)

    outer := context.allocator
    context.allocator = virtual.arena_allocator(arena)
    scratch := parse_source_file(path, src)
    context.allocator = outer

    context.allocator = g_persistent_allocator
    syms := File_Symbol_Names{
        struct_names   = make([dynamic]string),
        enum_names     = make([dynamic]string),
        proc_names     = make([dynamic]string),
        variable_names = make([dynamic]string),
        import_aliases = make(map[string]string),
    }
    for name in scratch.own_structs    { append(&syms.struct_names,   strings.clone(name)) }
    for name in scratch.own_enums      { append(&syms.enum_names,     strings.clone(name)) }
    for name in scratch.own_procs      { append(&syms.proc_names,     strings.clone(name)) }
    for name in scratch.own_variables  { append(&syms.variable_names, strings.clone(name)) }
    for alias, imp in scratch.import_aliases {
        syms.import_aliases[strings.clone(alias)] = strings.clone(imp)
    }
    g_file_symbols[path] = syms

    persistent := parse_source_file(path, src)
    context.allocator = outer

    return persistent
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
        if read_err != nil { delete(full_path, context.allocator); continue }

        file_result := index_one_file(full_path, string(src_data))
        merge_file_into_index(idx, &file_result)
        g_file_hash_cache[full_path] = file_hash(src_data)

        delete(src_data, context.allocator)
        found = true
    }

    return found
}

index_project_tree :: proc(project_root: string) -> (Project_Index, [dynamic]string) {
    idx          := make_project_index()
    visited_dirs := make([dynamic]string)
    dir_stack    := make([dynamic]string, context.allocator)
    append(&dir_stack, strings.clone(project_root, context.allocator))

    for len(dir_stack) > 0 {
        current := dir_stack[len(dir_stack) - 1]
        pop(&dir_stack)

        if index_directory(&idx, current) { append(&visited_dirs, strings.clone(current, context.allocator)) }

        sub_entries, sub_err := os.read_all_directory_by_path(current, context.allocator)
        if sub_err != nil { continue }
        for e in sub_entries {
            if e.type != .Directory || dir_should_be_skipped(e.name) { continue }
            path := strings.concatenate({current, "/", e.name}, context.allocator)
            append(&dir_stack, path)
        }
        os.file_info_slice_delete(sub_entries, context.allocator)
    }

    for dir in visited_dirs {
        resolve_and_load_imports(&idx, dir)
    }

    return idx, visited_dirs
}

merge_file_into_index :: proc(idx: ^Project_Index, file_result: ^File_Parse_Result) {
    for k, &s in file_result.own_structs    { idx.own_structs[k]    = s }
    for k, &e in file_result.own_enums      { idx.own_enums[k]      = e }
    for k,  v in file_result.own_procs      { idx.own_procs[k]      = v }
    for k,  v in file_result.own_variables  { idx.own_variables[k]  = v }
    for k,  v in file_result.own_constants  { idx.own_constants[k]  = v }
    for k,  v in file_result.import_aliases { idx.import_aliases[k] = v }
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
    delete(idx.own_structs)
    delete(idx.own_enums)
    delete(idx.own_procs)
    delete(idx.own_variables)
    delete(idx.own_constants)
    delete(idx.import_aliases)
    delete(idx.all_imported_structs)
    delete(idx.all_imported_enums)

    for k, v in idx.imported_package_dirs    { delete(k); delete(v) }
    delete(idx.imported_package_dirs)

    for k, v in idx.imported_struct_sources  { delete(k); delete(v) }
    delete(idx.imported_struct_sources)

    for k, v in idx.imported_enum_sources    { delete(k); delete(v) }
    delete(idx.imported_enum_sources)

    for k, &v in idx.imported_struct_conflicts { for s in v { delete(s) }; delete(v); delete(k) }
    delete(idx.imported_struct_conflicts)

    for k, &v in idx.imported_enum_conflicts   { for s in v { delete(s) }; delete(v); delete(k) }
    delete(idx.imported_enum_conflicts)
}

package_cache_destroy :: proc() {
    delete(g_package_cache)
    arena_reset(&g_package_arena)
}

file_hash :: proc(data: []u8) -> u64 {
    return xxhash.XXH64(data, 0)
}

build_index :: proc(project_root: string) {
    fmt.eprintfln("index build begin  root=%s", project_root)

    g_persistent_allocator = context.allocator

    project_index_destroy(&g_index)
    package_cache_destroy()

    g_package_cache = make(map[string]Package_Symbols)

    new_index, visited_dirs := index_project_tree(project_root)
    for dir in visited_dirs { load_package_symbols(dir) }

    g_index = new_index

    fmt.eprintfln("index build complete root=%s", project_root)
}

reindex_from_content :: proc(path: string, was_cached: bool, src: []u8) {
    p := path if was_cached else strings.clone(path, g_persistent_allocator)

    if old_syms, ok := g_file_symbols[p]; ok {
        for name in old_syms.struct_names   { delete_key(&g_index.own_structs,   name) }
        for name in old_syms.enum_names     { delete_key(&g_index.own_enums,     name) }
        for name in old_syms.proc_names     { delete_key(&g_index.own_procs,     name) }
        for name in old_syms.variable_names { delete_key(&g_index.own_variables, name); delete_key(&g_index.own_constants, name) }
    }

    file_result := index_one_file(p, string(src))
    merge_file_into_index(&g_index, &file_result)

    clear(&g_index.import_aliases)
    clear(&g_index.imported_package_dirs)
    for _, syms in g_file_symbols {
        for alias, imp in syms.import_aliases {
            if alias != "_" && alias != "" {
                g_index.import_aliases[strings.clone(alias, g_persistent_allocator)] = strings.clone(imp, g_persistent_allocator)
            }
        }
    }

    valid_sources := make(map[string]bool, context.temp_allocator)
    for alias in g_index.import_aliases { valid_sources[alias] = true }

    prune_stale_imports :: proc(
        imported  : ^map[string]$D,
        sources   : ^map[string]string,
        conflicts : ^map[string][dynamic]string,
        valid     : map[string]bool,
    ) {
        to_delete := make([dynamic]string, context.temp_allocator)
        for name, source in sources^ {
            if source not_in valid { append(&to_delete, name) }
        }
        for name in to_delete {
            delete_key(imported,  name)
            delete_key(sources,   name)
            delete_key(conflicts, name)
        }
    }

    prune_stale_imports(&g_index.all_imported_structs, &g_index.imported_struct_sources, &g_index.imported_struct_conflicts, valid_sources)
    prune_stale_imports(&g_index.all_imported_enums,   &g_index.imported_enum_sources,   &g_index.imported_enum_conflicts,   valid_sources)

    source_dir := path_parent_dir(p, context.temp_allocator)
    resolve_and_load_imports(&g_index, source_dir)
}

rebuild_index :: proc(trigger_file: string) {
    src_data, read_err := os.read_entire_file_from_path(trigger_file, context.temp_allocator)
    if read_err != nil {
        fmt.eprintfln("gjallarhorn: index rebuild error reading file=%s", trigger_file)
        return
    }

    hash := file_hash(src_data)
    cached_hash, was_cached := g_file_hash_cache[trigger_file]
    if was_cached && cached_hash == hash { return }

    reindex_from_content(trigger_file, was_cached, src_data)

    g_file_hash_cache[trigger_file if was_cached else strings.clone(trigger_file, g_persistent_allocator)] = hash
}

rebuild_index_from_buf :: proc(path: string, src: string) {
    _, was_cached := g_file_hash_cache[path]
    reindex_from_content(path, was_cached, transmute([]u8)src)
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

resolve_to_known_type :: proc(name: string) -> string {
    if name in g_index.own_structs               { return name }
    if name in g_index.own_enums                 { return name }
    if name in g_index.imported_struct_conflicts { return "" }
    if name in g_index.all_imported_structs      { return name }
    if name in g_index.imported_enum_conflicts   { return "" }
    if name in g_index.all_imported_enums        { return name }
    if t, ok := g_index.own_variables[name]; ok  { return t   }
    return ""
}

resolve_name_to_type :: proc(name: string, local_ctx: string) -> string {
    if t := resolve_to_known_type(name); t != "" { return t }
    if t, ok := resolve_local_var_type(local_ctx, name); ok { return t }
    return ""
}

parse_local_vars :: proc(src: string, consts: ^map[string]string = nil) -> map[string]string {
    vars        := make(map[string]string)
    l           := lexer_make(src)
    paren_depth := 0
    brace_depth := 0

    for {
        tok := lexer_next(&l)
        if tok.kind == .EOF { break }
        if tok.kind == .Open_Brace  { brace_depth += 1; continue }
        if tok.kind == .Close_Brace { if brace_depth > 0 { brace_depth -= 1 }; continue }
        if tok.kind == .Other {
            if tok.text == "(" { paren_depth += 1 }
            if tok.text == ")" && paren_depth > 0 { paren_depth -= 1 }
            continue
        }
        if tok.kind != .Identifier || paren_depth > 0 || brace_depth < 1 { continue }

        name := tok.text
        if is_keyword(name) { continue }

        next := lexer_peek(&l)

        if next.kind == .Double_Colon {
            lexer_next(&l)
            after := lexer_peek(&l)
            if after.kind == .Identifier && after.text != "struct" && after.text != "enum" && after.text != "proc" {
                type_str := parse_type_until(&l, proc(k: Token_Kind, t: string) -> bool {
                    return k == .EOF || k == .Comma || k == .Open_Brace
                })
                if type_str != "" { vars[strings.clone(name)] = type_str }
            } else if after.kind == .String_Literal || after.kind == .Other {
                rhs_start := l.pos
                type_str  := peek_rhs_type(&l)
                if type_str != "" {
                    vars[strings.clone(name)] = type_str
                    if consts != nil {
                        raw_val := after.text if after.kind == .String_Literal else strings.trim_right(l.src[rhs_start:l.pos], " \t\r\n")
                        if raw_val != "" { consts[strings.clone(name)] = strings.clone(raw_val) }
                    }
                }
            }
            continue
        }

        if next.kind == .Colon {
            lexer_next(&l)
            type_tok := lexer_peek(&l)

            if type_tok.kind == .Other && type_tok.text == "=" {
                lexer_next(&l)
                type_str := peek_rhs_type(&l)
                if type_str != "" { vars[strings.clone(name)] = type_str }
                continue
            }

            if type_tok.kind == .Colon {
                lexer_next(&l)
                after := lexer_peek(&l)
                if after.kind == .Identifier && (after.text == "struct" || after.text == "enum" || after.text == "proc") {
                } else if after.kind == .String_Literal || after.kind == .Other {
                    rhs_start := l.pos
                    type_str  := peek_rhs_type(&l)
                    if type_str != "" {
                        vars[strings.clone(name)] = type_str
                        if consts != nil {
                            raw_val := after.text if after.kind == .String_Literal else strings.trim_right(l.src[rhs_start:l.pos], " \t\r\n")
                            if nl := strings.index_byte(raw_val, '\n'); nl >= 0 { raw_val = strings.trim_right(raw_val[:nl], " \t\r") }
                            if raw_val != "" { consts[strings.clone(name)] = strings.clone(raw_val) }
                        }
                    }
                } else if after.kind == .Identifier {
                    type_str := peek_rhs_type(&l)
                    if type_str != "" { vars[strings.clone(name)] = type_str }
                }
                continue
            }

            type_parts := make([dynamic]string, context.temp_allocator)
            start_line := type_tok.line
            depth := 0
            for {
                pk := lexer_peek(&l)
                if pk.kind == .EOF || pk.line > start_line { break }
                if pk.kind == .Colon && depth == 0 { break }
                if pk.kind == .Other && pk.text == "=" && depth == 0 { break }
                if pk.kind == .Open_Brace { break }
                if pk.kind == .Other && pk.text == "(" { depth += 1 }
                if pk.kind == .Other && pk.text == ")" && depth > 0 { depth -= 1 }
                t := lexer_next(&l)
                if t.text != "" { append(&type_parts, t.text) }
            }
            type_str := strings.join(type_parts[:], "")

            if type_str != "" && !is_keyword(type_str) {
                vars[strings.clone(name)] = type_str
                if consts != nil && lexer_peek(&l).kind == .Colon {
                    lexer_next(&l)
                    val_tok := lexer_peek(&l)
                    raw_val := val_tok.text if val_tok.kind == .String_Literal else strings.trim_right(l.src[l.pos:], " \t\r\n")
                    if nl := strings.index_byte(raw_val, '\n'); nl >= 0 { raw_val = strings.trim_right(raw_val[:nl], " \t\r") }
                    if raw_val != "" { consts[strings.clone(name)] = strings.clone(raw_val) }
                    skip_to_next_statement(&l)
                }
            }
        }
    }
    return vars
}

resolve_local_var_type :: proc(local_ctx: string, var_name: string) -> (string, bool) {
    vars := parse_local_vars(local_ctx)
    defer delete(vars)

    if t, ok := vars[var_name]; ok {
        if defn, is_proc := g_index.own_procs[t]; is_proc && len(defn.returns) > 0 {
            return strings.clone(defn.returns[0]), true
        }
        return strings.clone(t), true
    }

    first_line := local_ctx
    if nl := strings.index_byte(local_ctx, '\n'); nl >= 0 { first_line = local_ctx[:nl] }
    if start := strings.index_byte(first_line, '('); start >= 0 {
        if t, ok := param_type_from_sig(first_line[start:], var_name); ok { return t, true }
    }

    return "", false
}

param_type_from_sig :: proc(sig: string, var_name: string) -> (string, bool) {
    l := lexer_make(sig)
    depth := 0
    for {
        tok := lexer_next(&l)
        if tok.kind == .EOF { break }
        if tok.kind == .Other {
            if tok.text == "(" { depth += 1 }
            if tok.text == ")" { if depth > 0 { depth -= 1 }; if depth == 0 { break } }
            continue
        }
        if tok.kind != .Identifier || depth == 0 { continue }
        if tok.text != var_name { continue }
        next := lexer_peek(&l)
        if next.kind != .Colon { continue }
        lexer_next(&l)
        type_str := parse_type_until(&l, proc(k: Token_Kind, t: string) -> bool {
            return k == .EOF || k == .Comma || k == .Other && (t == ")" || t == "=")
        })
        if type_str != "" { return type_str, true }
    }
    return "", false
}

format_struct :: proc(name: string, defn: Struct_Definition) -> string {
    max_len := 0
    for f in defn.fields { if len(f.name) > max_len { max_len = len(f.name) } }
    sb := strings.builder_make()
    strings.write_string(&sb, name); strings.write_string(&sb, " struct\n")
    for f in defn.fields {
        strings.write_string(&sb, indent_spaces)
        strings.write_string(&sb, f.name)
        for _ in 0 ..< max_len - len(f.name) { strings.write_byte(&sb, ' ') }
        strings.write_byte(&sb, ' ')
        strings.write_string(&sb, f.type); strings.write_byte(&sb, '\n')
    }
    return strings.to_string(sb)
}

format_enum :: proc(name: string, defn: Enum_Definition) -> string {
    sb := strings.builder_make()
    strings.write_string(&sb, name); strings.write_string(&sb, " enum\n")
    for v in defn.values {
        strings.write_string(&sb, indent_spaces); strings.write_string(&sb, v); strings.write_byte(&sb, '\n')
    }
    return strings.to_string(sb)
}

format_proc :: proc(name: string, defn: Proc_Definition) -> string {
    sb := strings.builder_make()
    strings.write_string(&sb, name); strings.write_string(&sb, " proc")
    for p in defn.params {
        strings.write_byte(&sb, '\n'); strings.write_string(&sb, indent_spaces)
        strings.write_string(&sb, "<- "); strings.write_string(&sb, p)
    }
    for r in defn.returns {
        strings.write_byte(&sb, '\n'); strings.write_string(&sb, indent_spaces)
        strings.write_string(&sb, "-> "); strings.write_string(&sb, r)
    }
    return strings.to_string(sb)
}

proc_signature_summary :: proc(defn: Proc_Definition) -> string {
    params := strings.join(defn.params[:], ", ")
    if len(defn.returns) == 0 { return fmt.tprintf("(%s)", params) }
    return fmt.tprintf("(%s) -> %s", params, strings.join(defn.returns[:], ", "))
}

hover_for_type :: proc(type_name: string) -> string {
    lookup := strings.trim_prefix(type_name, "^")
    if d, found := g_index.own_structs[lookup];          found { return format_struct(type_name, d) }
    if d, found := g_index.own_enums[lookup];            found { return format_enum(type_name, d)   }
    if d, found := g_index.all_imported_structs[lookup]; found { return format_struct(type_name, d) }
    if d, found := g_index.all_imported_enums[lookup];   found { return format_enum(type_name, d)   }
    if alias, name, has_dot := split_at_dot(lookup); has_dot {
        if pkg := package_by_alias(alias); pkg != nil {
            if d, found := pkg.structs[name];   found { return format_struct(type_name, d)          }
            if d, found := pkg.enums[name];     found { return format_enum(type_name, d)            }
            if t, found := pkg.variables[name]; found { return fmt.tprintf("%s %s", type_name, t) }
        }
    }
    return ""
}

qualifier_from_ctx :: proc(local_ctx: string, symbol: string) -> string {
    ctx := local_ctx
    for line in strings.split_lines_iterator(&ctx) {
        search := 0
        for {
            idx := strings.index(line[search:], symbol)
            if idx == -1 { break }
            abs := search + idx
            dot := abs - 1
            if dot < 0 || line[dot] != '.' { search = abs + 1; continue }
            alias_end   := dot
            alias_start := alias_end - 1
            for alias_start > 0 && (line[alias_start-1] == '_' || (line[alias_start-1] >= 'a' && line[alias_start-1] <= 'z') || (line[alias_start-1] >= 'A' && line[alias_start-1] <= 'Z') || (line[alias_start-1] >= '0' && line[alias_start-1] <= '9')) { alias_start -= 1 }
            alias := line[alias_start:alias_end]
            if _, ok := g_index.imported_package_dirs[alias]; ok {
                return strings.concatenate({alias, ".", symbol}, context.temp_allocator)
            }
            search = abs + 1
        }
    }
    return ""
}

hover_info :: proc(symbol: string, local_ctx: string) -> string {
    if d, ok := g_index.own_structs[symbol]; ok { return format_struct(symbol, d) }
    if d, ok := g_index.own_enums[symbol];   ok { return format_enum(symbol, d)   }
    if d, ok := g_index.own_procs[symbol];   ok { return format_proc(symbol, d)   }

    if symbol in g_index.imported_struct_conflicts || symbol in g_index.imported_enum_conflicts {
        if qualified := qualifier_from_ctx(local_ctx, symbol); qualified != "" {
            if s := hover_for_type(qualified); s != "" { return s }
        }
        conflicts := g_index.imported_struct_conflicts[symbol]
        if len(conflicts) == 0 { conflicts = g_index.imported_enum_conflicts[symbol] }
        return fmt.tprintf("%s: ambiguous (defined in %s)", symbol, strings.join(conflicts[:], ", "))
    }
    if d, ok := g_index.all_imported_structs[symbol]; ok { return format_struct(symbol, d) }
    if d, ok := g_index.all_imported_enums[symbol];   ok { return format_enum(symbol, d)   }

    if qualified := qualifier_from_ctx(local_ctx, symbol); qualified != "" {
        if s := hover_for_type(qualified); s != "" { return s }
    }

    if v, ok := g_index.own_constants[symbol]; ok { return v }

    type_name    := ""
    local_consts := make(map[string]string)
    defer delete(local_consts)
    if t, ok := g_index.own_variables[symbol]; ok {
        type_name = t
    } else {
        vars := parse_local_vars(local_ctx, &local_consts)
        defer delete(vars)
        if v, ok := local_consts[symbol]; ok { return v }
        if t, ok := vars[symbol]; ok {
            if defn, is_proc := g_index.own_procs[t]; is_proc && len(defn.returns) > 0 {
                type_name = defn.returns[0]
            } else {
                type_name = t
            }
        } else {
            first_line := local_ctx
            if nl := strings.index_byte(local_ctx, '\n'); nl >= 0 { first_line = local_ctx[:nl] }
            if start := strings.index_byte(first_line, '('); start >= 0 {
                if t, ok := param_type_from_sig(first_line[start:], symbol); ok { type_name = t }
            }
        }
    }

    if type_name != "" {
        if type_name in g_index.imported_struct_conflicts {
            return fmt.tprintf("%s: ambiguous (defined in %s)", symbol, strings.join(g_index.imported_struct_conflicts[type_name][:], ", "))
        }
        if type_name in g_index.imported_enum_conflicts {
            return fmt.tprintf("%s: ambiguous (defined in %s)", symbol, strings.join(g_index.imported_enum_conflicts[type_name][:], ", "))
        }
        if s := hover_for_type(type_name); s != "" { return s }
        return fmt.tprintf("%s %s", symbol, type_name)
    }

    for _, defn in g_index.own_structs {
        for field in defn.fields {
            if field.name != symbol { continue }
            t := field.type
            if s := hover_for_type(t); s != "" { return s }
            return fmt.tprintf("%s %s", symbol, t)
        }
    }
    return ""
}

goto_def :: proc(symbol: string, local_ctx: string) -> (file: string, line: int, col: int, ok: bool) {
    if d, found := g_index.own_structs[symbol]; found { loc := d.location; return loc.file, loc.line, loc.col, true }
    if d, found := g_index.own_enums[symbol];   found { loc := d.location; return loc.file, loc.line, loc.col, true }
    if d, found := g_index.own_procs[symbol];   found { loc := d.location; return loc.file, loc.line, loc.col, true }
    if symbol in g_index.imported_struct_conflicts { return "", 0, 0, false }
    if symbol in g_index.imported_enum_conflicts   { return "", 0, 0, false }
    if d, found := g_index.all_imported_structs[symbol]; found { loc := d.location; return loc.file, loc.line, loc.col, true }
    if d, found := g_index.all_imported_enums[symbol];   found { loc := d.location; return loc.file, loc.line, loc.col, true }
    return "", 0, 0, false
}

completions_from_package :: proc(alias: string, prefix: string) -> string {
    pkg := package_by_alias(alias)
    if pkg == nil { return "" }

    import_path := g_index.import_aliases[alias]
    display := import_path if import_path != "" else alias

    sb := strings.builder_make()
    for name in pkg.structs {
        if strings.has_prefix(name, prefix) { strings.write_string(&sb, name); strings.write_byte(&sb, '\t'); strings.write_string(&sb, display); strings.write_byte(&sb, '\n') }
    }
    for name in pkg.enums {
        if strings.has_prefix(name, prefix) { strings.write_string(&sb, name); strings.write_byte(&sb, '\t'); strings.write_string(&sb, display); strings.write_byte(&sb, '\n') }
    }
    for name, defn in pkg.procs {
        if strings.has_prefix(name, prefix) { strings.write_string(&sb, name); strings.write_byte(&sb, '\t'); strings.write_string(&sb, proc_signature_summary(defn)); strings.write_byte(&sb, '\n') }
    }
    return strings.trim_right(strings.to_string(sb), "\n")
}

Completion_Kind :: enum { Own_Variable, Own_Enum, Own_Proc, Own_Struct, Imported_Enum, Imported_Struct }

path_basename :: proc(path: string) -> string {
    for i := len(path) - 1; i >= 0; i -= 1 {
        if path[i] == '/' { return path[i+1:] }
    }
    return path
}

completions_unqualified :: proc(prefix: string, current_file: string) -> string {
    current_basename := path_basename(current_file)

    own_symbol_file := make(map[string]string, context.temp_allocator)
    for path, syms in g_file_symbols {
        basename := path_basename(path)
        for name in syms.struct_names   { own_symbol_file[name] = basename }
        for name in syms.enum_names     { own_symbol_file[name] = basename }
        for name in syms.proc_names     { own_symbol_file[name] = basename }
        for name in syms.variable_names { own_symbol_file[name] = basename }
    }

    conflict_source :: proc(name: string, is_struct: bool) -> string {
        conflicts := g_index.imported_struct_conflicts[name] if is_struct else g_index.imported_enum_conflicts[name]
        sb := strings.builder_make(context.temp_allocator)
        strings.write_string(&sb, "ambiguous: ")
        for c, i in conflicts {
            if i > 0 { strings.write_string(&sb, ", ") }
            imp := g_index.import_aliases[c]
            strings.write_string(&sb, imp if imp != "" else c)
        }
        return strings.to_string(sb)
    }

    import_source :: proc(name: string, is_struct: bool) -> string {
        alias := g_index.imported_struct_sources[name] if is_struct else g_index.imported_enum_sources[name]
        imp   := g_index.import_aliases[alias]
        return imp if imp != "" else alias
    }

    lines := make([dynamic]string, context.temp_allocator)

    add :: proc(lines: ^[dynamic]string, current_basename: string,
                name: string, source: string, detail: string, kind: Completion_Kind) {
        bucket := "1" if source != current_basename else "0"
        menu   := fmt.tprintf("%s · %s", source, detail) if source != "" else detail
        key    := fmt.tprintf("%s%s\x01%d\x01%s", bucket, source, int(kind), name)
        append(lines, fmt.tprintf("%s\x00%s\t%s", key, name, menu))
    }

    for name, defn in g_index.own_structs {
        if !strings.has_prefix(name, prefix) { continue }
        types := make([dynamic]string, context.temp_allocator)
        for f in defn.fields { append(&types, f.type) }
        add(&lines, current_basename, name, own_symbol_file[name], strings.join(types[:], " "), .Own_Struct)
    }
    for name, defn in g_index.own_enums {
        if !strings.has_prefix(name, prefix) { continue }
        add(&lines, current_basename, name, own_symbol_file[name], strings.join(defn.values[:], " "), .Own_Enum)
    }
    for name, defn in g_index.own_procs {
        if !strings.has_prefix(name, prefix) { continue }
        add(&lines, current_basename, name, own_symbol_file[name], proc_signature_summary(defn), .Own_Proc)
    }
    for name, type_name in g_index.own_variables {
        if !strings.has_prefix(name, prefix) { continue }
        add(&lines, current_basename, name, own_symbol_file[name], type_name, .Own_Variable)
    }
    for name in g_index.all_imported_structs {
        if !strings.has_prefix(name, prefix) || name in g_index.own_structs { continue }
        defn   := g_index.all_imported_structs[name]
        types  := make([dynamic]string, context.temp_allocator)
        for f in defn.fields { append(&types, f.type) }
        source := conflict_source(name, true) if name in g_index.imported_struct_conflicts else import_source(name, true)
        add(&lines, current_basename, name, source, strings.join(types[:], " "), .Imported_Struct)
    }
    for name in g_index.all_imported_enums {
        if !strings.has_prefix(name, prefix) || name in g_index.own_enums { continue }
        defn   := g_index.all_imported_enums[name]
        source := conflict_source(name, false) if name in g_index.imported_enum_conflicts else import_source(name, false)
        add(&lines, current_basename, name, source, strings.join(defn.values[:], " "), .Imported_Enum)
    }

    slice.sort(lines[:])

    sb := strings.builder_make()
    for line in lines {
        if sep := strings.index_byte(line, '\x00'); sep >= 0 {
            strings.write_string(&sb, line[sep+1:])
            strings.write_byte(&sb, '\n')
        }
    }
    return strings.trim_right(strings.to_string(sb), "\n")
}

completions_for_type :: proc(type_name: string, prefix: string, local_ctx: string) -> string {
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

    lookup := strings.trim_prefix(type_name, "^")

    if alias, name, has_dot := split_at_dot(lookup); has_dot {
        if pkg := package_by_alias(alias); pkg != nil {
            sb := strings.builder_make()
            if d, ok := pkg.structs[name]; ok { write_struct_fields(&sb, d, prefix) } else
            if d, ok := pkg.enums[name];   ok { write_enum_values(&sb, d, prefix, type_name) }
            return strings.trim_right(strings.to_string(sb), "\n")
        }
    }

    sb := strings.builder_make()
    if d, ok := g_index.own_structs[lookup];          ok { write_struct_fields(&sb, d, prefix)          } else
    if d, ok := g_index.own_enums[lookup];            ok { write_enum_values(&sb, d, prefix, type_name) } else
    if d, ok := g_index.all_imported_structs[lookup]; ok { write_struct_fields(&sb, d, prefix)          } else
    if d, ok := g_index.all_imported_enums[lookup];   ok { write_enum_values(&sb, d, prefix, type_name) }
    return strings.trim_right(strings.to_string(sb), "\n")
}

completions_for_request :: proc(prefix: string, dot_chain: string, local_ctx: string, current_file: string) -> string {
    if dot_chain == "" { return completions_unqualified(prefix, current_file) }

    segments      := strings.split(dot_chain, ".")
    defer delete(segments)
    current_type  := ""
    segment_start := 1

    if _, is_import := g_index.imported_package_dirs[segments[0]]; is_import {
        if len(segments) == 1 { return completions_from_package(segments[0], prefix) }
        alias := segments[0]; type_name := segments[1]
        if pkg := package_by_alias(alias); pkg != nil {
            if _, ok := pkg.structs[type_name]; ok {
                current_type  = strings.concatenate({alias, ".", type_name}, context.temp_allocator)
                segment_start = 2
            } else if _, ok := pkg.enums[type_name]; ok {
                current_type  = strings.concatenate({alias, ".", type_name}, context.temp_allocator)
                segment_start = len(segments)
            }
        }
        if current_type == "" { current_type = resolve_name_to_type(segments[0], local_ctx); segment_start = 1 }
    } else {
        current_type = resolve_name_to_type(segments[0], local_ctx)
    }

    if current_type == "" { return "" }

    for i := segment_start; i < len(segments); i += 1 {
        field_name := segments[i]
        if field_name == "" { return "" }

        lookup_type := strings.trim_prefix(current_type, "^")
        struct_defn, found := g_index.own_structs[lookup_type]
        if !found {
            if alias, name, has_dot := split_at_dot(lookup_type); has_dot {
                if pkg := package_by_alias(alias); pkg != nil { struct_defn, found = pkg.structs[name] }
            }
            if !found { struct_defn, found = g_index.all_imported_structs[lookup_type] }
            if !found { return "" }
        }

        next_type := ""
        for f in struct_defn.fields { if f.name == field_name { next_type = f.type; break } }
        if next_type == "" { return "" }
        current_type = next_type
    }

    return completions_for_type(current_type, prefix, local_ctx)
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

INLINE_FRAME_CAP :: 4096

write_frame :: proc(fd: posix.FD, msg: string) -> bool {
    body := transmute([]u8)msg
    n    := len(body)
    if n + 8 <= INLINE_FRAME_CAP {
        buf: [INLINE_FRAME_CAP]u8
        fmt.bprintf(buf[:8], "%08x", n)
        copy(buf[8:], body)
        return fd_write_all(fd, buf[:8 + n])
    }
    hdr_str := fmt.tprintf("%08x", n)
    hdr  := transmute([]u8)hdr_str
    return fd_write_all(fd, hdr) && fd_write_all(fd, body)
}

read_frame :: proc(fd: posix.FD, allocator := context.allocator) -> (string, bool) {
    hdr: [8]u8
    if !fd_read_exactly(fd, hdr[:]) { return "", false }
    n, ok := strconv.parse_int(string(hdr[:]), 16)
    if !ok                 { return "", false }
    if n > MAX_FRAME_BYTES { return "", false }
    if n == 0              { return "", true  }
    body := make([]u8, n, allocator)
    if !fd_read_exactly(fd, body) { delete(body, allocator); return "", false }
    return string(body), true
}

socket_path_for_root :: proc(project_root: string, allocator := context.allocator) -> string {
    h := xxhash.XXH64(transmute([]u8)project_root, 0)
    return fmt.aprintf("/tmp/gjallarhorn_%016x.sock", h, allocator = allocator)
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

    source_dir   := path_parent_dir(initial_file);      defer delete(source_dir)
    project_root := find_project_root(source_dir);      defer delete(project_root)
    socket_path  := socket_path_for_root(project_root); defer delete(socket_path)

    socket_path_c   := strings.clone_to_cstring(socket_path)
    g_socket_path_c  = socket_path_c
    posix.unlink(socket_path_c)

    g_project_root = strings.clone(project_root)
    build_index(project_root)

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
            current_file, cf_ok := read_frame(client_fd, context.temp_allocator); if !cf_ok { return }
            prefix,       p_ok  := read_frame(client_fd, context.temp_allocator); if !p_ok  { return }
            dot_chain,    d_ok  := read_frame(client_fd, context.temp_allocator); if !d_ok  { return }
            local_ctx,    l_ok  := read_frame(client_fd, context.temp_allocator); if !l_ok  { return }

            context.allocator = context.temp_allocator
            result := completions_for_request(prefix, dot_chain, local_ctx, current_file)
            write_frame(client_fd, result)

        case "comp_buf":
            path,      path_ok := read_frame(client_fd, context.temp_allocator); if !path_ok { return }
            prefix,    p_ok    := read_frame(client_fd, context.temp_allocator); if !p_ok    { return }
            dot_chain, d_ok    := read_frame(client_fd, context.temp_allocator); if !d_ok    { return }
            buf,       b_ok    := read_frame(client_fd, context.temp_allocator); if !b_ok    { return }
            local_ctx, l_ok    := read_frame(client_fd, context.temp_allocator); if !l_ok    { return }

            context.allocator = g_persistent_allocator
            rebuild_index_from_buf(path, buf)
            context.allocator = context.temp_allocator
            result := completions_for_request(prefix, dot_chain, local_ctx, path)
            write_frame(client_fd, result)

        case "hover":
            sym,       sym_ok := read_frame(client_fd, context.temp_allocator); if !sym_ok { return }
            local_ctx, ctx_ok := read_frame(client_fd, context.temp_allocator); if !ctx_ok { return }

            context.allocator = context.temp_allocator
            result := hover_info(sym, local_ctx)
            write_frame(client_fd, result)

		case "goto":
            sym,       sym_ok := read_frame(client_fd, context.temp_allocator)
            if !sym_ok { return }
            local_ctx, ctx_ok := read_frame(client_fd, context.temp_allocator)
            if !ctx_ok { return }

            context.allocator = context.temp_allocator
            file, line, col, ok := goto_def(sym, local_ctx)
            if ok {
                write_frame(client_fd, fmt.tprintf("%s\x00%d\x00%d", file, line, col))
            } else {
                write_frame(client_fd, "")
            }

        case "index":
            path, path_ok := read_frame(client_fd, context.temp_allocator)
            if !path_ok { return }
            context.allocator = g_persistent_allocator
            rebuild_index(path)
            write_frame(client_fd, "")

        case "index_buf":
            path, path_ok := read_frame(client_fd, context.temp_allocator)
            if !path_ok { return }
            src, src_ok := read_frame(client_fd, context.temp_allocator)
            if !src_ok { return }
            context.allocator = g_persistent_allocator
            rebuild_index_from_buf(path, src)
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
    filepath    := ""

    for i := 1; i < len(os.args); i += 1 {
        arg := os.args[i]
        if arg == "--daemon" {
            daemon_mode = true
            if i + 1 < len(os.args) {
                filepath = os.args[i+1]
                i += 1
            }
            project_root_markers = os.args[i+1:]
        }
    }

    if !daemon_mode || filepath == "" {
        fmt.eprintfln("usage: gjallarhorn --daemon <absolute_filepath> [root_marker ...]")
        os.exit(1)
    }

    daemon_start(filepath)
}
