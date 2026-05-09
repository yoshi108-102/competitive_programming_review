# 01. Frontend API クライアントパターン

> 出典:
> - [AWS Amplify v6 - fetchAuthSession](https://docs.amplify.aws/javascript/build-a-backend/auth/manage-user-session/)
> - [Next.js 16 - Server and Client Components](https://nextjs.org/docs/app/getting-started/server-and-client-components)
> - [MDN - Fetch API](https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API)
>
> 閲覧日 2026-05-09

## 概要

Backend が返す `{ data, meta }` / `{ error: { code, message } }` 形式（Task 3 / 03 で設計）に合わせて、TypeScript 側で型 + fetch ラッパーを書く。

このプロジェクトの Frontend は Next.js 16 の **App Router**を使っており、認証関連は **Client Components** ( `"use client"` ) で動かす（Cognito の JWT 取得と React の state 管理が必要なため）。

## 公式 docs に沿った解説

### A. Backend レスポンス型のミラー

Backend `shared/response.py::success/error` の戻り値を TS で表現:

```typescript
// Backend が返す JSON 形式（Task 3 / 03）
export type ApiSuccess<T> = {
  data: T;
  meta: Record<string, unknown> | null;
};

export type ApiError = {
  error: {
    code: string;
    message: string;
  };
};
```

ハンドラごとに `data` の型は違うので、ジェネリクス `T` で受ける。

ドメイン型（DynamoDB の item 形）:

```typescript
export type Submission = {
  user_id: string;
  submission_id: string;
  problem_id: string;
  contest_id: string;
  language: string;
  point: string;          // Decimal が default=str で文字列化されている (Task 3 / 02)
  length: number;
  result: string;
  execution_time: number | null;
  epoch_second: number;
};

export type User = {
  user_id: string;
  atcoder_username: string;
  last_sync_epoch?: number;
};
```

**重要**: `point` を `string` で型定義している。これは Backend が `Decimal` を `default=str` で文字列化するため。フロント側で数値演算したいなら `parseFloat(point)` する必要がある（Task 3 / 02 §C で触れた制約）。

### B. JWT トークンの取得 (Amplify v6)

Amplify v6 から API が変わり、トークンは `fetchAuthSession()` で取る:

```typescript
import { fetchAuthSession } from "aws-amplify/auth";

async function getIdToken(): Promise<string> {
  const session = await fetchAuthSession();
  const token = session.tokens?.idToken?.toString();
  if (!token) {
    throw new Error("Not authenticated");
  }
  return token;
}
```

`idToken` を使う理由:
- API Gateway の Cognito Authorizer は **`id_token` の検証**をデフォルトで行う
- `accessToken` でも検証できる構成があるが、Cognito User Pool のクレーム（`sub`, `email` 等）が確実に入っているのは `idToken`

### C. fetch ラッパー

毎ハンドラ呼び出しで以下を繰り返さないよう 1 箇所に閉じ込める:

1. JWT 取得 → `Authorization: Bearer ...` ヘッダ追加
2. `Content-Type: application/json` 設定
3. レスポンスを JSON にパース
4. `response.ok = false` のとき `ApiError` を読んで `Error` 例外に変換

```typescript
class ApiCallError extends Error {
  constructor(
    public code: string,
    message: string,
    public status: number,
  ) {
    super(message);
  }
}

async function apiFetch<T>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const baseUrl = process.env.NEXT_PUBLIC_API_URL;
  if (!baseUrl) throw new Error("NEXT_PUBLIC_API_URL not set");

  const token = await getIdToken();

  const res = await fetch(`${baseUrl}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      ...(init.headers ?? {}),
    },
  });

  const json = await res.json();

  if (!res.ok) {
    const err = json as ApiError;
    throw new ApiCallError(
      err.error?.code ?? "UNKNOWN",
      err.error?.message ?? "Unknown error",
      res.status,
    );
  }

  return (json as ApiSuccess<T>).data;
}
```

ポイント:
- 戻り値は **`data` 部分だけ**を返す（呼び出し側で `body.data` する手間を省く）
- 異常系は **例外に変換**（呼び出し側は `try/catch` で扱う）
- `meta` は別 API として欲しい場合は別関数を切る or 戻り値を `{data, meta}` に変える

### D. ハンドラごとの公開関数

低レイヤの `apiFetch` を呼ぶ高レイヤを 1 ハンドラ 1 関数で公開:

```typescript
export const api = {
  saveAtcoderUsername: (atcoderUsername: string) =>
    apiFetch<User>("/users/me", {
      method: "POST",
      body: JSON.stringify({ atcoder_username: atcoderUsername }),
    }),

  syncSubmissions: () =>
    apiFetch<{ synced_count: number; from_second: number }>(
      "/sync",
      { method: "POST" },
    ),

  listSubmissions: (params?: { limit?: number; nextToken?: string }) => {
    const qs = new URLSearchParams();
    if (params?.limit) qs.set("limit", String(params.limit));
    if (params?.nextToken) qs.set("nextToken", params.nextToken);
    const suffix = qs.toString() ? `?${qs}` : "";
    return apiFetch<Submission[]>(`/submissions${suffix}`);
  },

  getSubmission: (submissionId: string) =>
    apiFetch<Submission>(`/submissions/${encodeURIComponent(submissionId)}`),
};
```

このオブジェクトを Component から `import { api } from "@/lib/api"` で呼ぶと、UI 層は HTTP の細部を見ずに済む。

### E. 環境変数 (NEXT_PUBLIC_API_URL)

`process.env.NEXT_PUBLIC_API_URL` は **`NEXT_PUBLIC_` 接頭辞**でクライアント側に露出する。
Cognito の値も同様に `NEXT_PUBLIC_COGNITO_USER_POOL_ID` 等 (既存設定ファイル `app/lib/amplify-config.ts`)。

> 補足（公式 docs には記載なし）: `NEXT_PUBLIC_*` でない環境変数は **サーバ側のみ**で読める。クライアント JS から漏れない。シークレット類 (DB credential 等) は `NEXT_PUBLIC_` を付けない。

`.env.local` (gitignore) に開発用、`.env.local.example` (commit) に雛形を置く。値は Terraform apply 後に `terraform output` から取得（Task 17 + 18）。

## 重要ポイント

- Backend の `{data, meta}` / `{error}` 形式を TS で型化、fetch ラッパーは `data` 部分のみ返す
- JWT は **`fetchAuthSession().tokens.idToken`** から取得 (Amplify v6)
- API Gateway の Cognito Authorizer は **`id_token`** を検証する（`access_token` ではない）
- 異常系は `ApiCallError` 例外に変換して上に投げる
- `Decimal` フィールド (`point`) は **TS では `string`**。数値演算は `parseFloat`
- `NEXT_PUBLIC_*` 接頭辞でクライアント露出。それ以外はサーバ専用

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 関連 Task: Task 12〜15（このクライアントを使ってページを書く）

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_
