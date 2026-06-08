package gjallarhorn

import "core:crypto/legacy/md5"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Index — structs and enums parsed from the watched file
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Lexer — produces a flat stream of tokens from Odin source text
// ---------------------------------------------------------------------------

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

// Skip whitespace and line/block comments.
lexer_skip_whitespace :: proc(l: ^Lexer) {
    for l.pos < len(l.src) {
        c := l.src[l.pos]
        if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
            l.pos += 1
            continue
        }
        // Line comment: //
        if c == '/' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '/' {
            for l.pos < len(l.src) && l.src[l.pos] != '\n' { l.pos += 1 }
            continue
        }
        // Block comment: /* ... */
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

    // Identifier or keyword: [a-zA-Z_][a-zA-Z0-9_]*
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

    // Skip any other byte (operators, literals, …)
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

// ---------------------------------------------------------------------------
// Parser — walks the token stream and builds an Index
// ---------------------------------------------------------------------------

// Parse the entire source file into a fresh Index.
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

        // <Name> :: struct { ... }  or  <Name> :: enum ... { ... }
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

        // <name> : TypeName   (global variable declaration, single colon)
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

// Parse everything between the { } of a struct body.
// Odin struct fields look like:   field_name : Type,
// We collect field names and their type text.
parse_struct_body :: proc(l: ^Lexer) -> Struct_Entry {
    entry := Struct_Entry{fields = make([dynamic]Field_Entry)}

    // Skip any tokens before the opening brace (e.g. `#packed`, `using`, …)
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
            // Only at top depth — nested braces are sub-structs / using blocks.
            if depth != 1 { continue }
            field_name := tok.text
            // Expect a colon next (field : Type).  Skip if pattern doesn't match.
            if lexer_peek(l).kind != .Colon { continue }
            lexer_next(l) // consume :
            // Collect type tokens until comma, close-brace, or another field pattern.
            type_parts := make([dynamic]string, context.temp_allocator)
            for {
                pk := lexer_peek(l)
                if pk.kind == .EOF || pk.kind == .Comma || pk.kind == .Close_Brace { break }
                // Stop if we see another "ident :" — that's the next field.
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
            // ignore
        }
    }
    return entry
}

// Parse everything between the { } of an enum body.
// Odin enum values are simply identifiers separated by commas.
parse_enum_body :: proc(l: ^Lexer) -> Enum_Entry {
    entry := Enum_Entry{values = make([dynamic]string)}

    // Skip optional base type and directives before the opening brace.
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
            // Skip optional  = <expr>  assignment before the comma.
            for {
                pk := lexer_peek(l)
                if pk.kind == .EOF || pk.kind == .Comma || pk.kind == .Close_Brace { break }
                lexer_next(l)
            }
            if lexer_peek(l).kind == .Comma { lexer_next(l) }
        case:
            // ignore
        }
    }
}

// ---------------------------------------------------------------------------
// Completion logic
// ---------------------------------------------------------------------------

// The daemon's mutable state — one index per watched file path.
// Since the daemon is single-threaded (sequential accept loop) we don't need
// any locking.
g_index: Index

respond_to_buffer :: proc(buffer: string) -> string {
    // Step 1 — strip any partially-typed word after the last dot (the prefix
    // the user has already typed of the completion candidate).
    //
    //   "cat.breed.Per"  →  prefix = "Per",  chain_src = "cat.breed"
    //   "cat.breed."     →  prefix = "",     chain_src = "cat.breed"
    //   "cat.br"         →  prefix = "br",   chain_src = "cat"
    //
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

    // The character immediately before the word must be a dot.
    dot_pos := word_start - 1
    if dot_pos < 0 || buffer[dot_pos] != '.' {
        return ""
    }

    // Step 2 — collect the full dot-chain that ends at dot_pos.
    // Walk left over [a-zA-Z0-9_.] to grab e.g. "cat.breed" or "SomeEnum".
    chain_end   := dot_pos          // exclusive: the dot before prefix is not part of the chain
    chain_start := chain_end
    for chain_start > 0 {
        b := buffer[chain_start - 1]
        if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '.' {
            chain_start -= 1
        } else {
            break
        }
    }
    chain := buffer[chain_start:chain_end]  // e.g. "cat.breed" or "Cat"
    if chain == "" { return "" }

    // Step 3 — resolve the chain to a concrete type name by walking each
    // dot-separated segment through the index.
    //
    //   "cat.breed":
    //     segment[0] = "cat"   → resolve_local_type → "Cat"
    //     segment[1] = "breed" → look up field "breed" in struct Cat → "CatBreed"
    //   result type = "CatBreed"  →  completions = [Persian, Siamese]
    //
    segments := strings.split(chain, ".")
    defer delete(segments)

    // Resolve the root segment to a type name.
    current_type := resolve_to_type(segments[0], buffer)
    if current_type == "" { return "" }

    // Walk every subsequent segment as a field access on the current struct type.
    for i := 1; i < len(segments); i += 1 {
        field_name := segments[i]
        if field_name == "" { return "" }

        se, ok := g_index.structs[current_type]
        if !ok { return "" }           // not a struct — cannot dot into it

        next_type := ""
        for f in se.fields {
            if f.name == field_name {
                next_type = f.type
                break
            }
        }
        if next_type == "" { return "" }  // field not found
        current_type = next_type
    }

    return completions_for_type(current_type, prefix, buffer)
}

// resolve_to_type maps a single identifier to its declared type name.
// Resolution order (mirrors the old completions_for_type lookup):
//   1. The identifier itself is a known struct or enum name → return it as-is.
//   2. It is a global variable with an explicit type declaration.
//   3. It is a local variable somewhere above the cursor in the buffer.
resolve_to_type :: proc(name: string, buffer: string) -> string {
    // 1. Direct type name — already a struct or enum.
    if name in g_index.structs || name in g_index.enums {
        return name
    }
    // 2. Global variable.
    if type_name, ok := g_index.variables[name]; ok {
        return type_name
    }
    // 3. Local variable.
    if type_name, ok := resolve_local_type(buffer, name); ok {
        return type_name
    }
    return ""
}

// Scan the buffer text for a local declaration of `var_name` and return its
// type name.  Handles two patterns:
//
//   name : TypeName          (explicit type)
//   name := TypeName{...}    (inferred type from composite literal)
//
// We search backwards so the nearest declaration wins.
resolve_local_type :: proc(buffer: string, var_name: string) -> (string, bool) {
    i := len(buffer)
    for i > 0 {
        // Find the previous newline to get a line to examine.
        line_end := i
        i -= 1
        for i > 0 && buffer[i - 1] != '\n' { i -= 1 }
        line := strings.trim_space(buffer[i:line_end])

        // Match "var_name : TypeName" or "var_name := TypeName{"
        // We check that the line starts with var_name followed by whitespace or colon.
        if !strings.has_prefix(line, var_name) { continue }
        rest := strings.trim_left(line[len(var_name):], " \t")

        // Pattern 1: "name : TypeName"
        if strings.has_prefix(rest, ": ") || strings.has_prefix(rest, ":\t") || rest == ":" {
            after_colon := strings.trim_left(rest[1:], " \t")
            // Extract the first identifier token as the type name.
            end := 0
            for end < len(after_colon) {
                b := after_colon[end]
                if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') {
                    end += 1
                } else { break }
            }
            if end > 0 { return after_colon[:end], true }
        }

        // Pattern 2: "name := TypeName{"
        if strings.has_prefix(rest, ":= ") || strings.has_prefix(rest, ":=\t") || strings.has_prefix(rest, ":=") {
            after_assign := strings.trim_left(rest[2:], " \t")
            end := 0
            for end < len(after_assign) {
                b := after_assign[end]
                if b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') {
                    end += 1
                } else { break }
            }
            // Only accept if followed by '{' (composite literal), confirming it is a type.
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

// Format completions for a fully-resolved type name and a typed prefix.
// type_name must already be a concrete struct or enum name in g_index.
// Returns lines formatted as "word\tTypeHint", one per candidate.
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

// ---------------------------------------------------------------------------
// Shared I/O helpers
// ---------------------------------------------------------------------------

MAX_MESSAGE_BYTES :: 4 * 1024 * 1024  // 4 MiB (source files can be large)

fd_read_exactly :: proc(fd: linux.Fd, buf: []u8) -> bool {
    total := 0
    for total < len(buf) {
        n, err := linux.read(fd, buf[total:])
        if err != .NONE || n == 0 { return false }
        total += n
    }
    return true
}

fd_write_all :: proc(fd: linux.Fd, buf: []u8) {
    total := 0
    for total < len(buf) {
        n, _ := linux.write(fd, buf[total:])
        if n <= 0 { return }
        total += n
    }
}

// Message framing: 4-byte big-endian uint32 length prefix + UTF-8 body.

frame_write :: proc(fd: linux.Fd, msg: string) {
    body    := transmute([]u8)msg
    msg_len := u32(len(body))
    header: [4]u8 = {u8(msg_len >> 24), u8(msg_len >> 16), u8(msg_len >> 8), u8(msg_len)}
    fd_write_all(fd, header[:])
    fd_write_all(fd, body)
}

frame_read :: proc(fd: linux.Fd, allocator := context.allocator) -> (string, bool) {
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

// ---------------------------------------------------------------------------
// Socket path
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Daemon — --start <absolute_filepath>
// ---------------------------------------------------------------------------

daemon_start :: proc(filepath: string) {
    sock_path := socket_path_for_file(filepath)
    defer delete(sock_path)

    sock_path_c := strings.clone_to_cstring(sock_path)
    defer delete(sock_path_c)
    linux.unlink(sock_path_c)

    server_fd, sock_err := linux.socket(.UNIX, .STREAM, {}, .HOPOPT)
    if sock_err != .NONE {
        fmt.eprintfln("gjallarhorn: socket() failed: %v", sock_err)
        os.exit(1)
    }

    addr: linux.Sock_Addr_Un
    addr.sun_family = .UNIX
    copy(addr.sun_path[:], sock_path)

    if err := linux.bind(server_fd, &addr); err != .NONE {
        fmt.eprintfln("gjallarhorn: bind() failed: %v", err)
        os.exit(1)
    }
    if err := linux.listen(server_fd, 8); err != .NONE {
        fmt.eprintfln("gjallarhorn: listen() failed: %v", err)
        os.exit(1)
    }

    pid, fork_err := linux.fork()
    if fork_err != .NONE {
        fmt.eprintfln("gjallarhorn: fork() failed: %v", fork_err)
        os.exit(1)
    }
    if pid != 0 {
        fmt.println(sock_path)
        os.exit(0)
    }

    linux.setsid()

    // Index the file immediately on startup.
    if src, err := os.read_entire_file_from_path(filepath, context.allocator); err == nil {
        new_index := parse_source(string(src))
        index_destroy(&g_index)
        g_index = new_index
        delete(src, context.allocator)
    }

    daemon_serve(server_fd)
}

daemon_serve :: proc(server_fd: linux.Fd) {
    for {
        client_fd, accept_err := linux.accept(server_fd, (^linux.Sock_Addr_Un)(nil))
        if accept_err != .NONE { continue }
        handle_client(client_fd)
        linux.close(client_fd)
    }
}

// ---------------------------------------------------------------------------
// Protocol
//
// Every message is framed with a 4-byte length prefix.
// The first framed message from the client is a one-line command header:
//
//   "comp"   → second message is the buffer; reply with completions
//   "index"  → second message is full file source; rebuild index, reply ""
// ---------------------------------------------------------------------------

handle_client :: proc(client_fd: linux.Fd) {
    cmd, ok := frame_read(client_fd)
    if !ok { return }
    defer delete(cmd)

    switch cmd {
    case "comp":
        buffer, ok2 := frame_read(client_fd)
        if !ok2 { return }
        defer delete(buffer)
        response := respond_to_buffer(buffer)
        defer delete(response)
        frame_write(client_fd, response)

    case "index":
        filepath, ok2 := frame_read(client_fd)
        if !ok2 { return }
        defer delete(filepath)
        // Read the file from disk — avoids shell escaping limits on large files.
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

// ---------------------------------------------------------------------------
// Client helpers
// ---------------------------------------------------------------------------

client_connect :: proc(filepath: string) -> (linux.Fd, bool) {
    sock_path := socket_path_for_file(filepath)
    defer delete(sock_path)

    fd, sock_err := linux.socket(.UNIX, .STREAM, {}, .HOPOPT)
    if sock_err != .NONE {
        fmt.eprintfln("gjallarhorn: socket() failed: %v", sock_err)
        return 0, false
    }

    addr: linux.Sock_Addr_Un
    addr.sun_family = .UNIX
    copy(addr.sun_path[:], sock_path)

    if err := linux.connect(fd, &addr); err != .NONE {
        fmt.eprintfln("gjallarhorn: could not connect to daemon at %s", sock_path)
        linux.close(fd)
        return 0, false
    }
    return fd, true
}

// --comp <filepath> <buffer>
client_comp :: proc(filepath: string, buffer: string) {
    fd, ok := client_connect(filepath)
    if !ok { os.exit(1) }
    defer linux.close(fd)

    frame_write(fd, "comp")
    frame_write(fd, buffer)

    response, ok2 := frame_read(fd)
    if !ok2 {
        fmt.eprintfln("gjallarhorn: no response from daemon")
        os.exit(1)
    }
    defer delete(response)

    if len(response) > 0 {
        fmt.print(response)
    }
}

// --index <filepath>
// Tells the daemon to re-read and re-index the file from disk.
client_index :: proc(filepath: string) {
    fd, ok := client_connect(filepath)
    if !ok { os.exit(1) }
    defer linux.close(fd)

    frame_write(fd, "index")
    frame_write(fd, filepath)

    // Wait for the acknowledgement so the save doesn't race a following comp.
    response, _ := frame_read(fd)
    delete(response)
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

main :: proc() {
    if len(os.args) < 3 {
        usage()
        os.exit(1)
    }

    switch os.args[1] {
    case "--start":
        // --start <absolute_filepath>
        daemon_start(os.args[2])

    case "--comp":
        // --comp <absolute_filepath> <buffer_until_cursor>
        if len(os.args) < 4 { usage(); os.exit(1) }
        client_comp(os.args[2], os.args[3])

    case "--index":
        // --index <absolute_filepath>
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
