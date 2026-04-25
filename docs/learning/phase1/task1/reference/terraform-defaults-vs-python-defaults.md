# Terraform variable の `default` と Python 関数 default 引数の違い

## 概要

Terraform のモジュールを書いているとき、「`variable` ブロックに `default` を書くべきかどうか」で迷う場面がよくある。Python の関数なら `def f(x="default")` のようにほぼ常に default を書くのに、Terraform のモジュールでは「default を書かない」ことが推奨されるケースが多い。

このリファレンスは、両者の **default の意味論が根本的に違う** ことを整理する。要点を先に書くと:

- **Python の default = 「省略可能な引数」のシグナル**。関数は再利用される部品でも default を書くのが普通。
- **Terraform の default = 「呼び出し側に明示を強制しない」というシグナル**。再利用されるモジュールでは default を**書かない**方が安全になる場面が多い。

両者の差は「何が変数か」「呼び出しコストは何か」「事故ったときの被害は何か」の違いから来る。

## 詳細

### Terraform: `default` ありなしの意味

HashiCorp 公式の振る舞い:

> "If a variable does not have a default value, such as the `subnet_id` variable, then Terraform prompts the user to assign a value before it generates a plan."  
> — [Terraform Docs: Input Variables](https://developer.hashicorp.com/terraform/language/values/variables)

つまり Terraform では:

| `default` | 振る舞い |
|---|---|
| あり | **optional**。呼び出し側が省略すると default 値が使われる |
| なし | **required**。呼び出し側が値を渡さないと `terraform plan` がエラー（または対話プロンプト）になる |

`default` の優先順位は最下位:

> "The variable's `default` argument is at the lowest level of precedence."

CLI フラグ（`-var`）、`.tfvars`、環境変数、HCP Terraform の設定がすべて勝つ。`default` はあくまで「何も指定されなかったときの fallback」。

### Terraform: Root module と Child module は性質が違う

公式の表現:

> "Add `variables` blocks to your root module to let consumers pass values into the module at run time. Defining a `variable` block in a child module lets a parent module pass values into the child module at run time."

メンタルモデル:

| | Root module | Child module |
|---|---|---|
| 役割 | アプリ固有のスタックの**入り口**。`terraform` CLI が直接実行する場所 | 再利用される**部品**。別のスタックから `module "x" { source = "..." }` で呼ばれる |
| 値の供給元 | CLI の `-var`、`.tfvars`、環境変数、HCP の workspace | 親モジュールの `module` ブロック内の引数 |
| `default` の典型的な扱い | **書く**（`-var` を毎回打つのが煩雑なため） | **書かない**（呼び出し側に明示を強制） |

このプロジェクト（`atcoder-review`）の例:

```hcl
# terraform/variables.tf （ルート）
# default あり: このスタックでは値が固定なので CLI 省略可にする
variable "project_name" {
  type    = string
  default = "atcoder-review"
}

# terraform/modules/dynamodb/variables.tf （子モジュール）
# default なし: 汎用部品なので、呼び出し側で必ず指定させる
variable "table_name_prefix" {
  type        = string
  description = "DynamoDBテーブル名のプレフィックス"
  # default を書かない → ルート側で明示する責任を負わせる
}
```

### Terraform: 「default を書くべき/書くべきでない」の判断基準

業界の best practice をまとめると、軸は **環境依存性** と **「呼び出し側が考えるべきか」**:

| 値の種類 | default を書くか | 例 |
|---|---|---|
| 環境非依存・ほぼ固定 | **書く** | `enable_logging = true`、`max_retries = 3` |
| optional な collection | **書く（空コレクション）** | `tags = {}`, `subnet_ids = []` |
| プロバイダ側に default がある optional 設定 | **書く（`null`）** | `kms_key_id = null` |
| 環境ごとに変わる | **書かない** | `project_id`, `environment`, `region` |
| セキュリティに関わる | **書かない** | credentials, 公開範囲, IAM 主体 |
| 利用者が必ず意識すべき | **書かない** | 環境名、課金が発生するサイズ系 |

env0 / Spacelift / scalr の表現を要約すると:

> "For variables that have environment-independent values (such as `disk_size`), provide default values. For variables that have environment-specific values (such as `project_id`), don't provide default values."

> "Leave out defaults for values that the caller should always think about — like environment names and credentials."

書かないことには「**事故防止**」と「**意図の明示**」という積極的な意味がある:

- 呼び出し側が variable の存在に気付かないまま意図しない値で `apply` する事故を防ぐ
- モジュール作者が「この値はあなたが決めるべき」とシグナルを送れる

### Python: 関数の default 引数

Python では default は関数の **シグネチャ** に書くのが基本。

```python
def fetch(url, timeout=10, headers=None):
    if headers is None:
        headers = {}
    ...
```

意味は明確に「**省略可能な引数**」。呼び出し側は `fetch("https://...")` と書くだけで済む。

ただし有名なおとし穴がある: **mutable default の罠**。

```python
def append_item(item, items=[]):  # ❌
    items.append(item)
    return items

append_item(1)  # → [1]
append_item(2)  # → [1, 2] ←前回の状態が残る！
```

これは Python の言語仕様で:

> "Python's default arguments are evaluated once when the function is defined, not each time the function is called."  
> — [The Hitchhiker's Guide to Python: Common Gotchas](https://docs.python-guide.org/writing/gotchas/)

default 値は関数定義時に **1回だけ** 評価され、関数オブジェクトに紐付くオブジェクトとして共有される。list/dict などの mutable を default にすると、呼び出しごとに同じオブジェクトが使い回される。

回避策の慣習:

```python
def append_item(item, items=None):
    if items is None:
        items = []  # 呼び出しごとに新規生成
    items.append(item)
    return items
```

つまり Python の default は「**便利だが意味論が単純ではない**」もので、書くこと自体が問題というより「何を書くか」に注意が必要。

### なぜ「書く/書かない」の哲学が違うのか

| 観点 | Python | Terraform |
|---|---|---|
| 関数/モジュールの目的 | **ロジック** の再利用 | **インフラ構成** の再利用 |
| 呼び出しコスト | 軽い（メモリ上の関数呼び出し） | 重い（クラウドリソースの作成・課金・データ消失リスク） |
| 「省略」の被害 | 多くの場合は単に「よくある引数で実行される」 | 意図しない環境にリソースが作られる、上書きされる、消える |
| default の評価タイミング | 関数定義時に1回（罠あり） | `terraform plan` 時に毎回（罠なし） |
| 「再利用部品」の典型 | 標準ライブラリの関数（default あり） | child module（default なしが推奨） |

Terraform で default を控えめにするのは、**「事故ったときの被害が大きいから」** が本質。Python の関数で `timeout=10` をデフォルトにしても、最悪のケースは「タイムアウトが意図と違った」だけ。Terraform で `instance_type = "m5.24xlarge"` をデフォルトにしてしまうと、呼び出し側が気付かないまま月数千ドル課金される、というレベルの事故になり得る。

逆に言うと、Terraform でも **「事故にならない値」** には積極的に default を書いてよい。`enable_versioning = true`、`tags = {}`、`kms_key_id = null` のような値は default を書く方が利用者に親切。

## 比較表

| 軸 | Python 関数 default | Terraform module default |
|---|---|---|
| 書く位置 | 関数定義のシグネチャ | `variable` ブロック内 |
| `default` ありの意味 | optional 引数 | optional な変数 |
| `default` なしの意味 | 必須引数 | 必須変数（plan 時にエラー or プロンプト） |
| 評価タイミング | **関数定義時に1回**（mutable は共有される罠あり） | plan 実行時に毎回（基本は値なのでこの罠なし） |
| 「再利用部品」での慣習 | 多用される（mutable の罠を避けつつ） | 控えめ（環境依存・セキュリティ系には書かない） |
| 省略時の被害 | ロジックが想定外の挙動 | リソースが意図せず作成・破壊される可能性 |
| 優先順位 | 呼び出し側の引数 > default | CLI/tfvars/env > default（default は最下位） |

## よくある誤解

- **誤解: 「再利用される部品なら default を書くべき」**
  - 実際: Terraform の child module はその逆。再利用部品**だからこそ** default を書かず、呼び出し側に明示を強制するのが安全側。
- **誤解: 「Terraform は何も書かないと動かないので default を書いておくのが親切」**
  - 実際: `default` を書いた瞬間 optional 扱いになり、CLI の補完や IDE の警告で「未指定」を検出できなくなる。むしろ **明示を強制した方が事故を防げる**。
- **誤解: 「ルートモジュールも default なしで書くのが正統」**
  - 実際: ルートは特定プロジェクト専用で、毎回 `-var` を渡すコストが大きい。default を書いて省略可にする方が現実的。
- **誤解: 「Python の default はいつでも安全」**
  - 実際: mutable default（list, dict）は関数定義時に1回だけ評価され共有される。`None` 経由で関数内で生成するのが定石。

## まとめ

- Terraform の `default` は「optional / required」を切り替えるスイッチ。**書かない＝呼び出し側に強制**。
- Python の default は「省略可能なシグネチャ」のシグナル。**書く＝呼び出し側を楽にする**。
- 同じ "default" でも、**事故時の被害サイズと再利用の文脈** が違うので使い分ける哲学が逆転している。
- ルート（アプリ固有）= default あり、子モジュール（汎用部品）= default なし、が Terraform の典型パターン。
- Python では mutable default の罠（定義時1回評価）に注意。`None` を default にして関数内で生成。

## 参考文献

- [Input Variables — Terraform Docs (HashiCorp)](https://developer.hashicorp.com/terraform/language/values/variables) — default の振る舞いと優先順位、root/child module の使い分けの一次情報。閲覧日 2026-04-25。
- [Best practices for root modules — Terraform on Google Cloud](https://cloud.google.com/docs/terraform/best-practices/root-modules) — service module で「環境固有のものだけ variable に出し、共通値は hard-code する」原則。閲覧日 2026-04-25。
- [Terraform Modules Guide: Best Practices & Examples — env0](https://www.env0.com/blog/terraform-modules) — 「環境非依存には default、環境依存には書かない」「呼び出し側が考えるべき値（環境名、credentials）には default を書かない」のガイドライン。閲覧日 2026-04-25。
- [How to Use Terraform Variables: Examples & Best Practices — Spacelift](https://spacelift.io/blog/how-to-use-terraform-variables) — 開発フレンドリーな default、optional な list/map には空コレクション、optional な引数には `null` の使い分け。閲覧日 2026-04-25。
- [The Hitchhiker's Guide to Python: Common Gotchas](https://docs.python-guide.org/writing/gotchas/) — Python の default が定義時に1回だけ評価される仕様の説明。閲覧日 2026-04-25。
- [Python Mutable Defaults Are The Source of All Evil — Florimond Manca](https://florimond.dev/en/posts/2018/08/python-mutable-defaults-are-the-source-of-all-evil) — mutable default の具体例と回避策。閲覧日 2026-04-25。

---

_Saved at 2026-04-25 via /learning-flow:reference_
