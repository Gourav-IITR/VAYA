# Task: Connect `vayadelivery.com` to Firebase Hosting

**For:** developer agent
**Repo:** `GoodsDeliveryApp`
**Companion doc:** `DNS_SETUP_GUIDE.md` (DNS half — already done, do not redo)
**Posture:** verify first, change only what is missing, prove it worked.

---

## 1. Situation

DNS at GoDaddy is **complete and verified**. Firebase Hosting is **not** connected to the custom domains. All five hostnames resolve to Firebase but are served Firebase's default fallback certificate, so every one of them fails TLS.

### Verified 2026-09-13

DNS zone at GoDaddy (`vayadelivery.com`) — all present and resolving:

| Type | Name | Value |
|---|---|---|
| A | `@` | `199.36.158.100` |
| CNAME | `www` | `goods-delivery-platform.web.app` |
| CNAME | `app` | `vaya-customer-app.web.app` |
| CNAME | `partner` | `vaya-partner-app.web.app` |
| CNAME | `admin` | `vaya-logistics-admin.web.app` |

Firebase origins — all four deployed and serving real content:

| Origin | Title returned |
|---|---|
| `goods-delivery-platform.web.app` | VAYA \| Intra-City Logistics Network |
| `vaya-customer-app.web.app` | VAYA Customer App |
| `vaya-partner-app.web.app` | VAYA Driver Partner |
| `vaya-logistics-admin.web.app` | VAYA Control Hub |

Custom domains — **all five fail**, identical cause:

```
Hostname 'vayadelivery.com' didn't match certificate info
issuer   = /C=US/O=Google Trust Services/CN=WR4
subject  = /CN=firebaseapp.com
altnames = DNS:firebaseapp.com, DNS:*.firebaseapp.com
```

That is Firebase's default fallback cert — served when the requested hostname is **not registered as a custom domain on any site** in the project. Conclusion: the domains were never added in Hosting, or were added and their certificates have not provisioned.

**The CNAMEs do not create the connection by themselves.** A CNAME to `<site>.web.app` only starts working once that domain is registered on that site in Firebase Hosting. Do not "fix" DNS. DNS is not the problem.

---

## 2. Target state

| Site (Hosting target) | Custom domain(s) |
|---|---|
| `goods-delivery-platform` (`public`) | `vayadelivery.com`, `www.vayadelivery.com` |
| `vaya-customer-app` (`customer`) | `app.vayadelivery.com` |
| `vaya-partner-app` (`partner`) | `partner.vayadelivery.com` |
| `vaya-logistics-admin` (`admin`) | `admin.vayadelivery.com` |

Project: `goods-delivery-platform` (see `.firebaserc`).

Plus: all five hostnames present in **Authentication → Settings → Authorized domains**, or phone-auth sign-in breaks on every subdomain.

---

## 3. Preconditions

```bash
cd <repo root>
gcloud auth list --filter=status:ACTIVE --format="value(account)"
npx -y firebase-tools projects:list | grep goods-delivery-platform
```

Both must succeed against an account with **Firebase Admin** (or Hosting Admin) on `goods-delivery-platform`.

> A previous attempt to open the Hosting console failed with *"the project does not exist or you do not have permission to list apps."* If you hit the same thing, you are on the wrong Google account. **Stop and report** — do not create a new project, and do not create new Hosting sites.

---

## 4. Phase 1 — Verify (read-only, run this first)

Do not change anything until this phase is complete and you know which domains are actually missing.

### 4.1 What Firebase thinks it owns

```bash
PROJECT=goods-delivery-platform
TOKEN=$(gcloud auth print-access-token)

for SITE in goods-delivery-platform vaya-customer-app vaya-partner-app vaya-logistics-admin; do
  echo "=== $SITE"
  curl -s -H "Authorization: Bearer $TOKEN" \
    "https://firebasehosting.googleapis.com/v1beta1/projects/$PROJECT/sites/$SITE/customDomains" \
  | jq '.customDomains[]? | {name, hostState, ownershipState, certState: .cert.state, issues}'
done
```

Record, per domain: `hostState`, `ownershipState`, `cert.state`, and any `issues`.

If this endpoint 404s or is not enabled for the project, fall back to the Console (`https://console.firebase.google.com/project/goods-delivery-platform/hosting/sites`, open each site, read the Domains table) and carry on — the decision table below still applies.

### 4.2 What the internet actually sees

```bash
for H in vayadelivery.com www.vayadelivery.com app.vayadelivery.com partner.vayadelivery.com admin.vayadelivery.com; do
  echo "=== $H"
  echo | openssl s_client -servername "$H" -connect "$H:443" 2>/dev/null \
    | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null
done
```

- Cert names `firebaseapp.com` → **not connected.**
- Cert names the hostname → connected; confirm with an actual fetch (§6).

> Do this from a normal network. A corporate TLS-intercepting proxy rewrites the error page; the cert detail it reports is still the origin's, but run it somewhere clean if the output looks odd.

### 4.3 Decision table

| Phase 1 finding | Do |
|---|---|
| Domain absent from the site | §5.1 — add it |
| `ownershipState: OWNERSHIP_PENDING` + a TXT challenge | §5.2 — hand the TXT record over, then wait |
| `certState: CERT_PROPAGATING` / `CERT_PENDING`, no issues | Nothing. Wait and re-check. Adding it again will not speed it up |
| `hostState: HOST_CONFLICT` or wrong-site mismatch | **Stop and report.** Do not delete a domain off another site to free it |
| Present, `ACTIVE`, cert `ACTIVE`, but §4.2 still fails | **Stop and report** with both outputs — something else is in the path |

**If Phase 1 shows everything already connected and §6 passes: change nothing, report "already done", and stop.** That is a valid and expected outcome.

---

## 5. Phase 2 — Make the missing changes

Only for domains Phase 1 proved are missing. One domain at a time; re-run the §4.1 check after each.

### 5.1 Add a custom domain

Console route (fewer surprises): Build → Hosting → select the site from the site dropdown → **Add custom domain** → enter the hostname → follow the prompts.

- For `goods-delivery-platform`, add `vayadelivery.com` and set up `www.vayadelivery.com` as a redirect to it.
- The subdomains each go on **their own site** per the §2 table. Putting `app.vayadelivery.com` on the wrong site is the easiest mistake here and produces a site that loads the wrong app rather than an error — check the mapping twice.

API route, if you prefer it and §4.1 worked:

```bash
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://firebasehosting.googleapis.com/v1beta1/projects/$PROJECT/sites/$SITE/customDomains?customDomainId=$HOSTNAME" \
  -d '{}'
```

When Firebase offers DNS records it wants added: **the A and CNAME records already exist and are correct.** Do not add duplicates, do not change the A record, and do not remove the CNAMEs. Compare against §1 and only act on something genuinely new.

### 5.2 If Firebase asks for a TXT ownership record

It will give a token like `firebase=goods-delivery-platform-xxxxx`.

**Do not attempt to add it yourself.** DNS lives at GoDaddy under a separate login. Report the exact record to the human:

```
Type: TXT   Host: @   Value: <exact token, copied verbatim>
```

Then stop and wait for confirmation it is live before continuing.

### 5.3 Authorized domains for Auth

Console: Build → Authentication → Settings → Authorized domains → Add domain, for each of:

```
vayadelivery.com
www.vayadelivery.com
app.vayadelivery.com
partner.vayadelivery.com
admin.vayadelivery.com
```

Check current state first:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJECT/config" \
| jq '.authorizedDomains'
```

If you update this via the API, **send the full list** — `authorizedDomains` is replaced wholesale, and dropping `localhost` or the existing `*.firebaseapp.com` / `*.web.app` entries will break local development and the origins that currently work.

---

## 6. Phase 3 — Prove it

Not done until all five return HTTP 200 over valid TLS **and** serve the right app:

```bash
check() { # host, expected title fragment
  T=$(curl -s --max-time 20 "https://$1" | grep -o '<title>[^<]*</title>')
  echo "$1 -> $(curl -s -o /dev/null -w '%{http_code} ssl=%{ssl_verify_result}' "https://$1") $T"
}
check vayadelivery.com          # VAYA | Intra-City Logistics Network
check www.vayadelivery.com      # redirect to apex, or same title
check app.vayadelivery.com      # VAYA Customer App
check partner.vayadelivery.com  # VAYA Driver Partner
check admin.vayadelivery.com    # VAYA Control Hub
```

`ssl=0` means the certificate verified. A 200 with the *wrong* title means a domain landed on the wrong site — go back to §5.1.

Then one real browser load of `app.vayadelivery.com`, sign in with phone auth, and confirm the SMS flow completes. That is the only thing that actually exercises §5.3.

---

## 7. Rules

- **Never touch DNS at GoDaddy.** It is verified correct and you do not have the credentials. Anything DNS-shaped gets reported to the human, not done.
- **Never delete** a Hosting site, an existing custom domain, or an authorized domain.
- **Never create** a new Firebase project or Hosting site. Only the four in `.firebaserc` are in scope.
- **Never redeploy** to fix this. The four sites already serve correct content — this is purely a domain-attachment problem, and a deploy changes nothing about it.
- Certificate provisioning takes **20 minutes to a few hours**, occasionally up to 24. Waiting is the correct action, not retrying. Do not delete and re-add a domain because it is still pending.
- If two consecutive attempts at the same step fail, stop and report rather than trying a third variation.

## 8. Report back

- Phase 1 findings per domain (the raw `hostState` / `ownershipState` / `certState`).
- What you changed, per domain — or "nothing, already correct".
- Phase 3 output for all five.
- Anything handed back to the human: TXT tokens, permission errors, conflicts.
