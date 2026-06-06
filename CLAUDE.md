# AtCoder Review - プロジェクトコンテキスト

## 目的

AWS学習プロジェクト。AtCoder復習支援ツールを10 Phaseに分けて段階的に構築し、各PhaseでAWSサービスを1-2個ずつ学ぶ。

## 最重要ルール

- **勝手に実装を進めない**: 各ステップで解説 → ユーザー確認 → 実装の順序を守る
- **質疑応答・深掘りはdocsに残す**: 各トピックディレクトリ内の `reference/` に md+html の二本立てで記録（→ 教材・UI のフォーマット規約）
- **referenceは別ファイルでトピックに同梱**: 深掘りは各トピックの `reference/` に分離し、トピック教材と相互リンクする

## 現在の進捗

Phase 1 / Task 1（Terraform DynamoDBモジュール）の学習段階。詳細は `docs/LEARNING_CONTEXT.md` を参照。

## ドキュメント構成

- `plans/` — Phase設計書、実装計画
- `docs/learning/` — 学習ノート（Phase/Task別）
- `docs/LEARNING_CONTEXT.md` — 学習フローの全体像、進捗、ドキュメントルール
- `docs/superpowers/` — 設計 spec / 実装計画（brainstorming・writing-plans 由来）

## 教材・UI のフォーマット規約

### 教材はトピックごとのディレクトリ＋二本立て

- **1 トピック = 1 ディレクトリ**。`docs/learning/phase{N}/{NN}-{topic-slug}/` を作り、その中に教材を **二本立て**で置く:
  - `index.md` — Markdown（エディタ/GitHub 閲覧用）
  - `index.html` — note 風 HTML（ブラウザ閲覧用）。`index.md` の **twin**（同一内容を忠実変換し、内容を落とさない）
- **reference（深掘り）は同じトピックディレクトリ内の `reference/` に置く**。reference も **md + note 風 HTML の二本立て**（`reference/{ref-slug}.md` ↔ `reference/{ref-slug}.html`）。
- **トピック ⇄ reference を相互リンク**: トピック教材の末尾に「関連・深掘り（reference）」節を設けて配下の reference へリンクし、reference 側はトピック（`../index.html` / `../index.md`）へ戻リンクする。

ディレクトリ構成（例）:

```
docs/learning/phase{N}/
├── main.md                      ← Markdown ルーター（トピック目次）
├── index.html                   ← HTML ルーター（ランディング）
├── demo/index.html              ← テスト UI（note 風・インタラクティブ）
├── handson.md / handson.html    ← 実 AWS sandbox ハンズオン
└── {NN}-{topic-slug}/           ← トピックごとのディレクトリ
    ├── index.md                 ← 教材 Markdown
    ├── index.html               ← 教材 note 風 HTML（index.md の twin）
    └── reference/               ← このトピックの深掘り（md+html 二本立て）
        ├── {ref-slug}.md
        └── {ref-slug}.html      ← md の twin
```

### ルーティング（Phase ごと）

- `docs/learning/phase{N}/main.md` — **Markdown 側の目次（ルーター）**。各トピックの `{NN}-{topic-slug}/index.md` へのリンク集。
- `docs/learning/phase{N}/index.html` — **HTML 側のランディング（ルーター）**。各トピックの `{NN}-{topic-slug}/index.html`・**テスト UI（デモ）**・ハンズオンへの入口。

### その他

- **テスト UI も note 風 HTML**: インタラクティブなデモ/プレイグラウンドは `docs/learning/phase{N}/demo/index.html` に置き、`index.html` ルーターから辿れるようにする。
- **ハンズオンを必ず入れる**: 教材（md・html とも）とルーターには、対応する **実 AWS sandbox の操作手順**（`make sandbox-{test,up,load,watch,down}-phase{N}` の流れ・観測ポイント・コスト/destroy 注意）の「ハンズオン」節を入れる。
- **デザインは note.com 風で統一**: 白基調・1カラム（読み幅 ~720px）・Noto Sans JP・行間広め・落ち着いた 1 アクセント・派手な演出なし。
- 実 AWS の `apply`/`destroy` は Claude は実行しない（ユーザーが make で実行）。ハンズオンは手順と期待値の説明にとどめる。
