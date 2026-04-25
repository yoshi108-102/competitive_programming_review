# ブラウザの CORS ルールは「サイト独立・普遍適用」のホワイトリスト方式

> 種別: ユーザー議論・Q&A の記録（Phase 1 / Task 3）
> 関連教材: [01-lambda-response-format-and-cors.md](../01-lambda-response-format-and-cors.md)
> 関連reference: [why-cors-exists-three-actors.md](why-cors-exists-three-actors.md)

## 論点

ユーザーが Preflight の議論の流れで2つの根本的な問いを立てた:

1. **Preflight = ハンドシグナルだとすると、状態変更系メソッドの整合性は保たれるのか？**
2. **ブラウザ側の設定は evil.com の存在と独立しているのか？Chrome 設定でいじれる類のものなのか？**

特に2つ目は CORS の本質を理解する上で重要。「Chrome に悪意あるサイトのリストがあって、それを参照して弾いてる」と誤解すると CORS の設計思想が見えなくなる。

実際は **「クロスオリジンを全部疑う / サーバが許可宣言したものだけ通す」というホワイトリスト型ルールがブラウザに普遍適用**されており、サイト個別の設定は存在しない。

## Q&A

**Q1: Preflight はハンドシグナルだと考えていい？状態変更メソッドでも整合性は保たれる？**

ほぼ Yes。Preflight は本リクエスト前の「許可確認のハンドシェイク」と理解して OK。

整理:

| リクエスト種別 | preflight | 状態変更時の整合性 |
|---|---|---|
| `Content-Type: application/json` の POST/PUT/DELETE | ✅ あり | ✅ 保たれる（弾かれたら本リクエストは送られない） |
| カスタムヘッダ (`Authorization` 等) 付き | ✅ あり | ✅ 保たれる |
| HTML フォーム互換のシンプル POST | ❌ なし | ❌ 副作用発生しうる（古典的 CSRF 経路） |

**シンプルリクエストの例外**:

```html
<form action="https://bank.com/transfer" method="POST">
  <input name="amount" value="100">
  <input name="to" value="attacker">
</form>
```

これはメソッド POST、`Content-Type: application/x-www-form-urlencoded`、カスタムヘッダ無し → **シンプル判定 → preflight 無し**。本リクエストがいきなり飛び、CORS でレスポンスは JS に渡らないが、サーバ側の送金処理は完了している（CSRF 攻撃経路）。

**今回のプロジェクトの含意**:

`Authorization: Bearer <JWT>` を必須にしているため、全リクエストが非シンプル → preflight 対象 → 整合性は構造的に保たれる。これも JWT 認証方式の利点の1つ。

**Q2: ブラウザの CORS ルールは evil.com の存在と独立か？Chrome 設定でいじれる？**

完全に独立。**ブラウザに「evil.com リスト」のようなものは存在しない**。

ブラウザがやってるのは1つのルールだけ:

```
全クロスオリジン fetch について:
  「サーバが Access-Control-Allow-Origin で許可してない限り、
   レスポンスを JS に渡さない」
```

サイト名は一切関係ない。`evil.com` も `legit-partner.com` も同じルールで判定される。判定基準は「クロスオリジンか否か」と「サーバが許可宣言したか」だけ。

**Q3: ルールはどこに保管されているのか？**

3つの層に分かれている:

| 何 | どこに保管 | 誰が決める |
|---|---|---|
| **CORS のアルゴリズム本体** | ブラウザのバイナリ（ハードコード） | ブラウザ開発元 (Google, Mozilla 等) |
| **各サイトの許可オリジン** | 各サーバのレスポンスヘッダ（毎リクエスト動的に） | サーバの開発者 |
| **ユーザー設定** | Chrome 設定画面（ほぼ存在しない） | エンドユーザー |

つまり:

- **ルールの形**は Chrome のコードに焼き付き（全ユーザー共通・サイト独立）
- **許可されるオリジンの中身**は毎回サーバから動的に送られる
- **ユーザーが Chrome 設定でいじれる箇所はほぼない**

「Chrome の設定で evil.com をブロックする」みたいな項目は CORS の文脈では存在しない。CORS は完全にプロトコルレベルのルールで、ユーザー設定とは切り離されている。

**Q4: なぜ「evil.com を特別扱いしない」のに防げるのか？**

ホワイトリスト方式だから。

```
ブラックリスト方式（やらない）:
  「悪意あるサイトをリストアップして弾く」
  → 新種の悪意サイトに対処できない
  → リストの管理コストが大きい

ホワイトリスト方式（CORS の選択）:
  「全クロスオリジンを疑い、許可されたものだけ通す」
  → 新種でも自動的に弾かれる
  → 個別管理が不要
```

evil.com は「自分が許可されてる」と主張できない（できても、許可宣言はサーバ側のレスポンスから来るので偽装不可）ので、bank.com からのレスポンスは JS に渡らない。

**Q5: Chrome の設定でいじれる項目はあるのか？**

通常のエンドユーザーが使う項目はほぼない。ただし以下の例外:

| 項目 | 影響 |
|---|---|
| **拡張機能 (Chrome Extension)** | manifest で `host_permissions` を宣言すれば一部 API は CORS バイパス可能 |
| **`--disable-web-security` フラグ** | Chrome を CORS 無視で起動するデバッグ用フラグ。本番ユーザーは使わない（Chromium 開発者向け） |
| **3rd party Cookie をブロック** | Cookie 系の判定に影響（CORS そのものではない） |
| **拡張機能ポリシー (企業管理)** | IT 管理者が一部のサイトを除外する等。これも CORS 設定とは別軸 |

普通のユーザーは **CORS 設定を一切意識しない**。サーバ側の設定ミスは「Web サイトが壊れてるように見える」エラーとしてユーザーに表れる。

**Q6: 結局、誰が責任を持っているのか？**

役割分担:

| 主体 | 責務 |
|---|---|
| ブラウザ開発元 | CORS アルゴリズムを正しく実装する（バグ無く・仕様通り） |
| サーバ開発者 | `Access-Control-Allow-*` を正しく設定する（過度に緩めない） |
| エンドユーザー | 何もする必要がない（自動的に守られる） |

「ユーザーが意識せず守られる」のが CORS の理想形で、サーバ開発者がしっかり設定する責任を負っている、という設計。

## 結論 / 整理

**Preflight について**:

- 状態変更系（PUT/DELETE/JSON POST/カスタムヘッダ付き）は preflight 対象 → 弾かれたら本リクエストが送られない → 整合性が保たれる
- シンプル POST（HTML フォーム互換）は preflight 無しなので副作用発生しうる
- 今回のプロジェクトは `Authorization` 必須 → 全て preflight 対象 → 整合性 OK

**ブラウザの CORS ルールについて**:

- サイト名 (evil.com 等) は一切関係ない
- 「クロスオリジンは全部疑う / サーバ許可があれば通す」のホワイトリスト方式
- ルールはブラウザのバイナリにハードコード、許可オリジンはサーバから動的に来る
- ユーザー設定でいじれる項目はほぼない（責任はサーバ開発者）

CORS は「ブラウザ ↔ サーバ」のプロトコル合意であり、ユーザーの介入や個別サイトのリスト管理は不要、という普遍的な仕組み。

## 比較表 / 具体例

### ブラックリスト方式 vs ホワイトリスト方式

```
[ブラックリスト方式 (採用してない)]

  「悪意あるサイトをリストアップ」
       ↓
  evil.com, malware.example, ... を Chrome がリスト化
       ↓
  該当サイトからの fetch を弾く
       ↓
  問題: 新種に対応できない / リスト管理コストが大きい

[ホワイトリスト方式 (CORS の採用)]

  「全クロスオリジンを疑い、許可されたものだけ通す」
       ↓
  サーバが Access-Control-Allow-Origin: https://app.example.com を返す
       ↓
  ブラウザ: 「自分のオリジンが一致するなら通す、しないなら弾く」
       ↓
  evil.com は許可宣言できない（サーバ側のレスポンスから来るので偽装不可）
       ↓
  自動的に弾かれる
```

### CORS と他の「ブラウザ側セキュリティ」の比較

| 機構 | リスト保管場所 | サイト独立か |
|---|---|---|
| **CORS / SOP** | ブラウザコード（アルゴリズムのみ） | ✅ 独立（普遍ルール） |
| **HSTS** | Chrome の HSTS Preload List + サーバの HSTS ヘッダ | △ 部分的（Preload はリスト） |
| **Safe Browsing** | Google が管理する悪意サイトリスト | ❌ サイト個別（ブラックリスト） |
| **Mixed Content Block** | プロトコル判定のみ | ✅ 独立（普遍ルール） |
| **CSP** | サーバの CSP ヘッダ | ✅ 独立（サーバ宣言） |

CORS は「サイト個別リスト不要・サーバ宣言で動的に決まる」というシンプルな設計。Safe Browsing のようなリスト方式とは性質が違う。

### Preflight キャッシュ (Access-Control-Max-Age)

```
1回目のリクエスト: OPTIONS → 本リクエスト の2通信
                   サーバが Access-Control-Max-Age: 3600 を返す
   ↓
2回目以降（1時間以内）:
                   ブラウザがキャッシュ参照 → 本リクエストのみ
                   2通信 → 1通信に節約
```

ブラウザごとの上限:

| ブラウザ | 最大値 |
|---|---|
| Chromium 系 | 7200 秒 (2時間) |
| Firefox | 86400 秒 (24時間) |
| Safari | 600 秒 (10分) |

10分以上の値は Safari ではクランプされる。

## よくある誤解

- **誤解: Chrome に悪意あるサイトのリストがあり、それで CORS を判定している**
  - 実際: そんなリストはない。「クロスオリジンは全て疑う」という普遍ルールだけ
- **誤解: ユーザーが Chrome の設定で CORS をいじる**
  - 実際: 通常設定にはない。`--disable-web-security` フラグはあるが開発者向け
- **誤解: Preflight は全リクエストで発動する**
  - 実際: シンプルリクエスト条件を満たす場合は preflight 不要。HTML フォーム互換が境界
- **誤解: Preflight があれば全ての CSRF が防げる**
  - 実際: シンプル POST には preflight が無いので、フォーム送信型 CSRF は別途対策必要

## 参考文献

- [Cross-Origin Resource Sharing (CORS) - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS) — Preflight、シンプルリクエストの判定基準（閲覧 2026-04-25）
- [Preflight request - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Glossary/Preflight_request) — Preflight の正確な仕様（閲覧 2026-04-25）
- [Access-Control-Max-Age - MDN Web Docs](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Access-Control-Max-Age) — Preflight キャッシュの上限値（閲覧 2026-04-25）
- [Fetch Standard - WHATWG](https://fetch.spec.whatwg.org/) — Fetch の CORS アルゴリズム本体（閲覧 2026-04-25）

---

_Saved at 2026-04-25 via /learning-flow:reference_
