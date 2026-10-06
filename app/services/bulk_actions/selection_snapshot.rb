module BulkActions
  class SelectionSnapshot
    PURPOSE = 'conversation-bulk-selection'.freeze
    TOKEN_TTL = 5.minutes
    MAX_SELECTION_SIZE = 1_000
    RESOURCE_TYPES = %w[Conversation CommunicationThread].freeze
    FILTER_KEYS = %w[
      inbox_id status assignee_type team_id labels conversation_type sort_by
      crm_pipeline_id crm_stage_id appointment_status labels_scope team_scope
      unread source_id page mode query_data communication_thread_mode q query
    ].freeze
    ADVANCED_CONTEXT_KEYS = %w[
      crm_pipeline_id crm_stage_id appointment_status labels_scope team_scope
      unread sort_by page
    ].freeze

    class InvalidSelection < StandardError; end
    class InvalidFilters < StandardError; end
    class EmptySelection < StandardError; end

    class TooManyRecords < StandardError
      attr_reader :limit

      def initialize(limit)
        @limit = limit
        super("Bulk selection exceeds the limit of #{limit}")
      end
    end

    Selection = Struct.new(:token, :ids, :record_ids, :count, :inbox_ids, :inbox_ids_by_id, keyword_init: true) do
      def to_h
        super.except(:record_ids)
      end
    end
    Claims = Struct.new(:ids, :record_ids, :count, :resource_type, keyword_init: true)

    def self.verify!(token, account:, user:, resource_type:)
      payload = verifier.verify(token, purpose: PURPOSE).with_indifferent_access
      raise InvalidSelection unless payload[:version] == 1
      raise InvalidSelection unless payload[:account_id].to_i == account.id
      raise InvalidSelection unless payload[:user_id].to_i == user.id
      raise InvalidSelection unless payload[:resource_type] == resource_type
      raise InvalidSelection unless RESOURCE_TYPES.include?(resource_type)

      ids = Array(payload[:ids]).map { |id| Integer(id) }
      record_ids = Array(payload[:record_ids]).map { |id| Integer(id) }
      count = Integer(payload[:count])
      raise InvalidSelection if ids.empty? || ids.size > MAX_SELECTION_SIZE
      raise InvalidSelection unless ids.size == ids.uniq.size && ids.size == count
      raise InvalidSelection unless record_ids.size == count && record_ids.size == record_ids.uniq.size
      raise InvalidSelection if (ids + record_ids).any?(&:negative?) || (ids + record_ids).any?(&:zero?)

      Claims.new(ids: ids, record_ids: record_ids, count: count, resource_type: resource_type)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, TypeError
      raise InvalidSelection
    end

    def self.verifier
      Rails.application.message_verifier(:bulk_action_selection)
    end

    def initialize(account:, user:, resource_type:, filters:)
      @account = account
      @user = user
      @resource_type = resource_type
      @filters = filters.to_h.deep_transform_keys { |key| key.to_s.underscore }.with_indifferent_access
    end

    def perform
      raise InvalidSelection unless RESOURCE_TYPES.include?(@resource_type)
      raise InvalidSelection unless @account.account_users.exists?(user_id: @user.id)

      records = matching_scope.except(:order).reorder(nil).distinct.limit(MAX_SELECTION_SIZE + 1).pluck(:id, :display_id)
      raise TooManyRecords, MAX_SELECTION_SIZE if records.size > MAX_SELECTION_SIZE
      raise EmptySelection if records.empty?

      record_ids = records.map(&:first)
      ids = records.map(&:last)

      payload = {
        version: 1,
        account_id: @account.id,
        user_id: @user.id,
        resource_type: @resource_type,
        record_ids: record_ids,
        ids: ids,
        count: records.size
      }

      inbox_ids_by_id = inbox_ids_by_id_for(ids)
      Selection.new(
        token: self.class.verifier.generate(payload, expires_in: TOKEN_TTL, purpose: PURPOSE),
        ids: ids,
        record_ids: record_ids,
        count: records.size,
        inbox_ids: inbox_ids_by_id.values.flatten.uniq,
        inbox_ids_by_id: inbox_ids_by_id
      )
    end

    private

    def matching_scope
      validate_filter_keys!
      raise InvalidFilters if @filters[:q].present? || @filters[:query].present?

      @filters[:mode] == 'advanced' ? advanced_filter_scope : finder_scope
    end

    def validate_filter_keys!
      invalid_keys = @filters.keys.map(&:to_s) - FILTER_KEYS
      raise InvalidFilters if invalid_keys.present?
    end

    def finder_scope
      filters = @filters.except(:mode, :query_data, :communication_thread_mode, :page, :q, :query)
      case @resource_type
      when 'Conversation'
        ConversationFinder.new(@user, filters, current_account: @account).selection_scope
      when 'CommunicationThread'
        CommunicationThreadFinder.new(@user, filters, current_account: @account).selection_scope
      end
    end

    def advanced_filter_scope
      query_data = @filters[:query_data].to_h.with_indifferent_access
      raise InvalidFilters unless query_data[:payload].is_a?(Array)

      context = @filters.slice(*ADVANCED_CONTEXT_KEYS)
      filter_params = query_data.merge(context).except(:page, :sort_by)
      case @resource_type
      when 'Conversation'
        Conversations::FilterService.new(filter_params, @user, @account).selection_scope
      when 'CommunicationThread'
        CommunicationThreads::FilterService.new(filter_params, @user, @account).selection_scope
      end
    end

    def inbox_ids_by_id_for(ids)
      if @resource_type == 'Conversation'
        return @account.conversations.where(display_id: ids).pluck(:display_id, :inbox_id).each_with_object({}) do |(id, inbox_id), result|
          result[id.to_s] = [inbox_id]
        end
      end

      threads_by_id = @account.communication_threads.where(display_id: ids).pluck(:id, :display_id).to_h
      thread_ids = threads_by_id.keys
      accessible_conversation_ids = Conversations::PermissionFilterService.new(
        @account.conversations,
        @user,
        @account
      ).perform.select(:id)
      links_by_thread_id = CommunicationThreadConversation
        .where(account_id: @account.id, communication_thread_id: thread_ids)
        .where(conversation_id: accessible_conversation_ids)
        .pluck(:communication_thread_id, :inbox_id)
        .group_by(&:first)

      threads_by_id.each_with_object({}) do |(thread_id, display_id), result|
        result[display_id.to_s] = Array(links_by_thread_id[thread_id]).map(&:last).uniq
      end
    end
  end
end
