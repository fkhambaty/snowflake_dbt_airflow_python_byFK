variable "monthly_credit_quota" {
  description = "Credits per month before warehouses are suspended. Trial accounts: keep it small."
  type        = number
  default     = 100
}
