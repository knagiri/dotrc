# 変異テストの後始末に `git checkout` を使い、未 commit の作業を失った

## 経緯

claude-queue の PR 監視を実装した委譲先が、テストの判別力を示すために本体のコードへ変異を
当て、後始末に `git checkout -- <path>` を使った。そのファイルには未 commit の実装が残って
おり、変異と一緒に消えた（委譲先の内省から。失った範囲と復旧の手順は記録されていない）。
変異を戻す手段が、作業の退避を兼ねていなかった。

## 観測

この doc の作成時に使い捨ての repo で再現した:

```
$ printf 'a\n' > f && git add f && git commit -qm init
$ printf 'a\nwip\n' > f            # 未 commit の作業
$ cp f f.bak                       # 退避
$ sed -i 's/a/MUTATED/' f          # 変異
$ git checkout -- f && cat f
a                                  # wip まで消えた
$ cp f.bak f && cat f && git diff --stat
a
wip
 f | 1 +
 1 file changed, 1 insertion(+)
```

`git checkout -- <path>` は index の内容に戻すので、stage していない変異前の未 commit 分も消え
（この再現では wip を stage していない）、退避したコピーからなら変異前の差分に戻る。

## 直し方

変異の前に対象ファイルのコピーを退避し、そこから戻す。戻したあと `git diff` で変異前と同じ
差分になっていることを確かめる。

## 反映先

- `dot/claude/rules/evidence-over-guesswork.md` §4「変異は退避したコピーから戻す」
