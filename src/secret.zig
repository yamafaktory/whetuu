//! Recognizes a credential on a command line, so the history store never keeps
//! the command. Every shape is anchored on something distinctive, a provider's
//! token prefix or the place a secret sits, because a false positive silently
//! drops a command the user wanted kept. There is no entropy guessing.

const std = @import("std");

const ascii = std.ascii;
const mem = std.mem;

/// True when `text` holds anything that looks like a credential.
pub fn contains(text: []const u8) bool {
    for (tokens) |token| {
        if (hasToken(text, token)) return true;
    }
    return hasUrlCredentials(text) or
        hasAuthorizationHeader(text) or
        hasJwt(text) or
        hasPrivateKey(text) or
        hasSecretAssignment(text) or
        hasSecretFlag(text);
}

const Charset = enum {
    alnum,
    word,
    base64url,
    upper_digit,
    hex_lower,
    slack_path,

    fn has(charset: Charset, c: u8) bool {
        return switch (charset) {
            .alnum => ascii.isAlphanumeric(c),
            .word => isWord(c),
            .base64url => isWord(c) or c == '-',
            .upper_digit => ascii.isUpper(c) or ascii.isDigit(c),
            .hex_lower => ascii.isDigit(c) or (c >= 'a' and c <= 'f'),
            .slack_path => isWord(c) or c == '/',
        };
    }
};

/// A provider token: a fixed prefix at the start of a word, then at least
/// `len` bytes from `charset`.
const Token = struct {
    prefix: []const u8,
    charset: Charset,
    len: usize,
};

const tokens = [_]Token{
    .{ .prefix = "AKIA", .charset = .upper_digit, .len = 16 },
    .{ .prefix = "ASIA", .charset = .upper_digit, .len = 16 },
    .{ .prefix = "ghp_", .charset = .alnum, .len = 36 },
    .{ .prefix = "gho_", .charset = .alnum, .len = 36 },
    .{ .prefix = "ghu_", .charset = .alnum, .len = 36 },
    .{ .prefix = "ghs_", .charset = .alnum, .len = 36 },
    .{ .prefix = "ghr_", .charset = .alnum, .len = 76 },
    .{ .prefix = "github_pat_", .charset = .word, .len = 82 },
    .{ .prefix = "glpat-", .charset = .base64url, .len = 20 },
    .{ .prefix = "xoxa-", .charset = .base64url, .len = 10 },
    .{ .prefix = "xoxb-", .charset = .base64url, .len = 10 },
    .{ .prefix = "xoxp-", .charset = .base64url, .len = 10 },
    .{ .prefix = "xoxr-", .charset = .base64url, .len = 10 },
    .{ .prefix = "xoxs-", .charset = .base64url, .len = 10 },
    .{ .prefix = "hooks.slack.com/services/T", .charset = .slack_path, .len = 40 },
    .{ .prefix = "sk_live_", .charset = .alnum, .len = 24 },
    .{ .prefix = "sk_test_", .charset = .alnum, .len = 24 },
    .{ .prefix = "rk_live_", .charset = .alnum, .len = 24 },
    .{ .prefix = "rk_test_", .charset = .alnum, .len = 24 },
    .{ .prefix = "nfp_", .charset = .alnum, .len = 36 },
    .{ .prefix = "nfc_", .charset = .alnum, .len = 36 },
    .{ .prefix = "nfo_", .charset = .alnum, .len = 36 },
    .{ .prefix = "nfu_", .charset = .alnum, .len = 36 },
    .{ .prefix = "nfb_", .charset = .alnum, .len = 36 },
    .{ .prefix = "npm_", .charset = .alnum, .len = 36 },
    .{ .prefix = "pul-", .charset = .hex_lower, .len = 40 },
    .{ .prefix = "sk-ant-", .charset = .base64url, .len = 80 },
    .{ .prefix = "sk-proj-", .charset = .base64url, .len = 40 },
    .{ .prefix = "sk-svcacct-", .charset = .base64url, .len = 40 },
    .{ .prefix = "sk-admin-", .charset = .base64url, .len = 40 },
    .{ .prefix = "AIza", .charset = .base64url, .len = 35 },
    .{ .prefix = "hf_", .charset = .alnum, .len = 34 },
    .{ .prefix = "dop_v1_", .charset = .hex_lower, .len = 64 },
    .{ .prefix = "doo_v1_", .charset = .hex_lower, .len = 64 },
    .{ .prefix = "dor_v1_", .charset = .hex_lower, .len = 64 },
    .{ .prefix = "pypi-AgEIcHlwaS5vcmc", .charset = .base64url, .len = 50 },
};

fn hasToken(text: []const u8, token: Token) bool {
    var from: usize = 0;
    while (mem.findPos(u8, text, from, token.prefix)) |at| : (from = at + 1) {
        if (!startsWord(text, at)) continue;
        if (runLen(text, at + token.prefix.len, token.charset, token.len) == token.len) return true;
    }
    return false;
}

/// `scheme://user:password@`, with a literal password.
fn hasUrlCredentials(text: []const u8) bool {
    var from: usize = 0;
    while (mem.findPos(u8, text, from, "://")) |at| : (from = at + 1) {
        if (at == 0 or !ascii.isAlphanumeric(text[at - 1])) continue;

        const rest = text[at + 3 ..];
        const user = mem.findAny(u8, rest, "/:@ \t\n") orelse continue;
        if (user == 0 or rest[user] != ':') continue;

        const password = rest[user + 1 ..];
        const end = mem.findAny(u8, password, "/@ \t\n") orelse continue;
        if (end > 0 and password[end] == '@' and password[0] != '$') return true;
    }
    return false;
}

/// `Authorization: Bearer|Basic|Token <value>`, with a literal value.
fn hasAuthorizationHeader(text: []const u8) bool {
    const header = "authorization:";
    var from: usize = 0;
    while (ascii.findIgnoreCasePos(text, from, header)) |at| : (from = at + 1) {
        const rest = mem.trimStart(u8, text[at + header.len ..], " \t");
        const scheme = for ([_][]const u8{ "bearer", "basic", "token" }) |candidate| {
            if (ascii.startsWithIgnoreCase(rest, candidate)) break candidate;
        } else continue;

        const after = rest[scheme.len..];
        const value = mem.trimStart(u8, after, " \t");
        if (value.len == after.len or value.len < 8) continue;
        if (value[0] != '$' and mem.findAny(u8, value[0..8], " \t\n'\"") == null) return true;
    }
    return false;
}

/// Three base64url segments joined by dots, the first two opening on `eyJ`.
fn hasJwt(text: []const u8) bool {
    const min = 10;
    var from: usize = 0;
    while (mem.findPos(u8, text, from, "eyJ")) |at| {
        const header_end = at + runLen(text, at, .base64url, text.len);
        from = header_end;
        if (!startsWord(text, at) or header_end - at < min) continue;
        if (!mem.startsWith(u8, text[header_end..], ".eyJ")) continue;

        const payload = header_end + 1;
        const payload_end = payload + runLen(text, payload, .base64url, text.len);
        if (payload_end - payload < min or payload_end >= text.len or text[payload_end] != '.') continue;
        if (runLen(text, payload_end + 1, .base64url, min) == min) return true;
    }
    return false;
}

/// A PEM header for any kind of private key.
fn hasPrivateKey(text: []const u8) bool {
    const begin = "-----BEGIN ";
    var from: usize = 0;
    while (mem.findPos(u8, text, from, begin)) |at| : (from = at + 1) {
        const rest = text[at + begin.len ..];
        const label_len = mem.findNone(u8, rest, "ABCDEFGHIJKLMNOPQRSTUVWXYZ ") orelse rest.len;
        if (mem.endsWith(u8, rest[0..label_len], "PRIVATE KEY") and
            mem.startsWith(u8, rest[label_len..], "-----")) return true;
    }
    return false;
}

/// `NAME=value` where the name marks a secret and the value is literal, so
/// `TOKEN=$(vault read …)` passes and `TOKEN=abc` does not.
fn hasSecretAssignment(text: []const u8) bool {
    var from: usize = 0;
    while (mem.findScalarPos(u8, text, from, '=')) |eq| : (from = eq + 1) {
        var start = eq;
        while (start > 0 and isEnvName(text[start - 1])) start -= 1;
        if (start == eq or !startsWord(text, start)) continue;
        if (!isSecretName(text[start..eq])) continue;

        const first = literalStart(text[eq + 1 ..]) orelse continue;
        if (first != '=') return true;
    }
    return false;
}

/// `--password value` or `--token=value`, with a literal value.
fn hasSecretFlag(text: []const u8) bool {
    var from: usize = 0;
    while (mem.findPos(u8, text, from, "--")) |at| : (from = at + 1) {
        if (at > 0 and !ascii.isWhitespace(text[at - 1])) continue;

        const rest = text[at + 2 ..];
        const name = for ([_][]const u8{ "password", "passwd", "token", "api-key", "secret" }) |candidate| {
            if (mem.startsWith(u8, rest, candidate)) break candidate;
        } else continue;

        const after = rest[name.len..];
        if (after.len == 0) continue;
        const value = if (after[0] == '=')
            after[1..]
        else if (ascii.isWhitespace(after[0]))
            mem.trimStart(u8, after, " \t\n")
        else
            continue;

        const first = literalStart(value) orelse continue;
        if (first != '-') return true;
    }
    return false;
}

/// Splits an uppercase variable name on `_` and looks for a segment that marks
/// a secret. A name ending in `_FILE`, `_PATH` or `_DIR` holds where a secret
/// lives rather than the secret, the Docker convention for passing one in.
fn isSecretName(name: []const u8) bool {
    if (mem.eql(u8, name, "GOOGLE_SERVICE_ACCOUNT_KEY")) return true;
    if (mem.startsWith(u8, name, "AZURE_") and mem.endsWith(u8, name, "_KEY")) return true;

    for ([_][]const u8{ "_FILE", "_PATH", "_DIR" }) |suffix| {
        if (mem.endsWith(u8, name, suffix)) return false;
    }

    var previous: []const u8 = "";
    var it = mem.splitScalar(u8, name, '_');
    while (it.next()) |segment| : (previous = segment) {
        for ([_][]const u8{ "PASSWORD", "PASSWD", "SECRET", "TOKEN" }) |marker| {
            if (mem.eql(u8, segment, marker)) return true;
        }
        if (mem.eql(u8, previous, "API") and mem.eql(u8, segment, "KEY")) return true;
    }
    return false;
}

/// The first byte of a value that the shell would take literally, past one
/// opening quote, or null when the value is empty or expands to something else.
fn literalStart(value: []const u8) ?u8 {
    const unquoted = if (value.len > 0 and (value[0] == '"' or value[0] == '\'')) value[1..] else value;
    if (unquoted.len == 0) return null;
    return switch (unquoted[0]) {
        ' ', '\t', '\n', '$', '`', '(', '"', '\'', ';', '&', '|' => null,
        else => unquoted[0],
    };
}

/// How many bytes from `from` on belong to `charset`, counting at most `max`.
fn runLen(text: []const u8, from: usize, charset: Charset, max: usize) usize {
    var n: usize = 0;
    while (n < max and from + n < text.len and charset.has(text[from + n])) n += 1;
    return n;
}

fn startsWord(text: []const u8, at: usize) bool {
    return at == 0 or !isWord(text[at - 1]);
}

fn isWord(c: u8) bool {
    return ascii.isAlphanumeric(c) or c == '_';
}

fn isEnvName(c: u8) bool {
    return ascii.isUpper(c) or ascii.isDigit(c) or c == '_';
}

fn repeat(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    var out: [s.len * n]u8 = undefined;
    for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

test "provider tokens are recognized at the start of a word" {
    const found = [_][]const u8{
        "aws s3 ls --access-key AKIA" ++ repeat("A", 16),
        "echo ASIA" ++ repeat("7", 16),
        "git clone https://ghp_" ++ repeat("a", 36) ++ "@github.com/x/y",
        "gh auth login --with-token <<< gho_" ++ repeat("b", 36),
        "curl -H 'x: ghs_" ++ repeat("c", 36) ++ "'",
        "echo ghr_" ++ repeat("d", 76),
        "echo github_pat_11" ++ repeat("A", 20) ++ "_" ++ repeat("b", 59),
        "glab auth login -t glpat-" ++ repeat("x_-", 7),
        "slack xoxb-123-456-" ++ repeat("a", 10),
        "curl https://hooks.slack.com/services/T01234567/B01234567/" ++ repeat("z", 24),
        "stripe --api sk_live_" ++ repeat("9", 24),
        "stripe rk_test_" ++ repeat("9", 24),
        "netlify nfp_" ++ repeat("e", 36),
        "npm config set //registry/:_authToken npm_" ++ repeat("f", 36),
        "pulumi login pul-" ++ repeat("0123456789", 4),
        "claude sk-ant-api03-" ++ repeat("Q", 80),
        "openai sk-proj-" ++ repeat("r", 40),
        "curl ?key=AIza" ++ repeat("s", 35),
        "hf_" ++ repeat("t", 34),
        "doctl auth init -t dop_v1_" ++ repeat("ab", 32),
        "twine upload -p pypi-AgEIcHlwaS5vcmc" ++ repeat("u", 50),
    };
    for (found) |text| try std.testing.expect(contains(text));
}

test "a token cut short, or inside a longer word, is not a secret" {
    const passed = [_][]const u8{
        "echo ghp_" ++ repeat("a", 35),
        "echo xghp_" ++ repeat("a", 36),
        "echo my_npm_" ++ repeat("f", 36),
        "echo AKIA_is_a_prefix",
        "git checkout sk-live-demo",
        "pulumi login pul-" ++ repeat("Z", 40),
        "hf_hub_download",
    };
    for (passed) |text| try std.testing.expect(!contains(text));
}

test "a password in a URL is a secret, a user alone is not" {
    try std.testing.expect(contains("git clone https://me:hunter2@example.com/r.git"));
    try std.testing.expect(contains("psql postgres://app:s3cret@db:5432/app"));
    try std.testing.expect(!contains("git clone ssh://git@github.com/x/y"));
    try std.testing.expect(!contains("curl http://localhost:8080/a@b"));
    try std.testing.expect(!contains("git clone https://$USER:$TOKEN@example.com/r.git"));
    try std.testing.expect(!contains("echo ://a:b@"));
}

test "an authorization header with a literal value is a secret" {
    try std.testing.expect(contains("curl -H 'Authorization: Bearer abcdefgh123' https://api"));
    try std.testing.expect(contains("http :8080 authorization:token 12345678"));
    try std.testing.expect(!contains("curl -H \"Authorization: Bearer $TOKEN\" https://api"));
    try std.testing.expect(!contains("curl -H 'Authorization: Bearer abc'"));
    try std.testing.expect(!contains("grep -r Authorization: src"));
}

test "a JWT is a secret" {
    try std.testing.expect(contains("curl -b session=eyJhbGciOiJI.eyJzdWIiOiIx.SflKxwRJSM"));
    try std.testing.expect(contains("echo eyJ-eyJhbGciOiJI.eyJzdWIiOiIx.SflKxwRJSM"));
    try std.testing.expect(!contains("echo eyJhbGciOiJI.eyJzdWIiOiIx.short"));
    try std.testing.expect(!contains("echo eyJhbGciOiJI.notapayload.SflKxwRJSM"));
}

test "a private key header is a secret" {
    try std.testing.expect(contains("echo '-----BEGIN OPENSSH PRIVATE KEY-----' > k"));
    try std.testing.expect(contains("printf -- '-----BEGIN PRIVATE KEY-----\\n'"));
    try std.testing.expect(!contains("echo '-----BEGIN CERTIFICATE-----'"));
    try std.testing.expect(!contains("echo '-----BEGIN PUBLIC KEY-----'"));
}

test "a literal value assigned to a secret name is a secret" {
    const found = [_][]const u8{
        "export GITHUB_TOKEN=abc",
        "DB_PASSWORD=x docker compose up",
        "docker run -e MYSQL_ROOT_PASSWORD='hunter2' mysql",
        "export AWS_SECRET_ACCESS_KEY=abc",
        "OPENAI_API_KEY=\"abc\" python run.py",
        "export GOOGLE_SERVICE_ACCOUNT_KEY=abc",
        "export AZURE_STORAGE_KEY=abc",
        "TOKEN=dev ./run",
    };
    for (found) |text| try std.testing.expect(contains(text));

    const passed = [_][]const u8{
        "export GITHUB_TOKEN=$(gh auth token)",
        "export GITHUB_TOKEN=\"$X\"",
        "export GITHUB_TOKEN=`cat t`",
        "export GITHUB_TOKEN=",
        "export GITHUB_TOKEN= ls",
        "MYSQL_PASSWORD_FILE=/run/secrets/db docker compose up",
        "TOKENIZER_PATH=./tok python train.py",
        "export github_token=abc",
        "export MYGITHUB_TOKENS=abc",
        "API=1 KEY=2 make",
        "[[ $TOKEN == abc ]]",
        "echo $AWS_SECRET_ACCESS_KEY",
    };
    for (passed) |text| try std.testing.expect(!contains(text));
}

test "a literal value passed to a secret flag is a secret" {
    try std.testing.expect(contains("docker login --password hunter2 registry"));
    try std.testing.expect(contains("vault login --token=abc"));
    try std.testing.expect(contains("tool --api-key 'abc'"));
    try std.testing.expect(!contains("docker login --password-stdin registry"));
    try std.testing.expect(!contains("tool --token $T"));
    try std.testing.expect(!contains("tool --token --verbose"));
    try std.testing.expect(!contains("tool --token"));
    try std.testing.expect(!contains("tool --token-file ~/.t"));
    try std.testing.expect(!contains("tool x--token abc"));
}

test "ordinary commands are not secrets" {
    const passed = [_][]const u8{
        "",
        "git commit -m 'plan — done'",
        "zig build test --fuzz=300K",
        "curl -fsSL https://yamafaktory.github.io/whetuu/install.sh | sh",
        "ssh -p 2222 user@host",
        "kubectl get secret my-secret -o yaml",
        "grep -rn TOKEN src",
        "a=b c==d e=",
    };
    for (passed) |text| try std.testing.expect(!contains(text));
}

test "any bytes at all can be checked" {
    const Context = struct {
        fn testOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            _ = contains(buf[0..smith.slice(&buf)]);
        }
    };
    return std.testing.fuzz(Context{}, Context.testOne, .{});
}
