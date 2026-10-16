# Почтовый поддомен Resend

В Resend создан `notify.pouqwyggad123.shop` для отправителя `SimpleSchedule <noreply@notify.pouqwyggad123.shop>`. Регион `eu-west-1`, входящая почта отключена, отслеживание открытий и переходов отключено. После добавления записей выполнена живая проверка: **Resend Verified**, все четыре записи verified. DKIM/SPF/MX/CNAME также прочитаны из публичного DNS. SMTP в Supabase ещё не настроен; писем не отправляли.

В **активной DNS-зоне Cloudflare `pouqwyggad123.shop`** добавить:

| Тип | Name | Content | Priority | TTL |
| --- | --- | --- | --- | --- |
| TXT | `resend._domainkey.notify` | см. полную строку ниже | — | Auto |
| MX | `send.notify` | `feedback-smtp.eu-west-1.amazonses.com` | 10 | Auto |
| TXT | `send.notify` | `v=spf1 include:amazonses.com ~all` | — | Auto |
| CNAME | `rsend.notify` | `send.forge.rmta.net` | — | Auto |

DKIM TXT Content, без кавычек и переносов:

```text
p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDb6NRWS6koXKQUkvB9Xlm3hdazf12KsApfB32KgV/+5oQPYoSYuvYeEoroMm1p7ntWwfp42WElcJ051Jd+2XmLcuZtrhI/1nbQjXrqo6EH/pKDAFVPsJjz8xNwcddAW6ghucSQOkxFb19f/9rMUNWauw/AITzrCzfqT99u3EXmGQIDAQAB
```

Это публичный ключ DNS, не секретный API-ключ. CNAME должен быть **DNS only**, без HTTP-proxy. Не менять действующие A/AAAA/CNAME VPS, NS и чужие MX. После сохранения запустить проверку домена в Resend, дождаться статуса Verified и настроить custom SMTP в Supabase по [DEPLOY.md](DEPLOY.md).
