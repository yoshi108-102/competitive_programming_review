# CORS は「読み取り」しか防がない — 書き込み攻撃 (CSRF) は別の層で守る

> 種別: ユーザー議論・Q&A の記録（Phase 1 / Task 3）
> 関連教材: [01-lambda-response-format-and-cors.md](../01-lambda-response-format-and-cors.md)
> 関連reference: [cors-error-server-side-visibility.md](cors-error-server-side-visibility.md)

## 論点

「CORS エラー時もサーバには届いている」という話の直後、ユーザーが鋭い違和感を表明:

> サーバのレスポンスがフロントのブラウザで弾かれるだけということ？ということは、さっきのSOPの例でいくと、取引自体は成立するがこちらからはエラーに見えるということだろ。UX として不自然な仕様じゃないか？

これは CORS / SOP の設計思想を理解する上で**核心的な指摘**。

「悪意ある evil.com の JS が bank.com に送金 POST を送る」という攻撃を考えると:

- レスポンスは JS に渡されない（CORS で防げる）
- でも**送金自体は成立してしまう**（ブラウザはリクエストを送ったから）
- 被害者は「失敗した」と認識するが、サーバ側では送金完了している

つまり CORS は **「データ漏洩」しか防がない**。状態改変系の攻撃 (CSRF) は CORS の射程外。これは「設計ミス」ではなく**意図的な分業**。

## Q&A

**Q1: 結局 CORS は何を防いでるの？**

**「クロスオリジンの読み取り (reading)」だけ**を防いでいる。書き込み (writing / 状態改変) は防がない。

| 攻撃の目的 | CORS で防げるか | 理由 |
|---|---|---|
| 口座情報を盗む（読み取り） | ✅ 防げる | レスポンスを JS に渡さないので、データが evil.com に渡らない |
| 送金させる（書き込み・なりすまし） | ❌ 防げない | 送金はリクエスト送信時点で成立、レスポンス読めなくても被害は発生 |

**Q2: なぜリクエスト自体を止める設計にしなかった？UX 的に不自然じゃないか？**

意図的にそうしている。理由は3つ。

**(a) Web の歴史的経緯 — クロスオリジン POST が元々あった**

SOP が導入される前から、Web には正当なクロスオリジン POST があった:

```html
<!-- example.com 上のフォームから他社決済へ -->
<form action="https://payment.example.com/pay" method="POST">
  <input name="amount">
  <button>決済</button>
</form>
```

これは正当な機能。フォーム送信、外部決済、リダイレクト、画像読み込みなど、Web の根幹を支えている。「クロスオリジン書き込みを全部禁止」したら Web が壊れる。

**(b) 攻撃の種類で分業 — CORS は「漏洩」担当**

| 攻撃 | 必要な情報 | 防御の対象 |
|---|---|---|
| 情報漏洩 | レスポンスの中身 | 読み取りを止める ← CORS / SOP |
| なりすまし操作 | Cookie 等の認証情報 | 送信時に区別 ← Cookie / CSRF対策 |

CORS は射程を絞って「データ漏洩」を担当。書き込み攻撃は別の層が担当する分業設計。

**(c) 書き込み攻撃 (CSRF) は Cookie 側で対処された**

CSRF の本質は「**Cookie が勝手に送られる**」こと。だから対策はリクエスト側ではなく Cookie の方に入った:

```
Set-Cookie: sessionId=abc; SameSite=Lax
```

`SameSite=Lax`（Chrome 80 以降のデフォルト）だと、別オリジンからの POST には Cookie が**そもそも送られない**。これで CSRF はかなり防げるようになった。

**Q3: じゃあ Web セキュリティはどう構成されている？**

CORS は1つの層に過ぎず、**複数層の組み合わせ**で初めて成立する:

```
レイヤー1: SOP / CORS
  └─ クロスオリジンの「読み取り」を防ぐ
  └─ 主に情報漏洩対策

レイヤー2: SameSite Cookie / CSRF トークン
  └─ クロスオリジンの「書き込み (なりすまし)」を防ぐ
  └─ 主に状態改変対策

レイヤー3: CSP (Content-Security-Policy)
  └─ 危険なスクリプト実行を防ぐ
  └─ XSS 対策

レイヤー4: X-Frame-Options / frame-ancestors
  └─ Clickjacking を防ぐ

レイヤー5: HTTPS / HSTS
  └─ 通信路の盗聴・改竄を防ぐ
```

「CORS だけで何でも守れる」と思うと不完全に見えるが、**それぞれ別の攻撃を担当**しているので、CORS が漏洩担当なのは正しい。

**Q4: 今回の AtCoder Review プロジェクトでは CSRF を意識する必要は？**

ほぼ不要。理由は **Cognito の JWT を `Authorization: Bearer ...` ヘッダで送る方式**を採用しているため。

```
✅ Cookie を使わない
   ↓
✅ ブラウザが認証情報を「自動で」付けることがない
   ↓
✅ evil.com の JS が API を呼んでも、JWT ヘッダを付けられない
   （自分の JWT 持ってないから）
   ↓
✅ なりすまし送金が成立しない = CSRF リスクほぼゼロ
```

「Cookie 方式だと CSRF 対策が必要、JWT 方式だと CORS 設定だけで実質守られる」というのが、現代の SPA + API Gateway 構成で JWT が好まれる理由の1つ。

## 結論 / 整理

ユーザーの違和感「**CORS だけ見ていると不完全に見える**」は正しい。**CORS は読み取り防御専門で、書き込み防御は別の機構が担う**、という分業を理解すると整理できる。

教材で「SOP は壁、CORS は壁の扉」と表現したが、より正確には:

> その壁は「読み取り」という1方向にしか効かない壁。書き込みは壁を素通りする。

実務上の含意:

1. **「CORS エラーが出てるから安全」と思わない** — 副作用は発生している可能性がある (前 reference 参照)
2. **JWT in Authorization ヘッダ方式は CSRF 対策込み** — Cookie 方式と違い、CSRF トークンを別途用意する必要がない
3. **本番でオリジンを `*` にしない** — 漏洩防御が無効化される
4. **状態改変系 API (POST/PUT/DELETE) は冪等性 / 認証ヘッダ確認 を意識する** — CORS だけに頼らない

## 比較表 / 具体例

### CORS だけで守れる攻撃 / 守れない攻撃

| 攻撃 | CORS で防御 | 別途必要な対策 |
|---|---|---|
| evil.com から bank.com の口座情報を**読む** | ✅ できる | — |
| evil.com から bank.com に**送金 POST** を送る | ❌ できない | SameSite Cookie / CSRF トークン / JWT in Header |
| evil.com に bank.com を iframe 埋め込みして偽クリック (Clickjacking) | ❌ できない | X-Frame-Options / frame-ancestors |
| 自サイト内に注入された XSS が API を呼ぶ | ❌ できない | CSP / XSS 対策 / 入力サニタイズ |
| ネットワーク盗聴 | ❌ できない | HTTPS / HSTS |

### Cookie 認証 vs JWT 認証 (CSRF 観点)

```
[Cookie 認証]
   ブラウザが自動的に Cookie を付ける
       ↓
   evil.com の JS が POST を投げると Cookie が付く
       ↓
   サーバはログイン中ユーザーからのリクエストと誤認
       → CSRF 攻撃成立しうる
   対策: SameSite=Lax 以上 / CSRF トークン

[JWT in Authorization ヘッダ]
   JWT は localStorage / メモリに保管
       ↓
   evil.com の JS は別オリジン → 自分のオリジンの localStorage しか読めない
       ↓
   bank.com の JWT を取得できない → ヘッダに付けられない
       → CSRF 攻撃成立しない
   対策: CORS の正しい設定だけで足りる
```

## よくある誤解

- **誤解: CORS が通ったら安全、CORS で弾かれたら攻撃失敗**
  - 実際: CORS は「読み取り防御」だけ。書き込み攻撃 (CSRF) は CORS とは無関係に成立しうる
- **誤解: CORS 設定を厳しくすれば CSRF も防げる**
  - 実際: 部分的に防げるが完全ではない。CSRF は SameSite Cookie や認証ヘッダ方式（JWT）など別の層で対処する
- **誤解: SOP がリクエストを止めるから安全**
  - 実際: SOP はリクエストを止めない、レスポンスの読み取りを止めるだけ
- **誤解: フロントが CORS エラーで失敗したから DB は変わってない**
  - 実際: 本リクエスト型の CORS エラーなら、DB 書き込みは完了している可能性が高い

## 参考文献

- [Same-origin policy - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/Security/Same-origin_policy) — SOP は読み取り制御中心であることの公式説明（閲覧 2026-04-25）
- [Cross-Site Request Forgery (CSRF) - OWASP](https://owasp.org/www-community/attacks/csrf) — CSRF の定義と SOP では防げない理由（閲覧 2026-04-25）
- [SameSite cookies - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Set-Cookie/SameSite) — Cookie 側の CSRF 対策（閲覧 2026-04-25）
- [Cross-Site Request Forgery Prevention Cheat Sheet - OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html) — JWT in Header 方式が CSRF 耐性を持つ理由（閲覧 2026-04-25）

---

_Saved at 2026-04-25 via /learning-flow:reference_
