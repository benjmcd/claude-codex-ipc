#!/usr/bin/env bash
# Shared byte-safe renderer for reply-file and rollout-fallback bodies.
# Source this module, then call codex_ipc_render_file or codex_ipc_render_stream.

codex_ipc_render_stream() {
    LC_ALL=C od -An -v -t u1 | LC_ALL=C awk '
function escaped(byte) {
    printf "\\x%02X", byte
}
function reset_sequence() {
    need = 0
    count = 0
    codepoint = 0
    minimum = 0
}
function escape_sequence(    i) {
    for (i = 1; i <= count; i++) escaped(sequence[i])
    reset_sequence()
}
function emit_sequence(    i) {
    if (codepoint < minimum || codepoint > 1114111 || (codepoint >= 55296 && codepoint <= 57343)) {
        escape_sequence()
        return
    }
    if (codepoint >= 128 && codepoint <= 159) {
        printf "\\u{%04X}", codepoint
    } else {
        for (i = 1; i <= count; i++) printf "%c", sequence[i]
    }
    reset_sequence()
}
function consume(byte) {
    if (need > 0) {
        if (byte >= 128 && byte <= 191) {
            sequence[++count] = byte
            codepoint = codepoint * 64 + (byte - 128)
            need--
            if (need == 0) emit_sequence()
            return
        }
        escape_sequence()
        consume(byte)
        return
    }
    if (byte == 9 || byte == 10) {
        printf "%c", byte
    } else if (byte >= 32 && byte <= 126) {
        printf "%c", byte
    } else if (byte >= 194 && byte <= 223) {
        reset_sequence(); sequence[++count] = byte; codepoint = byte - 192; minimum = 128; need = 1
    } else if (byte >= 224 && byte <= 239) {
        reset_sequence(); sequence[++count] = byte; codepoint = byte - 224; minimum = 2048; need = 2
    } else if (byte >= 240 && byte <= 244) {
        reset_sequence(); sequence[++count] = byte; codepoint = byte - 240; minimum = 65536; need = 3
    } else {
        escaped(byte)
    }
}
{
    for (field = 1; field <= NF; field++) consume($field + 0)
}
END {
    if (need > 0) escape_sequence()
}
'
}

codex_ipc_render_file() {
    local file_path="$1" source_limit="$2"
    head -c "$source_limit" -- "$file_path" | codex_ipc_render_stream
}
