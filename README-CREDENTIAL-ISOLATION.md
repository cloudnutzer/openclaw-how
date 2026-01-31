# 🔐 Credential Isolation für Moltbot

## Das Problem

Wenn du Moltbot Zugriff auf Gmail, Google Calendar, Notion etc. geben willst, stehst du vor einem Dilemma:

**Schlecht:** API-Keys direkt im Bot-Container
```
❌ Bot wird kompromittiert → Angreifer hat alle Keys
❌ Keys in .env Datei → Können durch Prompt Injection geleakt werden
❌ Voller API-Zugriff → Bot kann alles tun (auch löschen, senden als du)
```

**Besser:** Middleware als Gatekeeper
```
✅ Bot kennt keine Keys → Nichts zu stehlen
✅ Middleware kontrolliert → Nur erlaubte Aktionen
✅ Granulare Rechte → "Lese Kalender" aber nicht "Lösche Termine"
```

---

## Architektur-Übersicht

```
┌─────────────────────────────────────────────────────────────────────────┐
│                            DEIN NETZWERK                                │
│                                                                         │
│  ┌─────────────────┐         ┌─────────────────┐                       │
│  │    MOLTBOT      │         │      n8n        │                       │
│  │    Container    │         │   (Middleware)  │                       │
│  │                 │  HTTP   │                 │      OAuth/API        │
│  │  Kennt KEINE    │────────▶│  Hält alle      │─────────────────┐     │
│  │  API-Keys       │         │  Credentials    │                 │     │
│  │                 │◀────────│  sicher         │◀────────────┐   │     │
│  │  Ruft nur       │  JSON   │                 │             │   │     │
│  │  Webhooks auf   │         │  Entscheidet:   │             │   │     │
│  └─────────────────┘         │  ✓ Erlaubt?     │             │   │     │
│                              │  ✓ Welche Daten?│             │   │     │
│                              │  ✓ Rate Limit?  │             │   │     │
│                              └─────────────────┘             │   │     │
│                                                              │   │     │
└──────────────────────────────────────────────────────────────│───│─────┘
                                                               │   │
                    ┌──────────────────────────────────────────┘   │
                    │                                              │
                    ▼                                              ▼
            ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
            │   Gmail     │  │  Google     │  │   Notion    │  │   Slack     │
            │   API       │  │  Calendar   │  │   API       │  │   API       │
            └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘
```

---

## Implementierung mit n8n

### Schritt 1: n8n zum Docker-Stack hinzufügen

Füge diesen Service zu deiner `docker-compose.yml` hinzu:

```yaml
services:
  # ... bestehende Moltbot Services ...

  #----------------------------------------------------------------------------
  # N8N - Credential Isolation Middleware
  #----------------------------------------------------------------------------
  n8n:
    image: n8nio/n8n:latest
    container_name: moltbot-n8n
    restart: unless-stopped
    
    user: "1000:1000"
    
    security_opt:
      - no-new-privileges:true
    
    # NUR internes Netzwerk - kein externer Zugriff!
    expose:
      - "5678"
    
    # Optional: Für Setup-Phase temporär öffnen, dann wieder entfernen
    # ports:
    #   - "127.0.0.1:5678:5678"
    
    volumes:
      - ./n8n-data:/home/node/.n8n:rw
    
    environment:
      # Basis-Konfiguration
      - N8N_HOST=n8n
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - WEBHOOK_URL=http://n8n:5678/
      
      # Sicherheit
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_USER:-admin}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_PASSWORD}
      
      # Encryption für Credentials
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      
      # Keine Telemetrie
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_PERSONALIZATION_ENABLED=false
    
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
    
    networks:
      - moltbot-internal
```

### Schritt 2: Sichere Credentials generieren

Füge zu deiner `.env` hinzu:

```bash
# n8n Middleware Credentials
N8N_USER=moltbot-admin
N8N_PASSWORD=$(openssl rand -base64 32)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)

# Webhook Secret (für Authentifizierung Bot → n8n)
WEBHOOK_SECRET=$(openssl rand -hex 24)
```

### Schritt 3: n8n Workflows erstellen

Nach dem Start von n8n (temporär Port freigeben für Setup):

1. Öffne `http://localhost:5678`
2. Melde dich mit N8N_USER/N8N_PASSWORD an
3. Erstelle Workflows für jede erlaubte Aktion

---

## Beispiel-Workflows

### Gmail: "Lies letzte E-Mails" (Read-Only)

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Webhook    │────▶│   Validate   │────▶│  Gmail Node  │────▶│   Response   │
│   Trigger    │     │   Secret     │     │  (Read Only) │     │   Filter     │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
```

**Workflow JSON:**

```json
{
  "name": "Moltbot - Gmail Read",
  "nodes": [
    {
      "name": "Webhook",
      "type": "n8n-nodes-base.webhook",
      "parameters": {
        "httpMethod": "POST",
        "path": "moltbot/gmail/read",
        "authentication": "headerAuth",
        "options": {}
      }
    },
    {
      "name": "Validate Secret",
      "type": "n8n-nodes-base.if",
      "parameters": {
        "conditions": {
          "string": [
            {
              "value1": "={{$node.Webhook.headers['x-webhook-secret']}}",
              "operation": "equals",
              "value2": "={{$env.WEBHOOK_SECRET}}"
            }
          ]
        }
      }
    },
    {
      "name": "Gmail",
      "type": "n8n-nodes-base.gmail",
      "parameters": {
        "operation": "getAll",
        "returnAll": false,
        "limit": 10,
        "filters": {
          "labelIds": ["INBOX"],
          "includeSpamTrash": false
        },
        "options": {
          "format": "metadata"
        }
      },
      "credentials": {
        "gmailOAuth2": {
          "id": "YOUR_CREDENTIAL_ID"
        }
      }
    },
    {
      "name": "Filter Sensitive Data",
      "type": "n8n-nodes-base.code",
      "parameters": {
        "jsCode": "// Entferne sensible Daten vor der Rückgabe\nreturn items.map(item => ({\n  json: {\n    id: item.json.id,\n    subject: item.json.payload?.headers?.find(h => h.name === 'Subject')?.value,\n    from: item.json.payload?.headers?.find(h => h.name === 'From')?.value,\n    date: item.json.payload?.headers?.find(h => h.name === 'Date')?.value,\n    snippet: item.json.snippet?.substring(0, 200)\n    // KEINE vollständigen Bodies, KEINE Attachments\n  }\n}));"
      }
    },
    {
      "name": "Respond",
      "type": "n8n-nodes-base.respondToWebhook",
      "parameters": {
        "respondWith": "json",
        "options": {}
      }
    }
  ]
}
```

### Gmail: "Sende E-Mail" (Mit Einschränkungen)

```json
{
  "name": "Moltbot - Gmail Send (Restricted)",
  "nodes": [
    {
      "name": "Webhook",
      "type": "n8n-nodes-base.webhook",
      "parameters": {
        "httpMethod": "POST",
        "path": "moltbot/gmail/send",
        "authentication": "headerAuth"
      }
    },
    {
      "name": "Validate & Sanitize",
      "type": "n8n-nodes-base.code",
      "parameters": {
        "jsCode": "const input = $input.all()[0].json;\n\n// Validierung\nconst errors = [];\n\n// 1. Webhook Secret prüfen\nif ($node.Webhook.headers['x-webhook-secret'] !== process.env.WEBHOOK_SECRET) {\n  throw new Error('Unauthorized');\n}\n\n// 2. Nur erlaubte Empfänger\nconst allowedDomains = ['@meinefirma.de', '@partner.com'];\nconst toEmail = input.to?.toLowerCase() || '';\nif (!allowedDomains.some(d => toEmail.endsWith(d))) {\n  errors.push(`Empfänger ${input.to} nicht in Whitelist`);\n}\n\n// 3. Keine Attachments erlaubt\nif (input.attachments && input.attachments.length > 0) {\n  errors.push('Attachments sind nicht erlaubt');\n}\n\n// 4. Max. Länge\nif ((input.body?.length || 0) > 5000) {\n  errors.push('E-Mail zu lang (max 5000 Zeichen)');\n}\n\n// 5. Keine Links in E-Mail (optional)\nif (/https?:\\/\\//i.test(input.body || '')) {\n  errors.push('Links in E-Mails nicht erlaubt');\n}\n\nif (errors.length > 0) {\n  throw new Error('Validation failed: ' + errors.join(', '));\n}\n\nreturn [{\n  json: {\n    to: input.to,\n    subject: `[Moltbot] ${input.subject}`.substring(0, 100),\n    body: input.body,\n    validated: true\n  }\n}];"
      }
    },
    {
      "name": "Gmail Send",
      "type": "n8n-nodes-base.gmail",
      "parameters": {
        "operation": "send",
        "sendTo": "={{$json.to}}",
        "subject": "={{$json.subject}}",
        "message": "={{$json.body}}",
        "options": {
          "appendSignature": true
        }
      }
    },
    {
      "name": "Log Action",
      "type": "n8n-nodes-base.code",
      "parameters": {
        "jsCode": "// Audit Log\nconsole.log(JSON.stringify({\n  timestamp: new Date().toISOString(),\n  action: 'gmail_send',\n  to: $json.to,\n  subject: $json.subject,\n  bodyLength: $json.body?.length\n}));\n\nreturn [{ json: { success: true, message: 'E-Mail gesendet' } }];"
      }
    }
  ]
}
```

### Google Calendar: "Lies Termine" (Read-Only)

```json
{
  "name": "Moltbot - Calendar Read",
  "nodes": [
    {
      "name": "Webhook",
      "type": "n8n-nodes-base.webhook",
      "parameters": {
        "path": "moltbot/calendar/read"
      }
    },
    {
      "name": "Google Calendar",
      "type": "n8n-nodes-base.googleCalendar",
      "parameters": {
        "operation": "getAll",
        "returnAll": false,
        "limit": 20,
        "options": {
          "timeMin": "={{$now.toISO()}}",
          "timeMax": "={{$now.plus({days: 7}).toISO()}}",
          "singleEvents": true,
          "orderBy": "startTime"
        }
      }
    },
    {
      "name": "Filter Private Events",
      "type": "n8n-nodes-base.code",
      "parameters": {
        "jsCode": "// Entferne private Termine und sensible Details\nreturn items.map(item => ({\n  json: {\n    id: item.json.id,\n    title: item.json.summary,\n    start: item.json.start?.dateTime || item.json.start?.date,\n    end: item.json.end?.dateTime || item.json.end?.date,\n    location: item.json.location,\n    // KEINE: attendees, description, conferenceData, attachments\n    isBusy: item.json.transparency !== 'transparent'\n  }\n})).filter(item => {\n  // Filtere explizit private Termine\n  const title = item.json.title?.toLowerCase() || '';\n  return !title.includes('privat') && !title.includes('personal');\n});"
      }
    }
  ]
}
```

---

## Moltbot Konfiguration

### Webhook-URLs in moltbot.json

```json
{
  "integrations": {
    "n8n": {
      "enabled": true,
      "baseUrl": "http://n8n:5678/webhook",
      "authHeader": "X-Webhook-Secret",
      "authSecret": "${WEBHOOK_SECRET}",
      "timeout": 30000,
      
      "endpoints": {
        "gmail": {
          "read": {
            "path": "/moltbot/gmail/read",
            "method": "POST",
            "description": "Liest die letzten 10 E-Mails (nur Metadaten)",
            "rateLimit": "10/minute"
          },
          "send": {
            "path": "/moltbot/gmail/send",
            "method": "POST",
            "description": "Sendet E-Mail (nur an Whitelist-Domains)",
            "requiresApproval": true,
            "rateLimit": "5/hour"
          }
        },
        "calendar": {
          "read": {
            "path": "/moltbot/calendar/read",
            "method": "POST",
            "description": "Liest Termine der nächsten 7 Tage",
            "rateLimit": "20/minute"
          },
          "create": {
            "path": "/moltbot/calendar/create",
            "method": "POST",
            "description": "Erstellt neuen Termin",
            "requiresApproval": true,
            "rateLimit": "10/hour"
          }
        },
        "notion": {
          "query": {
            "path": "/moltbot/notion/query",
            "method": "POST",
            "description": "Durchsucht Notion-Datenbanken",
            "rateLimit": "30/minute"
          }
        }
      }
    }
  }
}
```

### System-Prompt Erweiterung

Füge zum System-Prompt hinzu:

```
Du hast Zugriff auf folgende externe Dienste via sichere Webhooks:

GMAIL:
- gmail.read: Lies die letzten E-Mails (nur Betreff, Absender, Datum)
- gmail.send: Sende E-Mail (nur an @meinefirma.de, @partner.com - braucht Genehmigung)

KALENDER:
- calendar.read: Zeige Termine der nächsten 7 Tage
- calendar.create: Erstelle Termin (braucht Genehmigung)

NOTION:
- notion.query: Durchsuche Notion-Datenbanken

WICHTIG: Du hast KEINEN direkten API-Zugriff. Alle Anfragen gehen durch eine 
sichere Middleware, die deine Aktionen validiert und einschränkt.
```

---

## Sicherheitsebenen

### Ebene 1: Netzwerk-Isolation

```
┌─────────────────────────────────────┐
│         Docker Network              │
│  ┌─────────┐      ┌─────────┐      │
│  │ Moltbot │─────▶│   n8n   │      │
│  └─────────┘      └────┬────┘      │
│       ▲                │           │
│       │           NAT/Firewall     │
│       │                │           │
└───────│────────────────│───────────┘
        │                │
   127.0.0.1        OAuth Token
   (nur lokal)      (verschlüsselt)
                         │
                         ▼
                 ┌─────────────┐
                 │ Google API  │
                 └─────────────┘
```

### Ebene 2: Webhook-Authentifizierung

```python
# Moltbot sendet immer:
headers = {
    "X-Webhook-Secret": WEBHOOK_SECRET,
    "X-Request-ID": uuid4(),
    "X-Timestamp": datetime.now().isoformat()
}

# n8n validiert:
if header['X-Webhook-Secret'] != env.WEBHOOK_SECRET:
    return 401 Unauthorized
    
if abs(now - header['X-Timestamp']) > 60 seconds:
    return 400 Request Expired
```

### Ebene 3: Input-Validierung in n8n

- Whitelist für Empfänger
- Maximale Nachrichtenlänge
- Keine Attachments
- Keine Links (optional)
- Sanitization von Inhalten

### Ebene 4: Output-Filterung

- Entferne sensible Felder (volle E-Mail-Bodies, Attendees, etc.)
- Nur notwendige Daten zurückgeben
- Truncate lange Texte

### Ebene 5: Audit-Logging

```json
{
  "timestamp": "2026-01-29T14:30:00Z",
  "action": "gmail.send",
  "requestId": "abc-123",
  "input": {
    "to": "kollege@firma.de",
    "subject": "[Moltbot] Meeting Reminder"
  },
  "result": "success",
  "duration": 1240
}
```

---

## Vergleich: n8n vs. Zapier vs. Make

| Feature | n8n | Zapier | Make |
|---------|-----|--------|------|
| **Self-Hosted** | ✅ Ja | ❌ Nein | ❌ Nein |
| **Credentials lokal** | ✅ Ja | ❌ Cloud | ❌ Cloud |
| **Open Source** | ✅ Ja | ❌ Nein | ❌ Nein |
| **Kosten** | Kostenlos | Ab $20/Mo | Ab $9/Mo |
| **Custom Code** | ✅ JS/Python | Begrenzt | Begrenzt |
| **Webhook Auth** | ✅ Flexibel | Basis | Basis |
| **Audit Logs** | ✅ Voll | Begrenzt | Begrenzt |
| **Air-Gapped möglich** | ✅ Ja | ❌ Nein | ❌ Nein |

**Empfehlung:** Für Zero-Trust-Setups ist **n8n self-hosted** die beste Wahl.

---

## Alternativen zu n8n

### 1. Windmill (Open Source)

```yaml
windmill:
  image: ghcr.io/windmill-labs/windmill:main
  environment:
    - DATABASE_URL=postgres://...
```

- Mehr Developer-fokussiert
- TypeScript/Python native
- Komplexer als n8n

### 2. Temporal + Custom Workers

Für maximale Kontrolle:

```python
@activity.defn
async def send_email_activity(input: EmailInput) -> EmailOutput:
    # Volle Kontrolle über jeden Schritt
    validate_recipient(input.to)
    sanitize_content(input.body)
    result = await gmail_api.send(...)
    audit_log(input, result)
    return result
```

### 3. Eigener Minimal-Proxy

Für einfache Fälle - ein simpler FastAPI-Service:

```python
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
import os

app = FastAPI()
WEBHOOK_SECRET = os.environ["WEBHOOK_SECRET"]

class EmailRequest(BaseModel):
    to: str
    subject: str
    body: str

@app.post("/gmail/send")
async def send_email(
    request: EmailRequest,
    x_webhook_secret: str = Header(...)
):
    if x_webhook_secret != WEBHOOK_SECRET:
        raise HTTPException(401, "Unauthorized")
    
    # Validierung
    if not request.to.endswith("@firma.de"):
        raise HTTPException(400, "Recipient not allowed")
    
    # Gmail API Call mit gespeichertem Token
    # ...
```

---

## Quick Start

```bash
# 1. n8n zu docker-compose.yml hinzufügen (siehe oben)

# 2. Credentials generieren
echo "N8N_PASSWORD=$(openssl rand -base64 32)" >> config/.env
echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)" >> config/.env
echo "WEBHOOK_SECRET=$(openssl rand -hex 24)" >> config/.env

# 3. Stack starten
docker compose up -d

# 4. n8n UI öffnen (temporär)
# Füge ports: "127.0.0.1:5678:5678" zu n8n Service hinzu
docker compose up -d n8n

# 5. Workflows importieren unter http://localhost:5678

# 6. Port wieder entfernen für Produktion
# Entferne die ports: Zeile und restart
docker compose up -d n8n
```

---

## Fazit

Mit diesem Setup:

✅ **Moltbot hat KEINE API-Keys** für Gmail, Calendar, etc.  
✅ **n8n hält alle Credentials** verschlüsselt und lokal  
✅ **Jede Aktion ist granular kontrolliert** (Whitelist, Limits, Filter)  
✅ **Audit-Trail** für alle Operationen  
✅ **Selbst wenn Moltbot kompromittiert wird**, kann der Angreifer nur die definierten, eingeschränkten Aktionen ausführen
