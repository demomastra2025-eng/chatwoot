# frozen_string_literal: true

class Meta::AdReferralAutoTagger
  DEFAULT_AD_LABEL_TITLE = 'реклама'
  DEFAULT_AD_DISPLAY_TITLE = 'Реклама'
  FALLBACK_AD_LABEL_NAMES = %w[реклама meta_ads].freeze

  attr_reader :referral, :message

  def initialize(referral:, message: nil)
    @referral = referral
    @message = message
  end

  def perform
    return if referral.blank? || account.blank?

    label_titles = resolved_label_titles
    return if label_titles.empty?

    ActiveRecord::Base.transaction(requires_new: true) do
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
    return nil if auto_tag_explicitly_disabled?

    configured = account_custom_attributes[:meta_ads_auto_label].presence
    return find_or_build_configured_base_label(configured) if configured.present?

    existing = find_default_ad_label
    return existing if existing.present?

    ensure_default_ad_label if auto_tag_explicitly_enabled?
  end

  def auto_tag_explicitly_disabled?
    raw = account_custom_attributes[:meta_ads_auto_tag]
    !raw.nil? && !ActiveModel::Type::Boolean.new.cast(raw)
  end

  def auto_tag_explicitly_enabled?
    ActiveModel::Type::Boolean.new.cast(account_custom_attributes[:meta_ads_auto_tag]) == true
  end

  def find_or_build_configured_base_label(identifier)
    found = find_account_label(identifier)
    return found if found.present? || !auto_tag_explicitly_enabled?
    return nil if identifier.to_s.match?(/\A\d+\z/)

    create_account_label(identifier.to_s.strip)
  end

  def find_default_ad_label
    FALLBACK_AD_LABEL_NAMES.each do |candidate|
      label = find_account_label_by_name(candidate)
      return label if label.present?
    end
    nil
  end

  def ensure_default_ad_label
    account.labels.find_or_create_by!(title: DEFAULT_AD_LABEL_TITLE) do |label|
      label.display_title = DEFAULT_AD_DISPLAY_TITLE
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_default_ad_label
  end

  def create_account_label(name)
    return nil if name.blank?

    attrs = { display_title: name }
    attrs[:title] = name.downcase if name.downcase.match?(RegexHelper::UNICODE_CHARACTER_NUMBER_HYPHEN_UNDERSCORE)
    account.labels.create!(attrs)
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
    raw.is_a?(Hash) ? raw.stringify_keys : {}
  end

  def source_keys
    [referral.source_id, referral.ad_id].compact_blank.map(&:to_s).uniq
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
