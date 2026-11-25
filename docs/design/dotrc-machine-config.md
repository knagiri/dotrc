# dotrc のマシンローカル設定

マシンごとに違う値や、public な dotrc に載せたくない値（秘密ではないが公開したくない名前など）は、
checkout の外の untracked なファイル `${XDG_CONFIG_HOME:-$HOME/.config}/dotrc/config` に置き、
`bin/lib/dotrc-config.sh` の `dotrc_config <KEY> [<default>]` で読む。各項目の意味は、それを
読む側の doc が持つ。既存の env knob（`GH_AWAIT_REVIEWS_*` 等）は動作の調整であってマシン固有の値ではないので、移さない。

## 形式と解決順

1 行 1 項目の `KEY=value`。`#` で始まる行と空行は無視し、値は最初の `=` より後ろの文字列をそのまま
使う（quote の除去も変数展開もしない）。細かな規則（空白の扱い、同じ key が複数あれば最後が勝つ等）は
lib のヘッダが正典である。

解決順は、空でない同名の環境変数 → ファイル → 呼び出し側の default。テストや一時的な切り替えは
環境変数で行う。default の無い key がどこにも無ければ、ファイルのパスと書くべき行を stderr に出して
失敗する。値の書き込みは人が行い、ラッパーも agent もこのファイルを書かない。

## source しない

ファイルは shell として実行せず、key を照合して値を文字列として取り出すだけにしている。読み手は
承認プロンプトを挟まずに動くことがあるので、`source` すると、このファイルを書き換えられる
ものが承認なしに任意のコマンドを走らせられる。`mise.db.local.toml` を paranoid trust で読むのと
同じ懸念である（`docs/design/mise-config-layering.md`）。

## mise の global config にしない

mise の global config に置くと、値が全 repo の shell・tool の env に載る。`DATABASE_URL` を常時ロード
の場所に置かないのと同じ理由である（`docs/design/mise-config-layering.md`）。加えて mise は
非対話 shell や systemd timer では activate されないので、そこから起動される crawler が読めない。
