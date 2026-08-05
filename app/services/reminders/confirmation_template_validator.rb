# frozen_string_literal: true

class Reminders::ConfirmationTemplateValidator
  def initialize(account:, inbox:, template_params:, button_index:)
    @account = account
    @inbox = inbox
    @template_params = template_params
    @button_index = button_index
  end

  def valid?
    return false unless account_scoped_whatsapp_cloud_inbox?
    return false unless button_index.to_s == '0'

    buttons.one? && quick_reply_button?(buttons.first)
  end

  private

  attr_reader :account, :inbox, :template_params, :button_index

  def account_scoped_whatsapp_cloud_inbox?
    inbox&.account_id == account&.id &&
      inbox.channel.is_a?(Channel::Whatsapp) &&
      inbox.channel.provider == 'whatsapp_cloud'
  end

  def buttons
    @buttons ||= Array(selected_template&.[](:buttons))
  end

  def selected_template
    @selected_template ||= Outbound::ChannelTemplateCatalog.new(inbox: inbox).find_template(template_params.to_h)
  end

  def quick_reply_button?(button)
    button.present? && button.with_indifferent_access[:type].to_s.casecmp('QUICK_REPLY').zero?
  end
end
