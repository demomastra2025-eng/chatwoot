# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join 'spec/models/concerns/out_of_offisable_shared.rb'
require Rails.root.join 'spec/models/concerns/avatarable_shared.rb'

RSpec.describe Inbox do
  describe 'validations' do
    it { is_expected.to validate_presence_of(:account_id) }
    it { is_expected.to validate_presence_of(:name) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:account) }

    it { is_expected.to belong_to(:channel) }

    it { is_expected.to have_many(:campaign_deliveries).dependent(:delete_all) }

    it { is_expected.to have_many(:contact_inboxes).dependent(:destroy_async) }

    it { is_expected.to have_many(:contacts).through(:contact_inboxes) }

    it { is_expected.to have_many(:inbox_members).dependent(:destroy_async) }

    it { is_expected.to have_many(:members).through(:inbox_members).source(:user) }

    it { is_expected.to have_many(:conversations).dependent(:destroy_async) }

    it { is_expected.to have_many(:messages).dependent(:destroy_async) }

    it { is_expected.to have_many(:meta_ad_referrals).dependent(:delete_all) }

    it { is_expected.to have_many(:webhooks).dependent(:destroy_async) }

    it { is_expected.to have_many(:reporting_events) }

    it { is_expected.to have_many(:hooks) }
  end

  describe 'lock_to_single_conversation defaults' do
    let(:account) { create(:account) }

    def build_inbox(channel:, lock_to_single_conversation: nil)
      attributes = {
        account: account,
        name: 'Inbox',
        channel: channel
      }
      attributes[:lock_to_single_conversation] = lock_to_single_conversation unless lock_to_single_conversation.nil?

      described_class.new(attributes)
    end

    def build_twilio_channel(medium:)
      Channel::TwilioSms.new(
        account: account,
        account_sid: 'AC123456789',
        auth_token: 'test-token',
        medium: medium,
        messaging_service_sid: 'MG123456789'
      )
    end

    it 'defaults to true for messenger channels' do
      messenger_channels = [
        Channel::FacebookPage.new(account: account),
        Channel::Instagram.new(account: account),
        Channel::Line.new(account: account),
        Channel::Telegram.new(account: account),
        Channel::TelegramPersonal.new(account: account),
        Channel::TwitterProfile.new(account: account),
        Channel::Tiktok.new(account: account),
        Channel::VkCommunity.new(account: account),
        Channel::Weixin.new(account: account),
        Channel::Whatsapp.new(account: account),
        Channel::WhatsappWeb.new(account: account),
        build_twilio_channel(medium: :whatsapp)
      ]

      messenger_channels.each do |channel|
        inbox = build_inbox(channel: channel)

        inbox.valid?

        expect(inbox.lock_to_single_conversation).to be(true), channel.class.name
      end
    end

    it 'keeps false by default for non-messenger channels' do
      non_messenger_channels = [
        Channel::Api.new(account: account),
        Channel::Email.new(account: account),
        Channel::Sms.new(account: account),
        Channel::WebWidget.new(account: account),
        build_twilio_channel(medium: :sms)
      ]

      non_messenger_channels.each do |channel|
        inbox = build_inbox(channel: channel)

        inbox.valid?

        expect(inbox.lock_to_single_conversation).to be(false), channel.class.name
      end
    end

    it 'ignores an explicit false value for messenger channels' do
      inbox = build_inbox(
        channel: Channel::TelegramPersonal.new(account: account),
        lock_to_single_conversation: false
      )

      inbox.valid?

      expect(inbox.lock_to_single_conversation).to be(true)
      expect(inbox[:lock_to_single_conversation]).to be(true)
    end

    it 'ignores an explicit true value for non-messenger channels' do
      inbox = build_inbox(
        channel: Channel::Email.new(account: account),
        lock_to_single_conversation: true
      )

      inbox.valid?

      expect(inbox.lock_to_single_conversation).to be(false)
      expect(inbox[:lock_to_single_conversation]).to be(false)
    end
  end

  describe 'concerns' do
    it_behaves_like 'out_of_offisable'
    it_behaves_like 'avatarable'
  end

  describe '#add_members' do
    let(:inbox) { FactoryBot.create(:inbox) }

    before do
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
    end

    it 'handles adds all members and resets cache keys' do
      users = FactoryBot.create_list(:user, 3)
      inbox.add_members(users.map(&:id))
      expect(inbox.reload.inbox_members.size).to eq(3)

      expect(Rails.configuration.dispatcher).to have_received(:dispatch).at_least(:once)
                                                                        .with(
                                                                          'account.cache_invalidated',
                                                                          kind_of(Time),
                                                                          account: inbox.account,
                                                                          cache_keys: inbox.account.cache_keys
                                                                        )
    end
  end

  describe '#remove_members' do
    let(:inbox) { FactoryBot.create(:inbox) }
    let(:users) { FactoryBot.create_list(:user, 3) }

    before do
      inbox.add_members(users.map(&:id))
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
    end

    it 'removes the members and resets cache keys' do
      expect(inbox.reload.inbox_members.size).to eq(3)

      inbox.remove_members(users.map(&:id))
      expect(inbox.reload.inbox_members.size).to eq(0)

      expect(Rails.configuration.dispatcher).to have_received(:dispatch).at_least(:once)
                                                                        .with(
                                                                          'account.cache_invalidated',
                                                                          kind_of(Time),
                                                                          account: inbox.account,
                                                                          cache_keys: inbox.account.cache_keys
                                                                        )
    end
  end

  describe '#facebook?' do
    let(:inbox) do
      FactoryBot.build(:inbox, channel: channel_val)
    end

    context 'when the channel type is Channel::FacebookPage' do
      let(:channel_val) { Channel::FacebookPage.new }

      it do
        expect(inbox.facebook?).to be(true)
        expect(inbox.inbox_type).to eq('Facebook')
      end
    end

    context 'when the channel type is not Channel::FacebookPage' do
      let(:channel_val) { Channel::WebWidget.new }

      it do
        expect(inbox.facebook?).to be(false)
        expect(inbox.inbox_type).to eq('Website')
      end
    end
  end

  describe '#web_widget?' do
    let(:inbox) do
      FactoryBot.build(:inbox, channel: channel_val)
    end

    context 'when the channel type is Channel::WebWidget' do
      let(:channel_val) { Channel::WebWidget.new }

      it do
        expect(inbox.web_widget?).to be(true)
        expect(inbox.inbox_type).to eq('Website')
      end
    end

    context 'when the channel is not Channel::WebWidget' do
      let(:channel_val) { Channel::Api.new }

      it do
        expect(inbox.web_widget?).to be(false)
        expect(inbox.inbox_type).to eq('API')
      end
    end
  end

  describe '#api?' do
    let(:inbox) do
      FactoryBot.build(:inbox, channel: channel_val)
    end

    context 'when the channel type is Channel::Api' do
      let(:channel_val) { Channel::Api.new }

      it do
        expect(inbox.api?).to be(true)
        expect(inbox.inbox_type).to eq('API')
      end
    end

    context 'when the channel is not Channel::Api' do
      let(:channel_val) { Channel::FacebookPage.new }

      it do
        expect(inbox.api?).to be(false)
        expect(inbox.inbox_type).to eq('Facebook')
      end
    end
  end

  describe '#whatsapp_web?' do
    let(:inbox) do
      FactoryBot.build(:inbox, channel: channel_val)
    end

    context 'when the channel type is Channel::WhatsappWeb' do
      let(:channel_val) { Channel::WhatsappWeb.new }

      it do
        expect(inbox.whatsapp_web?).to be(true)
        expect(inbox.display_channel_type).to eq('Channel::WhatsappWeb')
      end
    end

    context 'when the channel is a legacy Channel::Api whatsapp web provider' do
      let(:channel_val) do
        Channel::Api.new(additional_attributes: { 'provider' => Channel::Api::WHATSAPP_WEB_PROVIDER })
      end

      it do
        expect(inbox.whatsapp_web?).to be(false)
        expect(inbox.display_channel_type).to eq('Channel::Api')
      end
    end
  end

  describe '#validations' do
    let(:inbox) { FactoryBot.create(:inbox) }

    context 'when validating inbox name' do
      it 'does not allow empty string' do
        I18n.with_locale(:en) do
          inbox.name = ''
          expect(inbox).not_to be_valid
          expect(inbox.errors.full_messages[0]).to eq(
            "Name can't be blank"
          )
        end
      end

      it 'does allow special characters except /\@<> in between' do
        inbox.name = 'inbox-name'
        expect(inbox).to be_valid

        inbox.name = 'inbox_name.and_1'
        expect(inbox).to be_valid
      end

      context 'when special characters allowed for some channel' do
        let!(:tw_channel_val) { FactoryBot.create(:channel_twitter_profile) }
        let(:inbox) { create(:inbox, channel: tw_channel_val) }

        it 'does allow special chacters like /\@<> for Facebook Channel' do
          inbox.name = 'inbox@name'
          expect(inbox).to be_valid
        end
      end
    end
  end

  describe '#update' do
    let!(:inbox) { FactoryBot.create(:inbox) }
    let!(:portal) { FactoryBot.create(:portal) }

    before do
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
    end

    it 'set portal id in inbox' do
      inbox.portal_id = portal.id
      inbox.save

      expect(inbox.portal).to eq(portal)
    end

    it 'sends the inbox_created event if ENABLE_INBOX_EVENTS is true' do
      with_modified_env ENABLE_INBOX_EVENTS: 'true' do
        channel = inbox.channel
        channel.update(widget_color: '#fff')

        expect(Rails.configuration.dispatcher).to have_received(:dispatch)
          .with(
            'inbox.updated',
            kind_of(Time),
            inbox: inbox,
            changed_attributes: kind_of(Object)
          )
      end
    end

    it 'sends the inbox_created event if ENABLE_INBOX_EVENTS is false' do
      channel = inbox.channel
      channel.update(widget_color: '#fff')

      expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
        .with(
          'inbox.updated',
          kind_of(Time),
          inbox: inbox,
          changed_attributes: kind_of(Object)
        )
    end

    it 'resets cache key if there is an update in the channel' do
      channel = inbox.channel
      channel.update(widget_color: '#fff')

      expect(Rails.configuration.dispatcher).to have_received(:dispatch)
        .with(
          'account.cache_invalidated',
          kind_of(Time),
          account: inbox.account,
          cache_keys: inbox.account.cache_keys
        )
    end

    it 'updates the cache key after update' do
      expect(inbox.account).to receive(:update_cache_key).with('inbox')
      inbox.update(name: 'New Name')
    end

    it 'updates the cache key after touch' do
      expect(inbox.account).to receive(:update_cache_key).with('inbox')
      inbox.touch # rubocop:disable Rails/SkipsModelValidations
    end
  end

  describe '#sanitized_name' do
    context 'when inbox name contains forbidden characters' do
      it 'removes forbidden and spam-trigger characters' do
        inbox = FactoryBot.build(:inbox, name: 'Test/Name\\With<Bad>@Characters"And\';:Quotes!#$%()')
        expect(inbox.sanitized_name).to eq('Test/NameWithBadCharactersAnd\'Quotes')
      end
    end

    context 'when inbox name has leading/trailing non-word characters' do
      it 'removes leading and trailing symbols' do
        inbox = FactoryBot.build(:inbox, name: '!!!Test Name***')
        expect(inbox.sanitized_name).to eq('Test Name')
      end

      it 'handles mixed leading/trailing characters' do
        inbox = FactoryBot.build(:inbox, name: '###@@@Test Inbox Name$$$%%')
        expect(inbox.sanitized_name).to eq('Test Inbox Name')
      end
    end

    context 'when inbox name has multiple spaces' do
      it 'normalizes multiple spaces to single space' do
        inbox = FactoryBot.build(:inbox, name: 'Test    Multiple     Spaces')
        expect(inbox.sanitized_name).to eq('Test Multiple Spaces')
      end

      it 'handles tabs and other whitespace' do
        inbox = FactoryBot.build(:inbox, name: "Test\t\nMultiple\r\nSpaces")
        expect(inbox.sanitized_name).to eq('Test Multiple Spaces')
      end
    end

    context 'when inbox name has leading/trailing whitespace' do
      it 'strips whitespace' do
        inbox = FactoryBot.build(:inbox, name: '   Test Name   ')
        expect(inbox.sanitized_name).to eq('Test Name')
      end
    end

    context 'when inbox name becomes empty after sanitization' do
      context 'with email channel' do
        it 'falls back to email local part' do
          email_channel = FactoryBot.build(:channel_email, email: 'support@example.com')
          inbox = FactoryBot.build(:inbox, name: '\\<>@"', channel: email_channel)
          expect(inbox.sanitized_name).to eq('Support')
        end

        it 'handles email with complex local part' do
          email_channel = FactoryBot.build(:channel_email, email: 'help-desk_team@example.com')
          inbox = FactoryBot.build(:inbox, name: '!!!@@@', channel: email_channel)
          expect(inbox.sanitized_name).to eq('Help Desk Team')
        end
      end

      context 'with non-email channel' do
        it 'returns empty string when name becomes blank' do
          web_widget_channel = FactoryBot.build(:channel_widget)
          inbox = FactoryBot.build(:inbox, name: '\\<>@"', channel: web_widget_channel)
          expect(inbox.sanitized_name).to eq('')
        end
      end
    end

    context 'when inbox name is blank initially' do
      context 'with email channel' do
        it 'uses email local part as fallback' do
          email_channel = FactoryBot.build(:channel_email, email: 'customer-care@example.com')
          inbox = FactoryBot.build(:inbox, name: '', channel: email_channel)
          expect(inbox.sanitized_name).to eq('Customer Care')
        end
      end

      context 'with non-email channel' do
        it 'returns empty string' do
          api_channel = FactoryBot.build(:channel_api)
          inbox = FactoryBot.build(:inbox, name: '', channel: api_channel)
          expect(inbox.sanitized_name).to eq('')
        end
      end
    end

    context 'when inbox name contains valid characters' do
      it 'preserves valid characters like hyphens, underscores, and dots' do
        inbox = FactoryBot.build(:inbox, name: 'Test-Name_With.Valid-Characters')
        expect(inbox.sanitized_name).to eq('Test-Name_With.Valid-Characters')
      end

      it 'preserves alphanumeric characters and spaces' do
        inbox = FactoryBot.build(:inbox, name: 'Customer Support 123')
        expect(inbox.sanitized_name).to eq('Customer Support 123')
      end

      it 'preserves balanced safe characters but removes spam-trigger symbols' do
        inbox = FactoryBot.build(:inbox, name: "Test!#$%&'*+/=?^_`{|}~-Name")
        expect(inbox.sanitized_name).to eq("Test'/_-Name")
      end

      it 'keeps commonly used safe characters' do
        inbox = FactoryBot.build(:inbox, name: "Support/Help's Team.Desk_2024-Main")
        expect(inbox.sanitized_name).to eq("Support/Help's Team.Desk_2024-Main")
      end
    end

    context 'when inbox name contains problematic characters for email headers' do
      it 'preserves Unicode symbols (trademark, etc.)' do
        inbox = FactoryBot.build(:inbox, name: 'Test™Name®With©Special™Characters')
        expect(inbox.sanitized_name).to eq('Test™Name®With©Special™Characters')
      end
    end

    context 'with edge cases' do
      it 'handles nil name gracefully' do
        inbox = FactoryBot.build(:inbox)
        allow(inbox).to receive(:name).and_return(nil)
        expect { inbox.sanitized_name }.not_to raise_error
      end

      it 'handles very long names' do
        long_name = 'A' * 1000
        inbox = FactoryBot.build(:inbox, name: long_name)
        expect(inbox.sanitized_name).to eq(long_name)
      end

      it 'handles unicode characters and preserves emojis' do
        inbox = FactoryBot.build(:inbox, name: 'Test Name with émojis 🎉')
        expect(inbox.sanitized_name).to eq('Test Name with émojis 🎉')
      end
    end
  end

  describe '#sanitized_business_name' do
    it 'sanitizes business name before using it in email From headers' do
      inbox = FactoryBot.build(:inbox, name: 'Support Inbox', business_name: 'Giro Crédito - Soporte (Email)')

      expect(inbox.sanitized_business_name).to eq('Giro Crédito - Soporte Email')
    end

    it 'falls back to sanitized inbox name when business name is blank after sanitization' do
      inbox = FactoryBot.build(:inbox, name: 'Support Inbox', business_name: '()')

      expect(inbox.sanitized_business_name).to eq('Support Inbox')
    end
  end
end
