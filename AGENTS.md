# dotrc

- 公開 repo のため、tracked ファイル・issue・PR・commit message に勤務先由来の具体名を書かない。対象範囲と実例の一般化は [CLAUDE.md](CLAUDE.md) に従う。
- `bin/` や `test/` で deploy 済み checkout を特定する処理を扱う場合は、[linked worktree での checkout 判定](.claude/rules/deployed-checkout-toplevel.md) を読む。
- テストには `test/*.test.sh` と `make -C src/claude-queue test vet fmt-check` がある。変更箇所に対応するテストを実行する。
- PR はユーザーから依頼された場合に作成する。マージや auto-merge の設定には別途明示指示が必要。
