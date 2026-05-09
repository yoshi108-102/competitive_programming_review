# SameSite Cookie と現代のブラウザ側 CSRF 防御

> 種別: ユーザー議論・Q&A の記録（Phase 1 / Task 3）
> 関連教材: [01-lambda-response-format-and-cors.md](../01-lambda-response-format-and-cors.md)
> 関連reference: [cors-only-blocks-reads-not-writes.md](cors-only-blocks-reads-not-writes.md)

## 論点

「CORS は読み取り防御、書き込み防御は別の層」の議論の中で、補足として:

> 現代では SameSite Cookie のデフォルト Lax 化で、ブラウザ側からも書き込み攻撃をある程度防ぐようになった

と述べた。これを掘り下げる。

ユーザーの直前の理解:

> ブラウザがサーバ側で何を守っているか知らないといけないわけだから本質的にリクエストが成功する

ブラウザは「ドメインロジック」を知らないので、**機械的に判定できる境界線でしか守れない**。SameSite Cookie はその境界線の選び方を「**Cookie の発行元 vs リクエストの起点**」に置いた、ブラウザ側の書き込み防御の代表例。

## Q&A

**Q1: SameSite Cookie とは何で、どう動く？**

Cookie に付ける属性で、「この Cookie はどんなコンテキストでブラウザが自動送信していいか」を Cookie 発行者（サーバ）が宣言する仕組み。

```
Set-Cookie: sessionId=abc123; SameSite=Lax; Secure; HttpOnly
```

3つの値:

| 値 | 動き | 用途 |
|---|---|---|
| **Strict** | 同一サイトからの遷移にしか送らない | 銀行など最高セキュリティ |
| **Lax** (デフォルト) | トップレベル GET 遷移は例外で送る、それ以外は同一サイトのみ | 一般的なログインセッション |
| **None** | 全部送る（クロスサイト含む）。`Secure` 必須 | 埋め込みウィジェット、3rd-party 統合 |

**Q2: それぞれの値で具体的にどう振る舞いが変わる？**

`bank.com` にログイン中（Cookie 発行済み）状態でのシナリオ:

| シナリオ | Strict | Lax | None |
|---|---|---|---|
| `bank.com` 内で別ページに遷移 | ✅ 送る | ✅ 送る | ✅ 送る |
| Google 検索結果から `bank.com` をクリック | ❌ 送らない | ✅ 送る (GET) | ✅ 送る |
| `evil.com` の `<form method="POST">` で `bank.com` に送信 | ❌ 送らない | ❌ 送らない | ✅ 送る |
| `evil.com` の `fetch("bank.com/api")` | ❌ 送らない | ❌ 送らない | ✅ 送る |
| `evil.com` の `<img src="bank.com/logo">` | ❌ 送らない | ❌ 送らない | ✅ 送る |

`Lax` は「ユーザーが意図的にリンクをクリックして遷移するのは正当」という考えで、Top-level GET 遷移だけは例外で許可している。POST やフレーム経由の送信は遮断される。

**Q3: なぜ Lax がデフォルトになったのか？**

歴史:

```
〜 2020年初頭:        SameSite 未指定 = None 扱い（全部送る）
                       ↓
2020年2月 Chrome 80:  SameSite 未指定 = Lax 扱いに変更
                       ↓
                       Firefox, Edge も追随
                       ↓
現在:                  ほぼ全主要ブラウザで Lax がデフォルト
```

これにより、**サーバが何も書かなくても自動的に Lax が効く**ようになった。古い広告系の Cookie が動かなくなる副作用があったほどの大きな変更。

「ブラウザ側からの書き込み攻撃防御」のメインの仕掛けとなり、サーバ側で CSRF トークンを実装しなくても CSRF 攻撃の大半が防がれるようになった。**ブラウザ側がドメインロジックを知らずに守れる、機械的な境界線**として「Cookie の発行元 vs リクエストの起点」を採用したのがポイント。

**Q4: "Same-Site" と "Same-Origin" の違いは？**

両者は別概念:

| 概念 | 一致条件 | 例 |
|---|---|---|
| **Same Origin** (CORS) | scheme + host + port が**完全一致** | `https://app.example.com` ≠ `https://api.example.com` |
| **Same Site** (Cookie) | **登録可能ドメイン** (eTLD+1) が一致 | `https://app.example.com` = `https://api.example.com` |

eTLD+1 = 「公開接尾辞リスト (Public Suffix List) の 1 段下」。`example.com` は eTLD+1、`app.example.com` はその子サブドメイン。

```
example.com / app.example.com / api.example.com
  → 全部 same-site
  → でも互いに cross-origin

example.com / other.com
  → cross-site（= cross-origin でもある）
```

なぜ違う粒度なのか:

- **Cookie は会社単位の信頼境界で扱いたい**: app と api がサブドメインで分かれていてもセッションを共有したい → eTLD+1 で同じ扱い
- **CORS は JS のレスポンス読み取りで厳格に扱いたい**: 同じ会社内でも別オリジンなら明示的に許可させる → 完全一致

セキュリティ機構ごとに保護対象が違うので、信頼境界の引き方も違う。

**Q5: SameSite=Lax で防げる / 防げないものは？**

防げる:

- evil.com の `<form action="bank.com/transfer" method="POST">` 自動送信
- evil.com の `fetch("bank.com/api", {method: "POST"})` (CORS 以前に Cookie が無い)
- evil.com の `<img src="bank.com/logout">`（GET でも top-level でない）
- iframe 経由の Cookie 送信全般

防げない:

- **同一サイト内の XSS** から API を呼ばれる（同一 site なので Cookie 送られる）
- **Google 検索からのクリックで GET アクション**（`/delete-account?id=123` のような GET API は Lax でも危険）
- **サブドメイン乗っ取り** (`evil.example.com` が乗っ取られたら same-site）

実装面の含意:

1. **状態改変は POST/PUT/DELETE で行う**（GET でやらない）← REST の原則と同じ
2. **同一サイト内の XSS 対策は別途必要**（CSP など）
3. **サブドメインを安易に増やさない・サブドメイン乗っ取りに注意**

**Q6: 今回のプロジェクトで SameSite Cookie は関係ある？**

ほぼ関係ない。**Cookie を使わず、JWT を `Authorization: Bearer` ヘッダで送る方式**を採用しているため。

```
Cookie 認証を選んでいたら:
  → SameSite=Lax + Secure + HttpOnly が必須設定
  → 状態改変 API なら CSRF トークンも検討

JWT in Authorization 方式（採用）:
  → Cookie が無い → SameSite 不要
  → ブラウザは JWT を「自動で」付けない → CSRF リスクは構造的にゼロ
  → CORS の設定だけ正しければ守られる
```

**Q7: Cookie 方式と JWT 方式、どちらが優れている？**

トレードオフがあり、用途次第。

| 観点 | Cookie + SameSite + HttpOnly | JWT in Authorization |
|---|---|---|
| CSRF 耐性 | SameSite=Lax で大半防げる | 構造的にゼロ |
| XSS 耐性 | HttpOnly で JS から読めない（強い） | localStorage 保管なら JS から読める（弱い） |
| 実装難度 | サーバ側でセッション管理 | JWT 署名検証だけ |
| サードパーティ統合 | SameSite=None + Secure 必須 | Authorization ヘッダで簡単 |
| サーバレス相性 | セッションストア必要 | ステートレスで完璧 |
| トークン失効 | サーバ側で無効化可（強い） | 短命にして頻繁に再発行 |

**サーバレス + SPA + JWT** がモダンなデフォルトになった理由:

- CSRF 不要（構造的に）
- ステートレス（Lambda と相性良い）
- 水平スケール容易（セッションストア共有不要）

ただし XSS 耐性は Cookie + HttpOnly の方が強い。XSS 対策（CSP、サニタイズ）と JWT 短命化で対処するのが定石。

## 結論 / 整理

CORS は「読み取り防御」だが、書き込み防御の一部はブラウザ側でも進化している。それが **SameSite Cookie のデフォルト Lax 化**。

- ブラウザはドメインロジックを知らない → **機械的な境界線**で守るしかない
- SameSite が選んだ境界線: 「Cookie 発行元の eTLD+1 と一致するか」
- これにより、サーバ側で CSRF トークンを実装しなくても CSRF の大半が防がれる
- ただし「機械的境界線」の限界として、同一サイト内 XSS や GET ベース API は守れない

**今回の AtCoder Review は Cookie を使わない JWT 方式**なので SameSite は不要。CSRF 耐性は方式選択で構造的に獲得している。

「Cookie + SameSite + HttpOnly」と「JWT in Authorization」は別のトレードオフがあり、サーバレス + SPA では後者がモダンなデフォルト。

## 比較表 / 具体例

### Site と Origin の信頼境界

```
[Origin 単位] (CORS の領域)
  https://app.example.com   ─┐
  https://api.example.com   ─┼─ 全部別オリジン
  https://example.com       ─┘

[Site 単位] (SameSite Cookie の領域)
  https://app.example.com   ─┐
  https://api.example.com   ─┼─ すべて same-site (eTLD+1 = example.com)
  https://example.com       ─┘
```

### Lax の動作判定フロー

```
リクエスト発生
   ↓
Cookie の発行元の eTLD+1 と
リクエストを発生させたページの eTLD+1 が一致？
   ↓
   YES → Cookie 送る（same-site）
   NO  → さらに判定
        ↓
        トップレベルナビゲーション (window.location)
        かつ メソッドが GET か？
           ↓
           YES → Cookie 送る（Lax の例外）
           NO  → Cookie 送らない（cross-site の遮断）
```

## よくある誤解

- **誤解: SameSite=Strict が一番安全だから常に使うべき**
  - 実際: Strict だと「Google からのリンク経由でログイン状態が消える」UX 問題が起きる。Lax がバランスのデフォルト
- **誤解: Same-site と Same-origin は同じ意味**
  - 実際: 別概念。Same-site は eTLD+1、Same-origin は scheme+host+port 完全一致
- **誤解: SameSite=Lax にすれば CSRF 完全に防げる**
  - 実際: GET ベース API や同一サイト XSS は防げない。状態改変は POST 等で、XSS は別途対策
- **誤解: JWT は安全だから XSS 対策しなくていい**
  - 実際: localStorage の JWT は XSS で盗まれうる。むしろ Cookie + HttpOnly より弱い面もある

## 参考文献

- [Set-Cookie - SameSite - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie/SameSite) — Strict/Lax/None の正確な仕様（閲覧 2026-04-25）
- [SameSite cookies explained - web.dev](https://web.dev/articles/samesite-cookies-explained) — Chrome 80 の Lax デフォルト化の背景説明（閲覧 2026-04-25）
- [Public Suffix List](https://publicsuffix.org/) — eTLD+1 判定に使われる公式リスト（閲覧 2026-04-25）
- [SameSite cookie recipes - web.dev](https://web.dev/articles/samesite-cookie-recipes) — 実装パターン集、3rd party Cookie 対応（閲覧 2026-04-25）

---

_Saved at 2026-04-25 via /learning-flow:reference_
