require 'rails_helper'

RSpec.describe 'Playground context across automation rules' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account, status: :resolved) }
  let(:policy) do
    Outbound::PlaygroundDeliveryPolicy.issue(
      mode: 'live', run_id: SecureRandom.uuid, session_id: SecureRandom.uuid, account_id: account.id,
      user_id: user.id, assistant_id: 1, caller_contact_id: conversation.contact_id,
      conversation_id: conversation.id, inbox_id: conversation.inbox_id, delivery_enabled: false
    )
  end

  after { Current.reset }

  def ordered_rules(listener, event_name, *rules)
    allow(listener).to receive(:current_account_rules).with(event_name, account)
                                                    .and_return(account.automation_rules.where(id: rules.map(&:id)).order(:id))
  end

  context 'when one conversation event matches a label rule and then a team email rule' do
    let(:listener) { AutomationRuleListener.instance }
    let(:team) { create(:team, account: account) }
    let(:label_rule) do
      create(:automation_rule, account: account, actions: [{ action_name: 'add_label', action_params: ['priority'] }])
    end
    let(:email_rule) do
      create(:automation_rule, account: account, actions: [{ action_name: 'send_email_to_team',
                                                          action_params: [{ team_ids: [team.id], message: 'Staff follow-up' }] }])
    end

    before do
      create(:team_member, team: team, user: user)
      ordered_rules(listener, 'conversation_updated', label_rule, email_rule)
      allow(TeamNotifications::AutomationNotificationMailer).to receive(:conversation_creation).and_call_original
    end

    def process_conversation_event
      event = Events::Base.new('conversation_updated', Time.current, conversation: conversation)
      with_modified_env(SMTP_ADDRESS: 'smtp.example.test') { listener.conversation_updated(event) }
    end

    shared_examples 'blocked staff delivery' do
      it 'executes both rules while preserving the causal policy and clearing only the actor context' do
        Current.user = user
        Current.account = account
        Outbound::PlaygroundDeliveryPolicy.with(run_policy) do
          expect { process_conversation_event }.not_to change(ActionMailer::Base.deliveries, :size)
          expect(conversation.reload.label_list).to include('priority')
          expect(TeamNotifications::AutomationNotificationMailer).to have_received(:conversation_creation)
            .with(conversation, team, 'Staff follow-up')
          expect(Current.playground_run_policy).to eq(run_policy)
          expect([Current.user, Current.account, Current.executed_by]).to all(be_nil)
          Current.reset
          expect(Current.playground_run_policy).to be_nil
        end
      end
    end

    context 'with a signed disabled policy' do
      let(:run_policy) { policy }

      include_examples 'blocked staff delivery'
    end

    context 'with false policy taint' do
      let(:run_policy) { false }

      include_examples 'blocked staff delivery'
    end

    context 'with empty policy taint' do
      let(:run_policy) { {} }

      include_examples 'blocked staff delivery'
    end

    it 'keeps ordinary matching rules and team delivery working without a Playground policy' do
      expect { process_conversation_event }.to change(ActionMailer::Base.deliveries, :size).by(1)
      expect(conversation.reload.label_list).to include('priority')
      expect(Current.playground_run_policy).to be_nil
    end
  end

  context 'when an appointment event matches two rules' do
    let(:listener) { SchedulingAutomationRuleListener.instance }
    let(:appointment) do
      create(:scheduling_appointment, account: account, resource: create(:scheduling_resource, account: account),
                                       contact: conversation.contact, conversation: conversation, starts_at: 2.days.from_now)
    end
    let(:conditions) { [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }] }
    let(:status_rule) do
      create(:automation_rule, account: account, event_name: 'appointment_updated', conditions: conditions,
                               actions: [{ action_name: 'change_appointment_status', action_params: ['confirmed'] }])
    end
    let(:touch_rule) do
      create(:automation_rule, account: account, event_name: 'appointment_updated', conditions: conditions,
                               actions: [{ action_name: 'create_touch', action_params: [{ body: 'Appointment follow-up', delay_minutes: 10 }] }])
    end

    before do
      account.enable_features!('scheduling')
      user
      appointment
      ordered_rules(listener, 'appointment_updated', status_rule, touch_rule)
    end

    it 'retains the original policy through a native status mutation and the subsequent provider reminder' do
      event = Events::Base.new('appointment_updated', Time.current, appointment: appointment)
      Outbound::PlaygroundDeliveryPolicy.with(policy) { listener.appointment_updated(event) }

      expect(appointment.reload.status).to eq('confirmed')
      expect(appointment.custom_attributes['captain_playground']).to eq(policy)
      reminder = account.reminders.where(remindable: appointment).sole
      expect(reminder.metadata['captain_playground']).to eq(policy)

      Current.reset
      reminder.update!(status: :processing)
      expect(Reminders::AppointmentProviderGuard).not_to receive(:new)
      expect(Reminders::ConversationResolver).not_to receive(:new)
      Reminders::ExecuteService.new(reminder: reminder).perform
      expect(reminder.reload).to be_failed
      expect(reminder.last_error).to eq(Outbound::PlaygroundDeliveryPolicy::BLOCKED_MESSAGE)
    end
  end

  it 'preserves restrictions after a CRM rule before the next listener creates a reminder' do
    account.enable_features!('crm_deals')
    deal = create(:crm_deal, account: account)
    rule = create(:automation_rule, account: account, event_name: 'deal_updated',
                                    conditions: [{ attribute_key: 'stage_id', filter_operator: 'equal_to',
                                                   values: [deal.stage_id.to_s], query_operator: nil }],
                                    actions: [{ action_name: 'assign_deal_owner', action_params: [user.id] }])
    reminder = nil
    Outbound::PlaygroundDeliveryPolicy.with(policy) do
      AutomationRules::CrmActionService.new(rule, account, deal, entity_kind: 'deal').perform
      reminder = Reminders::CreateService.new(account: account, remindable: conversation,
                                            attributes: { body: 'Next listener follow-up', text_mode: 'static',
                                                          scheduled_at: 1.hour.from_now }, creator: user).perform
    end
    expect(deal.reload.owner_id).to eq(user.id)
    expect(reminder.reload.metadata['captain_playground']).to eq(policy)
  end

  it 'keeps macro restrictions active for subsequent outgoing actions without retaining its user' do
    macro = create(:macro, account: account, actions: [{ action_name: 'add_label', action_params: ['macro-follow-up'] }])
    Outbound::PlaygroundDeliveryPolicy.with(false) do
      Macros::ExecutionService.new(macro, conversation, user).perform
      expect(conversation.reload.label_list).to include('macro-follow-up')
      expect(Current.user).to be_nil
      expect do
        Messages::MessageBuilder.new(user, conversation, { content: 'Must remain blocked' }).perform
      end.to raise_error(Outbound::PlaygroundDeliveryPolicy::Blocked)
    end
  end
end
