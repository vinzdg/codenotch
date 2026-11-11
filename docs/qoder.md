# Qoder credits

Qoder reads the signed-in account's big-model credit allowance from the account
usage page. International (`qoder.com`) and China mainland (`qoder.com.cn`)
accounts are selected separately in Settings → Accounts → Qoder → Region.

Click **Sign in** to open the selected site inside Codenotch. Complete the site's
login or verification, then close the sign-in window. Codenotch confirms the
session against the site's quota endpoint. No browser cookies or API keys need
to be pasted; the session stays in Codenotch's WebKit website store.

The ring shows used and total credits, including shared credits when reported.
The tooltip shows the used percentage and reset date when supplied by Qoder.
Changing regions clears the previous account's cached reading and selects that
region's independent session. Signing out clears only the selected site's
session in Codenotch.

## Failures

An unauthenticated account requests sign-in. A forbidden browser request asks
you to check the session or complete website verification. Invalid quota data
never produces a replacement reading; any retained previous reading is stale.

The source is the website's own
`GET /api/v2/me/usages/big_model_credits` endpoint, rather than a documented
public API. Frontend changes may require adapter updates. Where the site sends
`Bx-V`, Codenotch observes that build tag on same-origin usage requests; it does
not hard-code a historical version, import browser credentials or impersonate
another browser.
