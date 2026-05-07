variable "document_dir" {
  type        = string
  description = "Path to ssm-documents/ directory relative to this module"
  default     = "../../../ssm-documents"
}

variable "name_prefix" {
  type    = string
  default = "zeelool-ck"
}
