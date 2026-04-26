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

### Hot-reload

`.claude/settings.local.json` 等の編集は再起動なしに即時反映される（実測確認）。
