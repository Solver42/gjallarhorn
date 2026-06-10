package gjallarhorn

import "core:crypto/legacy/md5"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

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

Index :: struct {
    structs   : map[string]Struct_Entry,
    enums     : map[string]Enum_Entry,
    variables : map[string]string,   // variable name -> type name
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
}

Token_Kind :: enum {
    EOF,
    Ident,
    Double_Colon,   // ::
    Open_Brace,     // {
    Close_Brace,    // }
    Comma,          // ,
    Colon,          // :
    Other,
}

Token :: struct {
    kind : Token_Kind,
    text : string,   // slice into the original source — no allocation
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

    // :: vs :
    if c == ':' {
        if l.pos + 1 < len(l.src) && l.src[l.pos + 1] == ':' {
            l.pos += 2
            return Token{kind = .Double_Colon, text = "::"}
        }
        l.pos += 1
        return Token{kind = .Colon, text = ":"}
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

parse_source :: proc(src: string) -> Index {
    idx := Index{
        structs   = make(map[string]Struct_Entry),
        enums     = make(map[string]Enum_Entry),
        variables = make(map[string]string),
    }
    l := lexer_make(src)

    for {
        tok := lexer_next(&l)
        if tok.kind == .EOF { break }
        if tok.kind != .Ident { continue }

        name := tok.text

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
            }
            continue
        }

        if next.kind == .Colon {
            lexer_next(&l) // consume :
            type_tok := lexer_peek(&l)
            if type_tok.kind == .Ident {
                lexer_next(&l)
                idx.variables[strings.clone(name)] = strings.clone(type_tok.text)
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
            type_str := strings.join(type_parts[:], " ")
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

g_index: Index

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
        return ""
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

    current_type := resolve_to_type(segments[0], buffer)
    if current_type == "" { return "" }

    for i := 1; i < len(segments); i += 1 {
        field_name := segments[i]
        if field_name == "" { return "" }

        se, ok := g_index.structs[current_type]
        if !ok { return "" }

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
    if type_name, ok := g_index.variables[name]; ok {
        return type_name
    }
    if type_name, ok := resolve_local_type(buffer, name); ok {
        return type_name
    }
    return ""
}

resolve_local_type :: proc(buffer: string, var_name: string) -> (string, bool) {
    i := len(buffer)
    for i > 0 {
        line_end := i
        i -= 1
        for i > 0 && buffer[i - 1] != '\n' { i -= 1 }
        line := strings.trim_space(buffer[i:line_end])

        if !strings.has_prefix(line, var_name) { continue }
        rest := strings.trim_left(line[len(var_name):], " \t")

        if len(rest) > 0 && rest[0] == ':' && (len(rest) == 1 || rest[1] != '=') {
            after_colon := strings.trim_left(rest[1:], " \t")
            end := 0
            for end < len(after_colon) {
                b := after_colon[end]
                if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') {
                    end += 1
                } else { break }
            }
            if end > 0 { return after_colon[:end], true }
        }

        if strings.has_prefix(rest, ":=") {
            after_assign := strings.trim_left(rest[2:], " \t")
            end := 0
            for end < len(after_assign) {
                b := after_assign[end]
                if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') {
                    end += 1
                } else { break }
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

completions_for_type :: proc(type_name: string, prefix: string, buffer: string) -> string {
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
    return string(body), true
}

SOCKET_DIR    :: "/tmp"
SOCKET_PREFIX :: "gjallarhorn_"

socket_path_for_file :: proc(filepath: string, allocator := context.allocator) -> string {
    ctx: md5.Context
    md5.init(&ctx)
    md5.update(&ctx, transmute([]u8)filepath)
    digest: [md5.DIGEST_SIZE]u8
    md5.final(&ctx, digest[:])

    hash_hex := hex.encode(digest[:], allocator)
    defer delete(hash_hex, allocator)

    return strings.join({SOCKET_DIR, "/", SOCKET_PREFIX, string(hash_hex), ".sock"}, "", allocator)
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
    sock_path := socket_path_for_file(filepath)
    defer delete(sock_path)

    sock_path_c := strings.clone_to_cstring(sock_path)
    defer delete(sock_path_c)
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

    pid := posix.fork()
    if int(pid) < 0 {
        fmt.eprintfln("gjallarhorn: fork() failed: %v", posix.errno())
        os.exit(1)
    }
    if pid != 0 {
        fmt.println(sock_path)
        os.exit(0)
    }

    posix.setsid()

    if src, err := os.read_entire_file_from_path(filepath, context.allocator); err == nil {
        new_index := parse_source(string(src))
        index_destroy(&g_index)
        g_index = new_index
        delete(src, context.allocator)
    }

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
    if !ok { return }
    defer delete(cmd)

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
        if !path_ok { return }
        defer delete(filepath)
        if src, err := os.read_entire_file_from_path(filepath, context.allocator); err == nil {
            new_index := parse_source(string(src))
            index_destroy(&g_index)
            g_index = new_index
            delete(src, context.allocator)
        }
        frame_write(client_fd, "") // acknowledge

    case:
        frame_write(client_fd, "")
    }
}

client_connect :: proc(filepath: string) -> (posix.FD, bool) {
    sock_path := socket_path_for_file(filepath)
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
    if !ok { os.exit(1) }
    defer posix.close(fd)

    frame_write(fd, "comp")
    frame_write(fd, buffer)

    response, resp_ok := frame_read(fd)
    if !resp_ok {
        fmt.eprintfln("gjallarhorn: no response from daemon")
        os.exit(1)
    }
    defer delete(response)

    if len(response) > 0 {
        fmt.print(response)
    }
}

client_index :: proc(filepath: string) {
    fd, ok := client_connect(filepath)
    if !ok { os.exit(1) }
    defer posix.close(fd)

    frame_write(fd, "index")
    frame_write(fd, filepath)

    response, _ := frame_read(fd)
    delete(response)
}

main :: proc() {
    if len(os.args) < 3 {
        usage()
        os.exit(1)
    }

    switch os.args[1] {
    case "--start":
        daemon_start(os.args[2])

    case "--comp":
        if len(os.args) < 4 { usage(); os.exit(1) }
        client_comp(os.args[2], os.args[3])

    case "--index":
        client_index(os.args[2])

    case:
        usage()
        os.exit(1)
    }
}

usage :: proc() {
    fmt.eprintln("gjallarhorn — Odin completion daemon")
    fmt.eprintln("  gjallarhorn --start <absolute_filepath>")
    fmt.eprintln("  gjallarhorn --comp  <absolute_filepath> <buffer_until_cursor>")
    fmt.eprintln("  gjallarhorn --index <absolute_filepath>")
}
