# レビュー subagent が一時ファイルを `/tmp` に作り、後始末できずに残した

## 経緯

委譲先が `pr-review-loop` を回したところ、専門レビュー agent などの subagent が diff のコピーや
変異用の退避コピーを `/tmp` に作り、後始末の `rm` が拒否されて残った（`/tmp/pr224-review`、
`/tmp/pr225.diff`、`/tmp/pr226-mut.*` など 7 件）。subagent の prompt に置き場所の指定が無く、
agent ごとに `/tmp` を選んでいた。親 session には `$CLAUDE_JOB_DIR/tmp` を使う指示があるが、
fresh context の subagent には届いていなかった。

## 観測

background の委譲 session から `general-purpose` の subagent を 1 つ起こし、その Bash で実行した
（コマンドは個別の呼び出し。承認プロンプト・拒否はどれも出なかった。subagent 側は auto mode）:

```
$ printenv CLAUDE_JOB_DIR
/home/<user>/.claude-personal/jobs/308f1a20
$ touch /home/<user>/.claude-personal/jobs/308f1a20/tmp/probe-subagent.txt   # exit 0
$ ls -l .../jobs/308f1a20/tmp/probe-subagent.txt                              # exit 0, 0 byte
$ rm /home/<user>/.claude-personal/jobs/308f1a20/tmp/probe-subagent.txt      # exit 0
$ ls .../jobs/308f1a20/tmp/probe-subagent.txt
ls: cannot access '...': No such file or directory                           # exit 2
```

subagent の `CLAUDE_JOB_DIR` は親 session と同じ値で、`tmp/` は既に存在していた。
background session でのみ確認した。interactive では `CLAUDE_JOB_DIR` は未定義。

## 直し方

subagent の prompt に「一時ファイルは `/tmp` ではなく `$CLAUDE_JOB_DIR/tmp` の下に作る」を入れる。
`$CLAUDE_JOB_DIR` が未定義だと `$CLAUDE_JOB_DIR/tmp` は空展開で `/tmp` になるので、その場合は
`mktemp -d` で専用のディレクトリを作って使う指示も添える（`TMPDIR` 未設定なら `mktemp -d` も
`/tmp` 配下に作るので、`/tmp` を避ける手段ではなく、並行する job と名前が衝突しない専用領域を
得る手段である）。既存の `/tmp` の残骸は扱わない。

## 反映先

- `dot/claude/skills/pr-review-loop/SKILL.md` 手順 2.a-0.5「dispatch の形」、「判定 subagent prompt」、
  「修正 subagent prompt」
