# 専門レビューの codex 並走

`pr-review-loop` の 1 巡目の専門レビュー（手順 2.a-0.5）で、pr-review-toolkit の agent と同じ観点の
codex レビューを並走させ、判定役がどちらの指摘を採用したかをローカルのログに貯める仕組みの設計。
手順は `dot/claude/skills/pr-review-loop/SKILL.md` 手順 2.a-0.5、各コマンドの契約（入力・出力・
終了コード）は `bin/codex-review` と `bin/codex-review-tally` のヘッダが正典である。

## 目的

`pr-review-loop` の token 消費の一部を Claude の利用枠から codex（ChatGPT プラン）へ分散させたい。
委譲 session の実測では、1 巡目の専門レビュー（toolkit の agent はすべて opus）が全体の約 10〜40% を
占める。ただし置き換えてレビューが劣化するなら採らない。そこで今は codex を toolkit と**並走**させ、
置き換えたときに何を失い何を得るかのデータを貯める。toolkit 側を外すかはデータを見て人間が判断し、
別 PR で行う。判定役・修正役の codex 化は対象外である。

## 作り方

観点ごとに `codex exec` を 1 回ずつ並列に走らせる。観点の選び方は toolkit agent と同じ基準を共有し、
観点の定義も toolkit の agent 定義（インストール済みの版の本文）をそのまま codex に渡す。観点単位で
toolkit と突き合わせられ、1 回の codex が 1 観点に集中するので指摘が薄まらない。代償として PR あたり
最大 5 回 codex を呼ぶ。

退けた案は 2 つある。1 回の codex で全観点をまとめて見る案は、枠と時間は小さいが観点が浅くなりうる。
まさに比較で検出したい劣化の形なので、並走で codex の枠が足りないと分かったときの退避先として残す。
codex 内部の multi-agent で観点を分ける案は、`--ephemeral` 下で subagent の起動が黙って失敗する
（codex CLI 0.172.0 で、exit 0 のまま親が subagent の結果を捏造した要約を返すのを観測した）。
`--ephemeral` を外すと rollout の後片付けが要り、subagent の出力にスキーマも強制できない。得るものが
Claude 側の Bash 呼び出し数本の削減だけなので採らない。

## `codex-review` の形

- **read-only・ephemeral に固定し、フラグを素通ししない。** grant（`Bash(codex-review *)`）の広さを
  「PR の diff を read-only の codex に読ませる」に留めるため。素の `codex` / `codex exec` は allow
  しない
- **PR はホスト側で取得してデータとして渡す。** read-only sandbox にはネットワークが無く、codex から
  gh を叩けないため。gh の失敗は空の diff と取り違えないよう非 0 で止める
- **失敗を「指摘なし」として出さない。** codex の非 0・timeout・空出力・スキーマ不一致では stdout に
  何も出さず非 0 で終わる。空の findings 配列は、レビューが最後まで走ったときだけ意味を持つ
- **規約は codex 自身に読ませる。** cwd の repo の `CLAUDE.md` / `.claude/rules/` と global の
  `~/.claude/CLAUDE.md` / `~/.claude/rules/` を読むよう指示する。toolkit agent は Claude Code の session
  内で global の規約も暗黙に読んでいるので、比較の条件を揃えるため（置き換え後の codex にもどのみち要る）
- **独立性の不変条件は codex にも掛かる。** author の意図・HOW・担当領域は渡さない。禁止事項だけは
  制約として原文で渡す（ファイル引数）。その中身は codex へ送られるので、allow 済みのコマンドが任意の
  ローカルファイルを外部へ送る経路にならないよう、受け付けるのは固定の一時ディレクトリ（`/tmp` と
  `~/.claude/jobs`）の下のファイルに限る。`TMPDIR` 等の env から基準を取らないのは、呼び出し側が
  `~/.config` のような場所へ向けられるため

既知の限界: read-only sandbox は書き込みを塞ぐが読み取りは塞がない。PR の本文や diff に仕込まれた
指示で codex がホストのファイル（認証情報を含む）を読み、その内容を findings に書く経路は残る。
findings は判定役を経て PR 上の記録へ写りうる。同じ読み取り範囲は toolkit agent も持っているので
並走で新たに開く経路ではないが、規約を読ませる設計上 home を隔離できず、塞いでもいない。
同じ理由で、禁止事項ファイルの置き場所の制限も硬い境界ではない。呼び出し側が秘密を一時ディレクトリへ
写してから渡せば通るので、任意のパスをそのまま送れないようにする摩擦に留まる。`~/.claude/jobs` は
`CLAUDE_CONFIG_DIR` 未設定時の job の既定の置き場で、設定されていれば `/tmp` を使う。

もう 1 つ、観点の定義を読む plugin ディレクトリは env `CODEX_REVIEW_PLUGIN_ROOT` で変えられる。
`<dir>/<version>/agents/<観点>.md` の形のファイルなら codex へ送られうるので、環境を制御できる
呼び出し側には任意のファイルを送る経路が残る。禁止事項の基準だけを固定しても、この入力は塞がっていない。

観点の定義の版は、`~/.claude/plugins/installed_plugins.json` が記録する pr-review-toolkit の
`installPath` を使う。それが無ければ plugin cache で `sort -V` の最大のディレクトリに落ちるが、cache には
旧版が残りうるので installed の版と一致する保証は無い。

## 比較の数え方

`codex-review-tally` は 1 巡目の判定 verdict から、採用された指摘（`findings_to_fix` の全件と、
`findings_gated` のうち `blocker: true` のもの）を `source` の出所で分ける。判定役には、toolkit と
codex が同じ問題を指摘したら 1 項目にまとめて `source` に両方を書かせる。この指示は比較を `source`
から数えるためのもので、比較を行わない構成では不要になる。

比較は両側とも成功した観点の組だけで行う。片側が失敗した観点の指摘は `unpaired` として件数だけ数え、
toolkit だけ / codex だけには入れない。codex の失敗が「codex の取りこぼし」に数えられて判断が
偏るのを防ぐため。同じ理由で、orchestrator は全観点の終了を待ってから判定役へ進む（待たないと遅い
観点が恒常的に落ちる）。

読み方は次のとおり。

- `toolkit_only` — toolkit を外すと失う指摘。置き換えの判断で最も重い
- `codex_only` — codex を足すことで得る上乗せ
- `both` — どちらでも拾えるもの
- `unpaired` — 片側の失敗で比べられなかったもの。多ければ比較の母数が欠けている

出所が paired と unpaired の観点にまたがる項目は、paired な観点の出所だけで分類する（片側の出所が
paired でなければ、もう片側だけを持つ項目として数える）。`both` は paired な toolkit 出所と paired な
codex 出所が 1 つずつあれば成り立ち、同じ観点である必要は無い。書式の崩れた `source`（未知の観点名、
prefix の無い観点名）は分類に使わず、record の `malformed` に載せて警告する。

codex の出力は `pr` と `head_sha` を持ち、`codex-review-tally` は今の PR・head commit と一致する
出力だけを完了として数える。出力 dir は実行ごとに新しく作るが、前回の出力が混ざっても成功に
数えないための二重の備えである。

ログは `${XDG_STATE_HOME:-$HOME/.local/state}/codex-review/compare.jsonl` に、`pr-review-loop` の
1 巡目 1 回につき 1 行で追記する（同じ PR を再実行すれば行が増える）。`codex-review-tally --summary` は
行数 `records` と PR の一意数 `prs` を分けて集計する。repo の外のローカルファイルなので業務 repo の名前を
含みうる。tracked ファイル・PR 本文へは写さない。

## 既定と前提

opt-in の仕組みは持たず、codex が使える環境ではどの repo でも並走する。業務 repo のコードを codex に
送ってよいことを前提にしている。codex が無い・未ログインの環境では各観点が失敗として扱われ、
toolkit だけのレビューとして従来どおり進む。並走の失敗は収束条件にもイテレーション上限にも数えない。
