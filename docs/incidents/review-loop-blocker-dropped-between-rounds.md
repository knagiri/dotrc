# review loop で前巡の blocker が次巡の verdict から黙って消え、未解決のまま収束した

## 経緯

`pr-review-loop` を回した複数の PR で、同じ形の取りこぼしが繰り返し起きた。

- 1 巡目にだけ走る専門レビュー agent が担当外の既存欠陥（例外処理で元のエラーが置き換わる、
  戻り値を見ていない、保護パスを symlink 経由ですり抜けられる等）を挙げ、判定役がそれを
  `blocker: true, out_of_scope: true`（人間の判断待ち）に仕分けた。2 巡目の判定役は同じ指摘を
  verdict に載せず（空の verdict を返した回もある）、loop は blocker 無しとして収束し、auto-merge
  まで進んだ回がある
- 2 巡目以降に判定役自身が挙げた担当外の blocker も、次巡と監査巡の判定役が載せ直さず、収束した
- 監査巡の判定役が載せ直したので止まった回もあった。前回の監査以降に修正役がコードを変えて
  いない（`AUDIT_PENDING` が下りている）ときに同じことが起きると、監査巡は走らないので止まる機会が無い
- orchestrator が別途気づいて報告に載せた回もあったが、停止報告の手順は「最後の判定 verdict」を
  参照していたので、気づかなければ報告からも落ちる

## 何を誤ったか

`blocker: true` は carryover（却下済み・「載せ直すな」）に載せず、毎巡 fresh な判定役に再判定
させる設計だった。判定 prompt は、`blocker: true` と判断した指摘は前巡と同趣旨でも毎巡自分の verdict に
載せ直すよう求めていたが、fresh な判定役は会話履歴を持たず、入力にも前巡の blocker が無い。専門レビューの
findings は 1 巡目にしか入らないので、2 巡目以降の入力は 1 巡目より狭い。載せ直すかどうかは
判定役が同じ指摘へ自力で再到達するかに依存しており、散文の指示では守りようがなかった。

## 観測

複数の委譲 session で、判定役の verdict と loop の終端（収束・auto-merge）として観測された。
transcript の生出力は残っておらず、実行したコマンドと出力は記録されていない。再現はしていない。

## 直し方

orchestrator が `blocker: true` の項目を `OPEN_BLOCKERS` として ID 付きで巡をまたいで保持し、
判定役へ `<OPEN_BLOCKERS>` として渡す。判定役は各項目を `blocker_id` 付きで載せ直すか、
`blockers_resolved` に解消の根拠を書く。どちらにも無い項目は orchestrator が未解決の blocker として
扱い続けるので、継続判定・「担当外の blocker だけが残った」の停止判定・収束条件が、判定役の
再発見に依存しなくなる。最終サマリと停止報告は `OPEN_BLOCKERS` から出す。

## 反映した規約

- `dot/claude/skills/pr-review-loop/SKILL.md` の手順 2.a-1.5「未決の blocker の保持と照合（`OPEN_BLOCKERS`）」
  （判定 verdict を得た直後、修正役の dispatch より前に照合する）、手順 2.a-3、手順 2.c 冒頭、手順 2.e、手順 3.b / 4、判定 subagent prompt の未決の blocker と verdict スキーマ、
  verdict スキーマ（orchestrator 側の判定基準）節
