# One Link Events And Integration Patterns

Use this reference when deciding whether the integration should be polling, webhook-based, or app-like.

## Main Patterns

| Pattern | Best for | Main building blocks |
| --- | --- | --- |
| Workspace sync | Keep external systems aligned with operational data | Application API, webhooks |
| Channel client | Build your own chat surface | Client API |
| Connected app | Account-level or inbox-level external app setup | Integrations, hooks, settings |
| AI action surface | Let Captain call external actions | Captain custom tools |

## Webhook Flow

Typical event-driven sequence:

1. A One Link event happens.
2. A webhook or automation trigger fires.
3. Your endpoint receives and acknowledges the payload.
4. Your system processes it idempotently.
5. Your system optionally writes back through the API.

## Use Plain Webhooks When

- you need a broad event stream
- filtering happens in your own system
- you want a generic sync pipeline

## Use Automation-Triggered Flows When

- only selected business cases matter
- the trigger depends on labels, status, fields, or business conditions
- the workspace should control routing logic

## Receiver Design Recommendations

- make processing idempotent
- log source event IDs and payloads
- isolate retries from business logic
- validate signatures or shared secrets when configured
- keep ingestion and heavy processing separate

## Pattern Selection Heuristic

- If the user wants background sync, start with Application API plus webhooks.
- If the user wants a customer-facing messaging UI, start with Client API.
- If the user wants installation, stored settings, and lifecycle ownership, think in connected-app terms.
- If the user wants an assistant to call an external action, think in Captain custom-tool terms.
