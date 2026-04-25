# Lambda の HTTP レスポンス形式と CORS / SOP の関係

## 概要

`shared/response.py` に成功・エラーのレスポンスヘルパーを作る前段として、**なぜ Lambda が `{statusCode, headers, body}` という形で返すのか**、**なぜ CORS ヘッダを毎回含める必要があるのか** を、Web セキュリティの基礎（SOP、iframe、Clickjacking）まで遡って整理する。

キーポイント:

- Lambda Proxy Integration の返り値は **ただの HTTP レスポンスを dict で表現しただけ**
- CORS は **ブラウザのデフォルト防御 (SOP) をサーバの許可宣言で緩める仕組み**
- SOP は iframe 越しの DOM アクセスにも適用される、徳丸本の主戦場
- 今回の JWT + Authorization ヘッダ方式は CSRF リスクが低いため、CORS さえ正しく設定すればセキュリティ的に守られる

## 解説

### A. Lambda Proxy Integration の返り値形

#### 問題意識

Lambda ハンドラは Python の関数だから、素直に書けばこう書きたくなる:

```python
def handler(event, context):
    submissions = [{"id": "SUB001", "result": "AC"}]
    return submissions   # ← Pythonリストを返すだけ
```

しかし実装予定の Lambda はこう書く:

```python
def handler(event, context):
    submissions = [{"id": "SUB001", "result": "AC"}]
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"data": submissions})
    }
```

この特殊な形を要求しているのが **API Gateway の統合方式**。

#### API Gateway の3つの統合方式

| 統合方式 | Lambda の返り値 | 使われ方 |
|---|---|---|
| **Lambda Proxy Integration** | `{statusCode, headers, body}` の決まった形 | **現代の主流**（今回採用） |
| Lambda Integration (Non-Proxy) | 任意の形 + API Gateway 側で変換マッピング記述 | レガシー、複雑 |
| HTTP Integration | Lambda を介さず外部 HTTP に直接プロキシ | Lambda 不使用 |

Lambda Proxy Integration の利点:

1. API Gateway 側の設定が超シンプル（変換マッピング不要）
2. Lambda 側で HTTP セマンティクス（statusCode / headers / body）を完全制御できる
3. Terraform / CDK での設定が1行で済む

代償: Lambda が「HTTP レスポンスの形」を自分で組み立てる必要がある。

#### 正確な返り値スキーマ

```python
{
    "statusCode": 200,                    # int、必須
    "headers": {                           # dict[str, str]、省略可
        "Content-Type": "application/json"
    },
    "multiValueHeaders": {                 # dict[str, list[str]]、省略可
        "Set-Cookie": ["a=1", "b=2"]       # 同名ヘッダを複数送りたいとき
    },
    "body": "...",                         # str（文字列、dict ではない）、省略可
    "isBase64Encoded": False               # バイナリ返したいとき True
}
```

#### ハマりがちな罠3つ

**罠1: `body` は文字列でなくてはならない**

```python
# ❌ dict を直接入れる
return {"statusCode": 200, "body": {"data": [...]}}

# ✅ json.dumps で文字列化
return {"statusCode": 200, "body": json.dumps({"data": [...]})}
```

**罠2: `statusCode` が無いと 500 エラー**

```python
# ❌ 普通の dict（API Gateway が statusCode を探して見つからず 500 を返す）
return {"submissions": [...]}
```

**罠3: `headers` の値は文字列限定**

```python
# ❌ 数値やリストを入れる
return {"headers": {"X-Count": 42, "X-Tags": ["a", "b"]}}
```

数値は `str(42)`、複数値は `multiValueHeaders` に入れる。

#### 実体: HTTP レスポンスそのもの

```
HTTP/1.1 200 OK                                       ← statusCode
Content-Type: application/json                        ← headers
Access-Control-Allow-Origin: *                        ← headers
Set-Cookie: a=1                                       ← multiValueHeaders
Set-Cookie: b=2                                       ← multiValueHeaders

{"data": [...]}                                       ← body
```

生の HTTP レスポンスを「1行目 / ヘッダー / ボディ」の3要素に分解して dict にしただけ。

Lambda は **シリアライズの手間を省いた簡易 HTTP サーバ**。生のソケットや Flask/FastAPI 不要で、関数1つで HTTP エンドポイントが立つのが売り。

#### 他のサーバレスプラットフォームも同じ発想

| プラットフォーム | レスポンスの形 |
|---|---|
| AWS Lambda + API Gateway | `{statusCode, headers, body}` dict |
| Cloudflare Workers | `Response(body, {status, headers})` オブジェクト |
| Vercel Edge Functions | `new Response(body, {status, headers})` |
| Google Cloud Functions (HTTP) | Express 風の `res.status(200).send(...)` |

発想は全部同じ: 「HTTPサーバの裏側を隠して、レスポンスを表現するオブジェクトだけ返させる」。

#### なぜ response.py にヘルパーを作るのか

Lambda ハンドラを複数書くと、毎回同じボイラープレート（CORS ヘッダ、Content-Type、`{data}` でラップ）を書くハメになる。ヘルパーに統一することで:

```python
# get_submissions.py
return response.success(data=submissions)

# save_user.py
return response.success(data={"ok": True})
```

と業務ロジックに集中できる。

### B. CORS ヘッダ

#### CORS とは

**CORS = Cross-Origin Resource Sharing**。ブラウザのデフォルト防御である **同一オリジンポリシー (SOP)** を緩めるための仕組み。

- **オリジン (Origin)**: `scheme://host:port` の3点セット
- **SOP**: あるオリジンの JS が別のオリジンに fetch/XHR でリクエストを送ってその結果を読むことを、**デフォルトで禁止**する

#### なぜ SOP があるのか

クロスオリジンが自由だと、悪意あるサイトによる攻撃が成立:

```
あなたが evil.com を開く
    ↓
evil.com の JS が裏で bank.com にリクエスト
    ↓
あなたは bank.com にログイン中 → Cookie が自動で送られる
    ↓
evil.com が bank.com からあなたの口座情報を取得
```

これを防ぐため、ブラウザは「**同じオリジンから来たスクリプトしか、そのオリジンのリソースを読めない**」というガードを入れている。

#### 正当なクロスオリジン通信もしたい

今回のプロジェクト:

```
フロント: http://localhost:3000    (ローカル開発時)
         https://atcoder-review.xxx.amplifyapp.com  (本番)

API:     https://xxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com  (API Gateway)
```

フロントと API のオリジンが完全に別 → SOP でデフォルト禁止。これを「**正当なクロスオリジン通信を許可する**」のが CORS。

#### CORS の仕組み

**CORS はブラウザ側で実施される防御、サーバは「許可リスト」を HTTP ヘッダで宣言するだけ**。

```
ブラウザの fetch:
  evil.com の JS が api.example.com に fetch
    ↓
ブラウザはリクエストを送る
    ↓
api.example.com がレスポンスを返す
    ↓
レスポンスに Access-Control-Allow-Origin: https://app.example.com と書かれている
    ↓
ブラウザが Origin ヘッダ（evil.com）と照合
    ↓
許可されていない → JS にレスポンスを渡さずエラーにする
```

CORS の本質: **サーバ側のセキュリティではなく、ブラウザが「サーバの許可宣言」を信用して JS からの読み取りを制御する仕組み**。

#### response.py が返す各ヘッダ

```python
"headers": {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
},
```

| ヘッダ | 意味 |
|---|---|
| `Access-Control-Allow-Origin` | どのオリジンからのアクセスを許可するか。`*` は全許可（開発OK、本番では限定推奨） |
| `Access-Control-Allow-Headers` | どの HTTP ヘッダを使って良いか。Cognito の JWT を `Authorization` で送るため必須 |
| `Access-Control-Allow-Methods` | どの HTTP メソッドを許可するか。`OPTIONS` を入れるのが重要 |

#### Preflight リクエスト

**シンプルリクエスト以外は、ブラウザが事前に OPTIONS で許可確認を送る**。

シンプルリクエスト（preflight 不要）の条件:
- メソッドが `GET` / `HEAD` / `POST` のみ
- カスタムヘッダなし（`Content-Type` が `application/x-www-form-urlencoded`, `multipart/form-data`, `text/plain` のみ）

`Authorization: Bearer xxx` を付けると即「シンプル」ではなくなるので preflight 確定:

```
ブラウザ → サーバ: OPTIONS /submissions
                  Origin: http://localhost:3000
                  Access-Control-Request-Method: GET
                  Access-Control-Request-Headers: Authorization

サーバ → ブラウザ: 200 OK
                  Access-Control-Allow-Origin: *
                  Access-Control-Allow-Methods: GET,POST,...
                  Access-Control-Allow-Headers: Content-Type,Authorization

ブラウザ: 「OK、許可されてる」
ブラウザ → サーバ: GET /submissions
                  Authorization: Bearer xxx
                  Origin: http://localhost:3000
```

2回通信が発生する。`Access-Control-Allow-Methods` に `OPTIONS` を入れないと preflight が通らない。

#### 本番で `*` はNG

開発中は `*` でもよいが、本番では具体的なオリジンを指定:

```python
# ❌ 本番で使うとリスク大
"Access-Control-Allow-Origin": "*"

# ✅ 本番: 自分のフロントのオリジンに限定
"Access-Control-Allow-Origin": "https://atcoder-review.example.com"
```

理由:
- Cookie ベース認証では `*` + `Allow-Credentials: true` が仕様上禁止
- 意図せず「誰でも使える API」として晒すことになる

JWT（`Authorization` ヘッダ）方式なら Cookie 問題は回避できるが、「許可オリジン明示」は原則守るべき。今回の学習プロジェクトでは `*` で進めて、Phase 5（CloudFront, WAF）で見直す。

#### CORS にまつわる誤解

| 誤解 | 実際 |
|---|---|
| 「CORS はサーバのセキュリティ機能」 | ❌ **ブラウザのセキュリティ機能**。curl やサーバ間通信には適用されない |
| 「CORS エラーが出るのはサーバが落ちてるから」 | ❌ サーバは正常動作、**ブラウザがレスポンスを JS に渡さない**だけ |
| 「`*` は一番甘い設定だから安全」 | ⚠️ 「許可オリジンの明示」の方が安全、`*` は Cookie 認証と併用不可 |
| 「API Gateway で CORS 有効化すれば Lambda 側で何もしなくていい」 | ⚠️ OPTIONS は Gateway 側で返るが、本番レスポンスに CORS ヘッダを**毎回含める必要**あり |

### SOP と CORS の関係（整理）

```
SOP (同一オリジンポリシー)
  └─ デフォルトで別オリジンアクセスを禁止する防御

CORS (Cross-Origin Resource Sharing)
  └─ SOP を「サーバの許可宣言」で緩める仕組み
```

- **SOP は壁**（ブラウザが建てる）
- **CORS は壁の扉**（サーバが「このオリジンなら通していい」と鍵を渡す）
- **Preflight (OPTIONS) は鍵の確認**（扉を開ける前にブラウザが「この鍵で本当に通していい?」と確認する）

### 同一オリジンの正確な定義

**`(scheme, host, port)` の 3-tuple が完全一致**したときのみ同一オリジン。

| URL A | URL B | 判定 | 理由 |
|---|---|---|---|
| `https://example.com/page1` | `https://example.com/page2` | 同一 | パスは関係ない |
| `https://example.com` | `http://example.com` | 別 | scheme 違い |
| `https://example.com` | `https://api.example.com` | 別 | **サブドメイン違いは別オリジン** |
| `https://example.com` | `https://example.com:8443` | 別 | port 違い |
| `https://example.com` | `https://example.com:443` | 同一 | `:443` は https のデフォルト |
| `http://localhost` | `http://127.0.0.1` | 別 | 文字列一致、名前解決後の IP が同じでも別 |

### iframe と DOM の詳細

#### iframe の本質

`<iframe>` は**ページの中に別の独立したブラウザウィンドウを埋め込む**タグ:

```html
<!-- parent.html: https://app.example.com -->
<iframe src="https://video.example.com/player"></iframe>
```

iframe の中には別の `window`・`document` が独立して存在する。**「ページ内ページ」ではなく「ページ内ブラウザ」**。

#### ウィンドウ階層

```js
// iframe 内の JS から見た場合
window          // ← iframe 自身
window.parent   // ← 親ページの window
window.top      // ← 最上位の window（ネストしてたら一番外）

// 親ページの JS から見た場合
const iframe = document.querySelector("iframe");
iframe.contentWindow   // ← iframe の window
iframe.contentDocument // ← iframe の document
```

#### SOP が iframe に適用される形

**同一オリジン**:

```html
<!-- https://app.example.com/parent.html -->
<iframe src="https://app.example.com/inner.html"></iframe>

<script>
  const iframe = document.querySelector('iframe');
  
  // ✅ 全部できる
  iframe.contentDocument.body.innerHTML;
  iframe.contentWindow.someFunction();
</script>
```

**別オリジン**:

```html
<!-- https://app.example.com/parent.html -->
<iframe src="https://other.com/inner.html"></iframe>

<script>
  const iframe = document.querySelector('iframe');
  
  // ❌ ブロックされる
  iframe.contentDocument;        // SecurityError or null
  iframe.contentWindow.someFunc(); // 関数が見えても呼べない
</script>
```

iframe 内部は完全にブラックボックス。

#### 別オリジンでも許される数少ない操作

| 操作 | 可否 | 備考 |
|---|---|---|
| `iframe.contentWindow.location.href = "..."` | ✅ **書き込みのみ可** | iframe を別 URL に飛ばせる |
| `iframe.contentWindow.location.href` 読み取り | ❌ | 値は読めない |
| `iframe.contentWindow.postMessage(...)` | ✅ | メッセージ送信 |
| `iframe.contentWindow.length` | ✅ | 内部の iframe 数だけは読める |
| `iframe.contentWindow.focus() / blur() / close()` | ✅ | 一部メソッド呼び出し |

「書き込みは通るが読み取りは通らない」という非対称性。例えば `location.href = ...` で飛ばすのは攻撃に使われかねないが、遷移後のURLや中身を読めないので漏洩は起きない、という設計。

#### postMessage — 唯一の正当なクロスオリジン通信手段

```js
// 親ページ (https://app.example.com)
iframe.contentWindow.postMessage(
  { type: "GREETING", text: "hello" },
  "https://other.com"   // 送り先オリジンを明示
);

// iframe 内 (https://other.com)
window.addEventListener("message", (event) => {
  // ⚠️ 送信元検証は必須
  if (event.origin !== "https://app.example.com") {
    return;
  }
  
  console.log(event.data);  // { type: "GREETING", text: "hello" }
  event.source.postMessage({type: "REPLY", ok: true}, event.origin);
});
```

必須ルール:

1. 送信時は `targetOrigin` を必ず明示（`"*"` は使わない）
2. 受信時は `event.origin` を必ず検証
3. 受信データはユーザー入力と同等に扱う（XSS対策）

#### 歴史: `document.domain` (非推奨)

```js
// 両方のページで同じ値を設定
document.domain = "example.com";
```

→ サブドメイン間で SOP を緩めて DOM アクセス可能に。Chrome 109+ でデフォルト無効化。代替は `postMessage` + CSP。

#### `sandbox` 属性

信用できない iframe に追加制限をかける:

```html
<iframe src="https://untrusted.com" sandbox></iframe>
```

`sandbox` 単独だと JS 実行不可・フォーム送信不可・ポップアップ不可・トップレベルナビゲーション不可。必要な機能だけ個別許可:

```html
<iframe src="..." sandbox="allow-scripts allow-same-origin"></iframe>
```

#### 実用例: 身近なクロスオリジンiframe

| サービス | 使い方 | 理由 |
|---|---|---|
| YouTube 埋め込み | `<iframe src="youtube.com/embed/..."></iframe>` | YouTube のプレイヤーを自サイトに |
| Stripe Elements | クレジットカード入力フォームを iframe で提供 | **カード番号が自サイトのJSに触れない** = PCI DSS 準拠が楽 |
| Disqus / コメント欄 | 外部コメントシステムを iframe で埋め込み | ユーザー管理を外部化 |
| Google reCAPTCHA | Bot 検証UIを iframe で提供 | チェックロジックが外部で守られる |
| OAuth ログイン | Google/GitHub ログインがポップアップや iframe で開く | **ログイン情報が依頼元サイトのJSから見えない** |

Stripe が iframe を使うのが典型例: カード番号が自サイトの JS から読めないので、万一自サイトに XSS があってもカード番号の窃取は成立しない。SOP が防壁として機能している。

#### Clickjacking — SOP で防げない攻撃

```html
<!-- 攻撃サイト evil.com -->
<style>
  iframe { opacity: 0; position: absolute; top: 0; left: 0; }
</style>
<div>景品を受け取る</div>
<iframe src="https://bank.com/transfer?amount=100&to=attacker"></iframe>
```

SOP は iframe 内の DOM にアクセスしているわけではなく、**見えない iframe のボタンをクリックさせているだけ**なので止められない。

**サーバ側で防御する2つの方法**:

```
# 古典
X-Frame-Options: DENY
X-Frame-Options: SAMEORIGIN

# 現代（CSP）
Content-Security-Policy: frame-ancestors 'none'
Content-Security-Policy: frame-ancestors 'self'
Content-Security-Policy: frame-ancestors 'self' https://trusted.com
```

CSP の方が柔軟で複数オリジン指定可。最新ブラウザは両方サポートだが CSP 推奨。

#### CSRF — SOP で防げないもう一つの攻撃

```
あなたが bank.com にログイン中（Cookie が設定されている）
    ↓
evil.com を開く
    ↓
evil.com の <form action="https://bank.com/transfer" method="POST"> が勝手に submit
    ↓
Cookie が自動で送られる
    ↓
bank.com が「ログイン済みユーザーからの送金」と誤認
```

**SOP は「リクエストの送信」は止めない**、ブラウザによる「レスポンスの読み取り」だけ止める。CSRF はSOPだけでは防げない。

| 認証方式 | CSRF リスク | 対策 |
|---|---|---|
| Cookie ベース認証 | **あり**（ブラウザが自動で Cookie を送る） | CSRF トークン、SameSite Cookie |
| **JWT in `Authorization` ヘッダ**（今回の方式） | **低い**（明示的に JS がヘッダに付けるので evil.com からは付けられない） | CORS の正しい設定で十分 |

今回は Cognito の JWT を `Authorization: Bearer` で送る方式なので、**CORS 設定さえ正しければセキュリティ的に守られる**。

### 今回のプロジェクトでの関連度

- **iframe は使わない**（React で SPA を作る）
- DOM/iframe 越しのセキュリティは直接は関係ない
- 将来 Bedrock や Cognito Hosted UI を iframe で統合する可能性（Phase 6）
- **自サイトが iframe で埋め込まれて Clickjacking される防御**は考慮すべき → `X-Frame-Options: DENY` か CSP を Amplify Hosting で設定すると安全

## Q&A

**Q: Lambda Proxy Integration の返り値って、要するにただの HTTP レスポンスじゃん?**

その通り。`{statusCode, headers, body}` は HTTP レスポンスを3要素に分解して dict 化しただけ。AWS 独自の謎フォーマットに見えるが、実体は標準 HTTP。

Lambda は API Gateway から見ると「HTTP サーバを装っている」と言える。生のバイト列を書き出す代わりに HTTP レスポンスの構造体を dict で返し、API Gateway が実際のバイト列に変換して送出する。Cloudflare Workers の `Response` オブジェクトや Vercel Edge の `new Response()` も発想は同じで、どれも「HTTP サーバの裏側を隠して、レスポンスを表現するオブジェクトだけ返させる」。

**Q: SOP とは?**

**SOP = Same-Origin Policy = 同一オリジンポリシー**。ブラウザのデフォルトセキュリティ機能で、以下を禁止する:

1. 別オリジンへの fetch/XHR のレスポンスを JS から読む
2. 別オリジンの iframe 内の DOM にアクセスする
3. 別オリジンのウィンドウのプロパティを読む

CORS は SOP を「サーバの許可宣言」で**緩める**仕組み。SOP は壁、CORS は壁の扉、Preflight (OPTIONS) は鍵の確認、と覚えると整理しやすい。

**Q: 同一オリジンは scheme + host + port の3要素全一致だっけ? iframe でよくトラブルになるケースも徳丸本で読んだ気がする**

両方正しい。

- **同一オリジン** = `(scheme, host, port)` の 3-tuple が完全一致したときのみ
- **サブドメインは別オリジン** (`app.example.com` と `api.example.com` は別)
- **文字列一致が基準** (`localhost` と `127.0.0.1` は別、同じIPに解決されても)
- デフォルトポート（http=80, https=443）は省略と同一

徳丸本が扱う iframe ケースは主に「Clickjacking」「CSRF」「postMessage のセキュリティ」「document.domain の危険性」等。SOP + iframe + Cookie + CSRF の絡み合いが Web 攻撃の基礎で、ここを押さえれば徳丸本で扱うほぼ全てに対応できる。

**Q: iframe と DOM について詳しく**

iframe は「ページ内ブラウザ」で、独立した `window` / `document` を持つ。

**同一オリジンの iframe**:
- 親から `iframe.contentDocument.body.innerHTML` で中身を読み書き可能
- 親の JS が iframe 内の関数を直接呼べる

**別オリジンの iframe**:
- `contentDocument` は `SecurityError` か `null`
- ほぼ全ての相互アクセスがブロック
- 例外的に許される操作: `location.href` への書き込み、`postMessage`、`length`、`focus()`

**正当な通信手段は `postMessage` のみ**。送信時は `targetOrigin` を明示、受信時は `event.origin` を検証する。

**実用例**: YouTube 埋め込み、Stripe Elements（クレジットカード入力を iframe で隔離 → 自サイトの XSS から守る）、OAuth ログイン、reCAPTCHA。

**Clickjacking** は SOP で防げない（DOM アクセスしていないため）。`X-Frame-Options: DENY` か `Content-Security-Policy: frame-ancestors` で明示的に iframe 埋め込みを拒否する。

**CSRF** も SOP で防げない（リクエストは送られるため）。JWT in `Authorization` ヘッダ方式（今回採用）ならリスクが低く、CORS の正しい設定で守られる。

## 関連

- 前のトピック: [../task2/02-pytest-fixtures-for-aws.md](../task2/02-pytest-fixtures-for-aws.md) — Lambda テスト基盤
- 議論・Q&A: [reference/cors-error-server-side-visibility.md](reference/cors-error-server-side-visibility.md) — CORS エラー時にサーバ（CloudWatch）に届いているのか
- 議論・Q&A: [reference/cors-only-blocks-reads-not-writes.md](reference/cors-only-blocks-reads-not-writes.md) — CORS は「読み取り」しか防がない / CSRF は別の層
- 議論・Q&A: [reference/samesite-cookie-and-csrf-defense.md](reference/samesite-cookie-and-csrf-defense.md) — SameSite Cookie の Lax デフォルト化 / Site vs Origin / JWT 方式との比較
- 議論・Q&A: [reference/why-cors-exists-three-actors.md](reference/why-cors-exists-three-actors.md) — 「自分で許可して自分で防ぐ」ではない / サーバ・ブラウザ・ユーザーの3者構造
- 議論・Q&A: [reference/cors-rules-are-universal-not-per-site.md](reference/cors-rules-are-universal-not-per-site.md) — Preflight = ハンドシグナル / ブラウザのCORSルールはサイト独立のホワイトリスト方式
- 議論・Q&A: [reference/preflight-bypass-via-simple-post.md](reference/preflight-bypass-via-simple-post.md) — シンプル POST で preflight を回避する設計のトレードオフ / 主防御は別の層
- 次のトピック候補（未作成）: `json.dumps(..., default=str)` の役割（DynamoDB の Decimal / datetime 対応）、`{ data, meta }` 統一形式の設計思想
- 関連する将来 Task: Task 9 (Lambda モジュール) で API Gateway 統合設定、Phase 5 (CloudFront/WAF) でオリジン限定と CSP

---

_Saved at 2026-04-20 via /learning-flow:topic_
