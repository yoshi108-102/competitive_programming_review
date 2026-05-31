# AWS Phase 別 実 AWS sandbox（ハイブリッド観測） Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 各 Phase の AWS サービスを実 AWS に短時間立てて CloudWatch で観測できる、Phase 別に独立した sandbox 群（IaC＋ロード/観測スクリプト＋moto テスト＋脱線リッチ教材）を一括で用意する。

**Architecture:** `terraform/sandboxes/phaseN/` を Phase 別の独立 Terraform ルート（ローカル state・`Sandbox=phaseN` タグ・セキュリティ堅牢化）として作り、Makefile pattern target（test/up/load/watch/down）でハイブリッド運用する。普段は `moto` pytest ＋ `terraform validate` で無料検証し、観測時のみ `apply→load→watch→destroy`。Claude は apply/destroy を実行しない。

**Tech Stack:** Terraform (aws ~> 5.0 / archive), Python 3.12 Lambda (boto3/標準ライブラリ), moto, pytest, GNU Make, bash, AWS CLI v2。

**実装源（canonical）:** 各 Phase の具体リソース・load.sh・watch.sh・脱線・extra-credit のコードは設計書 `docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md` の「### Phase N」節に詳細がある。各タスクはそこを実装源とし、`terraform validate` と moto pytest を通る正しいコードに仕上げる（spec は設計レベルのため、構文・参照は実装時に検証して直す）。

**実行方式:** 本計画は sonnet サブエージェントのワークフローで Phase 並列に実装する（各 sandbox は独立なので並列と相性が良い）。共有スキャフォールド（Task 0）は決定的に作成し、Phase タスクは並列生成後に `make sandbox-test-phaseN` でゲートする。

---

## File Structure

```
Makefile                                  # Task 0: sandbox pattern target 追加
terraform/sandboxes/
  _budget/                                # Task 0: アカウント Budget(us-east-1)
    main.tf  variables.tf  .gitignore
  phase1/ ... phase10/                    # Task 1-10: 各 Phase 独立ルート
    providers.tf      # required_providers 固定 + provider(region/default_tags)
    variables.tf
    main.tf           # リソース本体 + aws_cloudwatch_dashboard + log_group
    outputs.tf
    load.sh           # set -euo pipefail / 活動生成
    watch.sh          # set -euo pipefail / get-dashboard スモーク + メトリクス + destroy リマインダ
    README.md         # 構成図・手順・脱線リンク・コスト注意
    .gitignore        # *.tfstate* / .terraform/ / *.zip
    (.terraform.lock.hcl は実装時 init 後にコミット)
    lambda_src/handler.py   # Lambda がある Phase のみ
backend/sandboxes/phaseN/handler.py        # （任意配置）handler の正準ソース。lambda_src からの参照でも可
backend/tests/sandboxes/phaseN/test_handler.py  # moto テスト（handler がある Phase のみ）
docs/learning/phaseN/preview-*.md          # Task 11: 脱線で拡充
docs/learning/phaseN/demo/index.html       # Task 11: 「実物で動かす」一行追記（存在 Phase のみ）
docs/learning/cross-cutting/               # Task 11: 横断テーマページ（任意）
```

各ルートは **1プロバイダ＝1リージョン**（Phase 5 のみ全リソース us-east-1）。複数リージョンを混在させない（alias 不要化）。

---

## Task 0: 共有スキャフォールド（Makefile / _budget / gitignore 雛形）

**Files:**
- Modify: `Makefile`（`.PHONY` 行付近と末尾 Cleanup セクション前に追記）
- Create: `terraform/sandboxes/_budget/main.tf`, `terraform/sandboxes/_budget/variables.tf`, `terraform/sandboxes/_budget/.gitignore`

- [ ] **Step 1: Makefile に sandbox セクションを追記**

`Makefile` の既存 `# AWS 学習デモサイト` セクションの直後（`# Cleanup` セクションの前）に以下を追記する。`ROOT`/`BACKEND` は既存定義を再利用。

```makefile
# ===========================================================================
# AWS 学習 sandbox (Phase 別 実 AWS・ハイブリッド観測)
# 設計: docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md
# 普段は moto+terraform validate で無料検証、観測時だけ up->load->watch->down。
# ===========================================================================
PHASES      := 1 2 3 4 5 6 7 8 9 10
SANDBOX_DIR := $(ROOT)/terraform/sandboxes
# provider plugin 共有キャッシュ (各 phase の init を高速化)
TF_PLUGIN_CACHE_DIR ?= $(HOME)/.terraform.d/plugin-cache
export TF_PLUGIN_CACHE_DIR

.PHONY: sandbox sandbox-down-all sandbox-budget FORCE
FORCE:

sandbox: ## AWS sandbox の使い方 (make sandbox-{test,up,load,watch,down}-phaseN, N=1..10)
	@echo "AWS 学習 sandbox — Phase 別 実 AWS をハイブリッド観測"
	@echo "  make sandbox-test-phaseN    # moto pytest + terraform validate (無料・無起動)"
	@echo "  make sandbox-up-phaseN      # terraform apply (実課金リソース作成)"
	@echo "  make sandbox-load-phaseN    # 活動生成 (load.sh)"
	@echo "  make sandbox-watch-phaseN   # CloudWatch ダッシュボード/メトリクス (watch.sh)"
	@echo "  make sandbox-down-phaseN    # terraform destroy (課金停止)"
	@echo "  make sandbox-down-all       # 全 phase destroy (apply 済みのみ)"
	@echo "  make sandbox-budget         # アカウント Budget アラーム (us-east-1, 任意)"

# moto pytest(あれば) + terraform validate。-backend=false で軽量、graceful skip。
sandbox-test-phase%: FORCE
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	@d="$(SANDBOX_DIR)/phase$*"; \
	 if [ -d "$(BACKEND)/tests/sandboxes/phase$*" ]; then \
	   echo "==> moto pytest phase$*"; \
	   cd $(BACKEND) && uv run pytest "tests/sandboxes/phase$*" -v; \
	 else echo "==> phase$* に moto テストなし(validate のみ)"; fi
	@d="$(SANDBOX_DIR)/phase$*"; \
	 echo "==> terraform validate phase$*"; \
	 terraform -chdir="$$d" init -backend=false -input=false >/dev/null && \
	 terraform -chdir="$$d" validate

sandbox-up-phase%: FORCE
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	@d="$(SANDBOX_DIR)/phase$*"; \
	 terraform -chdir="$$d" init -input=false && \
	 terraform -chdir="$$d" apply -auto-approve

sandbox-load-phase%: FORCE
	@bash "$(SANDBOX_DIR)/phase$*/load.sh"

sandbox-watch-phase%: FORCE
	@bash "$(SANDBOX_DIR)/phase$*/watch.sh"

sandbox-down-phase%: FORCE
	@terraform -chdir="$(SANDBOX_DIR)/phase$*" destroy -auto-approve

# fail-fast 回避: 失敗しても次へ。未 apply phase はスキップ。最後に失敗集計。
sandbox-down-all:
	@failed=""; for n in $(PHASES); do \
	  d="$(SANDBOX_DIR)/phase$$n"; \
	  if [ -d "$$d/.terraform" ] || [ -f "$$d/terraform.tfstate" ]; then \
	    echo "==> destroy phase$$n"; \
	    terraform -chdir="$$d" destroy -auto-approve || failed="$$failed $$n"; \
	  else echo "==> skip phase$$n (未 apply)"; fi; \
	done; \
	if [ -n "$$failed" ]; then echo "WARN: destroy 失敗 phase:$$failed (手動確認)"; exit 1; fi

sandbox-budget:
	@d="$(SANDBOX_DIR)/_budget"; \
	 terraform -chdir="$$d" init -input=false && terraform -chdir="$$d" apply -auto-approve
```

- [ ] **Step 2: `make sandbox` が動くことを確認**

Run: `make sandbox`
Expected: 使い方が表示される（pattern target はファイルを触らないので副作用なし）。

- [ ] **Step 3: `_budget` ルートを作成**

`terraform/sandboxes/_budget/main.tf`（Budgets API は us-east-1）:

```hcl
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# AWS Budgets は us-east-1 エンドポイント。region を固定する。
provider "aws" {
  region = "us-east-1"
  default_tags { tags = { Sandbox = "_budget", ManagedBy = "terraform" } }
}

resource "aws_budgets_budget" "monthly" {
  name         = "atcoder-sandbox-monthly"
  budget_type  = "COST"
  limit_amount = var.limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notify_email]
  }
}
```

`terraform/sandboxes/_budget/variables.tf`:

```hcl
variable "limit_usd"   { type = string, default = "5" }
variable "notify_email" { type = string }
```

`terraform/sandboxes/_budget/.gitignore`:

```
*.tfstate*
.terraform/
.terraform.lock.hcl
```

> 注: Budget はアカウントあたり 2 個まで無料。3 個目以降 $0.02/budget/日。既存 budget の有無を確認すること。

- [ ] **Step 4: コミット**

```bash
git add Makefile terraform/sandboxes/_budget
git commit -m "sandbox: Makefile pattern target と _budget スキャフォールド追加"
```

---

## Task 1〜10: 各 Phase の sandbox

各 Phase タスクは同じ手順骨格を踏む。Phase 固有の中身は **設計書の「### Phase N」節を実装源**とし、`terraform validate` と（handler があれば）moto pytest が通るよう仕上げる。

### 共通手順（各 Phase N で実施）

- [ ] **Step 1: ルートを作成** — `terraform/sandboxes/phaseN/` に `providers.tf`/`variables.tf`/`main.tf`/`outputs.tf`/`.gitignore` を作成。
  - `providers.tf`: `required_version >= 1.7`、`required_providers { aws = { source="hashicorp/aws", version="~> 5.0" } }`（archive を使う Phase は `archive = { source="hashicorp/archive" }` も）。`provider "aws"` は単一 region（Phase 5 は `us-east-1`、他は `ap-northeast-1`）＋ `default_tags { tags = { Sandbox = "phaseN" } }`。
  - `.gitignore`: `*.tfstate*` / `.terraform/` / `*.zip`（`.terraform.lock.hcl` は **コミットする**ので含めない）。
  - 各 Lambda に対し `aws_cloudwatch_log_group`（`name = "/aws/lambda/<fn>"`, `retention_in_days = 1`）を明示定義。
  - S3 を作る Phase（2,5）は `force_destroy = true` ＋ `aws_s3_bucket_public_access_block`（全 true）＋ 暗号化。
  - `aws_cloudwatch_dashboard` を1枚（Phase 9 は Lambda 通常メトリクス＋X-Ray コンソール deep link、Phase 5 は widget の `region` を `us-east-1`）。
- [ ] **Step 2: Lambda handler（必要 Phase のみ）** — `terraform/sandboxes/phaseN/lambda_src/handler.py` を作成。boto3 は使ってよいが、可能なら標準ライブラリ優先。`data "archive_file"` で zip 化（`output_path = "${path.module}/.terraform/handler.zip"`）。
- [ ] **Step 3: load.sh / watch.sh** — 先頭に `#!/usr/bin/env bash` と `set -euo pipefail` 必須。
  - `load.sh`: 設計書の活動生成シナリオを実装。
  - `watch.sh`: 冒頭で `aws cloudwatch get-dashboard --dashboard-name ...` 存在スモーク → メトリクス反映待ち（`sleep`）→ `aws cloudwatch get-metric-statistics`（`--period` をメトリクス粒度に合わせる。SQS は 300）→ 末尾に「観測後 `make sandbox-down-phaseN` を忘れずに」リマインダ。Phase 5/9 は該当コンソール（us-east-1 / X-Ray）への deep link を出力。
- [ ] **Step 4: README.md** — 構成・手順・コスト注意・脱線リンク。
- [ ] **Step 5: moto テスト（handler がある Phase のみ）** — `backend/tests/sandboxes/phaseN/test_handler.py` を作成。既存 `backend/tests/` の 2 段階 fixture 流儀（`mock_aws`）を踏襲し、handler のロジックを検証。
- [ ] **Step 6: 検証** — Run: `make sandbox-test-phaseN`  Expected: `terraform validate` が `Success`、handler があれば pytest PASS。
- [ ] **Step 7: コミット** — `git add terraform/sandboxes/phaseN backend/*/sandboxes/phaseN; git commit -m "sandbox: phaseN <service> を追加"`

### Phase 別の要点（実装源＝設計書の対応節）

- [ ] **Task 1 — Phase 1 (MVP 観測)**: 独立ルート＋`data`（`aws_lambda_function` 等）で本番デプロイ済みリソースを lookup し、**dashboard のみ**自 state に作る。本番 state 不変更。`variables.tf` で本番リソース名（Lambda 関数名群・API GW ID・DynamoDB テーブル名・Cognito Pool ID）を受け取る。handler なし（moto テストなし → validate のみ）。設計書 §Phase 1。
- [ ] **Task 2 — Phase 2 (S3)**: bucket（`force_destroy`/BPA/SSE-KMS or SSE-S3/アクセスログ）＋ `aws_s3_bucket_metric`（リクエストメトリクス）＋ `ObjectCreated`→Lambda。moto テストで handler 検証。設計書 §Phase 2。
- [ ] **Task 3 — Phase 3 (SQS)**: queue＋DLQ＋producer/consumer Lambda（SSE 暗号化・最小権限）。watch.sh は `--period 300`＋「load 後5分待つ」。moto テスト。設計書 §Phase 3。
- [ ] **Task 4 — Phase 4 (CloudWatch)**: カスタムメトリクス発行 Lambda（標準解像度 60）＋ `aws_cloudwatch_metric_alarm`（→SNS）＋ dashboard。moto テスト（put_metric_data 検証）。設計書 §Phase 4。
- [ ] **Task 5 — Phase 5 (CloudFront + WAF)**: **全リソース us-east-1 単一 provider**。S3 origin（`force_destroy`/OAC）＋ CloudFront ＋ WAF Web ACL（`scope = CLOUDFRONT`、マネージドルール＋レートベース）。dashboard widget `region = "us-east-1"`。caveat: 作成/破棄 最大30-45分。設計書 §Phase 5。
- [ ] **Task 6 — Phase 6 (Bedrock)**: Claude 呼出 Lambda。load.sh は終了コード確認し 403（モデルアクセス未有効）なら案内して abort、呼出は少数固定・短プロンプト。region/model は実装時に確認（既定は実在モデルを使用）。moto は Bedrock invoke をモック（または handler の前処理のみ）。設計書 §Phase 6。
- [ ] **Task 7 — Phase 7 (EventBridge)**: `rate(1 minute)` rule → Lambda ＋ put-events シナリオ。watch.sh に destroy リマインダ強調（放置課金）。moto テスト。設計書 §Phase 7。
- [ ] **Task 8 — Phase 8 (Step Functions)**: 小さな state machine（最小権限 IAM ロール）＋ start-execution。moto テスト（handler があれば）。設計書 §Phase 8。
- [ ] **Task 9 — Phase 9 (X-Ray)**: トレース有効 Lambda → DynamoDB。dashboard は Lambda 通常メトリクス、watch.sh は X-Ray コンソール（service-map）deep link。受け入れは「X-Ray コンソールでトレース観測」を含む。moto テスト。設計書 §Phase 9。
- [ ] **Task 10 — Phase 10 (SNS)**: topic（SSE-KMS）＋ SQS 購読（＋Lambda 購読）＋ フィルタポリシー＋購読 DLQ。moto テスト。設計書 §Phase 10。

---

## Task 11: 教材・デモの拡充

**Files:**
- Modify: `docs/learning/phase2..10/preview-*.md`（脱線セクション追記）
- Modify: `docs/learning/phaseN/demo/index.html`（存在 Phase のみ、「実物で動かす」一行）
- Create: `docs/learning/cross-cutting/README.md`（横断テーマ目次、任意）

- [ ] **Step 1: preview 教材に脱線を追記** — 各 `preview-*.md` に「## 🧭 関連サービス」「## 🛡 セキュリティ課題」「## 🏗 インフラ応用」を、設計書の対応 Phase 脱線を要約して追記。
- [ ] **Step 2: デモ HTML に一行追記** — 各 `docs/learning/phaseN/demo/index.html` の「正式教材で深掘り」付近に「実物で動かす: `make sandbox-up-phaseN` → `make sandbox-watch-phaseN` → `make sandbox-down-phaseN`」を追加（ファイルが存在する Phase のみ。無ければ sandbox README に記載）。
- [ ] **Step 3: コミット** — `git add docs/learning; git commit -m "学習: sandbox 脱線で preview 教材とデモを拡充"`

---

## Task 12: 最終検証

- [ ] **Step 1: 全 Phase の無料テストを通す** — Run: `for n in 1 2 3 4 5 6 7 8 9 10; do make sandbox-test-phase$n || echo "FAIL phase$n"; done`  Expected: 各 `terraform validate` が Success、handler 付き Phase は pytest PASS。失敗ゼロ。
- [ ] **Step 2: state が git に混入していないこと** — Run: `git status --porcelain | grep -E 'tfstate|\.terraform/' || echo OK`  Expected: `OK`。
- [ ] **Step 3: 本番スタック不変更の確認** — Run: `git status --short terraform/ | grep -vE 'sandboxes/' || echo "本番 tf 変更なし"`  Expected: 本番 `terraform/`（sandboxes 以外）に変更なし。
- [ ] **Step 4: まとめコミット（必要なら lock ファイル）** — 各 Phase の `.terraform.lock.hcl` を `git add` してコミット。

---

## 検証手段の前提

- `terraform` CLI と `uv`（backend）が利用可能であること。無い場合は該当検証を skip し、その旨を報告（実 apply は元々ユーザー実行）。
- `terraform validate` は `init -backend=false` で provider を取得するためネットワークが要る（AWS アカウントは不要・無課金）。
- 実 `apply`/`load`/`watch`/`destroy` は**ユーザーが実行**する（実課金）。本計画の自動検証は validate と moto のみ。

## Self-Review メモ

- Spec coverage: §アーキテクチャ→Task0+各 Phase Step1、§Makefile→Task0、§テスト→各 Phase Step5/6・Task12、§Phase1-10→Task1-10、§横断テーマ/教材→Task11、§ガードレール（log retention/force_destroy/down-all/budget/tags）→Task0+各 Phase Step1、§受け入れ条件→Task12。
- Placeholder: Phase 別コードは設計書を実装源とする方針を明示（巨大コードの二重掲載を避けるための意図的設計。設計書はコミット済みで参照可能）。
- Type 整合: Makefile の変数（`PHASES`/`SANDBOX_DIR`/`TF_PLUGIN_CACHE_DIR`）と target 名は全 Phase で一貫。
