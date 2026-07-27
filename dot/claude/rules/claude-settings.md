## Claude Code settings.json 編集ルール

`.claude/settings.json` や `~/.claude/settings.json` の `permissions` を編集するときの注意。
公式仕様: <https://code.claude.com/docs/en/permissions#bash>

### Multi-wildcard pattern の罠（実測ベース）

複数の `*` を含む Bash permission rule は docs と挙動が一致しない部分がある。

| パターン | 期待 | 実際の挙動 |
|---|---|---|
| `Bash(A * B)` | `A x B` にマッチ | OK |
| `Bash(A * B *)` | `A x B`（trailing 無し）と `A x B y`（有り）両方 | **trailing 必須**。`A x B` 単体にはマッチしない |
| `Bash(A * B:*)` | docs では `A * B *` と等価のはず | **どの形にもマッチしない**（dead rule） |

`:*` 形が壊れているのは多重 wildcard との組み合わせのみ。単一 wildcard の `Bash(cmd:*)` は仕様通り機能する。

### Trailing 引数の有無を両方許可するには 2 行に分ける

```json
"Bash(git -C * status)",
"Bash(git -C * status *)"
```

### allowlist 不要（auto-allow されるもの）

以下は permission rule を書いても dead code になる。

- 組み込み read-only コマンド: `ls`, `cat`, `head`, `tail`, `grep`, `find`, `wc`, `diff`, `stat`, `du`, `cd`, および `git status`/`log`/`diff`/`show` 等の read-only サブコマンド
- 自動剥がしされる process wrapper: `timeout`, `time`, `nice`, `nohup`, `stdbuf`, （フラグ無し）`xargs`

ただし `git -C <path>` を介すると read-only サブコマンドでも auto-allow が効かなくなるので、別途 allow rule が必要。

### ファイル系 permission は Read/Edit の 2 ファミリでしか照合されない

ファイル系 permission rule はツール名単位ではなく「読み系」「書き系」の 2 ファミリで判定される。`Read(path)` が Read/Glob/Grep 等の読み取り系ツールを、`Edit(path)` が Edit/Write/MultiEdit/NotebookEdit 等の書き込み系ツールをまとめてカバーする。

| ツール名で書いた rule | 照合されるか |
|---|---|
| `Read(path)` | される（読み取り系をまとめてカバー） |
| `Edit(path)` | される（書き込み系をまとめてカバー） |
| `Write(path)` / `Glob(path)` / `NotebookEdit(path)` / `MultiEdit(path)` | **されない**。allow/deny/ask いずれで書いても起動時に警告が出る dead rule |

このため書き込み系の rule は `Edit(path)` に、読み取り系の rule は `Read(path)` に寄せる。`Write(...)` / `Glob(...)` 等の個別ツール名でパス付き rule を書いても永久にマッチしない。

なおパスを伴わない裸のツール名 deny（例: `Write`）はツール全体にマッチする一括 deny であり、この 2 ファミリ判定の対象外なので警告は出ない。

由来: PR #23 で `settings.json` から `Glob(...)` / `Write(...)` / `MultiEdit(...)` 形の dead rule 23 件を削除した際に判明。

### Hot-reload

`.claude/settings.local.json` 等の編集は再起動なしに即時反映される（実測確認）。
