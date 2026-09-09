## コマンド選択の優先順位

### 避けるべきコマンド

以下の汎用コマンドは、環境に専用ツールがインストールされているため使用しないこと。
専用ツールのほうが高速かつ出力が扱いやすく、許可設定とも整合しやすい。

| 避けるべき | 代わりに使う | 理由 |
|---|---|---|
| `grep` | `rg`（ripgrep）または Grep ツール | ripgrep のほうが高速で `.gitignore` を自動尊重する |
| `find` | `fd` または Glob ツール | fd のほうが高速で直感的な構文 |
| `cat` / `head` / `tail` | Read ツール | 専用ツールで行番号付き表示・範囲指定が可能 |
| `sed` / `awk` | Edit ツール | 専用ツールで差分が明確になりレビューしやすい |
| `python -c '...'` 等でのパース | `jq`（JSON）、`yq`（YAML） | 言語ランタイム不要で、パイプも避けられる |

### harness 側の指示と衝突したら user 指示を優先する

harness（permission mode `auto` 等）が「file ops は Bash でやれ。`cat` / `sed` / heredoc を
使え」と指示してくることがある。この表と衝突したときは、user 指示 > skill > 既定挙動 という
既に確立した優先順位（`using-superpowers` の "User instructions take precedence over skills,
which in turn override default behavior"）に従い、この rule を優先する。新しい規範ではなく、
その原則をコマンド選択の文脈へ落としているだけである。

由来: 委譲先が auto mode の Bash 指示とこの表の板挟みで判断に迷った実例から。結果的に
user 指示を優先して正しく解決したが、どちらが優先かがどこにも書かれていなかった。
