#!/usr/bin/env python3
"""The confidential scan of a family repository: every file, message and identity it publishes is checked against
the lists of words, names and identities the family keeps privately.

    confidential_scan.py --policy library|fork [--words F] [--refs F] [--allow F] [--identities F] --files <path>...
    confidential_scan.py --policy ... --message <file>
    confidential_scan.py --policy ... --range <repo> <rev-list arguments>...
    confidential_scan.py --policy ... --history <repo>
    confidential_scan.py --policy ... --object <repo> <ref>

Categories: home paths (a directory under Users or home, in any letter case, as a case-insensitive file system reads
them), e-mail addresses, IPv4 addresses (four dotted octets that are no part of a longer dotted number or of a word,
sentence punctuation either side), credential shapes (GitHub,
GitLab, Slack, Anthropic or OpenAI, Google and Hugging Face tokens, AWS keys, private-key blocks, a key named
`password` or `token`, bare, quoted or ending a name such as GITHUB_TOKEN, followed by `=` or `:` and a value),
queue job ids (a hostq job's `q` and 3-7 digits, no part of a word or a dotted name), the
names of tools/mirrors/refs.tsv's private rows (read at run time, so the private codes' names are written once), and
the words of confidential-words.txt, each under a `[<category>]` line naming the category reported. Policy `library`
(the family's libraries) applies every category; `fork` (the forks, whose cluster tooling names
allocations and hosts by design) drops the `[cluster word]` section and the queue job ids alone. A word or name matches as a
case-insensitive substring, so a name inside an identifier is a hit; a word under a `[<category>, whole word]` line (a
short host name, which as a substring would flag ordinary words) matches only with no letter, digit or `_` on either
side, and is reported and dropped by a policy as <category>. A hit is excused only when its whole line,
stripped, is a `line: <text>` entry of confidential-allow.txt; a binary blob (a NUL byte) is a hit unless its object
id is a `blob: <id>` entry there. In a commit or tag message, never in a file, a line that is exactly
`Co-Authored-By: <name> <<address>>` with <address> a `trailer: <address>` entry has that address excused, its name
still scanned. A message is UTF-8 (no `encoding` header, or one naming UTF-8): a NUL byte in it is a hit, another
declared encoding or bytes that are not UTF-8 are unreadable. In --range, --history and --object the author,
committer and tagger of every commit and tag read must be an exact `Name <address>` line of
confidential-identities.txt; any other is a hit. A tag whose chain ends at a blob or a tree is a hit: what it
publishes is no commit's content. refs.tsv's rows are checked whole: a line that is no `#` comment and no row of
four TAB-separated columns (name, url, a 40- or 64-hex commit, cited by) and an optional fifth `private` is
unreadable, so a malformed row never drops a private name.

--files: each file's content and its path name; a symbolic link's content is its target's name, which is what git
stores for it, never the file it points at. --message: a commit message, every line, '#' lines included (a -m or
-F commit's whitespace cleanup and --cleanup=verbatim keep them, and a hook cannot see the cleanup mode). --range: the
blobs, path names, messages and identities of the commits `git rev-list <arguments>` lists, and the annotated tags on
them or named in the arguments (a tag pushed onto a published commit). --history: every blob, path name, message and
identity reachable from every ref, and every annotated tag. --object: the named ref's own object, an annotated tag
(its message and tagger, and every tag it wraps, down to the commit it must end at) or a commit (its message and identities), whether or not anything
else is new. A tag of a tag is followed to its end, each tag object scanned once.

The three lists default to the files beside this script and tools/mirrors/refs.tsv of its repository; the four
options replace them. Exit 0 clean, 1 a hit (each printed `<where>:<line>: <category>: <match>`), 2 a usage error,
a list that cannot be read, an object that cannot be read or a failed git call: never a skip. Standard library only.
"""

import hashlib
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
PATTERNS = (
    ("home path", r"/(?i:users|home)/[^/\s'\"`:;,)]+"),
    # an address starts where a run of its local part's characters starts, so a long run is read once, not once from
    # each of its characters (a 1.1 MB line took minutes, 2026-11-11)
    (
        "e-mail address",
        r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}",
    ),
    (
        "IPv4 address",
        r"(?<!\w)(?<!\d\.)(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?!\w)(?!\.\d)",
    ),
    (
        "credential",
        r"gh[opsur]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|glpat-[A-Za-z0-9_-]{20,}|xox[bp]-[A-Za-z0-9-]{10,}"
        # a key block's label runs to the next BEGIN at most, so a run of many BEGINs is read once
        r"|(?:AKIA|ASIA)[0-9A-Z]{16}|BEGIN (?:(?!BEGIN )[A-Z ])*PRIVATE KEY"
        r"|(?<![A-Za-z0-9])(?:sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|hf_[A-Za-z0-9]{30,})"
        # a key named password or token, alone or ending a name (GITHUB_TOKEN, X-Auth-Token, _token), quoted or not; a
        # name starts after no word character, `_` or `-`, so a long run of them is read once
        r"|(?i:(?<![a-z0-9_-])(?:[a-z0-9]*[_-])*(?:password|token)[\"']?\s*[=:]\s*\S+)",
    ),
    ("queue job id", r"(?<!\w)(?<!\w\.)q\d{3,7}(?!\w)"),
)
DROPPED = {
    "library": set(),
    "fork": {"cluster word", "queue job id", "private repository"},
}  # the sections and patterns each policy leaves out (fork: the family's own repositories' names)
TRAILER = re.compile(r"Co-Authored-By: ([^<>]+) <([^<>]+)>")
REFS_ROW = re.compile(r"\S+\t\S+\t(?:[0-9a-f]{40}|[0-9a-f]{64})\t\S+(?:\tprivate)?")


class Fatal(Exception):
    """A condition that ends the scan with exit 2: never a skip."""


def entries(path):
    """The stripped lines of a list file, blank lines and '#' comments left out."""
    text = pathlib.Path(path).read_text(encoding="utf-8")
    return [
        ln.strip() for ln in text.splitlines() if ln.strip() and not ln.lstrip().startswith("#")
    ]


def private_names(refs):
    """The names of refs.tsv's private rows: the first column of a row whose fifth is `private`. Every line is a `#`
    comment or a whole row; any other is fatal."""
    names = []
    for number, line in enumerate(pathlib.Path(refs).read_text(encoding="utf-8").splitlines(), 1):
        if line.startswith("#"):
            continue
        if not REFS_ROW.fullmatch(line) or "private" in line.split("\t")[:4]:
            raise Fatal(
                f"{refs}:{number}: {line!r} is not `<name> TAB <url> TAB <commit> TAB <cited by> [TAB private]`"
            )
        if line.endswith("\tprivate"):
            names.append(line.split("\t")[0])
    return names


def words_of(path, policy):
    """{word: (category, whole)} of a words file in `[<category>]` and `[<category>, whole word]` sections, the
    policy's dropped categories left out; a word listed both ways matches as a substring."""
    out, category = {}, None
    for ln in entries(path):
        if ln.startswith("[") and ln.endswith("]"):
            category, comma, qualifier = (s.strip() for s in ln[1:-1].partition(","))
            if comma and qualifier != "whole word":
                raise Fatal(f"{path}: {ln!r} is neither [<category>] nor [<category>, whole word]")
            whole = bool(comma)
        elif category is None:
            raise Fatal(f"{path}: the word {ln!r} stands before any [<category>] line")
        elif category not in DROPPED[policy]:
            word = ln.lower()
            if word not in out or out[word][1] and not whole:
                out[word] = (category, whole)
    return out


class Scanner:
    def __init__(self, policy, words, refs, allow, identities):
        found = {name.lower(): ("private name", False) for name in private_names(refs)}
        for word, kind in words_of(words, policy).items():
            found.setdefault(word, kind)
        self.rules = [
            (name, re.compile(rx)) for name, rx in PATTERNS if name not in DROPPED[policy]
        ]
        for category, whole in sorted(set(found.values())):
            mine = sorted(
                (w for w, k in found.items() if k == (category, whole)), key=len, reverse=True
            )
            rx = "|".join(map(re.escape, mine))
            # \w is a letter, a digit or `_`, so a whole word joined to any of them is no hit
            self.rules.append(
                (category, re.compile(rf"(?<!\w)(?:{rx})(?!\w)" if whole else rx, re.I))
            )
        self.allowed = {"line": set(), "blob": set(), "trailer": set()}
        for entry in entries(allow):
            kind, _, value = entry.partition(": ")
            if kind not in self.allowed or not value:
                raise Fatal(
                    f"{allow}: {entry!r} is none of `line: <text>`, `blob: <id>`, `trailer: <address>`"
                )
            self.allowed[kind].add(value.strip())
        self.lines, self.blobs, self.trailers = (
            self.allowed[k] for k in ("line", "blob", "trailer")
        )
        self.identities = set(entries(identities))
        self.hits = 0

    def hit(self, place, category, match):
        self.hits += 1
        print(f"{place}: {category}: {match}")

    def text(self, where, text, path=False, message=False):
        """Report each hit of text; a path name is one line reported as `<where>: path`. In a message, an allowed
        trailer's address is excused and its name scanned."""
        for number, line in enumerate(text.splitlines() or [""], 1):
            if line.strip() in self.lines:
                continue
            trailer = TRAILER.fullmatch(line.strip()) if message else None
            if trailer and trailer.group(2) in self.trailers:
                line = trailer.group(1)
            for category, rx in self.rules:
                for m in rx.finditer(line):
                    self.hit(
                        f"{where}: path" if path else f"{where}:{number}", category, m.group(0)
                    )

    def message(self, where, raw, header=True):
        """The message of a raw commit or tag object (header=False: raw is the bare message): a NUL byte a hit, a
        declared encoding other than UTF-8 or bytes that are not UTF-8 fatal, else its text scanned."""
        head, _, data = raw.partition(b"\n\n") if header else (b"", b"", raw)
        declared = [
            ln[9:].decode(errors="replace")
            for ln in head.split(b"\n")
            if ln.startswith(b"encoding ")
        ]
        if b"\0" in data:
            self.hit(where, "binary message", "a NUL byte")
        elif any(e.lower() not in ("utf-8", "utf8") for e in declared):
            raise Fatal(
                f"{where}: declares encoding {declared[0]}; the scan reads UTF-8 messages only"
            )
        else:
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError as err:
                raise Fatal(f"{where}: the message is not UTF-8 ({err})")
            self.text(where, text, message=True)

    def blob(self, where, data, sha):
        if b"\0" in data:
            if sha not in self.blobs:
                self.hit(where, "binary blob", sha)
        else:
            self.text(where, data.decode("utf-8", errors="replace"))

    def identity(self, where, raw):
        """The author, committer and tagger header lines of a raw commit or tag object, each a listed identity."""
        for line in raw.split(b"\n\n", 1)[0].decode("utf-8", errors="replace").splitlines():
            role, _, rest = line.partition(" ")
            if role in ("author", "committer", "tagger"):
                who = rest.rsplit(" ", 2)[0]  # the timestamp and the zone dropped
                if who not in self.identities:
                    self.hit(f"{where} {role}", "identity", who)


def git(repo, *args, data=None):
    r = subprocess.run(["git", "-C", str(repo), *args], input=data, capture_output=True)
    if r.returncode:
        raise Fatal(f"git {' '.join(args[:3])} failed: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout


def objects(repo, shas):
    """{sha: (type, content)} through one `git cat-file --batch`; an object the repository lacks is fatal."""
    out = git(repo, "cat-file", "--batch", data="".join(f"{s}\n" for s in shas).encode())
    found, at = {}, 0
    while at < len(out):
        end = out.index(b"\n", at)
        header = out[at:end].decode().split()
        if len(header) != 3:  # "<sha> missing" or "<sha> ambiguous"
            raise Fatal(f"cannot read object {' '.join(header)}")
        sha, kind, size = header
        found[sha] = (kind, out[end + 1 : end + 1 + int(size)])
        at = end + 1 + int(size) + 1
    return found


def scan_tags(scanner, repo, tags):
    """The message and tagger of every tag object in tags ({sha: where}) and, recursively, of each tag object one
    points at, each object once."""
    seen = set()
    while tags:
        seen |= tags.keys()
        inner = {}
        for sha, (_, raw) in objects(repo, tags).items():
            scanner.message(f"tag {tags[sha]}", raw)
            scanner.identity(f"tag {tags[sha]}", raw)
            head = raw.split(b"\n", 2)  # a tag object starts "object <sha>", "type <type>"
            target = head[0].decode().removeprefix("object ")
            kind = head[1].decode(errors="replace").removeprefix("type ") if len(head) > 1 else "?"
            if kind == "tag" and target not in seen:
                inner[target] = f"{tags[sha]} -> {target[:12]}"
            elif kind not in ("tag", "commit"):
                scanner.hit(f"tag {tags[sha]}", "tag target", f"{kind} {target}")
        tags = inner


def scan_commits(scanner, repo, commits, every_blob, named=()):
    short = {c: c[:12] for c in commits}
    blobs = {}  # blob -> where
    if every_blob:
        for line in git(repo, "rev-list", "--all", "--objects").decode().splitlines():
            sha, _, path = line.partition(" ")
            blobs.setdefault(sha, f"{sha[:12]} ({path})" if path else sha[:12])
        kinds = git(
            repo,
            "cat-file",
            "--batch-check=%(objectname) %(objecttype)",
            data="\n".join(blobs).encode(),
        )
        keep = {ln.split()[0] for ln in kinds.decode().splitlines() if ln.endswith(" blob")}
        blobs = {s: w for s, w in blobs.items() if s in keep}
        # NUL-separated, as git stores them: the quoted form spells a non-ASCII byte or a newline as an escape
        names = git(repo, "log", "--all", "-m", "--format=", "--name-only", "-z")
        for path in sorted({p for p in names.decode("utf-8", errors="replace").split("\0") if p}):
            scanner.text(path, path, path=True)
    else:
        for c in commits:
            raw = git(
                repo, "diff-tree", "-r", "-m", "--root", "--no-commit-id", "--no-renames", "-z", c
            )
            fields = raw.decode("utf-8", errors="replace").split("\0")
            for meta, path in zip(fields[0::2], fields[1::2]):
                _, mode, _, sha, status = meta.split()
                if status in ("A", "C", "M", "R", "T"):
                    scanner.text(f"{short[c]}:{path}", path, path=True)
                    if mode != "160000":  # a gitlink (a submodule) has a path name and no blob
                        blobs.setdefault(sha, f"{short[c]}:{path}")
    for sha, (_, data) in objects(repo, blobs).items():
        scanner.blob(blobs[sha], data, sha)
    for c, (_, raw) in objects(repo, commits).items():
        scanner.message(f"{short[c]} message", raw)
        scanner.identity(short[c], raw)
    tags = git(
        repo,
        "for-each-ref",
        *([] if every_blob else ["refs/tags"]),
        "--format=%(objecttype) %(objectname) %(*objectname) %(refname)",
    )
    wanted = set(commits)
    named = {*named, *(f"refs/tags/{n}" for n in named)}
    annotated = {}
    for line in tags.decode().splitlines():
        kind, sha, peeled, ref = line.split(" ", 3)
        if kind == "tag" and (every_blob or peeled in wanted or ref in named):
            annotated[sha] = ref
    scan_tags(scanner, repo, annotated)


def scan_object(scanner, repo, ref):
    """The ref's own object, never what it peels to."""
    sha = git(repo, "rev-parse", "--verify", ref).decode().strip()
    kind, raw = objects(repo, [sha])[sha]
    if kind == "tag":
        scan_tags(scanner, repo, {sha: ref})
    elif kind == "commit":
        scanner.message(f"{sha[:12]} message", raw)
        scanner.identity(sha[:12], raw)
    else:
        raise Fatal(f"{ref} is a {kind}, not a tag or a commit")


def blob_id(data):
    """The git object id (SHA-1 object format) of data as a blob."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def main(argv):
    lists = {
        "--words": HERE / "confidential-words.txt",
        "--refs": HERE.parent / "mirrors/refs.tsv",
        "--allow": HERE / "confidential-allow.txt",
        "--identities": HERE / "confidential-identities.txt",
        "--policy": None,
    }
    while argv[:1] and argv[0] in lists and len(argv) > 1:
        lists[argv[0]] = argv[1]
        argv = argv[2:]
    modes = ("--files", "--message", "--range", "--history", "--object")
    if lists["--policy"] not in DROPPED or len(argv) < 2 or argv[0] not in modes:
        print(__doc__, file=sys.stderr)
        return 2
    mode, rest = argv[0], argv[1:]
    try:
        scanner = Scanner(
            *(lists[k] for k in ("--policy", "--words", "--refs", "--allow", "--identities"))
        )
        if mode == "--files":
            for path in rest:
                p = pathlib.Path(path)
                data = bytes(p.readlink()) if p.is_symlink() else p.read_bytes()
                scanner.text(path, path, path=True)
                scanner.blob(path, data, blob_id(data))
        elif mode == "--message":
            # shortcut: a hit in a comment git's editor template adds (`# Author: <name> <address>` when the author
            # is not the committer) blocks too; such a commit is made with -m or -F
            scanner.message(rest[0], pathlib.Path(rest[0]).read_bytes(), header=False)
        elif mode == "--object":
            if len(rest) != 2:
                raise Fatal("--object needs <repo> <ref>")
            scan_object(scanner, rest[0], rest[1])
        else:
            repo, revs = rest[0], rest[1:] if mode == "--range" else ["--all"]
            if not revs:
                raise Fatal("--range needs rev-list arguments")
            commits = git(repo, "rev-list", *revs).decode().split()
            scan_commits(scanner, repo, commits, every_blob=mode == "--history", named=revs)
    except (Fatal, OSError, UnicodeDecodeError) as err:
        print(f"confidential_scan: {err}", file=sys.stderr)
        return 2
    return 1 if scanner.hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
