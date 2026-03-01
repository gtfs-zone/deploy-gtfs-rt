resource "uptimekuma_notification" "telegram" {
  name = "Telegram"
  type = "telegram"
  config = jsonencode({
    telegramBotToken       = var.telegram_bot_token
    telegramChatID         = var.telegram_chat_id
    telegramSendSilently   = false
    telegramProtectContent = false
  })
  is_active      = true
  is_default     = true
  apply_existing = true
}
