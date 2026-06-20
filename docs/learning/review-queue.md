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

### [2026-05-09] Phase 1 / Task 3 — Q1 Lambda Proxy Integration の body に dict を渡すとどうなるか

**問題**: Lambda ハンドラで `return {"statusCode": 200, "body": {"data": [{"id": "SUB001"}]}}` のように body に dict をそのまま渡した場合、クライアントには何が見えるか。理由も述べよ。

**当時の回答（2026-05-09）**: 「Lambda内部で加工されるため、HTTPレスポンスの形に加工されて見える。」 — 誤答。自動 JSON 化はされない。

**模範解答の要点**:
- API Gateway は **502 Bad Gateway**（`Internal server error` / CloudWatch には `Malformed Lambda proxy response`）を返す
- API Gateway Lambda Proxy Integration のコントラクトは `body` が **文字列必須**。dict は許容されない
- したがって全 Lambda ハンドラで `body=json.dumps(...)` を必ず通す必要があり、これが `shared/response.py` の存在意義（書き忘れ防止）
- `json.dumps(..., default=str)` で Decimal / datetime を文字列化する慣用パターンも合わせて押さえる

**参考**:
- [Lambda Proxy Integration - AWS Docs](https://docs.aws.amazon.com/apigateway/latest/developerguide/set-up-lambda-proxy-integrations.html)

**関連ノート**: [phase1/task2/02-lambda-proxy-integration-and-cors.md](phase1/task2/02-lambda-proxy-integration-and-cors.md) — A. Lambda Proxy Integration の返り値形

---

### [2026-05-09] Phase 1 / Task 3 — Q3 CORS の防御主体（サーバ側 Origin チェックで十分か）

**問題**: 「サーバが Origin ヘッダを見て、許可リストに無いオリジンからのリクエストを拒否すれば、ブラウザに頼らなくても同等の防御になるのでは？」という主張の問題点を説明せよ。

**当時の回答（2026-05-09）**: 「curl などを使う場合には Origin の値を任意に偽装することが可能であるため、脆弱性が高い構成になってしまうため。」 — Origin 偽装の論点は正しいが、CORS 本来の役割を取りこぼしている。

**模範解答の要点**:
- CORS の本質は「サーバの防御」ではなく「**ブラウザ上でユーザーを守る**」レイヤ。3 アクター（ユーザー/ブラウザ/サーバ）の協調防御
- 想定する攻撃: 被害者が `bank.com` にログイン中、`evil.com` を開く。`evil.com` の JS が被害者の認証 Cookie で `bank.com/api/...` を fetch しようとする → ブラウザが「クロスオリジンレスポンスを JS から読めなくする」層が CORS
- このシナリオでは Origin を付けているのは被害者のブラウザ自身（正しい `evil.com` を付与）。サーバ側 Origin チェックも一部機能はするが、CORS が担う「**応答の読み取り禁止**」というブラウザレイヤの保護を置き換えてはいない
- curl 等のブラウザ外攻撃では Origin は任意設定可能 → サーバ側チェック自体が無力
- まとめ: サーバ側チェックは **CORS の代替ではなく補助**

**参考**:
- [Origin header - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Origin)
- [Cross-Origin Resource Sharing (CORS) - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS)

**関連ノート**: [phase1/practice/reference/why-cors-exists-three-actors.md](phase1/practice/reference/why-cors-exists-three-actors.md)

---

### [2026-05-09] Phase 1 / Task 3 — Q4 JWT (Authorization: Bearer) 方式の CSRF 耐性

**問題**: Cognito JWT を `Authorization: Bearer` ヘッダで送る方式が CSRF に対して構造的に強い理由を、Cookie 認証と対比して説明せよ。また、この方式で preflight が常に発動する理由とセキュリティ上の副次的利点も述べよ。

**当時の回答（2026-05-09）**: 「わからない」 — 要復習

**模範解答の要点**:
- **Cookie 方式が CSRF に弱い構造**: ブラウザは「リクエスト先ドメイン」を基準に Cookie を**自動付与**する。`evil.com` の form から `bank.com/transfer` に POST しても、ブラウザは `bank.com` の Cookie を付けてしまう。攻撃者は Cookie を読まなくても「被害者の認証で送信」が成立する
- **JWT (Bearer) が構造的に強い理由**: `Authorization` ヘッダは **JS が明示的に付ける必要がある**。ブラウザが自動付与しない → 攻撃者ページから fetch してもヘッダ無し → サーバは未認証として弾く。つまり「**認証情報の自動送信ルートが存在しない**」のが本質
- **preflight が常に発動する理由**: `Authorization` ヘッダはカスタムヘッダ扱いで Simple Request の条件を外れる → ブラウザは本リクエスト前に `OPTIONS` プリフライトを送る
- **副次的利点**: サーバの `Access-Control-Allow-Origin` 不許可なら本リクエスト自体が届かない → 「未許可オリジンからの状態変更リクエストすら到達しない」二重防御

**参考**:
- [Cross-Site Request Forgery Prevention Cheat Sheet - OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html)
- [SameSite cookies - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie/SameSite)

**関連ノート**: [phase1/practice/reference/cors-only-blocks-reads-not-writes.md](phase1/practice/reference/cors-only-blocks-reads-not-writes.md), [phase1/practice/reference/samesite-cookie-and-csrf-defense.md](phase1/practice/reference/samesite-cookie-and-csrf-defense.md), [phase1/practice/reference/preflight-bypass-via-simple-post.md](phase1/practice/reference/preflight-bypass-via-simple-post.md)

---

## 習得済み

### [2026-05-09] Phase 1 / Task 1 — Q5(b) default の使い分け（ルート側）

**問題**: ルート側の `terraform/variables.tf` には `default = "atcoder-review"` と書いてある。なぜこちらは書くのか？

**当時の回答（2026-04-18）**: 要復習

**2回目の回答（2026-04-25）**: 「モジュールはそもそも再利用可能な部品だから、具体的な値は呼び出し側に書くのが筋」 — モジュール側に default を書かない理由は捉えたが、ルート側に書く積極理由（CLI コスト回避）に触れられず → 部分正解。

**3回目の回答（2026-05-09、✅ 正解）**: 「モジュールと違って再利用しないし、プロジェクトに対する var の値は確定しているので、煩雑な CLI コマンドを打ち込むより楽だから」 — 3要素（再利用しない・値が確定・CLI 煩雑さ回避）すべてカバー。

**模範解答の要点**:
- ルートはこのプロジェクト固有の設定、再利用しない
- 毎回 `-var project_name=...` を CLI で渡すのは煩雑なので default を提供
- 役割分担: **ルート = アプリ固有の入り口**（default あり）、**モジュール = 汎用部品**（default なしで明示を強制）

**関連ノート**:
- [phase1/task1/06-dynamodb-module-implementation.md](phase1/task1/06-dynamodb-module-implementation.md) — Step 1 の `default` の使い分けセクション
- [phase1/task1/reference/terraform-defaults-vs-python-defaults.md](phase1/task1/reference/terraform-defaults-vs-python-defaults.md) — ルート/モジュールの default 哲学、Python 関数 default との比較

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
