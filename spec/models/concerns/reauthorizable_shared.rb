require 'rails_helper'

shared_examples_for 'reauthorizable' do
  let(:model) { described_class } # the class that includes the concern
  let(:obj) { FactoryBot.create(model.to_s.underscore.tr('/', '_').to_sym) }

  it 'authorization_error!' do
    expect(obj.authorization_error_count).to eq 0

    obj.authorization_error!

    expect(obj.authorization_error_count).to eq 1
  end

  it 'prompts reauthorization when error threshold is passed' do
    expect(obj.reauthorization_required?).to be false

    obj.class::AUTHORIZATION_ERROR_THRESHOLD.times do
      obj.authorization_error!
    end

    expect(obj.reauthorization_required?).to be true
  end

  # Helper methods to set up mailer mocks
  def setup_automation_rule_mailer(_obj)
    account_mailer = instance_double(AdministratorNotifications::AccountNotificationMailer)
    automation_mailer_response = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
    allow(AdministratorNotifications::AccountNotificationMailer).to receive(:with).and_return(account_mailer)
    allow(account_mailer).to receive(:automation_rule_disabled).and_return(automation_mailer_response)
  end

  def setup_integrations_hook_mailer(obj)
    integrations_mailer = instance_double(AdministratorNotifications::IntegrationsNotificationMailer)
    slack_mailer_response = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
    dialogflow_mailer_response = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
    allow(AdministratorNotifications::IntegrationsNotificationMailer).to receive(:with).and_return(integrations_mailer)
    allow(integrations_mailer).to receive(:slack_disconnect).and_return(slack_mailer_response)
    allow(integrations_mailer).to receive(:dialogflow_disconnect).and_return(dialogflow_mailer_response)

    # Allow the model to respond to slack? and dialogflow? methods
    allow(obj).to receive(:slack?).and_return(true)
    allow(obj).to receive(:dialogflow?).and_return(false)
  end

  def setup_channel_mailer(_obj)
    channel_mailer = instance_double(AdministratorNotifications::ChannelNotificationsMailer)
    allow(AdministratorNotifications::ChannelNotificationsMailer).to receive(:with).and_return(channel_mailer)

    %i[facebook whatsapp email instagram tiktok].each do |provider|
      mailer_response = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
      allow(channel_mailer).to receive("#{provider}_disconnect").and_return(mailer_response)
    end
  end

  describe 'prompt_reauthorization!' do
    before do
      # Setup mailer mocks based on model type
      if model.to_s == 'AutomationRule'
        setup_automation_rule_mailer(obj)
      elsif model.to_s == 'Integrations::Hook'
        setup_integrations_hook_mailer(obj)
      else
        setup_channel_mailer(obj)
      end
    end

    it 'sets reauthorization required flag' do
      expect(obj.reauthorization_required?).to be false
      obj.prompt_reauthorization!
      expect(obj.reauthorization_required?).to be true
    end

    it 'calls the correct mailer based on model type' do
      obj.prompt_reauthorization!

      if model.to_s == 'AutomationRule'
        expect(AdministratorNotifications::AccountNotificationMailer).to have_received(:with).with(account: obj.account)
      elsif model.to_s == 'Integrations::Hook'
        expect(AdministratorNotifications::IntegrationsNotificationMailer).to have_received(:with).with(account: obj.account)
      else
        expect(AdministratorNotifications::ChannelNotificationsMailer).to have_received(:with).with(account: obj.account)
      end
    end

    it 'notifies only once while reauthorization is already required' do
      2.times { obj.prompt_reauthorization! }

      if model.to_s == 'AutomationRule'
        expect(AdministratorNotifications::AccountNotificationMailer).to have_received(:with).with(account: obj.account).once
      elsif model.to_s == 'Integrations::Hook'
        expect(AdministratorNotifications::IntegrationsNotificationMailer).to have_received(:with).with(account: obj.account).once
      else
        expect(AdministratorNotifications::ChannelNotificationsMailer).to have_received(:with).with(account: obj.account).once
      end
    end

    it 'releases the transition claim when its notification handler fails' do
      handler_method = case model.to_s
                       when 'AutomationRule' then :handle_automation_rule_reauthorization
                       when 'Integrations::Hook' then :process_integration_hook_reauthorization_emails
                       else :send_channel_reauthorization_email
                       end
      allow(obj).to receive(handler_method).and_raise(StandardError, 'queue unavailable')

      expect { obj.prompt_reauthorization! }.to raise_error(StandardError, 'queue unavailable')
      durable_reauthorization = model.const_defined?(:DURABLE_REAUTHORIZATION_CONFIG_KEY)
      expect(obj.reauthorization_required?).to be(durable_reauthorization)

      allow(obj).to receive(handler_method).and_return(true)
      expect(obj.prompt_reauthorization!).to be(true)
      expect(obj.reauthorization_required?).to be(true)
      expect(Redis::Alfred.get(obj.send(:reauthorization_required_key))).to be_present
      expect(obj).to have_received(handler_method).twice
    end
  end

  if described_class.name.start_with?('Channel::')
    describe 'inbox reauthorization events' do
      before do
        setup_channel_mailer(obj)
        allow(Rails.configuration.dispatcher).to receive(:dispatch)
      end

      it 'emits inbox.updated once when authorization errors cross the threshold' do
        with_modified_env ENABLE_INBOX_EVENTS: 'true' do
          (obj.class::AUTHORIZATION_ERROR_THRESHOLD + 1).times do
            obj.authorization_error!
          end
        end

        expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
          Events::Types::INBOX_UPDATED,
          kind_of(Time),
          inbox: obj.inbox,
          changed_attributes: { 'reauthorization_required' => [false, true] }
        ).once
      end

      it 'emits inbox.updated when reauthorization is cleared' do
        with_modified_env ENABLE_INBOX_EVENTS: 'true' do
          obj.prompt_reauthorization!
          obj.reauthorized!
        end

        expect(Rails.configuration.dispatcher).to have_received(:dispatch).with(
          Events::Types::INBOX_UPDATED,
          kind_of(Time),
          inbox: obj.inbox,
          changed_attributes: { 'reauthorization_required' => [true, false] }
        ).once
      end
    end
  end

  it 'reauthorized!' do
    # setting up the object with the errors to validate its cleared on action
    obj.authorization_error!
    obj.prompt_reauthorization!
    expect(obj.reauthorization_required?).to be true
    expect(obj.authorization_error_count).not_to eq 0

    obj.reauthorized!

    # authorization errors are reset
    expect(obj.authorization_error_count).to eq 0
    expect(obj.reauthorization_required?).to be false
  end
end
