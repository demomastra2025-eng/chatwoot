# Open Items

## Current Known Gaps

- the live test DID still uses the built-in welcome demo app, not the new CRM-driven runtime app
- there are currently `0` Fonoster agents configured
- there are currently `0` Fonoster domains configured
- the browser signaling value returned today is `ws://75.119.131.165:5062`, while a production HTTPS client will likely need secure signaling
- Fonoster `Number` route updates currently fail through the public API on this instance during `UpdateNumber`; bridge routing works because of a dedicated DB fallback, but the platform bug itself still exists
- runtime support for direct live `appRef` handoff is still incomplete; current runtime safely supports `reject` and `operator`, and can only treat `app` or `ai` as a dial transfer when the bridge provides a concrete destination

## Platform Limitations Already Observed

- inbound-only trunk creation through the public Fonoster API was not reliable in this setup
- part of the Twilio/Fonoster trunk linkage had to be created at the storage level

Related operational note:

- [`/root/fonoster-docker/CHANGELOG.md`](/root/fonoster-docker/CHANGELOG.md)

## Production Hardening Tasks

- replace default access-key usage with dedicated API keys
- finalize operator/webphone strategy
- decide whether Chatwoot reaches the bridge through private networking, VPN, or a restricted proxy
- define Chatwoot extension strategy
- add SIP/RTP observability
- define recording retention and privacy rules
- define transcript storage policy

## Documentation Growth Points

Future documents that may be added:

- `16-webphone-strategy.md`
- `17-ai-tools-catalog.md`
- `18-chatwoot-ui-integration.md`
- `19-security-and-secrets.md`
- `20-e2e-test-plan.md`
