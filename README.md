# jj-get

Clone and organize [Jujutsu](https://github.com/jj-vcs/jj) repositories
in a directory tree derived from their URLs, like
[git-get](https://github.com/grdl/git-get) does for Git.

```console
$ jj-get grdl/git-get
$ jj-get https://codeberg.org/ziglings/exercises.git
$ jj-list
/home/me/repositories
├── codeberg.org
│   └── ziglings
│       └── exercises  main  ok
└── github.com
    └── grdl
        └── git-get    main  modified, main 1 ahead of origin
```

A single binary provides two commands, chosen by the name it is
invoked as:

- **`jj-get`** clones a repository into `<root>/<host>/<path>` with
  `jj git clone`.
- **`jj-list`** (a symlink to `jj-get`) shows every repository under the
  root along with its state.

## Installation

With Nix:

```console
$ nix profile install github:uzaaft/jj-get
```

From source, with Zig 0.16 or later:

```console
$ zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

Both install `jj-get` and the `jj-list` symlink. jj must be on `PATH`.

To use them as `jj get` and `jj list`, add aliases to your jj config:

```toml
[aliases]
get = ["util", "exec", "--", "jj-get"]
list = ["util", "exec", "--", "jj-list"]
```

## jj-get

```
jj-get [options] <repository>
jj-get [options] --dump <file>
```

| Option | Description |
| --- | --- |
| `-b, --branch <name>` | Fetch only this bookmark and check it out instead of the default branch |
| `-d, --dump <file>` | Clone every repository listed in a file, or `-` for stdin |
| `-t, --host <host>` | Default host for short references (default: `github.com`) |
| `-r, --root <path>` | Root directory for repositories (default: `~/repositories`) |
| `-c, --scheme <scheme>` | Default scheme for short references (default: `ssh`) |
| `-s, --skip-host` | Don't create a directory for the host |

Repositories can be given as:

| Reference | Clones | Into |
| --- | --- | --- |
| `user/repo` | `ssh://git@github.com/user/repo` | `github.com/user/repo` |
| `gitlab.com/user/repo` | `ssh://git@gitlab.com/user/repo` | `gitlab.com/user/repo` |
| `https://github.com/user/repo.git` | as given | `github.com/user/repo` |
| `git@github.com:user/repo.git` | `ssh://git@github.com/user/repo.git` | `github.com/user/repo` |
| `/srv/git/repo` | `file:///srv/git/repo` | `srv/git/repo` |

Ports, `~user` segments and a trailing `.git` are dropped from the
destination path.

## jj-list

```
jj-list [options]
```

| Option | Description |
| --- | --- |
| `-f, --fetch` | Run `jj git fetch --all-remotes` in each repository first |
| `-o, --out <format>` | `tree` (default), `flat` or `dump` |
| `-r, --root <path>` | Root directory to scan (default: `~/repositories`) |

Each repository is shown with the nearest bookmark at or below its
working-copy commit, then its status:

| Status | Meaning |
| --- | --- |
| `ok` | Nothing to report |
| `modified` | The working-copy commit has changes |
| `conflict` | The working-copy commit has conflicts |
| `main conflicted` | The `main` bookmark is conflicted |
| `main 1 ahead of origin` | `main` has commits not on `main@origin` |
| `main 2 behind origin` | `main@origin` has commits not on `main` |

Repositories are queried concurrently, and `jj-list` exits with status
1 if any of them couldn't be read.

### Backing up and restoring

`--out dump` prints one clone URL per repository, preferring the
`origin` remote. Feed it back to `jj-get` to recreate the same layout
elsewhere:

```console
$ jj-list --out dump > repos.txt
$ jj-get --dump repos.txt
```

Existing repositories are skipped, so re-running a dump is safe. Blank
lines and `#` comments are ignored, and a second column naming a
branch is accepted for compatibility with git-get dump files. jj-get
doesn't write branches itself because `jj git clone --branch` fetches
only that branch.

## Configuration

Settings are taken from, in order of precedence: command line flags,
environment variables, the `[jjget]` table in jj's config, and the
defaults.

| jj config | Environment | Default |
| --- | --- | --- |
| `jjget.root` | `JJGET_ROOT` | `~/repositories` |
| `jjget.host` | `JJGET_HOST` | `github.com` |
| `jjget.scheme` | `JJGET_SCHEME` | `ssh` |
| `jjget.skip-host` | `JJGET_SKIP_HOST` | `false` |

```console
$ jj config set --user jjget.root '~/src'
$ jj config set --user jjget.scheme https
```

A leading `~` in the root is expanded.

## Differences from git-get

- Clones are jj repositories, colocated with Git unless your jj config
  says otherwise.
- Status is expressed in jj terms: working-copy changes and conflicts,
  conflicted bookmarks, and tracked bookmarks ahead of or behind their
  remotes. There is no "untracked" state since jj tracks every file.
- `--branch` accepts bookmarks but not tags, and fetches only that
  bookmark.
- `host/user/repo` references use their own host rather than being
  placed under the default one.
- Configuration lives in jj's config instead of `~/.gitconfig`.

## Development

```console
$ nix develop          # zig, zls, jj and git
$ zig build test       # unit and end-to-end tests
$ zig build test-unit  # just the fast ones
$ nix flake check      # build and test the package in the sandbox
```

## License

MIT
