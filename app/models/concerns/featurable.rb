module Featurable
  extend ActiveSupport::Concern

  BITMASK_FEATURE_LIMIT = 63
  # Preserve the original 63 bitmask positions forever.
  # Any feature added after this list must be stored in feature_flags_overflow
  # so changes in config/features.yml order cannot reinterpret existing bits.
  LEGACY_BITMASK_FEATURE_NAMES = %w[
    inbound_emails
    channel_email
    channel_facebook
    channel_twitter
    ip_lookup
    disable_branding
    email_continuity_on_api_channel
    help_center
    agent_bots
    macros
    agent_management
    team_management
    inbox_management
    labels
    custom_attributes
    automations
    canned_responses
    integrations
    voice_recorder
    mobile_v2
    channel_website
    campaigns
    reports
    crm
    auto_resolve_conversations
    custom_reply_email
    custom_reply_domain
    audit_logs
    response_bot
    message_reply_to
    insert_article_in_reply
    inbox_view
    sla
    help_center_embedding_search
    linear_integration
    captain_integration
    custom_roles
    chatwoot_v4
    report_v4
    contact_chatwoot_support_team
    shopify_integration
    search_with_gin
    channel_instagram
    crm_integration
    channel_voice
    notion_integration
    captain_integration_v2
    whatsapp_embedded_signup
    whatsapp_campaign
    crm_v2
    assignment_v2
    twilio_content_templates
    advanced_search
    saml
    advanced_search_indexing
    reply_mailer_migration
    quoted_email_reply
    companies
    channel_tiktok
    csat_review_notes
    captain_tasks
    conversation_required_attributes
    advanced_assignment
  ].freeze
  QUERY_MODE = {
    flag_query_mode: :bit_operator,
    check_for_column: false
  }.freeze

  FEATURE_LIST = YAML.safe_load(Rails.root.join('config/features.yml').read).freeze
  FEATURE_NAMES = FEATURE_LIST.pluck('name').freeze
  FEATURE_POSITIONS = LEGACY_BITMASK_FEATURE_NAMES.each_with_index.each_with_object({}) do |(feature_name, index), result|
    result[feature_name] = index + 1 if FEATURE_NAMES.include?(feature_name)
  end.freeze
  OVERFLOW_FEATURE_NAMES = (FEATURE_NAMES - LEGACY_BITMASK_FEATURE_NAMES).freeze

  FEATURES = FEATURE_POSITIONS.each_with_object({}) do |(name, position), result|
    result[position] = "feature_#{name}".to_sym
  end

  included do
    include FlagShihTzu
    has_flags FEATURES.merge(column: 'feature_flags').merge(QUERY_MODE)

    before_create :enable_default_features

    define_method(:selected_feature_flags) do
      FEATURE_NAMES.filter_map do |feature_name|
        feature_name.to_sym if feature_enabled?(feature_name)
      end
    end

    define_method(:selected_feature_flags=) do |features|
      apply_selected_feature_flags(features)
    end
  end

  OVERFLOW_FEATURE_NAMES.each do |feature_name|
    define_method("feature_#{feature_name}?") do
      overflow_feature_enabled?(feature_name)
    end

    define_method("feature_#{feature_name}=") do |value|
      set_overflow_feature(feature_name, value)
    end
  end

  def enable_features(*names)
    names.each do |name|
      set_feature_state(name, true)
    end
  end

  def enable_features!(*names)
    enable_features(*names)
    save
  end

  def disable_features(*names)
    names.each do |name|
      set_feature_state(name, false)
    end
  end

  def disable_features!(*names)
    disable_features(*names)
    save
  end

  def feature_enabled?(name)
    normalized_name = normalize_feature_name(name)
    return false unless FEATURE_NAMES.include?(normalized_name)
    return overflow_feature_enabled?(normalized_name) if overflow_feature?(normalized_name)

    public_send("feature_#{normalized_name}?")
  end

  def all_features
    FEATURE_NAMES.index_with do |feature_name|
      feature_enabled?(feature_name)
    end
  end

  def enabled_features
    all_features.select { |_feature, enabled| enabled == true }
  end

  def disabled_features
    all_features.select { |_feature, enabled| enabled == false }
  end

  def apply_selected_feature_flags(features)
    normalized_names = Array(features).flatten.filter_map do |feature_name|
      normalized_feature_name = normalize_feature_name(feature_name)
      normalized_feature_name if FEATURE_NAMES.include?(normalized_feature_name)
    end

    FEATURE_NAMES.each do |feature_name|
      set_feature_state(feature_name, normalized_names.include?(feature_name))
    end
  end

  private

  def enable_default_features
    config = InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    return true if config.blank?

    features_to_enabled = Array(config.value).filter_map do |feature|
      feature = feature.with_indifferent_access
      feature[:name] if feature[:enabled]
    end
    enable_features(*features_to_enabled)
  end

  def normalize_feature_name(name)
    name.to_s.sub(/\Afeature_/, '')
  end

  def overflow_feature?(name)
    OVERFLOW_FEATURE_NAMES.include?(name)
  end

  def overflow_feature_enabled?(name)
    overflow_feature_flags.include?(normalize_feature_name(name))
  end

  def overflow_feature_flags
    return [] unless supports_overflow_feature_flags?

    Array(self[:feature_flags_overflow]).map(&:to_s).uniq & OVERFLOW_FEATURE_NAMES
  end

  def set_feature_state(name, enabled)
    normalized_name = normalize_feature_name(name)
    return unless FEATURE_NAMES.include?(normalized_name)

    if overflow_feature?(normalized_name)
      set_overflow_feature(normalized_name, enabled)
    else
      public_send("feature_#{normalized_name}=", ActiveModel::Type::Boolean.new.cast(enabled))
    end
  end

  def set_overflow_feature(name, enabled)
    return unless supports_overflow_feature_flags?

    normalized_name = normalize_feature_name(name)
    flags = overflow_feature_flags

    if ActiveModel::Type::Boolean.new.cast(enabled)
      flags |= [normalized_name]
    else
      flags -= [normalized_name]
    end

    self[:feature_flags_overflow] = flags
  end

  def supports_overflow_feature_flags?
    has_attribute?(:feature_flags_overflow) || self.class.column_names.include?('feature_flags_overflow')
  end
end
