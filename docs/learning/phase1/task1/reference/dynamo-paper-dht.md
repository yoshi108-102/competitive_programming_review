# Dynamo 論文と分散ハッシュテーブル（DHT）の内部実装

## 概要

2007年のSOSPで発表された **"Dynamo: Amazon's Highly Available Key-value Store"** は、分散ハッシュテーブル（Distributed Hash Table, DHT）の商用実装を世に広めた古典論文である。Amazon.comのショッピングカートのような「**絶対に止まってはいけない**」サービスを支えるために、既知のアルゴリズム（Consistent Hashing、Vector Clock、Quorum、Gossip Protocol）を**組み合わせて一つのシステムに仕上げた**ことが論文の本質的な貢献である。

この論文は DynamoDB の直接の起源だが、**DynamoDB と Dynamo は別物**であることに注意が必要。DynamoDB は2012年の立ち上げ以降、論文の設計から大きく進化し、2022年の USENIX ATC で発表された後継論文で中身が公開されている。本リファレンスは (1) Dynamo論文が提唱した4つのコアアルゴリズム、(2) Dynamo → DynamoDB の進化、をソース付きで整理する。

## 詳細

### 1. Dynamo 論文の位置づけ

- **発表**: SOSP 2007（Symposium on Operating Systems Principles）
- **著者**: Giuseppe DeCandia, Deniz Hastorun, Madan Jampani, Gunavardhan Kakulapati, Avinash Lakshman, Alex Pilchin, Swaminathan Sivasubramanian, Peter Vosshall, **Werner Vogels**（Amazon CTO）
- **目的**: Amazon.com の「always-on（常に書き込める）」要件を満たす分散KVストアの設計
- **設計哲学**: 可用性（Availability）と分断耐性（Partition tolerance）を最優先し、**強整合性を犠牲にする**（CAP定理で言えば AP 寄り）

論文の一文で要約すると:

> "Dynamo uses a synthesis of well known techniques to achieve scalability and availability."
> — *DeCandia et al., SOSP 2007*

**新しいアルゴリズムを発明したのではなく、既存の技術を組み合わせて商用に耐えるシステムを作った**点が貢献。

論文の影響で生まれた分散DB:

- **Apache Cassandra**（Facebook、Dynamo + BigTable の合成）
- **Riak**（Basho）
- **Voldemort**（LinkedIn）
- **ScyllaDB**（Cassandra 互換の C++ 実装）

### 2. Consistent Hashing（一貫性ハッシュ法）

#### 問題意識

素朴な `hash(key) % N` によるシャーディングは、サーバー追加/削除時にほぼ全データの再配置が発生する:

```
N=3 → N=4 に変更:
  key="user-123": hash % 3 = 0 → サーバーA
  key="user-123": hash % 4 = 3 → サーバーD（移動）

ほぼ全キーが別のサーバーに移動 → 大規模な再配置が必要
```

#### Consistent Hashing のアイデア

ハッシュ値空間を**円環（リング）**として扱う:

```
      0 / 2^32
      ┌───┴───┐
   サーバーA          サーバーB
      │                │
      └───┐       ┌────┘
          サーバーC

- サーバーも key も同じハッシュ関数で円上に配置
- key を時計回りに探索し、最初に見つかったサーバーが担当
```

サーバー追加時の再配置量:

- 従来: `O(K)` （全データが再配置される可能性）
- Consistent Hashing: **約 `K/N`** （新サーバーが担当する区間のデータだけ）

#### 制約と Virtual Node

素朴な実装では、ノードが円上に偏在すると負荷が偏る。これを解決するのが **Virtual Node（仮想ノード）**:

- 1つの物理ノードを円上の**複数位置**（典型的に 100〜1000 点）に配置する
- ハッシュ関数により位置がランダム化されるため、物理ノード単位で見ると負荷が平均化される
- ノード障害時もデータが複数の隣接ノードに分散して担当される

現在の商用 DHT 実装（DynamoDB、Cassandra、ScyllaDB）は全て Virtual Node を採用している。

### 3. Vector Clock（ベクトル時計）

#### 問題意識

分散システムでは「書き込みの順序」が難しい問題になる:

```
時刻 T1: クライアントA が「item X を追加」
時刻 T2: クライアントB が「item Y を追加」
時刻 T3: ネットワーク分断が発生、2つのレプリカが別々に更新される

結果:
  レプリカ1: [X]       （クライアントAの更新を受けた）
  レプリカ2: [Y]       （クライアントBの更新を受けた）
  → どちらが「正しい」?
```

物理時計（タイムスタンプ）は NTP 同期でも数ミリ秒ズレるので、**厳密な順序判定**には使えない。

#### Vector Clock の構造

各オブジェクトは `(node_id, counter)` のペアのリストを持つ:

```
item X の vector clock: [(A, 2), (B, 1)]
  → ノードA上で2回、ノードB上で1回更新された

item X の新バージョン: [(A, 3), (B, 1)]
  → ノードAで更に1回更新された（= 旧バージョンの子孫）
```

#### 因果関係の判定

2つのバージョン V1, V2 の関係:

| 関係 | 判定 |
|---|---|
| V1 が V2 の祖先 | V1 の全 counter ≤ V2 の全 counter、かつ少なくとも1つは < |
| V2 が V1 の祖先 | 逆 |
| **並行（conflict）** | どちらでもない（両方を保持して後で解決） |

#### Dynamo での使われ方

```
ショッピングカートへの並行書き込み:
  クライアントA: カートに本を追加 → [A:1]
  クライアントB: 同時にカートに音楽を追加 → [B:1]
  
→ Vector Clock の比較で「並行更新」と判定
→ システムは両方保持し、次回の読み取り時にクライアントに両バージョンを返す
→ クライアントは「本 + 音楽」にマージして書き戻す
```

**semantic reconciliation（意味的和解）** と呼ばれる。Amazon のショッピングカートで「削除したアイテムが復活することはあっても、追加したアイテムが消えることはない」挙動の技術的根拠がこれ。

### 4. Quorum ベース複製（N, R, W）

#### 3つのパラメータ

| 記号 | 意味 |
|---|---|
| **N** | データを複製するノード数（レプリカ数） |
| **R** | 読み取り成功に必要な応答ノード数 |
| **W** | 書き込み成功に必要な応答ノード数 |

#### 強整合性の条件

**W + R > N** を満たせば、読み書きするノード集合が必ず重なる → 最新データを含むノードから読める:

```
N=3, W=2, R=2 の場合:
  W=2 → 書き込み時は 3ノード中 2ノード以上に書く
  R=2 → 読み取り時も 2ノード以上から読む
  → 書いたノードと読むノードの集合が必ず1つ以上重なる
  → 最新値が読める
```

#### 可用性との tradeoff

| 設定 | 整合性 | 可用性 |
|---|---|---|
| W=N, R=1 | 強（読み高速） | 書き込みが1ノード障害で失敗 |
| W=1, R=N | 強（書き高速） | 読み取りが1ノード障害で失敗 |
| **W=(N/2)+1, R=(N/2)+1** | 強（バランス） | 過半数が生きていればOK |
| W=1, R=1 | 結果整合性のみ | 最高（1ノードでもOK） |

Dynamo 論文ではデフォルト `N=3, W=2, R=2` が採用されている。

### 5. Gossip Protocol（流言プロトコル）

#### 目的

- クラスタのメンバーシップ情報の共有（どのノードが生きているか）
- 障害検出（どのノードが死んだか）

#### 仕組み

```
1. 各ノードは定期的（例: 1秒ごと）にランダムな別ノードを選ぶ
2. 選んだノードと「自分が知っている全ノードの状態」を交換
3. 新しい情報を得たら自分の状態を更新

→ 対数時間（O(log N)）でクラスタ全体に情報が伝播
```

中央集権的な管理ノードを持たないため、**単一障害点がない**。疫病の伝播モデルに似ているため "Gossip" や "Epidemic" と呼ばれる。

### 6. Dynamo vs DynamoDB の決定的な違い

DynamoDB（2012年〜）は Dynamo論文の設計を**多くの点で変更している**。2022年 USENIX ATC の論文 "Amazon DynamoDB: A Scalable, Predictably Performant, and Fully Managed NoSQL Database Service" で詳細が公開された。

#### 主要な相違点

| 観点 | Dynamo（2007論文） | DynamoDB（2012〜） |
|---|---|---|
| **複製モデル** | リーダーレス（Quorum） | **単一リーダー（Multi-Paxos）** |
| **整合性の選択** | 結果整合性のみ | **強整合性 or 結果整合性**（クライアントが選択） |
| **パーティション管理** | P2P ハッシュリング（Gossip） | **中央集権的なパーティションマップ + 配置サービス** |
| **テナンシー** | シングルテナント（社内サービスごとに別クラスタ） | **マルチテナント**（共通インフラで多数顧客を捌く） |
| **Vector Clock** | あり | **なし**（単一リーダーなので不要） |
| **運用モデル** | 各チームが自前運用 | **フルマネージドサービス** |
| **SKの存在** | なし（純粋KV） | **あり**（Partition Key + Sort Key + GSI） |

#### なぜ変わったのか

Dynamo 論文の設計は研究として優れていたが、**商用マネージドサービス**として運用するには問題があった:

1. **Vector Clock の複雑さ**: semantic reconciliation をクライアント側に押し付けるので、開発者体験が悪い
2. **結果整合性のみの制限**: 「書いた直後に読めない」挙動がアプリケーション開発を難しくする
3. **P2P Gossip の運用難**: メンバーシップ情報の不整合がトラブルの原因になりやすい
4. **マルチテナント要求**: 一顧客の暴走が他顧客に波及しないよう、厳密なリソース分離が必要

こうした課題を解決するため、DynamoDB は「Dynamo論文の設計思想（ハッシュ分散、水平スケール）」を継承しつつ、**中身の実装を大幅に再設計**した。

### 7. DHT の制約が DynamoDB 仕様に残した影響

DynamoDB が Dynamo論文から離れた部分は多いが、**DHTという根本構造は引き継いでいる**。そのため DynamoDB の仕様制約のほとんどは「DHT であることの必然」である:

| DynamoDB の仕様 | DHT 由来の理由 |
|---|---|
| PK は完全一致のみ | ハッシュ関数で物理配置を決めるため、範囲検索不可 |
| PK 変更不可 | 値を変えるとハッシュ値が変わる = 置き場所が変わる |
| PK のカーディナリティが重要 | ハッシュ分散が偏るとホットパーティションになる |
| GSI は「コピー」 | 別のキーで分散し直すため、物理的に別のデータが必要 |
| JOIN 不可 | ハッシュテーブルは関係演算のための構造ではない |
| 横断 Scan は高コスト | 全パーティションに聞きに行く必要がある |

DynamoDB で「なぜこの制約があるのか?」と迷ったら、**「ハッシュテーブルの性質」に立ち戻る**と大抵の疑問が解ける。

## 比較表

### Dynamo 系 DB の系譜

| DB | 開発元 | リリース | 特徴 |
|---|---|---|---|
| Dynamo | Amazon | 2007（論文） | 社内専用、P2P、リーダーレス |
| Voldemort | LinkedIn | 2009 | オープンソース、Dynamo風 |
| Cassandra | Facebook→Apache | 2008 | Dynamo + BigTable、広く普及 |
| Riak | Basho | 2009 | 純粋な Dynamo クローン、開発終了 |
| DynamoDB | Amazon | 2012 | マネージド、単一リーダー、SK追加 |
| ScyllaDB | ScyllaDB Inc | 2015 | Cassandra 互換、C++ 実装で高速 |

### DHT 4大アルゴリズムまとめ

| アルゴリズム | 解決する問題 | DynamoDBでの採用 |
|---|---|---|
| Consistent Hashing | データ配置と再配置の最小化 | ✅（内部で採用） |
| Vector Clock | 並行更新の因果判定 | ❌（単一リーダーで不要） |
| Quorum (NRW) | 可用性と整合性のtrade-off | 部分採用（強整合性オプションで変化） |
| Gossip Protocol | クラスタメンバーシップの共有 | ❌（中央集権的な配置サービス） |

## よくある誤解

- **誤解: DynamoDB は Dynamo論文の実装そのもの**
  - 実際: DynamoDB は Dynamo論文の設計から大きく変わっており、特に**複製モデル（リーダーレス → 単一リーダー）**と**整合性モデル（結果整合性のみ → 強整合性も選択可能）**が根本的に異なる。論文の設計思想（ハッシュ分散、水平スケール、マネージド運用の前身）は引き継いでいるが、内部実装は別物と考えた方が正確。

- **誤解: Consistent Hashing はサーバー数が変わっても一切再配置しない**
  - 実際: 全く再配置しないわけではなく、**全体の約 K/N 程度**のデータが再配置される。ただし素朴なハッシュ分散の「ほぼ全データ移動」と比べると遥かに少ない。

- **誤解: Vector Clock があれば全ての conflict が解決できる**
  - 実際: Vector Clock は**因果関係の判定**をするだけで、**並行更新の自動解決はしない**。最終的な conflict 解決はクライアント側の semantic reconciliation か、システム側のポリシー（last-write-wins など）に任される。

- **誤解: DynamoDB の GSI は内部的に別テーブルだからコストが倍**
  - 実際: 「内部的に別テーブル」は正しいが、コストが「倍」というより**GSIの数に応じて倍々**。GSI 3本なら元テーブルのストレージとWCUが合計で約4倍（元1 + GSI3）になる。

- **誤解: Quorum は Paxos や Raft と同じ**
  - 実際: Quorum はより素朴な仕組みで、Paxos/Raft は**線形化可能性**を保証する本格的な合意アルゴリズム。DynamoDB は内部で Multi-Paxos を使っていて、単なる Quorum よりも強い整合性保証を得ている。

## まとめ

- Dynamo論文（SOSP 2007）は **既知の分散アルゴリズム（Consistent Hashing、Vector Clock、Quorum、Gossip）を組み合わせて商用DHTを作った**論文。新しいアルゴリズムの発明ではなく、**商用レベルの統合**が貢献。
- Consistent Hashing は「ハッシュ値空間を円環として扱い、近接するサーバーに key を配置する」手法。サーバー追加/削除時の再配置を `K/N` に抑える。Virtual Node で負荷を平均化。
- Vector Clock は並行更新の因果判定。Dynamo ではショッピングカートの semantic reconciliation で活用された。
- Quorum（N, R, W）は `W + R > N` で強整合性を達成できる。`N=3, W=2, R=2` が古典的なバランス設定。
- **DynamoDB は Dynamo論文とは実装が別物**。単一リーダー（Multi-Paxos）、中央集権的パーティション管理、マルチテナントアーキテクチャを採用している。論文の設計思想は継承しているが、中身は2012年以降大きく進化した。
- それでも **DynamoDB の制約の大部分は「DHT であること」から導かれる**。PK完全一致のみ、PK変更不可、ホットパーティション問題、GSIがコピー、JOIN不可、Scanが高コスト — 全てハッシュテーブルの性質の直接の帰結。

## 参考文献

- [Dynamo: Amazon's Highly Available Key-value Store (SOSP 2007 PDF)](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) — 原論文、Werner Vogels の公式PDF配布。閲覧日 2026-04-18
- [Dynamo paper - ACM Digital Library](https://dl.acm.org/doi/10.1145/1294261.1294281) — ACM 公式掲載。閲覧日 2026-04-18
- [Amazon DynamoDB: A Scalable, Predictably Performant, and Fully Managed NoSQL Database Service (USENIX ATC 2022)](https://www.usenix.org/system/files/atc22-elhemali.pdf) — DynamoDB の現行アーキテクチャを詳述した後継論文。閲覧日 2026-04-18
- [Consistent hashing - Wikipedia](https://en.wikipedia.org/wiki/Consistent_hashing) — Consistent Hashing の定義、Virtual Node の一般的実装。閲覧日 2026-04-18
- [Dynamo (storage system) - Wikipedia](https://en.wikipedia.org/wiki/Dynamo_(storage_system)) — Dynamo 自体の整理。DynamoDB との違いにも言及。閲覧日 2026-04-18
- [Key Takeaways from the DynamoDB Paper - Alex DeBrie](https://www.alexdebrie.com/posts/dynamodb-paper/) — USENIX 2022 論文の要約と Dynamo との比較。閲覧日 2026-04-18
- [The DynamoDB paper - Marc Brooker's Blog](https://brooker.co.za/blog/2022/07/12/dynamodb.html) — AWSプリンシパルエンジニアによるUSENIX論文解説。閲覧日 2026-04-18
- [Dynamo, DynamoDB, and Aurora DSQL - Marc Brooker's Blog](https://brooker.co.za/blog/2025/08/15/dynamo-dynamodb-dsql.html) — Dynamo系DBの系譜と現代の AWS DB ラインナップ。閲覧日 2026-04-18
- [The Dynamo Paper - DynamoDB Guide](https://www.dynamodbguide.com/the-dynamo-paper/) — Alex DeBrie による Dynamo 論文の章解説。閲覧日 2026-04-18
- [How are vector clocks used in Dynamo? - Educative](https://www.educative.io/answers/how-are-vector-clocks-used-in-dynamo) — Vector Clock の Dynamo 実装解説。閲覧日 2026-04-18
- [Vector Clocks in Distributed Systems - GeeksforGeeks](https://www.geeksforgeeks.org/computer-networks/vector-clocks-in-distributed-systems/) — Vector Clock の一般的説明。閲覧日 2026-04-18
- [Leaderless Replication: Dynamo-style, Quorum Consensus - The Algorists](https://efficientcodeblog.wordpress.com/2017/12/25/leaderless-replication-dynamo-style-quorum-consensus-eventual-consistency-high-availability-and-low-latency/) — NRW quorum の詳細解説。閲覧日 2026-04-18
- [Dynamo | Apache Cassandra Documentation](https://cassandra.apache.org/doc/latest/cassandra/architecture/dynamo.html) — Cassandra から見た Dynamo 系アーキテクチャ。閲覧日 2026-04-18
- [Amazon's DynamoDB — 10 years later - Amazon Science](https://www.amazon.science/latest-news/amazons-dynamodb-10-years-later) — Amazon 公式の振り返り記事。閲覧日 2026-04-18

---

_Saved at 2026-04-18 via /learning-flow:reference_
