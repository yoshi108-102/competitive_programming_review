# CORS lab

ブラウザの CORS 機構そのものを目視するための実験ラボ。AWS デプロイ前に「どのヘッダが無いと何が起きるか」を体で覚えるのが目的。

## 構成

```
front  http://localhost:5500   <-- index.html を配信
api    http://localhost:8000   <-- server.py (CORS_MODE で挙動切替)
```

オリジンが違うので、ブラウザの fetch は必ず CORS チェックを通る。

## 起動

```bash
# ターミナル A — API サーバ（モードを変えながら再起動して観察する）
CORS_MODE=none python experiments/cors-lab/server.py

# ターミナル B — 静的フロント
python -m http.server 5500 --directory experiments/cors-lab
```

ブラウザで <http://localhost:5500/> を開き、DevTools を開いた状態でボタンを押す。

## CORS_MODE 一覧

| mode              | レスポンスに付くヘッダ                                    |
| ----------------- | --------------------------------------------------------- |
| `none`            | （何も付けない）                                          |
| `wildcard`        | `Allow-Origin: *`                                         |
| `exact`           | `Allow-Origin: http://localhost:5500`                     |
| `wrong`           | `Allow-Origin: http://example.com`（わざとズレ）          |
| `credentials-bug` | `Allow-Origin: *` + `Allow-Credentials: true`（典型ミス） |
| `full`            | Origin / Methods / Headers / Credentials すべて正しく返す |

## 期待挙動マトリクス（試して埋める用）

`OK` = レスポンスが JS から読める / `BLOCK` = ブラウザが遮断 / `HIT` = ブラウザがブロックしてもサーバ側ハンドラには到達

|                          | none | wildcard | exact | wrong | credentials-bug | full |
| ------------------------ | ---- | -------- | ----- | ----- | --------------- | ---- |
| 1. Simple GET            |      |          |       |       |                 |      |
| 2. Custom-header GET     |      |          |       |       |                 |      |
| 3. Simple POST           |      |          |       |       |                 |      |
| 4. POST with JSON        |      |          |       |       |                 |      |
| 5. GET with credentials  |      |          |       |       |                 |      |

ヒント: 3 (Simple POST) は preflight が無いので `none` でも**サーバログには届く**（HIT）が、JS からはレスポンスが読めない（BLOCK）。読み取りはブロックされても書き込み（副作用）は起きるという CORS の本質を観察できる。

## 観察ポイント

- **DevTools Console**: ブラウザが出すエラー文を読む。`No 'Access-Control-Allow-Origin' header` / `did not succeed` / `does not allow credentials` などモード別に文言が変わる。
- **DevTools Network**: preflight が必要なボタン (2,4) では `OPTIONS /probe` が**先に1本**飛ぶ。これが落ちると本リクエストは送信されない。
- **API サーバ標準出力**: `[mode=...] METHOD /path origin=... has-custom-header=...` を1行で吐く。POST が到達したときは `>>> POST RECEIVED` が立つ。**ブラウザでエラーが出ているのにこの行が出る瞬間**が CORS の核心（読み取り遮断 ≠ 副作用阻止）。

## 症状: 全ボタン Failed to fetch のとき

`Failed to fetch` は CORS 拒否でも TCP 失敗でも同じ TypeError を出すので、ボタンを押すだけでは切り分けられない。まずページ上部の **Run diagnostics** を押す。`/healthz` は `CORS_MODE` 非依存で常に `Allow-Origin: *` を返すコントロール用エンドポイントなので、純粋な到達性の試金石になる。

- **D4 (no-cors) だけ成功 / D1〜D3 失敗**: ブラウザの CORS パスのみ落ちている純粋な CORS 動作。実験は正しく機能している。本来のボタン側で目的の挙動を観察してよい。
- **D4 も失敗（=全滅）**: 接続層の問題。サーバ側に `[wire] client=...` ログが出ていなければ TCP すら届いていない。Firewall / VPN / 拡張機能 / Private Network Access / 企業プロキシを順に疑う。
- **D2 (127.0.0.1) / D3 ([::1]) は成功 / D1 (localhost) だけ失敗**: 名前解決層の問題。`/etc/hosts` の `localhost` 行や DNS resolver、`scutil --dns` を確認。
- **D5 (XHR) だけ成功 or 失敗**: fetch と XHR は実装パスが別。XHR だけ通るなら fetch 側の Service Worker / 拡張機能 / Private Network Access プリフライトを疑う。逆に XHR だけ落ちるなら Mixed-content 系の制約が効いている可能性。

## 既知の注意点

- preflight 結果はブラウザにキャッシュされる（`Access-Control-Max-Age` 既定で5秒〜数分）。モード切替の効果が出ないときは DevTools Network パネルで **Disable cache** をオン、または別タブ/シークレットで開き直す。
- `credentials: 'include'` ではブラウザ実装によりオリジン以外への Cookie 送信が制限されるため、ローカルでは Cookie 自体は飛ばないことがある。観察したいのは「`*` + credentials が拒否される」点だけなので、Cookie が無くても十分。
- 一部ブラウザ拡張が CORS ヘッダを書き換える。挙動が教科書と違ったら拡張を切ってシークレットで再現する。

## 関連リファレンス

- [why-cors-exists-three-actors](../../docs/learning/phase1/task3/reference/why-cors-exists-three-actors.md)
- [cors-only-blocks-reads-not-writes](../../docs/learning/phase1/task3/reference/cors-only-blocks-reads-not-writes.md)
- [preflight-bypass-via-simple-post](../../docs/learning/phase1/task3/reference/preflight-bypass-via-simple-post.md)
- [cors-error-server-side-visibility](../../docs/learning/phase1/task3/reference/cors-error-server-side-visibility.md)
