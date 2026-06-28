# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreadFinder do
  subject(:finder) { described_class.new(user, params) }

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let(:params) { { status: 'open', assignee_type: 'all', appointment_status: 'confirmed' } }

  before do
    create(:inbox_member, user: user, inbox: inbox)
    Current.account = account
  end

  describe '#perform' do
    context 'with unread filter' do
      let(:params) { { status: 'all', assignee_type: 'all', unread: 'true' } }

      it 'returns only communication threads with unread count' do
        unread_thread, = create_thread_with_conversation(unread_count: 2)
        read_thread, = create_thread_with_conversation(unread_count: 0)

        result = finder.perform

        expect(result[:communication_threads].map(&:id)).to contain_exactly(unread_thread.id)
        expect(result[:communication_threads].map(&:id)).not_to include(read_thread.id)
      end

      it 'intersects unread with status, assignee, inbox, team, label, CRM, and appointment filters' do
        team = create(:team, account: account)
        other_team = create(:team, account: account)
        pipeline = create(:crm_pipeline, account: account)
        stage = create(:crm_stage, account: account, pipeline: pipeline)
        other_stage = create(:crm_stage, account: account, pipeline: pipeline)
        matching_thread, matching_conversation = create_thread_with_conversation(unread_count: 2)
        read_thread, read_conversation = create_thread_with_conversation(unread_count: 0)
        wrong_team_thread, wrong_team_conversation = create_thread_with_conversation(unread_count: 2)
        wrong_label_thread, wrong_label_conversation = create_thread_with_conversation(unread_count: 2)
        wrong_stage_thread, wrong_stage_conversation = create_thread_with_conversation(unread_count: 2)
        wrong_appointment_thread, wrong_appointment_conversation = create_thread_with_conversation(unread_count: 2)

        [matching_thread, read_thread, wrong_label_thread, wrong_stage_thread,
         wrong_appointment_thread].each do |thread|
          thread.update!(assignee: user, team: team)
        end
        wrong_team_thread.update!(assignee: user, team: other_team)

        [matching_conversation, read_conversation, wrong_team_conversation, wrong_label_conversation,
         wrong_stage_conversation, wrong_appointment_conversation].each do |conversation|
          conversation.update!(status: 'pending')
        end

        [matching_conversation, read_conversation, wrong_team_conversation, wrong_stage_conversation,
         wrong_appointment_conversation].each { |conversation| conversation.update_labels('vip') }
        wrong_label_conversation.update_labels('other')

        [matching_thread, read_thread, wrong_team_thread, wrong_label_thread, wrong_appointment_thread].each do |thread|
          create(:crm_deal, account: account, pipeline: pipeline, stage: stage,
                            originating_communication_thread: thread)
        end
        create(:crm_deal, account: account, pipeline: pipeline, stage: other_stage,
                          originating_communication_thread: wrong_stage_thread)

        [matching_conversation, read_conversation, wrong_team_conversation, wrong_label_conversation,
         wrong_stage_conversation].each do |conversation|
          create(:scheduling_appointment, account: account, contact: conversation.contact, conversation: conversation,
                                          status: 'confirmed')
        end
        create(:scheduling_appointment, account: account, contact: wrong_appointment_conversation.contact,
                                        conversation: wrong_appointment_conversation, status: 'scheduled')

        result = described_class.new(
          user,
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

        expect(result[:communication_threads].map(&:id)).to contain_exactly(matching_thread.id)
      end
    end

    it 'filters communication threads by appointment status through contacts and linked conversations' do
      appointment_contact = create(:contact, account: account)
      contact_thread = create_thread_for(contact: appointment_contact)
      direct_thread, direct_conversation = create_thread_with_conversation
      other_thread, other_conversation = create_thread_with_conversation

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

      result = finder.perform

      expect(result[:communication_threads].map(&:id)).to contain_exactly(contact_thread.id, direct_thread.id)
      expect(result[:communication_threads].map(&:id)).not_to include(other_thread.id)
    end

    it 'filters communication threads with any appointment when appointment status is any' do
      confirmed_thread, confirmed_conversation = create_thread_with_conversation
      scheduled_thread, scheduled_conversation = create_thread_with_conversation
      no_appointment_thread, = create_thread_with_conversation

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

      result = described_class.new(user, params.merge(appointment_status: 'any')).perform

      expect(result[:communication_threads].map(&:id)).to contain_exactly(confirmed_thread.id, scheduled_thread.id)
      expect(result[:communication_threads].map(&:id)).not_to include(no_appointment_thread.id)
    end

    it 'keeps appointment status counts as appointment records scoped by thread context' do
      _confirmed_thread, confirmed_conversation = create_thread_with_conversation(unread_count: 1)
      _scheduled_thread, scheduled_conversation = create_thread_with_conversation(unread_count: 1)
      _read_thread, read_conversation = create_thread_with_conversation(unread_count: 0)

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

      result = finder.perform

      expect(result[:count].dig(:unread_counts, :appointment_statuses)).to include(
        'confirmed' => 2,
        'scheduled' => 1
      )
    end
  end

  def create_thread_for(contact:, unread_count: 0)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact)
    thread = create(:communication_thread, account: account, contact: contact, unread_count: unread_count)
    create(
      :communication_thread_conversation,
      account: account,
      communication_thread: thread,
      conversation: conversation,
      inbox: inbox,
      contact_inbox: conversation.contact_inbox
    )
    thread
  end

  def create_thread_with_conversation(unread_count: 0)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact)
    thread = create(:communication_thread, account: account, contact: contact, unread_count: unread_count)
    create(
      :communication_thread_conversation,
      account: account,
      communication_thread: thread,
      conversation: conversation,
      inbox: inbox,
      contact_inbox: conversation.contact_inbox
    )
    [thread, conversation]
  end
end
