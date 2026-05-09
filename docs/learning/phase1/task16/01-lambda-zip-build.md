# 01. Lambda デプロイパッケージのビルド方法

> 出典: [AWS Lambda - Working with .zip file archives for Python](https://docs.aws.amazon.com/lambda/latest/dg/python-package.html)（閲覧日 2026-05-09）

## 概要

AWS Lambda の Python ランタイムは「ZIP の **ルートに** 配置されたモジュール」を import 可能にする。
ハンドラ識別子 `lambdas.save_user.handler.lambda_handler` (Terraform 側で指定、Task 9) は、ZIP のルートから

```
lambdas/save_user/handler.py 内の lambda_handler 関数
```

を解決する。**ハンドラ識別子の `.` 区切りが ZIP 内のディレクトリ構造に対応**する。

## 公式 docs に沿った解説

### A. デプロイパッケージの構造

公式 docs より、最小構造:

```
my_function.zip
├── handler.py          ← ハンドラ識別子 "handler.lambda_handler" の場合
└── (依存ライブラリ)
```

このプロジェクトのように複数ハンドラを 1 ZIP に詰める場合:

```
lambda.zip
├── shared/
│   ├── __init__.py
│   ├── response.py
│   ├── db.py
│   └── atcoder_client.py
├── lambdas/
│   ├── __init__.py
│   ├── save_user/
│   │   ├── __init__.py
│   │   └── handler.py        ← lambdas.save_user.handler.lambda_handler
│   ├── sync_submissions/
│   │   └── handler.py
│   └── get_submissions/
│       └── handler.py
├── boto3/
├── botocore/
├── requests/                  ← Task 5 で追加した依存
├── certifi/
├── charset_normalizer/
├── idna/
└── urllib3/
```

複数ハンドラ用に別々の ZIP を作る選択肢もあるが、共有コード (`shared/*`) を重複させる必要があるため、**1 ZIP 共有**が運用効率が良い。Terraform 側で `for_each` の各関数が同じ ZIP を参照する。

### B. 依存ライブラリの含め方

`pip install --target <dir>` で **指定ディレクトリに平坦にインストール**する:

```bash
pip install -r requirements.txt --target ./build
```

これで `./build/boto3/`, `./build/requests/` などができる。
このプロジェクトでは `uv` を使っているので:

```bash
uv export --no-hashes --format requirements-txt > requirements.txt
pip install -r requirements.txt --target ./build
```

または `uv pip install`:

```bash
uv pip install --target ./build -r requirements.txt
```

### C. Boto3 の特殊事情

AWS Lambda Python ランタイムには **boto3 が事前インストール**されている。同梱版を使う選択肢:

| 方針 | メリット | デメリット |
|---|---|---|
| 自前で含める | バージョン固定。新機能を即使える | ZIP サイズが増える (~10MB) |
| 同梱版を使う | ZIP 軽量 | バージョンが Lambda runtime 側都合で変わる |

このプロジェクトでは **自前で含める**方針。再現性とローカルテスト (moto + boto3) との整合のため。

### D. プラットフォーム差の注意

`requests` のような pure Python なら問題ないが、**C 拡張を含むパッケージ**は Lambda の実行環境 (Amazon Linux 2023, x86_64) と一致するビルドが必要。

このプロジェクトの依存 (`boto3`, `requests`) はいずれも pure Python なので普通にローカル (macOS) でビルドして OK。
将来 `numpy` 等を入れるなら `pip install --platform manylinux2014_x86_64 --only-binary=:all: ...` のような細工が必要になる。

### E. Make ターゲット

このプロジェクトはルートの `Makefile` でビルドを管理する:

```makefile
build: $(ZIP_PATH)

$(ZIP_PATH): $(BACKEND)/pyproject.toml $(BACKEND)/uv.lock \
             $(shell find $(BACKEND)/shared $(BACKEND)/lambdas -type f -name '*.py')
	rm -rf $(BUILD_DIR) $(ZIP_PATH)
	mkdir -p $(BUILD_DIR)
	cd $(BACKEND) && uv export --no-hashes --no-dev --format requirements-txt > $(BUILD_DIR)/requirements.txt
	cd $(BACKEND) && uv pip install --target $(BUILD_DIR) --requirement $(BUILD_DIR)/requirements.txt
	rm -f $(BUILD_DIR)/requirements.txt
	cp -r $(BACKEND)/shared $(BUILD_DIR)/
	cp -r $(BACKEND)/lambdas $(BUILD_DIR)/
	find $(BUILD_DIR) -type d -name __pycache__ -exec rm -rf {} +
	cd $(BUILD_DIR) && zip -rq ../lambda.zip .
```

実行: `make build`

**Make を使う利点**:
- 実ファイルターゲット (`$(ZIP_PATH)` を target、ソースを prerequisite とする) で**変更がなければ再ビルドをスキップ**できる
- bash スクリプトだと毎回フルでビルドし直す
- `pyproject.toml` / `uv.lock` / `*.py` のいずれかが変わったらだけ再ビルドが走る

Terraform はこの ZIP を `filename` で参照（Task 9）:

```hcl
filename         = "../backend/dist/lambda.zip"
source_code_hash = filebase64sha256("../backend/dist/lambda.zip")
```

`source_code_hash` のおかげで、ビルドし直して中身が変わると次の `terraform apply` で関数が更新される。

## 重要ポイント

- ハンドラ識別子の `.` 区切り = ZIP 内のパス区切り
- 依存は `pip install --target` で平坦にインストールしてから ZIP 化
- このプロジェクトは **1 ZIP に全ハンドラ + 全依存**を詰める運用 (共有コード重複防止)
- C 拡張なしの依存だけなら macOS でビルドして OK
- `terraform apply` で更新するには `source_code_hash = filebase64sha256(...)` 必須

## 関連

- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）
- 関連 Task: Task 9 (ZIP を Terraform で参照), Task 17 (apply で実際にデプロイ)

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_
