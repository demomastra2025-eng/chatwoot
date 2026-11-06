# frozen_string_literal: true

# Streams only the blob already attached to the account-owned message; no filename or URL is copied.
class Messages::VoiceCoreAttachmentSpool
  EXTENSION_ALIASES = { 'oga' => 'ogg', 'mpeg' => 'mp3', 'mpga' => 'mp3', 'mp4' => 'm4a' }.freeze

  def initialize(attachment)
    @attachment = attachment
  end

  def open(&)
    account_id = @attachment.message.account_id
    raise Telephony::VoiceCoreClient::Error, 'invalid_attachment_account' unless @attachment.account_id == account_id

    Telephony::VoiceCoreAudioSpool.new(account_id: account_id, source: self).open(&)
  end

  def stage(spool)
    raise Telephony::VoiceCoreClient::Error, 'attachment_not_found' unless @attachment.file.attached?

    extension = Messages::AudioTranscriptionFile.new(@attachment).canonical_extension
    extension = EXTENSION_ALIASES.fetch(extension, extension)
    blob = @attachment.file.blob
    spool.write_audio(".#{extension}") do |write|
      # The native download block streams chunks; the shared writer enforces the cumulative byte cap.
      blob.download { |chunk| write.call(chunk) }
    end
  end
end
