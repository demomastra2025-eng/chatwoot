# == Schema Information
#
# Table name: channel_instagram
#
#  id           :bigint           not null, primary key
#  access_token :string           not null
#  expires_at   :datetime         not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :integer          not null
#  instagram_id :string           not null
#
# Indexes
#
#  index_channel_instagram_on_instagram_id  (instagram_id) UNIQUE
#
class Channel::Instagram < ApplicationRecord
  include Channelable
  include Reauthorizable
  self.table_name = 'channel_instagram'

  attr_accessor :skip_auto_subscribe

  # TODO: Remove guard once encryption keys become mandatory (target 3-4 releases out).
  encrypts :access_token if Chatwoot.encryption_configured?

  AUTHORIZATION_ERROR_THRESHOLD = 1

  validates :access_token, presence: true
  validates :instagram_id, uniqueness: true, presence: true

  after_create_commit :subscribe, unless: :skip_auto_subscribe?
  before_destroy :unsubscribe

  def name
    'Instagram'
  end

  def create_contact_inbox(instagram_id, name)
    @contact_inbox = ::ContactInboxWithContactBuilder.new({
                                                            source_id: instagram_id,
                                                            inbox: inbox,
                                                            contact_attributes: { name: name }
                                                          }).perform
  end

  def subscribe(raise_on_error: false, access_token: nil)
    subscription_access_token = access_token.presence || self.access_token

    # ref https://developers.facebook.com/docs/instagram-platform/webhooks#enable-subscriptions
    response = HTTParty.post(
      "https://graph.instagram.com/v22.0/#{instagram_id}/subscribed_apps",
      query: {
        subscribed_fields: %w[messages message_reactions messaging_seen],
        access_token: subscription_access_token
      }
    )

    if raise_on_error && response.respond_to?(:success?) && !response.success?
      raise "Instagram webhook subscription failed: #{response.code} - #{response.body}"
    end

    response
  rescue StandardError => e
    redacted_error = redacted_subscription_error(e, subscription_access_token)
    Rails.logger.debug { "Rescued: #{e.class}: #{redacted_error}" }
    raise StandardError, redacted_error if raise_on_error

    true
  end

  def skip_auto_subscribe?
    ActiveModel::Type::Boolean.new.cast(skip_auto_subscribe)
  end

  def unsubscribe
    HTTParty.delete(
      "https://graph.instagram.com/v22.0/#{instagram_id}/subscribed_apps",
      query: {
        access_token: access_token
      }
    )
    true
  rescue StandardError => e
    Rails.logger.debug { "Rescued: #{e.inspect}" }
    true
  end

  def access_token
    Instagram::RefreshOauthTokenService.new(channel: self).access_token
  end

  def provider_authorization_healthy?
    Meta::AuthorizationHealthCheckService.new(self).healthy?
  end

  private

  def redacted_subscription_error(error, token)
    Array.wrap(token).compact_blank.each_with_object(error.message.to_s.dup) do |token_value, message|
      message.gsub!(token_value.to_s, '[FILTERED]')
    end.gsub(/access_token=[^&\s]+/, 'access_token=[FILTERED]')
  end
end
