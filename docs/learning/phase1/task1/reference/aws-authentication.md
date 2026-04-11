# AWS認証のベストプラクティス（2026年現在）

## 認証方法の変遷

```
2020年頃の常識:
  IAMユーザー作成 → アクセスキー発行 → ~/.aws/credentials に設定
  → 動くが、キー漏洩リスクあり

2026年の推奨:
  IAM Identity Center → ブラウザでSSOログイン → 一時認証情報を自動取得
  → キーが存在しないので漏洩しようがない
```

## なぜ長期アクセスキーが危険か

- GitHubに誤コミット → 数分でボットに拾われて不正利用される
- PCから漏洩 → 無期限にアクセス可能
- 退職者のキーが残る → いつまでもアクセスできてしまう
- 一時認証情報なら: セッション期限（数時間）で自動失効、漏洩しても被害が限定的

## シナリオ別の推奨

### ローカル開発

**最推奨: IAM Identity Center (旧AWS SSO)**

```bash
aws configure sso              # 初回設定
aws sso login --profile my-profile  # 毎日の作業開始時
# → ブラウザが開く → ログイン → 一時認証情報が自動取得
# → 数時間で期限切れ → 再ログインするだけ
```

**次善: `aws configure` でアクセスキーを設定**

```bash
aws configure
# → ~/.aws/credentials にアクセスキーが保存される
# → 動くが、長期キーなのでリスクあり
```

### EC2 / Lambda 上のアプリケーション

**IAMロール（今も推奨）**

EC2にIAMロールをアタッチ → EC2上のコードが自動で一時認証情報を取得。アクセスキーを一切使わない。

### CI/CD（GitHub Actions等）

**OIDC連携**

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::123456789:role/github-actions
    aws-region: ap-northeast-1
# → シークレットの保存が不要
```

## IAMユーザー vs IAMロール（混同しやすい）

| | IAMユーザー | IAMロール |
|---|---|---|
| 紐づく先 | 人 | リソースやサービス |
| 認証情報 | 永続的なアクセスキー | 一時的な認証情報 |
| 推奨度 | 非推奨（Identity Centerへ移行） | 推奨 |

## IAM Identity Center vs IAMロールの違い

この2つは目的が違い、競合するものではなく組み合わせて使う。

| | IAM Identity Center | IAMロール |
|---|---|---|
| 何を管理 | **誰が**AWSにアクセスできるか | **何が**できるか |
| 対象 | 人間 | 人間、サービス、両方 |
| 認証情報 | ブラウザログイン → 一時トークン | 一時的な認証情報を自動発行 |
| 単体で使える？ | ×（ロールとの組み合わせが必要） | ○（LambdaなどサービスはロールだけでOK） |

Identity Center = 「会社の入館証」（誰がビルに入れるか）
IAMロール = 「部屋の鍵」（何の部屋にアクセスできるか）

人間の場合: Identity Centerでログイン → IAMロールを引き受ける → 権限に応じた操作
サービスの場合: IAMロールだけ（Lambda等はログイン不要、ロールを直接引き受ける）

### Identity Center の本質は「認証の一元管理」

Identity Centerは単なる「短期アクセスキー発行機」ではなく、3つの役割を持つ:

1. **認証**: 「この人は本当に田中さんか？」を確認（会社のID基盤と連携、MFA強制）
2. **ロール割り当て**: 「田中さんにはこのPermission Set（ロール）を使わせる」を管理
3. **一時認証情報の発行**: 上記2つを通過したら自動発行（結果として短期キーになる）

具体的な流れ（例: EC2を作りたい場合）:

```
① Identity Center でログイン → 「田中さんであること」確認
② Permission Set の選択 → 「田中さんは InfraAdminRole を使える」と判断
   → InfraAdminRole の中身: ec2:RunInstances を Allow
③ 一時認証情報が発行 → InfraAdminRole の権限付き → EC2作成が可能
④ 数時間後に期限切れ → 再ログイン必要
```

Identity Centerがなかった時代はIAMユーザーにアクセスキーを発行して直接権限を付けていた。Identity Centerにより「ログインの仕組み」と「権限の定義」が分離され、セキュリティが向上。

### なぜ「IAMユーザーのキーを短期にする」ではダメなのか

問題の本質は「永続キー」にあるが、IAMユーザーのアクセスキーは仕組み上、永続でしか発行できない（自動期限切れ機能がない）。手動ローテーション（古いキーを無効化→新しいキーを発行）は可能だが、忘れたら永遠に有効のまま。

`sts:AssumeRole` を使えばIAMユーザーからでも一時キーを発行できるが、「一時キーを取得するために永続キーが必要」→ 結局永続キーが存在する。

Identity Centerは「永続キーを使わないログイン方法」:
- ブラウザでログイン（パスワード + MFA）→ 一時キー発行
- `~/.aws/credentials` にキーが保存されない → 漏洩する「ファイル」自体がない

副産物として:
- 退職者のアクセスを会社のID基盤で即無効化（IAMユーザーだと各AWSアカウントで個別削除が必要）
- 1回のログインで複数AWSアカウント（dev/staging/prod）にアクセス

### なぜIAMユーザーのキーに「自動期限切れ」を追加しなかったのか

IAMユーザーのアクセスキーは2006年のAWS初期からある仕組み。API用のパスワードとして設計された（Webサービスのパスワードに有効期限がないのと同じ発想）。

既存キーに有効期限を後付けすると、世界中の本番システムで使われているキーが突然期限切れになり大規模障害が発生する（後方互換性を壊せない）。だから既存の仕組みは変えず、別の仕組み（STS + Identity Center）を作った。

### ~/.aws/credentials は諸悪の根源か？

ファイル自体が悪いのではなく「永続キーしか発行できないIAMユーザーの設計」が根本原因。

- `~/.aws/credentials`（IAMユーザー）: 永続キーを平文保存 → 盗まれたら永遠に有効
- `~/.aws/sso/cache/`（Identity Center）: 一時トークンをキャッシュ → 盗まれても数時間で無効

ファイルに保存する点は同じだが、中身の寿命が決定的に違う。

## 参考資料

- [Security best practices in IAM - AWS公式](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [Beyond IAM access keys: Modern authentication approaches for AWS - AWS Security Blog](https://aws.amazon.com/blogs/security/beyond-iam-access-keys-modern-authentication-approaches-for-aws/)
- [AWS IAM Identity Center: The right way in 2026 - DEV Community](https://dev.to/aws-builders/aws-authentication-iam-identity-center-sso-the-right-way-in-2026-4409)
