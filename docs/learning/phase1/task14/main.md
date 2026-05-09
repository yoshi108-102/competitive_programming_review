# Phase 1 / Task 14: Frontend — 提出一覧ページ

## 概要

`/submissions` で同期 + 一覧表示。`POST /sync` ボタンと `GET /submissions?limit=...&nextToken=...` の組み合わせ。

主な学習ポイント:
- `useEffect` での初回ロード
- ページネーションの状態管理 (`nextToken` を state で持つ)
- 「もっと見る」ボタンのパターン

## 目次

- 共通教材: [Task 12 / 01](../task12/01-nextjs-client-page-with-auth-and-api.md) §D (データ取得パターン)

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
