# CORS エラー時、サーバ側（CloudWatch）には届いているのか？

> 種別: ユーザー議論・Q&A の記録（Phase 1 / Task 3）
> 関連教材: [01-lambda-response-format-and-cors.md](../01-lambda-response-format-and-cors.md)

## 論点

「CORS はブラウザ側のセキュリティ機能」と説明された直後、ユーザーから次の問いが出た:

> ブラウザのセキュリティだったのか。ということは、CORSエラーが発生した時に CloudWatch 見ても信号は届いていないわけね

直感的には自然な解釈だが、**実際は逆で「ほとんどのケースで届いている」**。これが CORS デバッグの典型的な落とし穴。

「ブラウザが守る」 = 「リクエストがブラウザから出ない」と誤解されやすいが、実際は「リクエストは出る、でもレスポンスを JS に渡さない」という事後制御。

## Q&A

**Q1: CORS エラーが出たとき、サーバ（Lambda / CloudWatch）には何も届いていない？**

ほとんどのケースで**届いている**。CORS の仕組みを正確に分解するとこう:

```
1. ブラウザは fetch を呼ぶ
2. ブラウザはリクエストを送信する  ← ★ ここで届く
3. サーバは普通にリクエストを処理してレスポンスを返す
4. ブラウザがレスポンスのヘッダを見る
5. Access-Control-Allow-Origin が合わない
6. ブラウザが「JS にレスポンスを渡さない」 → CORS エラー
```

リクエスト自体は送られていて、Lambda は普通に動く。CloudWatch には:

- API Gateway のアクセスログ → 記録あり
- Lambda の実行ログ → 普通に実行された記録あり
- DynamoDB に書き込みする処理だったら、**実データが書き込まれている**

ブラウザが「JS にレスポンスを渡さない」のは事後処理なので、サーバ側からは「成功して 200 を返した」ようにしか見えない。

**Q2: じゃあ「ブラウザのセキュリティ機能」とはどういう意味？**

**「リクエストの送信を止める」のではなく、「レスポンスを JS に読ませない」**ことで防御している、という意味。

SOP / CORS は元々、悪意あるサイト（evil.com）が他サイトのデータを「読み取って盗む」ことを防ぐのが目的。だから「読み取り」を止めれば目的は達成される。リクエスト自体を止めようとすると、画像表示・フォーム送信など正当な機能まで巻き添えになる。

「データ漏洩防止」を「読み取り制御」で実現している、というのが CORS / SOP の設計思想。

**Q3: デバッグのときに気をつけることは？**

「フロント側 CORS エラー / バックエンド側 200 OK」が**両方同時に正しい**状況がある、と知っておく。典型的な噛み合わない会話:

```
フロント開発者: 「CORS エラーで失敗してる」
バックエンド開発者: 「CloudWatch 見たら 200 で正常終了してる」
                    → 両者の言い分が噛み合わない
```

これは両方正しい。サーバから見れば 200、ブラウザから見ればレスポンスをブロックされてエラー、という状態が同時に成立している。

確認方法はブラウザの DevTools:

- **Network タブ**: リクエストが送られている（Status 200 になってる）
- **Console タブ**: `CORS policy: ...` エラーが出ている

「Network 200 / Console エラー」が CORS エラーの典型的な見え方。

**Q4: 例外はある？**

ある。**Preflight (OPTIONS) で弾かれるケース**は本リクエストが送られない:

- `Authorization: Bearer ...` のようなカスタムヘッダ付きリクエストでは、ブラウザが事前に OPTIONS を送る
- OPTIONS のレスポンスに正しい `Access-Control-Allow-*` が無いと、ブラウザは「許可されていない」と判断
- このとき**本リクエスト (GET / POST) 自体を送らない**

CloudWatch には OPTIONS だけが記録され、本来の API 呼び出しは記録されない。

## 結論 / 整理

CORS エラー時のサーバ側可視性は、リクエストの種類によって2パターンに分かれる:

| パターン | サーバへの到達 | CloudWatch 記録 | 副作用（DB書き込み等） |
|---|---|---|---|
| 本リクエストのレスポンスヘッダが不正 | 届く | 本リクエストが記録される | **発生する**（注意！） |
| Preflight (OPTIONS) で弾かれる | OPTIONS のみ | OPTIONS のみ記録 | 発生しない |

**特に1つ目が怖い**: 「フロントから見ると失敗してるのに DB には書かれてる」状態が起きうる。

> CORS は通信成立後の表示制御であって、副作用は止められない。

「冪等でない API（POST / DELETE 等）+ CORS 設定ミス」のコンボは整合性バグの温床。フロントの fetch が catch されたからといって、サーバに何も起きていないとは限らない。

## 比較表 / 具体例

### 「ブラウザが守る」とよく言われる仕組みの違い

| 仕組み | 何を止めるか | サーバへ届くか |
|---|---|---|
| **SOP / CORS** | レスポンスを JS に渡すのを止める | **届く**（GET/POST 本体）/ 届かない（preflight 失敗時） |
| **Mixed Content ブロック** | HTTPS ページから HTTP リソース取得を止める | 届かない |
| **CSP (Content-Security-Policy)** | スクリプト読み込みやインライン実行を止める | 届かない（読み込み自体が発生しない） |
| **HSTS** | HTTPS 強制 | リクエストは飛ぶが http→https にアップグレード |

CORS は「届くけど読ませない」、CSP は「そもそも届かせない」と性質が違う。

### CloudWatch / DevTools 観察の対応関係

```
CORS エラー（本リクエストのレスポンスヘッダ不正）:
  - DevTools Network: GET /submissions → 200 OK
  - DevTools Console: CORS policy: No 'Access-Control-Allow-Origin' header...
  - CloudWatch: API Gateway access log にリクエスト記録あり
                Lambda 実行ログあり
                DynamoDB の Get/Put 実行されている

CORS エラー（Preflight 失敗）:
  - DevTools Network: OPTIONS /submissions → 200 OK or 4xx
                       GET /submissions → (没)
  - DevTools Console: CORS policy: Response to preflight request...
  - CloudWatch: OPTIONS のログのみ
                本来の GET/POST のログは無い
```

## よくある誤解

- **誤解: CORS エラーが出ているなら、サーバには何も到達していない**
  - 実際: 本リクエスト型のエラーなら届いている。OPTIONS で弾かれた場合のみ届かない
- **誤解: CORS エラーなら副作用は発生しない**
  - 実際: POST が CORS エラーでも、レスポンスヘッダ起因なら DB 書き込みは完了している可能性がある
- **誤解: バックエンド側の問題だから CloudWatch を直せばいい**
  - 実際: サーバは正常動作している。修正するのは「レスポンスに Access-Control-Allow-Origin を含める」というレスポンス側の話で、ロジックの問題ではない

## 参考文献

- [Cross-Origin Resource Sharing (CORS) - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS) — CORS の仕様、preflight、シンプルリクエストの定義（閲覧 2026-04-25）
- [Same-origin policy - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/Security/Same-origin_policy) — SOP がブラウザ側の制限であることの公式説明（閲覧 2026-04-25）
- [CORS for REST APIs in API Gateway - AWS Docs](https://docs.aws.amazon.com/apigateway/latest/developerguide/how-to-cors.html) — API Gateway 側で CORS ヘッダを返す設定（閲覧 2026-04-25）

---

_Saved at 2026-04-25 via /learning-flow:reference_
