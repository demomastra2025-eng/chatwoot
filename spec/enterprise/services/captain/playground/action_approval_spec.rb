require 'rails_helper'

RSpec.describe Captain::Playground::ActionApproval do
  let(:account) { create(:account).tap { |item| item.enable_features!('crm_deals') } }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant) }
  let(:deal) { create(:crm_deal, account: account) }

  before { allow(assistant).to receive(:allowed_agent_tool_ids).and_return(%w[update_deal]) }
  after { Current.reset }

  def with_preview(inbox_id: nil)
    session.with_lock(inbox_id: inbox_id) do |workspace|
      workspace.set_permissions!(read: true, write: true)
      service = described_class.new(workspace)
      preview = service.preview('update_deal', deal_id: deal.id, title: 'Confirmed title')
      yield workspace, service, preview
    end
  end

  it 'requires the exact server digest and target snapshot and never runs a changed action' do
    with_preview do |_workspace, service, preview|
      expect { service.confirm(id: preview['id'], digest: 'forged') }.to raise_error(ArgumentError, /expired, changed, or was revoked/)
      deal.update!(title: 'Someone edited this target')
      expect { service.confirm(id: preview['id'], digest: preview['digest']) }.to raise_error(ArgumentError, /target or payload changed/)
      expect(deal.reload.title).to eq('Someone edited this target')
    end
  end

  it 'rechecks current profile selection at confirmation and cannot expand the tool list' do
    with_preview do |_workspace, service, preview|
      allow(assistant).to receive(:allowed_agent_tool_ids).and_return([])
      expect { service.confirm(id: preview['id'], digest: preview['digest']) }
        .to raise_error(Pundit::NotAuthorizedError, /not selected/)
      expect(deal.reload.title).not_to eq('Confirmed title')
    end
  end

  it 'checks revocation after preparing the target and again at actual execution' do
    with_preview do |workspace, service, preview|
      executor = service.instance_variable_get(:@executor)
      allow(executor).to receive(:prepare).and_wrap_original do |original, *args|
        result = original.call(*args)
        workspace.store.set_permissions(session_id: workspace.id, read: false, write: false)
        result
      end
      expect(executor).not_to receive(:execute)
      expect { service.confirm(id: preview['id'], digest: preview['digest']) }.to raise_error(ArgumentError, /revoked/)
    end
  end

  it 'marks a delegated validation failure failed and blocks replay without executing a real mutation' do
    with_preview do |_workspace, service, preview|
      executor = service.instance_variable_get(:@executor)
      expect(executor).to receive(:execute).once.and_return('ERROR: Invalid configured stage')
      expect(service.confirm(id: preview['id'], digest: preview['digest'])).to include(success: false, delivered: false)
      expect(preview['status']).to eq('failed')
      expect { service.confirm(id: preview['id'], digest: preview['digest']) }.to raise_error(ArgumentError, /revoked/)
    end
  end

  it 'does not let the final delegate execute from a policy whose generation was revoked' do
    with_preview do |workspace, _service, preview|
      preview['status'] = 'executing'
      workspace.save!
      policy = Outbound::PlaygroundDeliveryPolicy.issue(workspace.context_reference.merge(
        run_id: SecureRandom.uuid, action_id: preview['id'], action_digest: preview['digest'], generation: preview['generation'],
        tool: preview['tool'], arguments: preview['arguments'], target: preview['target'], delivery_enabled: false
      ))
      executor = Captain::Playground::RealToolExecutor.new(workspace)
      prepared = executor.prepare(preview['tool'], preview['arguments'])
      workspace.store.set_permissions(session_id: workspace.id, read: false, write: false)
      expect(prepared[:delegate]).not_to receive(:execute)
      Outbound::PlaygroundDeliveryPolicy.with(policy) do
        expect { executor.execute(preview['tool'], preview['arguments'], prepared: prepared) }.to raise_error(ArgumentError, /disabled|revoked/)
      end
    end
  end

  it 'compares the target again under its record lock after the preview was marked executing' do
    with_preview do |workspace, service, preview|
      allow(workspace).to receive(:save!).and_wrap_original do |original|
        result = original.call
        deal.update!(title: 'Changed while confirmation was saved')
        result
      end
      expect { service.confirm(id: preview['id'], digest: preview['digest']) }
        .to raise_error(ArgumentError, /target or payload changed/)
      expect(deal.reload.title).to eq('Changed while confirmation was saved')
      expect(preview['status']).to eq('failed')
    end
  end

  it 'cannot confirm the entry agent preview after another agent becomes active' do
    destination = create(:captain_assistant, account: account)
    with_preview(inbox_id: inbox.id) do |workspace, service, preview|
      workspace.activate_agent!(destination)
      expect(service.instance_variable_get(:@executor)).not_to receive(:execute)
      expect { service.confirm(id: preview['id'], digest: preview['digest']) }.to raise_error(ArgumentError, /revoked/)
    end
  end

  it 'binds a destination preview to its own tools and rechecks routing and activation at confirmation' do
    destination = create(:captain_assistant, account: account)
    allow(destination).to receive(:allowed_agent_tool_ids).and_return(%w[update_deal])
    session.with_lock(inbox_id: inbox.id) do |workspace|
      workspace.set_permissions!(read: true, write: true)
      workspace.activate_agent!(destination)
      service = described_class.new(workspace)
      preview = service.preview('update_deal', deal_id: deal.id, title: 'Destination title')
      expect(preview['binding']).to include('assistant_id' => destination.id, 'entry_assistant_id' => assistant.id)
      expect(service.instance_variable_get(:@executor)).not_to receive(:execute)

      destination.update!(active: false)
      expect { service.confirm(id: preview['id'], digest: preview['digest']) }.to raise_error(Pundit::NotAuthorizedError)
      destination.update!(active: true)
      # Routing is the grid of the chosen channel (its active external agents), not a stored list of the entry agent.
      destination.update!(usage_mode: 'internal_assistant')
      expect { service.confirm(id: preview['id'], digest: preview['digest']) }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  describe 'a real action of the owner of a council part, which is not the active agent of the session' do
    let(:owner) { create(:captain_assistant, account: account) }

    before do
      assistant.update!(handoff_agent_ids: [owner.id])
      # Only the owner has the tool in its profile; the record that the session loads for the owner is a fresh one.
      allow(assistant).to receive(:allowed_agent_tool_ids).and_return([])
      allow_any_instance_of(Captain::Assistant).to receive(:allowed_agent_tool_ids) { |agent| agent.id == owner.id ? %w[update_deal] : [] }
    end

    it 'records the owner in the preview, keeps the references of the session, and confirms the action as the owner' do
      session.with_lock do |workspace|
        workspace.set_permissions!(read: true, write: true)
        preview = described_class.new(workspace.acting_as(owner.id)).preview('update_deal', deal_id: deal.id, title: 'Owner title')

        expect(preview).to include('actor_id' => owner.id)
        expect(preview['binding']).to include('assistant_id' => assistant.id, 'entry_assistant_id' => assistant.id)

        result = described_class.new(workspace).confirm(id: preview['id'], digest: preview['digest'])

        expect(result).to include(success: true, delivered: false)
        expect(deal.reload.title).to eq('Owner title')
        expect(preview['status']).to eq('completed')
      end
    end

    it 'cannot be confirmed as another agent: the digest covers the owner' do
      allow(assistant).to receive(:allowed_agent_tool_ids).and_return(%w[update_deal])
      session.with_lock do |workspace|
        workspace.set_permissions!(read: true, write: true)
        preview = described_class.new(workspace.acting_as(owner.id)).preview('update_deal', deal_id: deal.id, title: 'Owner title')
        preview['actor_id'] = assistant.id

        expect { described_class.new(workspace).confirm(id: preview['id'], digest: preview['digest']) }
          .to raise_error(ArgumentError, /target or payload changed/)
        expect(deal.reload.title).not_to eq('Owner title')
      end
    end

    it 'still confirms a preview that was made before the owner was recorded: its digest did not cover it' do
      allow_any_instance_of(Captain::Assistant).to receive(:allowed_agent_tool_ids).and_return(%w[update_deal])
      with_preview do |workspace, service, preview|
        preview.delete('actor_id')
        legacy = preview.slice('tool', 'arguments', 'target', 'generation', 'binding')
        preview['digest'] = Digest::SHA256.hexdigest(JSON.generate(service.send(:canonical, legacy)))
        workspace.save!

        expect(service.confirm(id: preview['id'], digest: preview['digest'])).to include(success: true)
        expect(deal.reload.title).to eq('Confirmed title')
      end
    end
  end

  it 'does not grant a destination the entry agent selected tool list' do
    destination = create(:captain_assistant, account: account)
    allow(destination).to receive(:allowed_agent_tool_ids).and_return([])
    session.with_lock(inbox_id: inbox.id) do |workspace|
      workspace.set_permissions!(read: true, write: true)
      workspace.activate_agent!(destination)
      expect do
        described_class.new(workspace).preview('update_deal', deal_id: deal.id, title: 'Unselected action')
      end.to raise_error(Pundit::NotAuthorizedError, /not selected/)
    end
  end
end
