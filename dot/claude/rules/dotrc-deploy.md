---
paths:
  - "**/dot/**"
  - "**/bin/deploy.sh"
---

## dotrc の展開経路（`bin/deploy.sh`）と新規エントリの落とし穴

このリポジトリ（dotrc）の `dot/` 配下は、`bin/deploy.sh` が張る symlink 経由でホームから
参照される。**symlink はエントリ単位で張られるため、新しいトップレベルエントリを足しても
`deploy.sh` を再実行するまでホーム側からは不可視のまま**になる。この rule は dot/ ツリーを
触る作業でだけロードする（他リポジトリでは効かない話なので `paths` でスコープする）。

### 1. 実物を読んでから書く

展開方式を説明・変更する前に `bin/deploy.sh` を Read する。以下は現時点の要約であって、
スクリプト側が変われば古くなる。記憶や本 rule の要約だけを根拠に「ここに symlink が
張られるはず」と決めない。

### 2. 展開方式は 3 パターンある

`deploy.sh` は `dot/` 直下の各エントリ名でループし、次のいずれかで symlink を張る。

| 対象 | 挙動 | 結果 |
|---|---|---|
| `MergeLinkMap` に載るもの（現状 `claude`） | ディレクトリ丸ごとではなく、**配下の各エントリを個別に** link | `dot/claude/<entry>` → `~/.claude/<entry>` |
| `CustomLocationMap` に載るもの（現状 `git` / `nvim`） | ディレクトリ丸ごとを指定先へ link | `dot/git` → `~/.config/git` |
| それ以外 | ディレクトリ／ファイル丸ごとを link | `dot/<name>` → `~/.<name>` |

`claude` が merge 方式なのは、`~/.claude` に Claude Code 自身が作る実体（`projects/`,
`sessions/`, `.credentials.json` 等）が同居しており、丸ごと差し替えられないため。

### 3. 帰結 — 何が自動反映され、何が反映されないか

- **既に linked なディレクトリの中へのファイル追加は自動反映される。** 例: `dot/claude/skills/`
  に新しい skill を足す場合、`~/.claude/skills` の symlink は既にあるので、その先の実体に
  ファイルが増えれば見える。`deploy.sh` の再実行は要らない。なお symlink が指すのは
  `deploy.sh` を走らせた checkout なので、linked worktree 側で足したファイルはその checkout
  へ merge / pull されて初めて現れる（これは deploy 方式ではなく worktree の性質による）。
- **新しいトップレベルエントリは反映されない。** 例: `dot/claude/agents/` を新設した場合、
  `~/.claude/agents` という symlink 自体が存在しないので、`deploy.sh` を再実行するまで
  ホーム側から一切見えない。`dot/` 直下に新しいディレクトリを足した場合（→ `~/.<name>`）も同じ。

境目は「そのエントリに対応する symlink が既にあるか」であって、ファイルが repo に
commit されたかではない。

### 4. したがって、新規エントリを足す変更では展開を明示する

`dot/` 配下に新しいトップレベルエントリ（`dot/<name>/` や `dot/claude/<entry>/`）を足す
変更では、`bin/deploy.sh` の再実行が要る旨を作業サマリや PR 本文に明記し、可能なら手元で
展開を確認する。

```
bin/deploy.sh
ls -ld ~/.claude/agents      # symlink が張れたか確認（エントリ自身を見る。中身の列挙は不可）
```

検証を `ls -ld`（または `readlink`）にするのは、`ls -la` だと落とし穴があるため。`ln -snvf`
の宛先が**既に実体ディレクトリとして存在する**場合、`ln` はエラーにせずそのディレクトリの
中へ symlink を作る（例: `~/.claude/agents` が実ディレクトリなら `~/.claude/agents/agents`
が作られ、`~/.claude/agents` 自体は未展開のまま黙って残る。Claude Code 自身が `agents` を
実ディレクトリとして先に作ることは現実的にありうる）。`ls -la ~/.claude/agents` はこの入れ子
symlink の行を列挙してしまい、「張れた」と誤読しうる。エントリ自身の種別を見る `ls -ld` /
`readlink` ならこの誤読を避けられる。

merge して終わりにすると、repo 上は正しいのにホーム側は未展開という乖離が残り、しかも
その乖離は「機能が黙って無いだけ」として現れるので気づきにくい。既存ディレクトリ内への
ファイル追加ではこの手当ては不要（§3 のとおり自動反映される）。

再実行には副作用もある点は把握しておく。symlink 張り自体は冪等（`ln -f` で毎回上書き）だが、
`~/.bashrc` への DOTRC ブロック追記には冪等ガードが無く、再実行のたびに同じブロックが
重複追記される（PATH 追加は case ガードで実害が薄く、`source` 行の重複も概ね無害だが、
`~/.bashrc` に cruft が積む）。Go が入っている環境では claude-queue の `make install` も
再実行のたびに走る。気になる場合は再実行後に `~/.bashrc` の重複ブロックを手で整理する。

---

由来: 委譲ランの自己内省で捕捉。`dot/claude/agents/`（`pr-judge` / `pr-fix` / `impl-light` /
`impl-standard` / `impl-heavy`）が repo に存在するのに `~/.claude/agents` が無く、
`pr-review-automerge` が指定する `pr-judge` / `pr-fix` の agent type を解決できずに
general-purpose での代替を強いられた。根本原因は個々の作業ミスではなく、「新規カテゴリ追加時に
展開経路の再実行が要る」ことがどこにも明文化されていなかった点。
