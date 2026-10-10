require 'rails_helper'

RSpec.describe Captain::Playground::ActionApproval do
  let(:account) { create(:account).tap { |item| item.enable_features!('crm_deals') } }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant) }
  let(:deal) { create(:crm_deal, account: account) }

  before { allow(assistant).to receive(:allowed_agent_tool_ids).and_return(%w[update_deal]) }
  after { Current.reset }

  def with_preview
    session.with_lock do |workspace|
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
end
