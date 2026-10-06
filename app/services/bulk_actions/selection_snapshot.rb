class BulkActions::SelectionSnapshot
  PURPOSE = 'conversation-bulk-selection'.freeze
  TOKEN_TTL = 5.minutes
  MAX_SELECTION_SIZE = 10_000
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

  Selection = Data.define(:token, :ids, :record_ids, :count, :inbox_ids, :inbox_ids_by_id) do
    def to_h
      super.except(:record_ids)
    end
  end
  Claims = Data.define(:ids, :record_ids, :count, :resource_type)

  def self.verify!(token, account:, user:, resource_type:)
    payload = verifier.verify(token, purpose: PURPOSE).with_indifferent_access
    validate_identity!(payload, account, user, resource_type)
    claims_from(payload, resource_type)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError, TypeError
    raise InvalidSelection
  end

  def self.validate_identity!(payload, account, user, resource_type)
    raise InvalidSelection unless payload[:version] == 1
    raise InvalidSelection unless payload[:account_id].to_i == account.id
    raise InvalidSelection unless payload[:user_id].to_i == user.id
    raise InvalidSelection unless payload[:resource_type] == resource_type
    raise InvalidSelection unless RESOURCE_TYPES.include?(resource_type)
  end

  def self.claims_from(payload, resource_type)
    ids = Array(payload[:ids]).map { |id| Integer(id) }
    record_ids = Array(payload[:record_ids]).map { |id| Integer(id) }
    count = Integer(payload[:count])
    raise InvalidSelection unless valid_ids?(ids, record_ids, count)

    Claims.new(ids: ids, record_ids: record_ids, count: count, resource_type: resource_type)
  end

  def self.valid_ids?(ids, record_ids, count)
    count.between?(1, MAX_SELECTION_SIZE) && valid_id_list?(ids, count) && valid_id_list?(record_ids, count)
  end

  def self.valid_id_list?(ids, count)
    ids.size == count && ids.uniq.size == count && ids.all?(&:positive?)
  end

  def self.verifier
    Rails.application.message_verifier(:bulk_action_selection)
  end

  def initialize(account:, user:, resource_type:, filters:)
    @account = account
    @user = user
    @resource_type = resource_type
    raise InvalidFilters unless filters.is_a?(Hash)

    @filters = filters.to_h.deep_transform_keys { |key| key.to_s.underscore }.with_indifferent_access
    @filters.delete(:q) if @filters[:q].blank?
  end

  def perform
    raise InvalidSelection unless RESOURCE_TYPES.include?(@resource_type)
    raise InvalidSelection unless @account.account_users.exists?(user_id: @user.id)

    records = selected_records
    build_selection(records)
  end

  private

  def selected_records
    records = matching_scope.except(:order, :limit, :offset).reorder(nil).distinct
                            .limit(MAX_SELECTION_SIZE + 1).pluck(:id, :display_id)
    raise TooManyRecords, MAX_SELECTION_SIZE if records.size > MAX_SELECTION_SIZE
    raise EmptySelection if records.empty?

    records
  end

  def build_selection(records)
    record_ids = records.map(&:first)
    ids = records.map(&:last)
    inbox_ids_by_id = inbox_ids_by_id_for(ids)
    Selection.new(
      token: signed_token(ids, record_ids),
      ids: ids,
      record_ids: record_ids,
      count: records.size,
      inbox_ids: inbox_ids_by_id.values.flatten.uniq,
      inbox_ids_by_id: inbox_ids_by_id
    )
  end

  def signed_token(ids, record_ids)
    payload = {
      version: 1, account_id: @account.id, user_id: @user.id,
      resource_type: @resource_type, record_ids: record_ids, ids: ids, count: ids.size
    }
    self.class.verifier.generate(payload, expires_in: TOKEN_TTL, purpose: PURPOSE)
  end

  def matching_scope
    validate_filter_keys!
    validate_search_filters!

    @filters[:mode] == 'advanced' ? advanced_filter_scope : finder_scope
  end

  def validate_search_filters!
    raise InvalidFilters if @filters.key?(:query)
    return if @filters[:q].blank?

    raise InvalidFilters unless @filters[:q].is_a?(String)
    raise InvalidFilters if @filters[:mode] == 'advanced'
    raise InvalidFilters if @resource_type == 'CommunicationThread'
  end

  def validate_filter_keys!
    invalid_keys = @filters.keys.map(&:to_s) - FILTER_KEYS
    raise InvalidFilters if invalid_keys.present?
    raise InvalidFilters unless %w[basic advanced].include?(@filters[:mode].presence || 'basic')
  end

  def finder_scope
    filters = @filters.except(:mode, :query_data, :communication_thread_mode, :page, :query)
    filters = filters.slice(:q) if filters[:q].present?
    case @resource_type
    when 'Conversation'
      ConversationFinder.new(@user, filters, @account).selection_scope
    when 'CommunicationThread'
      CommunicationThreadFinder.new(@user, filters, @account).selection_scope
    end
  end

  def advanced_filter_scope
    raise InvalidFilters unless @filters[:query_data].is_a?(Hash)

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
    return conversation_inboxes_by_id(ids) if @resource_type == 'Conversation'

    thread_inboxes_by_id(ids)
  end

  def conversation_inboxes_by_id(ids)
    @account.conversations.where(display_id: ids).pluck(:display_id, :inbox_id).each_with_object({}) do |(id, inbox_id), result|
      result[id.to_s] = [inbox_id]
    end
  end

  def thread_inboxes_by_id(ids)
    threads_by_id = CommunicationThread.where(account_id: @account.id, display_id: ids).pluck(:id, :display_id).to_h
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
