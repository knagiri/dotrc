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
- `<CODEX_DIR>` を job dir の下に作る。`printenv CLAUDE_JOB_DIR` で値を取り、展開済みのリテラル
  パスで `mkdir -p <値>/tmp` と `mktemp -d -p <値>/tmp codex-review.XXXXXX` を撃つ（変数展開を
  コマンドに含めない）。job が消えるときに一緒に消えるので、後始末の `rm` は手順に置かない
- `CLAUDE_JOB_DIR` が未定義（`printenv` が何も返さない。interactive session 等）のときだけ
  `mktemp -d -p /tmp codex-review.XXXXXX` にし、後始末は best-effort で `/tmp` に残りうると明記する
- `rm` の allow は足さない

## /tmp 案を取り下げた理由

最初の直しは `<CODEX_DIR>` を `/tmp` 直下に作り、後始末に `rm -rf` を指示する形だった。この PR の
review を回した auto mode の session で、その後始末の `rm -rf /tmp/codex-review.<...>` を実行したところ
permission で拒否された（`rm` は allowlist に無い）。承認待ち・拒否で止まる問題が後始末の段で
再発するので、置き場所を job dir に戻し、後始末そのものを無くした。mktemp の承認待ちは上のとおり
観測していないが、`rm` の拒否は観測した。

## 反映先

- `dot/claude/settings.json`（`Bash(mktemp *)`）
- `dot/claude/skills/pr-review-loop/SKILL.md` 手順 2.a-0.5「codex の並走」
