require 'rails_helper'

describe SearchService do
  subject(:search) { described_class.new(current_user: user, current_account: account, params: params, search_type: search_type) }

  let(:search_type) { 'all' }
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }
  let!(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:harry) { create(:contact, name: 'Harry Potter', email: 'test@test.com', account_id: account.id) }
  let!(:conversation) { create(:conversation, contact: harry, inbox: inbox, account: account) }
  let!(:message) { create(:message, account: account, inbox: inbox, content: 'Harry Potter is a wizard') }
  let!(:portal) { create(:portal, account: account) }
  let(:article) do
    create(:article, title: 'Harry Potter Magic Guide', content: 'Learn about wizardry', account: account, portal: portal, author: user,
                     status: 'published')
  end

  before do
    create(:inbox_member, user: user, inbox: inbox)
    Current.account = account
  end

  after do
    Current.account = nil
  end

  describe '#perform' do
    context 'when search types' do
      let(:params) { { q: 'Potter' } }

      it 'returns all for all' do
        search_type = 'all'
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: search_type)
        expect(search.perform.keys).to match_array(%i[contacts messages conversations articles])
      end

      it 'returns contacts for contacts' do
        search_type = 'Contact'
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: search_type)
        expect(search.perform.keys).to match_array(%i[contacts])
      end

      it 'returns messages for messages' do
        search_type = 'Message'
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: search_type)
        expect(search.perform.keys).to match_array(%i[messages])
      end

      it 'returns conversations for conversations' do
        search_type = 'Conversation'
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: search_type)
        expect(search.perform.keys).to match_array(%i[conversations])
      end

      it 'returns articles for articles' do
        search_type = 'Article'
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: search_type)
        expect(search.perform.keys).to match_array(%i[articles])
      end
    end

    context 'when contact search' do
      it 'searches across name, email, phone_number and identifier and returns in the order of contact last_activity_at' do
        # random contact
        create(:contact, account_id: account.id)
        # unresolved contact -> no identifying info
        # will not appear in search results
        create(:contact, name: 'Harry Potter', account_id: account.id)
        harry2 = create(:contact, email: 'HarryPotter@test.com', account_id: account.id, last_activity_at: 2.days.ago)
        harry3 = create(:contact, identifier: 'Potter123', account_id: account.id, last_activity_at: 1.day.ago)
        harry4 = create(:contact, identifier: 'Potter1235', account_id: account.id, last_activity_at: 2.minutes.ago)

        params = { q: 'Potter ' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Contact')
        expect(search.perform[:contacts].map(&:id)).to eq([harry4.id, harry3.id, harry2.id, harry.id])
      end

      it 'searches contacts by phone regardless of spaces, plus sign, and 8/+7 prefix' do
        matching_contact = create(:contact, account_id: account.id, phone_number: '+77011234567')
        create(:contact, account_id: account.id, phone_number: '+77777777777')

        aggregate_failures do
          ['+7 701 123 45 67', '7011234567', '8 701 123 45 67'].each do |query|
            params = { q: query }
            search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Contact')
            expect(search.perform[:contacts].map(&:id)).to eq([matching_contact.id]), "expected query #{query.inspect} to find the normalized phone"
          end
        end
      end
    end

    context 'when message search' do
      let!(:message2) { create(:message, account: account, inbox: inbox, content: 'harry is cool') }

      it 'searches across message content and return in created_at desc' do
        # random messages in another account
        create(:message, content: 'Harry Potter is a wizard')
        # random messsage in inbox with out access
        create(:message, account: account, inbox: create(:inbox, account: account), content: 'Harry Potter is a wizard')
        params = { q: 'Harry' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')
        expect(search.perform[:messages].map(&:id)).to eq([message2.id, message.id])
      end

      it 'does not find the technical Captain tool lines' do
        tool_line = create(
          :message,
          message_type: 'activity',
          account: account,
          inbox: inbox,
          content: 'AI Agent completed tool zebralookup',
          source_id: 'captain-tool:search-1',
          content_attributes: { data: { type: 'captain_tool_event', event: 'completed' } }
        )
        assignment = create(:message, message_type: 'activity', account: account, inbox: inbox,
                                      content: 'Conversation assigned to zebralookup owner')
        params = { q: 'zebralookup' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')

        expect(search.perform[:messages].map(&:id)).to eq([assignment.id])
        expect(search.perform[:messages].map(&:id)).not_to include(tool_line.id)
      end

      context 'with feature flag for search type' do
        let(:params) { { q: 'Harry' } }
        let(:search_type) { 'Message' }

        it 'uses literal SQL under either search feature setting' do
          allow(account).to receive(:feature_enabled?).and_call_original

          [true, false].each do |enabled|
            allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(enabled)
            search_service = described_class.new(current_user: user, current_account: account, params: params, search_type: search_type)
            expect(search_service.perform[:messages].pluck(:id)).to contain_exactly(message.id, message2.id)
          end
        end

        it 'returns same results regardless of search type' do
          # Create test messages
          message3 = create(:message, account: account, inbox: inbox, content: 'Harry is a wizard apprentice')

          # Test with GIN search
          allow(account).to receive(:feature_enabled?).and_call_original
          allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(true)
          gin_search = described_class.new(current_user: user, current_account: account, params: params, search_type: search_type)
          gin_results = gin_search.perform[:messages].map(&:id)

          # Test with LIKE search
          allow(account).to receive(:feature_enabled?).and_call_original
          allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(false)
          like_search = described_class.new(current_user: user, current_account: account, params: params, search_type: search_type)
          like_results = like_search.perform[:messages].map(&:id)

          # Both search types should return the same messages
          expect(gin_results).to match_array(like_results)
          expect(gin_results).to include(message.id, message2.id, message3.id)
        end
      end

      # rubocop:disable RSpec/MultipleMemoizedHelpers
      context 'when filtering messages with time, sender, and inbox', :opensearch do
        let!(:agent) { create(:user, account: account) }
        let!(:inbox2) { create(:inbox, account: account) }
        let!(:old_message) do
          create(:message, account: account, inbox: inbox, content: 'old wizard message', sender: harry, created_at: 80.days.ago)
        end
        let!(:recent_message) do
          create(:message, account: account, inbox: inbox, content: 'recent wizard message', sender: harry, created_at: 1.day.ago)
        end
        let!(:agent_message) do
          create(:message, account: account, inbox: inbox, content: 'wizard from agent', sender: agent, created_at: 1.day.ago)
        end
        let!(:inbox2_message) do
          create(:message, account: account, inbox: inbox2, content: 'wizard in inbox2', sender: harry, created_at: 1.day.ago)
        end

        before do
          account.enable_features!('advanced_search')
          create(:inbox_member, inbox: inbox2, user: user)
        end

        it 'filters messages by time range with LIKE search' do
          allow(ChatwootApp).to receive(:advanced_search_allowed?).and_return(false)
          allow(account).to receive(:feature_enabled?).and_call_original
          allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(false)
          allow(account).to receive(:feature_enabled?).with('advanced_search').and_return(true)
          params = { q: 'wizard', since: 50.days.ago.to_i, search_type: 'Message' }
          search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')
          results = search.perform[:messages]

          expect(results.map(&:id)).to include(recent_message.id, agent_message.id, inbox2_message.id)
          expect(results.map(&:id)).not_to include(old_message.id)
        end

        it 'filters messages by time range with GIN search' do
          allow(ChatwootApp).to receive(:advanced_search_allowed?).and_return(false)
          allow(account).to receive(:feature_enabled?).and_call_original
          allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(true)
          allow(account).to receive(:feature_enabled?).with('advanced_search').and_return(true)
          params = { q: 'wizard', since: 50.days.ago.to_i, search_type: 'Message' }
          search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')
          results = search.perform[:messages]

          expect(results.map(&:id)).to include(recent_message.id, agent_message.id, inbox2_message.id)
          expect(results.map(&:id)).not_to include(old_message.id)
        end

        it 'filters messages by sender (contact)' do
          allow(ChatwootApp).to receive(:advanced_search_allowed?).and_return(false)
          allow(account).to receive(:feature_enabled?).and_call_original
          allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(false)
          allow(account).to receive(:feature_enabled?).with('advanced_search').and_return(true)
          params = { q: 'wizard', from: "contact:#{harry.id}", search_type: 'Message' }
          search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')
          results = search.perform[:messages]

          expect(results.map(&:id)).to include(recent_message.id, old_message.id, inbox2_message.id)
          expect(results.map(&:id)).not_to include(agent_message.id)
        end

        it 'filters messages by sender (agent)' do
          allow(ChatwootApp).to receive(:advanced_search_allowed?).and_return(false)
          allow(account).to receive(:feature_enabled?).and_call_original
          allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(false)
          allow(account).to receive(:feature_enabled?).with('advanced_search').and_return(true)
          params = { q: 'wizard', from: "agent:#{agent.id}", search_type: 'Message' }
          search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')
          results = search.perform[:messages]

          expect(results.map(&:id)).to include(agent_message.id)
          expect(results.map(&:id)).not_to include(recent_message.id, old_message.id, inbox2_message.id)
        end

        it 'filters messages by inbox' do
          allow(ChatwootApp).to receive(:advanced_search_allowed?).and_return(false)
          allow(account).to receive(:feature_enabled?).and_call_original
          allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(false)
          allow(account).to receive(:feature_enabled?).with('advanced_search').and_return(true)
          params = { q: 'wizard', inbox_id: inbox2.id, search_type: 'Message' }
          search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')
          results = search.perform[:messages]

          expect(results.map(&:id)).to include(inbox2_message.id)
          expect(results.map(&:id)).not_to include(recent_message.id, old_message.id, agent_message.id)
        end

        it 'combines multiple filters' do
          allow(ChatwootApp).to receive(:advanced_search_allowed?).and_return(false)
          allow(account).to receive(:feature_enabled?).and_call_original
          allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(false)
          allow(account).to receive(:feature_enabled?).with('advanced_search').and_return(true)
          params = { q: 'wizard', since: 50.days.ago.to_i, inbox_id: inbox.id, from: "contact:#{harry.id}", search_type: 'Message' }
          search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Message')
          results = search.perform[:messages]

          expect(results.map(&:id)).to include(recent_message.id)
          expect(results.map(&:id)).not_to include(old_message.id, agent_message.id, inbox2_message.id)
        end
      end
      # rubocop:enable RSpec/MultipleMemoizedHelpers
    end

    context 'when conversation search' do
      it 'searches across conversations using contact information and order by created_at desc' do
        # random messages in another inbox
        random = create(:contact, account_id: account.id)
        create(:conversation, contact: random, inbox: inbox, account: account)
        conv2 = create(:conversation, contact: harry, inbox: inbox, account: account)
        params = { q: 'test@test.com' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Conversation')
        expect(search.perform[:conversations].map(&:id)).to eq([conv2.id, conversation.id])
      end

      it 'searches across conversations with display id' do
        random = create(:contact, account_id: account.id, name: 'random', email: 'random@random.test', identifier: 'random')
        new_converstion = create(:conversation, contact: random, inbox: inbox, account: account)
        params = { q: new_converstion.display_id }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Conversation')
        expect(search.perform[:conversations].map(&:id)).to include new_converstion.id
      end

      it 'searches conversations by message content without duplicating conversations' do
        matching_contact = create(:contact, account_id: account.id, name: 'Message Match')
        matching_conversation = create(:conversation, contact: matching_contact, inbox: inbox, account: account)
        create(:message, conversation: matching_conversation, account: account, inbox: inbox, content: 'needle text in first message')
        create(:message, conversation: matching_conversation, account: account, inbox: inbox, content: 'needle text in second message')
        create(:conversation, contact: create(:contact, account_id: account.id, name: 'No Match'), inbox: inbox, account: account)

        params = { q: 'needle text' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Conversation')

        expect(search.perform[:conversations].map(&:id)).to eq([matching_conversation.id])
      end

      it 'does not match a conversation only by its Captain tool lines' do
        tool_only = create(:conversation, contact: create(:contact, account_id: account.id, name: 'Tool Only'), inbox: inbox, account: account)
        create(
          :message,
          message_type: 'activity',
          conversation: tool_only,
          account: account,
          inbox: inbox,
          content: 'AI Agent completed tool zebralookup',
          source_id: 'captain-tool:zebra-1',
          content_attributes: { data: { type: 'captain_tool_event', event: 'completed' } }
        )
        typed = create(:conversation, contact: create(:contact, account_id: account.id, name: 'Typed'), inbox: inbox, account: account)
        create(:message, conversation: typed, account: account, inbox: inbox, content: 'please run zebralookup')

        params = { q: 'zebralookup' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Conversation')

        expect(search.perform[:conversations].map(&:id)).to eq([typed.id])
      end

      it 'keeps message-content conversation search account and inbox scoped' do
        inaccessible_inbox = create(:inbox, account: account)
        inaccessible_conversation = create(
          :conversation,
          contact: create(:contact, account_id: account.id),
          inbox: inaccessible_inbox,
          account: account
        )
        other_account = create(:account)
        other_inbox = create(:inbox, account: other_account)
        other_conversation = create(
          :conversation,
          contact: create(:contact, account_id: other_account.id),
          inbox: other_inbox,
          account: other_account
        )

        create(:message, conversation: inaccessible_conversation, account: account, inbox: inaccessible_inbox, content: 'scoped secret phrase')
        create(:message, conversation: other_conversation, account: other_account, inbox: other_inbox, content: 'scoped secret phrase')

        params = { q: 'scoped secret phrase' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Conversation')

        expect(search.perform[:conversations]).to be_empty
      end

      it 'searches conversations by phone when the query uses 8 instead of +7' do
        matching_contact = create(:contact, account_id: account.id, phone_number: '+77011234567')
        matching_conversation = create(:conversation, contact: matching_contact, inbox: inbox, account: account)
        create(:conversation, contact: create(:contact, account_id: account.id, phone_number: '+77777777777'), inbox: inbox, account: account)

        params = { q: '8 701 123 45 67' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Conversation')

        expect(search.perform[:conversations].map(&:id)).to eq([matching_conversation.id])
      end
    end

    context 'when article search' do
      it 'returns matching articles' do
        article2 = create(:article, title: 'Spellcasting Guide',
                                    account: account, portal: portal, author: user, status: 'published')
        article3 = create(:article, title: 'Spellcasting Manual',
                                    account: account, portal: portal, author: user, status: 'published')

        params = { q: 'Spellcasting' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Article')
        results = search.perform[:articles]

        expect(results.length).to eq(2)
        expect(results.map(&:id)).to contain_exactly(article2.id, article3.id)
      end

      it 'returns paginated results' do
        # Create many articles to test pagination
        16.times do |i|
          create(:article, title: "Magic Article #{i}", account: account, portal: portal, author: user, status: 'published')
        end

        params = { q: 'Magic', page: 1 }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Article')
        results = search.perform[:articles]

        expect(results.length).to eq(15) # Default per_page is 15
      end
    end

    context 'when filtering contacts with time caps', :opensearch do
      let!(:old_contact) { create(:contact, name: 'Old Potter', email: 'old@test.com', account: account, last_activity_at: 100.days.ago) }
      let!(:recent_contact) { create(:contact, name: 'Recent Potter', email: 'recent@test.com', account: account, last_activity_at: 1.day.ago) }

      before do
        account.enable_features!('advanced_search')
      end

      it 'caps since to 90 days ago and excludes older contacts' do
        params = { q: 'Potter', since: 100.days.ago.to_i, search_type: 'Contact' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Contact')
        results = search.perform[:contacts]

        expect(results.map(&:id)).not_to include(old_contact.id)
        expect(results.map(&:id)).to include(recent_contact.id)
      end

      it 'caps until to 90 days from now' do
        params = { q: 'Potter', until: 100.days.from_now.to_i, search_type: 'Contact' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Contact')
        results = search.perform[:contacts]

        # Both contacts should be included since their last_activity_at is before the capped time
        expect(results.map(&:id)).to include(recent_contact.id)
      end
    end

    context 'when filtering conversations with time caps', :opensearch do
      let!(:old_conversation) { create(:conversation, contact: harry, inbox: inbox, account: account, last_activity_at: 100.days.ago) }
      let!(:recent_conversation) { create(:conversation, contact: harry, inbox: inbox, account: account, last_activity_at: 1.day.ago) }

      before do
        account.enable_features!('advanced_search')
      end

      it 'caps since to 90 days ago and excludes older conversations' do
        params = { q: 'Harry', since: 100.days.ago.to_i, search_type: 'Conversation' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Conversation')
        results = search.perform[:conversations]

        expect(results.map(&:id)).not_to include(old_conversation.id)
        expect(results.map(&:id)).to include(recent_conversation.id)
      end

      it 'caps until to 90 days from now' do
        params = { q: 'Harry', until: 100.days.from_now.to_i, search_type: 'Conversation' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Conversation')
        results = search.perform[:conversations]

        # Both conversations should be included since their last_activity_at is before the capped time
        expect(results.map(&:id)).to include(recent_conversation.id)
      end
    end

    context 'when filtering articles with time caps', :opensearch do
      let!(:old_article) do
        create(:article, title: 'Old Magic Guide', account: account, portal: portal, author: user, status: 'published', updated_at: 100.days.ago)
      end
      let!(:recent_article) do
        create(:article, title: 'Recent Magic Guide', account: account, portal: portal, author: user, status: 'published', updated_at: 1.day.ago)
      end

      before do
        account.enable_features!('advanced_search')
      end

      it 'caps since to 90 days ago and excludes older articles' do
        params = { q: 'Magic', since: 100.days.ago.to_i, search_type: 'Article' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Article')
        results = search.perform[:articles]

        expect(results.map(&:id)).not_to include(old_article.id)
        expect(results.map(&:id)).to include(recent_article.id)
      end

      it 'caps until to 90 days from now' do
        params = { q: 'Magic', until: 100.days.from_now.to_i, search_type: 'Article' }
        search = described_class.new(current_user: user, current_account: account, params: params, search_type: 'Article')
        results = search.perform[:articles]

        # Both articles should be included since their updated_at is before the capped time
        expect(results.map(&:id)).to include(recent_article.id)
      end
    end
  end

  describe '#message_base_query' do
    let(:params) { { q: 'test' } }
    let(:search_type) { 'Message' }

    context 'when user is admin' do
      let(:admin_user) { create(:user) }
      let(:admin_search) do
        create(:account_user, account: account, user: admin_user, role: 'administrator')
        described_class.new(current_user: admin_user, current_account: account, params: params, search_type: search_type)
      end

      it 'does not filter by inbox_id' do
        # Testing the private method itself seems like the best way to ensure
        # that the inboxes are not added to the search query
        base_query = admin_search.send(:message_base_query)

        # Should only have the time filter, not inbox filter
        expect(base_query.to_sql).to include('created_at >= ')
        expect(base_query.to_sql).not_to include('inbox_id')
      end
    end

    context 'when user is not admin' do
      before do
        account_user = account.account_users.find_or_create_by(user: user)
        account_user.update!(role: 'agent')
      end

      it 'filters by accessible inbox_id when user has limited access' do
        # Create an additional inbox that user is NOT assigned to
        create(:inbox, account: account)

        base_query = search.send(:message_base_query)

        # Should have both time and inbox filters
        expect(base_query.to_sql).to include('created_at >= ')
        expect(base_query.to_sql).to include('inbox_id')
      end

      context 'when user has access to all inboxes' do
        before do
          # Create additional inbox and assign user to all inboxes
          other_inbox = create(:inbox, account: account)
          create(:inbox_member, user: user, inbox: other_inbox)
        end

        it 'skips inbox filtering as optimization' do
          base_query = search.send(:message_base_query)

          # Should only have the time filter, not inbox filter
          expect(base_query.to_sql).to include('created_at >= ')
          expect(base_query.to_sql).not_to include('inbox_id')
        end
      end
    end
  end

  describe 'literal message search with advanced features enabled' do
    let(:search_type) { 'Message' }
    let(:contact) { create(:contact, account: account) }
    let!(:from_contact) do
      create(:message, account: account, inbox: inbox, sender: contact, content: 'Нужна справка', created_at: 1.day.ago)
    end
    let!(:from_agent) do
      create(:message, account: account, inbox: inbox, sender: user, content: 'Другая справка', created_at: 5.days.ago)
    end

    before do
      allow(account).to receive(:feature_enabled?).and_call_original
      allow(account).to receive(:feature_enabled?).with('advanced_search').and_return(true)
      allow(account).to receive(:feature_enabled?).with('search_with_gin').and_return(true)
      allow(ChatwootApp).to receive(:advanced_search_allowed?).and_return(true)
    end

    it 'uses SQL and keeps the sender and time filters without consulting Searchkick' do
      expect(Message).not_to receive(:search)
      params = { q: 'справка', from: "contact:#{contact.id}", since: 2.days.ago.to_i }
      service = described_class.new(current_user: user, current_account: account, params: params, search_type: search_type)

      expect(service.perform[:messages].pluck(:id)).to eq([from_contact.id])
    end

    it 'does not match a different word form under the GIN feature flag' do
      params = { q: 'справку' }
      service = described_class.new(current_user: user, current_account: account, params: params, search_type: search_type)

      expect(service.perform[:messages].pluck(:id)).to be_empty
    end

    it 'limits an explicitly selected inbox to one the user can open' do
      foreign_inbox = create(:inbox, account: account)
      params = { q: 'справка', inbox_id: foreign_inbox.id }
      service = described_class.new(current_user: user, current_account: account, params: params, search_type: search_type)

      expect(service.perform[:messages].pluck(:id)).to contain_exactly(from_contact.id, from_agent.id)
    end
  end
end
