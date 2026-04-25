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

### [2026-04-25] Phase 1 / Task 1 — Q5(b) default の使い分け（ルート側）

**問題**: ルート側の `terraform/variables.tf` には `default = "atcoder-review"` と書いてある。なぜこちらは書くのか？

**当時の回答**: 要復習

**直近の回答（2026-04-25）**: 「モジュールはそもそも再利用可能な部品だから、具体的な値は呼び出し側に書くのが筋」 — モジュール側に default を書かない理由（核心）は捉えたが、ルート側に書く積極理由（CLI で毎回 `-var` を渡すコスト回避）には触れられず → 部分正解、待機中のまま継続。

**模範解答の要点**:
- ルートはこのプロジェクト固有の設定、再利用しない
- 毎回 `-var project_name=...` を CLI で渡すのは煩雑なので default を提供
- 役割分担: **ルート = アプリ固有の入り口**（default あり）、**モジュール = 汎用部品**（default なしで明示を強制）

**関連ノート**:
- [phase1/task1/06-dynamodb-module-implementation.md](phase1/task1/06-dynamodb-module-implementation.md) — Step 1 の `default` の使い分けセクション
- [phase1/task1/reference/terraform-defaults-vs-python-defaults.md](phase1/task1/reference/terraform-defaults-vs-python-defaults.md) — ルート/モジュールの default 哲学、Python 関数 default との比較

---

## 習得済み

（再出題で正解したエントリはここへ移動。日付も再出題日で更新）

### [2026-04-25] Phase 1 / Task 1 — Q6(b) ARN の構成要素

**問題**: ARN の構成要素を思い出せる範囲で書け（`arn:aws:...` の続き）

**当時の回答（2026-04-18）**: `(service-name):(region):(uuid)` — account-id を UUID と誤認、resource-path 欠落。

**再出題の回答（2026-04-25、✅ 正解）**: `aws:service-name:region:account-id:resource-path` — 5要素すべて正しい順番・名称で書けた。

**模範解答の要点**:

```
arn:<partition>:<service>:<region>:<account-id>:<resource-path>
```

- `<partition>` はほぼ常に `aws`（中国は `aws-cn`、GovCloud は `aws-us-gov`）
- `<account-id>` は 12桁の数字（例: `123456789012`）
- `<resource-path>` のフォーマットはサービスごとに異なる（`table/foo`、`function:bar` 等）

**関連ノート**: [phase1/task1/reference/iam-overview.md](phase1/task1/reference/iam-overview.md) — 「4. ARN」セクション
