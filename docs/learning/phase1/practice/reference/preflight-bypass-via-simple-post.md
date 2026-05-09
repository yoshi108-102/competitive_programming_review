# Preflight をシンプル POST で回避する設計のセキュリティ・レイテンシトレードオフ

> 種別: ユーザー議論・Q&A の記録（Phase 1 / Task 3）
> 関連教材: [01-lambda-response-format-and-cors.md](../01-lambda-response-format-and-cors.md)
> 関連reference: [cors-rules-are-universal-not-per-site.md](cors-rules-are-universal-not-per-site.md), [cors-only-blocks-reads-not-writes.md](cors-only-blocks-reads-not-writes.md)

## 論点

ユーザーが Preflight の議論から踏み込んだ:

> POST で実質 DELETE ですみたいな感じで実装されてたらその分セキュリティは脆弱になる一方、preflight が発生しない分レイテンシが少なくなるという認識でいいの

これは古い RPC 風 API（Rails の `_method=delete` 等）や、レイテンシを削減したい設計判断としてリアルに存在するパターン。preflight をバイパスできる条件と、それによる影響（セキュリティ弱化 / レイテンシ改善）は実際にトレードオフになる。

ただし「preflight が無い = 危険」と単純化すると、**CORS の防御階層を見誤る**。preflight は補助的な早期ブロックで、書き込み攻撃への主防御は SameSite Cookie / CSRF トークン / JWT 方式など別の層にある。

## Q&A

**Q1: preflight が発動する条件を正確に整理すると？**

メソッドだけでなく、Content-Type やカスタムヘッダ全てが影響する。

| リクエスト要素 | シンプル | 非シンプル → preflight 発動 |
|---|---|---|
| メソッド | GET, HEAD, POST | PUT, DELETE, PATCH 他 |
| Content-Type | `application/x-www-form-urlencoded`, `multipart/form-data`, `text/plain` | `application/json`, その他 |
| カスタムヘッダ | なし（または安全な定義済みのみ） | `Authorization`, `X-API-Key` 他 |

**1つでも非シンプルに該当すれば preflight 発動**。

**Q2: 「POST で実質 DELETE」のパターンは実在するのか？**

実在する。代表的な3パターン:

**(1) フォーム互換 (preflight なし)**

```
POST /users/123/delete HTTP/1.1
Content-Type: application/x-www-form-urlencoded

_method=delete&id=123
```

Rails の hidden `_method` フィールドや、jQuery 時代の RPC 風 API。シンプルリクエストなので preflight 不要。

**(2) JSON POST (preflight あり)**

```
POST /users/123/delete HTTP/1.1
Content-Type: application/json

{"action": "delete", "id": 123}
```

JSON にした瞬間に preflight 発動。モダン REST はこちら。

**(3) Authorization ヘッダ付き POST (preflight あり)**

```
POST /users/123/delete HTTP/1.1
Authorization: Bearer xxx
Content-Type: application/x-www-form-urlencoded
```

カスタムヘッダがあるので preflight 発動。今回の AtCoder Review プロジェクトはこのパターン。

**Q3: レイテンシは本当に減るのか？**

初回はその通り。

```
preflight あり (初回):
  ブラウザ → サーバ: OPTIONS    (1 RTT)
  サーバ → ブラウザ: 200 OK
  ブラウザ → サーバ: POST       (1 RTT)
  サーバ → ブラウザ: 200 OK
  合計: 2 RTT

シンプル POST (preflight なし):
  ブラウザ → サーバ: POST       (1 RTT)
  サーバ → ブラウザ: 200 OK
  合計: 1 RTT
```

ただし `Access-Control-Max-Age` で preflight 結果がキャッシュされるので、**2回目以降は preflight が省略される**:

```
1回目: OPTIONS + POST = 2 RTT
2回目以降 (キャッシュ有効内): POST のみ = 1 RTT
```

ブラウザごとの最大値:

| ブラウザ | 最大値 |
|---|---|
| Chromium 系 | 7200 秒 (2時間) |
| Firefox | 86400 秒 (24時間) |
| Safari | 600 秒 (10分) |

**SPA の典型ユースケースでは preflight レイテンシは「初回のみ」**で、ユーザー体感影響は小さい。

**Q4: セキュリティは本当に弱くなる？**

部分的に正しい。ただし**preflight が無くても CORS-Allow-Origin は依然として効く**:

```
シンプル POST でも:
  ブラウザ → サーバ: POST       (送られる)
  サーバが処理して 200 OK 返す  (副作用発生する)
  ブラウザ: Allow-Origin チェック → JS に渡すか判定
```

つまり「**読み取り防御は依然として効く**」(漏洩は防げる)。問題は「**副作用 (DELETE 相当の処理) が発生済み**」というところ。

これは [cors-only-blocks-reads-not-writes.md](cors-only-blocks-reads-not-writes.md) で議論した「CORS は読み取り防御専門」と直結する。preflight は「副作用が起きる前に早期ブロックする補助的な層」であって、書き込み防御の主役ではない。

**Q5: じゃあ書き込み攻撃 (CSRF) の主防御は何？**

複数層の組み合わせ:

| 防御 | 役割 | preflight との関係 |
|---|---|---|
| **SameSite Cookie** | クロスオリジンで Cookie が送られないようにする | preflight 無しでも有効 |
| **CSRF トークン** | サーバが「正規ページから来たか」を毎回検証 | preflight 無しでも有効 |
| **JWT in Authorization** | そもそも認証情報が自動送信されない | カスタムヘッダで preflight 発動 |
| **Preflight** | 副作用が起きる前の早期ブロック | 補助的な早期ブロック |

つまり preflight は「**他の防御がちゃんとしていれば不要だが、あれば追加の安全網**」という位置付け。preflight が無くても上の3つで防げるなら、セキュリティ上は問題ない。

**Q6: 設計判断としてどう選ぶべきか？**

ケース別に整理:

| ケース | preflight | 適切か |
|---|---|---|
| 同一オリジン (Rails の `_method=delete`) | 関係なし (CORS 不要) | ✅ 問題なし |
| 別オリジン API + Cookie 認証 + シンプル POST | なし | ⚠️ CSRF 危険 → SameSite/CSRF トークン必須 |
| 別オリジン API + JWT in Authorization + JSON POST | あり | ✅ 安全 |
| 別オリジン API + JWT in Authorization + シンプル POST | あり (Authorization のため) | ✅ 安全 |

「**Cookie 認証 + シンプル POST + クロスオリジン**」の組み合わせが一番危険。今回の JWT 方式なら、シンプル POST にしても Authorization ヘッダで preflight が発動するし、そもそも CSRF リスクが構造的に低い。

**Q7: なぜモダン API は preflight 発動を許容しているのか？**

「セキュリティと意味のクリアさ」を選んだ結果。

- **REST**: 動詞をメソッドで表現 (`DELETE /users/123`) → preflight 発動するが意図がクリア
- **GraphQL**: 全部 POST だが Content-Type: application/json で preflight 発動
- **gRPC-Web**: Content-Type: application/grpc-web で preflight 発動

レイテンシより**設計の明確さ・防御の堅牢さ**を優先する判断。preflight キャッシュで実質コストは小さくできるので、トレードオフは「初回 1 RTT vs 設計の明確さ + 早期ブロック」となり、後者が勝つことが多い。

**Q8: 実用上、preflight レイテンシをさらに削減したい場合は？**

`Access-Control-Max-Age` を長めに設定:

```python
"headers": {
    "Access-Control-Max-Age": "86400",  # 24時間
    ...
}
```

Firefox は 24時間まで、Chrome は 2時間まで、Safari は 10分までクランプ。

注意点:
- キャッシュ有効期間中はブラウザが preflight をスキップする
- サーバ側で CORS 設定を変更しても、**キャッシュが切れるまで反映されない**
- 開発環境では短め (60秒など)、本番では長め (3600秒など) が定石

## 結論 / 整理

**ユーザーの仮説は両方とも部分的に正しい:**

1. ✅ シンプル POST に倒すと preflight が無いのでレイテンシは減る (初回 1 RTT 短縮)
2. ✅ preflight が無いので「副作用前の早期ブロック」という安全網が1つ減る

**ただし重要な但し書き:**

- **CORS-Allow-Origin は依然として有効** (読み取り防御は残る)
- **preflight は補助的な層**で、CSRF の主防御は別 (SameSite Cookie, CSRF トークン, JWT)
- **preflight キャッシュ**でレイテンシコストはほぼ初回のみ
- **モダン API は意図的に preflight を発動させる方向**で設計されている

**今回の AtCoder Review では:**

- JWT in Authorization 方式 → 全リクエストで preflight 発動
- CSRF リスクは構造的にゼロ（Cookie 不使用）
- preflight レイテンシは `Access-Control-Max-Age` で軽減可能
- 「シンプル POST に倒す最適化」は不要、むしろやるべきでない

## 比較表 / 具体例

### preflight 発動条件マトリクス

| メソッド \ Content-Type | form-urlencoded | application/json | (no body) |
|---|---|---|---|
| **GET** | シンプル | — | シンプル |
| **POST** | シンプル | **preflight** | シンプル |
| **PUT** | **preflight** | **preflight** | **preflight** |
| **DELETE** | **preflight** | **preflight** | **preflight** |
| **PATCH** | **preflight** | **preflight** | **preflight** |

加えて、**Authorization 等のカスタムヘッダがあれば、メソッドや Content-Type に関わらず preflight 発動**。

### 「POST で全部やる」設計のセキュリティ評価

```
[同一オリジン (CORS 不要)]
   Rails の _method=delete    → ✅ OK (CORS 関係なし)
   form 送信                  → ✅ OK

[クロスオリジン + Cookie 認証 + シンプル POST]
   form 風 POST で DELETE     → ⚠️ CSRF 危険
   別途必要: SameSite=Strict / CSRF トークン

[クロスオリジン + JWT in Authorization]
   どんな POST も preflight   → ✅ 安全
   構造的に CSRF 耐性あり

[クロスオリジン + JSON POST]
   Content-Type で preflight  → ✅ 安全
   モダン REST/GraphQL の標準
```

### 各防御層と preflight の関係

```
[攻撃: クロスオリジンから状態変更]
   ↓
レイヤー1: SameSite Cookie
  └ Cookie が送られなければそもそも認証通らない
   ↓ (Cookie 認証でない場合)
レイヤー2: Preflight
  └ 副作用が起きる前にブロック (シンプル POST だと無効)
   ↓ (シンプル POST の場合)
レイヤー3: CSRF トークン
  └ サーバが正規ページから来たか検証
   ↓ (検証してない場合)
レイヤー4: 認証ヘッダ方式 (JWT)
  └ そもそも認証情報が自動送信されない

→ どれか1つでも有効なら防御成立
```

preflight は「あれば嬉しいが、無くても他で守れる」レイヤー。**主防御は「認証情報がブラウザによって自動送信されない方式」 = JWT in Authorization**。

## よくある誤解

- **誤解: preflight が CSRF の主防御**
  - 実際: 補助的な早期ブロック。主防御は SameSite Cookie / CSRF トークン / JWT 方式
- **誤解: シンプル POST に倒せば常にレイテンシが半分になる**
  - 実際: 初回のみ。Access-Control-Max-Age で2回目以降はキャッシュされる
- **誤解: preflight が無いリクエストは CORS の対象外**
  - 実際: Allow-Origin は依然として効く。読み取り防御は残る、副作用ブロックが効かないだけ
- **誤解: 「POST で何でもやる」は古臭い設計**
  - 実際: GraphQL は意図的に全 POST。Content-Type で preflight 発動するから安全
- **誤解: モダン API は preflight を避けるために最適化されている**
  - 実際: むしろ意図的に preflight を発動させて設計の明確さと早期ブロックを取っている

## 参考文献

- [CORS - MDN Web Docs - Preflighted requests](https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS#preflighted_requests) — Preflight 発動条件の正確な仕様（閲覧 2026-04-25）
- [Access-Control-Max-Age - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Access-Control-Max-Age) — Preflight キャッシュ、ブラウザごとの上限（閲覧 2026-04-25）
- [Cross-Site Request Forgery Prevention Cheat Sheet - OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html) — CSRF 防御の正攻法（preflight に頼らない設計）（閲覧 2026-04-25）
- [Rails - PUT vs POST](https://guides.rubyonrails.org/form_helpers.html#how-do-forms-with-put-or-delete-methods-work) — `_method=delete` の歴史的経緯（閲覧 2026-04-25）

---

_Saved at 2026-04-25 via /learning-flow:reference_
