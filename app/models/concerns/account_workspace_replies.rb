module AccountWorkspaceReplies
  extend ActiveSupport::Concern

  NON_TEXT_CHANNEL_TYPES = %w[Channel::Voice Channel::Email].freeze

  included do
    store_accessor :settings, :workspace_greeting, :workspace_out_of_office
    before_validation :initialize_workspace_replies, on: :create
    validate :validate_workspace_reply_messages
    validate :validate_workspace_reply_channels
  end

  def workspace_greeting_config
    config = workspace_greeting.is_a?(Hash) ? workspace_greeting : {}
    { 'enabled' => false, 'message' => '', 'excluded_inbox_ids' => [] }.merge(config)
  end

  def workspace_out_of_office_config
    config = workspace_out_of_office.is_a?(Hash) ? workspace_out_of_office : {}
    { 'enabled' => false, 'message' => '' }.merge(config)
  end

  def workspace_greeting_enabled_for?(inbox)
    config = workspace_greeting_config
    config['enabled'] == true && config['message'].present? &&
      config['excluded_inbox_ids'].exclude?(inbox.id) &&
      NON_TEXT_CHANNEL_TYPES.exclude?(inbox.channel_type)
  end

  def workspace_greeting_message
    workspace_greeting_config['message'].to_s
  end

  def workspace_out_of_office_message
    config = workspace_out_of_office_config
    config['message'].to_s if config['enabled'] == true
  end

  private

  def initialize_workspace_replies
    self.workspace_greeting = workspace_greeting_config if workspace_greeting.nil?
    self.workspace_out_of_office = workspace_out_of_office_config if workspace_out_of_office.nil?
  end

  def validate_workspace_reply_messages
    { workspace_greeting: workspace_greeting, workspace_out_of_office: workspace_out_of_office }.each do |key, value|
      next unless value.is_a?(Hash) && value['enabled'] == true && value['message'].blank?

      errors.add(key, 'requires a message when enabled')
    end
  end

  def validate_workspace_reply_channels
    ids = workspace_greeting_config['excluded_inbox_ids']
    return unless ids.is_a?(Array) && ids.all?(Integer)

    previous = settings_in_database.to_h['workspace_greeting']
    previous_ids = previous.is_a?(Hash) ? Array(previous['excluded_inbox_ids']) : []
    added_ids = ids - previous_ids
    return if (added_ids - inboxes.where(id: added_ids).pluck(:id)).empty?

    errors.add(:workspace_greeting, 'contains channels from another account')
  end
end
