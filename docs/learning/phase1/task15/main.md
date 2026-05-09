# Phase 1 / Task 15: Frontend — 提出詳細ページ

## 概要

`/submissions/[submission_id]` で 1 件の提出詳細を表示。Backend `GET /submissions/{submission_id}` を呼ぶ。

主な学習ポイント:
- Next.js 16 の動的ルート: `params: Promise<{ submission_id: string }>` + `use(params)`
- 404 のハンドリング (Backend が `NOT_FOUND` を返したら専用 UI)

## 目次

- 共通教材: [Task 12 / 01](../task12/01-nextjs-client-page-with-auth-and-api.md) §F (動的ルート)

## 振り返り

（Task 内の全 Topic クイズ完了後に生成）
