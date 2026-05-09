# 02. json.dumps の default パラメータと DynamoDB Decimal 問題

> 出典:
> - [Python `json` — JSON encoder and decoder](https://docs.python.org/3/library/json.html)（閲覧日 2026-05-09）
>   - `json.dumps()` シグネチャと `default` 引数: [`json.dumps`](https://docs.python.org/3/library/json.html#json.dumps)
>   - Python → JSON 型対応表: [Basic Usage](https://docs.python.org/3/library/json.html#basic-usage)
>   - JSONEncoder のサブクラス化: [`json.JSONEncoder.default`](https://docs.python.org/3/library/json.html#json.JSONEncoder.default)
> - [Boto3 DynamoDB customization reference](https://docs.aws.amazon.com/boto3/latest/reference/customizations/dynamodb.html)（閲覧日 2026-05-09）
>   - DynamoDB Number 型 ↔ Python `Decimal` の対応
>
> このノートは公式ドキュメントの「`json` モジュールの `dumps`/エンコーダ」と「Boto3 DynamoDB の型対応」を起点に、Claude が自動生成した教材です。

## 概要

Lambda が DynamoDB から取り出したデータをそのまま `json.dumps(...)` するとほぼ確実に `TypeError: Object of type Decimal is not JSON serializable` で落ちる。
これは Python 標準の JSON エンコーダが扱える型が限定されていて、DynamoDB が**意図的に** `decimal.Decimal` を返してくるためで、両者を繋ぐのが `json.dumps()` の `default` 引数（または `JSONEncoder` のサブクラス化）。

`shared/response.py` の最終的な実装は `json.dumps(body, default=str)` という 1 行に集約されるが、その「`default=str` だけで済むのか／それで本当に良いのか」を判断できるよう、ここで `default` 引数の挙動と Decimal の素性を押さえる。

> 前提（既習）: HTTP レスポンスの三要素（`statusCode` / `headers` / `body`）と CORS ヘッダの意味は [01-lambda-response-format-and-cors.md](01-lambda-response-format-and-cors.md) で扱った。本稿は `body=...` に何を渡すかという**シリアライズ層**に集中する。

## 公式 docs に沿った解説

### A. `json.dumps()` のシグネチャと `default` 引数

公式 docs より、`json.dumps()` のシグネチャは以下:

```python
json.dumps(obj, *, skipkeys=False, ensure_ascii=True, check_circular=True,
           allow_nan=True, cls=None, indent=None, separators=None,
           default=None, sort_keys=False, **kw)
```

`default` 引数の定義（公式 docs 引用）:

> If specified, **default** should be a function that gets called for objects that can't otherwise be serialized. It should return a JSON encodable version of the object or raise a `TypeError`. If not specified, `TypeError` is raised.

ポイントを噛み砕くと:

- `default` は**関数**を渡す引数（フォールバック用コールバック）
- エンコーダが「素では JSON にできない型」に出会った時にだけ呼ばれる（既知の型はスルー）
- 戻り値は **JSON 化可能な値**（`dict` / `list` / `str` / `int` / `float` / `bool` / `None` のいずれか）でなければならない
- `default` を渡さないと `TypeError` が即座に発生

### B. Python → JSON の型対応表（公式 docs より）

| Python | JSON |
|---|---|
| `dict` | object |
| `list`, `tuple` | array |
| `str` | string |
| `int`, `float`, `int`/`float` 派生 Enum | number |
| `True` | `true` |
| `False` | `false` |
| `None` | `null` |

公式 docs の補足:

> Keys in key/value pairs of JSON are always of the type `str`. When a dictionary is converted into JSON, all the keys of the dictionary are coerced to strings.

ここに**載っていない型**はすべて `default` フォールバック行きになる。代表例:

- `decimal.Decimal`
- `datetime.datetime` / `datetime.date`
- `uuid.UUID`
- `set` / `frozenset`
- `bytes` / `bytearray`
- 自作クラス全般

### C. `default=str` 慣用句

公式 docs には `default=str` という具体例は載っていないが、`default` 引数の契約（呼ばれる／JSON 化可能な値を返す）から派生する慣用パターン。

`str` 関数自体は「任意のオブジェクトを `str` 化して返す」関数なので、`default` 引数の要件（JSON 化可能な値を返す）を満たす。よって:

```python
import json
from decimal import Decimal
from datetime import datetime

json.dumps({
    "price": Decimal("100.50"),
    "ts": datetime(2026, 5, 9, 12, 0, 0),
}, default=str)
# => '{"price": "100.50", "ts": "2026-05-09 12:00:00"}'
```

特徴:

- **シンプル**: 1 行の宣言で「未知の型はとりあえず `str()` する」と決められる
- **欠点**: すべて文字列になる。クライアントが JSON で **数値として** 受け取りたい場合は型情報が落ちる（例: `100.50` → `"100.50"`）
- **代替**: 型ごとに分岐する独自関数 or `JSONEncoder` サブクラス（後述）

### D. `JSONEncoder` のサブクラス化（より厳密にやる場合）

公式 docs より:

> To extend this to recognize other objects, subclass and implement a `default()` method with another method that returns a serializable object for `o` if possible, otherwise it should call the superclass implementation (to raise `TypeError`).

例（複素数型対応、公式 docs 抜粋を整形）:

```python
class ComplexEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, complex):
            return [obj.real, obj.imag]
        # 親クラスに委ねて未知型は TypeError
        return super().default(obj)

json.dumps(2 + 1j, cls=ComplexEncoder)
# => '[2.0, 1.0]'
```

`default` 引数（関数渡し）と `cls` 引数（エンコーダクラス渡し）の使い分け:

| | `default=fn` | `cls=MyEncoder` |
|---|---|---|
| 用途 | 1 関数で済む単純なフォールバック | 型ごとに分岐したい / 再利用したい |
| 親クラスへの委譲 | できない（TypeError を自分で raise） | `super().default(obj)` で自然に書ける |
| ステート | 持てない | クラス属性として持てる |
| 速度 | 同等（公式 docs 上の差は明記なし） | 同等 |

### E. DynamoDB が `Decimal` を返す事情（boto3 docs より）

Boto3 の Table Resource ドキュメントには、DynamoDB の **Number (N)** 型と Python 型の対応として以下が示されている:

| Python | DynamoDB |
|---|---|
| `integer` | Number (N) |
| `decimal.Decimal` | Number (N) |

つまり Boto3 の `Table.get_item` などが返す数値属性は **`Decimal` インスタンス**。`int` や `float` ではない。

公式 docs 上にはっきりした「なぜ Decimal なのか」の記述はないが、設計上の含意は明確:

- DynamoDB の Number 型は内部的に**文字列で**保持され、最大 38 桁の精度を持つ（IEEE 754 浮動小数点ではない）
- これを `float` で受けると `0.1 + 0.2 == 0.3` が False になる類の精度欠落が起きる
- `Decimal` で受けることで「DynamoDB に書いた数値と帰ってきた数値がビット単位で一致する」ことを保証している

> 補足（公式 docs には記載なし）: DynamoDB Stream や AWS SDK 全般でも数値は string 表現で交換されており、Decimal 採用は Boto3 単独の癖ではなく DynamoDB 全体の設計と整合している。

### F. Decimal × json.dumps が衝突する理由

ここまでの 2 つの事実を組み合わせると、衝突は構造的:

- Boto3 は精度保護のため `Decimal` を返す
- Python 標準の `json` モジュールは Python → JSON 型対応表に `Decimal` を含めていない（`int` と `float` のみ）
- 結果: DynamoDB から取り出した item をそのまま `json.dumps()` すると `TypeError: Object of type Decimal is not JSON serializable`

```python
import json, decimal
json.dumps({"price": decimal.Decimal("100.50")})
# TypeError: Object of type Decimal is not JSON serializable
```

これは「ライブラリのバグ」ではなく、両側の **正当な設計判断**が出会った結果。だから Lambda 側で意識的に橋渡しする必要がある。

### G. `datetime` も同じ系譜

`datetime.datetime` / `datetime.date` も Python 標準の json では未対応のため、`default` フォールバックが必要。`default=str` だと:

```python
str(datetime(2026, 5, 9, 12, 0, 0))   # '2026-05-09 12:00:00'
str(datetime(2026, 5, 9, 12, 0, 0).isoformat())  # '2026-05-09T12:00:00'
```

`str()` の出力は `datetime` の場合「`YYYY-MM-DD HH:MM:SS`」と空白区切り。フロントが厳密に ISO8601 を期待するなら、`default=str` ではなく `default=lambda o: o.isoformat() if isinstance(o, datetime) else str(o)` のような分岐が必要。

> このプロジェクトでは Decimal の方が登場頻度が高く、`datetime` を直接シリアライズする箇所はまだ無い見込み。`default=str` で十分なケースに該当するが、登場した時に再考する。

## 重要ポイント

- `default` は「未知型に出会ったときに呼ばれるフォールバック関数」。**戻り値は JSON 化可能な値**でなければならない
- Python 標準 json の対応型は `dict / list / tuple / str / int / float / bool / None` のみ。**`Decimal` も `datetime` も範囲外**
- DynamoDB は精度保証のため Number 型を `Decimal` で返してくる（Boto3 の意図的な設計）
- `default=str` は「未知型はとりあえず `str()`」というワンライナーの慣用句。十分な多くのケースで使える反面、**型情報が文字列として落ちる**ことを理解しておく
- 厳密に型ごと分岐したい場合は `json.JSONEncoder` をサブクラス化して `default()` を実装、`cls=MyEncoder` で渡す
- このプロジェクトの `shared/response.py` ではまず `default=str` を採用する。後で問題が出たら `JSONEncoder` 化する設計余地を残す

## コード例

### 落ちる例

```python
import json
from decimal import Decimal

item = {"id": "SUB001", "score": Decimal("1500.5")}
json.dumps(item)
# TypeError: Object of type Decimal is not JSON serializable
```

### `default=str` で吸収

```python
import json
from decimal import Decimal

item = {"id": "SUB001", "score": Decimal("1500.5")}
json.dumps(item, default=str)
# '{"id": "SUB001", "score": "1500.5"}'
# ← score が文字列になっている点に注意
```

### `JSONEncoder` で型ごと厳密に処理

```python
import json
from decimal import Decimal
from datetime import datetime

class AppEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            # 整数値なら int、それ以外は float に
            return int(obj) if obj % 1 == 0 else float(obj)
        if isinstance(obj, datetime):
            return obj.isoformat()
        return super().default(obj)

item = {"id": "SUB001", "score": Decimal("1500.5"), "ts": datetime(2026, 5, 9)}
json.dumps(item, cls=AppEncoder)
# '{"id": "SUB001", "score": 1500.5, "ts": "2026-05-09T00:00:00"}'
```

`Decimal` → `float` キャストには微小な精度欠落リスクがある（IEEE754 の限界）。AtCoder スコアのような整数中心の用途では問題になりにくいが、金額計算では `str` 化して JS 側で文字列のまま扱う方が安全という選択肢もある。

## 関連

- 前: [01-lambda-response-format-and-cors.md](01-lambda-response-format-and-cors.md) — Lambda Proxy Integration の戻り値三要素、CORS
- 次: [03-shared-response-helper-design.md](03-shared-response-helper-design.md) — `shared/response.py` の設計ノート（このシリアライズ層を含めて 1 関数に閉じ込める）
- 議論・Q&A: （`lesson` 中に発生したら `reference/` 配下にリンクが追加されます）

---

_Auto-generated at 2026-05-09 via /learning-flow:material（公式 docs 駆動）_

## 振り返りクイズ

回答は各問の `**回答**:` 行の下に記入してください。
全問記入後に `/learning-flow:grade` を実行すると、Claude が採点して進捗を更新します。

---

### Q1. `default` 引数の契約

`json.dumps(obj, default=fn)` の `fn` に渡せる関数の **満たすべき契約** を答えよ。

具体的には:
- `fn` はどんなタイミングで呼ばれるか
- `fn` の戻り値はどうあるべきか
- 戻り値が契約を満たさなかったらどうなるか

また、以下のコードはなぜ動かないか説明せよ。

```python
import json
from decimal import Decimal

def fn(obj):
    if isinstance(obj, Decimal):
        return obj  # ← Decimal を返してしまう

json.dumps({"x": Decimal("1.5")}, default=fn)
```

**参考**:
- [`json.dumps` - Python Docs](https://docs.python.org/3/library/json.html#json.dumps)

**回答**:

---

### Q2. `default=str` の構造的トレードオフ

`shared/response.py` の MVP 実装では `json.dumps(body, default=str)` を採用する。
このワンライナー慣用句が成立する仕組みと、**フロントエンド側に与える影響**（型情報の観点）を説明せよ。

具体的には:
- なぜ組み込み関数 `str` を `default` 引数にそのまま渡せるのか（契約面で）
- DynamoDB から取れた `Decimal("1500.5")` がフロントに届いた時、JS 側で `score * 2` のような数値演算を直接できるか
- できないなら、フロント側で何をする必要があるか

**参考**:
- [`json.dumps` - Python Docs](https://docs.python.org/3/library/json.html#json.dumps)
- [Python → JSON conversion table - Python Docs](https://docs.python.org/3/library/json.html#py-to-json-table)

**回答**:

---

### Q3. なぜ Boto3 は `Decimal` を返すのか

Boto3 の DynamoDB Table Resource は数値属性を `int` でも `float` でもなく `decimal.Decimal` で返してくる。
この設計判断の理由を、**float で受けたらどんな問題が起きるか**という具体例とともに説明せよ。

ヒント: DynamoDB 側で Number 型がどう保持されているか、IEEE 754 浮動小数点の限界（例: `0.1 + 0.2 == 0.3` の結果）。

**参考**:
- [Boto3 DynamoDB customization - Valid item types](https://docs.aws.amazon.com/boto3/latest/reference/customizations/dynamodb.html)
- [Floating Point Arithmetic: Issues and Limitations - Python Docs](https://docs.python.org/3/tutorial/floatingpoint.html)

**回答**:

---

### Q4. `default=fn` と `cls=MyEncoder` の使い分け

`json.dumps` で未知型を救う方法として、`default` 引数に関数を渡す方法と、`json.JSONEncoder` をサブクラス化して `cls=MyEncoder` で渡す方法がある。

両者を比較し、**`shared/response.py` でまず `default=str` を採用し、後で必要になったら `JSONEncoder` 化する** という移行戦略がなぜ妥当なのか、設計上の利点を説明せよ。

ヒント: `json.dumps(body, default=str)` から `json.dumps(body, cls=AppEncoder)` への置き換えで、ハンドラ側のコードはどれだけ変わるか。

**参考**:
- [`json.JSONEncoder` - Python Docs](https://docs.python.org/3/library/json.html#json.JSONEncoder)
- [`json.JSONEncoder.default` - Python Docs](https://docs.python.org/3/library/json.html#json.JSONEncoder.default)

**回答**:

---

### Q5. `datetime` の `default=str` 落とし穴

`datetime.datetime` を `default=str` でシリアライズすると、出力フォーマットがフロント側の期待と食い違うことがある。

```python
import json
from datetime import datetime

json.dumps({"ts": datetime(2026, 5, 9, 12, 0, 0)}, default=str)
```

(a) このコードの出力文字列は何になるか（`ts` の値部分のフォーマット）
(b) フロントが ISO 8601 形式（`2026-05-09T12:00:00`）を期待していた場合、何が問題か
(c) `default=str` を変えずにこれを解決するならどう書けばよいか（簡単な方針で良い）

**参考**:
- [`datetime.datetime.__str__` - Python Docs](https://docs.python.org/3/library/datetime.html#datetime.datetime.__str__)
- [`datetime.datetime.isoformat` - Python Docs](https://docs.python.org/3/library/datetime.html#datetime.datetime.isoformat)

**回答**:
