# エンジニアB: 長期的システム精査レビュー

## はじめに
Phase 5（レコメンド機能）までの最終形を見据え、MVP段階で「後から直すと高コストになる設計判断」を中心にレビューする。

---

## 1. DynamoDBスキーマの将来対応レビュー

### アクセスパターンの洗い出し

| Phase | アクセスパターン | 現スキーマで対応可能か |
|---|---|---|
| 1 | ユーザーの提出一覧取得 | ✅ submissions PK=USER#{userId} |
| 1 | 特定の提出詳細取得 | ✅ submissions PK=USER#{userId} SK=SUB#{id} |
| 2 | タグで問題を検索 | ⚠️ GSI1 (TAG#{tag}) あるが、difficulty ソートのSK未定義 |
| 2 | ユーザーの問題別タグ取得 | ❌ problems テーブルにユーザー概念がない |
| 3 | ユーザーの問題別レビュー取得 | ✅ reviews PK=USER#{userId} SK=REVIEW#{problemId} |
| 3 | チャット履歴の取得 | ⚠️ reviews テーブルの chat_history が1アイテムに収まるか |
| 4 | タグ別正答率の集計 | ❌ 集計用のアクセスパターンが未考慮 |
| 4 | difficulty別分布 | ❌ submissionsにdifficulty情報がない |
| 5 | 未解決問題の取得 | ❌ 「ユーザーが解いていない問題」を効率的に取得する手段がない |

### 指摘事項

#### 【重要】submissions テーブルに problem の difficulty / tags を非正規化すべき
Phase 4 でタグ別正答率を出すには、submissions と problems を結合する必要がある。DynamoDB には JOIN がないため、以下のいずれかが必要:
- **案A**: submissions に difficulty, tags を非正規化して保存（推奨）
- **案B**: アプリ側で2テーブルをクエリして結合（コスト・複雑さ増）

→ **MVP段階での提言**: submissions 保存時に difficulty を一緒に保存する設計にしておく

#### 【重要】problems テーブルの GSI1 設計が不十分
現設計: `GSI1 PK: TAG#{tag}` だがSKが未定義。
- Phase 2: タグ + difficulty でフィルタリングしたい → `GSI1 SK: DIFFICULTY#{difficulty}` を追加
- Phase 5: 未解決問題の抽出 → problems テーブルだけでは不可能、ユーザーごとの解答状況が必要

→ **提言**: GSI1 の SK を `DIFFICULTY#{difficulty}` に設定。Phase 5 用には別途検討が必要。

#### 【注意】chat_history のサイズ問題
Phase 3 のチャット履歴を reviews テーブルの1アイテムに入れると、DynamoDB の 400KB 制限に抵触する可能性がある。
→ **提言**: MVP段階では対処不要だが、reviews テーブルの chat_history は将来的に別テーブルまたは S3 に分離する前提で設計する。

---

## 2. API設計の拡張性

### Phase 1-5 で必要になる全APIエンドポイント予測

```
Phase 1:
  POST   /users/me                    # ユーザー設定
  POST   /submissions/sync            # 提出同期
  GET    /submissions                  # 提出一覧

Phase 2:
  POST   /problems/{id}/tags          # タグ追加（手動）
  POST   /problems/{id}/auto-tag      # タグ自動生成（Bedrock）
  GET    /problems?tag=xxx&diff=xxx   # 問題検索

Phase 3:
  POST   /reviews/{problemId}/chat    # チャット送信
  GET    /reviews/{problemId}         # レビュー取得
  PUT    /reviews/{problemId}/memo    # メモ更新

Phase 4:
  GET    /dashboard/stats             # 集計データ取得
  GET    /dashboard/weakness          # 弱点分析

Phase 5:
  GET    /recommendations             # レコメンド取得
```

### 設計上の提言

#### レスポンス形式を統一する
```json
{
  "data": { ... },
  "meta": {
    "nextToken": "xxx",
    "totalCount": 100
  }
}
```
→ **MVP段階で確定すべき。** 後から変えるとフロントの全API呼び出しに影響する。

#### エラーレスポンス形式も統一する
```json
{
  "error": {
    "code": "SUBMISSION_SYNC_IN_PROGRESS",
    "message": "同期処理が既に実行中です"
  }
}
```

#### API バージョニング
MVP段階では `/v1/` プレフィックスは不要（個人プロジェクトのため）。ただし、API Gateway のステージ機能で `prod` / `dev` を分けておくと便利。

---

## 3. Bedrock 統合の準備

### MVP段階で準備すべきこと

#### Terraform に Bedrock のIAMポリシーを追加する必要はまだない
Phase 2 で追加すればよい。ただし、Lambda の IAM ロール設計を拡張しやすくしておく。

#### source_code の保存形式に注意
Phase 2-3 で Bedrock に提出コードを渡す際、以下の情報がセットで必要:
- 問題文（Phase 2 で取得開始）
- 提出コード
- 判定結果
- 言語情報

→ **MVP段階での提言**: submissions テーブルに `language` を確実に保存する（AtCoder Problems APIから取得可能）。問題文の取得はPhase 2だが、`problem_id` と `contest_id` が正しく保存されていれば後から紐付け可能。

#### Bedrock のモデルアクセス申請
- Amazon Bedrock でClaude を使うにはモデルアクセスの有効化が必要
- MVP開発中に申請しておくと Phase 2 への移行がスムーズ
→ **提言**: MVP開発開始時にBedrockのモデルアクセスを申請しておく（数日かかる場合がある）

---

## 4. スケーラビリティとコスト最適化

### データ量の見積もり
- 一般的なAtCoderユーザー: 500〜5,000件の提出
- ヘビーユーザー: 10,000〜30,000件
- 1提出あたりのデータサイズ:
  - メタデータのみ: ~500B
  - source_code含む: ~5KB〜50KB（平均10KB想定）
- 1ユーザーの最大データ量: 30,000 × 10KB = 300MB

### DynamoDB コスト
- オンデマンド: 書き込み $1.25/100万WCU、読み取り $0.25/100万RCU
- 個人利用なら月$1以下で収まる
- **注意**: 初回の大量同期（数千件の書き込み）で一時的にコストが跳ねる可能性 → バッチ書き込み（`BatchWriteItem`）で最適化

### Lambda コールドスタート
- Python Lambda: コールドスタート ~1-2秒
- 個人利用なら許容範囲
- Phase 3 のチャットAPIでは体感が悪くなる可能性 → Phase 3 で Provisioned Concurrency を検討

### 提言
- MVP段階ではコスト最適化は不要、オンデマンドで十分
- `BatchWriteItem` (25件ずつ) は sync_submissions で最初から使うべき（パフォーマンスと書き込みコスト最適化のため）

---

## 5. セキュリティとデータ保護

### AtCoder利用規約との整合性
- AtCoder Problems APIは公開API（kenkoooo氏が運営）で、利用制限は「常識的な範囲」
- AtCoder本体のスクレイピングは利用規約で明示的に禁止されていない（2024年時点）が、グレーゾーン
- **提言**:
  - ユーザー自身の提出コードのみを取得する（他ユーザーのコードは取得しない）
  - レート制限を厳守（2秒以上の間隔）
  - AtCoder側からブロックされた場合の fallback を用意（エラーメッセージ表示のみでOK）
  - robots.txt を確認し、クロール禁止パスにはアクセスしない

### ユーザーデータの保護
- Cognito で認証されたユーザーのみがデータにアクセスできる（API Gateway Authorizer）
- DynamoDB のデータは AWS が自動で暗号化（encryption at rest）
- **注意**: API Gateway → Lambda 間で `userId` を Cognito JWT の `sub` クレームから取得すること（リクエストボディから取得すると他ユーザーのデータにアクセス可能になる）

### 提言
- Lambda 内で `event['requestContext']['authorizer']['claims']['sub']` から userId を取得する設計を徹底
- フロントエンドに AWS 認証情報（Access Key 等）を絶対に含めない
- Terraform の state ファイル（S3）にアクセス制限を設定

---

## 6. MVP段階での具体的な提言まとめ

### 必須（やらないと後で痛い）

1. **APIレスポンス形式を統一する** — `{ data, meta }` 形式。後から変えるとフロント全体に影響
2. **userId は必ず Cognito JWT の sub から取得する** — セキュリティの基本。リクエストボディからの取得は禁止
3. **submissions 保存時に difficulty も非正規化して保存する** — Phase 4 の集計で JOIN が必要になる
4. **BatchWriteItem を使う** — 大量同期時のパフォーマンスとコスト
5. **Lambda の IAM ロールを機能単位で分離する** — sync 用と get 用で別ロール（最小権限の原則）

### 推奨（やっておくとスムーズ）

6. **Bedrock のモデルアクセスを早めに申請** — 審査に時間がかかる場合がある
7. **AtCoder Problems API のレスポンスを型定義しておく** — Python の TypedDict or dataclass で
8. **Terraform の出力値を整理する** — API Gateway URL, Cognito Pool ID 等をoutputsに
9. **`from_second` パラメータを users テーブルに保存** — 差分同期のため、最後に同期した時刻を記録
10. **ログ出力を構造化する** — Lambda 内で `json.dumps()` 形式のログ → CloudWatch Logs Insights で検索しやすい

### 不要（MVPでやると過剰）

- API バージョニング（`/v1/`）
- DynamoDB の Provisioned Capacity
- Lambda の Provisioned Concurrency
- WAF / Rate Limiting（個人利用のため）
- 複雑なエラーリトライ機構
- テーブルの暗号化キーのカスタマイズ（AWS管理キーで十分）
