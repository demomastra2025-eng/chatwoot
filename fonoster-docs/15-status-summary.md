# Status Summary

## Ready

- Fonoster platform is running on this server
- public domain is working:
  - `https://cloud.vconsult.kz`
- core services are up:
  - `apiserver`
  - `routr`
  - `asterisk`
  - `rtpengine`
  - `dashboard`
  - `autopilot`
  - `envoy`
  - `postgres`
  - `influxdb`
  - `nats`
  - `telephony-bridge`
  - `voice-runtime`
- bridge is running locally on:
  - `127.0.0.1:38081`
- production-style Node voice runtime is running internally on:
  - `voice-runtime:50062`
- a dedicated Fonoster EXTERNAL app already exists for that runtime:
  - `Onelink Voice Runtime`
  - `96fc259c-6bcd-4cbf-bb7d-d2c51f248934`
- native Fonoster SDK/API access has been tested
- bridge endpoints for Chatwoot-facing telephony actions have been implemented
- route switching and AI toggle now work through the bridge
- developer documentation for the Chatwoot team is in place

## Not Ready Yet

- Chatwoot server is not connected to the bridge yet
- the public DID is not switched from demo path to the new runtime yet
- browser calling is not production-ready yet because signaling is still returned as `ws://...`, not hardened `wss://`
- the public Fonoster `UpdateNumber` path is still buggy on this instance
- full end-to-end production validation with Chatwoot has not happened yet

## Current Technical Truth

- Fonoster-side infrastructure is ready
- bridge-side integration layer is ready for Chatwoot to consume
- the Fonoster-side voice runtime layer now also exists
- the remaining work is now mostly on Chatwoot integration, secure cross-server access, and final cutover

## Next Step

1. Connect the Chatwoot server to the bridge
2. Implement Chatwoot backend calls to the bridge
3. Decide and configure the real inbound decision logic
4. Switch the public DID from demo path to `Onelink Voice Runtime`
5. Test outbound calling from Chatwoot
6. Test AI toggle and operator enable/disable from Chatwoot
7. Run full real-call end-to-end validation

## Read This Next

- [`14-chatwoot-server-checklist.md`](./14-chatwoot-server-checklist.md)
- [`13-chatwoot-developer-guide.md`](./13-chatwoot-developer-guide.md)
- [`05-telephony-bridge.md`](./05-telephony-bridge.md)
- [`10-open-items.md`](./10-open-items.md)
