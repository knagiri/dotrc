# 登録前に不在を待ったため「background session は自動終了する」と誤記録した

## 経緯

`claude --bg` で起こした background session が、タスクを完遂したら自分で終了するかを確かめた。
roster から session が消えるまで待つループを回したところ、初回チェックで抜けたので
「完遂すれば自分で終了する」と結論した。

実際には `claude --bg` は session が roster に載る前に return する。ループは「まだ載っていない」を
「もう居ない」と読んで初回で真になっていた。session は完遂後も `idle` で約 60 分居座る。

結論だけが spec に書かれ、実行したコマンドと出力が無かったので、委譲先は誰も再現できなかった。
5 本の並列委譲を経て 8 箇所の doc へ前提として伝播し、撤回に PR 2 本を要した。

## 観測

誤った確認に使ったループ（当時の形）:

```
claude --bg ...
until ! claude agents --json | jq -e '<session が居る>'; do sleep 2; done
```

起動直後の roster にはまだ当該 session が無く、ループは 1 回目で抜けた。存在を確かめてから
待つ形にすると、完遂後も `status: idle` のまま roster に残り続けることが観測された。

## 直し方

- 不在を成功条件にする確認は、対象の存在・出現を確かめてから待機に入る
- 非同期に登録されるリソースは、起動コマンドの return を登録の証拠として扱わない
- spec / plan に実測を書くときは、実行したコマンドと観測した出力を併記する
- 委譲先は完遂しても自然終了しないので、委譲元が完了報告を受けて `claude-stop-bg` で閉じる

## 反映先

- `dot/claude/rules/evidence-over-guesswork.md`「5. 確認が空振りしていないか確かめる」
- `dot/claude/skills/delegate-to-worktree/SKILL.md` 手順 1「spec / plan に実測を書くときは…」
- `dot/claude/rules/worktree-scope.md`「6. 作業を別 worktree へ分岐する」（委譲元が閉じる）
