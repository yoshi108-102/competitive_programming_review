# AtCoder Review - プロジェクトコンテキスト

## 目的

AWS学習プロジェクト。AtCoder復習支援ツールを10 Phaseに分けて段階的に構築し、各PhaseでAWSサービスを1-2個ずつ学ぶ。

## 最重要ルール

- **勝手に実装を進めない**: 各ステップで解説 → ユーザー確認 → 実装の順序を守る
- **質疑応答はdocsに残す**: `docs/learning/phase{N}/task{M}/` にトピック別mdで記録
- **referenceは別md**: 深掘り情報は `reference/` ディレクトリに分離

## 現在の進捗

Phase 1 / Task 1（Terraform DynamoDBモジュール）の学習段階。詳細は `docs/LEARNING_CONTEXT.md` を参照。

## ドキュメント構成

- `plans/` — Phase設計書、実装計画
- `docs/learning/` — 学習ノート（Phase/Task別）
- `docs/LEARNING_CONTEXT.md` — 学習フローの全体像、進捗、ドキュメントルール
- `docs/superpowers/` — 設計 spec / 実装計画（brainstorming・writing-plans 由来）

## 教材・UI のフォーマット規約

- **教材は二本立てで作る**: 同じ内容を `Markdown`（エディタ/GitHub 閲覧用）と **note 風 HTML**（ブラウザ閲覧用）の両方で用意する。HTML は Markdown の twin（例: `02-foo.md` ↔ `02-foo.html`）。
- **ルーティングは Phase ごと**:
  - `docs/learning/phase{N}/main.md` — **Markdown 側の目次（ルーター）**。その Phase の md 教材へのリンク集。
  - `docs/learning/phase{N}/index.html` — **HTML 側のランディング（ルーター）**。note 風 HTML 教材と**テスト UI（デモ）**への入口。
- **テスト UI も note 風 HTML**: インタラクティブなデモ/プレイグラウンドは `docs/learning/phase{N}/demo/index.html` に置き、`index.html` ルーターから辿れるようにする。
- **ハンズオンを必ず入れる**: 教材（md・html とも）とルーターには、対応する **実 AWS sandbox の操作手順**（`make sandbox-{test,up,load,watch,down}-phase{N}` の流れ・観測ポイント・コスト/destroy 注意）の「ハンズオン」節を入れる。
- **デザインは note.com 風で統一**: 白基調・1カラム（読み幅 ~720px）・Noto Sans JP・行間広め・落ち着いた 1 アクセント・派手な演出なし。
- 実 AWS の `apply`/`destroy` は Claude は実行しない（ユーザーが make で実行）。ハンズオンは手順と期待値の説明にとどめる。
