## Bash ツールのコマンド制約

許可設定（allowlist）にマッチせず **毎回ユーザーの手動承認が必要になる** ケースを避ける。
詳細仕様: <https://code.claude.com/docs/en/permissions>

### 承認が必要になるパターン

| パターン | 例 | 代替 |
|---|---|---|
| `$VAR` 変数展開 | `git -C $PWD status` | リテラルで書く（cwd ならそのまま `git status`） |
| バックスラッシュエスケープ空白 | `cd Application\ Support` | ダブルクォートで囲む（`"Application Support"`） |
| 自動剥がしされない process wrapper | `npx`, `docker exec`, `devbox run`, `watch`, `setsid`, `find -exec`, `find -delete` | ツールを直接インストールするか、末端まで具体化した allow ルールを足す（`Bash(npx tool *)` ではなく `Bash(npx prettier --check .)`） |
| allowlist 外かつ組み込み read-only でないコマンド | `tar`, `gzip`, `mv` 等 | allow ルールを追加する、または専用ツールで代替する |

### 複合コマンドはサブコマンド単位で評価される

`\|`, `&&`, `\|\|`, `;`, `\|&`, `&`, 改行 はそれ自体では承認トリガーにならない。Claude Code はシェル演算子を構造的にパースし、各サブコマンドが allow ルールまたは組み込み read-only リストに含まれていれば承認なしで実行される。`$()` 内のコマンドも独立に評価される。

例: `echo foo | tr a-z A-Z` は `echo`/`tr` がともに allow にあれば通る。`echo "$(date +%Y)"` も同様。

サブコマンドのうち一つでも未許可だったり変数展開を含めば、その時点で承認要求になる。

### 組み込み read-only コマンド（allowlist 不要）

`ls`, `cat`, `head`, `tail`, `grep`, `find`, `wc`, `diff`, `stat`, `du`, `cd`, および `git status`/`log`/`diff`/`show` 等の read-only サブコマンドは組み込みで承認なしに実行される。設定変更不可。

### 自動剥がしされる process wrapper

`timeout`, `time`, `nice`, `nohup`, `stdbuf`, フラグ無しの `xargs` は照合前に剥がされ、内側コマンドだけが allowlist と突き合わされる。例えば `Bash(npm test *)` を allow しておけば `timeout 30 npm test` も承認なしで通る。

### その他の代替手段

- 複数コマンドの実行: 個別の Bash 呼び出しに分け、依存がなければ並列で投げる
- バックグラウンド化（`setsid`, `nohup`）: Bash ツールの `run_in_background: true` を使う
- 周期実行（`watch`）: `/loop` skill を利用
- `find -exec` / `-delete`: `find ... -print` の出力を bare `xargs` に渡す（`xargs` は剥がされて内側コマンドで照合される）
