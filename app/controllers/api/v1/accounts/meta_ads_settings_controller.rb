# frozen_string_literal: true

class Api::V1::Accounts::MetaAdsSettingsController < Api::V1::Accounts::BaseController
  RECENT_SOURCES_LIMIT = 50
  RECENT_SOURCE_KEY_SQL = "COALESCE(NULLIF(BTRIM(source_id), ''), NULLIF(BTRIM(ad_id), ''))"

  before_action :current_account
  before_action :ensure_account_member!, only: [:show]
  before_action :ensure_administrator!, only: [:update]

  def show
    render json: settings_payload, status: :ok
  end

  def update
    persist_settings_attributes!
    ensure_system_label_if_enabled!
    render json: settings_payload, status: :ok
  end

  private

  def ensure_account_member!
    raise Pundit::NotAuthorizedError if Current.account_user.blank?
  end

  def ensure_administrator!
    raise Pundit::NotAuthorizedError unless Current.account_user&.administrator?
  end

  def persist_settings_attributes!
    Current.account.with_lock('FOR NO KEY UPDATE') do
      attrs = Current.account.custom_attributes.to_h.deep_dup
      apply_auto_tag_param!(attrs)
      apply_source_rules_param!(attrs)
      Current.account.update!(custom_attributes: attrs)
    end
  end

  def apply_auto_tag_param!(attrs)
    return unless params.key?(:auto_tag_enabled)

    attrs['meta_ads_auto_tag'] = ActiveModel::Type::Boolean.new.cast(params[:auto_tag_enabled]) == true
  end

  def apply_source_rules_param!(attrs)
    return unless params.key?(:source_rules)

    attrs['meta_ads_source_label_map'] = normalized_source_label_map(params[:source_rules])
    attrs.delete('meta_ads_source_labels')
  end

  def ensure_system_label_if_enabled!
    return unless Meta::AdReferralAutoTagger.auto_tag_enabled?(Current.account)

    Meta::AdReferralAutoTagger.ensure_system_label!(Current.account)
  end

  def settings_payload
    sys_label = Meta::AdReferralAutoTagger.find_system_label(Current.account)
    {
      auto_tag_enabled: Meta::AdReferralAutoTagger.auto_tag_enabled?(Current.account),
      system_label: system_label_json(sys_label),
      source_rules: serialized_source_rules,
      recent_sources: recent_referral_sources
    }
  end

  def system_label_json(label)
    {
      id: label&.id,
      title: label&.title || Meta::AdReferralAutoTagger::DEFAULT_AD_LABEL_TITLE,
      display_title: label&.display_title.presence || Meta::AdReferralAutoTagger::DEFAULT_AD_DISPLAY_TITLE,
      color: label&.color.presence || Meta::AdReferralAutoTagger::DEFAULT_AD_COLOR,
      exists: label.present?
    }
  end

  def account_labels_index
    labels = Current.account.labels.reorder(:id).to_a
    {
      by_id: labels.index_by(&:id),
      by_name: index_labels_by_name(labels)
    }
  end

  def index_labels_by_name(labels)
    labels.each_with_object({}) do |lbl, acc|
      acc[lbl.title.to_s.downcase] ||= lbl if lbl.title.present?
      acc[lbl.display_title.to_s.downcase] ||= lbl if lbl.display_title.present?
    end
  end

  def serialized_source_rules
    raw_map = raw_source_label_map
    return [] unless raw_map.is_a?(Hash)

    idx = account_labels_index
    raw_map.filter_map { |source_key, raw_targets| serialize_source_rule(idx, source_key, raw_targets) }
  end

  def raw_source_label_map
    attrs = Current.account.custom_attributes.to_h
    attrs['meta_ads_source_label_map'].presence || attrs['meta_ads_source_labels']
  end

  def serialize_source_rule(idx, source_key, raw_targets)
    source_id = source_key.to_s.strip
    return nil if source_id.blank?

    matched = Array(raw_targets).filter_map { |target| resolve_label_from_index(idx, target) }.uniq(&:id)
    return nil if matched.empty?

    {
      source_id: source_id,
      label_ids: matched.map(&:id),
      labels: matched.map { |lbl| serialize_label(lbl) }
    }
  end

  def serialize_label(lbl)
    { id: lbl.id, title: lbl.title, display_title: lbl.display_title.presence || lbl.title, color: lbl.color }
  end

  def resolve_label_from_index(idx, target)
    val = target.to_s.strip
    return nil if val.blank?
    return idx[:by_id][val.to_i] || idx[:by_name][val.downcase] if target.is_a?(Integer) || val.match?(/\A\d+\z/)

    idx[:by_name][val.downcase]
  end

  def normalized_source_label_map(raw_rules)
    rules_list = extract_rules_array(raw_rules)
    return {} if rules_list.empty?

    valid_ids = Current.account.labels.reorder(nil).pluck(:id).to_set
    rules_list.each_with_object({}) do |entry, acc|
      append_normalized_rule!(acc, entry, valid_ids)
    end
  end

  def extract_rules_array(raw_rules)
    return raw_rules.values if raw_rules.is_a?(ActionController::Parameters)
    return raw_rules if raw_rules.is_a?(Array)

    []
  end

  def append_normalized_rule!(acc, entry, valid_ids)
    hash = normalize_rule_hash(entry)
    source_id = hash['source_id'].to_s.strip
    return if source_id.blank?

    ids = extract_valid_label_ids(hash, valid_ids)
    return if ids.empty?

    acc[source_id] = ((acc[source_id] || []) + ids).uniq
  end

  def normalize_rule_hash(entry)
    raw = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.to_h
    raw.stringify_keys
  rescue StandardError
    {}
  end

  def extract_valid_label_ids(hash, valid_ids)
    raw = hash['label_ids'] || hash['label_id']
    list = raw.is_a?(Hash) ? raw.values : Array(raw)
    list
      .flatten
      .filter_map { |val| val.to_i if val.respond_to?(:to_i) }
      .select { |id| valid_ids.include?(id) }
      .uniq
  end

  def recent_referral_sources
    recent_referral_rows.map { |row| serialize_recent_source_row(row) }
  end

  def recent_referral_rows
    MetaAdReferral
      .where(account_id: Current.account.id)
      .where("#{RECENT_SOURCE_KEY_SQL} IS NOT NULL")
      .group(Arel.sql(RECENT_SOURCE_KEY_SQL))
      .order(Arel.sql('MAX(received_at) DESC'))
      .limit(RECENT_SOURCES_LIMIT)
      .pluck(*recent_referral_pluck_columns)
  end

  def recent_referral_pluck_columns
    [
      Arel.sql(RECENT_SOURCE_KEY_SQL),
      Arel.sql("MAX(NULLIF(BTRIM(headline), ''))"),
      Arel.sql("MAX(NULLIF(BTRIM(body), ''))"),
      Arel.sql('MAX(provider)'),
      Arel.sql('COUNT(*)'),
      Arel.sql('MAX(received_at)')
    ]
  end

  def serialize_recent_source_row(row)
    {
      source_id: row[0],
      headline: row[1],
      body: row[2],
      provider: row[3],
      referrals_count: row[4].to_i,
      last_received_at: row[5]&.iso8601
    }
  end
end
