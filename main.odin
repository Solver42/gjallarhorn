package gjallarhorn

import "core:fmt"
import "core:hash/xxhash"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"

g_indent_spaces                    : string
g_socket_path_c                    : cstring
g_project_root_markers             : []string
g_imported_package_cache           : map[string]Imported_Package
g_imported_package_arena           : virtual.Arena
g_odin_root                        : string
g_persistent_allocator             : mem.Allocator
g_project_symbol_index             : Symbol_Index
g_file_content_hash_by_path        : map[string]u64
g_indexed_file_metadata_by_path    : map[string]Indexed_File_Metadata
g_symbol_source_filename_by_name   : map[string]string

DEV :: #config(DEV, false)

Struct_Field :: struct {
    name : string,
    type : string,
}

Struct_Definition :: struct {
    fields       : [dynamic]Struct_Field,
    location     : Symbol_Ref,
    end_location : Symbol_Ref,
}

Enum_Definition :: struct {
    values       : [dynamic]string,
    location     : Symbol_Ref,
    end_location : Symbol_Ref,
}

Union_Definition :: struct {
    variants     : [dynamic]string,
    location     : Symbol_Ref,
    end_location : Symbol_Ref,
}

Proc_Definition :: struct {
    params       : [dynamic]string,
    returns      : [dynamic]string,
    location     : Symbol_Ref,
    end_location : Symbol_Ref,
}

Symbol_Ref :: struct {
    file   : string,
    line   : int,
    column : int,
}

Imported_Package :: struct {
    structs            : map[string]Struct_Definition,
    enums              : map[string]Enum_Definition,
    unions             : map[string]Union_Definition,
    procs              : map[string]Proc_Definition,
    variables          : map[string]string,
    variable_locations : map[string]Symbol_Ref,
}

Symbol_Index :: struct {
    project_structs           : map[string]Struct_Definition,
    project_enums             : map[string]Enum_Definition,
    project_unions            : map[string]Union_Definition,
    project_procs             : map[string]Proc_Definition,
    project_variables         : map[string]string,
    project_variable_locations: map[string]Symbol_Ref,
    project_constants         : map[string]string,
    import_aliases            : map[string]string,
    imported_package_dirs     : map[string]string,
    all_imported_structs      : map[string]Struct_Definition,
    all_imported_enums        : map[string]Enum_Definition,
    imported_struct_origin_alias   : map[string]string,
    imported_enum_origin_alias     : map[string]string,
    imported_struct_conflicts : map[string][dynamic]string,
    imported_enum_conflicts   : map[string][dynamic]string,
}

Indexed_File_Metadata :: struct {
    struct_names    : [dynamic]string,
    enum_names      : [dynamic]string,
    union_names     : [dynamic]string,
    proc_names      : [dynamic]string,
    variable_names  : [dynamic]string,
    import_aliases  : map[string]string,
    source_filename : string,
}

Token_Kind :: enum { EOF, Identifier, String_Literal, Double_Colon, Open_Brace, Close_Brace, Comma, Colon, Hash, Other }

Token :: struct {
    kind   : Token_Kind,
    text   : string,
    line   : int,
    column : int,
}

Lexer :: struct {
    source               : string,
    pos                  : int,
    line                 : int,
    column               : int,
    inside_block_comment : bool,
    has_buffered_token   : bool,
    buffered_token       : Token,
}

lexer_from_source :: proc(source: string) -> Lexer { return {source = source, line = 1, column = 1} }

lexer_advance_one_byte :: proc(lexer: ^Lexer) {
    current_byte := lexer.source[lexer.pos]
    lexer.pos += 1
    if current_byte == '\n' { lexer.line += 1; lexer.column = 1 } else { lexer.column += 1 }
}

lexer_skip_whitespace_and_comments :: proc(lexer: ^Lexer) {
    for lexer.pos < len(lexer.source) {
        current_byte := lexer.source[lexer.pos]

        if lexer.inside_block_comment {
            if current_byte == '*' && lexer.pos+1 < len(lexer.source) && lexer.source[lexer.pos+1] == '/' {
                lexer.pos += 2; lexer.column += 2; lexer.inside_block_comment = false; continue
            }
            if current_byte == '\n' { lexer.pos += 1; lexer.line += 1; lexer.column = 1 } else { lexer.pos += 1; lexer.column += 1 }
            continue
        }

        if current_byte == ' ' || current_byte == '\t' || current_byte == '\r' { lexer.pos += 1; lexer.column += 1; continue }
        if current_byte == '\n'                                                 { lexer.pos += 1; lexer.line += 1; lexer.column = 1; continue }

        if current_byte == '/' && lexer.pos+1 < len(lexer.source) {
            if lexer.source[lexer.pos+1] == '/' { for lexer.pos < len(lexer.source) && lexer.source[lexer.pos] != '\n' { lexer.pos += 1 }; continue }
            if lexer.source[lexer.pos+1] == '*' { lexer.pos += 2; lexer.column += 2; lexer.inside_block_comment = true; continue }
        }
        break
    }
}

lexer_read_token :: proc(lexer: ^Lexer) -> Token {
    lexer_skip_whitespace_and_comments(lexer)
    if lexer.pos >= len(lexer.source) { return {kind = .EOF} }

    start_line   := lexer.line
    start_column := lexer.column
    current_byte := lexer.source[lexer.pos]

    if current_byte == '_' || (current_byte >= 'a' && current_byte <= 'z') || (current_byte >= 'A' && current_byte <= 'Z') {
        start := lexer.pos
        for lexer.pos < len(lexer.source) {
            identifier_byte := lexer.source[lexer.pos]
            if identifier_byte == '_' || (identifier_byte >= 'a' && identifier_byte <= 'z') || (identifier_byte >= 'A' && identifier_byte <= 'Z') || (identifier_byte >= '0' && identifier_byte <= '9') {
                lexer.pos += 1; lexer.column += 1
            } else { break }
        }
        return {kind = .Identifier, text = lexer.source[start:lexer.pos], line = start_line, column = start_column}
    }

    if current_byte == ':' {
        if lexer.pos+1 < len(lexer.source) && lexer.source[lexer.pos+1] == ':' {
            lexer_advance_one_byte(lexer); lexer_advance_one_byte(lexer)
            return {kind = .Double_Colon, text = "::", line = start_line, column = start_column}
        }
        lexer_advance_one_byte(lexer)
        return {kind = .Colon, text = ":", line = start_line, column = start_column}
    }

    if current_byte == '"' {
        lexer_advance_one_byte(lexer)
        start := lexer.pos
        for lexer.pos < len(lexer.source) && lexer.source[lexer.pos] != '"' {
            if lexer.source[lexer.pos] == '\\' { lexer.pos += 1; lexer.column += 1 }
            lexer_advance_one_byte(lexer)
        }
        text := lexer.source[start:lexer.pos]
        if lexer.pos < len(lexer.source) { lexer_advance_one_byte(lexer) }
        return {kind = .String_Literal, text = text, line = start_line, column = start_column}
    }

    if current_byte == '`' {
        lexer_advance_one_byte(lexer)
        start := lexer.pos
        for lexer.pos < len(lexer.source) && lexer.source[lexer.pos] != '`' { lexer_advance_one_byte(lexer) }
        text := lexer.source[start:lexer.pos]
        if lexer.pos < len(lexer.source) { lexer_advance_one_byte(lexer) }
        return {kind = .String_Literal, text = text, line = start_line, column = start_column}
    }

    if current_byte == '\'' {
        start := lexer.pos
        lexer_advance_one_byte(lexer)
        for lexer.pos < len(lexer.source) && lexer.source[lexer.pos] != '\'' {
            if lexer.source[lexer.pos] == '\\' { lexer.pos += 1; lexer.column += 1 }
            lexer_advance_one_byte(lexer)
        }
        if lexer.pos < len(lexer.source) { lexer_advance_one_byte(lexer) }
        return {kind = .Other, text = lexer.source[start:lexer.pos], line = start_line, column = start_column}
    }

    if current_byte == '{' { lexer_advance_one_byte(lexer); return {kind = .Open_Brace,  text = "{", line = start_line, column = start_column} }
    if current_byte == '}' { lexer_advance_one_byte(lexer); return {kind = .Close_Brace, text = "}", line = start_line, column = start_column} }
    if current_byte == ',' { lexer_advance_one_byte(lexer); return {kind = .Comma,       text = ",", line = start_line, column = start_column} }
    if current_byte == '#' { lexer_advance_one_byte(lexer); return {kind = .Hash,        text = "#", line = start_line, column = start_column} }

    start      := lexer.pos
    _, rune_width := utf8.decode_rune_in_string(lexer.source[lexer.pos:])
    lexer.pos += rune_width; lexer.column += 1
    return {kind = .Other, text = lexer.source[start:lexer.pos], line = start_line, column = start_column}
}

lexer_consume_token :: proc(lexer: ^Lexer) -> Token {
    if lexer.has_buffered_token { lexer.has_buffered_token = false; return lexer.buffered_token }
    return lexer_read_token(lexer)
}

lexer_peek_token :: proc(lexer: ^Lexer) -> Token {
    if !lexer.has_buffered_token { lexer.buffered_token = lexer_read_token(lexer); lexer.has_buffered_token = true }
    return lexer.buffered_token
}

dir_contains_root_marker :: proc(dir: string) -> bool {
    for marker in g_project_root_markers {
        path := strings.concatenate({dir, "/", marker}, context.temp_allocator)
        if _, err := os.stat(path, context.temp_allocator); err == nil { return true }
    }
    return false
}

find_project_root :: proc(start_dir: string, allocator := context.allocator) -> string {
    current_dir := start_dir
    for {
        if dir_contains_root_marker(current_dir) { return strings.clone(current_dir, allocator) }
        slash := strings.last_index_byte(current_dir, '/')
        if slash <= 0 { break }
        current_dir = current_dir[:slash]
    }
    return strings.clone(start_dir, allocator)
}

import_alias_from_path :: proc(path: string) -> string {
    last := -1
    for i := 0; i < len(path); i += 1 {
        if path[i] == ':' || path[i] == '/' { last = i }
    }
    if last == -1 { return path }
    return path[last+1:]
}

is_keyword :: proc(word: string) -> bool {
    switch word {
    case "package",
         "if", "else", "when", "for", "switch", "case", "do", "fallthrough",
         "return", "defer", "break", "continue", "where",
         "in", "not_in", "using",
         "distinct", "bit_set", "map", "dynamic",
         "cast", "auto_cast", "transmute",
         "context", "or_else", "or_return":
        return true
    }
    return false
}

lexer_skip_rest_of_line :: proc(lexer: ^Lexer) {
    start_line := lexer.line
    for {
        peeked := lexer_peek_token(lexer)
        if peeked.kind == .EOF || peeked.line > start_line { return }
        lexer_consume_token(lexer)
    }
}

lexer_skip_rhs_until_comma_or_line :: proc(lexer: ^Lexer, stop_line: int, stop_at_body_brace := false) {
    paren_depth := 0
    brace_depth := 0
    for {
        peeked := lexer_peek_token(lexer)
        if peeked.kind == .EOF || peeked.line > stop_line { return }
        if peeked.kind == .Open_Brace && stop_at_body_brace && paren_depth == 0 && brace_depth == 0 { return }
        if peeked.kind == .Open_Brace                                     { brace_depth += 1 }
        if peeked.kind == .Close_Brace && brace_depth > 0                 { brace_depth -= 1 }
        if peeked.kind == .Other && peeked.text == "("                    { paren_depth += 1 }
        if peeked.kind == .Other && peeked.text == ")" && paren_depth > 0 { paren_depth -= 1 }
        if peeked.kind == .Comma && paren_depth == 0 && brace_depth == 0  { return }
        lexer_consume_token(lexer)
    }
}

lexer_read_type_expression :: proc(lexer: ^Lexer, stop_check: proc(Token_Kind, string) -> bool, max_line := max(int)) -> string {
    builder      := strings.builder_make(context.allocator)
    prev_was_dot := false
    for {
        peeked := lexer_peek_token(lexer)
        if peeked.kind == .EOF || peeked.line > max_line { break }
        if stop_check(peeked.kind, peeked.text) { break }
        if peeked.kind == .Identifier && !prev_was_dot {
            saved := lexer^
            lexer_consume_token(lexer)
            next_kind := lexer_peek_token(lexer).kind
            lexer^ = saved
            if next_kind == .Colon || next_kind == .Double_Colon { break }
        }
        token := lexer_consume_token(lexer)
        prev_was_dot = (token.text == ".")
        if token.text != "" { strings.write_string(&builder, token.text) }
    }
    return strings.to_string(builder)
}

lexer_infer_numeric_literal_type :: proc(lexer: ^Lexer) -> string {
    has_dot_or_exponent := false
    prev_was_dot        := false
    line                := lexer_peek_token(lexer).line
    prev_token_end_col  := -1
    for {
        peeked := lexer_peek_token(lexer)
        if peeked.kind == .EOF || peeked.line > line { break }
        if peeked.kind == .Comma                                              { break }
        if peeked.kind == .Other && peeked.text == ";"                        { break }
        if peeked.kind == .Other && peeked.text == "." && prev_was_dot        { has_dot_or_exponent = false; break }
        if peeked.kind == .Identifier && prev_token_end_col == peeked.column {
            lexer_consume_token(lexer)
            switch peeked.text {
            case "i":      return "complex128"
            case "j", "k": return "quaternion256"
            }
            break
        }
        token := lexer_consume_token(lexer)
        if token.kind == .Other {
            prev_token_end_col = token.column + len(token.text)
            prev_was_dot       = token.text == "."
            for number_byte in transmute([]u8)token.text {
                if number_byte == '.' || number_byte == 'e' || number_byte == 'E' { has_dot_or_exponent = true }
            }
        } else {
            prev_token_end_col = -1
            prev_was_dot       = false
        }
    }
    if has_dot_or_exponent { return "f64" }
    return "int"
}

lexer_infer_rhs_return_types :: proc(lexer: ^Lexer, local_procs: map[string]Proc_Definition = nil, stop_at_body_brace := false) -> []string {
    infer_one_literal :: proc(lexer: ^Lexer, stop_at_body_brace: bool) -> (type_name: string, consumed_past_value: bool) {
        token := lexer_peek_token(lexer)
        if token.kind == .String_Literal { lexer_skip_rhs_until_comma_or_line(lexer, token.line, stop_at_body_brace); return "string", true }
        if token.kind == .Other && len(token.text) > 0 {
            if token.text[0] >= '0' && token.text[0] <= '9' { return lexer_infer_numeric_literal_type(lexer), false }
            if token.text[0] == '-' || token.text[0] == '+' {
                saved      := lexer^
                lexer_consume_token(lexer)
                after_sign := lexer_peek_token(lexer)
                lexer^      = saved
                if after_sign.kind == .Other && len(after_sign.text) > 0 && after_sign.text[0] >= '0' && after_sign.text[0] <= '9' {
                    return lexer_infer_numeric_literal_type(lexer), false
                }
            }
            if token.text[0] == '\'' { lexer_skip_rhs_until_comma_or_line(lexer, token.line, stop_at_body_brace); return "rune", true }
        }
        if token.kind == .Identifier {
            switch token.text {
            case "true", "false": lexer_skip_rhs_until_comma_or_line(lexer, token.line, stop_at_body_brace); return "bool", true
            case "nil":           lexer_skip_rhs_until_comma_or_line(lexer, token.line, stop_at_body_brace); return "",     true
            }
        }
        return "", false
    }

    first_token := lexer_peek_token(lexer)

    first_type, first_consumed_past := infer_one_literal(lexer, stop_at_body_brace)
    if first_type != "" || first_consumed_past {
        results := make([dynamic]string, context.temp_allocator)
        if first_type != "" { append(&results, first_type) }
        for {
            if lexer_peek_token(lexer).kind != .Comma { break }
            lexer_consume_token(lexer)
            next_type, next_consumed_past := infer_one_literal(lexer, stop_at_body_brace)
            if next_type != "" { append(&results, next_type) } else if !next_consumed_past { break }
        }
        if len(results) == 0 { return nil }
        out := make([]string, len(results), context.temp_allocator)
        copy(out, results[:])
        return out
    }

    if first_token.kind == .Identifier {
        switch first_token.text {
        case "make", "new":
            lexer_consume_token(lexer)
            if lexer_peek_token(lexer).kind == .Other && lexer_peek_token(lexer).text == "(" {
                lexer_consume_token(lexer)
                type_name := lexer_read_type_expression(lexer, proc(kind: Token_Kind, text: string) -> bool {
                    return kind == .EOF || kind == .Comma || (kind == .Other && text == ")")
                })
                lexer_skip_rhs_until_comma_or_line(lexer, first_token.line, stop_at_body_brace)
                if type_name == "" { return nil }
                out    := make([]string, 1, context.temp_allocator)
                out[0]  = type_name
                return out
            }
            lexer_skip_rhs_until_comma_or_line(lexer, first_token.line, stop_at_body_brace)
            return nil
        }
    }

    type_name       := lexer_read_type_expression(lexer, proc(kind: Token_Kind, text: string) -> bool {
        return kind == .EOF || kind == .Open_Brace || kind == .Colon || kind == .Comma ||
               (kind == .Other && (text == "=" || text == "("))
    }, first_token.line)
    token_after_type := lexer_peek_token(lexer)
    lexer_skip_rhs_until_comma_or_line(lexer, first_token.line, stop_at_body_brace)
    if token_after_type.kind == .Other && token_after_type.text == "(" {
        if alias, name, has_dot := split_qualified_name_at_dot(type_name); has_dot {
            if pkg := imported_package_by_import_alias(alias); pkg != nil {
                if defn, found := pkg.procs[name]; found && len(defn.returns) > 0 { return defn.returns[:] }
            }
        }
        if defn, found := local_procs[type_name]; found && len(defn.returns) > 0 { return defn.returns[:] }
        if defn, found := g_project_symbol_index.project_procs[type_name]; found && len(defn.returns) > 0 { return defn.returns[:] }
    }
    if type_name == "" { return nil }
    out    := make([]string, 1, context.temp_allocator)
    out[0]  = type_name
    return out
}

lexer_infer_rhs_first_type :: proc(lexer: ^Lexer, local_procs: map[string]Proc_Definition = nil, stop_at_body_brace := false) -> string {
    returns := lexer_infer_rhs_return_types(lexer, local_procs, stop_at_body_brace)
    if len(returns) == 0 { return "" }
    return returns[0]
}

Parsed_File_Declarations :: struct {
    file_path                  : string,
    project_structs            : map[string]Struct_Definition,
    project_enums              : map[string]Enum_Definition,
    project_unions             : map[string]Union_Definition,
    project_procs              : map[string]Proc_Definition,
    project_variables          : map[string]string,
    project_variable_locations : map[string]Symbol_Ref,
    project_constants          : map[string]string,
    import_aliases             : map[string]string,
    map_lookup_expressions     : map[string]string,
}

parse_declaration_right_hand_side :: proc(lexer: ^Lexer, name: string, location: Symbol_Ref, result: ^Parsed_File_Declarations) {
    after := lexer_peek_token(lexer)

    if after.kind == .Identifier {
        switch after.text {
        case "struct":
            lexer_consume_token(lexer)
            struct_defn := parse_struct_definition(lexer)
            struct_defn.location = location
            result.project_structs[strings.clone(name)] = struct_defn
            return
        case "enum":
            lexer_consume_token(lexer)
            enum_defn := parse_enum_definition(lexer)
            enum_defn.location = location
            result.project_enums[strings.clone(name)] = enum_defn
            return
        case "proc":
            lexer_consume_token(lexer)
            proc_defn := parse_proc_definition(lexer)
            proc_defn.location = location
            result.project_procs[strings.clone(name)] = proc_defn
            return
        case "union":
            lexer_consume_token(lexer)
            union_defn := parse_union_definition(lexer)
            union_defn.location = location
            result.project_unions[strings.clone(name)] = union_defn
            return
        case "distinct":
            lexer_consume_token(lexer)
            type_name := lexer_read_type_expression(lexer, proc(kind: Token_Kind, text: string) -> bool {
                return kind == .EOF || kind == .Comma || kind == .Open_Brace
            })
            if type_name != "" {
                result.project_variables[strings.clone(name)]          = type_name
                result.project_variable_locations[strings.clone(name)] = location
            }
            return
        }
        if after.text == "true" || after.text == "false" {
            lexer_consume_token(lexer)
            result.project_variables[strings.clone(name)]          = "bool"
            result.project_variable_locations[strings.clone(name)] = location
            result.project_constants[strings.clone(name)]          = strings.clone(after.text)
            return
        }
        rhs_line    := after.line
        rhs_builder := strings.builder_make(context.temp_allocator)
        prev_end    := -1
        for {
            peeked := lexer_peek_token(lexer)
            if peeked.kind == .EOF || peeked.kind == .Open_Brace || peeked.line > rhs_line { break }
            if peeked.kind == .Comma { break }
            token := lexer_consume_token(lexer)
            if prev_end != -1 && token.column > prev_end { strings.write_byte(&rhs_builder, ' ') }
            strings.write_string(&rhs_builder, token.text)
            prev_end = token.column + len(token.text)
        }
        type_name := strings.trim_right(strings.to_string(rhs_builder), " \t")
        if type_name != "" {
            is_expression := strings.contains_any(type_name, "+-*/%&|^~<>!")
            if is_expression {
                result.project_constants[strings.clone(name)] = strings.clone(type_name)
            } else {
                result.project_variables[strings.clone(name)]          = type_name
                result.project_variable_locations[strings.clone(name)] = location
            }
        }
        return
    }

    if after.kind == .Hash {
        lexer_consume_token(lexer)
        directive := lexer_peek_token(lexer)
        if directive.kind == .Identifier {
            if directive.text == "type" { lexer_consume_token(lexer); parse_declaration_right_hand_side(lexer, name, location, result); return }
        }
        lexer_skip_rest_of_line(lexer)
        return
    }

    if after.kind == .String_Literal || after.kind == .Other {
        type_name := lexer_infer_rhs_first_type(lexer, result.project_procs)
        if type_name != "" {
            result.project_variables[strings.clone(name)]          = type_name
            result.project_variable_locations[strings.clone(name)] = location
            raw_value : string
            if after.kind == .String_Literal {
                raw_value = after.text
            } else {
                rhs_start := uintptr(raw_data(after.text)) - uintptr(raw_data(lexer.source))
                raw_value = strings.trim_right(lexer.source[rhs_start:lexer.pos], " \t\r\n")
                if newline := strings.index_byte(raw_value, '\n'); newline >= 0 { raw_value = strings.trim_right(raw_value[:newline], " \t\r") }
            }
            if raw_value != "" { result.project_constants[strings.clone(name)] = strings.clone(raw_value) }
        }
    }
}

parse_file_declarations :: proc(file_path: string, source: string, outer_scope_procs: map[string]Proc_Definition = nil) -> Parsed_File_Declarations {
    result := Parsed_File_Declarations {
        file_path                  = strings.clone(file_path),
        project_structs            = make(map[string]Struct_Definition),
        project_enums              = make(map[string]Enum_Definition),
        project_unions             = make(map[string]Union_Definition),
        project_procs              = make(map[string]Proc_Definition),
        project_variables          = make(map[string]string),
        project_variable_locations = make(map[string]Symbol_Ref),
        project_constants          = make(map[string]string),
        import_aliases             = make(map[string]string),
        map_lookup_expressions     = make(map[string]string),
    }
    for name, defn in outer_scope_procs { result.project_procs[name] = defn }
    lexer                 := lexer_from_source(source)
    paren_depth           := 0
    brace_depth           := 0
    transparent_brace_depth := 0
    location              := Symbol_Ref{file = result.file_path}
    pending_proc_end_name := ""
    previous_token_opens_control_header := false

    for {
        token := lexer_consume_token(&lexer)
        if token.kind == .EOF { break }
        declaration_is_in_control_header := previous_token_opens_control_header
        previous_token_opens_control_header = token.kind == .Identifier && (token.text == "if" || token.text == "switch" || token.text == "when")
        if token.kind == .Open_Brace {
            if transparent_brace_depth > 0 { transparent_brace_depth += 1 } else { brace_depth += 1 }
            continue
        }
        if token.kind == .Close_Brace {
            if transparent_brace_depth > 0 {
                transparent_brace_depth -= 1
                continue
            }
            if brace_depth > 0 {
                brace_depth -= 1
                if brace_depth == 0 && pending_proc_end_name != "" {
                    if proc_defn, ok := result.project_procs[pending_proc_end_name]; ok {
                        proc_defn.end_location = {line = token.line, column = token.column}
                        result.project_procs[pending_proc_end_name] = proc_defn
                    }
                    pending_proc_end_name = ""
                }
            }
            continue
        }
        if token.kind == .Hash {
            if lexer_peek_token(&lexer).kind == .Identifier { lexer_consume_token(&lexer) }
            continue
        }
        if token.kind == .Other {
            if token.text == "(" { paren_depth += 1 }
            if token.text == ")" && paren_depth > 0 { paren_depth -= 1 }
            continue
        }
        if token.kind != .Identifier || paren_depth > 0 || brace_depth > 0 { continue }

        name          := token.text
        location.line  = token.line
        location.column = token.column

        if is_keyword(name) && name != "for" { continue }

        if name == "for" {
            saved       := lexer
            first_token := lexer_peek_token(&lexer)
            if first_token.kind != .Identifier {
                lexer = saved
                continue
            }
            first_name := lexer_consume_token(&lexer).text

            has_second_name := false
            second_name     := ""
            second_token: Token
            if lexer_peek_token(&lexer).kind == .Comma {
                lexer_consume_token(&lexer)
                second_token = lexer_peek_token(&lexer)
                if second_token.kind != .Identifier {
                    lexer = saved
                    continue
                }
                second_name     = lexer_consume_token(&lexer).text
                has_second_name = true
            }

            in_token := lexer_peek_token(&lexer)
            if in_token.kind != .Identifier || in_token.text != "in" {
                lexer = saved
                continue
            }
            lexer_consume_token(&lexer)

            ranged_token       := lexer_peek_token(&lexer)
            ranged_type_string := ""
            if ranged_token.kind == .String_Literal {
                ranged_type_string = "string"
                lexer_consume_token(&lexer)
            } else if ranged_token.kind == .Identifier {
                ranged_type_string = result.project_variables[ranged_token.text]
                lexer_consume_token(&lexer)
            }

            first_type  := ""
            second_type := ""
            if ranged_type_string == "string" {
                first_type  = "rune"
                second_type = "int"
            } else if strings.has_prefix(ranged_type_string, "map[") {
                if key_type, value_type, ok := split_map_type_string(ranged_type_string); ok {
                    first_type  = key_type
                    second_type = value_type
                }
            } else if strings.has_prefix(ranged_type_string, "[") {
                if closing_bracket := strings.index_byte(ranged_type_string, ']'); closing_bracket != -1 {
                    if element_type := ranged_type_string[closing_bracket+1:]; element_type != "" {
                        first_type  = element_type
                        second_type = "int"
                    }
                }
            }

            if first_type == "" || (has_second_name && second_type == "") {
                lexer = saved
                continue
            }

            first_location := Symbol_Ref{file = result.file_path, line = first_token.line, column = first_token.column}
            if first_name != "_" {
                result.project_variables[strings.clone(first_name)]          = first_type
                result.project_variable_locations[strings.clone(first_name)] = first_location
            }
            if has_second_name && second_name != "_" {
                second_location := Symbol_Ref{file = result.file_path, line = second_token.line, column = second_token.column}
                result.project_variables[strings.clone(second_name)]          = second_type
                result.project_variable_locations[strings.clone(second_name)] = second_location
            }
            continue
        }

        if name == "import" {
            peek  := lexer_peek_token(&lexer)
            import_alias, import_path: string
            if peek.kind == .String_Literal {
                lexer_consume_token(&lexer); import_path = peek.text; import_alias = import_alias_from_path(import_path)
            } else if peek.kind == .Identifier || (peek.kind == .Other && peek.text == ".") {
                alias_token := lexer_consume_token(&lexer); import_alias = alias_token.text
                path_token  := lexer_consume_token(&lexer); if path_token.kind == .String_Literal { import_path = path_token.text }
            }
            if import_alias != "_" && import_alias != "" && import_path != "" {
                result.import_aliases[strings.clone(import_alias)] = strings.clone(import_path)
            }
            continue
        }

        if name == "foreign" {
            peek := lexer_peek_token(&lexer)
            if peek.kind == .Identifier && peek.text == "import" {
                lexer_consume_token(&lexer)
                continue
            }
            if peek.kind == .Identifier {
                lexer_consume_token(&lexer)
                peek = lexer_peek_token(&lexer)
            }
            if peek.kind == .Open_Brace {
                lexer_consume_token(&lexer)
                transparent_brace_depth += 1
            }
            continue
        }

        declaration_locations := make([dynamic]Symbol_Ref, context.temp_allocator)
        declaration_names     := make([dynamic]string,     context.temp_allocator)
        append(&declaration_names,     name)
        append(&declaration_locations, location)
        for lexer_peek_token(&lexer).kind == .Comma {
            lexer_consume_token(&lexer)
            next_token := lexer_peek_token(&lexer)
            if next_token.kind != .Identifier { break }
            next_name := lexer_consume_token(&lexer)
            if is_keyword(next_name.text) { break }
            append(&declaration_names,     next_name.text)
            append(&declaration_locations, Symbol_Ref{file = result.file_path, line = next_name.line, column = next_name.column})
        }

        next := lexer_peek_token(&lexer)

        if next.kind == .Double_Colon {
            lexer_consume_token(&lexer)
            parse_declaration_right_hand_side(&lexer, declaration_names[0], declaration_locations[0], &result)
            if declaration_names[0] in result.project_procs { pending_proc_end_name = declaration_names[0] }
            continue
        }

        if next.kind == .Colon {
            lexer_consume_token(&lexer)
            type_token := lexer_peek_token(&lexer)

            if type_token.kind == .Identifier && type_token.text == "for" && len(declaration_names) == 1 {
                lexer_consume_token(&lexer)
                header_start := uintptr(lexer.pos)
                header_end   := uintptr(len(lexer.source))
                for {
                    position_before_peek := lexer.pos
                    peeked := lexer_peek_token(&lexer)
                    if peeked.kind == .EOF { break }
                    if peeked.kind == .Open_Brace {
                        header_end = uintptr(position_before_peek)
                        break
                    }
                    lexer_consume_token(&lexer)
                }
                header_text := strings.trim_space(lexer.source[header_start:header_end])
                result.project_constants[strings.clone(declaration_names[0])] = strings.clone(fmt.tprintf("%s for %s", declaration_names[0], header_text))
                continue
            }

            if type_token.kind == .Other && type_token.text == "=" {
                lexer_consume_token(&lexer)
                rhs_return_types := lexer_infer_rhs_return_types(&lexer, result.project_procs, declaration_is_in_control_header)
                lookup_expression := ""
                if len(declaration_names) == 2 && len(rhs_return_types) == 1 {
                    lookup_expression = rhs_return_types[0]
                    if semicolon := strings.index_byte(lookup_expression, ';'); semicolon != -1 { lookup_expression = lookup_expression[:semicolon] }
                }
                _, is_map_lookup := split_map_lookup_expression(lookup_expression)
                if len(rhs_return_types) >= len(declaration_names) {
                    for i in 0..<len(declaration_names) {
                        if rhs_return_types[i] != "" && declaration_names[i] != "_" {
                            result.project_variables[strings.clone(declaration_names[i])]          = rhs_return_types[i]
                            result.project_variable_locations[strings.clone(declaration_names[i])] = declaration_locations[i]
                        }
                    }
                } else if is_map_lookup {
                    if declaration_names[0] != "_" {
                        result.map_lookup_expressions[strings.clone(declaration_names[0])]     = strings.clone(lookup_expression)
                        result.project_variable_locations[strings.clone(declaration_names[0])] = declaration_locations[0]
                    }
                    if declaration_names[1] != "_" {
                        result.project_variables[strings.clone(declaration_names[1])]          = "bool"
                        result.project_variable_locations[strings.clone(declaration_names[1])] = declaration_locations[1]
                    }
                } else {
                    for i in 0..<len(declaration_names) {
                        if i > 0 && lexer_peek_token(&lexer).kind == .Comma { lexer_consume_token(&lexer) }
                        type_name := lexer_infer_rhs_first_type(&lexer, result.project_procs, declaration_is_in_control_header)
                        if type_name != "" && declaration_names[i] != "_" {
                            result.project_variables[strings.clone(declaration_names[i])]          = type_name
                            result.project_variable_locations[strings.clone(declaration_names[i])] = declaration_locations[i]
                        }
                    }
                }
                continue
            }

            if type_token.kind == .Colon {
                lexer_consume_token(&lexer)
                parse_declaration_right_hand_side(&lexer, declaration_names[0], declaration_locations[0], &result)
                continue
            }

            type_parts := make([dynamic]string, context.temp_allocator)
            start_line := type_token.line
            paren_depth_inner := 0
            for {
                peeked := lexer_peek_token(&lexer)
                if peeked.kind == .EOF || peeked.line > start_line { break }
                if peeked.kind == .Colon && paren_depth_inner == 0 { break }
                if peeked.kind == .Other && peeked.text == "=" && paren_depth_inner == 0 { break }
                if peeked.kind == .Open_Brace || peeked.kind == .Close_Brace || peeked.kind == .Comma { break }
                if peeked.kind == .Other && peeked.text == "(" { paren_depth_inner += 1 }
                if peeked.kind == .Other && peeked.text == ")" && paren_depth_inner > 0 { paren_depth_inner -= 1 }
                part := lexer_consume_token(&lexer)
                if part.text != "" { append(&type_parts, part.text) }
            }
            type_name := strings.join(type_parts[:], "")

            if type_name != "" && !is_keyword(type_name) {
                raw_value : string
                if lexer_peek_token(&lexer).kind == .Colon {
                    lexer_consume_token(&lexer)
                    value_token := lexer_peek_token(&lexer)
                    lexer_skip_rest_of_line(&lexer)
                    if value_token.kind == .String_Literal {
                        raw_value = value_token.text
                    } else if value_token.kind == .Identifier || value_token.kind == .Other {
                        rhs_start := uintptr(raw_data(value_token.text)) - uintptr(raw_data(lexer.source))
                        raw_value = strings.trim_right(lexer.source[rhs_start:lexer.pos], " \t\r\n")
                        if newline := strings.index_byte(raw_value, '\n'); newline >= 0 { raw_value = strings.trim_right(raw_value[:newline], " \t\r") }
                    }
                }
                for i in 0..<len(declaration_names) {
                    result.project_variables[strings.clone(declaration_names[i])]          = type_name
                    result.project_variable_locations[strings.clone(declaration_names[i])] = declaration_locations[i]
                    if raw_value != "" { result.project_constants[strings.clone(declaration_names[i])] = strings.clone(raw_value) }
                }
            }
        }
    }
    return result
}

parse_struct_definition :: proc(lexer: ^Lexer) -> Struct_Definition {
    defn  := Struct_Definition{fields = make([dynamic]Struct_Field)}
    depth := 0
    for { token := lexer_consume_token(lexer); if token.kind == .EOF { return defn }; if token.kind == .Open_Brace { depth = 1; break } }

    for depth > 0 {
        token := lexer_consume_token(lexer)
        #partial switch token.kind {
        case .EOF:         return defn
        case .Open_Brace:  depth += 1
        case .Close_Brace:
            depth -= 1
            if depth == 0 { defn.end_location = {line = token.line, column = token.column} }
        case .Hash:        if lexer_peek_token(lexer).kind == .Identifier { lexer_consume_token(lexer) }
        case .Identifier:
            if depth != 1 { continue }
            field_names := make([dynamic]string, context.temp_allocator)
            append(&field_names, token.text)
            for lexer_peek_token(lexer).kind == .Comma {
                lexer_consume_token(lexer)
                next := lexer_peek_token(lexer)
                if next.kind != .Identifier { break }
                append(&field_names, lexer_consume_token(lexer).text)
            }
            if lexer_peek_token(lexer).kind != .Colon { continue }
            lexer_consume_token(lexer)

            field_type := lexer_read_type_expression(lexer, proc(kind: Token_Kind, text: string) -> bool {
                return kind == .EOF || kind == .Comma || kind == .Close_Brace
            })
            if lexer_peek_token(lexer).kind == .Comma { lexer_consume_token(lexer) }

            for field_name in field_names {
                append(&defn.fields, Struct_Field{
                    name = strings.clone(field_name),
                    type = field_type,
                })
            }
        case:
        }
    }
    return defn
}

parse_enum_definition :: proc(lexer: ^Lexer) -> Enum_Definition {
    defn := Enum_Definition{values = make([dynamic]string)}
    for { token := lexer_consume_token(lexer); if token.kind == .EOF { return defn }; if token.kind == .Open_Brace { break } }
    for {
        token := lexer_consume_token(lexer)
        #partial switch token.kind {
        case .EOF:         return defn
        case .Close_Brace: defn.end_location = {line = token.line, column = token.column}; return defn
        case .Identifier:
            append(&defn.values, strings.clone(token.text))
            for {
                peeked := lexer_peek_token(lexer)
                if peeked.kind == .EOF || peeked.kind == .Comma || peeked.kind == .Close_Brace { break }
                lexer_consume_token(lexer)
            }
            if lexer_peek_token(lexer).kind == .Comma { lexer_consume_token(lexer) }
        case:
        }
    }
}

parse_union_definition :: proc(lexer: ^Lexer) -> Union_Definition {
    defn := Union_Definition{variants = make([dynamic]string)}
    for { token := lexer_consume_token(lexer); if token.kind == .EOF { return defn }; if token.kind == .Open_Brace { break } }
    for {
        if lexer_peek_token(lexer).kind == .EOF || lexer_peek_token(lexer).kind == .Close_Brace {
            close := lexer_consume_token(lexer)
            if close.kind == .Close_Brace { defn.end_location = {line = close.line, column = close.column} }
            return defn
        }
        variant := lexer_read_type_expression(lexer, proc(kind: Token_Kind, text: string) -> bool {
            return kind == .EOF || kind == .Comma || kind == .Close_Brace
        })
        if variant != "" { append(&defn.variants, variant) }
        if lexer_peek_token(lexer).kind == .Comma { lexer_consume_token(lexer) }
    }
}

proc_parameter_list_has_names :: proc(lexer: ^Lexer) -> bool {
    saved := lexer^
    defer lexer^ = saved

    depth := 0
    for {
        token := lexer_consume_token(lexer)
        if token.kind == .EOF { return false }
        if token.kind == .Colon { return true }
        if token.kind == .Other && token.text == "(" { depth += 1 }
        if token.kind == .Other && token.text == ")" {
            if depth == 0 { return false }
            depth -= 1
        }
    }
}

parse_unnamed_type_list :: proc(lexer: ^Lexer) -> [dynamic]string {
    types := make([dynamic]string)
    for {
        builder := strings.builder_make(context.allocator)
        depth   := 0
        for {
            peeked := lexer_peek_token(lexer)
            if peeked.kind == .EOF { break }
            if peeked.kind == .Other && peeked.text == "(" { depth += 1 }
            if peeked.kind == .Other && peeked.text == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            if depth == 0 && peeked.kind == .Comma { break }
            strings.write_string(&builder, lexer_consume_token(lexer).text)
        }
        if type_name := strings.to_string(builder); type_name != "" { append(&types, type_name) }
        if lexer_peek_token(lexer).kind == .Comma { lexer_consume_token(lexer); continue }
        return types
    }
}

parse_parameter_type_list :: proc(lexer: ^Lexer) -> [dynamic]string {
    if !proc_parameter_list_has_names(lexer) { return parse_unnamed_type_list(lexer) }

    types := make([dynamic]string)
    for {
        name_count := 0
        for {
            peeked := lexer_peek_token(lexer)
            if peeked.kind == .EOF { return types }
            if peeked.kind == .Other && peeked.text == ")" { return types }
            if peeked.kind == .Colon { break }
            if peeked.kind == .Identifier { name_count += 1 }
            lexer_consume_token(lexer)
        }
        lexer_consume_token(lexer)

        builder := strings.builder_make(context.allocator)
        for {
            peeked := lexer_peek_token(lexer)
            if peeked.kind == .EOF { break }
            if peeked.kind == .Other && (peeked.text == ")" || peeked.text == "=") { break }
            if peeked.kind == .Comma { break }
            strings.write_string(&builder, lexer_consume_token(lexer).text)
        }
        if type_name := strings.to_string(builder); type_name != "" {
            for _ in 0..<max(name_count, 1) { append(&types, type_name) }
        }

        if lexer_peek_token(lexer).kind == .Comma { lexer_consume_token(lexer) }
    }
}

Named_Parameter :: struct {
    name   : string,
    type   : string,
    line   : int,
    column : int,
}

parse_named_parameter_list :: proc(lexer: ^Lexer) -> [dynamic]Named_Parameter {
    parameters := make([dynamic]Named_Parameter, context.temp_allocator)
    if !proc_parameter_list_has_names(lexer) { return parameters }

    for {
        names := make([dynamic]Token, context.temp_allocator)
        for {
            peeked := lexer_peek_token(lexer)
            if peeked.kind == .EOF { return parameters }
            if peeked.kind == .Other && peeked.text == ")" { return parameters }
            if peeked.kind == .Colon { break }
            if peeked.kind == .Identifier { append(&names, lexer_consume_token(lexer)) } else { lexer_consume_token(lexer) }
        }
        lexer_consume_token(lexer)

        builder := strings.builder_make(context.temp_allocator)
        for {
            peeked := lexer_peek_token(lexer)
            if peeked.kind == .EOF { break }
            if peeked.kind == .Other && (peeked.text == ")" || peeked.text == "=") { break }
            if peeked.kind == .Comma { break }
            strings.write_string(&builder, lexer_consume_token(lexer).text)
        }
        if type_name := strings.to_string(builder); type_name != "" {
            for name_token in names { append(&parameters, Named_Parameter{name = name_token.text, type = type_name, line = name_token.line, column = name_token.column}) }
        }

        if lexer_peek_token(lexer).kind == .Comma { lexer_consume_token(lexer) }
    }
}

parse_proc_definition :: proc(lexer: ^Lexer) -> Proc_Definition {
    defn := Proc_Definition{params = make([dynamic]string), returns = make([dynamic]string)}

    if lexer_peek_token(lexer).kind == .String_Literal { lexer_consume_token(lexer) }
    open_paren := lexer_consume_token(lexer)
    if open_paren.kind != .Other || open_paren.text != "(" { return defn }

    defn.params = parse_parameter_type_list(lexer)
    if lexer_peek_token(lexer).kind == .Other && lexer_peek_token(lexer).text == ")" { lexer_consume_token(lexer) }

    if lexer_peek_token(lexer).kind == .Other && lexer_peek_token(lexer).text == "-" {
        lexer_consume_token(lexer)
        if lexer_peek_token(lexer).kind == .Other && lexer_peek_token(lexer).text == ">" { lexer_consume_token(lexer) }

        if lexer_peek_token(lexer).kind == .Other && lexer_peek_token(lexer).text == "(" {
            lexer_consume_token(lexer)
            defn.returns = parse_parameter_type_list(lexer)
            if lexer_peek_token(lexer).kind == .Other && lexer_peek_token(lexer).text == ")" { lexer_consume_token(lexer) }
        } else {
            arrow_line := lexer_peek_token(lexer).line
            builder    := strings.builder_make(context.allocator)
            for {
                peeked := lexer_peek_token(lexer)
                if peeked.kind == .EOF || peeked.kind == .Open_Brace || peeked.line > arrow_line { break }
                if peeked.kind == .Hash || (peeked.kind == .Other && peeked.text == "-") { break }
                strings.write_string(&builder, lexer_consume_token(lexer).text)
            }
            if return_type := strings.to_string(builder); return_type != "" { append(&defn.returns, return_type) }
        }
    }

    return defn
}

find_odin_standard_library_root :: proc() -> (string, bool) {
    if g_odin_root != "" { return g_odin_root, true }

    saved := context.allocator
    context.allocator = g_persistent_allocator
    defer context.allocator = saved

    env_value, found := os.lookup_env_alloc("ODIN_ROOT", context.allocator)
    if found && env_value != "" {
        root := env_value
        if root[len(root)-1] == '/' { root = root[:len(root)-1] }
        g_odin_root = strings.clone(root)
        delete(env_value)
        return g_odin_root, true
    }
    if found { delete(env_value) }

    state, stdout, stderr, err := os.process_exec({command = {"odin", "root"}}, context.allocator)
    if err != nil || !state.success { delete(stdout); delete(stderr); return "", false }
    delete(stderr)

    root := strings.trim_space(string(stdout))
    if len(root) > 0 && root[len(root)-1] == '/' { root = root[:len(root)-1] }
    g_odin_root = strings.clone(root)
    delete(stdout)
    return g_odin_root, true
}

resolve_import_path_to_directory :: proc(import_path: string, source_dir: string) -> (string, bool) {
    colon := -1
    for i := 0; i < len(import_path); i += 1 { if import_path[i] == ':' { colon = i; break } }

    if colon != -1 {
        standard_library_root, ok := find_odin_standard_library_root()
        if !ok { return "", false }
        return strings.concatenate({standard_library_root, "/", import_path[:colon], "/", import_path[colon+1:]}), true
    }

    return strings.concatenate({source_dir, "/", import_path}), true
}

load_and_cache_imported_package :: proc(package_dir: string) {
    if package_dir in g_imported_package_cache { return }

    caller_allocator := context.allocator
    context.allocator = virtual.arena_allocator(&g_imported_package_arena)

    pkg := Imported_Package{
        structs            = make(map[string]Struct_Definition),
        enums              = make(map[string]Enum_Definition),
        unions             = make(map[string]Union_Definition),
        procs              = make(map[string]Proc_Definition),
        variables          = make(map[string]string),
        variable_locations = make(map[string]Symbol_Ref),
    }

    exported_type_aliases         := make(map[string]string)
    exported_type_alias_locations := make(map[string]Symbol_Ref)

    file_infos, err := os.read_all_directory_by_path(package_dir, context.allocator)
    if err != nil {
        context.allocator = caller_allocator
        g_imported_package_cache[package_dir] = pkg
        return
    }
    defer os.file_info_slice_delete(file_infos, context.allocator)

    for file_info in file_infos {
        if file_info.type == .Directory               { continue }
        if !strings.has_suffix(file_info.name, ".odin") { continue }

        full_path := strings.concatenate({package_dir, "/", file_info.name}, context.allocator)
        source_bytes, read_err := os.read_entire_file_from_path(full_path, context.allocator)
        if read_err != nil { delete(full_path, context.allocator); continue }

        file_result := parse_file_declarations(full_path, string(source_bytes))
        delete(full_path, context.allocator)
        delete(source_bytes, context.allocator)

        for k, &struct_defn in file_result.project_structs    { pkg.structs[k]                    = struct_defn }
        for k, &enum_defn   in file_result.project_enums      { pkg.enums[k]                      = enum_defn   }
        for k, &union_defn  in file_result.project_unions     { pkg.unions[k]                      = union_defn  }
        for k, &proc_defn   in file_result.project_procs      { pkg.procs[k]                       = proc_defn   }
        for k,  type_name   in file_result.project_variables  { exported_type_aliases[k]           = type_name   }
        for k,  loc         in file_result.project_variable_locations { exported_type_alias_locations[k] = loc   }
    }

    follow_type_alias_chain :: proc(aliases: map[string]string, start: string) -> string {
        current := start
        for hops := 0; hops < 100; hops += 1 {
            next, ok := aliases[current]; if !ok { return current }; current = next
        }
        return current
    }

    for alias_name, target in exported_type_aliases {
        if len(alias_name) == 0 || alias_name[0] < 'A' || alias_name[0] > 'Z' { continue }
        resolved_name := follow_type_alias_chain(exported_type_aliases, target)

        cloned_alias := strings.clone(alias_name)
        if loc, has_loc := exported_type_alias_locations[alias_name]; has_loc {
            pkg.variable_locations[cloned_alias] = loc
        }
        if struct_entry, ok := pkg.structs[resolved_name]; ok {
            struct_copy := Struct_Definition{fields = make([dynamic]Struct_Field, len(struct_entry.fields))}
            for &field, i in struct_entry.fields { struct_copy.fields[i] = {name = strings.clone(field.name), type = strings.clone(field.type)} }
            pkg.structs[cloned_alias] = struct_copy
        } else if enum_entry, ok := pkg.enums[resolved_name]; ok {
            enum_copy := Enum_Definition{values = make([dynamic]string, len(enum_entry.values))}
            for value, i in enum_entry.values { enum_copy.values[i] = strings.clone(value) }
            pkg.enums[cloned_alias] = enum_copy
        } else {
            pkg.variables[cloned_alias] = strings.clone(resolved_name)
        }
    }

    context.allocator = caller_allocator
    g_imported_package_cache[package_dir] = pkg
}

merge_imported_package_into_index :: proc(index: ^Symbol_Index, import_alias: string, package_dir: string) {
    cached_package, ok := g_imported_package_cache[package_dir]
    if !ok { return }
    if import_alias != "." {
        if existing_dir, already_registered := index.imported_package_dirs[import_alias]; already_registered && existing_dir == package_dir { return }
        index.imported_package_dirs[strings.clone(import_alias)] = strings.clone(package_dir)
    }

    register_or_track_import_conflict :: proc(
        index       : ^Symbol_Index,
        import_alias: string,
        package_dir : string,
        name        : string,
        imported    : ^map[string]$Definition,
        defn        : Definition,
        sources     : ^map[string]string,
        conflicts   : ^map[string][dynamic]string,
        project     : map[string]Definition,
    ) {
        if name in project { return }
        if name not_in imported^ {
            imported^[name] = defn
            sources^[strings.clone(name)] = strings.clone(import_alias)
            return
        }
        existing_source := sources^[name]
        existing_dir, dir_known := index.imported_package_dirs[existing_source]
        if dir_known && existing_dir == package_dir { return }
        if name not_in conflicts^ {
            conflicts^[strings.clone(name)] = make([dynamic]string)
            append(&conflicts^[name], strings.clone(existing_source))
            append(&conflicts^[name], strings.clone(import_alias))
        } else {
            already_listed := false
            for listed_alias in conflicts^[name] { if listed_alias == import_alias { already_listed = true; break } }
            if !already_listed { append(&conflicts^[name], strings.clone(import_alias)) }
        }
    }

    for name, defn in cached_package.structs {
        register_or_track_import_conflict(index, import_alias, package_dir, name, &index.all_imported_structs, defn, &index.imported_struct_origin_alias, &index.imported_struct_conflicts, index.project_structs)
    }
    for name, defn in cached_package.enums {
        register_or_track_import_conflict(index, import_alias, package_dir, name, &index.all_imported_enums, defn, &index.imported_enum_origin_alias, &index.imported_enum_conflicts, index.project_enums)
    }
}

load_imports_for_directory :: proc(index: ^Symbol_Index, source_dir: string) {
    for import_alias, import_path in index.import_aliases {
        if import_alias == "_" { continue }
        package_dir, ok := resolve_import_path_to_directory(import_path, source_dir)
        if !ok { continue }
        load_and_cache_imported_package(package_dir)
        merge_imported_package_into_index(index, import_alias, package_dir)
    }
}

directory_name_is_hidden :: proc(name: string) -> bool {
    return len(name) > 0 && name[0] == '.'
}

parse_and_register_file :: proc(file_path: string, source: string) -> Parsed_File_Declarations {
    caller_allocator  := context.allocator
    context.allocator  = g_persistent_allocator
    result            := parse_file_declarations(file_path, source)
    context.allocator  = caller_allocator

    file_symbol_names := Indexed_File_Metadata{
        struct_names    = make([dynamic]string),
        enum_names      = make([dynamic]string),
        union_names     = make([dynamic]string),
        proc_names      = make([dynamic]string),
        variable_names  = make([dynamic]string),
        import_aliases  = make(map[string]string),
        source_filename = path_basename(strings.clone(file_path)),
    }
    for name in result.project_structs            { append(&file_symbol_names.struct_names,   strings.clone(name)) }
    for name in result.project_enums              { append(&file_symbol_names.enum_names,     strings.clone(name)) }
    for name in result.project_unions             { append(&file_symbol_names.union_names,    strings.clone(name)) }
    for name in result.project_procs              { append(&file_symbol_names.proc_names,     strings.clone(name)) }
    for name in result.project_variables          { append(&file_symbol_names.variable_names, strings.clone(name)) }
    for import_alias, import_path in result.import_aliases {
        file_symbol_names.import_aliases[strings.clone(import_alias)] = strings.clone(import_path)
    }
    g_indexed_file_metadata_by_path[file_path] = file_symbol_names
    for name in result.project_structs   { g_symbol_source_filename_by_name[strings.clone(name)] = file_symbol_names.source_filename }
    for name in result.project_enums     { g_symbol_source_filename_by_name[strings.clone(name)] = file_symbol_names.source_filename }
    for name in result.project_unions    { g_symbol_source_filename_by_name[strings.clone(name)] = file_symbol_names.source_filename }
    for name in result.project_procs     { g_symbol_source_filename_by_name[strings.clone(name)] = file_symbol_names.source_filename }
    for name in result.project_variables { g_symbol_source_filename_by_name[strings.clone(name)] = file_symbol_names.source_filename }

    return result
}

build_symbol_index :: proc(project_root: string) -> (Symbol_Index, [dynamic]string) {
    index := Symbol_Index {
        project_structs            = make(map[string]Struct_Definition),
        project_enums              = make(map[string]Enum_Definition),
        project_unions             = make(map[string]Union_Definition),
        project_procs              = make(map[string]Proc_Definition),
        project_variables          = make(map[string]string),
        project_variable_locations = make(map[string]Symbol_Ref),
        project_constants          = make(map[string]string),
        import_aliases             = make(map[string]string),
        imported_package_dirs      = make(map[string]string),
        all_imported_structs       = make(map[string]Struct_Definition),
        all_imported_enums         = make(map[string]Enum_Definition),
        imported_struct_origin_alias    = make(map[string]string),
        imported_enum_origin_alias      = make(map[string]string),
        imported_struct_conflicts  = make(map[string][dynamic]string),
        imported_enum_conflicts    = make(map[string][dynamic]string),
    }
    project_source_dirs := make([dynamic]string)
    dir_stack    := make([dynamic]string, context.allocator)
    append(&dir_stack, strings.clone(project_root, context.allocator))

    for len(dir_stack) > 0 {
        current_dir := dir_stack[len(dir_stack)-1]
        pop(&dir_stack)

        entries, err := os.read_all_directory_by_path(current_dir, context.allocator)
        if err != nil { continue }

        dir_has_odin_files := false
        for entry in entries {
            if entry.type == .Directory {
                if !directory_name_is_hidden(entry.name) {
                    append(&dir_stack, strings.concatenate({current_dir, "/", entry.name}, context.allocator))
                }
                continue
            }
            if !strings.has_suffix(entry.name, ".odin") { continue }
            full_path := strings.concatenate({current_dir, "/", entry.name}, context.allocator)
            source_bytes, read_err := os.read_entire_file_from_path(full_path, context.allocator)
            if read_err != nil { delete(full_path, context.allocator); continue }
            file_result := parse_and_register_file(full_path, string(source_bytes))
            merge_file_declarations_into_index(&index, &file_result)
            g_file_content_hash_by_path[full_path] = compute_file_hash(source_bytes)
            delete(source_bytes, context.allocator)
            dir_has_odin_files = true
        }
        os.file_info_slice_delete(entries, context.allocator)

        if dir_has_odin_files { append(&project_source_dirs, strings.clone(current_dir, context.allocator)) }
    }

    for dir in project_source_dirs {
        load_imports_for_directory(&index, dir)
    }

    return index, project_source_dirs
}

merge_file_declarations_into_index :: proc(index: ^Symbol_Index, file_result: ^Parsed_File_Declarations) {
    for k, &struct_defn in file_result.project_structs            { index.project_structs[k]             = struct_defn }
    for k, &enum_defn   in file_result.project_enums              { index.project_enums[k]               = enum_defn   }
    for k, &union_defn  in file_result.project_unions             { index.project_unions[k]              = union_defn  }
    for k,  proc_defn   in file_result.project_procs              { index.project_procs[k]               = proc_defn   }
    for k,  type_name   in file_result.project_variables          { index.project_variables[k]           = type_name   }
    for k,  loc         in file_result.project_variable_locations { index.project_variable_locations[k]  = loc         }
    for k,  value       in file_result.project_constants          { index.project_constants[k]           = value       }
    for k,  import_path in file_result.import_aliases             { index.import_aliases[k]              = import_path  }
}

path_parent_dir :: proc(file_path: string, allocator := context.allocator) -> string {
    for i := len(file_path)-1; i >= 0; i -= 1 {
        if file_path[i] == '/' {
            if i == 0 { return strings.clone("/", allocator) }
            return strings.clone(file_path[:i], allocator)
        }
    }
    return strings.clone(".", allocator)
}

path_basename :: proc(path: string) -> string {
    for i := len(path)-1; i >= 0; i -= 1 {
        if path[i] == '/' { return path[i+1:] }
    }
    return path
}

symbol_index_free :: proc(index: ^Symbol_Index) {
    delete(index.project_structs)
    delete(index.project_enums)
    delete(index.project_unions)
    delete(index.project_procs)
    delete(index.project_variables)
    delete(index.project_variable_locations)
    delete(index.project_constants)
    delete(index.import_aliases)
    delete(index.all_imported_structs)
    delete(index.all_imported_enums)

    for k, v in index.imported_package_dirs   { delete(k); delete(v) }
    delete(index.imported_package_dirs)

    for k, v in index.imported_struct_origin_alias { delete(k); delete(v) }
    delete(index.imported_struct_origin_alias)

    for k, v in index.imported_enum_origin_alias   { delete(k); delete(v) }
    delete(index.imported_enum_origin_alias)

    for k, &v in index.imported_struct_conflicts { for s in v { delete(s) }; delete(v); delete(k) }
    delete(index.imported_struct_conflicts)

    for k, &v in index.imported_enum_conflicts   { for s in v { delete(s) }; delete(v); delete(k) }
    delete(index.imported_enum_conflicts)
}

imported_package_cache_free :: proc() {
    delete(g_imported_package_cache)
    virtual.arena_free_all(&g_imported_package_arena)
}

compute_file_hash :: proc(data: []u8) -> u64 {
    return xxhash.XXH64(data, 0)
}

rebuild_symbol_index :: proc(project_root: string) {
    fmt.eprintfln("index build begin  root=%s", project_root)

    g_persistent_allocator = context.allocator

    symbol_index_free(&g_project_symbol_index)
    imported_package_cache_free()

    g_imported_package_cache                  = make(map[string]Imported_Package)
    g_symbol_source_filename_by_name = make(map[string]string)

    new_index, project_source_dirs := build_symbol_index(project_root)
    for dir in project_source_dirs { load_and_cache_imported_package(dir) }

    g_project_symbol_index = new_index

    fmt.eprintfln("index build complete root=%s", project_root)
}

reindex_file_from_source_bytes :: proc(file_path: string, was_already_indexed: bool, source_bytes: []u8) {
    canonical_path := file_path if was_already_indexed else strings.clone(file_path, g_persistent_allocator)

    if previous_symbols, ok := g_indexed_file_metadata_by_path[canonical_path]; ok {
        for name in previous_symbols.struct_names   { delete_key(&g_project_symbol_index.project_structs,   name) }
        for name in previous_symbols.enum_names     { delete_key(&g_project_symbol_index.project_enums,     name) }
        for name in previous_symbols.union_names    { delete_key(&g_project_symbol_index.project_unions,    name) }
        for name in previous_symbols.proc_names     { delete_key(&g_project_symbol_index.project_procs,     name) }
        for name in previous_symbols.variable_names {
            delete_key(&g_project_symbol_index.project_variables,          name)
            delete_key(&g_project_symbol_index.project_variable_locations, name)
            delete_key(&g_project_symbol_index.project_constants,          name)
        }

        for name in previous_symbols.struct_names   { delete_key(&g_symbol_source_filename_by_name, name) }
        for name in previous_symbols.enum_names     { delete_key(&g_symbol_source_filename_by_name, name) }
        for name in previous_symbols.union_names    { delete_key(&g_symbol_source_filename_by_name, name) }
        for name in previous_symbols.proc_names     { delete_key(&g_symbol_source_filename_by_name, name) }
        for name in previous_symbols.variable_names { delete_key(&g_symbol_source_filename_by_name, name) }
    }

    file_result := parse_and_register_file(canonical_path, string(source_bytes))
    merge_file_declarations_into_index(&g_project_symbol_index, &file_result)

    clear(&g_project_symbol_index.import_aliases)
    clear(&g_project_symbol_index.imported_package_dirs)
    for _, file_symbols in g_indexed_file_metadata_by_path {
        for import_alias, import_path in file_symbols.import_aliases {
            if import_alias != "_" && import_alias != "" {
                g_project_symbol_index.import_aliases[strings.clone(import_alias, g_persistent_allocator)] = strings.clone(import_path, g_persistent_allocator)
            }
        }
    }

    still_valid_import_aliases := make(map[string]bool, context.temp_allocator)
    for import_alias in g_project_symbol_index.import_aliases { still_valid_import_aliases[import_alias] = true }

    prune_stale_imports :: proc(
        imported  : ^map[string]$D,
        sources   : ^map[string]string,
        conflicts : ^map[string][dynamic]string,
        valid     : map[string]bool,
    ) {
        names_to_remove := make([dynamic]string, context.temp_allocator)
        for name, source in sources^ {
            if source not_in valid { append(&names_to_remove, name) }
        }
        for name in names_to_remove {
            delete_key(imported,  name)
            delete_key(sources,   name)
            delete_key(conflicts, name)
        }
    }

    prune_stale_imports(&g_project_symbol_index.all_imported_structs, &g_project_symbol_index.imported_struct_origin_alias, &g_project_symbol_index.imported_struct_conflicts, still_valid_import_aliases)
    prune_stale_imports(&g_project_symbol_index.all_imported_enums,   &g_project_symbol_index.imported_enum_origin_alias,   &g_project_symbol_index.imported_enum_conflicts,   still_valid_import_aliases)

    source_dir := path_parent_dir(canonical_path, context.temp_allocator)
    load_imports_for_directory(&g_project_symbol_index, source_dir)
}

reindex_file_from_disk :: proc(file_path: string) {
    source_bytes, read_err := os.read_entire_file_from_path(file_path, context.temp_allocator)
    if read_err != nil {
        fmt.eprintfln("gjallarhorn: index rebuild error reading file=%s", file_path)
        return
    }

    content_hash              := compute_file_hash(source_bytes)
    cached_hash, was_indexed  := g_file_content_hash_by_path[file_path]
    if was_indexed && cached_hash == content_hash { return }

    reindex_file_from_source_bytes(file_path, was_indexed, source_bytes)

    g_file_content_hash_by_path[file_path if was_indexed else strings.clone(file_path, g_persistent_allocator)] = content_hash
}

reindex_file_from_unsaved_buffer :: proc(file_path: string, unsaved_source: string) {
    source_bytes             := transmute([]u8)unsaved_source
    content_hash             := compute_file_hash(source_bytes)
    cached_hash, was_indexed := g_file_content_hash_by_path[file_path]
    if was_indexed && cached_hash == content_hash { return }
    reindex_file_from_source_bytes(file_path, was_indexed, source_bytes)
    g_file_content_hash_by_path[file_path if was_indexed else strings.clone(file_path, g_persistent_allocator)] = content_hash
}

split_qualified_name_at_dot :: proc(name: string) -> (before, after: string, found: bool) {
    for i := 0; i < len(name); i += 1 {
        if name[i] == '.' { return name[:i], name[i+1:], true }
    }
    return "", "", false
}

split_map_lookup_expression :: proc(expression: string) -> (container: string, ok: bool) {
    open_bracket := strings.index_byte(expression, '[')
    if open_bracket <= 0 || !strings.has_suffix(expression, "]") { return "", false }
    container = expression[:open_bracket]
    if strings.contains_any(container, " \t()[]&*^") { return "", false }
    if strings.index_byte(expression[open_bracket:], ':') != -1 { return "", false }
    return container, true
}

split_map_type_string :: proc(type_string: string) -> (key_type, value_type: string, ok: bool) {
    if !strings.has_prefix(type_string, "map[") { return "", "", false }
    depth := 1
    for i := 4; i < len(type_string); i += 1 {
        switch type_string[i] {
        case '[': depth += 1
        case ']':
            depth -= 1
            if depth == 0 {
                key_type   = type_string[4:i]
                value_type = type_string[i+1:]
                if key_type == "" || value_type == "" { return "", "", false }
                return key_type, value_type, true
            }
        }
    }
    return "", "", false
}

imported_package_by_import_alias :: proc(import_alias: string) -> ^Imported_Package {
    package_dir, ok := g_project_symbol_index.imported_package_dirs[import_alias]
    if !ok { return nil }
    if pkg, found := &g_imported_package_cache[package_dir]; found { return pkg }
    return nil
}

local_scope_find_struct :: proc(scope: Local_Scope, name: string) -> (defn: Struct_Definition, line_offset: int, found: bool) {
    for block in scope.blocks { if defn, ok := block.declarations.project_structs[name]; ok { return defn, block.line_offset, true } }
    return {}, 0, false
}

local_scope_find_enum :: proc(scope: Local_Scope, name: string) -> (defn: Enum_Definition, line_offset: int, found: bool) {
    for block in scope.blocks { if defn, ok := block.declarations.project_enums[name]; ok { return defn, block.line_offset, true } }
    return {}, 0, false
}

local_scope_find_union :: proc(scope: Local_Scope, name: string) -> (defn: Union_Definition, line_offset: int, found: bool) {
    for block in scope.blocks { if defn, ok := block.declarations.project_unions[name]; ok { return defn, block.line_offset, true } }
    return {}, 0, false
}

local_scope_find_proc :: proc(scope: Local_Scope, name: string) -> (defn: Proc_Definition, line_offset: int, found: bool) {
    if defn, ok := scope.procs[name]; ok { return defn, 0, true }
    return {}, 0, false
}

local_scope_find_variable_type :: proc(scope: Local_Scope, name: string, remaining_hops := 8) -> (string, bool) {
    for block in scope.blocks {
        for parameter in block.parameters { if parameter.name == name { return parameter.type, true } }
        if type_name, found := block.declarations.project_variables[name]; found { return type_name, true }
        if lookup_expression, found := block.declarations.map_lookup_expressions[name]; found {
            if remaining_hops == 0 { return "", false }
            container, _ := split_map_lookup_expression(lookup_expression)
            container_type := resolve_dot_chain_to_final_type(container, scope, remaining_hops - 1)
            if _, value_type, is_map := split_map_type_string(container_type); is_map { return value_type, true }
            return "", false
        }
    }
    return "", false
}

local_scope_find_variable_location :: proc(scope: Local_Scope, name: string) -> (loc: Symbol_Ref, line_offset: int, found: bool) {
    for block in scope.blocks {
        for parameter in block.parameters {
            if parameter.name == name { return Symbol_Ref{line = parameter.line, column = parameter.column}, 0, true }
        }
        if loc, ok := block.declarations.project_variable_locations[name]; ok { return loc, block.line_offset, true }
    }
    return {}, 0, false
}

local_scope_find_constant :: proc(scope: Local_Scope, name: string) -> (string, bool) {
    for block in scope.blocks { if value, found := block.declarations.project_constants[name]; found { return value, true } }
    return "", false
}

resolve_dot_chain_head_to_type_name :: proc(name: string, local_scope: Maybe(Local_Scope) = nil, remaining_hops := 8) -> string {
    if paren_index := strings.index_byte(name, '('); paren_index != -1 {
        called_proc_name := name[:paren_index]
        if scope, has_scope := local_scope.?; has_scope {
            if defn, _, found := local_scope_find_proc(scope, called_proc_name); found && len(defn.returns) > 0 { return defn.returns[0] }
        }
        if defn, found := g_project_symbol_index.project_procs[called_proc_name]; found && len(defn.returns) > 0 { return defn.returns[0] }
        return ""
    }
    if scope, has_scope := local_scope.?; has_scope {
        for parameter in scope.parameters { if parameter.name == name { return parameter.type } }
        if _, _, found := local_scope_find_struct(scope, name); found { return name }
        if _, _, found := local_scope_find_enum(scope, name);   found { return name }
        if type_name, found := local_scope_find_variable_type(scope, name, remaining_hops); found { return type_name }
    }
    if name in g_project_symbol_index.project_structs               { return name }
    if name in g_project_symbol_index.project_enums                 { return name }
    if name in g_project_symbol_index.imported_struct_conflicts     { return ""   }
    if name in g_project_symbol_index.all_imported_structs          { return name }
    if name in g_project_symbol_index.imported_enum_conflicts       { return ""   }
    if name in g_project_symbol_index.all_imported_enums            { return name }
    if type_name, ok := g_project_symbol_index.project_variables[name]; ok { return type_name }
    return ""
}

find_qualified_symbol_in_procedure_source :: proc(enclosing_procedure_source: string, symbol: string) -> string {
    source := enclosing_procedure_source
    for line in strings.split_lines_iterator(&source) {
        search_offset := 0
        for {
            match_offset := strings.index(line[search_offset:], symbol)
            if match_offset == -1 { break }
            absolute_offset := search_offset + match_offset
            dot_offset      := absolute_offset - 1
            if dot_offset < 0 || line[dot_offset] != '.' { search_offset = absolute_offset + 1; continue }
            alias_end   := dot_offset
            alias_start := alias_end - 1
            for alias_start > 0 && (line[alias_start-1] == '_' || (line[alias_start-1] >= 'a' && line[alias_start-1] <= 'z') || (line[alias_start-1] >= 'A' && line[alias_start-1] <= 'Z') || (line[alias_start-1] >= '0' && line[alias_start-1] <= '9')) { alias_start -= 1 }
            import_alias := line[alias_start:alias_end]
            if _, ok := g_project_symbol_index.imported_package_dirs[import_alias]; ok {
                return strings.concatenate({import_alias, ".", symbol}, context.temp_allocator)
            }
            search_offset = absolute_offset + 1
        }
    }
    return ""
}

format_struct :: proc(name: string, defn: Struct_Definition) -> string {
    max_field_name_len := 0
    for field in defn.fields { if len(field.name) > max_field_name_len { max_field_name_len = len(field.name) } }
    builder := strings.builder_make()
    strings.write_string(&builder, name); strings.write_string(&builder, " struct\n")
    for field in defn.fields {
        strings.write_string(&builder, g_indent_spaces)
        strings.write_string(&builder, field.name)
        for _ in 0..<max_field_name_len-len(field.name) { strings.write_byte(&builder, ' ') }
        strings.write_byte(&builder, ' ')
        strings.write_string(&builder, field.type); strings.write_byte(&builder, '\n')
    }
    return strings.to_string(builder)
}

format_labeled_list :: proc(name: string, label: string, items: []string) -> string {
    builder := strings.builder_make()
    strings.write_string(&builder, name); strings.write_string(&builder, " "); strings.write_string(&builder, label); strings.write_byte(&builder, '\n')
    for item in items {
        strings.write_string(&builder, g_indent_spaces); strings.write_string(&builder, item); strings.write_byte(&builder, '\n')
    }
    return strings.to_string(builder)
}

format_proc :: proc(name: string, defn: Proc_Definition) -> string {
    builder := strings.builder_make()
    strings.write_string(&builder, name); strings.write_string(&builder, " proc")
    for param in defn.params {
        strings.write_byte(&builder, '\n'); strings.write_string(&builder, g_indent_spaces)
        strings.write_string(&builder, "<- "); strings.write_string(&builder, param)
    }
    for return_type in defn.returns {
        strings.write_byte(&builder, '\n'); strings.write_string(&builder, g_indent_spaces)
        strings.write_string(&builder, "-> "); strings.write_string(&builder, return_type)
    }
    return strings.to_string(builder)
}

proc_signature_summary :: proc(defn: Proc_Definition) -> string {
    params := strings.join(defn.params[:], ", ")
    if len(defn.returns) == 0 { return fmt.tprintf("(%s)", params) }
    return fmt.tprintf("(%s) -> %s", params, strings.join(defn.returns[:], ", "))
}

hover_text_for_type_name :: proc(type_name: string) -> string {
    lookup := strings.trim_prefix(type_name, "^")
    if defn, found := g_project_symbol_index.project_structs[lookup];       found { return format_struct(type_name, defn) }
    if defn, found := g_project_symbol_index.project_enums[lookup];         found { return format_labeled_list(type_name, "enum", defn.values[:])   }
    if defn, found := g_project_symbol_index.project_unions[lookup];        found { return format_labeled_list(type_name, "union", defn.variants[:]) }
    if defn, found := g_project_symbol_index.all_imported_structs[lookup];  found { return format_struct(type_name, defn) }
    if defn, found := g_project_symbol_index.all_imported_enums[lookup];    found { return format_labeled_list(type_name, "enum", defn.values[:])   }
    if import_alias, member_name, has_dot := split_qualified_name_at_dot(lookup); has_dot {
        if pkg := imported_package_by_import_alias(import_alias); pkg != nil {
            if defn, found := pkg.structs[member_name];            found { return format_struct(type_name, defn)                  }
            if defn, found := pkg.enums[member_name];              found { return format_labeled_list(type_name, "enum", defn.values[:])     }
            if defn, found := pkg.unions[member_name];             found { return format_labeled_list(type_name, "union", defn.variants[:])   }
            if defn, found := pkg.procs[member_name];              found { return format_proc(type_name, defn)                    }
            if alias_type, found := pkg.variables[member_name];    found { return fmt.tprintf("%s %s", type_name, alias_type)     }
        }
    }
    return ""
}

hover_text_for_typed_symbol :: proc(symbol: string, type_name: string) -> string {
    if hover_text := hover_text_for_type_name(type_name); hover_text != "" { return hover_text }
    return fmt.tprintf("%s %s", symbol, type_name)
}

hover_text_for_package_member :: proc(import_alias: string, member_name: string) -> string {
    pkg := imported_package_by_import_alias(import_alias)
    if pkg == nil { return "" }
    if defn, found := pkg.procs[member_name];   found { return format_proc(member_name, defn)   }
    if defn, found := pkg.structs[member_name]; found { return format_struct(member_name, defn) }
    if defn, found := pkg.enums[member_name];   found { return format_labeled_list(member_name, "enum", defn.values[:])   }
    if defn, found := pkg.unions[member_name];  found { return format_labeled_list(member_name, "union", defn.variants[:]) }
    if type_name, found := pkg.variables[member_name]; found { return hover_text_for_typed_symbol(member_name, type_name) }
    return ""
}

hover_text_for_symbol :: proc(symbol: string, dot_chain: string, enclosing_procedure_source: string, cursor_line_offset: int) -> string {
    local_scope: Maybe(Local_Scope)
    if scope, ok := parse_local_scope_from_enclosing_procedure_source(enclosing_procedure_source, cursor_line_offset); ok { local_scope = scope }

    if dot_chain != "" {
        if _, is_import_alias := g_project_symbol_index.imported_package_dirs[dot_chain]; is_import_alias && strings.index_byte(dot_chain, '.') == -1 {
            return hover_text_for_package_member(dot_chain, symbol)
        }
        current_type := resolve_dot_chain_to_final_type(dot_chain, local_scope)
        if current_type == "" { return "" }
        if field_type, found := find_field_type_within_type_name(current_type, symbol, local_scope); found { return hover_text_for_typed_symbol(symbol, field_type) }
        return ""
    }

    if scope, has_scope := local_scope.?; has_scope {
        for parameter in scope.parameters { if parameter.name == symbol { return hover_text_for_typed_symbol(symbol, parameter.type) } }
        if defn, _, found := local_scope_find_struct(scope, symbol); found { return format_struct(symbol, defn) }
        if defn, _, found := local_scope_find_enum(scope, symbol);   found { return format_labeled_list(symbol, "enum", defn.values[:])   }
        if defn, _, found := local_scope_find_union(scope, symbol);  found { return format_labeled_list(symbol, "union", defn.variants[:]) }
        if defn, _, found := local_scope_find_proc(scope, symbol);   found { return format_proc(symbol, defn)   }
        if constant_value, found := local_scope_find_constant(scope, symbol); found { return constant_value }
        if type_name, found := local_scope_find_variable_type(scope, symbol); found { return hover_text_for_typed_symbol(symbol, type_name) }
    }

    if defn, ok := g_project_symbol_index.project_structs[symbol]; ok { return format_struct(symbol, defn) }
    if defn, ok := g_project_symbol_index.project_enums[symbol];   ok { return format_labeled_list(symbol, "enum", defn.values[:])   }
    if defn, ok := g_project_symbol_index.project_unions[symbol];  ok { return format_labeled_list(symbol, "union", defn.variants[:]) }
    if defn, ok := g_project_symbol_index.project_procs[symbol];   ok { return format_proc(symbol, defn)   }

    if symbol in g_project_symbol_index.imported_struct_conflicts || symbol in g_project_symbol_index.imported_enum_conflicts {
        if qualified := find_qualified_symbol_in_procedure_source(enclosing_procedure_source, symbol); qualified != "" {
            if hover_text := hover_text_for_type_name(qualified); hover_text != "" { return hover_text }
        }
        conflicts := g_project_symbol_index.imported_struct_conflicts[symbol]
        if len(conflicts) == 0 { conflicts = g_project_symbol_index.imported_enum_conflicts[symbol] }
        return fmt.tprintf("%s: ambiguous (defined in %s)", symbol, strings.join(conflicts[:], ", "))
    }
    if defn, ok := g_project_symbol_index.all_imported_structs[symbol]; ok { return format_struct(symbol, defn) }
    if defn, ok := g_project_symbol_index.all_imported_enums[symbol];   ok { return format_labeled_list(symbol, "enum", defn.values[:]) }

    if qualified := find_qualified_symbol_in_procedure_source(enclosing_procedure_source, symbol); qualified != "" {
        if hover_text := hover_text_for_type_name(qualified); hover_text != "" { return hover_text }
    }

    if constant_value, ok := g_project_symbol_index.project_constants[symbol]; ok { return constant_value }
    if type_name, ok := g_project_symbol_index.project_variables[symbol]; ok { return hover_text_for_typed_symbol(symbol, type_name) }

    return ""
}

find_symbol_definition_location :: proc(symbol: string, dot_chain: string, enclosing_procedure_source: string, current_file: string, cursor_line_offset: int, procedure_start_line: int) -> (file: string, line: int, column: int, ok: bool) {
    if scope, scope_ok := parse_local_scope_from_enclosing_procedure_source(enclosing_procedure_source, cursor_line_offset); scope_ok {
        for parameter in scope.parameters {
            if parameter.name != symbol { continue }
            return current_file, procedure_start_line + parameter.line - 1, parameter.column, true
        }
        if defn, offset, found := local_scope_find_struct(scope, symbol); found { return current_file, procedure_start_line + (defn.location.line + offset) - 1, defn.location.column, true }
        if defn, offset, found := local_scope_find_enum(scope, symbol);   found { return current_file, procedure_start_line + (defn.location.line + offset) - 1, defn.location.column, true }
        if defn, offset, found := local_scope_find_union(scope, symbol);  found { return current_file, procedure_start_line + (defn.location.line + offset) - 1, defn.location.column, true }
        if defn, offset, found := local_scope_find_proc(scope, symbol);   found { return current_file, procedure_start_line + (defn.location.line + offset) - 1, defn.location.column, true }
        if loc, offset, found := local_scope_find_variable_location(scope, symbol); found { return current_file, procedure_start_line + (loc.line + offset) - 1, loc.column, true }
    }

    package_lookup :: proc(pkg: ^Imported_Package, name: string) -> (file: string, line: int, column: int, ok: bool) {
        if defn, found := pkg.procs[name];               found { loc := defn.location;     return loc.file, loc.line, loc.column, true }
        if defn, found := pkg.structs[name];             found { loc := defn.location;     return loc.file, loc.line, loc.column, true }
        if defn, found := pkg.enums[name];               found { loc := defn.location;     return loc.file, loc.line, loc.column, true }
        if defn, found := pkg.unions[name];              found { loc := defn.location;     return loc.file, loc.line, loc.column, true }
        if loc, found  := pkg.variable_locations[name]; found { return loc.file, loc.line, loc.column, true }
        return "", 0, 0, false
    }

    if _, is_import_alias := g_project_symbol_index.imported_package_dirs[dot_chain]; is_import_alias && strings.index_byte(dot_chain, '.') == -1 {
        if pkg := imported_package_by_import_alias(dot_chain); pkg != nil {
            if file, line, col, found := package_lookup(pkg, symbol); found { return file, line, col, true }
        }
        return "", 0, 0, false
    }

    if defn, found := g_project_symbol_index.project_structs[symbol];             found { loc := defn.location; return loc.file, loc.line, loc.column, true }
    if defn, found := g_project_symbol_index.project_enums[symbol];               found { loc := defn.location; return loc.file, loc.line, loc.column, true }
    if defn, found := g_project_symbol_index.project_unions[symbol];              found { loc := defn.location; return loc.file, loc.line, loc.column, true }
    if defn, found := g_project_symbol_index.project_procs[symbol];               found { loc := defn.location; return loc.file, loc.line, loc.column, true }
    if loc, found := g_project_symbol_index.project_variable_locations[symbol];   found { return loc.file, loc.line, loc.column, true }
    if symbol in g_project_symbol_index.imported_struct_conflicts { return "", 0, 0, false }
    if symbol in g_project_symbol_index.imported_enum_conflicts   { return "", 0, 0, false }
    if defn, found := g_project_symbol_index.all_imported_structs[symbol]; found { loc := defn.location; return loc.file, loc.line, loc.column, true }
    if defn, found := g_project_symbol_index.all_imported_enums[symbol];   found { loc := defn.location; return loc.file, loc.line, loc.column, true }

    if qualified := find_qualified_symbol_in_procedure_source(enclosing_procedure_source, symbol); qualified != "" {
        import_alias, member_name, _ := split_qualified_name_at_dot(qualified)
        if pkg := imported_package_by_import_alias(import_alias); pkg != nil {
            if file, line, col, found := package_lookup(pkg, member_name); found { return file, line, col, true }
        }
    }
    current_dir := path_parent_dir(current_file, context.temp_allocator)
    for package_dir, &pkg in g_imported_package_cache {
        if package_dir == current_dir {
            if file, line, col, found := package_lookup(&pkg, symbol); found { return file, line, col, true }
            break
        }
    }
    return "", 0, 0, false
}

completions_for_import_alias :: proc(import_alias: string, prefix: string) -> string {
    pkg := imported_package_by_import_alias(import_alias)
    if pkg == nil { return "" }

    import_path := g_project_symbol_index.import_aliases[import_alias]
    display_name := import_path if import_path != "" else import_alias

    builder := strings.builder_make()
    for name in pkg.structs {
        if strings.has_prefix(name, prefix) { strings.write_string(&builder, name); strings.write_byte(&builder, '\t'); strings.write_string(&builder, display_name); strings.write_byte(&builder, '\n') }
    }
    for name in pkg.enums {
        if strings.has_prefix(name, prefix) { strings.write_string(&builder, name); strings.write_byte(&builder, '\t'); strings.write_string(&builder, display_name); strings.write_byte(&builder, '\n') }
    }
    for name, defn in pkg.procs {
        if strings.has_prefix(name, prefix) { strings.write_string(&builder, name); strings.write_byte(&builder, '\t'); strings.write_string(&builder, proc_signature_summary(defn)); strings.write_byte(&builder, '\n') }
    }
    for name, defn in pkg.unions {
        if strings.has_prefix(name, prefix) { strings.write_string(&builder, name); strings.write_byte(&builder, '\t'); strings.write_string(&builder, strings.join(defn.variants[:], " ")); strings.write_byte(&builder, '\n') }
    }
    for name, type_name in pkg.variables {
        if strings.has_prefix(name, prefix) { strings.write_string(&builder, name); strings.write_byte(&builder, '\t'); strings.write_string(&builder, type_name); strings.write_byte(&builder, '\n') }
    }
    return strings.trim_right(strings.to_string(builder), "\n")
}

Completion_Entry :: struct {
    name              : string,
    menu_origin_label : string,
    detail            : string,
    kind_rank         : int,
    priority          : int,
    declaration_order : int,
}

collect_local_scope_entries :: proc(entries: ^[dynamic]Completion_Entry, scope: Local_Scope, prefix: string) {
    parameter_count := len(scope.parameters)
    seen_names      := make(map[string]bool, context.temp_allocator)

    for parameter, index in scope.parameters {
        if !strings.has_prefix(parameter.name, prefix) { continue }
        seen_names[parameter.name] = true
        append(entries, Completion_Entry{name = parameter.name, menu_origin_label = scope.procedure_name, detail = parameter.type, kind_rank = 5, priority = 0, declaration_order = index})
    }

    BLOCK_TIER_SPAN :: 100000
    for block, block_index in scope.blocks {
        block_tier := parameter_count + block_index * BLOCK_TIER_SPAN

        for parameter, parameter_index in block.parameters {
            if !strings.has_prefix(parameter.name, prefix) || seen_names[parameter.name] { continue }
            seen_names[parameter.name] = true
            append(entries, Completion_Entry{name = parameter.name, menu_origin_label = scope.procedure_name, detail = parameter.type, kind_rank = 5, priority = 0, declaration_order = block_tier + parameter_index})
        }

        for name, defn in block.declarations.project_structs {
            if !strings.has_prefix(name, prefix) || seen_names[name] { continue }
            seen_names[name] = true
            field_types := make([dynamic]string, context.temp_allocator)
            for field in defn.fields { append(&field_types, field.type) }
            append(entries, Completion_Entry{name = name, menu_origin_label = scope.procedure_name, detail = strings.join(field_types[:], " "), kind_rank = 1, priority = 0, declaration_order = block_tier + defn.location.line})
        }
        for name, defn in block.declarations.project_enums {
            if !strings.has_prefix(name, prefix) || seen_names[name] { continue }
            seen_names[name] = true
            append(entries, Completion_Entry{name = name, menu_origin_label = scope.procedure_name, detail = strings.join(defn.values[:], " "), kind_rank = 2, priority = 0, declaration_order = block_tier + defn.location.line})
        }
        for name, defn in block.declarations.project_unions {
            if !strings.has_prefix(name, prefix) || seen_names[name] { continue }
            seen_names[name] = true
            append(entries, Completion_Entry{name = name, menu_origin_label = scope.procedure_name, detail = strings.join(defn.variants[:], " "), kind_rank = 3, priority = 0, declaration_order = block_tier + defn.location.line})
        }
        for name, type_name in block.declarations.project_variables {
            if !strings.has_prefix(name, prefix) || seen_names[name] { continue }
            seen_names[name] = true
            location := block.declarations.project_variable_locations[name]
            append(entries, Completion_Entry{name = name, menu_origin_label = scope.procedure_name, detail = type_name, kind_rank = 5, priority = 0, declaration_order = block_tier + location.line})
        }
        for name, value in block.declarations.project_constants {
            if !strings.has_prefix(name, prefix) || seen_names[name] { continue }
            loop_header_prefix := fmt.tprintf("%s for ", name)
            if !strings.has_prefix(value, loop_header_prefix) { continue }
            seen_names[name] = true
            append(entries, Completion_Entry{name = name, menu_origin_label = scope.procedure_name, detail = strings.trim_prefix(value, fmt.tprintf("%s ", name)), kind_rank = 6, priority = 0, declaration_order = block_tier})
        }
    }
}

completions_for_unqualified_prefix :: proc(prefix: string, current_file: string, local_scope: Maybe(Local_Scope) = nil) -> string {
    current_filename := path_basename(current_file)

    ambiguous_source_label :: proc(name: string, is_struct: bool) -> string {
        conflicts := g_project_symbol_index.imported_struct_conflicts[name] if is_struct else g_project_symbol_index.imported_enum_conflicts[name]
        builder := strings.builder_make(context.temp_allocator)
        strings.write_string(&builder, "ambiguous: ")
        for import_alias, i in conflicts {
            if i > 0 { strings.write_string(&builder, ", ") }
            import_path := g_project_symbol_index.import_aliases[import_alias]
            strings.write_string(&builder, import_path if import_path != "" else import_alias)
        }
        return strings.to_string(builder)
    }

    unambiguous_source_label :: proc(name: string, is_struct: bool) -> string {
        import_alias := g_project_symbol_index.imported_struct_origin_alias[name] if is_struct else g_project_symbol_index.imported_enum_origin_alias[name]
        import_path  := g_project_symbol_index.import_aliases[import_alias]
        return import_path if import_path != "" else import_alias
    }

    entries := make([dynamic]Completion_Entry, context.temp_allocator)

    if scope, has_scope := local_scope.?; has_scope {
        collect_local_scope_entries(&entries, scope, prefix)
    }

    collect :: proc(entries: ^[dynamic]Completion_Entry, name: string, menu_origin_label: string, detail: string, kind_rank: int, priority: int) {
        append(entries, Completion_Entry{name = name, menu_origin_label = menu_origin_label, detail = detail, kind_rank = kind_rank, priority = priority})
    }

    for name, defn in g_project_symbol_index.project_structs {
        if !strings.has_prefix(name, prefix) { continue }
        field_types := make([dynamic]string, context.temp_allocator)
        for field in defn.fields { append(&field_types, field.type) }
        priority := 1 if g_symbol_source_filename_by_name[name] == current_filename else 2
        collect(&entries, name, g_symbol_source_filename_by_name[name], strings.join(field_types[:], " "), 1, priority)
    }
    for name, defn in g_project_symbol_index.project_enums {
        if !strings.has_prefix(name, prefix) { continue }
        priority := 1 if g_symbol_source_filename_by_name[name] == current_filename else 2
        collect(&entries, name, g_symbol_source_filename_by_name[name], strings.join(defn.values[:], " "), 2, priority)
    }
    for name, defn in g_project_symbol_index.project_unions {
        if !strings.has_prefix(name, prefix) { continue }
        priority := 1 if g_symbol_source_filename_by_name[name] == current_filename else 2
        collect(&entries, name, g_symbol_source_filename_by_name[name], strings.join(defn.variants[:], " "), 3, priority)
    }
    for name, defn in g_project_symbol_index.project_procs {
        if !strings.has_prefix(name, prefix) { continue }
        priority := 1 if g_symbol_source_filename_by_name[name] == current_filename else 2
        collect(&entries, name, g_symbol_source_filename_by_name[name], proc_signature_summary(defn), 4, priority)
    }
    for name, type_name in g_project_symbol_index.project_variables {
        if !strings.has_prefix(name, prefix) { continue }
        priority := 1 if g_symbol_source_filename_by_name[name] == current_filename else 2
        collect(&entries, name, g_symbol_source_filename_by_name[name], type_name, 5, priority)
    }
    for name in g_project_symbol_index.all_imported_structs {
        if !strings.has_prefix(name, prefix) || name in g_project_symbol_index.project_structs { continue }
        defn   := g_project_symbol_index.all_imported_structs[name]
        field_types := make([dynamic]string, context.temp_allocator)
        for field in defn.fields { append(&field_types, field.type) }
        menu_origin_label := ambiguous_source_label(name, true) if name in g_project_symbol_index.imported_struct_conflicts else unambiguous_source_label(name, true)
        collect(&entries, name, menu_origin_label, strings.join(field_types[:], " "), 1, 2)
    }
    for name in g_project_symbol_index.all_imported_enums {
        if !strings.has_prefix(name, prefix) || name in g_project_symbol_index.project_enums { continue }
        defn   := g_project_symbol_index.all_imported_enums[name]
        menu_origin_label := ambiguous_source_label(name, false) if name in g_project_symbol_index.imported_enum_conflicts else unambiguous_source_label(name, false)
        collect(&entries, name, menu_origin_label, strings.join(defn.values[:], " "), 2, 2)
    }

    slice.sort_by(entries[:], proc(a, b: Completion_Entry) -> bool {
        if a.priority          != b.priority          { return a.priority < b.priority }
        if a.priority == 0 && a.declaration_order != b.declaration_order { return a.declaration_order < b.declaration_order }
        if a.menu_origin_label != b.menu_origin_label { return a.menu_origin_label < b.menu_origin_label }
        if a.kind_rank         != b.kind_rank         { return a.kind_rank < b.kind_rank }
        return a.name < b.name
    })

    builder := strings.builder_make(context.temp_allocator)
    for entry in entries {
        strings.write_string(&builder, entry.name)
        strings.write_byte(&builder, '\t')
        if entry.menu_origin_label != "" { strings.write_string(&builder, entry.menu_origin_label); strings.write_string(&builder, " │ ") }
        strings.write_string(&builder, entry.detail)
        strings.write_byte(&builder, '\n')
    }
    return strings.trim_right(strings.to_string(builder), "\n")
}

completions_for_type_members :: proc(type_name: string, prefix: string, local_scope: Maybe(Local_Scope) = nil) -> string {
    write_struct_fields :: proc(builder: ^strings.Builder, defn: Struct_Definition, prefix: string) {
        for field in defn.fields {
            if strings.has_prefix(field.name, prefix) { strings.write_string(builder, field.name); strings.write_byte(builder, '\t'); strings.write_string(builder, field.type); strings.write_byte(builder, '\n') }
        }
    }
    write_enum_values :: proc(builder: ^strings.Builder, defn: Enum_Definition, prefix: string, type_name: string) {
        for value in defn.values {
            if strings.has_prefix(value, prefix) { strings.write_string(builder, value); strings.write_byte(builder, '\t'); strings.write_string(builder, type_name); strings.write_byte(builder, '\n') }
        }
    }

    lookup := strings.trim_prefix(type_name, "^")

    if scope, has_scope := local_scope.?; has_scope {
        if defn, _, found := local_scope_find_struct(scope, lookup); found {
            builder := strings.builder_make()
            write_struct_fields(&builder, defn, prefix)
            return strings.trim_right(strings.to_string(builder), "\n")
        }
        if defn, _, found := local_scope_find_enum(scope, lookup); found {
            builder := strings.builder_make()
            write_enum_values(&builder, defn, prefix, type_name)
            return strings.trim_right(strings.to_string(builder), "\n")
        }
    }

    if import_alias, member_name, has_dot := split_qualified_name_at_dot(lookup); has_dot {
        if pkg := imported_package_by_import_alias(import_alias); pkg != nil {
            builder := strings.builder_make()
            if defn, ok := pkg.structs[member_name]; ok { write_struct_fields(&builder, defn, prefix) } else
            if defn, ok := pkg.enums[member_name];   ok { write_enum_values(&builder, defn, prefix, type_name) }
            return strings.trim_right(strings.to_string(builder), "\n")
        }
    }

    builder := strings.builder_make()
    if defn, ok := g_project_symbol_index.project_structs[lookup];       ok { write_struct_fields(&builder, defn, prefix)          } else
    if defn, ok := g_project_symbol_index.project_enums[lookup];         ok { write_enum_values(&builder, defn, prefix, type_name) } else
    if defn, ok := g_project_symbol_index.all_imported_structs[lookup];  ok { write_struct_fields(&builder, defn, prefix)          } else
    if defn, ok := g_project_symbol_index.all_imported_enums[lookup];    ok { write_enum_values(&builder, defn, prefix, type_name) }
    return strings.trim_right(strings.to_string(builder), "\n")
}

find_field_type_within_type_name :: proc(type_name: string, field_name: string, local_scope: Maybe(Local_Scope) = nil) -> (string, bool) {
    lookup := strings.trim_prefix(type_name, "^")

    if scope, has_scope := local_scope.?; has_scope {
        if defn, _, found := local_scope_find_struct(scope, lookup); found {
            for field in defn.fields { if field.name == field_name { return field.type, true } }
        }
    }

    if import_alias, member_name, has_dot := split_qualified_name_at_dot(lookup); has_dot {
        if pkg := imported_package_by_import_alias(import_alias); pkg != nil {
            if defn, ok := pkg.structs[member_name]; ok {
                for field in defn.fields { if field.name == field_name { return field.type, true } }
            }
        }
    }

    if defn, ok := g_project_symbol_index.project_structs[lookup]; ok {
        for field in defn.fields { if field.name == field_name { return field.type, true } }
    }
    if defn, ok := g_project_symbol_index.all_imported_structs[lookup]; ok {
        for field in defn.fields { if field.name == field_name { return field.type, true } }
    }
    return "", false
}

resolve_dot_chain_to_final_type :: proc(dot_chain: string, local_scope: Maybe(Local_Scope) = nil, remaining_hops := 8) -> string {
    chain_segments := strings.split(dot_chain, ".", context.temp_allocator)
    defer delete(chain_segments, context.temp_allocator)
    if len(chain_segments) == 0 || chain_segments[0] == "" { return "" }

    current_type  := ""
    segment_start := 1

    if _, is_import_alias := g_project_symbol_index.imported_package_dirs[chain_segments[0]]; is_import_alias {
        if len(chain_segments) == 1 { return "" }
        import_alias := chain_segments[0]; type_name := chain_segments[1]
        if pkg := imported_package_by_import_alias(import_alias); pkg != nil {
            if _, ok := pkg.structs[type_name]; ok {
                current_type  = strings.concatenate({import_alias, ".", type_name}, context.temp_allocator)
                segment_start = 2
            } else if _, ok := pkg.enums[type_name]; ok {
                current_type  = strings.concatenate({import_alias, ".", type_name}, context.temp_allocator)
                segment_start = len(chain_segments)
            }
        }
        if current_type == "" { current_type = resolve_dot_chain_head_to_type_name(chain_segments[0], local_scope, remaining_hops); segment_start = 1 }
    } else {
        current_type = resolve_dot_chain_head_to_type_name(chain_segments[0], local_scope, remaining_hops)
    }

    if current_type == "" { return "" }

    for i := segment_start; i < len(chain_segments); i += 1 {
        field_name := chain_segments[i]
        if field_name == "" { return "" }

        lookup_type := strings.trim_prefix(current_type, "^")
        struct_defn, found := g_project_symbol_index.project_structs[lookup_type]
        if !found {
            if import_alias, member_name, has_dot := split_qualified_name_at_dot(lookup_type); has_dot {
                if pkg := imported_package_by_import_alias(import_alias); pkg != nil { struct_defn, found = pkg.structs[member_name] }
            }
            if !found { struct_defn, found = g_project_symbol_index.all_imported_structs[lookup_type] }
            if !found { return "" }
        }

        next_type := ""
        for field in struct_defn.fields { if field.name == field_name { next_type = field.type; break } }
        if next_type == "" { return "" }
        current_type = next_type
    }

    return current_type
}

completions_for_dot_chain :: proc(prefix: string, dot_chain: string, current_file: string, enclosing_procedure_source: string = "", cursor_line_offset: int = -1) -> string {
    local_scope: Maybe(Local_Scope)
    if scope, ok := parse_local_scope_from_enclosing_procedure_source(enclosing_procedure_source, cursor_line_offset); ok { local_scope = scope }

    if dot_chain == "" { return completions_for_unqualified_prefix(prefix, current_file, local_scope) }

    if _, is_import_alias := g_project_symbol_index.imported_package_dirs[dot_chain]; is_import_alias && strings.index_byte(dot_chain, '.') == -1 {
        return completions_for_import_alias(dot_chain, prefix)
    }

    current_type := resolve_dot_chain_to_final_type(dot_chain, local_scope)
    if current_type == "" { return "" }

    return completions_for_type_members(current_type, prefix, local_scope)
}

Local_Scope_Block :: struct {
    declarations      : Parsed_File_Declarations,
    line_offset       : int,
    parameters        : [dynamic]Named_Parameter,
}

Local_Scope :: struct {
    procedure_name : string,
    parameters     : [dynamic]Named_Parameter,
    blocks         : [dynamic]Local_Scope_Block,
    procs          : map[string]Proc_Definition,
}

parse_named_proc_header :: proc(header_source: string, start_line: int = 1) -> (procedure_name: string, parameters: [dynamic]Named_Parameter, header_end: int, ok: bool) {
    header_lexer      := lexer_from_source(header_source)
    header_lexer.line  = start_line
    for {
        token := lexer_consume_token(&header_lexer)
        if token.kind == .EOF { return "", nil, 0, false }
        if token.kind == .Identifier { procedure_name = token.text }
        if token.kind == .Double_Colon { break }
    }
    if lexer_peek_token(&header_lexer).kind != .Identifier || lexer_peek_token(&header_lexer).text != "proc" { return "", nil, 0, false }
    lexer_consume_token(&header_lexer)

    if lexer_peek_token(&header_lexer).kind == .String_Literal { lexer_consume_token(&header_lexer) }
    open_paren := lexer_consume_token(&header_lexer)
    if open_paren.kind != .Other || open_paren.text != "(" { return "", nil, 0, false }
    parameters = parse_named_parameter_list(&header_lexer)
    if lexer_peek_token(&header_lexer).kind == .Other && lexer_peek_token(&header_lexer).text == ")" { lexer_consume_token(&header_lexer) }
    header_end = header_lexer.pos

    if lexer_peek_token(&header_lexer).kind == .Other && lexer_peek_token(&header_lexer).text == "-" {
        lexer_consume_token(&header_lexer)
        if lexer_peek_token(&header_lexer).kind == .Other && lexer_peek_token(&header_lexer).text == ">" { lexer_consume_token(&header_lexer) }
        if lexer_peek_token(&header_lexer).kind == .Other && lexer_peek_token(&header_lexer).text == "(" {
            lexer_consume_token(&header_lexer)
            for named_return in parse_named_parameter_list(&header_lexer) { append(&parameters, named_return) }
            if lexer_peek_token(&header_lexer).kind == .Other && lexer_peek_token(&header_lexer).text == ")" { lexer_consume_token(&header_lexer); header_end = header_lexer.pos }
        } else {
            arrow_line := lexer_peek_token(&header_lexer).line
            for {
                peeked := lexer_peek_token(&header_lexer)
                if peeked.kind == .EOF || peeked.kind == .Open_Brace || peeked.line > arrow_line { break }
                if peeked.kind == .Hash || (peeked.kind == .Other && peeked.text == "-") { break }
                lexer_consume_token(&header_lexer)
                header_end = header_lexer.pos
            }
        }
    }
    return procedure_name, parameters, header_end, true
}

parse_local_scope_from_enclosing_procedure_source :: proc(enclosing_procedure_source: string, cursor_line_offset: int) -> (scope: Local_Scope, ok: bool) {
    procedure_name, parameters, header_end, header_ok := parse_named_proc_header(enclosing_procedure_source)
    if !header_ok { return {}, false }
    scope.procedure_name = procedure_name
    scope.parameters     = parameters

    body_start := -1
    remaining_lexer := lexer_from_source(enclosing_procedure_source[header_end:])
    for {
        peeked := lexer_peek_token(&remaining_lexer)
        if peeked.kind == .EOF { return {}, false }
        if peeked.kind == .Open_Brace { lexer_consume_token(&remaining_lexer); body_start = header_end + remaining_lexer.pos; break }
        lexer_consume_token(&remaining_lexer)
    }

    proc_end_line, _ := find_matching_close_brace_line(enclosing_procedure_source[body_start:], start_line = 1)
    if proc_end_line == -1 { return {}, false }
    if cursor_line_offset < 0 || cursor_line_offset >= proc_end_line { return {}, false }

    cursor_line          := cursor_line_offset + 1
    enclosing_blocks     := find_innermost_enclosing_blocks(enclosing_procedure_source[body_start:], block_start_line = 1, cursor_line = cursor_line)
    scope.blocks          = make([dynamic]Local_Scope_Block, len(enclosing_blocks), context.temp_allocator)
    accumulated_procs    := make(map[string]Proc_Definition, context.temp_allocator)
    for i := len(enclosing_blocks)-1; i >= 0; i -= 1 {
        block       := enclosing_blocks[i]
        declarations := parse_file_declarations("", block.source, accumulated_procs)
        for name, defn in declarations.project_procs {
            if name in accumulated_procs { continue }
            absolute_defn := defn
            absolute_defn.location.line += block.line - 1
            accumulated_procs[name] = absolute_defn
        }
        scope.blocks[i] = Local_Scope_Block{declarations = declarations, line_offset = block.line - 1, parameters = block.parameters}
    }
    scope.procs = accumulated_procs
    return scope, true
}

find_matching_close_brace_line :: proc(body_source: string, start_line: int) -> (close_line: int, close_offset: int) {
    lexer       := lexer_from_source(body_source)
    lexer.line   = start_line
    brace_depth := 1
    for {
        token := lexer_consume_token(&lexer)
        if token.kind == .EOF { return -1, -1 }
        if token.kind == .Open_Brace  { brace_depth += 1 }
        if token.kind == .Close_Brace {
            brace_depth -= 1
            if brace_depth == 0 { return token.line, lexer.pos }
        }
    }
}

Source_Block :: struct {
    source     : string,
    line       : int,
    parameters : [dynamic]Named_Parameter,
}

find_innermost_enclosing_blocks :: proc(block_source: string, block_start_line: int, cursor_line: int) -> [dynamic]Source_Block {
    blocks := make([dynamic]Source_Block, context.temp_allocator)
    append(&blocks, Source_Block{source = block_source, line = block_start_line})

    current_source := block_source
    current_line   := block_start_line
    for {
        lexer                  := lexer_from_source(current_source)
        lexer.line              = current_line
        brace_depth            := 0
        found_child            := false
        statement_start_offset := 0
        child_source: string
        child_line:       int
        child_parameters: [dynamic]Named_Parameter

        for {
            token := lexer_consume_token(&lexer)
            if token.kind == .EOF { break }
            if token.kind == .Open_Brace {
                brace_depth += 1
                if brace_depth != 1 { continue }
                open_line   := token.line
                open_offset := lexer.pos
                close_line, close_offset := find_matching_close_brace_line(current_source[open_offset:], start_line = open_line)
                if close_line == -1 { break }
                if cursor_line >= open_line && cursor_line <= close_line {
                    child_source = current_source[open_offset : open_offset + close_offset - 1]
                    child_line   = open_line
                    header_input       := current_source[statement_start_offset:open_offset]
                    header_start_line  := open_line - strings.count(header_input, "\n")
                    if _, header_parameters, header_end, header_ok := parse_named_proc_header(header_input, header_start_line); header_ok {
                        gap := current_source[statement_start_offset + header_end : open_offset - 1]
                        if strings.trim_space(gap) == "" { child_parameters = header_parameters }
                    }
                    found_child  = true
                    break
                }
                statement_start_offset = open_offset + close_offset
            }
            if token.kind == .Close_Brace && brace_depth > 0 { brace_depth -= 1 }
        }

        if !found_child { break }
        append(&blocks, Source_Block{source = child_source, line = child_line, parameters = child_parameters})
        current_source = child_source
        current_line   = child_line
    }

    slice.reverse(blocks[:])
    return blocks
}

MAX_FRAME_BYTES :: 4 * 1024 * 1024

read_exactly_n_bytes :: proc(fd: posix.FD, buffer: []u8) -> bool {
    total := 0
    for total < len(buffer) {
        bytes_read := posix.read(fd, &buffer[total], uint(len(buffer))-uint(total))
        if bytes_read <= 0 { return false }
        total += bytes_read
    }
    return true
}

write_all_bytes :: proc(fd: posix.FD, buffer: []u8) -> bool {
    total := 0
    for total < len(buffer) {
        bytes_written := posix.write(fd, &buffer[total], uint(len(buffer))-uint(total))
        if bytes_written <= 0 { return false }
        total += bytes_written
    }
    return true
}

INLINE_FRAME_CAP :: 4096

write_uint32_as_hex8 :: proc(buffer: []u8, value: int) {
    digits := "0123456789abcdef"
    v := u32(value)
    for i := 7; i >= 0; i -= 1 { buffer[i] = digits[v & 0xf]; v >>= 4 }
}

write_length_prefixed_frame :: proc(fd: posix.FD, message: string) -> bool {
    body       := transmute([]u8)message
    byte_count := len(body)
    if byte_count+8 <= INLINE_FRAME_CAP {
        buffer: [INLINE_FRAME_CAP]u8
        write_uint32_as_hex8(buffer[:8], byte_count)
        copy(buffer[8:], body)
        return write_all_bytes(fd, buffer[:8+byte_count])
    }
    length_header: [8]u8
    write_uint32_as_hex8(length_header[:], byte_count)
    return write_all_bytes(fd, length_header[:]) && write_all_bytes(fd, body)
}

read_length_prefixed_frame :: proc(fd: posix.FD, allocator := context.allocator) -> (string, bool) {
    length_header: [8]u8
    if !read_exactly_n_bytes(fd, length_header[:]) { return "", false }
    frame_length, parse_ok := strconv.parse_int(string(length_header[:]), 16)
    if !parse_ok                   { return "", false }
    if frame_length > MAX_FRAME_BYTES { return "", false }
    if frame_length == 0              { return "", true  }
    body := make([]u8, frame_length, allocator)
    if !read_exactly_n_bytes(fd, body) { delete(body, allocator); return "", false }
    return string(body), true
}

unix_socket_path_for_project_root :: proc(project_root: string, allocator := context.allocator) -> string {
    path_hash := xxhash.XXH64(transmute([]u8)project_root, 0)
    return fmt.aprintf("/tmp/gjallarhorn_%016x.sock", path_hash, allocator = allocator)
}

unix_sockaddr_from_path :: proc(socket_path: string) -> posix.sockaddr_un {
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
    ignore_action: posix.sigaction_t
    ignore_action.sa_handler = transmute(proc "c" (posix.Signal))posix.SIG_IGN
    posix.sigaction(.SIGPIPE, &ignore_action, nil)

    terminate_action: posix.sigaction_t
    terminate_action.sa_handler = signal_handler
    posix.sigaction(.SIGTERM, &terminate_action, nil)
    posix.sigaction(.SIGINT,  &terminate_action, nil)
}

run_daemon :: proc(initial_file: string) {
    install_signal_handlers()

    source_dir   := path_parent_dir(initial_file);                  defer delete(source_dir)
    project_root := find_project_root(source_dir);                  defer delete(project_root)
    socket_path  := unix_socket_path_for_project_root(project_root); defer delete(socket_path)

    socket_path_c   := strings.clone_to_cstring(socket_path)
    g_socket_path_c  = socket_path_c
    posix.unlink(socket_path_c)

    rebuild_symbol_index(project_root)

    server_fd := posix.socket(.UNIX, .STREAM)
    if int(server_fd) < 0 { fmt.eprintfln("socket() failed: %v", posix.errno()); os.exit(1) }

    addr := unix_sockaddr_from_path(socket_path)
    if posix.bind(server_fd, cast(^posix.sockaddr)&addr, posix.socklen_t(size_of(addr))) == .FAIL {
        fmt.eprintfln("bind() failed: %v", posix.errno()); os.exit(1)
    }
    if posix.listen(server_fd, 8) == .FAIL {
        fmt.eprintfln("listen() failed: %v", posix.errno()); os.exit(1)
    }

    fmt.eprintfln("socket:%s", socket_path)

    when DEV {
        log_path := fmt.aprintf("/tmp/gjallarhorn_%016x.log", xxhash.XXH64(transmute([]u8)project_root, 0))
        defer delete(log_path)
        log_file, log_err := os.open(log_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
        if log_err == nil { os.stderr = log_file }
    }

    accept_client_connections(server_fd)
}

accept_client_connections :: proc(server_fd: posix.FD) {
    for {
        client_fd := posix.accept(server_fd, nil, nil)
        if int(client_fd) < 0 {
            if posix.errno() == .EINTR { continue }
            fmt.eprintfln("accept() failed: %v", posix.errno())
            continue
        }
        serve_client_requests(client_fd)
        posix.close(client_fd)
    }
}

serve_client_requests :: proc(client_fd: posix.FD) {
    for {
        free_all(context.temp_allocator)

        command, read_ok := read_length_prefixed_frame(client_fd, context.temp_allocator)
        if !read_ok { break }

        switch command {
        case "complete":
            current_file, file_ok               := read_length_prefixed_frame(client_fd, context.temp_allocator); if !file_ok    { return }
            prefix,       prefix_ok             := read_length_prefixed_frame(client_fd, context.temp_allocator); if !prefix_ok  { return }
            dot_chain,    chain_ok               := read_length_prefixed_frame(client_fd, context.temp_allocator); if !chain_ok   { return }
            enclosing_procedure_source, proc_ok := read_length_prefixed_frame(client_fd, context.temp_allocator); if !proc_ok    { return }
            cursor_line_offset_text, offset_ok  := read_length_prefixed_frame(client_fd, context.temp_allocator); if !offset_ok  { return }
            cursor_line_offset, _                := strconv.parse_int(cursor_line_offset_text)

            context.allocator = context.temp_allocator
            when DEV { timer_start := time.now() }
            result := completions_for_dot_chain(prefix, dot_chain, current_file, enclosing_procedure_source, cursor_line_offset)
            when DEV { fmt.eprintfln("complete: elapsed=%v bytes=%d", time.since(timer_start), len(result)) }
            write_length_prefixed_frame(client_fd, result)

        case "complete_unsaved":
            file_path,     file_ok               := read_length_prefixed_frame(client_fd, context.temp_allocator); if !file_ok   { return }
            prefix,        prefix_ok             := read_length_prefixed_frame(client_fd, context.temp_allocator); if !prefix_ok { return }
            dot_chain,     chain_ok               := read_length_prefixed_frame(client_fd, context.temp_allocator); if !chain_ok  { return }
            enclosing_procedure_source, proc_ok  := read_length_prefixed_frame(client_fd, context.temp_allocator); if !proc_ok   { return }
            cursor_line_offset_text, offset_ok   := read_length_prefixed_frame(client_fd, context.temp_allocator); if !offset_ok { return }
            unsaved_source, buf_ok               := read_length_prefixed_frame(client_fd, context.temp_allocator); if !buf_ok    { return }
            cursor_line_offset, _                := strconv.parse_int(cursor_line_offset_text)

            context.allocator = g_persistent_allocator
            reindex_file_from_unsaved_buffer(file_path, unsaved_source)
            context.allocator = context.temp_allocator
            result := completions_for_dot_chain(prefix, dot_chain, file_path, enclosing_procedure_source, cursor_line_offset)
            write_length_prefixed_frame(client_fd, result)

        case "hover":
            symbol_name,               symbol_ok    := read_length_prefixed_frame(client_fd, context.temp_allocator); if !symbol_ok    { return }
            dot_chain,                 chain_ok     := read_length_prefixed_frame(client_fd, context.temp_allocator); if !chain_ok      { return }
            enclosing_procedure_source, procedure_ok := read_length_prefixed_frame(client_fd, context.temp_allocator); if !procedure_ok { return }
            cursor_line_offset_text,   offset_ok     := read_length_prefixed_frame(client_fd, context.temp_allocator); if !offset_ok    { return }
            cursor_line_offset, _                    := strconv.parse_int(cursor_line_offset_text)

            context.allocator = context.temp_allocator
            result := hover_text_for_symbol(symbol_name, dot_chain, enclosing_procedure_source, cursor_line_offset)
            write_length_prefixed_frame(client_fd, result)

        case "goto":
            symbol_name,               symbol_ok      := read_length_prefixed_frame(client_fd, context.temp_allocator); if !symbol_ok      { return }
            dot_chain,                 chain_ok       := read_length_prefixed_frame(client_fd, context.temp_allocator); if !chain_ok        { return }
            enclosing_procedure_source, procedure_ok   := read_length_prefixed_frame(client_fd, context.temp_allocator); if !procedure_ok   { return }
            current_file,              file_ok         := read_length_prefixed_frame(client_fd, context.temp_allocator); if !file_ok         { return }
            cursor_line_offset_text,   offset_ok        := read_length_prefixed_frame(client_fd, context.temp_allocator); if !offset_ok      { return }
            procedure_start_line_text, start_line_ok    := read_length_prefixed_frame(client_fd, context.temp_allocator); if !start_line_ok   { return }
            cursor_line_offset, _                       := strconv.parse_int(cursor_line_offset_text)
            procedure_start_line, _                     := strconv.parse_int(procedure_start_line_text)

            context.allocator = context.temp_allocator
            file, line, col, found := find_symbol_definition_location(symbol_name, dot_chain, enclosing_procedure_source, current_file, cursor_line_offset, procedure_start_line)
            if found {
                write_length_prefixed_frame(client_fd, fmt.tprintf("%s\x00%d\x00%d", file, line, col))
            } else {
                write_length_prefixed_frame(client_fd, "")
            }

        case "index":
            file_path, file_ok := read_length_prefixed_frame(client_fd, context.temp_allocator); if !file_ok { return }
            context.allocator = g_persistent_allocator
            reindex_file_from_disk(file_path)
            write_length_prefixed_frame(client_fd, "")

        case "index_unsaved":
            file_path,     file_ok := read_length_prefixed_frame(client_fd, context.temp_allocator); if !file_ok { return }
            unsaved_source, buf_ok := read_length_prefixed_frame(client_fd, context.temp_allocator); if !buf_ok  { return }
            context.allocator = g_persistent_allocator
            reindex_file_from_unsaved_buffer(file_path, unsaved_source)
            write_length_prefixed_frame(client_fd, "")

        case "indexes_directory":
            file_path, file_ok := read_length_prefixed_frame(client_fd, context.temp_allocator); if !file_ok { return }
            file_directory := path_parent_dir(file_path, context.temp_allocator)
            write_length_prefixed_frame(client_fd, "1" if file_directory in g_imported_package_cache else "")

        case:
            fmt.eprintfln("unknown command: %q", command)
            write_length_prefixed_frame(client_fd, "")
            return
        }
    }
}

main :: proc() {
    daemon_mode  := false
    initial_file := ""

    for i := 1; i < len(os.args); i += 1 {
        arg := os.args[i]
        if arg == "--daemon" {
            daemon_mode = true
            if i+1 < len(os.args) {
                initial_file = os.args[i+1]
                i += 1
            }
        } else if arg == "--indent" {
            if i+1 < len(os.args) {
                g_indent_spaces = os.args[i+1]
                i += 1
            }
        } else {
            g_project_root_markers = os.args[i:]
            break
        }
    }

    if g_indent_spaces == "" { g_indent_spaces = "    " }

    if !daemon_mode || initial_file == "" {
        fmt.eprintfln("usage: gjallarhorn --daemon <absolute_filepath> --indent <spaces> [root_marker ...]")
        os.exit(1)
    }

    run_daemon(initial_file)
}
