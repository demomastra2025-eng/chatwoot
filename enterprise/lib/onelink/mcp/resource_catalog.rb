# frozen_string_literal: true

module Onelink
  module Mcp
    class ResourceCatalog
      MIME_JSON = 'application/json'
      MIME_TEXT = 'text/plain'

      def initialize(auth_context:, captain_tool_adapter:, openapi_catalog:)
        @auth_context = auth_context
        @captain_tool_adapter = captain_tool_adapter
        @openapi_catalog = openapi_catalog
      end

      def list
        [
          resource(
            uri: account_uri('profile'),
            name: 'OneLink workspace profile',
            description: 'Current account, authenticated user, and MCP assistant context.',
            mime_type: MIME_JSON
          ),
          resource(
            uri: account_uri('tools/catalog'),
            name: 'OneLink MCP tool catalog',
            description: 'Current account-scoped MCP tools visible to this token.',
            mime_type: MIME_JSON
          ),
          resource(
            uri: account_uri('assistants'),
            name: 'Captain assistants',
            description: 'Captain assistants in the current workspace.',
            mime_type: MIME_JSON
          ),
          resource(
            uri: account_uri('openapi/tools'),
            name: 'OpenAPI fallback catalog',
            description: 'OpenAPI-derived MCP fallback tools allowed by the current workspace MCP policy.',
            mime_type: MIME_JSON
          )
        ]
      end

      def read(uri)
        normalized_uri = uri.to_s
        payload =
          case normalized_uri
          when account_uri('profile')
            profile_payload
          when account_uri('tools/catalog')
            { tools: @captain_tool_adapter.tools + @openapi_catalog.tools }
          when account_uri('assistants')
            assistants_payload
          when account_uri('openapi/tools'), account_uri('openapi/read_only_tools')
            { tools: @openapi_catalog.tools }
          else
            raise Onelink::Mcp::Server::JsonRpcError.new(-32_002, 'Resource not found')
          end

        {
          contents: [
            {
              uri: normalized_uri,
              mimeType: MIME_JSON,
              text: JSON.pretty_generate(payload.as_json)
            }
          ]
        }
      end

      private

      attr_reader :auth_context

      def account_uri(path)
        "onelink://accounts/#{auth_context.account.id}/#{path}"
      end

      def resource(uri:, name:, description:, mime_type:)
        {
          uri: uri,
          name: name,
          description: description,
          mimeType: mime_type
        }
      end

      def profile_payload
        {
          account: account_payload,
          user: user_payload,
          account_user: account_user_payload,
          assistant: assistant_payload,
          mcp_access: mcp_access_summary,
          scope_name: auth_context.scope_name
        }
      end

      def account_payload
        {
          id: auth_context.account.id,
          name: auth_context.account.name
        }
      end

      def user_payload
        {
          id: auth_context.user.id,
          name: auth_context.user.name,
          email: auth_context.user.email
        }
      end

      def account_user_payload
        {
          id: auth_context.account_user&.id,
          role: auth_context.account_user&.role,
          administrator: auth_context.administrator?
        }
      end

      def assistant_payload
        {
          id: auth_context.assistant.persisted? ? auth_context.assistant.id : nil,
          name: auth_context.assistant.name,
          usage_mode: auth_context.assistant.usage_mode
        }
      end

      def mcp_access_summary
        access = auth_context.mcp_access_policy.config
        {
          enabled: access['enabled'],
          max_risk_level: access['max_risk_level'],
          sources: access['sources'],
          require_confirmation_for_mutations: access['require_confirmation_for_mutations']
        }
      end

      def assistants_payload
        assistants = Captain::Assistant.for_account(auth_context.account.id).ordered.limit(100)
        {
          assistants: assistants.map do |assistant|
            {
              id: assistant.id,
              name: assistant.name,
              description: assistant.description,
              usage_mode: assistant.usage_mode,
              created_at: assistant.created_at&.iso8601,
              updated_at: assistant.updated_at&.iso8601
            }
          end
        }
      end
    end
  end
end
