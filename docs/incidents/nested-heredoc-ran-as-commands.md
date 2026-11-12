# heredoc で書いたスクリプトの残りがコマンドとして走った

## 経緯

委譲先 session がテストスクリプトを heredoc（`cat > file <<EOF ... EOF`）で書いた。書き込む
内容そのものが `EOF` 区切りの heredoc を含んでいたため、内側の `EOF` の行で外側の heredoc が
閉じた。残りの行は書き込まれずに bash コマンドとして実行され、空の変数が展開されて
`chmod +x /*` の形になった。`/` 直下の mode 変更は通らず、実害は無かった。

この件は委譲先の報告による。元 session のコマンドと出力は手元に無く、`chmod +x /*` に化けた
こと自体は再現していない。

## 観測

この doc の作成時に、scratch dir で `echo` だけを使って機構を再現した。`run.sh` は、内側に
heredoc を持つ `gen.sh` を heredoc で書き出すつもりのスクリプト:

```
$ cat run.sh
cat > gen.sh <<EOF
echo "line 1 of gen.sh"
cat > inner.txt <<EOF
inner body
EOF
echo "outer continues: target=[\$dir/x]"
echo "expanded now: [$dir/x]"
EOF
$ bash run.sh; echo "exit=$?"
outer continues: target=[$dir/x]
expanded now: [/x]
run.sh: line 8: EOF: command not found
exit=127
$ cat gen.sh
echo "line 1 of gen.sh"
cat > inner.txt <<EOF
inner body
$ ls
gen.sh
run.sh
```

- `gen.sh` は内側の `EOF` の手前で切れている
- 後続の 2 行は `run.sh` を実行したシェルで走った。`$dir` は未定義なので `$dir/x` が `/x` に
  なった（元の件で `chmod +x /*` に化けたのと同じ形）
- 最後の `EOF` の行もコマンドとして走って exit 127 になったが、それより前の行は既に実行済み

## 直し方

ファイルの書き込みは Write ツール（部分変更は Edit）で行う。内容がシェルを通らないので、
区切り語の衝突も `$` の展開も原理的に起きない。区切り語を固有にする案は採らなかった。
ファイル書き込み以外の heredoc（commit message を stdin で渡す等）で本文に区切り語だけの行が
入るのはまれで、規約にするほどの頻度が無いため。

## 反映先

- `dot/claude/rules/command-selection.md`「避けるべきコマンド」の表
