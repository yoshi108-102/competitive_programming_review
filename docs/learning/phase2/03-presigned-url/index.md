# Phase 2 教材: プリサインド URL（署名付き一時アクセス）

---

## このトピックは何か

プリサインド URL（Presigned URL）は、S3 バケットへの一時的なアクセス権を URL に埋め込む仕組みです。IAM 認証情報を相手に渡さなくても、URL を知っている人だけが指定した期間だけオブジェクトを GET または PUT できます。

典型的なユースケースは次のとおりです。

- **ダウンロードリンクの発行**: バックエンドが URL を生成し、フロントエンドに返す。ユーザーは AWS 認証なしでオブジェクトを取得できる。
- **クライアントサイド直接アップロード**: フロントエンドが PUT 用の URL を使って、バックエンド（Lambda）を経由せず S3 に直接ファイルを送る。Lambda の転送コスト・ペイロードサイズ制限を回避できる。

---

## コアコンセプト

### 署名の仕組み

プリサインド URL は AWS Signature Version 4（SigV4）で署名されます。URL にはクエリパラメータとして署名に必要な情報がすべて含まれており、署名の検証は S3 側が行います。

```
https://BUCKET.s3.REGION.amazonaws.com/KEY
  ?X-Amz-Algorithm=AWS4-HMAC-SHA256
  &X-Amz-Credential=AKID%2FYYYYMMDD%2FREGION%2Fs3%2Faws4_request
  &X-Amz-Date=20260101T000000Z
  &X-Amz-Expires=3600
  &X-Amz-SignedHeaders=host
  &X-Amz-Signature=<計算済み署名値>
```

| パラメータ | 意味 |
|---|---|
| `X-Amz-Algorithm` | 署名アルゴリズム（常に `AWS4-HMAC-SHA256`） |
| `X-Amz-Credential` | 署名者の IAM エンティティ ID、日付、リージョン、サービス |
| `X-Amz-Date` | URL 生成時刻（ISO 8601 形式） |
| `X-Amz-Expires` | TTL（秒）。生成時刻からの有効期間 |
| `X-Amz-Signature` | SigV4 で計算した署名値 |

S3 は受信したリクエストの `X-Amz-Date` + `X-Amz-Expires` を現在時刻と比較し、期限切れなら 403 を返します。署名値の改ざん（パス・パラメータの変更）も 403 になります。

### 誰の権限で署名されるか

プリサインド URL は **署名した IAM エンティティの権限を借用** します。URL を使う人が IAM ポリシーを持っていなくても、署名者が `s3:GetObject` を持っていれば GET できます。逆に、署名者が持っていない権限を URL で付与することはできません。

```
署名者（Lambda 実行ロール）が s3:GetObject を持っている
  ↓
generate_presigned_url("get_object") で URL 生成
  ↓
URL を受け取ったブラウザが GET リクエスト送信
  ↓
S3 が「署名者のロールで s3:GetObject 許可あり」を確認 → 200 OK
```

### TTL と有効期限の制約

TTL（`ExpiresIn`）には署名に使う IAM エンティティの種類によって上限があります。

| 署名者 | TTL の上限 |
|---|---|
| IAM ロール（STS 一時認証情報） | **1 時間（3600 秒）** |
| IAM ユーザー（長期認証情報） | **7 日（604800 秒）** |

Lambda 実行ロールは STS 一時認証情報を使うため、上限は 1 時間です。`ExpiresIn=86400`（24 時間）を指定しても URL の有効期限はロールの認証情報が失効するまでに切り詰められます。

### GET 用と PUT 用の違い

| 操作 | boto3 の `ClientMethod` | 必要な IAM 権限（署名者側） | 用途 |
|---|---|---|---|
| GET（ダウンロード） | `"get_object"` | `s3:GetObject` | ダウンロードリンクの発行 |
| PUT（アップロード） | `"put_object"` | `s3:PutObject` | クライアント直接アップロード |

PUT 用 URL の場合、クライアントは URL に対して `Content-Type` などのヘッダーを含めてリクエストします。署名生成時に `Params` で `ContentType` を指定すると、URL を使う際にそのヘッダー値と一致しなければ 403 になります。

---

## 主要な設定・API・パラメータ（SDK コード例）

### GET 用 URL の生成

```python
import boto3

s3 = boto3.client("s3", region_name="ap-northeast-1")

url = s3.generate_presigned_url(
    ClientMethod="get_object",
    Params={
        "Bucket": "atcoder-review-artifacts",
        "Key": "submissions/2026/abc.json",
        # ResponseContentDisposition で download ヘッダーを強制することも可能
        # "ResponseContentDisposition": 'attachment; filename="abc.json"',
    },
    ExpiresIn=300,  # TTL: 5 分（秒単位）
)
# 返り値は文字列 URL。これをそのままクライアントに渡す。
```

### PUT 用 URL の生成

```python
url = s3.generate_presigned_url(
    ClientMethod="put_object",
    Params={
        "Bucket": "atcoder-review-artifacts",
        "Key": "uploads/user123/solution.py",
        "ContentType": "text/x-python",  # 署名に ContentType を含める
    },
    ExpiresIn=600,  # 10 分
    HttpMethod="PUT",  # PUT 用には明示的に指定する
)
```

クライアント（ブラウザ / curl）からは次のように使います。

```bash
# GET
curl -L "$URL" -o output.json

# PUT
curl -X PUT "$URL" \
  -H "Content-Type: text/x-python" \
  --data-binary @solution.py
```

### presigned_post（フォームアップロード）

ブラウザの `<form>` から直接アップロードする場合は `generate_presigned_post` を使います。

```python
response = s3.generate_presigned_post(
    Bucket="atcoder-review-artifacts",
    Key="uploads/${filename}",
    Fields={"Content-Type": "text/x-python"},
    Conditions=[
        ["content-length-range", 1, 1_048_576],  # 1 バイト〜1 MB
    ],
    ExpiresIn=600,
)
# response = {"url": "https://...", "fields": {"key": ..., "AWSAccessKeyId": ..., ...}}
```

`generate_presigned_post` では `Conditions` でファイルサイズ・Content-Type などの制約を URL に埋め込めます。`generate_presigned_url(put_object)` より細かい制御が可能です。

---

## よくある落とし穴・誤解

### 1. Lambda 実行ロールで署名した URL の TTL 上限

最も頻繁に踏む落とし穴です。`ExpiresIn=86400` を指定しても、Lambda の一時認証情報（STS）の有効期限（デフォルト最大 1 時間）が先に来ると、1 時間後に URL は使えなくなります。URL の実効 TTL は `min(ExpiresIn, 認証情報残存時間)` です。

長い TTL が必要な場合は IAM ユーザーの長期認証情報で署名するか、CloudFront Signed URL に切り替えることを検討してください。

### 2. PUT URL の Content-Type ミスマッチ

`generate_presigned_url` の `Params` に `ContentType` を入れると、その値が署名の計算に含まれます。クライアントが送る `Content-Type` ヘッダーが一致しないと S3 は 403 を返します。`Content-Type` を署名に含めたくない場合は `Params` から除外してください（ただし型チェックがなくなる）。

### 3. 期限切れ後の挙動（403 vs 401）

有効期限を過ぎた URL にアクセスすると S3 は **HTTP 403 Forbidden** を返します（401 ではありません）。エラーボディは XML で、`<Code>AccessDenied</Code>` と `<Message>Request has expired.</Message>` が含まれます。クライアント側で期限切れを判別したい場合はこのレスポンスをパースします。

### 4. 漏洩リスクと緩和

プリサインド URL は「URL を知っているだけで使える」ため、漏洩すると TTL 内は誰でも使えます。

| リスク源 | 緩和策 |
|---|---|
| ログへの URL 出力 | Lambda のロガーに URL 本体を渡さない。`--debug` モード禁止 |
| CloudWatch Logs Insights で検索可能 | ログストリームへの IAM アクセス制限 |
| TTL が長すぎる | ダウンロードリンクは 5〜15 分、アップロードは 10〜30 分程度を目安に最短設定 |
| IAM ユーザー認証情報の流出 | IAM ロールで署名する（上限 1 時間で自動制限） |

CloudFront Signed URL/Cookies に置き換えると CloudFront ディストリビューション側で即時無効化できます。S3 プリサインド URL は S3 側では無効化できません。

### 5. `BlockPublicAccess` との関係

バケットに `BlockPublicAccess` が有効でも、プリサインド URL は IAM ポリシーの認可に基づくため動作します。プリサインド URL はパブリックアクセスではなく IAM 認可のフローを使うからです。混同しないよう注意してください。

### 6. URL の改ざんは即座に 403

キー名・クエリパラメータ・バケット名を 1 文字でも変えると署名が合わなくなり 403 になります。URL を「ベースにして似た URL を作る」ようなことはできません。

---

## このプロジェクト（AtCoder 復習）での使いどころ

| ユースケース | 実装パターン |
|---|---|
| AtCoder のコード本体（数 KB〜数十 KB）を S3 に保存し、フロントエンドに一時 URL を返す | `get_object` URL を Lambda が生成 → API 経由でクライアントへ |
| ユーザーが手元のコードを S3 にアップロード | `put_object` URL をフロントが受け取り、ブラウザから直接 PUT |
| コードの差分ビュー用にダウンロードリンクを都度発行 | TTL 5〜10 分で GET URL を返すエンドポイント |

Phase 1 で DynamoDB に保存した提出データは最大 400 KB のアイテム制限があります。コード本体が大きい場合は S3 にコードを置き、DynamoDB にはそのキーだけを保持する「参照パターン」が自然です。フロントエンドはそのキーを受け取ってプリサインド URL 経由でコードを取得します。

---

## 公式ドキュメント（出典）

- [プリサインド URL を使用したオブジェクトの共有 — Amazon S3 ユーザーガイド](https://docs.aws.amazon.com/AmazonS3/latest/userguide/ShareObjectPreSignedURL.html)（閲覧日 2026-05-31）
- [プリサインド URL の使用 — Amazon S3 ユーザーガイド](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-presigned-url.html)（閲覧日 2026-05-31）
