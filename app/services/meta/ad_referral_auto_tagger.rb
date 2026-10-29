# frozen_string_literal: true

class Meta::AdReferralAutoTagger
  DEFAULT_AD_LABEL_TITLE = 'meta_ads'
  DEFAULT_AD_DISPLAY_TITLE = 'Meta Ads'
  DEFAULT_AD_COLOR = '#1F93FF'
  DEFAULT_AD_DESCRIPTION = 'Обращения с рекламы Meta (Instagram / Facebook / WhatsApp)'
  SYSTEM_AD_LABEL_NAMES = ['meta_ads', 'meta ads'].freeze

  attr_reader :referral, :message

  def self.auto_tag_enabled?(account)
    return false if account.blank?

    raw = account.custom_attributes.to_h.with_indifferent_access[:meta_ads_auto_tag]
    raw.nil? || ActiveModel::Type::Boolean.new.cast(raw) == true
  end

  def self.find_system_label(account)
    return nil if account.blank?

    account.labels
           .reorder(:id)
           .where('LOWER(title) IN (:names) OR LOWER(display_title) IN (:names)', names: SYSTEM_AD_LABEL_NAMES)
           .first
  end

  def self.ensure_system_label!(account)
    existing = find_system_label(account)
    return existing if existing.present?

    Label.transaction(requires_new: true) do
      account.labels.find_or_create_by!(title: DEFAULT_AD_LABEL_TITLE) do |label|
        label.display_title = DEFAULT_AD_DISPLAY_TITLE
        label.color = DEFAULT_AD_COLOR
        label.description = DEFAULT_AD_DESCRIPTION
        label.show_on_sidebar = true
      end
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_system_label(account)
  end

  def initialize(referral:, message: nil)
    @referral = referral
    @message = message
  end

  def perform
    return if referral.blank? || account.blank?

    ActiveRecord::Base.transaction(requires_new: true) do
      label_titles = resolved_label_titles
      next if label_titles.empty?

      assign_labels!(label_titles)
    end
  rescue StandardError => e
    Rails.logger.warn("[MetaAdReferral] auto-tagging failed: #{e.class}: #{e.message}")
  end

  private

  def account
    @account ||= referral.account || message&.account
  end

  def conversation
    @conversation ||= referral.conversation || message&.conversation
  end

  def contact
    @contact ||= referral.contact || conversation&.contact || sender_contact
  end

  def sender_contact
    message.sender if message&.sender.is_a?(Contact)
  end

  def account_custom_attributes
    @account_custom_attributes ||= account.custom_attributes.to_h.with_indifferent_access
  end

  def resolved_label_titles
    titles = []
    base = resolve_base_label
    titles << base.title if base.present?
    titles.concat(resolve_source_mapped_labels.map(&:title))
    titles.compact_blank.uniq
  end

  def resolve_base_label
    return nil unless self.class.auto_tag_enabled?(account)

    configured = account_custom_attributes[:meta_ads_auto_label].presence
    return find_or_build_configured_base_label(configured) if configured.present?

    ensure_default_ad_label
  end

  def find_or_build_configured_base_label(identifier)
    found = find_account_label(identifier)
    return found if found.present?
    return nil if identifier.to_s.match?(/\A\d+\z/)

    create_account_label(identifier.to_s.strip)
  end

  def find_default_ad_label
    self.class.find_system_label(account)
  end

  def ensure_default_ad_label
    existing = find_default_ad_label
    return existing if existing.present?

    self.class.ensure_system_label!(account)
  end

  def create_account_label(name)
    return nil if name.blank?

    attrs = { display_title: name, color: DEFAULT_AD_COLOR }
    attrs[:title] = name.downcase if name.downcase.match?(RegexHelper::UNICODE_CHARACTER_NUMBER_HYPHEN_UNDERSCORE)
    Label.transaction(requires_new: true) do
      account.labels.create!(attrs)
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_account_label_by_name(name)
  end

  def resolve_source_mapped_labels
    mapping = source_label_mapping
    return [] if mapping.empty?

    source_keys.flat_map { |key| Array(mapping[key]) }
               .compact_blank
               .filter_map { |identifier| find_account_label(identifier) }
  end

  def source_label_mapping
    raw = account_custom_attributes[:meta_ads_source_label_map].presence ||
          account_custom_attributes[:meta_ads_source_labels]
    return {} unless raw.is_a?(Hash)

    raw.each_with_object({}) do |(key, val), acc|
      stripped = key.to_s.strip
      acc[stripped] = Array(acc[stripped]) + Array(val) if stripped.present?
    end
  end

  def source_keys
    [referral.source_id, referral.ad_id].map { |val| val.to_s.strip }.reject(&:blank?).uniq
  end

  def find_account_label(identifier)
    value = identifier.to_s.strip
    return nil if value.blank?

    if identifier.is_a?(Integer) || value.match?(/\A\d+\z/)
      by_id = account.labels.reorder(nil).find_by(id: value.to_i)
      return by_id if by_id.present?
    end

    find_account_label_by_name(value)
  end

  def find_account_label_by_name(name)
    normalized = name.to_s.strip
    return nil if normalized.blank?

    account.labels
           .reorder(:id)
           .where('LOWER(title) = LOWER(:name) OR LOWER(display_title) = LOWER(:name)', name: normalized)
           .first
  end

  def assign_labels!(label_titles)
    if contact.present?
      Labels::UnifiedAssignmentService.add(
        contact: contact,
        labels: label_titles,
        conversation: conversation
      )
    elsif conversation.present?
      existing = conversation.label_list.map(&:downcase)
      missing = label_titles.reject { |title| existing.include?(title.downcase) }
      conversation.add_labels(missing) if missing.any?
    end
  end
end
