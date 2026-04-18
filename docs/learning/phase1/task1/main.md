# Phase 1 / Task 1: Terraform DynamoDB モジュール — 学習ノート

## 概要

DynamoDBのテーブルを3つ（users, submissions, problems）Terraformで定義する。

## トピック別ノート

- [01. DynamoDB キー設計](01-dynamodb-keys.md) — PK/SK/GSIの概念、RDBとの比較、設計パターン
- [02. Terraform コード解説](02-terraform-code-walkthrough.md) — 既存コードのブロックごとの解説と質疑応答
- [03. モジュール設計パターン](03-module-design-patterns.md) — AWSサービス単位 vs 機能単位 vs 階層ハイブリッド、3つの流派と使い分け
- [04. DynamoDBのアイテム設計](04-dynamodb-item-design.md) — スキーマレスの制約と自由度、attribute宣言、Python(boto3)例、Single Table Design
- [05. ユーザーIDの正体](05-user-id-identity.md) — user_id = Cognito sub、AtCoder handleとの区別、命名判断
- [06. DynamoDBモジュール実装の設計判断ログ](06-dynamodb-module-implementation.md) — Step1〜6の設計判断まとめ、適用された原則（YAGNI、明示性、最小公開）
- [07. Terraform Bootstrapの鶏と卵問題](07-terraform-bootstrap.md) — init失敗の原因、Bootstrapパターン、prevent_destroy、use_lockfile移行
- [08. Terraform 状態ロック機構](08-terraform-state-locking.md) — tflockテーブルの役割、Conditional Write、stuck lock、force-unlock、use_lockfile方式
- [09. DynamoDB = 分散ハッシュテーブルという視点](09-dynamodb-as-hashtable.md) — DHTメンタルモデル、Dynamo論文、PK部分一致不可の原理、SKがソート可能型のみの理由、PK/SK非対称性、Inverted GSI

## リファレンス

- [DynamoDB キー設計 vs RDB 比較リファレンス](reference/dynamodb-keys-vs-rdb.md) — 詳細比較、Web検索ソース付き
- [Terraform 基礎リファレンス](reference/terraform-basics.md) — HCL構文、variable/output/resource、backend、モジュール連携
- [AWS認証のベストプラクティス](reference/aws-authentication.md) — IAM Identity Center、IAMロール、アクセスキーの比較
- [IAM概要](reference/iam-overview.md) — ユーザー/グループ/ロール/ポリシー、ARN、信頼ポリシー、最小権限の原則
- [Dynamo論文と分散ハッシュテーブル](reference/dynamo-paper-dht.md) — SOSP 2007論文、Consistent Hashing、Vector Clock、Quorum、Gossip、Dynamo vs DynamoDB

## 振り返り（クイズ形式）

回答は各問の下に記入。採点・補足は Claude が `/learning-flow:next` 実行時に行う。

### Q1. DynamoDB キー設計

  submissions テーブルは PK=user_id, SK=submission_id にした。

  - (a) なぜ PK だけでなく SK も必要だったか？
  - (b) 逆に users テーブルは PK のみにした理由は？

  (a): ソートとか範囲検索とかするため？アルゴリズム的な必要性はよくわからない
  (b):usersテーブルはユースケースの関係上、単体取得しかありえないから

Q2. GSI の意義

  problems テーブルに TagDifficultyIndex (tag + difficulty) の GSI を張った。

  - (a) もしこの GSI がなかったら「タグ=DP, 難易度=1200 の問題を一覧取得」するクエリはどう動く？（どんな問題が起きる？）
  - (b) projection_type = "ALL" と KEYS_ONLY の違い、それぞれのトレードオフは？

  (a) 今回はPK=user_id,SK=submission_idであり、DynamoDBではPKもしくはSKでなければ検索が不可能。そのため、全探索して1件ずつ処理するしかなくなる。
  (b) projection_typeは、GSIを使用したときに新しくコピーされるテーブルの要素を定める。ALLの場合全ての要素がコピーされるためAWSコストがかさむが、対応力が高い。KEYS_ONLY属性の場合、PKと投影したインデックスキーのみがコピーされるためコストが低い。

Q3. スキーマレス

  attribute ブロックには PK / SK / GSI のキーで使う属性だけ書く。

  - (a) もし users テーブルで「email もキーじゃないけど attribute ブロックに書いておこう」とした場合、何が起きる？
  - (b) Lambda から boto3 で put_item するとき、Terraform に宣言していない属性（created_at 等）は自由に入れられる？ その根拠は？

(a): terraformでエラーを吐く。
(b): DynamoDBはスキーマレスの構造なので、キーさえちゃんと指定していれば当然自由に入れることが可能。

Q4. Terraform モジュール構造

  variables.tf / main.tf / outputs.tf の3ファイル。

  - (a) Terraform エンジンにとって、この3分割は必須か？
  - (b) それでも分ける理由を1つ挙げるなら？

(a): 問題文bがほとんど答えを言っているが、必須ではない。
(b): 可読性の向上。

Q5. default の使い分け

- (a) モジュール側の variables.tf には default を書かなかった。なぜ？
- (b) ルート側の terraform/variables.tf には default = "atcoder-review" と書いてある。なぜこちらは書くのか？

(a): defaultはmainに書くものだから。
(b): 要復習

Q6. ARN

- (a) テーブル名（name）とARN、IAM ポリシーの Resource に書くのはどっち？ 理由は？
- (b) ARN の構成要素を思い出せる範囲で（arn:aws:... の続き）
(a): ARN。テーブルは一意ではないが、ARNは絶対に一意。
(b): (service-name):(region):(uuid)？

Q7. ユーザーID

users テーブルの user_id は何を指すか？ AtCoder のハンドル名ではない、その理由を2つ挙げよ。

users_idはcognitoで生成される一意なユーザIDのこと。Atcoderのユーザ名のように、外部で変更可能なものをPKにするのは後に勝手に変更された時のリスクを考慮するとやるべきではない。また、AtCoderのアカウントを後で削除してしまった場合、存在しないIDがキーに入っていることになり、バグの元。

Q8. モジュール設計の流派

今のプロジェクトは modules/cognito/, modules/dynamodb/ のように AWSサービス単位で切っている。

- (a) これ以外の代表的な流派を1つ挙げよ
- (b) 今このプロジェクトでこの流派（AWSサービス単位）を選んだ判断理由は？

(a): ビジネスロジックごとに分ける。
(b): 学習のため。サービスごと切り出してあると初学者に見やすいから。

---

## 採点・補足（2026-04-18 採点）

| 問題 | 評価 |
|---|---|
| Q1 (a)(b) | ✅ 概ね正解 |
| Q2 (a)(b) | ✅ 正解（「Scan になる」という用語を添えて覚えると尚可） |
| Q3 (a)(b) | ✅ 正解 |
| Q4 (a)(b) | ✅ 正解 |
| **Q5 (a)** | ⚠️ 一部正解 — 下記補足 |
| **Q5 (b)** | ❌ 要復習 — 下記補足 |
| Q6 (a) | ✅ 正解 |
| **Q6 (b)** | ⚠️ 一部正解 — 下記補足 |
| Q7 | ✅ 正解（3つ目の理由「未連携ユーザーも扱える」も覚えておくと尚可） |
| Q8 (a)(b) | ✅ 正解 |

### Q5 (a) 補足: モジュール側に default を書かない理由

「default はmainに書くもの」という表現はやや曖昧。正確な本質:

- **モジュール（部品）側に default を書かない** のは、**呼び出し側に値を明示的に渡させる**ため
- モジュールは他プロジェクトで再利用する可能性のある部品
- もし default を書くと、他プロジェクトで使ったときに「何も渡さないと `atcoder-review` の名前でリソースが作られる」というバグの温床になる
- 「呼び忘れに気づかない（サイレントにデフォルトが使われる）」リスクを避ける設計

→ 詳細: [06-dynamodb-module-implementation.md](06-dynamodb-module-implementation.md) の Step 1 セクション

### Q5 (b) 補足: ルート側に default を書く理由

ルート側（`terraform/variables.tf`）には `default = "atcoder-review"` のように既定値を書く。理由:

1. **ルートはこのプロジェクト固有の設定**
   - モジュールと違って再利用しない
   - 「このプロジェクト = atcoder-review」は確定している
2. **実行時の利便性**
   - もし default を書かないと、`terraform plan` や `apply` 毎回 `-var project_name=atcoder-review` を渡す必要がある
   - CLI が煩雑になるのを避ける
3. **設計上の役割分担**
   - **ルート** = このプロジェクト固有の設定・入り口 → default で既定値を提供してOK
   - **モジュール** = 汎用部品 → default なしで呼び出し側に明示を強制

```
ルート: terraform/variables.tf (default あり)
  │
  ↓ var.project_name で参照
  │
modules.tf で module "dynamodb" に渡す
  │
  ↓ 明示的に project_name = var.project_name と渡す
  │
モジュール: modules/dynamodb/variables.tf (default なし)
```

### Q6 (b) 補足: ARN の正確な構成要素

```
arn:aws:<service>:<region>:<account-id>:<resource-path>
```

書いた答え `(service-name):(region):(uuid)` との差分:

- `service`: ✅ 正しい
- `region`: ✅ 正しい
- **`account-id`** ≠ UUID — **AWSアカウントID（12桁の数字、例: `123456789012`）**
  - UUID ではない。アカウントごとに割り振られる固定の数字
- `resource-path`: 抜けている — リソース種別/名前（例: `table/atcoder-review-users-prod`）

具体例:
```
arn:aws:dynamodb:ap-northeast-1:123456789012:table/atcoder-review-users-prod
│   │   │        │              │            │
│   │   │        │              │            └── resource-path
│   │   │        │              └── account-id (12桁数字)
│   │   │        └── region
│   │   └── service
│   └── partition (通常 aws)
└── ARN プレフィックス
```

→ 詳細: [reference/iam-overview.md](reference/iam-overview.md) の「4. ARN」セクション

## Task 1 総括

このTaskを通じて、以下を身につけた:

- **DynamoDB の設計思想**: アクセスパターンから逆算、PK/SK/GSI、スキーマレス、属性設計
- **Terraform モジュール**: variables/main/outputs の役割分担、default の使い分け、モジュール呼び出しと output 連携
- **AWS の基礎語彙**: ARN（絶対住所）、Cognito sub（不変の内部ID）、IAM role/policy との関係性
- **設計原則の適用**: YAGNI、明示性、最小公開、意図をコメントで残す

**次 Task に繋げる宿題**:
- タグ複数対応の再設計（Single Table Design の検討）
- Lambda の IAM ロールをどのモジュールに置くか（モジュール境界設計）
- submissions の SK に時系列要素を入れるか（`timestamp#submission_id`）
- `terraform apply` で実リソース化する機会（S3バックエンド認証の実運用）