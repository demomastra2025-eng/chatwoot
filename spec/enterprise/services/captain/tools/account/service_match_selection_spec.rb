require 'rails_helper'

# Which services found for the mentions of one call are offered: within a band of the best score, at most `limit` per mention, and a
# cap on the whole answer that leaves every mention its best service. No database: the hits are plain structs.
RSpec.describe Captain::Tools::Account::ServiceMatchSelection do
  let(:selection) { described_class.new(band: 0.05, cap: 6) }

  def result(mention, *scores)
    { mention: mention, hits: scores.each_with_index.map { |score, index| Scheduling::ServiceIndex::Hit.new("#{mention}-#{index}", score) } }
  end

  def scores_of(results)
    results.to_h { |item| [item[:mention], item[:hits].map(&:score)] }
  end

  it 'keeps the services within the band of the best one, at most the limit' do
    results = [result('a', 0.90, 0.88, 0.86, 0.84, 0.70)]

    expect(scores_of(selection.call(results, 3))).to eq('a' => [0.90, 0.88, 0.86])
    expect(scores_of(selection.call([result('b', 0.90, 0.88, 0.86, 0.84)], 10))).to eq('b' => [0.90, 0.88, 0.86])
  end

  it 'leaves a mention without services alone' do
    expect(scores_of(selection.call([result('empty')], 3))).to eq('empty' => [])
  end

  it 'cuts the whole answer to the cap by dropping the weakest service of the longest list, and never the best one of a mention' do
    results = [result('a', 0.95, 0.94, 0.93, 0.92), result('b', 0.95, 0.94, 0.93, 0.92), result('c', 0.95)]

    cut = selection.call(results, 4)

    expect(cut.sum { |item| item[:hits].size }).to eq(6)
    expect(scores_of(cut).values.map(&:first)).to eq([0.95, 0.95, 0.95])
    expect(scores_of(cut)['c']).to eq([0.95])
    expect((scores_of(cut)['a'].size - scores_of(cut)['b'].size).abs).to be <= 1
  end

  it 'stops cutting when every mention is down to its best service' do
    results = Array.new(8) { |index| result("m#{index}", 0.9) }

    expect(selection.call(results, 3).sum { |item| item[:hits].size }).to eq(8)
  end
end
