# frozen_string_literal: true

require Rails.root.join('enterprise/lib/onelink/mcp/access_policy').to_s

module Onelink
  module Mcp
    class AuthContext
      DEFAULT_SCOPE_NAME = Captain::ToolAccess::SCOPE_ASSISTANT
      VIRTUAL_ASSISTANT_NAME = 'Workspace MCP'
      VIRTUAL_ASSISTANT_DESCRIPTION = 'Virtual assistant used to expose account-scoped OneLink MCP tools.'

      attr_reader :account, :account_user, :access_token, :assistant, :request, :scope_name, :user

      def self.from_controller(controller)
        query_parameters = controller.request.query_parameters.with_indifferent_access
        new(
          account: Current.account,
          account_user: Current.account_user,
          user: Current.user,
          access_token: controller.instance_variable_get(:@access_token),
          request: controller.request,
          assistant_id: query_parameters[:assistant_id],
          scope_name: query_parameters[:scope]
        )
      end

      def self.from_assistant_tool(assistant:, user:, scope_name: DEFAULT_SCOPE_NAME)
        account = assistant.account
        account_user = user.present? ? account.account_users.find_by(user_id: user.id) : nil

        new(
          account: account,
          account_user: account_user,
          user: user,
          access_token: nil,
          request: nil,
          assistant_id: assistant.persisted? ? assistant.id : nil,
          scope_name: scope_name
        )
      end

      def initialize(account:, account_user:, user:, access_token:, request:, assistant_id: nil, scope_name: nil)
        @account = account
        @account_user = account_user
        @user = user
        @access_token = access_token
        @request = request
        @scope_name = normalize_scope_name(scope_name)
        @assistant = resolve_assistant(assistant_id)
      end

      def user_token?
        access_token.present? && access_token.owner.is_a?(User) && user.is_a?(User)
      end

      def administrator?
        account_user&.administrator?
      end

      def token_value
        access_token&.token.to_s
      end

      def base_url
        request&.base_url.to_s
      end

      def metadata
        {
          account_id: account.id,
          user_id: user.id,
          account_user_id: account_user&.id,
          assistant_id: assistant.persisted? ? assistant.id : nil,
          scope_name: scope_name
        }.compact
      end

      def mcp_access_policy
        @mcp_access_policy ||= Onelink::Mcp::AccessPolicy.new(auth_context: self)
      end

      private

      def normalize_scope_name(value)
        normalized = value.to_s.presence || DEFAULT_SCOPE_NAME
        return normalized if Captain::ToolAccess::SCOPE_ORDER.include?(normalized)

        DEFAULT_SCOPE_NAME
      end

      def resolve_assistant(assistant_id)
        return find_assistant!(assistant_id) if assistant_id.present?

        default_assistant || virtual_assistant
      end

      def find_assistant!(assistant_id)
        Captain::Assistant.for_account(account.id).external_agent.find(assistant_id)
      end

      def default_assistant
        Captain::Assistant.for_account(account.id).external_agent.order(updated_at: :desc, id: :desc).first
      end

      def virtual_assistant
        Captain::Assistant.new(
          account: account,
          name: VIRTUAL_ASSISTANT_NAME,
          description: VIRTUAL_ASSISTANT_DESCRIPTION,
          usage_mode: 'external_agent',
          config: {}
        )
      end
    end
  end
end
