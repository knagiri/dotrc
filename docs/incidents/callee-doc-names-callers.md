# 参照される側のコメントが利用者を名指しし、利用者が増えて嘘になった

## 経緯

`bin/gh-pr-checks` のヘッダコメントと出力組み立て部のコメントは、自分の責務（CI の状態を
JSON で返す）に加えて、誰がどの field を読むかを書いていた。

- ヘッダ: 「Callers use this only to confirm that *nothing has failed*」と、利用者の使い方を規定
- 出力部: 「pr-review-loop and pr-automerge read has_failure and pending_count, and pr-automerge
  also reads checks[]」と、利用者と読む field を列挙

誤りは 2 段で起きた。

1. d9b5d0b（`pr-review-automerge` 時代）で、判定役が `checks[]`（`source` / `conclusion` /
   `superseded`）を読むようになった（cancelled だけが fail に効いているときに `pending` と判定
   するため）。この commit が変えたのは利用者側の SKILL.md だけで、`bin/gh-pr-checks` には触れて
   いない。コメントは差分に現れないまま古くなった。「利用する側の差分に現れない」が実際に起きた
   のはここ。
2. その後の分割（2ec5f7b、`pr-review-automerge` を `pr-review-loop` と `pr-automerge` に分割）と
   レビュー対応（6244614）では、このコメント行を直接編集した。それでも `checks[]` を読むのは
   `pr-automerge` だけという記述は残った。利用者を列挙する書き方のままでは、編集していても
   正しい列挙を保てなかった。

同じ形はほかにも見つかった。`pr-review-loop` の SKILL.md は自分の出力の行き先として
`claude-review` がログに残すことを書き、`bin/lib/gh-mise.sh` は引数を渡す唯一の利用者を
名指ししていた。また `bin/claude-review` のヘッダは、起動する claude を interactive と書いて
いたが、実際のコマンドは `claude -p`（headless）である。

## 観測

```
$ git show 6244614 -- bin/gh-pr-checks | rg '^[-+]  # '
-  # The top-level shape is fixed -- pr-review-loop and pr-automerge read has_failure,
-  # pending_count and summary -- so superseded runs are still listed and still
+  # The top-level shape is fixed -- pr-review-loop and pr-automerge read has_failure
+  # and pending_count, and pr-automerge also reads checks[] (source, conclusion,
+  # superseded, name, workflow_id, run_number) -- so superseded runs are still listed and still

$ git show bdbcc38:dot/claude/skills/pr-review-loop/SKILL.md | rg -n 'source =='
424:>   判定してよいのではなく、両 source 通しての AND 条件）: 実質的な failure（`source ==
425:>   "actions"` の `conclusion` が `failure` / `timed_out` / `startup_failure`、`source ==
427:>   無く、**かつ** `source == "actions"` の `conclusion` が `cancelled` かつ `superseded: false`
```

（行番号は bdbcc38 時点。）

## 直し方

参照される側のコメントから利用者の列挙と利用目的を外し、出力の契約（どの field を返すか）と
自分が保証しないこと（required の充足は判定しない）だけを書く形に直した。利用関係の記述が要る
場合は利用する側に置く。`bin/claude-review` の記述は headless に直した。

## 反映先

- `dot/claude/rules/doc-authoring.md`「参照される側には自分の責務だけを書く」
