---
paths:
  - "**/dot/**"
  - "**/bin/deploy.sh"
  - "**/src/claude-queue/**"
---

## dotrc の展開経路（`bin/deploy.sh`）と新規エントリの落とし穴

このリポジトリ（dotrc）の `dot/` 配下は、`bin/deploy.sh` が張る symlink 経由でホームから
参照される。**symlink はエントリ単位で張られるため、新しいトップレベルエントリを足しても
`deploy.sh` を再実行するまでホーム側からは不可視のまま**になる。この rule は dotrc の
`dot/` ツリー、`bin/deploy.sh`、`src/claude-queue` を触る作業でだけロードする（他リポジトリ
では効かない話なので `paths` でスコープする）。

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
commit されたかではない。ただし symlink 経路そのものに乗らない成果物もある（§5）。

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

### 5. symlink では届かないもの — ビルド成果物は再ビルドが要る

`bin/claude-queue` は symlink ではなく `make -C src/claude-queue install` が `bin/` へ吐く
バイナリで、`.gitignore` に入っている（実体は checkout ごとのローカルビルド）。したがって
`src/claude-queue` を変更した PR を merge / pull しても、**バイナリは更新されない**。symlink
経由で反映される skill / rule（`dot/` 配下、§2〜§3）とも、`bin/deploy.sh` が `~/.bashrc` へ
PATH を追加するだけで symlink は張らない `bin/` のスクリプトとも、反映経路がそもそも違う
（`bin/deploy.sh` 冒頭を参照）。

`src/claude-queue` を触ったら、merge 後に再ビルドする。ビルド先は実行した checkout の `bin/`
（`Makefile` の `BIN` は `git rev-parse --show-toplevel` で解決する）で、ホームの PATH に
乗るのは `bin/deploy.sh` を走らせた checkout の `bin/`（§3 と同じ理屈）。委譲先 agent は既定で
linked worktree で作業するため、worktree 側で `make install` してもホームから叩かれる
バイナリは更新されない。ホーム側へ反映したいなら、`bin/deploy.sh` を走らせた checkout（通常
main の working tree）側で再ビルドするか、worktree の変更をそちらへ merge / pull してから
再ビルドする。

**linked worktree で作業している agent は、この再ビルドを checkout を跨いで自分で行わない。**
別 checkout の `bin/` への書き込みは worktree のスコープ外であり（`worktree-scope.md` §2）、
`cd` / `git -C` で checkout を渡り歩いて回避するのも承認プロンプトで詰まる
（`working-directory.md`）。merge 後に再ビルドが要る旨を委譲元・人間へ報告し、そこで止まる。

```
make -C src/claude-queue install
find src/claude-queue -name '*.go' -newer bin/claude-queue   # 出力が空ならバイナリがソースより新しい
```

ソースは直っているのにバイナリは古い、という乖離は「直したはずの挙動が直っていない」として
現れる。修正内容そのものを疑う方向へ切り分けが向かうので、原因に辿り着くまでが遠い。

---

由来: 委譲ランの自己内省で捕捉。`dot/claude/agents/`（`pr-judge` / `pr-fix` / `impl-light` /
`impl-standard` / `impl-heavy`）が repo に存在するのに `~/.claude/agents` が無く、
`pr-review-automerge` が指定する `pr-judge` / `pr-fix` の agent type を解決できずに
general-purpose での代替を強いられた。根本原因は個々の作業ミスではなく、「新規カテゴリ追加時に
展開経路の再実行が要る」ことがどこにも明文化されていなかった点。

§5 の由来: picker の `-d` 除去（PR #48）を merge した後もフォーカスが移らず、原因の切り分けに
1 往復かかった。ソースからは `-d` が消えていたが、動いていたのは merge の 57 分前にビルドした
バイナリだった。
