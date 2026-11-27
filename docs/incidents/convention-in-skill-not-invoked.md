# 「呼ばない」規約を、呼ばれない skill に置いた

## 経緯

規約「grant（allowlist）変更を含む PR は auto-merge させず、人間の approve を待つ」の正典を、
`dot/claude/rules/gh-commands.md` から `dot/claude/skills/pr-automerge/SKILL.md` へ移した。
その PR の review で、規約を守る場面は `pr-automerge` を呼ばない場面なので、正典の本文が
ロードされる経路が無いと指摘された。

skill の本文は skill を呼んだときにしか読まれない。「ある作業をしないこと」を求める規約を
その作業の skill に置くと、守るべき場面（作業をしない場面）では読まれず、読まれるのは既に
作業を始めた後になる。description に「grant 変更を含む PR には使わない」と書いても、それは
呼ぶかどうかを判断する agent が grant 変更に気づいている前提で効くだけで、気づいていなければ
素通りする。

一般化した型: 『ある作業をしないこと』を求める規約は、その作業の skill に置くと読まれない。
読み落としても止まる機械的なゲートを、作業を実行する経路そのものに置く。

## 観測

ゲートを入れた `bin/gh-automerge` の merge 呼び出しだけを `echo WOULD_MERGE; exit 0` に
差し替えたコピーで、dotrc の merge 済み PR を判定させた。settings.json を変えた PR は止まり、
SKILL.md の本文だけを変えた PR は通った。

```
$ <copy>/gh-automerge <settings.json を変えた PR>
gh-automerge: #<N> contains a grant change; not merging -- wait for a human to approve it
  dot/claude/settings.json: settings file
rc=5
$ <copy>/gh-automerge <SKILL.md の本文だけを変えた PR>
WOULD_MERGE
rc=0
```

途中、frontmatter の読み出しを `printf | awk` のパイプにしていたため、awk が閉じの `---` で
読むのをやめると printf が SIGPIPE で落ち、`pipefail` で失敗扱いになって、本文だけの変更を
「比較できない」として止めていた（fail closed 側に倒れたので取りこぼしではなく過検出）。
here-string に変えて直した。

## 直し方

allowlist で許可された唯一の merge 経路である `bin/gh-automerge` に、merge の前に grant 変更を
判定するゲートを入れた。settings ファイルの変更、SKILL.md / agent 定義 / command 定義
（`.claude/commands/` と、この repo の配置の `dot/claude/commands/`）の frontmatter の変更
（新規・削除・改名・コピーを含む）、frontmatter を比べられない場合、差分や内容が読めない場合に
exit 5 で止まり、理由のファイルを stderr に出す。判定した head は `--match-head-commit` で固定する。

## 反映先

- `bin/gh-automerge` のヘッダ（ゲートの契約）
- `dot/claude/skills/pr-automerge/SKILL.md`「grant 変更を含む PR は auto-merge させない」
  「`gh-automerge` の契約」手順 5
- `docs/design/gh-wrappers.md`「`gh-automerge` の grant 変更ゲート」
- `test/gh-automerge.test.sh`
