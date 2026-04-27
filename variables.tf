variable "vault_addr" {
  description = "Adresse OpenBao (ex: https://openbao.ilyara.com)"
  type        = string
}

variable "vault_token" {
  description = "Token OpenBao injecté par Semaphore"
  type        = string
  sensitive   = true
}
