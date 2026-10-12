require 'rails_helper'

RSpec.describe Captain::Runtime::Council::Lanes do
  def plan(id, writer: false, after: nil, refs: [])
    described_class::Plan.new(id: id, writer: writer, prerequisite_id: after, object_refs: refs)
  end

  def ids(lanes)
    { writer: lanes[:writer].map(&:id), readers: lanes[:readers].map { |lane| lane.map(&:id) } }
  end

  it 'puts every part whose owner can write into one lane in plan order, also for different people' do
    lanes = described_class.build([plan('a', writer: true), plan('b', writer: true), plan('c', writer: true)])

    expect(ids(lanes)).to eq(writer: %w[a b c], readers: [])
  end

  it 'gives every read-only part a lane of its own, next to the writer lane' do
    lanes = described_class.build([plan('read-1'), plan('write', writer: true), plan('read-2')])

    expect(ids(lanes)).to eq(writer: %w[write], readers: [%w[read-1], %w[read-2]])
  end

  it 'keeps a dependent part after its prerequisite, in the lane of the prerequisite' do
    lanes = described_class.build([plan('a'), plan('b', after: 'a'), plan('c')])

    expect(ids(lanes)).to eq(writer: [], readers: [%w[a b], %w[c]])
  end

  it 'moves a read-only part that depends on a writer into the writer lane, at its place in the plan' do
    lanes = described_class.build([plan('write', writer: true), plan('lonely'), plan('after', after: 'write')])

    expect(ids(lanes)).to eq(writer: %w[write after], readers: [%w[lonely]])
  end

  it 'moves a writer that depends on a read-only part together with it into the writer lane' do
    lanes = described_class.build([plan('read'), plan('write', writer: true, after: 'read')])

    expect(ids(lanes)).to eq(writer: %w[read write], readers: [])
  end

  it 'joins parts that name the same object, and the join is transitive' do
    appointment = { 'type' => 'appointment', 'id' => 7 }
    deal = { 'type' => 'deal', 'id' => 3 }
    lanes = described_class.build([plan('a', refs: [appointment]), plan('b', refs: [deal]), plan('c', refs: [appointment, deal]),
                                   plan('d', refs: [{ type: 'deal', id: 4 }])])

    expect(ids(lanes)).to eq(writer: [], readers: [%w[a b c], %w[d]])
  end

  it 'moves the parts of a shared object into the writer lane when one of them writes' do
    task = { 'type' => 'task', 'id' => 1 }
    lanes = described_class.build([plan('read', refs: [task]), plan('other'), plan('write', writer: true, refs: [task])])

    expect(ids(lanes)).to eq(writer: %w[read write], readers: [%w[other]])
  end

  it 'is empty for no parts' do
    expect(described_class.build([])).to eq(writer: [], readers: [])
  end
end
