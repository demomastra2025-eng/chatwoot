require 'stringio'

class TelegramPersonal::SyncProfileAvatarJob < ApplicationJob
  AVATAR_FINGERPRINT_METADATA_KEY = 'telegram_avatar_fingerprint'.freeze

  queue_as :default

  retry_on TelegramPersonal::GatewayClient::GatewayError, wait: 30.seconds, attempts: 3

  def perform(contact_channel_profile_id, avatar_fingerprint)
    profile = find_syncable_profile(contact_channel_profile_id, avatar_fingerprint)
    return if profile.blank?
    return if avatar_already_synced?(profile, avatar_fingerprint)

    attach_avatar(
      profile,
      fetch_avatar_payload(profile, avatar_fingerprint),
      avatar_fingerprint
    )
  rescue StandardError => e
    Rails.logger.error(
      "[TELEGRAM PERSONAL] Profile avatar sync failed for profile=#{contact_channel_profile_id} " \
      "fingerprint=#{avatar_fingerprint}: #{e.class}: #{e.message}"
    )
    raise
  end

  private

  def find_syncable_profile(contact_channel_profile_id, avatar_fingerprint)
    return if avatar_fingerprint.blank?

    profile = ContactChannelProfile.find_by(id: contact_channel_profile_id)
    return if profile.blank?
    return unless profile.provider == 'telegram_personal'
    return if profile.source_id.blank?
    return unless profile.inbox&.channel.is_a?(Channel::TelegramPersonal)

    profile
  end

  def fetch_avatar_payload(profile, avatar_fingerprint)
    TelegramPersonal::GatewayClient.new(channel: profile.inbox.channel).fetch_profile_avatar!(
      peer_user_id: profile.source_id,
      avatar_fingerprint: avatar_fingerprint
    )
  end

  def attach_avatar(profile, payload, avatar_fingerprint)
    profile.avatar.attach(
      io: StringIO.new(payload[:body]),
      filename: avatar_filename(profile, payload[:content_type]),
      content_type: payload[:content_type],
      metadata: { AVATAR_FINGERPRINT_METADATA_KEY => avatar_fingerprint }
    )
    profile.update!(last_synced_at: Time.current)
  end

  def avatar_filename(profile, content_type)
    extension = case content_type.to_s
                when 'image/png'
                  '.png'
                when 'image/gif'
                  '.gif'
                else
                  '.jpg'
                end

    "telegram-personal-avatar-#{profile.source_id}#{extension}"
  end

  def avatar_already_synced?(profile, avatar_fingerprint)
    return false unless profile.avatar.attached?

    profile.avatar.blob&.metadata&.[](AVATAR_FINGERPRINT_METADATA_KEY) == avatar_fingerprint
  end
end
