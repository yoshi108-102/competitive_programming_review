# AtCoder Review - 開発・デプロイタスク
# 各ターゲットの解説: docs/learning/phase1/task16/, task17/, task18/

# bash で実行 (set -euo pipefail を有効化するため)
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# 目標ターゲットを並べる場所 (PHONY = ファイル生成しない)
.PHONY: help test build plan apply sync-env destroy tf-validate tf-fmt clean demo

.DEFAULT_GOAL := help

# パス
ROOT       := $(CURDIR)
BACKEND    := $(ROOT)/backend
FRONTEND   := $(ROOT)/frontend
TERRAFORM  := $(ROOT)/terraform
DIST_DIR   := $(BACKEND)/dist
BUILD_DIR  := $(DIST_DIR)/build
ZIP_PATH   := $(DIST_DIR)/lambda.zip


help: ## このヘルプを表示
	@echo "AtCoder Review - Make targets"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "通常の流れ:"
	@echo "  make test       # backend テスト"
	@echo "  make plan       # build + terraform plan"
	@echo "  make apply      # 実 AWS にデプロイ (課金開始)"
	@echo "  make sync-env   # frontend/.env.local を生成"
	@echo "  cd frontend && npm run dev   # ローカル確認"
	@echo "  make destroy    # 課金停止"


# ===========================================================================
# Backend
# ===========================================================================

test: ## backend の pytest を実行
	cd $(BACKEND) && uv run pytest tests/ -v


# ===========================================================================
# Lambda ZIP build
# 設計: docs/learning/phase1/task16/01-lambda-zip-build.md
# ===========================================================================

build: $(ZIP_PATH) ## Lambda デプロイ ZIP を生成 (backend/dist/lambda.zip)

# 実ファイルターゲット: ソース or 依存定義が変わったら再ビルド
$(ZIP_PATH): $(BACKEND)/pyproject.toml $(BACKEND)/uv.lock \
             $(shell find $(BACKEND)/shared $(BACKEND)/lambdas -type f -name '*.py' 2>/dev/null)
	@echo "==> Building Lambda ZIP"
	@rm -rf $(BUILD_DIR) $(ZIP_PATH)
	@mkdir -p $(BUILD_DIR)
	@echo "==> Installing production dependencies"
	cd $(BACKEND) && uv export --no-hashes --no-dev --format requirements-txt > $(BUILD_DIR)/requirements.txt
	cd $(BACKEND) && uv pip install --target $(BUILD_DIR) --requirement $(BUILD_DIR)/requirements.txt
	@rm -f $(BUILD_DIR)/requirements.txt
	@echo "==> Copying application code"
	cp -r $(BACKEND)/shared $(BUILD_DIR)/
	cp -r $(BACKEND)/lambdas $(BUILD_DIR)/
	@echo "==> Removing __pycache__ for reproducibility"
	@find $(BUILD_DIR) -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	@find $(BUILD_DIR) -type f -name '*.pyc' -delete 2>/dev/null || true
	@echo "==> Zipping"
	cd $(BUILD_DIR) && zip -rq ../lambda.zip .
	@echo
	@echo "Built: $(ZIP_PATH) ($$(du -h $(ZIP_PATH) | cut -f1))"
	@shasum -a 256 $(ZIP_PATH)


# ===========================================================================
# Terraform
# ===========================================================================

tf-validate: ## terraform validate (provider download なしの構文チェック)
	cd $(TERRAFORM) && terraform init -backend=false >/dev/null && terraform validate

tf-fmt: ## terraform fmt -recursive
	cd $(TERRAFORM) && terraform fmt -recursive

plan: build ## build + terraform plan -out=tfplan
	cd $(TERRAFORM) && terraform plan -out=tfplan

apply: ## terraform apply tfplan (要 plan 済み、実 AWS 課金が発生)
	@if [ ! -f $(TERRAFORM)/tfplan ]; then \
		echo "ERROR: $(TERRAFORM)/tfplan が見つかりません。先に 'make plan' を実行してください。" >&2; \
		exit 1; \
	fi
	cd $(TERRAFORM) && terraform apply tfplan
	@rm -f $(TERRAFORM)/tfplan

destroy: ## terraform destroy (課金停止用)
	cd $(TERRAFORM) && terraform destroy


# ===========================================================================
# Frontend env sync
# 設計: docs/learning/phase1/task18/01-frontend-integration-test.md
# ===========================================================================

sync-env: ## terraform output から frontend/.env.local を生成
	@cd $(TERRAFORM) && \
		USER_POOL_ID=$$(terraform output -raw cognito_user_pool_id) && \
		CLIENT_ID=$$(terraform output -raw cognito_user_pool_client_id) && \
		API_URL=$$(terraform output -raw api_gateway_url) && \
		printf "NEXT_PUBLIC_COGNITO_USER_POOL_ID=%s\nNEXT_PUBLIC_COGNITO_USER_POOL_CLIENT_ID=%s\nNEXT_PUBLIC_API_URL=%s\n" \
			"$$USER_POOL_ID" "$$CLIENT_ID" "$$API_URL" > $(FRONTEND)/.env.local
	@echo "Wrote $(FRONTEND)/.env.local:"
	@cat $(FRONTEND)/.env.local


# ===========================================================================
# AWS 学習デモサイト (Phase ごとに自己完結 HTML)
# 各 Phase の概念を「触って体験」できるデモ。docs/learning/phaseN/demo/index.html
# 1 ファイル完結 (CSS/JS インライン) なのでサーバ不要・Phase 間でバグが伝播しない。
# ===========================================================================

demo: ## Phase デモの開き方を表示 (make demo-phaseN, N=1..10)
	@echo "AWS 学習デモ — Phase ごとに自己完結 HTML をブラウザで開きます"
	@echo "  使い方: make demo-phaseN     (N = 1..10)"
	@echo "  例:     make demo-phase1     # docs/learning/phase1/demo/index.html を開く"
	@echo
	@echo "現在あるデモ:"
	@ls -1 docs/learning/phase*/demo/index.html 2>/dev/null | sed 's/^/  - /' || echo "  (まだありません)"

# Phase ごとのデモを既定ブラウザで開く (例: make demo-phase5)
demo-phase%:
	@f="docs/learning/phase$*/demo/index.html"; \
	 if [ ! -f "$$f" ]; then echo "ERROR: $$f が見つかりません" >&2; exit 1; fi; \
	 echo "Opening $$f"; \
	 open "$$f" 2>/dev/null || xdg-open "$$f" 2>/dev/null || echo "手動で開いてください: $$f"


# ===========================================================================
# AWS 学習 sandbox (Phase 別 実 AWS) — ターゲットは別ファイルに分離
# ===========================================================================
-include $(ROOT)/terraform/sandboxes/sandbox.mk


# ===========================================================================
# Cleanup
# ===========================================================================

clean: ## ビルド成果物を削除
	rm -rf $(BUILD_DIR) $(ZIP_PATH) $(TERRAFORM)/tfplan
