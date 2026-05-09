# Phase 1 / Task 12: Frontend — 共通レイアウト (ナビゲーション)

## 概要

既存の `app/page.tsx` のヘッダ部分を **AppShell** コンポーネントに切り出し、`/settings` `/submissions` へのナビゲーションを追加する。
Task 13 以降の各ページが共通のヘッダで描画される土台。

主な学習ポイント:

- **Next.js 16 App Router のレイアウト合成**: `layout.tsx` から `app/components/AppShell` へ責務分離
- **`<Link>` によるクライアントサイド遷移**: `next/link`, prefetching
- **Client Component に閉じる範囲**: AppShell 自体は client (useAuthenticator 使うため)

## 目次

- [01. Next.js 16 のクライアントページ + 認証 + API 呼び出しパターン](01-nextjs-client-page-with-auth-and-api.md) — Task 12〜15 共通参照

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
