# == Schema Information
#
# Table name: channel_facebook_pages
#
#  id                :integer          not null, primary key
#  page_access_token :string           not null
#  user_access_token :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :integer          not null
#  instagram_id      :string
#  page_id           :string           not null
#
# Indexes
#
#  index_channel_facebook_pages_on_page_id                 (page_id)
#  index_channel_facebook_pages_on_page_id_and_account_id  (page_id,account_id) UNIQUE
#

class Channel::FacebookPage < ApplicationRecord
  include Channelable
  include Reauthorizable

  attr_accessor :skip_auto_subscribe

  # TODO: Remove guard once encryption keys become mandatory (target 3-4 releases out).
  if Chatwoot.encryption_configured?
    encrypts :page_access_token
    encrypts :user_access_token
  end

  self.table_name = 'channel_facebook_pages'

  validates :page_id, uniqueness: { scope: :account_id }

  after_create_commit :subscribe, unless: :skip_auto_subscribe?
  before_destroy :unsubscribe

  def name
    'Facebook'
  end

  def create_contact_inbox(instagram_id, name)
    @contact_inbox = ::ContactInboxWithContactBuilder.new({
                                                            source_id: instagram_id,
                                                            inbox: inbox,
                                                            contact_attributes: { name: name }
                                                          }).perform
  end

  def subscribe(raise_on_error: false)
    # ref https://developers.facebook.com/docs/messenger-platform/reference/webhook-events
    Facebook::Messenger::Subscriptions.subscribe(
      access_token: page_access_token,
      subscribed_fields: %w[
        messages message_deliveries message_echoes message_reads standby messaging_handovers
      ]
    )
  rescue StandardError => e
    redacted_error = redacted_subscription_error(e)
    Rails.logger.debug { "Rescued: #{e.class}: #{redacted_error}" }
    raise StandardError, redacted_error if raise_on_error

    true
  end

  def skip_auto_subscribe?
    ActiveModel::Type::Boolean.new.cast(skip_auto_subscribe)
  end

  def unsubscribe
    Facebook::Messenger::Subscriptions.unsubscribe(access_token: page_access_token)
  rescue StandardError => e
    Rails.logger.debug { "Rescued: #{e.inspect}" }
    true
  end

  def provider_authorization_healthy?
    Meta::AuthorizationHealthCheckService.new(self).healthy?
  end

  private

  def redacted_subscription_error(error)
    [page_access_token, user_access_token].compact_blank.each_with_object(error.message.to_s.dup) do |token, message|
      message.gsub!(token.to_s, '[FILTERED]')
    end.gsub(/access_token=[^&\s]+/, 'access_token=[FILTERED]')
  end
end
