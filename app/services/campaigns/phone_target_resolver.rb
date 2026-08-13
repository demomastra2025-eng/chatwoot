class Campaigns::PhoneTargetResolver
  pattr_initialize [:inbox!, :phone_number!]

  def resolve
    case inbox.channel_type
    when 'Channel::Whatsapp', 'Channel::WhatsappWeb'
      phone_number.delete('+')
    when 'Channel::Sms'
      phone_number
    when 'Channel::TwilioSms'
      inbox.channel.medium == 'whatsapp' ? "whatsapp:#{phone_number}" : phone_number
    end
  end
end
