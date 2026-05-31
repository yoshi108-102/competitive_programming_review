# Phase 6 プレビュー教材: Bedrock — Claude を呼ぶ Messages API 体験

> プレビュー教材: デモ体験のために先行生成しました。正式な lesson / 振り返りクイズ / 採点は Phase 6 到達時に実施します。

---

## このサービスは何か

Amazon Bedrock は、AWS が提供するフルマネージドの **基盤モデル（Foundation Model, FM）** サービスだ。Anthropic (Claude)、Amazon (Titan/Nova)、Meta (Llama)、Mistral など複数ベンダのモデルを、**同一の AWS API 体系・IAM・VPC 境界**で利用できる。

モデル本体の管理（重みの保持・スケーリング・GPU 調達）は AWS 側が担う。利用者は API を叩くだけでよく、推論インフラを自前で持つ必要がない。

```
アプリ (Lambda 等)
    │  AWS SDK (boto3 / aws-sdk-js 等)
    ▼
Amazon Bedrock Runtime  ──→  Claude / Titan / Llama ...
    │
    IAM: bedrock:InvokeModel / bedrock:InvokeModelWithResponseStream
```

---

## いつ使うか・使わないか

| 場面 | 判断 |
|------|------|
| テキスト生成・要約・分類・コード生成を Lambda から呼びたい | **使う** |
| 複数ベンダのモデルを試してコスト/品質比較したい | **使う** |
| AWS IAM・CloudTrail・VPC で LLM アクセスを統制したい | **使う** |
| 独自データでモデルを微調整（Fine-tuning）したい | **使う**（Bedrock のカスタムモデル機能） |
| OpenAI API 互換クライアントを使い回したい | **使わない**（Bedrock は独自エンドポイント体系） |
| 推論レイテンシを極限まで下げたい（専用 GPU 常駐） | **Bedrock Provisioned Throughput** か自前 EC2 を検討 |

---

## コアコンセプト

### 基盤モデル (Foundation Model)

Bedrock が管理する推論エンドポイントの単位。モデルは **モデル ID** で指定する。

Claude モデルの ID 体系:

```
anthropic.claude-3-5-sonnet-20241022-v2:0
anthropic.claude-3-haiku-20240307-v1:0
anthropic.claude-opus-4-5               ← 最新世代はリージョン・時期で変動
```

AWS コンソール > Bedrock > "モデルアクセス" でモデルごとに利用申請が必要な点に注意。

### InvokeModel と Converse API

Bedrock Runtime には 2 つの主要な呼び出し方がある。

| | InvokeModel | Converse |
|---|---|---|
| エンドポイント | `/model/{modelId}/invoke` | `/model/{modelId}/converse` |
| リクエスト形式 | モデル固有 JSON（Claude なら Messages 形式） | Bedrock 統一スキーマ |
| マルチベンダ切替 | コード変更が必要 | モデル ID 差替えだけで可 |
| ストリーミング | InvokeModelWithResponseStream | ConverseStream |
| 向いている用途 | Claude 固有機能をフル活用 | ベンダ非依存な抽象化 |

### Messages API の形（Claude 固有）

InvokeModel で Claude を呼ぶ際のリクエスト JSON:

```json
{
  "anthropic_version": "bedrock-2023-05-31",
  "system": "あなたは AtCoder の問題を解説するアシスタントです。",
  "messages": [
    { "role": "user",      "content": "二分探索の計算量を教えてください" },
    { "role": "assistant", "content": "O(log N) です。理由は..." },
    { "role": "user",      "content": "具体例を出してください" }
  ],
  "max_tokens": 512,
  "temperature": 0.7
}
```

レスポンスの主要フィールド:

```json
{
  "content": [{ "type": "text", "text": "..." }],
  "stop_reason": "end_turn",
  "usage": { "input_tokens": 120, "output_tokens": 89 }
}
```

### temperature と max_tokens

- **temperature** (0.0〜1.0): 出力の多様性。0 に近いほど決定論的（コード生成・分類向き）、1 に近いほど創造的（アイデア生成向き）。
- **max_tokens**: 生成するトークンの上限。到達すると `stop_reason` が `"max_tokens"` になり、出力が途中で切れる。必ずレスポンスの `stop_reason` を確認すること。

### ストリーミング

`InvokeModelWithResponseStream` を使うと、チャンクごとにトークンが届くため UX が向上する。boto3 では `response["body"]` がイベントストリームになる:

```python
response = bedrock.invoke_model_with_response_stream(
    modelId="anthropic.claude-3-haiku-20240307-v1:0",
    body=json.dumps(payload),
)
for event in response["body"]:
    chunk = json.loads(event["chunk"]["bytes"])
    if chunk["type"] == "content_block_delta":
        print(chunk["delta"]["text"], end="", flush=True)
```

---

## 主要な設定・API・パラメータ

### IAM 権限

```json
{
  "Effect": "Allow",
  "Action": [
    "bedrock:InvokeModel",
    "bedrock:InvokeModelWithResponseStream"
  ],
  "Resource": "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-*"
}
```

Lambda に付与する実行ロールに上記を追加する。

### boto3 クライアント

```python
import boto3, json

bedrock = boto3.client("bedrock-runtime", region_name="ap-northeast-1")

response = bedrock.invoke_model(
    modelId="anthropic.claude-3-haiku-20240307-v1:0",
    contentType="application/json",
    accept="application/json",
    body=json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 256,
        "messages": [{"role": "user", "content": "こんにちは"}],
    }),
)
body = json.loads(response["body"].read())
print(body["content"][0]["text"])
```

### 主要パラメータ早見表

| パラメータ | 型 | 説明 | 備考 |
|---|---|---|---|
| `modelId` | string | 呼び出すモデルの ID | リージョンごとに利用可能モデルが異なる |
| `anthropic_version` | string | Bedrock 向け固定値 | `"bedrock-2023-05-31"` |
| `system` | string | システムプロンプト | messages の外に置く（Claude 3 以降） |
| `messages` | array | 会話履歴 | role は `"user"` / `"assistant"` のみ |
| `max_tokens` | integer | 最大出力トークン数 | 必須フィールド |
| `temperature` | float | 出力の多様性 | 省略時モデルデフォルト |
| `top_p` | float | 核サンプリング | temperature と同時指定は非推奨 |

---

## よくある落とし穴・誤解

**1. モデルアクセス申請を忘れる**
Bedrock はデフォルトでモデルへのアクセスが無効。コンソールで明示的に "アクセスをリクエスト" しないと `AccessDeniedException` が返る。

**2. `anthropic_version` フィールドが必要**
Anthropic の直接 API（api.anthropic.com）とは異なり、Bedrock 経由では `anthropic_version: "bedrock-2023-05-31"` を必ずリクエストに含める。

**3. `stop_reason` を確認せず出力を信頼する**
`stop_reason: "max_tokens"` の場合、テキストは途中で切れている。`max_tokens` を適切に設定するか、呼び出し側で検知して再送またはエラー返却を行う。

**4. temperature と top_p の同時指定**
Anthropic は temperature か top_p のどちらか一方だけを指定することを推奨している。両方指定すると予測不能な挙動になることがある。

**5. リージョンとモデル提供状況の齟齬**
Claude 3 Opus 等は一部リージョンでのみ利用可能。`ap-northeast-1`（東京）でのモデル提供状況は公式ページで都度確認する。

**6. InvokeModel と Converse の混在**
Converse API のリクエストスキーマは InvokeModel とは別物。`messages` の持ち方や `system` の書き方が異なるため、どちらを使うか最初に統一する。

---

## このプロジェクト（AtCoder 復習）での使いどころ

| 機能 | 説明 |
|------|------|
| 問題解説の自動生成 | ユーザーが解けなかった問題のコード + 問題文を送り、Claude に解説を生成させる |
| ヒントの段階的提示 | temperature 低め・short max_tokens で「ヒントだけ」を返す system プロンプト設計 |
| 提出コードのレビュー | 正解コードと比較して改善点を列挙させる |
| 苦手タグの分析要約 | DynamoDB から取得した提出履歴を要約し、「最近 DP の正解率が低い」などの洞察を返す |

Lambda (Phase 1 で構築済み) から直接 `bedrock-runtime` を呼ぶため、新規インフラ追加は IAM ポリシーの拡張のみ。コスト管理は CloudWatch メトリクス `InvocationLatency` + `InputTokenCount` / `OutputTokenCount` で把握できる。

---

## デモで体験したこと

`docs/learning/phase6/demo/index.html` のシミュレートされたチャットプレイグラウンドでは、左ペインの system プロンプト・messages 入力・temperature/max_tokens スライダーを操作すると、右ペインのリクエスト JSON がリアルタイムで更新される。これにより、「パラメータを変えると JSON のどのフィールドが変わるか」が視覚的に確認できた。

「送信」ボタンを押すと定型応答が 1 語ずつストリーミング表示（`setInterval` による疑似ストリーム）され、トークンが逐次届く感覚を体感できた。応答枠の下部には概算トークン数と `stop_reason`（`end_turn` / `max_tokens`）がバッジ表示され、max_tokens を小さく設定すると `stop_reason: max_tokens` で出力が途中終了することが確認できた。

InvokeModel と Converse API の違いを示す説明カードも配置されており、同じ Claude モデルでも API 体系の選択が設計の柔軟性に影響することを事前に把握できた。

---

## 公式ドキュメント（出典）

- [Amazon Bedrock とは](https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html)（閲覧日 2026-05-31）
- [Converse API を使用した推論](https://docs.aws.amazon.com/bedrock/latest/userguide/conversation-inference.html)（閲覧日 2026-05-31）
- [Anthropic Messages API リファレンス](https://docs.anthropic.com/en/api/messages)（閲覧日 2026-05-31）
- [InvokeModel — Bedrock Runtime](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-invoke.html)（閲覧日 2026-05-31）
