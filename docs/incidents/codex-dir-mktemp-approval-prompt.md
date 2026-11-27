# codex 並走の出力 dir の作成が、承認待ちで止まりうると指摘された

## 経緯

`pr-review-loop` の専門レビューに codex の並走を足した PR を codex によるレビューにかけたところ、
出力 dir `<CODEX_DIR>` の作り方に指摘が入った。初版は `"$CLAUDE_JOB_DIR"` を含むパスへ `mktemp -d`
で作る手順で、(1) `mktemp` が allowlist に無い、(2) コマンドが変数展開を含む、の 2 点から、
allow 済みでも承認待ちで止まりうるという内容だった。

これは指摘であり、実際に承認待ちで止まったことは観測も再現もしていない。(2) は
`dot/claude/rules/bash-command-constraints.md` の「`$VAR` 変数展開」の行に基づく推論で、(1) は
`dot/claude/settings.json` の allow に当時 `Bash(mktemp *)` が無かったことを読んだ結果である。
承認待ちになった場合の帰結（委譲先が止まる等）は類推であり、確かめていない。

## 直し方

- `Bash(mktemp *)` を allow に足す
- `<CODEX_DIR>` を `mktemp -d -p /tmp codex-review.XXXXXX` で作り、パスはリテラルで書く
  （変数展開を避けるため置き場所は `/tmp` 直下になる）
- 一時ファイルの一般方針（`$CLAUDE_JOB_DIR/tmp`）の例外になるので、理由と後始末（tally の実行後、
  並走を中断した場合も `rm -rf`）を手順に明記する

## 反映先

- `dot/claude/settings.json`（`Bash(mktemp *)`）
- `dot/claude/skills/pr-review-loop/SKILL.md` 手順 2.a-0.5「codex の並走」
