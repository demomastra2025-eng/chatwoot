require 'rails_helper'

RSpec.describe Captain::Runtime::Council::Lanes do
  def plan(id, writer: false, after: nil, refs: [])
    described_class::Plan.new(id: id, writer: writer, prerequisite_id: after, object_refs: refs)
  end

  def ids(lanes)
    lanes.map { |lane| lane.map(&:id) }
  end

  it 'keeps independent parts separate even when every owner has write tools' do
    lanes = described_class.build([plan('a', writer: true), plan('b', writer: true), plan('c', writer: true)])

    expect(ids(lanes)).to eq([%w[a], %w[b], %w[c]])
  end

  it 'gives every read-only part a lane of its own, next to the writer lane' do
    lanes = described_class.build([plan('read-1'), plan('write', writer: true), plan('read-2')])

    expect(ids(lanes)).to eq([%w[read-1], %w[write], %w[read-2]])
  end

  it 'keeps a dependent part after its prerequisite, in the lane of the prerequisite' do
    lanes = described_class.build([plan('a'), plan('b', after: 'a'), plan('c')])

    expect(ids(lanes)).to eq([%w[a b], %w[c]])
  end

  it 'moves a read-only part that depends on a writer into the writer lane, at its place in the plan' do
    lanes = described_class.build([plan('write', writer: true), plan('lonely'), plan('after', after: 'write')])

    expect(ids(lanes)).to eq([%w[write after], %w[lonely]])
  end

  it 'moves a writer that depends on a read-only part together with it into the writer lane' do
    lanes = described_class.build([plan('read'), plan('write', writer: true, after: 'read')])

    expect(ids(lanes)).to eq([%w[read write]])
  end

  it 'joins parts that name the same object, and the join is transitive' do
    appointment = { 'type' => 'appointment', 'id' => 7 }
    deal = { 'type' => 'deal', 'id' => 3 }
    lanes = described_class.build([plan('a', refs: [appointment]), plan('b', refs: [deal]), plan('c', refs: [appointment, deal]),
                                   plan('d', refs: [{ type: 'deal', id: 4 }])])

    expect(ids(lanes)).to eq([%w[a b c], %w[d]])
  end

  it 'moves the parts of a shared object into the writer lane when one of them writes' do
    task = { 'type' => 'task', 'id' => 1 }
    lanes = described_class.build([plan('read', refs: [task]), plan('other'), plan('write', writer: true, refs: [task])])

    expect(ids(lanes)).to eq([%w[read write], %w[other]])
  end

  it 'is empty for no parts' do
    expect(described_class.build([])).to eq([])
  end

  it 'does not treat a shared patient or contact as an implicit dependency for independent writer-capable parts' do
    refs = [{ type: 'patient', id: 1 }, { type: 'contact', id: 2 }]
    expect(ids(described_class.build([plan('a', writer: true, refs: refs), plan('b', writer: true, refs: refs)]))).to eq([%w[a], %w[b]])
  end
end
