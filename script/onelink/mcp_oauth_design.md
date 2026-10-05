# MCP OAuth design proposal

## Scope and compatibility

Add OAuth authorization for the existing account-scoped MCP endpoint as a second authentication path. Keep user API access tokens working for existing clients. Both paths must resolve to a real OneLink user and account, then pass through the current MCP access policy, tool checks, confirmation flow, and audit behavior. OAuth must not create a broader service identity or forward an MCP access token to downstream APIs.

The MCP 2025-06-18 authorization profile requires Protected Resource Metadata, Authorization Server Metadata, resource indicators, bearer-token validation, and OAuth 2.1 security practices. Use Authorization Code with PKCE (`S256`), exact redirect URI checks, HTTPS outside localhost, short-lived access tokens, and refresh-token rotation for public clients. Dynamic Client Registration is a useful interoperability option, but can follow an initial controlled client-registration path.

## Proposed flow

1. Return `401 Unauthorized` for a missing or invalid credential and include a `WWW-Authenticate` challenge that points to the MCP Protected Resource Metadata document (RFC 9728).
2. Publish the canonical MCP resource URI and its trusted authorization server in Protected Resource Metadata. Publish the authorization server endpoints and supported methods through RFC 8414 metadata.
3. Have clients request authorization-code access using PKCE and include the MCP server's canonical URI as the RFC 8707 `resource` parameter in both authorization and token requests.
4. Issue a short-lived token tied to the authorizing OneLink user and account. Validate issuer, expiry, audience/resource binding, and granted scopes on every MCP request. Map the token back to the same user/account context used by the existing API-token path.
5. Apply the existing account access policy and per-tool confirmation checks after token validation. Revoke access when the user is removed from the account or the grant is revoked; audit the OAuth client and user alongside existing MCP call records.

## Decisions needed before implementation

- Choose whether OneLink's current identity provider will act as the authorization server or whether a dedicated OAuth authorization service is required.
- Decide how clients register: controlled/manual registration first, or Dynamic Client Registration (RFC 7591) at launch.
- Define a minimal scope vocabulary and how account selection works when one user belongs to several workspaces. Scopes should grant no more authority than the existing MCP account policy.
- Choose token format, signing-key rotation, revocation behavior, consent UI, grant-management UI, and rollout/metrics. Do not accept tokens minted for unrelated OneLink APIs as MCP access tokens.

## Sources

- [MCP 2025-06-18 Authorization](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)
- [RFC 9728: OAuth 2.0 Protected Resource Metadata](https://www.rfc-editor.org/rfc/rfc9728)
- [RFC 8414: OAuth 2.0 Authorization Server Metadata](https://www.rfc-editor.org/rfc/rfc8414)
- [RFC 8707: Resource Indicators for OAuth 2.0](https://www.rfc-editor.org/rfc/rfc8707)
- [RFC 7591: OAuth 2.0 Dynamic Client Registration Protocol](https://www.rfc-editor.org/rfc/rfc7591)

## File location

The requested `docs/mcp_oauth_design.md` path is inside a Git submodule. To avoid changing the submodule gitlink or writing to its separate repository, this note is stored at the tracked repository path `script/onelink/mcp_oauth_design.md` instead.
