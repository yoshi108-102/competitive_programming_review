# AWS 学習 sandbox (Phase 別 実 AWS・ハイブリッド観測)
# 設計: docs/superpowers/specs/2026-05-31-aws-phase-sandboxes-design.md
# 普段は moto+terraform validate で無料検証、観測時だけ up->load->watch->down。
PHASES      := 1 2 3 4 5 6 7 8 9 10
SANDBOX_DIR := $(ROOT)/terraform/sandboxes
# provider plugin 共有キャッシュ (ユーザーの make 実行を高速化)
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
	@if [ -d "$(BACKEND)/tests/sandboxes/phase$*" ]; then \
	  echo "==> moto pytest phase$*"; \
	  cd $(BACKEND) && uv run pytest "tests/sandboxes/phase$*" -v; \
	else echo "==> phase$* に moto テストなし (validate のみ)"; fi
	@echo "==> terraform validate phase$*"
	@terraform -chdir="$(SANDBOX_DIR)/phase$*" init -backend=false -input=false >/dev/null && \
	 terraform -chdir="$(SANDBOX_DIR)/phase$*" validate

sandbox-up-phase%: FORCE
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	@terraform -chdir="$(SANDBOX_DIR)/phase$*" init -input=false && \
	 terraform -chdir="$(SANDBOX_DIR)/phase$*" apply -auto-approve

sandbox-load-phase%: FORCE
	@bash "$(SANDBOX_DIR)/phase$*/load.sh"

sandbox-watch-phase%: FORCE
	@bash "$(SANDBOX_DIR)/phase$*/watch.sh"

sandbox-down-phase%: FORCE
	@terraform -chdir="$(SANDBOX_DIR)/phase$*" destroy -auto-approve

# fail-fast 回避: 失敗しても次へ継続。未 apply phase はスキップ。最後に失敗集計。
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
	@terraform -chdir="$(SANDBOX_DIR)/_budget" init -input=false && \
	 terraform -chdir="$(SANDBOX_DIR)/_budget" apply -auto-approve
