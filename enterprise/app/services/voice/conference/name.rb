require 'digest'

module Voice::Conference::Name
  def self.for(conversation, call_ref: nil)
    base_name = "conf_account_#{conversation.account_id}_conv_#{conversation.display_id}"
    return base_name if call_ref.blank?

    "#{base_name}_call_#{Digest::SHA256.hexdigest(call_ref.to_s).first(16)}"
  end
end
