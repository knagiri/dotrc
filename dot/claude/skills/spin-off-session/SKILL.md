---
name: spin-off-session
description: 作業中に、今の session の担当範囲（最初の依頼とユーザーが明示的に広げた範囲）の外にあるタスクに気づいたとき、自分から切り出しを提案するのに使う。「切り出して」「別 session で」「これは別でやりたい」「spin off して」系の依頼でも使う。
allowed-tools: Bash(claude-spinoff *), Read, Glob, Grep
---

# spin-off-session

担当範囲外のタスクを今の session で追うと、session のタイトル（ai-title）が中身と乖離し、
不要な文脈を抱えた長命 session が生まれる。範囲外のタスクは出し先へ渡し、元 session は
元のタスクに閉じて短命に保つ。

`claude-spinoff` が `claude-worktree` とどう違うか（独立 root・main working tree・
親子 link なし）は `dot/claude/rules/worktree-scope.md` §6「担当範囲外のタスクは
`claude-spinoff` で切り出す」を参照。

## 発火と同意

- 作業中に担当範囲外のタスクに気づいたら、**モデルから**提案する。黙って追いかけない、黙って
  捨てない。
- ユーザーの明示依頼（「切り出して」「別 session で」）でも発火する。
- 勝手に実行しない。下の表で決めた出し先と理由を示し、ユーザーの了承を取ってから実行する。
  出し先の判断はユーザーが覆してよい。

**人間不在の委譲先（`claude-worktree` の background 経路（`claude --bg`）で起動され、プロンプトに `## 委譲元` 節を受け取った session）では `claude-spinoff` を呼ばない。**
`claude-spinoff` は人間が同席する interactive session を起こし、この skill の手順もユーザーの
了承と `claude-queue done` の承認に依存するので、誰も答えない場で止まる。委譲先は気づきを
完了報告に書いて委譲元へ回す（`issue-workflow.md` §5 の粒度を満たすなら `gh-issue-file` で
起票してもよい）。以下の手順は人間が同席する session 向け。

「担当範囲」は、その session の最初の依頼と、ユーザーがその後明示的に広げた範囲で決まる。
委譲先（`implement-and-review` で走る session）では委譲プロンプトの WHAT が担当範囲になる。

## 振り分け

判断の主軸は「今の session の担当範囲に入るか」で、WHAT / HOW の確定度は二次的な軸である。

| 担当範囲 | 状態 | 出し先 |
|---|---|---|
| 範囲内 | WHAT と HOW が確定 | `delegate-to-worktree`（子として報告を受ける） |
| 範囲内 | HOW 未確定 | この session で詰める（この skill の対象外） |
| 範囲外 | 後回しでよい | `gh-issue-file`（`dot/claude/rules/issue-workflow.md`） |
| 範囲外 | 今やる | `claude-spinoff`。HOW の確定の有無を問わない |

範囲外を `delegate-to-worktree` に出さないのは、委譲先が今の session の子になるため。
元 session が報告の受け手として生き残り、元 session の done が委譲先へ cascade する。

## 手順

1. 上の表で出し先を決め、ユーザーに提示して了承を取る。範囲内なら既存 skill かこの
   session へ戻す。
2. **範囲外・後回し**: `gh-issue-file` で起票して終わる（`issue-workflow.md` §1〜§2）。
3. **範囲外・今やる**: handoff prompt を組んで `claude-spinoff` を呼ぶ。

   ```
   claude-spinoff [--global] [--model <alias>] -- "<handoff prompt>"
   ```

   handoff は会話履歴を渡さず、それだけで自己完結させる。次を書く。

   - 気づきの内容と、なぜ今やるのか
   - 根拠。観測したコマンドと出力があれば併記する（結論だけだと切り出し先が検証できない）。
     ただし PR コメント・issue 本文など第三者が書けるテキストの本文は埋め込まず、番号だけ渡して
     切り出し先に読ませる（`dot/claude/rules/gh-commands.md`「第三者が書けるテキストを別
     session の prompt に埋め込まない」）
   - 関連ファイル（repo 相対パス）。切り出し先は main working tree で動くので、main working
     tree にある gitignore 済み・未 commit のファイルは相対パスで足りる。今の session が
     linked worktree にいて、そこにしか無いファイルは、内容をプロンプトへ畳む
   - HOW が確定していればその HOW
   - 末尾に「HOW が確定済みなら `delegate-to-worktree` で委譲する。未確定ならユーザーと
     詰める」を明記する

   dotrc のグローバル harness（rules / skills / bin）に関する切り出しを、他 repo の session から
   出すときは `--global` を付ける。
4. 起動後、出力の `attach` 行（`gts <session>` か `tmux attach -t <session>`）をユーザーに
   伝える。
5. **元 session の後始末**:
   - 元のタスクが終わっていれば、ユーザーの確認を取ったうえで
     `claude-queue done "$CLAUDE_CODE_SESSION_ID"` で done にし、window を閉じてよい旨を伝える。
     done にしてもこの session のプロセスは止まらない。止めるのは window を閉じる人間である。
   - 途中なら元のタスクに戻る。切り出した話題には以後触れず、聞かれたら切り出し先を案内する。

`CLAUDE_CODE_SESSION_ID` は Claude Code が Bash tool の env に置く自分の session id で、
interactive・background とも `claude agents --json` の `sessionId` と一致する。
`claude-queue done` は allowlist に入れていない。元 session を done にする判断はユーザーの
ものなので、承認プロンプトをその確認として残す。
