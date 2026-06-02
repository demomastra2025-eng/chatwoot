require 'digest'
require 'net/imap'
require 'timeout'

class Inboxes::FetchImapEmailsJob < MutexApplicationJob
  EMAIL_PROCESSING_TIMEOUT_SECONDS = ENV.fetch('EMAIL_PROCESSING_TIMEOUT_SECONDS', 30).to_i
  PROBLEMATIC_EMAIL_FAILURE_THRESHOLD = ENV.fetch('EMAIL_PROBLEMATIC_FAILURE_THRESHOLD', 3).to_i
  PROBLEMATIC_EMAIL_FAILURE_TTL = 1.day

  queue_as :scheduled_jobs

  def perform(channel, interval = 1)
    return unless should_fetch_email?(channel)

    key = format(::Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: channel.inbox.id)

    with_lock(key, 5.minutes) do
      process_email_for_channel(channel, interval)
    end
  rescue *ExceptionList::IMAP_EXCEPTIONS => e
    Rails.logger.error "Authorization error for email channel - #{channel.inbox.id} : #{e.message}"
  rescue IOError, OpenSSL::SSL::SSLError, Net::IMAP::NoResponseError, Net::IMAP::BadResponseError, Net::IMAP::InvalidResponseError,
         Net::IMAP::ResponseParseError, Net::IMAP::ResponseReadError, Net::IMAP::ResponseTooLargeError => e
    Rails.logger.error "Error for email channel - #{channel.inbox.id} : #{e.message}"
  rescue LockAcquisitionError
    Rails.logger.error "Lock failed for #{channel.inbox.id}"
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
  end

  private

  def should_fetch_email?(channel)
    channel.imap_enabled? && !channel.reauthorization_required?
  end

  def process_email_for_channel(channel, interval)
    inbound_emails = if channel.microsoft?
                       Imap::MicrosoftFetchEmailService.new(channel: channel, interval: interval).perform
                     elsif channel.google?
                       Imap::GoogleFetchEmailService.new(channel: channel, interval: interval).perform
                     else
                       Imap::FetchEmailService.new(channel: channel, interval: interval).perform
                     end
    inbound_emails.each do |inbound_mail|
      next if skip_problematic_email?(inbound_mail, channel)

      process_mail(inbound_mail, channel)
    end
  rescue OAuth2::Error => e
    Rails.logger.error "Error for email channel - #{channel.inbox.id} : #{e.message}"
    channel.authorization_error!
  rescue BaseRefreshOauthTokenService::MissingRefreshTokenError => e
    Rails.logger.error "Reauthorization required for email channel - #{channel.inbox.id} : #{e.message}"
    channel.prompt_reauthorization!
  end

  def process_mail(inbound_mail, channel)
    Timeout.timeout(email_processing_timeout) do
      Imap::ImapMailbox.new.process(inbound_mail, channel)
    end
    clear_problematic_email_failure(inbound_mail, channel)
  rescue StandardError => e
    record_problematic_email_failure(inbound_mail, channel)
    ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
    Rails.logger.error("
      #{channel.provider} Email dropped: #{inbound_mail.from} and message_source_id: #{inbound_mail.message_id}")
  end

  def skip_problematic_email?(inbound_mail, channel)
    return false if problematic_email_failure_count(inbound_mail, channel) < problematic_email_failure_threshold

    Rails.logger.warn(
      "[IMAP] Skipping problematic email for inbox #{channel.inbox.id} with message_source_id: #{problematic_email_identifier(inbound_mail)}"
    )
    true
  end

  def record_problematic_email_failure(inbound_mail, channel)
    Redis::Alfred.setex(problematic_email_failure_cache_key(inbound_mail, channel), problematic_email_failure_count(inbound_mail, channel) + 1,
                        PROBLEMATIC_EMAIL_FAILURE_TTL)
  end

  def clear_problematic_email_failure(inbound_mail, channel)
    Redis::Alfred.delete(problematic_email_failure_cache_key(inbound_mail, channel))
  end

  def problematic_email_failure_count(inbound_mail, channel)
    Redis::Alfred.get(problematic_email_failure_cache_key(inbound_mail, channel)).to_i
  end

  def problematic_email_failure_cache_key(inbound_mail, channel)
    "imap:problematic-email:#{channel.id}:#{Digest::SHA256.hexdigest(problematic_email_identifier(inbound_mail))}"
  end

  def problematic_email_identifier(inbound_mail)
    inbound_mail.message_id.to_s.presence || Digest::SHA256.hexdigest(problematic_email_fingerprint(inbound_mail))
  end

  def problematic_email_fingerprint(inbound_mail)
    %i[from to subject date].filter_map { |attribute| safe_mail_attribute(inbound_mail, attribute) }.join(':')
  end

  def safe_mail_attribute(inbound_mail, attribute)
    return unless inbound_mail.respond_to?(attribute)

    inbound_mail.public_send(attribute).to_s
  rescue StandardError
    nil
  end

  def email_processing_timeout
    [EMAIL_PROCESSING_TIMEOUT_SECONDS, 1].max
  end

  def problematic_email_failure_threshold
    [PROBLEMATIC_EMAIL_FAILURE_THRESHOLD, 1].max
  end
end
