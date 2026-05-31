variable "limit_usd" {
  type        = string
  default     = "5"
  description = "月次予算の上限 (USD)"
}

variable "notify_email" {
  type        = string
  description = "予算超過通知の送信先メールアドレス (実際に受け取るなら自分のメールに上書き)"
  default     = "sandbox@example.com"
}
