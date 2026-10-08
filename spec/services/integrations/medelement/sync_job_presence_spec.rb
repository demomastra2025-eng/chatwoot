require 'rails_helper'

RSpec.describe Integrations::Medelement::SyncJobPresence do
  let(:run) { instance_double(Integrations::Medelement::SyncRun, id: 29, hook_id: 17) }
  let(:presence) { described_class.new }

  def payload(arguments, wrapped: true)
    return { 'class' => described_class::JOB_CLASS, 'args' => arguments } unless wrapped

    {
      'class' => 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper',
      'wrapped' => described_class::JOB_CLASS,
      'args' => [{ 'job_class' => described_class::JOB_CLASS, 'arguments' => arguments }]
    }
  end

  it 'recognizes exact durable run payloads from the ActiveJob wrapper' do
    expect(presence.send(:matches?, payload([17, 29]), run)).to be(true)
  end

  it 'recognizes legacy direct payloads and retries that can resume the active hook run' do
    expect(presence.send(:matches?, payload([17, 29], wrapped: false), run)).to be(true)
    expect(presence.send(:matches?, payload([17, nil, %w[schedules]]), run)).to be(true)
  end

  it 'ignores another hook, another durable run and unrelated job classes' do
    expect(presence.send(:matches?, payload([18, 29]), run)).to be(false)
    expect(presence.send(:matches?, payload([17, 30]), run)).to be(false)
    expect(presence.send(:matches?, { 'class' => 'OtherJob', 'args' => [17, 29] }, run)).to be(false)
  end

  it 'treats an unrecognizable sync job payload as evidence against recovery' do
    expect(presence.send(:matches?, payload(nil), run)).to be(true)
    expect(presence.send(:matches?, payload([]), run)).to be(true)
  end
end
