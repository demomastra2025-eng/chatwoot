require 'rails_helper'

# Literal search of message text in the global search, and who may find what. Separate from search_service_spec.rb, whose
# examples describe the long-standing behaviour (English whole-word matching of Latin text) and are not touched.
RSpec.describe SearchService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }

  before do
    Current.account = account
    create(:inbox_member, user: user, inbox: inbox)
  end

  after { Current.account = nil }

  def enable_gin(enabled)
    allow(account).to receive(:feature_enabled?).and_call_original
    allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(enabled)
  end

  def service(text, type = 'Message', as: user, **extra)
    described_class.new(current_user: as, current_account: account, params: { q: text, **extra }, search_type: type)
  end

  def found_ids(text, **options)
    service(text, **options).perform[:messages].map(&:id)
  end

  def message(content, minutes_ago = 0, conversation_inbox: inbox, **attributes)
    create(:message, account: account, inbox: conversation_inbox, content: content, created_at: minutes_ago.minutes.ago, **attributes)
  end

  [true, false].each do |gin|
    context "with search_with_gin #{gin ? 'enabled (the production setting)' : 'disabled'}" do
      before { enable_gin(gin) }

      describe 'literal text' do
        let!(:past) { message('Мы записали вас на среду') }
        let!(:noun) { message('Ваша запись подтверждена') }
        let!(:infinitive) { message('Хотите записаться на приём?') }

        it 'finds the typed text as typed and no other word form of it' do
          aggregate_failures do
            expect(found_ids('записаться')).to eq([infinitive.id])
            expect(found_ids('записали')).to eq([past.id])
            expect(found_ids('запись')).to eq([noun.id])
          end
        end

        it 'finds a part of a word, ignoring the case, and е and ё are the same letter' do
          with_yo = message('Нужен приём врача')

          aggregate_failures do
            expect(found_ids('запис')).to contain_exactly(past.id, noun.id, infinitive.id)
            expect(found_ids('ЗАПИСАЛИ')).to eq([past.id])
            expect(found_ids('прием')).to contain_exactly(infinitive.id, with_yo.id)
            expect(found_ids('ПРИЁМ врача')).to eq([with_yo.id])
          end
        end

        it 'does not search the messages of another account or of an inbox the user cannot open' do
          create(:message, content: 'Мы записали вас в другом аккаунте')
          create(:message, account: account, inbox: create(:inbox, account: account), content: 'Мы записали вас в чужом ящике')

          expect(found_ids('записали')).to eq([past.id])
        end

        it 'pages the results newest first' do
          messages = Array.new(17) { |index| message('нужна справка', index) }

          aggregate_failures do
            expect(found_ids('справка')).to eq(messages.first(15).map(&:id))
            expect(found_ids('справка', page: 2)).to eq(messages.last(2).map(&:id))
            expect(found_ids('справка', page: 3)).to be_empty
          end
        end

        it 'survives a NUL byte, exotic spaces and characters that are operators in SQL or in a full-text query' do
          aggregate_failures do
            ["запис\u0000али", "вас\u00A0на\u2009среду", "50% (скидка) [vip] _x_ \\", "a & b | (c", 'foo:* bar', "it's", '!!!'].each do |text|
              expect { service(text).perform[:messages].to_a }.not_to raise_error, "expected #{text.inspect} not to fail"
            end
            expect(found_ids("вас\u00A0на\u2009среду")).to eq([past.id])
          end
        end

        it 'tells the controller when the time limit cut the search short, and still answers' do
          searching = service('справка')
          allow_any_instance_of(Search::MessageQuery).to receive(:newest).and_return(Search::MessageQuery::Result.new([], true)) # rubocop:disable RSpec/AnyInstance

          expect(searching.perform[:messages].to_a).to be_empty
          expect(searching).to be_messages_partial
        end

        it 'is not partial when nothing was cut short' do
          searching = service('справка')

          searching.perform[:messages].to_a

          expect(searching).not_to be_messages_partial
        end
      end

      describe 'a latin text' do
        let!(:wizards) { message('wizards study together') }
        let!(:kaspi) { message('Pay with Kaspi.kz please') }

        it 'finds a part of a word of 4 or more characters' do
          expect(found_ids('kaspi')).to eq([kaspi.id])
          expect(found_ids('wizard')).to eq([wizards.id])
        end
      end
    end
  end

  describe 'the full-text index (search_with_gin) and a short text' do
    before { enable_gin(true) }

    it 'keeps the English whole-word matching for Latin text of 1-3 characters: "the" does not find "together"' do
      message('wizards study together')

      expect(found_ids('the')).to be_empty
    end

    it 'finds a whole word of 1-2 Cyrillic letters, which has no literal search' do
      ok = message('ок, договорились')
      message('окно открыто')

      expect(found_ids('ок')).to eq([ok.id])
    end
  end

  describe 'the plain search (search_with_gin disabled) and a short text' do
    before { enable_gin(false) }

    it 'does not search for 1 or 2 characters, which would match nearly every message' do
      message('ок, договорились')

      expect(found_ids('ок')).to be_empty
    end
  end

  describe 'who may find what' do
    let(:hidden_contact) { create(:contact, account: account, name: 'Скрытый Петров', phone_number: '+77015550000') }
    # in an inbox of the agent, but unassigned and without the agent taking part: not for a custom role that has only
    # conversation_participating_manage
    let!(:hidden) { create(:conversation, account: account, inbox: inbox, contact: hidden_contact) }
    let!(:visible) { create(:conversation, account: account, inbox: inbox, contact: create(:contact, account: account), assignee: user) }
    let!(:hidden_message) { message('Секретная справка про диагноз', conversation: hidden) }
    let!(:visible_message) { message('Нужная справка для вас', conversation: visible) }

    before do
      custom_role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
      user.account_users.find_by(account: account).update!(custom_role: custom_role)
    end

    [true, false].each do |gin|
      it "returns no message of a conversation the custom role cannot open (search_with_gin #{gin})" do
        enable_gin(gin)

        aggregate_failures do
          expect(found_ids('справка')).to eq([visible_message.id])
          expect(found_ids('секретная')).to be_empty
          expect(found_ids('диагноз')).to be_empty
        end
      end
    end

    it 'returns no conversation the custom role cannot open: not by the text of a message, nor by contact name, phone or number' do
      aggregate_failures do
        expect(service('справка', 'Conversation').perform[:conversations].map(&:id)).to eq([visible.id])
        expect(service('секретная', 'Conversation').perform[:conversations].map(&:id)).to be_empty
        expect(service('Скрытый', 'Conversation').perform[:conversations].map(&:id)).to be_empty
        expect(service('8 701 555 00 00', 'Conversation').perform[:conversations].map(&:id)).to be_empty
        expect(service(hidden.display_id.to_s, 'Conversation').perform[:conversations].map(&:id)).not_to include(hidden.id)
      end
    end

    it 'returns the same in the global search of all tabs' do
      result = service('справка', 'all').perform

      expect(result[:messages].map(&:id)).to eq([visible_message.id])
      expect(result[:conversations].map(&:id)).to eq([visible.id])
    end

    it 'leaves the whole inbox to a user without a custom role' do
      user.account_users.find_by(account: account).update!(custom_role: nil)

      expect(found_ids('справка')).to contain_exactly(visible_message.id, hidden_message.id)
      expect(service('справка', 'Conversation').perform[:conversations].map(&:id)).to contain_exactly(visible.id, hidden.id)
    end
  end

  describe 'the conversations tab and the text of messages' do
    let!(:contact) { create(:contact, account: account, name: 'Мария', phone_number: '+77011234567') }
    let!(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }

    it 'finds the conversation by the text of its messages exactly as typed' do
      message('Хотите записаться на приём?', conversation: conversation)

      aggregate_failures do
        expect(service('записаться', 'Conversation').perform[:conversations].map(&:id)).to eq([conversation.id])
        expect(service('записали', 'Conversation').perform[:conversations].map(&:id)).to be_empty
        expect(service('на прием', 'Conversation').perform[:conversations].map(&:id)).to eq([conversation.id])
      end
    end

    it 'does not search the text of messages for 1-2 characters' do
      message('ок', conversation: conversation)

      expect(service('ок', 'Conversation').perform[:conversations].map(&:id)).to be_empty
    end
  end
end
