# スクリプトでテストを消したら隣のテストまで消えていた

## 経緯

claude-queue の PR 監視を実装した委譲先が、不要になったテストをスクリプトで消した際に、
範囲の指定がずれて隣のテストまで消していた（委譲先の内省から。どのコマンドで消したかは
記録されていない）。削除はエラーにならず、残ったテストは通るので、その場では気づけなかった。

## 観測

この doc の作成時に、行番号での削除がずれる形を使い捨てのファイルで再現した。`test_b` の
2 行（3〜4 行目）を消すつもりで、その前に別の編集で先頭へ 1 行入っていた場合:

```
$ printf 'test_a\n  body_a\ntest_b\n  body_b\ntest_c\n  body_c\n' > t   # commit 済み
$ sed -i '1i # header' t      # 先に入った別の編集
$ sed -i '3,4d' t; echo "exit=$?"
exit=0
$ git diff t
+# header
 test_a
-  body_a
-test_b
   body_b
```

sed は exit 0 で、消えたのは `test_a` の本体と `test_b` の見出しだった。`git diff` を見れば
一目で分かる。

## 直し方

複数行をスクリプトで消したら直後に `git diff` で範囲を確かめる。可能なら Edit ツールで、消す
範囲を文字列として明示する。

## 反映先

- `dot/claude/rules/command-selection.md`「スクリプトで複数行を消したら `git diff` で消えた範囲を確かめる」
