# CI を持たない repo では auto-merge の有効化が clean 拒否で構造的に届かなかった

## 経緯

`pr-review-automerge` は「auto-merge を有効化したこと」を終端状態にしており、`bin/gh-automerge` は
`gh pr merge --auto --merge <PR>` だけを撃っていた。GitHub は `mergeStateStatus` が `CLEAN` の PR
への auto-merge 有効化を拒否する（待つものが何も無いので、張れる auto-merge が無い）。dotrc は
当時 GitHub Actions workflow を持たず、PR 作成直後や base 追随直後にほぼ必ず `CLEAN` へ落ちる。
結果として、独立した 2 本の委譲がいずれも同じ拒否で merge ステップを完了できずに止まった。

## 観測

`gh pr merge --auto --merge <PR>` が非 0 で終わり、stderr に次の文言が出た。

```
Pull request is in clean status
```

2 本の委譲で同じ失敗が出た。コマンド出力の全文は残っていない。

## 直し方

`bin/gh-automerge` は `--auto` の失敗の stderr に `clean status` が含まれるときだけ
`gh pr merge --merge <PR>` へ fallback する。それ以外の失敗（required check 未達、conflict、
repo で auto-merge が無効等）は fallback せず終了コードごと返す。fallback 後も branch protection は
GitHub 側が強制し、ラッパーは `--admin` 等のバイパスフラグを付けない。CI に fail が無いことの
事前確認は従来どおり呼び出し側（`pr-review-automerge`）が `gh-pr-checks` で行う。

`test/gh-wrappers.test.sh` に、clean 拒否 → fallback、clean 以外の失敗 → fallback しない、
`--auto` 成功 → 直接 merge しない、の 3 ケースを足した。

## 反映先

- `bin/gh-automerge`（header コメント）
- `dot/claude/rules/gh-commands.md`「5. merge と review thread 操作（自律レビューループ用）」
- `dot/claude/skills/pr-review-automerge/SKILL.md`（終端状態の判定に `merged` を含める）
