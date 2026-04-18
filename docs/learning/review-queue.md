# 復習キュー

間違えた問題・要復習項目を蓄積する。新しい学習セッション開始時に Claude が確認し、優先的に再出題する。

書式:

```
### [YYYY-MM-DD] Phase N / Task M — 問題の短いタイトル
**問題**: ...
**当時の回答**: ...
**模範解答の要点**: ...
**関連ノート**: [path](path)
```

正解できた問題は「待機中」から「習得済み」へ移動する。

---

## 待機中（未習得）

### [2026-04-18] Phase 1 / Task 1 — Q5(b) default の使い分け（ルート側）

**問題**: ルート側の `terraform/variables.tf` には `default = "atcoder-review"` と書いてある。なぜこちらは書くのか？

**当時の回答**: 要復習

**模範解答の要点**:
- ルートはこのプロジェクト固有の設定、再利用しない
- 毎回 `-var project_name=...` を CLI で渡すのは煩雑なので default を提供
- 役割分担: **ルート = アプリ固有の入り口**（default あり）、**モジュール = 汎用部品**（default なしで明示を強制）

**関連ノート**: [phase1/task1/06-dynamodb-module-implementation.md](phase1/task1/06-dynamodb-module-implementation.md) — Step 1 の `default` の使い分けセクション

### [2026-04-18] Phase 1 / Task 1 — Q6(b) ARN の構成要素

**問題**: ARN の構成要素を思い出せる範囲で書け（`arn:aws:...` の続き）

**当時の回答**: `(service-name):(region):(uuid)`

**模範解答の要点**:

```
arn:aws:<service>:<region>:<account-id>:<resource-path>
```

- `service`, `region` は合っていた
- `account-id` は UUID ではなく **12桁の数字**（AWSアカウント番号、例: `123456789012`）
- `resource-path`（例: `table/atcoder-review-users-prod`）が欠けていた

**関連ノート**: [phase1/task1/reference/iam-overview.md](phase1/task1/reference/iam-overview.md) — 「4. ARN」セクション

---

## 習得済み

（再出題で正解したエントリはここへ移動。日付も再出題日で更新）
