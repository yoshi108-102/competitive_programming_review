# 01. Next.js 16 のクライアントページ + 認証 + API 呼び出しパターン

> 出典:
> - [Next.js 16 - Layouts and Pages](https://nextjs.org/docs/app/getting-started/layouts-and-pages)（閲覧日 2026-05-09）
> - [Next.js 16 - Server and Client Components](https://nextjs.org/docs/app/getting-started/server-and-client-components)（閲覧日 2026-05-09）
> - [Next.js 16 - Linking and Navigating](https://nextjs.org/docs/app/getting-started/linking-and-navigating)（閲覧日 2026-05-09）
>
> このノートは Task 12〜15（layout / settings / submissions list / submission detail）で共通参照する設計教材。

## 概要

このプロジェクトの Frontend ページは概ね以下の骨格に収束する:

```tsx
"use client";  // Cognito JWT, useState, useEffect 必須なので Client Component

export default function Page() {
  // 1. state
  const [data, setData] = useState<...>(...);
  const [error, setError] = useState<...>(null);
  const [loading, setLoading] = useState(false);

  // 2. データ取得 (useEffect で初回 / refetch 関数で手動)
  useEffect(() => {
    api.something().then(setData).catch(setError);
  }, []);

  // 3. UI
  return <div>...</div>;
}
```

App Router の Server Component と区別する判断:
- 認証状態を読む (`useAuthenticator`) → Client
- `useState` / `useEffect` → Client
- `localStorage` 等のブラウザ API → Client
- それ以外 → Server を試す（このプロジェクトでは認証必須なのでほぼ全 Client）

## 公式 docs に沿った解説

### A. 全ページ Client Component の判断

このプロジェクトでは API 呼び出しに **Cognito JWT** が必要。JWT 取得は `aws-amplify/auth` の `fetchAuthSession()` で、これは **クライアント側のみ**で動く（Amplify が `localStorage` にトークンを持つため）。

選択肢:
- **(a) すべてのページを Client Component**: `"use client"` を付ける。シンプル
- **(b) Server Component で fetch + Cookie ベース認証**: より高度だが Amplify Cognito は Cookie 認証をデフォルトで持たない
- **(c) ページは Server、データ取得部分は Client**: 折衷案

このプロジェクトは MVP スピード重視で **(a)** を採用。`"use client"` を全ページに付ける。
SEO / 初期表示速度が重要になったら (c) への移行を検討。

### B. レイアウト合成

Next.js 16 の Layout は **入れ子可能**。`app/layout.tsx` がルートレイアウトで、その下に共通ヘッダなどを配置する。

```tsx
// app/layout.tsx (server component, html/body を含む)
export default function RootLayout({ children }) {
  return (
    <html lang="ja">
      <body>
        <AmplifyProvider>      {/* client - Amplify 設定 */}
          <AuthGuard>           {/* client - 未認証ならログイン画面 */}
            <AppShell>           {/* client - ヘッダ・ナビ */}
              {children}        {/* 各 page.tsx */}
            </AppShell>
          </AuthGuard>
        </AmplifyProvider>
      </body>
    </html>
  );
}
```

各ページは `children` の位置に来る。共通ヘッダが自動で付く。

### C. `<Link>` でクライアントサイド遷移

```tsx
import Link from "next/link";

<Link href="/settings">設定</Link>
<Link href="/submissions">提出一覧</Link>
```

`<Link>` は:
- viewport に入った時に **prefetch** (バックグラウンドで次ページのコードを取得)
- クリック時にフルリロードせず **client-side transition** でレンダリング
- `<a>` を使うとフルリロード（avoid）

### D. データ取得パターン (useEffect + fetch)

```tsx
"use client";

import { useEffect, useState } from "react";
import { api, ApiCallError } from "@/app/lib/api";

export default function SubmissionsPage() {
  const [items, setItems] = useState<Submission[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);

    api.listSubmissions()
      .then(({ items }) => { if (!cancelled) setItems(items); })
      .catch((e: unknown) => {
        if (!cancelled) {
          setError(e instanceof ApiCallError ? e.message : "取得エラー");
        }
      })
      .finally(() => { if (!cancelled) setLoading(false); });

    return () => { cancelled = true; };  // unmount 時の race 防止
  }, []);

  if (loading) return <p>読み込み中...</p>;
  if (error) return <p className="text-red-600">{error}</p>;
  return <SubmissionsTable items={items} />;
}
```

ポイント:
- `cancelled` フラグで unmount 後の `setState` を防ぐ（React の strict mode で 2 回マウントされても安全に）
- `try/catch` の代わりに `.then().catch().finally()` で書くと race-safe にしやすい
- `instanceof ApiCallError` で型を絞ってメッセージを取り出す

### E. フォーム + 副作用パターン

```tsx
"use client";

import { useState, FormEvent } from "react";
import { api } from "@/app/lib/api";

export default function SettingsPage() {
  const [username, setUsername] = useState("");
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setMessage(null);
    try {
      await api.saveAtcoderUsername(username);
      setMessage("保存しました");
    } catch (err) {
      setMessage(err instanceof Error ? err.message : "失敗しました");
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={onSubmit}>
      <input value={username} onChange={(e) => setUsername(e.target.value)} />
      <button disabled={saving}>{saving ? "保存中..." : "保存"}</button>
      {message && <p>{message}</p>}
    </form>
  );
}
```

### F. 動的ルート (`/submissions/[submission_id]`)

Next.js 16 では `params` が **Promise** になっている (Next.js 15 以降):

```tsx
"use client";

import { use } from "react";
import { useEffect, useState } from "react";

type PageProps = {
  params: Promise<{ submission_id: string }>;
};

export default function SubmissionDetail({ params }: PageProps) {
  const { submission_id } = use(params);  // React の use() で Promise を unwrap

  const [item, setItem] = useState<Submission | null>(null);
  // ...
}
```

`use()` は React 19 の機能で、Promise / Context を unwrap できる。Server Component なら `await params` で良いが、Client Component では `use()` を使う。

## 重要ポイント

- このプロジェクトでは Cognito JWT が必要なため、**全ページ Client Component**で書く (`"use client"`)
- `app/layout.tsx` は Server Component のままで OK。中で AmplifyProvider / AuthGuard / AppShell を入れ子に
- `<Link>` を使う。`<a>` はフルリロードになるので避ける
- データ取得は `useEffect` 内、`cancelled` フラグで race-safe に
- フォームは `useState` + `onSubmit` で。送信中は `disabled` で二重送信防止
- 動的ルートは `params: Promise<{...}>` 型、Client Component では `use(params)` で unwrap

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 関連 Task: Task 13〜15（このパターンで個別ページ実装）

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_
