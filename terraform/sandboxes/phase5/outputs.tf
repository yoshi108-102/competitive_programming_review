output "cloudfront_domain_name" {
  description = "CloudFront ディストリビューションのドメイン名"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront ディストリビューション ID"
  value       = aws_cloudfront_distribution.main.id
}

output "origin_bucket_name" {
  description = "S3 オリジンバケット名"
  value       = aws_s3_bucket.origin.id
}

output "cf_logs_bucket_name" {
  description = "CloudFront ログバケット名"
  value       = aws_s3_bucket.cf_logs.id
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = aws_wafv2_web_acl.main.arn
}

output "waf_web_acl_name" {
  description = "WAF Web ACL 名"
  value       = aws_wafv2_web_acl.main.name
}

output "dashboard_url" {
  description = "CloudWatch ダッシュボード URL (us-east-1)"
  value       = "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=phase5-dashboard"
}
