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

## 参考資料

- [Security best practices in IAM - AWS公式](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [Beyond IAM access keys: Modern authentication approaches for AWS - AWS Security Blog](https://aws.amazon.com/blogs/security/beyond-iam-access-keys-modern-authentication-approaches-for-aws/)
- [AWS IAM Identity Center: The right way in 2026 - DEV Community](https://dev.to/aws-builders/aws-authentication-iam-identity-center-sso-the-right-way-in-2026-4409)
