# 01. Frontend 結合テスト手順

> 出典:
> - [Next.js - Environment Variables](https://nextjs.org/docs/app/guides/environment-variables)
> - [AWS Amplify Auth - JavaScript](https://docs.amplify.aws/javascript/build-a-backend/auth/)
>
> 閲覧日 2026-05-09

## 概要

Phase 1 の最後の確認。Frontend (`localhost:3000`) から本番デプロイ済みの API Gateway を叩いて、認証 → 設定登録 → 同期 → 一覧 → 詳細の **end-to-end フロー** が動くことを確認する。

## 手順

### Step 1: Terraform output の値を `.env.local` に転記

ルート `Makefile` の sync-env ターゲットが `terraform output -raw` から値を取り出して `frontend/.env.local` に書き出す:

```bash
make sync-env
```

実行内容:
1. `terraform output -raw cognito_user_pool_id`
2. `terraform output -raw cognito_user_pool_client_id`
3. `terraform output -raw api_gateway_url`
4. これらを `NEXT_PUBLIC_*` 接頭辞付きで `frontend/.env.local` に書き込み

### Step 2: Frontend 起動

```bash
cd frontend
npm install   # 初回のみ
npm run dev
```

→ `http://localhost:3000` でアクセス可能。

### Step 3: ログイン

`http://localhost:3000` を開くと **Authenticator (Amplify UI)** のログイン画面。
Task 17 で作った Cognito ユーザー (例: `test@example.com` / `RealPass123!`) でログインする。

### Step 4: 設定 → 同期 → 一覧 のフロー

1. ナビの「設定」→ AtCoder ユーザー名（自分のもの or `chokudai` 等）を入力 → 保存
   - 期待: 緑のメッセージ「保存しました: {username}」
2. ナビの「提出一覧」→「AtCoder と同期」ボタン
   - 期待: 「N 件取得しました」とテーブル表示
3. テーブルの「詳細」リンク → `/submissions/{submission_id}`
   - 期待: 提出詳細表示

### Step 5: ブラウザ DevTools で CORS / レスポンス確認

DevTools Network タブで:
- `OPTIONS /users/me` が 200 を返している (preflight 成功)
- `POST /users/me` の応答ヘッダに `Access-Control-Allow-Origin: *` がある
- `Authorization: Bearer eyJ...` ヘッダが送信されている

ここがちゃんと出来ていれば Phase 1 完成。

## 想定トラブル

| 症状 | 当たり |
|---|---|
| Authenticator が表示されない | `NEXT_PUBLIC_COGNITO_*` の値ミス |
| ログイン後 fetch で CORS エラー | Lambda or API Gateway 側の `Access-Control-Allow-Origin` 漏れ |
| 401 Unauthorized | JWT 期限切れ → 一度ログアウトして再ログイン |
| `/sync` が `USER_NOT_CONFIGURED` | 先に設定で AtCoder username を登録する |
| `/submissions` 空配列 | sync 未実行 or 該当ユーザーに submission ゼロ |
| TypeError: undefined is not an object | env 変数が反映されていない → `npm run dev` を再起動 |

## 環境変数の流れ

```
[Terraform output (state)]
       │
       │ terraform output -raw
       ↓
[.env.local (local file, gitignore)]
       │
       │ Next.js が起動時に読み込み
       ↓
[process.env.NEXT_PUBLIC_*]
       │
       │ ビルド時にクライアント JS に埋め込み
       ↓
[ブラウザの JS]
```

**`NEXT_PUBLIC_` 接頭辞**は Next.js の規約。これを付けると **クライアント JS にバンドルされる**。
Cognito User Pool ID 等は公開しても安全（DDoS の懸念のみで、認証情報自体ではない）なので問題ない。
**シークレット類 (DB password 等) は絶対に `NEXT_PUBLIC_` を付けない**。

## 重要ポイント

- 環境変数は **Terraform output → `.env.local` → Next.js process** の 3 段階
- `NEXT_PUBLIC_` 接頭辞 = クライアント露出。それ以外はサーバ専用
- CORS は **2 系統で揃える**: API Gateway OPTIONS (preflight) + Lambda 応答 (本リクエスト) の両方
- DevTools Network タブで Authorization ヘッダ・CORS ヘッダ・status code を最終確認

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 関連 Task: Task 17 (Terraform apply で値を取得), Task 11 (API クライアントが env を読む実装)

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_
