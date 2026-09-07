require 'rails_helper'

describe ConversationFinder do
  subject(:conversation_finder) { described_class.new(user_1, params) }

  let!(:account) { create(:account) }
  let!(:user_1) { create(:user, account: account) }
  let!(:user_2) { create(:user, account: account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:contact_inbox) { create(:contact_inbox, inbox: inbox, source_id: 'testing_source_id') }
  let!(:restricted_inbox) { create(:inbox, account: account) }

  before do
    create(:inbox_member, user: user_1, inbox: inbox)
    create(:inbox_member, user: user_2, inbox: inbox)
    create(:conversation, account: account, inbox: inbox, assignee: user_1)
    create(:conversation, account: account, inbox: inbox, assignee: user_1)
    create(:conversation, account: account, inbox: inbox, assignee: user_1, status: 'resolved')
    create(:conversation, account: account, inbox: inbox, assignee: user_2, contact_inbox: contact_inbox)
    # unassigned conversation
    create(:conversation, account: account, inbox: inbox)
    Current.account = account
  end

  describe '#perform' do
    context 'with status' do
      let(:params) { { status: 'open', assignee_type: 'me' } }

      it 'filter conversations by status' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 2
      end
    end

    context 'with inbox' do
      let!(:restricted_conversation) { create(:conversation, account: account, inbox_id: restricted_inbox.id) }

      it 'returns conversation from any inbox if its admin' do
        params = { inbox_id: restricted_inbox.id }
        result = described_class.new(admin, params).perform

        expect(result[:conversations].map(&:id)).to include(restricted_conversation.id)
      end

      it 'returns conversation from inbox if agent is its member' do
        params = { inbox_id: restricted_inbox.id }
        create(:inbox_member, user: user_1, inbox: restricted_inbox)
        result = described_class.new(user_1, params).perform

        expect(result[:conversations].map(&:id)).to include(restricted_conversation.id)
      end

      it 'returns conversations from account inboxes where agent is not a member' do
        params = { inbox_id: restricted_inbox.id }
        result = described_class.new(user_1, params).perform

        expect(result[:conversations].map(&:id)).to include(restricted_conversation.id)
      end

      it 'keeps Voice conversations readable without inbox membership' do
        voice_inbox = create(:channel_voice, :sipuni, account: account).inbox
        voice_conversation = create(:conversation, account: account, inbox: voice_inbox)
        params = { inbox_id: voice_inbox.id, status: 'all' }

        expect(described_class.new(user_1, params).perform[:conversations]).to include(voice_conversation)
      end

      it 'returns only the conversations from the inbox if inbox_id filter is passed' do
        conversation = create(:conversation, account: account, inbox_id: inbox.id)
        params = { inbox_id: restricted_inbox.id }
        result = described_class.new(admin, params).perform

        conversation_ids = result[:conversations].map(&:id)
        expect(conversation_ids).not_to include(conversation.id)
        expect(conversation_ids).to include(restricted_conversation.id)
      end
    end

    context 'with assignee_type all' do
      let(:params) { { assignee_type: 'all' } }

      it 'filter conversations by assignee type all' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 4
      end
    end

    context 'with assignee_type unassigned' do
      let(:params) { { assignee_type: 'unassigned' } }

      it 'filter conversations by assignee type unassigned' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
      end
    end

    context 'with status all' do
      let(:params) { { status: 'all' } }

      it 'returns all conversations' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 5
      end
    end

    context 'with unread filter' do
      let(:params) { { status: 'all', assignee_type: 'all', unread: 'true' } }

      it 'returns only conversations with unread incoming public messages' do
        unread_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          agent_last_seen_at: 1.hour.ago
        )
        read_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          agent_last_seen_at: 5.minutes.ago
        )
        private_message_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          agent_last_seen_at: 1.hour.ago
        )
        outgoing_message_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          agent_last_seen_at: 1.hour.ago
        )

        create(:message, account: account, conversation: unread_conversation, created_at: 10.minutes.ago)
        create(:message, account: account, conversation: read_conversation, created_at: 10.minutes.ago)
        create(
          :message,
          account: account,
          conversation: private_message_conversation,
          private: true,
          created_at: 10.minutes.ago
        )
        create(
          :message,
          account: account,
          conversation: outgoing_message_conversation,
          message_type: :outgoing,
          created_at: 10.minutes.ago
        )

        result = conversation_finder.perform

        expect(result[:conversations].map(&:id)).to contain_exactly(unread_conversation.id)
      end

      it 'intersects unread with status, assignee, inbox, team, label, CRM, and appointment filters' do
        team = create(:team, account: account)
        other_team = create(:team, account: account)
        pipeline = create(:crm_pipeline, account: account)
        stage = create(:crm_stage, account: account, pipeline: pipeline)
        other_stage = create(:crm_stage, account: account, pipeline: pipeline)
        matching_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          assignee: user_1,
          team: team,
          status: 'pending',
          agent_last_seen_at: 1.hour.ago
        )
        read_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          assignee: user_1,
          team: team,
          status: 'pending',
          agent_last_seen_at: 5.minutes.ago
        )
        wrong_team_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          assignee: user_1,
          team: other_team,
          status: 'pending',
          agent_last_seen_at: 1.hour.ago
        )
        wrong_label_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          assignee: user_1,
          team: team,
          status: 'pending',
          agent_last_seen_at: 1.hour.ago
        )
        wrong_stage_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          assignee: user_1,
          team: team,
          status: 'pending',
          agent_last_seen_at: 1.hour.ago
        )
        wrong_appointment_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          assignee: user_1,
          team: team,
          status: 'pending',
          agent_last_seen_at: 1.hour.ago
        )

        [
          matching_conversation,
          read_conversation,
          wrong_team_conversation,
          wrong_label_conversation,
          wrong_stage_conversation,
          wrong_appointment_conversation
        ].each do |conversation|
          create(:message, account: account, conversation: conversation, created_at: 10.minutes.ago)
        end

        matching_conversation.update!(status: 'pending', assignee: user_1, team: team)
        read_conversation.update!(status: 'pending', assignee: user_1, team: team)
        wrong_team_conversation.update!(status: 'pending', assignee: user_1, team: other_team)
        wrong_label_conversation.update!(status: 'pending', assignee: user_1, team: team)
        wrong_stage_conversation.update!(status: 'pending', assignee: user_1, team: team)
        wrong_appointment_conversation.update!(status: 'pending', assignee: user_1, team: team)

        [matching_conversation, read_conversation, wrong_team_conversation, wrong_stage_conversation,
         wrong_appointment_conversation].each { |conversation| conversation.update_labels('vip') }
        wrong_label_conversation.update_labels('other')

        [matching_conversation, read_conversation, wrong_team_conversation, wrong_label_conversation,
         wrong_appointment_conversation].each do |conversation|
          create(:crm_deal, account: account, pipeline: pipeline, stage: stage, originating_conversation: conversation)
        end
        create(:crm_deal, account: account, pipeline: pipeline, stage: other_stage,
                          originating_conversation: wrong_stage_conversation)

        [matching_conversation, read_conversation, wrong_team_conversation, wrong_label_conversation,
         wrong_stage_conversation].each do |conversation|
          create(:scheduling_appointment, account: account, contact: conversation.contact, conversation: conversation,
                                          status: 'confirmed')
        end
        create(:scheduling_appointment, account: account, contact: wrong_appointment_conversation.contact,
                                        conversation: wrong_appointment_conversation, status: 'scheduled')

        result = described_class.new(
          user_1,
          {
            status: 'pending',
            assignee_type: 'me',
            inbox_id: inbox.id,
            team_id: team.id,
            labels: ['vip'],
            crm_pipeline_id: pipeline.id,
            crm_stage_id: stage.id,
            appointment_status: 'confirmed',
            unread: 'true'
          }
        ).perform

        expect(result[:conversations].map(&:id)).to contain_exactly(matching_conversation.id)
      end
    end

    context 'with assignee_type assigned' do
      let(:params) { { assignee_type: 'assigned' } }

      it 'filter conversations by assignee type assigned' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 3
      end

      it 'returns the correct meta' do
        result = conversation_finder.perform
        expect(result[:count]).to include(
          mine_count: 2,
          assigned_count: 3,
          unassigned_count: 1,
          all_count: 4
        )
      end
    end

    context 'with facet counts' do
      let(:params) { { status: 'open', assignee_type: 'me', inbox_id: inbox.id } }

      it 'keeps ownership counts independent from secondary filters and scopes facets by active filters' do
        second_inbox = create(:inbox, account: account, enable_auto_assignment: false)
        create(:inbox_member, user: user_1, inbox: second_inbox)
        create(:conversation, account: account, inbox: second_inbox, assignee: user_1, status: 'open')
        create(:conversation, account: account, inbox: second_inbox, assignee: user_1, status: 'pending')
        Conversation.where(account: account, assignee: user_1).find_each do |conversation|
          status = conversation.status
          conversation.update!(agent_last_seen_at: 1.hour.ago)
          create(:message, account: account, conversation: conversation, created_at: 10.minutes.ago)
          conversation.update!(status: status)
        end

        result = conversation_finder.perform

        expect(result[:count][:assignee_counts]).to include(
          mine_count: 5,
          unassigned_count: 1,
          all_count: 7
        )
        expect(result[:count].dig(:unread_counts, :statuses)).to include(
          'open' => 2,
          'resolved' => 1
        )
        expect(result[:count][:unread_counts]).to include(
          all: 3,
          inboxes: include(inbox.id.to_s => 2, second_inbox.id.to_s => 1)
        )
      end
    end

    context 'with team' do
      let(:team) { create(:team, account: account) }
      let(:params) { { team_id: team.id } }

      it 'filter conversations by team' do
        create(:conversation, account: account, inbox: inbox, team: team)
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
      end
    end

    context 'with any team scope' do
      let(:team) { create(:team, account: account) }
      let(:params) { { team_scope: 'any' } }

      it 'filters conversations to records assigned to a team' do
        conversation = create(:conversation, account: account, inbox: inbox, team: team)

        result = conversation_finder.perform

        expect(result[:conversations].map(&:id)).to contain_exactly(conversation.id)
      end
    end

    context 'with labels' do
      let(:params) { { labels: ['resolved'] } }

      it 'filter conversations by labels' do
        conversation = inbox.conversations.first
        conversation.update_labels('resolved')

        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
      end
    end

    context 'with any label scope' do
      let(:params) { { labels_scope: 'any' } }

      it 'filters conversations to records that have at least one label' do
        conversation = inbox.conversations.first
        conversation.update_labels('vip')

        result = conversation_finder.perform

        expect(result[:conversations].map(&:id)).to contain_exactly(conversation.id)
      end
    end

    context 'with CRM deal context' do
      let(:pipeline) { create(:crm_pipeline, account: account) }
      let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
      let(:other_stage) { create(:crm_stage, account: account, pipeline: pipeline) }
      let(:other_pipeline) { create(:crm_pipeline, account: account) }
      let(:other_pipeline_stage) { create(:crm_stage, account: account, pipeline: other_pipeline) }
      let(:params) { { status: 'open', assignee_type: 'all', crm_pipeline_id: pipeline.id } }

      it 'filters conversations by deal pipeline through deal contacts and originating conversations' do
        deal_contact = create(:contact, account: account)
        contact_conversation = create(:conversation, account: account, inbox: inbox, contact: deal_contact)
        direct_conversation = create(:conversation, account: account, inbox: inbox)
        other_conversation = create(:conversation, account: account, inbox: inbox)

        deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
        create(:crm_deal_contact, account: account, deal: deal, contact: deal_contact)
        create(:crm_deal, account: account, pipeline: pipeline, stage: stage, originating_conversation: direct_conversation)
        create(:crm_deal, account: account, pipeline: other_pipeline, stage: other_pipeline_stage,
                          originating_conversation: other_conversation)

        result = conversation_finder.perform

        expect(result[:conversations].map(&:id)).to contain_exactly(contact_conversation.id, direct_conversation.id)
      end

      it 'filters conversations by deal stage and returns pipeline and stage unread counts' do
        matching_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          agent_last_seen_at: 1.hour.ago
        )
        other_stage_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          agent_last_seen_at: 1.hour.ago
        )
        create(:message, account: account, conversation: matching_conversation, created_at: 10.minutes.ago)
        create(:message, account: account, conversation: other_stage_conversation, created_at: 10.minutes.ago)
        create(:crm_deal, account: account, pipeline: pipeline, stage: stage, originating_conversation: matching_conversation)
        create(:crm_deal, account: account, pipeline: pipeline, stage: other_stage,
                          originating_conversation: other_stage_conversation)

        stage_result = described_class.new(
          user_1,
          { status: 'open', assignee_type: 'all', crm_pipeline_id: pipeline.id, crm_stage_id: stage.id }
        ).perform

        expect(stage_result[:conversations].map(&:id)).to contain_exactly(matching_conversation.id)
        expect(stage_result[:count].dig(:unread_counts, :pipelines)).to include(pipeline.id.to_s => 2)
        expect(stage_result[:count].dig(:unread_counts, :stages)).to include(
          stage.id.to_s => 1,
          other_stage.id.to_s => 1
        )
      end
    end

    context 'with scheduling appointment context' do
      let(:params) { { status: 'open', assignee_type: 'all', appointment_status: 'confirmed' } }

      it 'filters conversations by appointment status through contacts and direct conversation links' do
        appointment_contact = create(:contact, account: account)
        contact_conversation = create(:conversation, account: account, inbox: inbox, contact: appointment_contact)
        direct_conversation = create(:conversation, account: account, inbox: inbox)
        other_conversation = create(:conversation, account: account, inbox: inbox)

        create(:scheduling_appointment, account: account, contact: appointment_contact, status: 'confirmed')
        create(
          :scheduling_appointment,
          account: account,
          contact: direct_conversation.contact,
          conversation: direct_conversation,
          status: 'confirmed'
        )
        create(
          :scheduling_appointment,
          account: account,
          contact: other_conversation.contact,
          conversation: other_conversation,
          status: 'scheduled'
        )

        result = conversation_finder.perform

        expect(result[:conversations].map(&:id)).to contain_exactly(contact_conversation.id, direct_conversation.id)
      end

      it 'filters conversations with any appointment when appointment status is any' do
        confirmed_conversation = create(:conversation, account: account, inbox: inbox)
        scheduled_conversation = create(:conversation, account: account, inbox: inbox)
        no_appointment_conversation = create(:conversation, account: account, inbox: inbox)

        create(
          :scheduling_appointment,
          account: account,
          contact: confirmed_conversation.contact,
          conversation: confirmed_conversation,
          status: 'confirmed'
        )
        create(
          :scheduling_appointment,
          account: account,
          contact: scheduled_conversation.contact,
          conversation: scheduled_conversation,
          status: 'scheduled'
        )

        result = described_class.new(user_1, params.merge(appointment_status: 'any')).perform

        expect(result[:conversations].map(&:id)).to contain_exactly(confirmed_conversation.id, scheduled_conversation.id)
        expect(result[:conversations].map(&:id)).not_to include(no_appointment_conversation.id)
      end

      it 'keeps appointment status counts as dialog counts scoped by dialog context' do
        confirmed_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          agent_last_seen_at: 1.hour.ago
        )
        scheduled_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          agent_last_seen_at: 1.hour.ago
        )
        read_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          agent_last_seen_at: 5.minutes.ago
        )
        create(:message, account: account, conversation: confirmed_conversation, created_at: 10.minutes.ago)
        create(:message, account: account, conversation: scheduled_conversation, created_at: 10.minutes.ago)
        create(:message, account: account, conversation: read_conversation, created_at: 10.minutes.ago)
        create(
          :scheduling_appointment,
          account: account,
          contact: confirmed_conversation.contact,
          conversation: confirmed_conversation,
          status: 'confirmed'
        )
        create(
          :scheduling_appointment,
          account: account,
          contact: confirmed_conversation.contact,
          conversation: confirmed_conversation,
          status: 'confirmed'
        )
        create(
          :scheduling_appointment,
          account: account,
          contact: scheduled_conversation.contact,
          conversation: scheduled_conversation,
          status: 'scheduled'
        )
        create(
          :scheduling_appointment,
          account: account,
          contact: read_conversation.contact,
          conversation: read_conversation,
          status: 'confirmed'
        )
        create(:scheduling_appointment, account: account, status: 'confirmed')

        result = conversation_finder.perform

        expect(result[:count].dig(:unread_counts, :appointment_statuses)).to include(
          'any' => 2,
          'confirmed' => 1,
          'scheduled' => 1
        )
      end
    end

    context 'with source_id' do
      let(:params) { { source_id: 'testing_source_id' } }

      it 'filter conversations by source id' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 1
      end
    end

    context 'without source' do
      let(:params) { {} }

      it 'returns conversations with any source' do
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 4
      end
    end

    context 'with message and event activity sort options' do
      let(:params) { { status: 'open', assignee_type: 'all' } }

      it 'sorts by public non-activity messages by default and keeps event activity as an explicit legacy option' do
        base_time = Time.zone.now
        Conversation.where(account: account).find_each do |conversation|
          conversation.update!(created_at: base_time - 10.days, last_activity_at: base_time - 10.days)
        end

        event_activity_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          created_at: base_time - 3.days,
          last_activity_at: base_time - 3.days
        )
        latest_message_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          created_at: base_time - 4.days,
          last_activity_at: base_time - 4.days
        )

        create(:message, conversation: event_activity_conversation, message_type: :incoming, created_at: base_time - 2.days)
        create(:message, conversation: event_activity_conversation, message_type: :activity, created_at: base_time)
        create(:message, conversation: latest_message_conversation, message_type: :incoming, created_at: base_time - 1.hour)

        default_result = conversation_finder.perform
        legacy_result = described_class.new(user_1, params.merge(sort_by: 'last_event_activity_at_desc')).perform

        expect(default_result[:conversations].first.id).to eq(latest_message_conversation.id)
        expect(legacy_result[:conversations].first.id).to eq(event_activity_conversation.id)
      end
    end

    context 'with updated_within' do
      let(:params) { { updated_within: 20, assignee_type: 'unassigned', sort_by: 'created_at_asc' } }

      it 'filters based on params, sort order but returns all conversations without pagination with in time range' do
        # value of updated_within is in seconds
        # write spec based on that
        existing_unassigned_ids = account.conversations.where(assignee_id: nil).pluck(:id)
        conversations = create_list(:conversation, 50, account: account,
                                                       inbox: inbox, assignee: nil,
                                                       updated_at: Time.now.utc - 30.seconds,
                                                       created_at: Time.now.utc - 30.seconds)
        # Refresh 28 conversations inside the 20-second window with deterministic sort timestamps.
        refreshed_at = Time.current
        account.conversations
               .where(id: existing_unassigned_ids)
               .update_all(updated_at: refreshed_at - 10.seconds)
        conversations.first(28).each_with_index do |conversation, index|
          conversation.update_columns(
            updated_at: refreshed_at - 10.seconds,
            created_at: refreshed_at - 30.seconds + index.seconds
          )
        end
        result = conversation_finder.perform
        # pagination is not applied
        # filters are applied
        # Explicitly refreshed conversations and pre-existing recent unassigned conversations are inside the window.
        expect(result[:conversations].map(&:id)).to contain_exactly(
          *existing_unassigned_ids,
          *conversations.first(28).map(&:id)
        )
        # ensure that the conversations are sorted by created_at
        expect(result[:conversations].first.created_at).to be < result[:conversations].last.created_at
      end
    end

    context 'with participating conversation type' do
      let(:params) { { status: 'all', assignee_type: 'all', conversation_type: 'participating' } }
      let!(:participating_conversation) { create(:conversation, account: account, inbox: inbox) }
      let(:custom_role) { create(:custom_role, account: account, permissions: ['crm_deal_view']) }

      before do
        account.account_users.find_by!(user: user_1).update!(role: :agent, custom_role: custom_role)
        create(:conversation_participant, account: account, conversation: participating_conversation, user: user_1)
      end

      it 'does not bypass a custom role without conversation permissions' do
        result = conversation_finder.perform

        expect(result[:conversations]).to be_empty
      end

      it 'uses the same authorized scope for meta counts' do
        result = conversation_finder.perform_meta_only

        expect(result[:count][:all_count]).to eq(0)
      end

      it 'returns participating conversations when the custom role permits them' do
        custom_role.update!(permissions: ['conversation_participating_manage'])

        result = conversation_finder.perform

        expect(result[:conversations].map(&:id)).to include(participating_conversation.id)
      end
    end

    context 'with pagination' do
      let(:params) { { status: 'open', assignee_type: 'me', page: 1 } }

      it 'returns paginated conversations' do
        create_list(:conversation, 50, account: account, inbox: inbox, assignee: user_1)
        result = conversation_finder.perform
        expect(result[:conversations].length).to be 25
      end
    end

    context 'with perform_meta_only' do
      let(:params) { { assignee_type: 'assigned' } }

      it 'returns only count without conversations' do
        result = conversation_finder.perform_meta_only
        expect(result).to have_key(:count)
        expect(result).not_to have_key(:conversations)
      end

      it 'returns the correct counts' do
        result = conversation_finder.perform_meta_only
        expect(result[:count]).to include(
          mine_count: 2,
          assigned_count: 3,
          unassigned_count: 1,
          all_count: 4
        )
      end

      it 'returns same counts as perform' do
        meta_result = conversation_finder.perform_meta_only
        full_result = conversation_finder.perform
        expect(meta_result[:count]).to eq(full_result[:count])
      end
    end

    context 'with participating conversation counts' do
      let(:params) { { conversation_type: 'participating', status: 'all', assignee_type: 'all' } }

      it 'keeps an unassigned Voice participant in account-readable payload and count scopes' do
        voice_inbox = create(:channel_voice, :sipuni, account: account).inbox
        voice_conversation = create(:conversation, account: account, inbox: voice_inbox)
        voice_membership = create(:inbox_member, inbox: voice_inbox, user: user_1)
        create(:conversation_participant, account: account, conversation: voice_conversation, user: user_1)
        voice_membership.destroy!

        full_result = conversation_finder.perform
        meta_result = conversation_finder.perform_meta_only

        expect(full_result[:conversations]).to include(voice_conversation)
        expect(full_result[:count]).to include(all_count: 1, assigned_count: 0, unassigned_count: 1, mine_count: 0)
        expect(meta_result[:count]).to eq(full_result[:count])
      end

      it 'keeps empty custom-role permissions out of payload and count scopes' do
        participating_conversation = create(:conversation, account: account, inbox: restricted_inbox)
        create(:inbox_member, inbox: restricted_inbox, user: user_1)
        create(:conversation_participant, account: account, conversation: participating_conversation, user: user_1)
        restricted_role = create(:custom_role, account: account, permissions: [])
        account.account_users.find_by!(user: user_1).update!(custom_role: restricted_role)

        full_result = conversation_finder.perform
        meta_result = conversation_finder.perform_meta_only

        expect(full_result[:conversations]).to be_empty
        expect(full_result[:count]).to include(all_count: 0, assigned_count: 0, unassigned_count: 0, mine_count: 0)
        expect(meta_result[:count]).to eq(full_result[:count])
      end
    end

    context 'with unattended' do
      let(:params) { { status: 'open', assignee_type: 'me', conversation_type: 'unattended' } }

      it 'returns unattended conversations' do
        create(:conversation, account: account, first_reply_created_at: Time.now.utc, assignee: user_1) # attended_conversation
        create(:conversation, account: account, first_reply_created_at: nil, assignee: user_1) # unattended_conversation_no_first_reply
        create(:conversation, account: account, first_reply_created_at: Time.now.utc,
                              assignee: user_1, waiting_since: Time.now.utc) # unattended_conversation_waiting_since

        result = conversation_finder.perform
        expect(result[:conversations].length).to eq(5)
      end
    end
  end
end
