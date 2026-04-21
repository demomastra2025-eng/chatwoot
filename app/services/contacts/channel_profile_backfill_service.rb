class Contacts::ChannelProfileBackfillService
  Result = Struct.new(
    :processed_count,
    :created_count,
    :updated_count,
    :skipped_count,
    :failed_count,
    keyword_init: true
  )

  PROFILE_DATA_KEYS = {
    'telegram' => %w[username language_code social_telegram_user_id social_telegram_user_name],
    'telegram_personal' => %w[
      username language_code first_name last_name phone_number profile_photo_url
      is_bot is_contact is_mutual_contact is_premium is_verified is_scam
      is_fake is_restricted is_deleted sync_source last_message_at unread_count
      social_telegram_user_id social_telegram_user_name
    ],
    'whatsapp_web' => %w[
      raw_jid canonical_jid lid_jid provisional_whatsapp_identity
      profile_pic_url provider
    ],
    'instagram' => %w[
      social_instagram_user_name social_instagram_follower_count
      social_instagram_is_user_follow_business social_instagram_is_business_follow_user
      social_instagram_is_verified_user
    ],
    'twitter_profile' => %w[
      screen_name location url description followers_count friends_count profile_image_url
    ],
    'vk_community' => %w[social_vk_user_id social_vk_screen_name city vk_bdate],
    'line' => %w[social_line_user_id],
    'tiktok' => %w[username social_tiktok_user_id social_tiktok_user_name],
    'twilio_sms' => %w[from_zip_code from_country from_state]
  }.freeze

  def initialize(scope: ContactInbox.all, batch_size: 500, force: false, logger: Rails.logger)
    @scope = scope
    @batch_size = batch_size
    @force = force
    @logger = logger
  end

  def perform
    result = Result.new(processed_count: 0, created_count: 0, updated_count: 0, skipped_count: 0, failed_count: 0)

    scope
      .includes(:channel_profile, :inbox, contact: { avatar_attachment: [:blob] })
      .find_each(batch_size: batch_size) do |contact_inbox|
      result.processed_count += 1
      backfill_contact_inbox(contact_inbox, result)
    rescue StandardError => e
      result.failed_count += 1
      logger.error(
        "[CONTACT CHANNEL PROFILE BACKFILL] Failed for contact_inbox=#{contact_inbox.id}: #{e.class}: #{e.message}"
      )
    end

    result
  end

  private

  attr_reader :scope, :batch_size, :force, :logger

  def backfill_contact_inbox(contact_inbox, result)
    if contact_inbox.channel_profile.present? && !force
      result.skipped_count += 1
      return
    end

    created = contact_inbox.channel_profile.blank?

    Contacts::ChannelProfileUpsertService.new(
      contact_inbox: contact_inbox,
      provider: provider_name(contact_inbox),
      profile_attributes: profile_attributes(contact_inbox)
    ).perform

    if created
      result.created_count += 1
    else
      result.updated_count += 1
    end
  end

  def profile_attributes(contact_inbox)
    contact = contact_inbox.contact
    profile_data = sanitized_profile_data(contact_inbox, merged_profile_data(contact_inbox))

    {
      name: contact.name,
      email: contact.email,
      phone_number: contact.phone_number,
      identifier: contact.identifier,
      username: preferred_username(contact_inbox, profile_data),
      avatar_url: preferred_avatar_url(contact_inbox, contact, profile_data),
      profile_data: profile_data
    }.compact
  end

  def merged_profile_data(contact_inbox)
    legacy_profile_data(contact_inbox).merge(extracted_profile_data(contact_inbox))
  end

  def legacy_profile_data(contact_inbox)
    additional_attributes = contact_inbox.contact.additional_attributes.to_h.deep_stringify_keys
    provider_profiles = additional_attributes.dig('channel_profiles', provider_name(contact_inbox))
    return {} unless provider_profiles.is_a?(Hash)

    exact_profile = exact_legacy_profile_match(contact_inbox, provider_profiles)
    return exact_profile if exact_profile.present?

    return single_legacy_profile(provider_profiles) if single_legacy_profile(provider_profiles).present?

    log_ambiguous_legacy_profile(contact_inbox, provider_profiles) if ambiguous_legacy_profiles?(provider_profiles)
    {}
  end

  def extracted_profile_data(contact_inbox)
    additional_attributes = contact_inbox.contact.additional_attributes.to_h.deep_stringify_keys
    provider = provider_name(contact_inbox)
    profile_data = additional_attributes.slice(*PROFILE_DATA_KEYS.fetch(provider, []))

    profile_data.merge!(provider_specific_profile_data(provider, additional_attributes))

    profile_data.compact
  end

  def preferred_username(contact_inbox, profile_data)
    profile_data['username'].presence ||
      instagram_username(contact_inbox.contact.additional_attributes.to_h.deep_stringify_keys).presence
  end

  def preferred_avatar_url(contact_inbox, contact, profile_data)
    candidate = profile_data['avatar_url'].presence ||
                profile_data['profile_photo_url'].presence ||
                profile_data['profile_pic_url'].presence ||
                profile_data['profile_image_url'].presence ||
                contact.avatar_url.presence

    ContactChannelProfile.persistable_avatar_url(
      provider: provider_name(contact_inbox),
      avatar_url: candidate
    )
  end

  def sanitized_profile_data(contact_inbox, profile_data)
    ContactChannelProfile.sanitize_profile_data(
      provider: provider_name(contact_inbox),
      profile_data: profile_data
    )
  end

  def instagram_username(additional_attributes)
    additional_attributes['social_instagram_user_name'].presence ||
      additional_attributes.dig('social_profiles', 'instagram').presence
  end

  def tiktok_username(additional_attributes)
    additional_attributes['social_tiktok_user_name'].presence ||
      additional_attributes.dig('social_profiles', 'tiktok').presence
  end

  def provider_specific_profile_data(provider, additional_attributes)
    return { 'username' => instagram_username(additional_attributes) } if provider == 'instagram'
    return { 'username' => tiktok_username(additional_attributes) } if provider == 'tiktok'
    return { 'peer_user_id' => additional_attributes['social_telegram_user_id'] } if provider == 'telegram_personal'
    return { 'username' => additional_attributes['screen_name'] } if provider == 'twitter_profile'

    {}
  end

  def lookup_keys(contact_inbox)
    contact = contact_inbox.contact
    provider = provider_name(contact_inbox)

    [
      contact.identifier.presence,
      contact_inbox.source_id.presence,
      "#{provider}:#{contact_inbox.source_id}".presence
    ].compact.uniq
  end

  def exact_legacy_profile_match(contact_inbox, provider_profiles)
    lookup_keys(contact_inbox).each do |key|
      profile = provider_profiles[key]
      return profile.deep_stringify_keys if profile.is_a?(Hash)
    end

    nil
  end

  def single_legacy_profile(provider_profiles)
    legacy_profiles = provider_profiles.values.select { |value| value.is_a?(Hash) }.map(&:deep_stringify_keys)
    return legacy_profiles.first if legacy_profiles.one?

    nil
  end

  def ambiguous_legacy_profiles?(provider_profiles)
    provider_profiles.values.count { |value| value.is_a?(Hash) } > 1
  end

  def log_ambiguous_legacy_profile(contact_inbox, provider_profiles)
    logger.warn(
      "[CONTACT CHANNEL PROFILE BACKFILL] Ambiguous legacy profile for contact_inbox=#{contact_inbox.id} " \
      "provider=#{provider_name(contact_inbox)} lookup_keys=#{lookup_keys(contact_inbox).join(',')} " \
      "candidate_keys=#{provider_profiles.keys.join(',')}"
    )
  end

  def provider_name(contact_inbox)
    contact_inbox.inbox.channel_type.demodulize.underscore
  end
end
